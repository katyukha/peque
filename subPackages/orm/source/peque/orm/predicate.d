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
private import peque.exception: NotSupportedError, PequeException, QueryClientError, QueryError;
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

/// Constant TRUE (value=true) or FALSE (value=false) — no parameters.
struct LiteralNode { bool value; }

/** EXISTS (SELECT 1 FROM tableName _sq WHERE (...))
  *
  * tableName is the bare SQL table name (no alias).
  * inner is built with SF!(M, fieldName) references using the "_sq." prefix.
  * NOT EXISTS = ~Predicate(ExistsNode(...)) via the existing NotNode/~ operator.
  **/
struct ExistsNode { string tableName; Predicate* inner; }

/** col IN (SELECT ...) — produced by F!(M,"f").inSubquery(qs.asSubquery!"f"()).
  *
  * subquerySql holds the full SELECT statement; subqueryParams are its bound
  * values.  $N tokens in subquerySql are shifted by the outer offset at
  * serialisation time so they don't collide with outer query parameters.
  *
  * NOT IN: ~Predicate(InSubqueryNode(...)) via the existing NotNode/~ operator.
  **/
struct InSubqueryNode {
    string    colExpr;
    string    subquerySql;
    PGValue[] subqueryParams;
}

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
                                 LiteralNode, ExistsNode, PathNode,
                                 InSubqueryNode,
                                 AndNode, OrNode, NotNode);
    package(peque) PT _inner;

    this(T)(T node) { _inner = PT(node); }

    // Copy constructor — needed when boxing into heap-allocated Predicate*.
    this(Predicate src) { _inner = src._inner; }

    /** Always-false predicate — matches no rows. SQL: FALSE.
      *
      * Identity element for | (OR): none | p == p
      * Absorbing element for & (AND): none & p == none
      **/
    static @property Predicate none() { return Predicate(LiteralNode(false)); }

    /** Always-true predicate — matches every row. SQL: TRUE.
      *
      * Absorbing element for | (OR): all | p == all
      * Identity element for & (AND): all & p == p
      **/
    static @property Predicate all() { return Predicate(LiteralNode(true)); }

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
        // A NULL-valued equality is `col = NULL` in raw SQL, which is always
        // UNKNOWN and matches nothing. `where!"field"(nullable)` with an empty
        // Nullable means "field IS NULL", so emit that (no bound parameter).
        (ref EqNode n) => n.value.isNull
            ? SerializedPred(n.colExpr ~ " IS NULL", [])
            : SerializedPred(
                n.colExpr ~ " = $" ~ to!string(offset + 1),
                [n.value],
            ),
        // Likewise a NULL-valued `!=`/`<>` means "field IS NOT NULL". Other
        // operators against NULL (<, >, LIKE, …) are genuinely meaningless, so
        // they pass through unchanged.
        (ref OpNode n) => n.value.isNull && (n.op == "!=" || n.op == "<>")
            ? SerializedPred(n.colExpr ~ " IS NOT NULL", [])
            : SerializedPred(
                n.colExpr ~ " " ~ n.op ~ " $" ~ to!string(offset + 1),
                [n.value],
            ),
        (ref InNode n) {
            if (n.values.length == 0)
                return SerializedPred("FALSE", []);
            string ph;
            foreach (i, _; n.values) {
                if (i > 0) ph ~= ", ";
                ph ~= "$" ~ to!string(offset + i + 1);
            }
            return SerializedPred(n.colExpr ~ " IN (" ~ ph ~ ")", n.values);
        },
        (ref NullNode n)    => SerializedPred(n.colExpr ~ " IS NULL", []),
        // Parenthesised: every other leaf serialises to a single comparison and
        // is safe under AND precedence, but a raw fragment may contain OR, which
        // would otherwise re-associate when embedded as an And/Or child.
        (ref RawNode n)     => SerializedPred("(" ~ _shiftParams(n.sql, offset) ~ ")",
                                              n.params),
        (ref LiteralNode n) => SerializedPred(n.value ? "TRUE" : "FALSE", []),
        (ref ExistsNode n) {
            enforce!NotSupportedError(!_containsExistsNode(*n.inner),
                "Nested EXISTS subqueries are not supported: both levels would " ~
                "alias their inner table to _sq, producing incorrect SQL. " ~
                "Rewrite using a JOIN or a single-level exists!() instead.");
            auto i = serializePredicate(*n.inner, offset);
            return SerializedPred(
                "EXISTS (SELECT 1 FROM " ~ n.tableName ~ " _sq WHERE (" ~ i.sql ~ "))",
                i.params,
            );
        },
        (ref InSubqueryNode n) => SerializedPred(
            n.colExpr ~ " IN (" ~ _shiftParams(n.subquerySql, offset) ~ ")",
            n.subqueryParams,
        ),
        (ref PathNode n) {
            // enforce, not assert(false): reachable whenever a predicate tree is
            // serialised without going through QuerySet.where(), and assert would
            // be compiled out under -release, halting with no diagnostic.
            enforce!QueryClientError(false,
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
        (ref EqNode      _) => false,
        (ref OpNode      _) => false,
        (ref InNode      _) => false,
        (ref NullNode    _) => false,
        (ref RawNode     _) => false,
        (ref LiteralNode _) => false,
        (ref ExistsNode      _) => true,
        (ref InSubqueryNode  _) => false,
        (ref PathNode        _) => false,
        (ref AndNode n) => _containsExistsNode(*n.left) || _containsExistsNode(*n.right),
        (ref OrNode  n) => _containsExistsNode(*n.left) || _containsExistsNode(*n.right),
        (ref NotNode n) => _containsExistsNode(*n.inner),
    );
}


