/** WHERE predicate expression tree for peque:orm.
  *
  * Provides a composable, type-safe predicate system for QuerySet.where().
  * Build leaf predicates via FieldBuilder (the F template in peque.orm.field),
  * compose with |, &, ~:
  *
  * ---
  * import peque.orm;
  *
  * // equality
  * F!(User, "status")("active")
  *
  * // comparison
  * F!(User, "age") >= 18
  *
  * // OR
  * F!(User, "status")("active") | F!(User, "status")("pending")
  *
  * // AND (between .where() calls is implicit; explicit & inside a predicate)
  * F!(User, "dept")("eng") & F!(User, "level") >= 3
  *
  * // NOT
  * ~F!(User, "isAdmin")(false)
  *
  * // raw escape hatch — use in QuerySet.whereRaw(), not directly
  * ---
  **/
module peque.orm.predicate;

private import std.conv: to;
private import std.sumtype: SumType, match;
private import peque.converter: PGValue;
private import peque.exception: PequeException;
private import std.exception: enforce;


// ---------------------------------------------------------------------------
// Leaf nodes
// ---------------------------------------------------------------------------

/// col = $N
struct EqNode   { string colExpr; PGValue value; }

/// col OP $N  (OP = >=, <=, >, <, !=, LIKE)
struct OpNode   { string colExpr; string op; PGValue value; }

/// col IN ($N, $N+1, ...)
struct InNode   { string colExpr; PGValue[] values; }

/// col IS NULL
struct NullNode { string colExpr; }

/// Raw SQL fragment — $1/$2/... are offset-shifted at serialisation time
struct RawNode  { string sql; PGValue[] params; }

/** EXISTS (SELECT 1 FROM tableName _sq WHERE (...))
  *
  * tableName is the bare SQL table name (no alias).
  * inner is built with SF!(M, fieldName) references using the "_sq." prefix.
  * NOT EXISTS = ~Predicate(ExistsNode(...)) via the existing NotNode/~ operator.
  **/
struct ExistsNode { string tableName; Predicate* inner; }

/** Unresolved field-path predicate — created by the type-free F!"path" template.
  *
  * path:      D camelCase field path, e.g. "status", "deliveryAddress.country"
  * op:        "=", "!=", ">", ">=", "<", "<=", "LIKE", "IN", "IS NULL"
  * params:    bound values (empty for IS NULL; one for scalar ops; multiple for IN)
  * otherPath: second path for column-to-column comparisons, else ""
  *
  * PathNodes MUST be resolved by the QuerySet before serialization; calling
  * serializePredicate on an unresolved PathNode is a programming error.
  **/
struct PathNode {
    string    path;
    string    op;
    PGValue[] params;
    string    otherPath;
}


// ---------------------------------------------------------------------------
// Branch nodes — recursive via heap-allocated Predicate*
// ---------------------------------------------------------------------------

struct AndNode { Predicate* left; Predicate* right; }
struct OrNode  { Predicate* left; Predicate* right; }
struct NotNode { Predicate* inner; }


// ---------------------------------------------------------------------------
// Predicate — tagged union with composition operators
// ---------------------------------------------------------------------------

struct Predicate {
    private alias PT = SumType!(EqNode, OpNode, InNode, NullNode, RawNode,
                                 ExistsNode, PathNode, AndNode, OrNode, NotNode);
    package(peque) PT _inner;

    this(T)(T node) { _inner = PT(node); }

    // Copy constructor — needed when boxing into heap-allocated Predicate*.
    this(Predicate src) { _inner = src._inner; }

    /// Compose with OR.
    Predicate opBinary(string op : "|")(Predicate rhs) {
        return Predicate(OrNode(new Predicate(this), new Predicate(rhs)));
    }

    /// Compose with AND.
    Predicate opBinary(string op : "&")(Predicate rhs) {
        return Predicate(AndNode(new Predicate(this), new Predicate(rhs)));
    }

    /// Negate.
    Predicate opUnary(string op : "~")() {
        return Predicate(NotNode(new Predicate(this)));
    }
}


// ---------------------------------------------------------------------------
// Serialisation
// ---------------------------------------------------------------------------