// True when the quote at sql[i] opens an E'...' escape-string literal, where a
// backslash escapes the following character. In standard (non-E) literals
// backslashes are ordinary characters and only '' escapes a quote.
private bool _isEscapeStringStart(string sql, size_t i) pure nothrow @safe @nogc {
    if (i == 0) return false;
    immutable char p = sql[i - 1];
    if (p != 'E' && p != 'e') return false;
    // The E must stand alone, not end an identifier (e.g. `type'x'`).
    if (i >= 2) {
        immutable char q = sql[i - 2];
        immutable bool identChar =
            (q >= 'a' && q <= 'z') || (q >= 'A' && q <= 'Z') ||
            (q >= '0' && q <= '9') || q == '_';
        if (identChar) return false;
    }
    return true;
}

// If sql[i] opens a dollar-quoted string, return its full tag ("$$", "$tag$");
// otherwise return "". A digit after '$' means a parameter, never a tag.
private string _dollarQuoteTag(string sql, size_t i) pure nothrow @safe @nogc {
    if (i >= sql.length || sql[i] != '$') return "";
    size_t j = i + 1;
    if (j < sql.length && sql[j] == '$') return sql[i .. j + 1];
    while (j < sql.length) {
        immutable char c = sql[j];
        immutable bool identChar =
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
            (j > i + 1 && c >= '0' && c <= '9');   // tag may not start with a digit
        if (!identChar) break;
        ++j;
    }
    if (j > i + 1 && j < sql.length && sql[j] == '$') return sql[i .. j + 1];
    return "";
}

/** Offset all $N placeholder tokens in a SQL fragment by `offset`.
  *
  * Only real placeholders are rewritten. String literals ('...' and E'...'),
  * quoted identifiers ("..."), dollar-quoted bodies ($$...$$, $tag$...$tag$)
  * and comments (-- and nestable / * … * /) are copied through verbatim — a
  * naive scan would silently corrupt e.g. whereRaw("tag = 'v$1x'") into
  * 'v$2x' when the fragment is serialised at a non-zero offset.
  **/
package(peque) string _shiftParams(string sql, int offset) pure {
    import std.string: indexOf;

    if (offset == 0) return sql;
    string result;
    size_t i = 0;

    while (i < sql.length) {
        immutable char c = sql[i];
        immutable size_t start = i;

        // -- line comment
        if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
            while (i < sql.length && sql[i] != '\n') ++i;
            result ~= sql[start .. i];
            continue;
        }

        // /* block comment */ — nests in PostgreSQL
        if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
            int depth = 0;
            while (i < sql.length) {
                if (i + 1 < sql.length && sql[i] == '/' && sql[i + 1] == '*') {
                    ++depth; i += 2;
                } else if (i + 1 < sql.length && sql[i] == '*' && sql[i + 1] == '/') {
                    --depth; i += 2;
                    if (depth == 0) break;
                } else ++i;
            }
            result ~= sql[start .. i];
            continue;
        }

        // '...' string literal — '' escapes; backslash escapes only in E'...'
        if (c == '\'') {
            immutable bool escapes = _isEscapeStringStart(sql, i);
            ++i;
            while (i < sql.length) {
                if (escapes && sql[i] == '\\' && i + 1 < sql.length) { i += 2; continue; }
                if (sql[i] == '\'') {
                    if (i + 1 < sql.length && sql[i + 1] == '\'') { i += 2; continue; }
                    ++i;
                    break;
                }
                ++i;
            }
            result ~= sql[start .. i];
            continue;
        }

        // "..." quoted identifier — "" escapes
        if (c == '"') {
            ++i;
            while (i < sql.length) {
                if (sql[i] == '"') {
                    if (i + 1 < sql.length && sql[i + 1] == '"') { i += 2; continue; }
                    ++i;
                    break;
                }
                ++i;
            }
            result ~= sql[start .. i];
            continue;
        }

        if (c == '$') {
            // $tag$ ... $tag$ dollar-quoted body
            immutable string tag = _dollarQuoteTag(sql, i);
            if (tag.length) {
                i += tag.length;
                immutable auto end = indexOf(sql[i .. $], tag);
                i = (end < 0) ? sql.length : i + end + tag.length;
                result ~= sql[start .. i];
                continue;
            }
            // $N placeholder
            if (i + 1 < sql.length && sql[i + 1] >= '1' && sql[i + 1] <= '9') {
                ++i;
                immutable size_t ds = i;
                while (i < sql.length && sql[i] >= '0' && sql[i] <= '9') ++i;
                result ~= "$" ~ to!string(to!int(sql[ds .. i]) + offset);
                continue;
            }
        }

        result ~= c;
        ++i;
    }
    return result;
}

unittest {
    // Plain placeholders shift.
    assert(_shiftParams("a = $1 AND b = $2", 2) == "a = $3 AND b = $4");
    assert(_shiftParams("a = $1", 0) == "a = $1");           // offset 0 is a no-op
    assert(_shiftParams("a = $9 OR b = $10", 1) == "a = $10 OR b = $11");

    // $N inside literals must NOT shift.
    assert(_shiftParams("tag = 'v$1x' AND b = $1", 1) == "tag = 'v$1x' AND b = $2");
    assert(_shiftParams("a = '$1'", 5) == "a = '$1'");
    assert(_shiftParams(`a = "$1col" AND b = $1`, 1) == `a = "$1col" AND b = $2`);

    // Escaped quotes keep the scanner inside/outside the literal correctly.
    assert(_shiftParams("a = 'it''s $1' AND b = $1", 1) == "a = 'it''s $1' AND b = $2");
    assert(_shiftParams(`a = "x""y$1" AND b = $1`, 1) == `a = "x""y$1" AND b = $2`);
    assert(_shiftParams(`a = E'\'$1' AND b = $1`, 1) == `a = E'\'$1' AND b = $2`);

    // Dollar-quoted bodies are opaque.
    assert(_shiftParams("a = $$b $1 c$$ AND d = $1", 1) == "a = $$b $1 c$$ AND d = $2");
    assert(_shiftParams("a = $tag$ $1 $tag$ AND d = $1", 3) == "a = $tag$ $1 $tag$ AND d = $4");
    // An unterminated dollar quote consumes the rest rather than corrupting it.
    assert(_shiftParams("a = $$ $1", 1) == "a = $$ $1");

    // Comments are copied verbatim, including a nested block comment.
    assert(_shiftParams("a = $1 -- keep $1\nb = $1", 1) == "a = $2 -- keep $1\nb = $2");
    assert(_shiftParams("a = $1 /* $1 /* $1 */ $1 */ b = $1", 1) ==
           "a = $2 /* $1 /* $1 */ $1 */ b = $2");

    // Non-placeholder dollars pass through untouched.
    assert(_shiftParams("cost $ = $1", 1) == "cost $ = $2");
    assert(_shiftParams("a = $0", 1) == "a = $0");   // $0 is not a valid placeholder
}