/// Output of serializePredicate.
struct SerializedPred {
    string    sql;
    PGValue[] params;
}

/** Serialise a predicate to a SQL fragment + flat parameter list.
  *
  * Parameters are numbered starting at (offset + 1) so callers that have
  * already bound N parameters pass offset = N.
  **/
package(peque) SerializedPred serializePredicate(ref Predicate pred, int offset = 0) {
    return pred._inner.match!(
        (ref EqNode n) => SerializedPred(
            n.colExpr ~ " = $" ~ to!string(offset + 1),
            [n.value],
        ),
        (ref OpNode n) => SerializedPred(
            n.colExpr ~ " " ~ n.op ~ " $" ~ to!string(offset + 1),
            [n.value],
        ),
        (ref InNode n) {
            string ph;
            foreach (i, _; n.values) {
                if (i > 0) ph ~= ", ";
                ph ~= "$" ~ to!string(offset + i + 1);
            }
            return SerializedPred(n.colExpr ~ " IN (" ~ ph ~ ")", n.values);
        },
        (ref NullNode n)  => SerializedPred(n.colExpr ~ " IS NULL", []),
        (ref RawNode n)   => SerializedPred(_shiftParams(n.sql, offset), n.params),
        (ref ExistsNode n) {
            enforce!PequeException(!_containsExistsNode(*n.inner),
                "Nested EXISTS subqueries are not supported: both levels would " ~
                "alias their inner table to _sq, producing incorrect SQL. " ~
                "Rewrite using a JOIN or a single-level exists!() instead.");
            auto i = serializePredicate(*n.inner, offset);
            return SerializedPred(
                "EXISTS (SELECT 1 FROM " ~ n.tableName ~ " _sq WHERE (" ~ i.sql ~ "))",
                i.params,
            );
        },
        (ref PathNode n) {
            assert(false,
                "PathNode for path '" ~ n.path ~ "' was not resolved before SQL serialization. " ~
                "Pass F!\"path\" predicates through QuerySet.where() which resolves them.");
            return SerializedPred.init;
        },
        (ref AndNode n) {
            auto l = serializePredicate(*n.left,  offset);
            auto r = serializePredicate(*n.right, offset + cast(int)l.params.length);
            return SerializedPred("(" ~ l.sql ~ " AND " ~ r.sql ~ ")", l.params ~ r.params);
        },
        (ref OrNode n) {
            auto l = serializePredicate(*n.left,  offset);
            auto r = serializePredicate(*n.right, offset + cast(int)l.params.length);
            return SerializedPred("(" ~ l.sql ~ " OR "  ~ r.sql ~ ")", l.params ~ r.params);
        },
        (ref NotNode n) {
            auto i = serializePredicate(*n.inner, offset);
            return SerializedPred("NOT (" ~ i.sql ~ ")", i.params);
        },
    );
}

// Return true if the predicate tree contains at least one ExistsNode anywhere.
private bool _containsExistsNode(ref Predicate pred) {
    return pred._inner.match!(
        (ref EqNode   _) => false,
        (ref OpNode   _) => false,
        (ref InNode   _) => false,
        (ref NullNode _) => false,
        (ref RawNode  _) => false,
        (ref ExistsNode _) => true,
        (ref PathNode _) => false,
        (ref AndNode n) => _containsExistsNode(*n.left) || _containsExistsNode(*n.right),
        (ref OrNode  n) => _containsExistsNode(*n.left) || _containsExistsNode(*n.right),
        (ref NotNode n) => _containsExistsNode(*n.inner),
    );
}


// Offset all $N tokens in a SQL fragment by `offset`.
package(peque) string _shiftParams(string sql, int offset) pure {
    if (offset == 0) return sql;
    string result;
    size_t i = 0;
    while (i < sql.length) {
        if (sql[i] == '$' && i + 1 < sql.length &&
                sql[i + 1] >= '1' && sql[i + 1] <= '9') {
            ++i;
            size_t start = i;
            while (i < sql.length && sql[i] >= '0' && sql[i] <= '9') ++i;
            result ~= "$" ~ to!string(to!int(sql[start .. i]) + offset);
        } else {
            result ~= sql[i++];
        }
    }
    return result;
}
