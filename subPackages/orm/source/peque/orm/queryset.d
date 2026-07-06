/** Lazy query builder for peque:orm.
  *
  * QuerySet!(M, Ctx, JoinFields...) is a value type that accumulates WHERE
  * filters, ORDER BY, LIMIT, OFFSET, SET (for partial updates), and join
  * specifications.  Nothing is sent to the database until a terminal method
  * is called.  QuerySets are immutable by convention — every builder method
  * returns a new copy, so you can safely branch from a base query:
  *
  * ---
  * auto base    = repo.query().where!"active"(true);
  * auto admins  = base.where!"role"("admin").all();
  * auto editors = base.where!"role"("editor").all();
  * ---
  *
  * Builder methods (return new QuerySet):
  *  - where!"field"(val)      — type-safe equality WHERE (compile-time field check)
  *  - whereIn!"field"(vals)   — type-safe IN clause
  *  - where(Predicate)        — composable predicate (F expressions, OR/AND/NOT)
  *  - whereRaw(sql, args...)  — raw SQL escape hatch (local $1/$2 renumbered)
  *  - orderBy(clause)         — set ORDER BY
  *  - limit(n)                — set LIMIT
  *  - offset(n)               — set OFFSET
  *  - set!(fieldName)(val)    — accumulate a SET assignment (for update())
  *  - joinOne!(relField)      — LEFT JOIN a @related/@many2one field
  *  - prefetch!(relField)     — schedule a post-query SELECT for @one2many/@many2many
  *  - groupBy!("field", …)    — switch to a GroupedQuerySet (GROUP BY / HAVING)
  *
  * Terminal methods:
  *  - all()                → M[]          — fetch all matching rows
  *  - first()              → Nullable!M   — fetch at most one row
  *  - count()              → long         — SELECT COUNT(*)
  *  - exists()             → bool         — SELECT 1 … LIMIT 1
  *  - aggregate!(agg)()    → Nullable!T   — scalar SUM/AVG/MIN/MAX/COUNT via F!(M,"f").sum etc.
  *  - asSubquery!"f"()     → SubQuery!T   — capture as single-column subquery atom (no DB call)
  *  - delete_()            → long         — DELETE, returns rows deleted
  *  - update()             → long         — partial UPDATE using accumulated set!() calls
  *  - select!DTO()         → DTO[]        — project main + join columns into a DTO
  *
  * Grouped queries (GroupedQuerySet, produced by groupBy!):
  *  - annotate!("alias", F!(M,"f").sum)   — typed aggregate SELECT column
  *  - annotate!("alias", "RAW SQL")       — raw aggregate expression (trusted)
  *  - having(Predicate)                   — filter groups (aggregate comparisons)
  *  - select!DTO()                        — grouped projection, GROUP-BY-validated
  **/
module peque.orm.queryset;

private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.traits: hasUDA, FieldNameTuple, Fields;
private import std.string: indexOf;
private import std.exception: enforce;
private import peque.exception: PequeException;

private import peque.model: model, defaultOrder, field, primaryKey, related,
    one2many, many2many, many2one, OnDelete, hasMany2OneUDA, autoHydrate;
private import peque.converter: PGValue, convertToPG;
private import peque.query_context: isQueryContext;
private import peque.orm.repository: isModel;
private import peque.orm.sql;
private import peque.orm.predicate;
private import peque.orm.field: FieldBuilder, PathBuilder, AggBuilder, isAggBuilder, F, toOrdering;
private import peque.orm.ordering: Ordering, OrderKind, OrderDir, OrderNulls;
private import peque.orm.predicate: PathNode, LiteralNode, InSubqueryNode;
private import peque.orm.subquery: SubQuery;
private import std.sumtype: match;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Extract the default ORDER BY terms from the @defaultOrder UDA on M, or [].
// Each UDA argument is normalized via toOrdering: a string becomes a raw term,
// an F builder / Ordering becomes a managed field term.
private template _modelDefaultOrder(M) {
    static if (hasUDA!(M, defaultOrder)) {
        private static Ordering[] _compute() {
            Ordering[] terms;
            static foreach (uda; __traits(getAttributes, M)) {{
                static if (is(uda) && is(uda == defaultOrder!fields, fields...)) {
                    static foreach (f; fields)
                        terms ~= toOrdering(f);
                }
            }}
            return terms;
        }
        enum Ordering[] _modelDefaultOrder = _compute();
    } else {
        enum Ordering[] _modelDefaultOrder = [];
    }
}

// Extract the inner (non-Nullable) type from a @related field on M named jf.
private template _innerRelType(M, string jf) {
    alias _FT = typeof(__traits(getMember, M, jf));
    static if (is(_FT == Nullable!U, U))
        alias _innerRelType = U;
    else
        alias _innerRelType = _FT;
}

// Extract the target model type from a @many2one!(T, ...) field on M.
private template _m2oRelType(M, string memberName) {
    private alias _Mem = __traits(getMember, M, memberName);
    static foreach (_uda; __traits(getAttributes, _Mem)) {
        static if (is(_uda == many2one!(_U, _od), _U, OnDelete _od)) {
            alias _m2oRelType = _U;
        }
    }
}

// Related model type for a relation-field name on M (whether @related or
// @many2one), or `void` if relName is not a relation field. Used for
// compile-time validation of join-path order specs.
private template _pathRelType(M, string relName) {
    private template _scan(size_t i) {
        static if (i >= FieldNameTuple!M.length)
            alias _scan = void;
        else {
            private enum  _mn  = FieldNameTuple!M[i];
            private alias _Mem = __traits(getMember, M, _mn);
            static if (_mn == relName && hasUDA!(_Mem, related))
                alias _scan = _innerRelType!(M, _mn);
            else static if (_mn == relName && hasMany2OneUDA!_Mem)
                alias _scan = _m2oRelType!(M, _mn);
            else
                alias _scan = _scan!(i + 1);
        }
    }
    alias _pathRelType = _scan!0;
}

// FK column on M used to join to a relation field's target table: a @related
// field resolves to its backing FK column; a @many2one field is itself the FK
// column. Returns "" if relName is not a relation field. Single source of truth
// for the FK-column half of join-path resolution (paired with _pathRelType).
private template _pathFkCol(M, string relName) {
    private template _scan(size_t i) {
        static if (i >= FieldNameTuple!M.length)
            enum string _scan = "";
        else {
            private enum  _mn  = FieldNameTuple!M[i];
            private alias _Mem = __traits(getMember, M, _mn);
            static if (_mn == relName && hasUDA!(_Mem, related))
                enum string _scan = _fkColForRelatedField!(M, _mn, _innerRelType!(M, _mn))();
            else static if (_mn == relName && hasMany2OneUDA!_Mem)
                enum string _scan = _colName!(_Mem, _mn);
            else
                enum string _scan = _scan!(i + 1);
        }
    }
    enum string _pathFkCol = _scan!0;
}

// ---------------------------------------------------------------------------
// Module-level prefetch executor — called at runtime from a delegate stored
// in _prefetches.  Separate from QuerySet to avoid circular template issues.
// ---------------------------------------------------------------------------

private void _execPrefetch(M, Ctx, string relField)(ref M[] rows, Ctx* ctx) {
    import std.conv: to;
    import std.array: join;
    import peque.orm.sql: buildSelectList, ormTableName, ormPkColName,
        ormPkFieldName, _findM2OFKColFor;
    import peque.hydration: _hydrateAnnotated;

    static foreach (memberName; FieldNameTuple!M) {{
        static if (memberName == relField) {
            alias FieldType  = typeof(__traits(getMember, M, memberName));

            // ---- @one2many -----------------------------------------------
            static foreach (uda; __traits(getAttributes, __traits(getMember, M, memberName))) {{
                static if (is(uda) && is(uda == one2many!(TargetM, invField), TargetM, string invField)) {
                    // Collect unique PKs from main rows (O(n) via seen-set).
                    alias PkType = typeof(__traits(getMember, M, ormPkFieldName!M()));
                    PkType[] pks;
                    bool[PkType] pkSeen;
                    foreach (ref r; rows) {
                        auto pk = __traits(getMember, r, ormPkFieldName!M());
                        if (pk !in pkSeen) { pkSeen[pk] = true; pks ~= pk; }
                    }
                    if (pks.length == 0) return;

                    // Build IN placeholders: $1, $2, ...
                    string placeholders;
                    foreach (i; 0 .. pks.length) {
                        if (i > 0) placeholders ~= ", ";
                        placeholders ~= "$" ~ to!string(i + 1);
                    }

                    // FK column on TargetM — resolve from the named invField directly
                    // (the field may have @field or @many2one UDA; either is valid)
                    alias InvFieldDecl = __traits(getMember, TargetM, invField);
                    enum fkCol = _colName!(InvFieldDecl, invField);

                    string sql = "SELECT " ~ buildSelectList!TargetM() ~
                                 " FROM "  ~ ormTableName!TargetM ~
                                 " WHERE " ~ fkCol ~ " IN (" ~ placeholders ~ ")";

                    // Build PGValue[] array
                    PGValue[] pgParams;
                    foreach (pk; pks) pgParams ~= convertToPG(pk);

                    auto result = ctx.execParams(sql, pgParams);

                    // Stitch: for each target row, find matching M row(s)
                    TargetM[] targets;
                    targets.length = result.ntuples;
                    foreach (i; 0 .. result.ntuples)
                        targets[i] = result.getRow(i).as!TargetM;

                    enum invFkField = invField; // D field name on TargetM
                    foreach (ref m; rows) {
                        alias ElemType = typeof(FieldType.init[0]);
                        ElemType[] arr;
                        foreach (ref t; targets) {
                            if (__traits(getMember, t, invFkField) == __traits(getMember, m, ormPkFieldName!M()))
                                arr ~= t;
                        }
                        __traits(getMember, m, memberName) = arr;
                    }
                }
            }}

            // ---- @many2many ---------------------------------------------
            static foreach (uda; __traits(getAttributes, __traits(getMember, M, memberName))) {{
                static if (is(uda) && is(uda == many2many!(TargetM, jt, sk, tk), TargetM, string jt, string sk, string tk)) {
                    alias PkType = typeof(__traits(getMember, M, ormPkFieldName!M()));
                    PkType[] pks;
                    bool[PkType] pkSeen;
                    foreach (ref r; rows) {
                        auto pk = __traits(getMember, r, ormPkFieldName!M());
                        if (pk !in pkSeen) { pkSeen[pk] = true; pks ~= pk; }
                    }
                    if (pks.length == 0) return;

                    string placeholders;
                    foreach (i; 0 .. pks.length) {
                        if (i > 0) placeholders ~= ", ";
                        placeholders ~= "$" ~ to!string(i + 1);
                    }

                    enum targetPkCol = ormPkColName!TargetM();
                    string sql =
                        "SELECT " ~ buildSelectList!TargetM() ~ ", j." ~ sk ~
                        " FROM " ~ ormTableName!TargetM ~ " t" ~
                        " JOIN " ~ jt ~ " j ON j." ~ tk ~ " = t." ~ targetPkCol ~
                        " WHERE j." ~ sk ~ " IN (" ~ placeholders ~ ")";

                    PGValue[] pgParams;
                    foreach (pk; pks) pgParams ~= convertToPG(pk);

                    auto result = ctx.execParams(sql, pgParams);

                    // Decode target rows + selfKey column
                    // The self-key column is the last column appended to the query
                    foreach (ref m; rows) {
                        alias ElemType = typeof(FieldType.init[0]);
                        ElemType[] arr;
                        foreach (i; 0 .. result.ntuples) {
                            auto row = result.getRow(i);
                            auto selfKeyVal = row[sk].as!PkType;
                            if (selfKeyVal == __traits(getMember, m, ormPkFieldName!M())) {
                                arr ~= row.as!TargetM;
                            }
                        }
                        __traits(getMember, m, memberName) = arr;
                    }
                }
            }}
        }
    }}
}


// ---------------------------------------------------------------------------
// Filter-join infrastructure — implicit joins from F!"rel.field" paths
// ---------------------------------------------------------------------------

private struct _FilterJoin {
    string path;         // dedup key: "partner", "partner.company"
    string alias_;       // SQL alias: "fj0", "fj1", …
    string table;        // SQL table name
    string pkCol;        // PK column of the joined table
    string parentAlias;  // "_m" or parent join alias for chained joins
    string fkCol;        // FK column on the parent
}

// True if M has a @related or @many2one member with the given D name (runtime check).
private bool _isKnownRelField(M)(string name) {
    import peque.model: related;
    bool found = false;
    static foreach (memberName; FieldNameTuple!M) {{
        alias Mem = __traits(getMember, M, memberName);
        static if (hasUDA!(Mem, related) || hasMany2OneUDA!Mem) {
            if (memberName == name) found = true;
        }
    }}
    return found;
}

// Resolve a 1-level join path "relName.fieldName" against M.
// Checks JoinFields first (reuse hydration join alias), then existing fjoins,
// then adds a new filter join.
private string _resolveOneLevel(M, JoinFields...)(
    string relName, string fieldName,
    ref _FilterJoin[] fjoins, ref int idx)
{
    import peque.model: related;
    string result;

    // 1 — reuse an existing hydration join (JoinFields)
    static foreach (jfIdx, jf; JoinFields) {{
        if (jf == relName && !result.length) {
            alias JfRelType = _innerRelType!(M, jf);
            result = "j" ~ to!string(jfIdx) ~ "." ~ _fieldColNameRuntime!JfRelType(fieldName);
        }
    }}
    if (result.length) return result;

    // 2 — reuse an existing filter join
    foreach (ref fj; fjoins) {
        if (fj.path == relName) {
            // Use camelToSnake fallback since we can't get RelType here
            import peque.hydration: camelToSnake;
            return fj.alias_ ~ "." ~ camelToSnake(fieldName);
        }
    }

    // 3 — create a new filter join (via @related or @many2one — same shape,
    //     differing only in target type / FK column, both from the helpers)
    static foreach (memberName; FieldNameTuple!M) {{
        alias Mem = __traits(getMember, M, memberName);
        static if (hasUDA!(Mem, related) || hasMany2OneUDA!Mem) {
            if (memberName == relName && !result.length) {
                alias RelType = _pathRelType!(M, memberName);
                enum  fkCol    = _pathFkCol!(M, memberName);
                enum  relTable = ormTableName!RelType;
                enum  relPkCol = ormPkColName!RelType();
                string jAlias = "fj" ~ to!string(idx);
                fjoins ~= _FilterJoin(relName, jAlias, relTable, relPkCol, "_m", fkCol);
                idx++;
                result = jAlias ~ "." ~ _fieldColNameRuntime!RelType(fieldName);
            }
        }
    }}

    assert(result.length > 0,
        "No @related or @many2one field '" ~ relName ~ "' on " ~ M.stringof);
    return result;
}

// Resolve a 2-level join path "rel1.rel2.fieldName" against M.
private string _resolveTwoLevel(M, JoinFields...)(
    string rel1, string rel2, string fieldName,
    ref _FilterJoin[] fjoins, ref int idx)
{
    string result;

    // Level-1: find rel1 on M (via @related or @many2one — unified through the
    // _pathRelType / _pathFkCol helpers), reusing a hydration (JoinFields) or
    // existing filter join, else creating one.
    static foreach (m1; FieldNameTuple!M) {{
        alias Mem1 = __traits(getMember, M, m1);
        static if (hasUDA!(Mem1, related) || hasMany2OneUDA!Mem1) {
            if (m1 == rel1 && !result.length) {
                alias RelType1 = _pathRelType!(M, m1);
                enum  t1  = ormTableName!RelType1;
                enum  pk1 = ormPkColName!RelType1();
                enum  fk1 = _pathFkCol!(M, m1);

                string a1;
                static foreach (jfIdx, jf; JoinFields) {
                    if (jf == rel1 && !a1.length) a1 = "j" ~ to!string(jfIdx);
                }
                if (!a1.length)
                    foreach (ref fj; fjoins) if (fj.path == rel1) { a1 = fj.alias_; break; }
                if (!a1.length) {
                    a1 = "fj" ~ to!string(idx);
                    fjoins ~= _FilterJoin(rel1, a1, t1, pk1, "_m", fk1);
                    idx++;
                }

                // Level-2: find rel2 on RelType1, chaining off a1.
                static foreach (m2; FieldNameTuple!RelType1) {{
                    alias Mem2 = __traits(getMember, RelType1, m2);
                    static if (hasUDA!(Mem2, related) || hasMany2OneUDA!Mem2) {
                        if (m2 == rel2 && !result.length) {
                            alias RelType2 = _pathRelType!(RelType1, m2);
                            enum  t2  = ormTableName!RelType2;
                            enum  pk2 = ormPkColName!RelType2();
                            enum  fk2 = _pathFkCol!(RelType1, m2);
                            string path2 = rel1 ~ "." ~ rel2;
                            string a2;
                            foreach (ref fj; fjoins) if (fj.path == path2) { a2 = fj.alias_; break; }
                            if (!a2.length) {
                                a2 = "fj" ~ to!string(idx);
                                fjoins ~= _FilterJoin(path2, a2, t2, pk2, a1, fk2);
                                idx++;
                            }
                            result = a2 ~ "." ~ _fieldColNameRuntime!RelType2(fieldName);
                        }
                    }
                }}
            }
        }
    }}

    assert(result.length > 0,
        "Cannot resolve path '" ~ rel1 ~ "." ~ rel2 ~ "." ~ fieldName ~ "' on " ~ M.stringof);
    return result;
}

// Resolve a field path to a SQL column expression, accumulating needed filter joins.
private string _resolvePathToCol(M, JoinFields...)(
    string path, ref _FilterJoin[] fjoins, ref int idx)
{
    auto d1 = indexOf(path, '.');
    if (d1 < 0) {
        return "_m." ~ _fieldColNameRuntime!M(path);
    }
    string rel1 = path[0 .. d1];
    string rest = path[d1 + 1 .. $];
    auto d2 = indexOf(rest, '.');
    if (d2 < 0) {
        return _resolveOneLevel!(M, JoinFields)(rel1, rest, fjoins, idx);
    }
    return _resolveTwoLevel!(M, JoinFields)(rel1, rest[0 .. d2], rest[d2 + 1 .. $], fjoins, idx);
}

// Resolve all PathNodes in a predicate tree; return a new tree with concrete nodes.
private Predicate _resolvePred(M, JoinFields...)(
    Predicate p, ref _FilterJoin[] fjoins, ref int idx)
{
    return p._inner.match!(
        (ref EqNode n)      => p,
        (ref OpNode n)      => p,
        (ref InNode n)      => p,
        (ref NullNode n)    => p,
        (ref RawNode n)     => p,
        (ref LiteralNode n)      => p,
        (ref ExistsNode n)       => p,
        (ref InSubqueryNode n)   => p,
        (ref PathNode n) {
            string colExpr = _resolvePathToCol!(M, JoinFields)(n.path, fjoins, idx);
            if (n.op == "IN_SUB")
                return Predicate(InSubqueryNode(colExpr, n.otherPath, n.params));
            if (n.otherPath.length) {
                string other = _resolvePathToCol!(M, JoinFields)(n.otherPath, fjoins, idx);
                return Predicate(RawNode(colExpr ~ " " ~ n.op ~ " " ~ other, []));
            }
            if (n.op == "IS NULL") return Predicate(NullNode(colExpr));
            if (n.op == "IN")      return Predicate(InNode(colExpr, n.params));
            if (n.op == "=")       return Predicate(EqNode(colExpr, n.params[0]));
            return Predicate(OpNode(colExpr, n.op, n.params[0]));
        },
        (ref AndNode n) {
            auto l = _resolvePred!(M, JoinFields)(*n.left,  fjoins, idx);
            auto r = _resolvePred!(M, JoinFields)(*n.right, fjoins, idx);
            return Predicate(AndNode(new Predicate(l), new Predicate(r)));
        },
        (ref OrNode n) {
            auto l = _resolvePred!(M, JoinFields)(*n.left,  fjoins, idx);
            auto r = _resolvePred!(M, JoinFields)(*n.right, fjoins, idx);
            return Predicate(OrNode(new Predicate(l), new Predicate(r)));
        },
        (ref NotNode n) {
            auto inner = _resolvePred!(M, JoinFields)(*n.inner, fjoins, idx);
            return Predicate(NotNode(new Predicate(inner)));
        },
    );
}

// Build the " DESC"/" NULLS …" suffix for a column/path order term.
private string _orderSuffix(in Ordering ord) {
    string s;
    if (ord.dir == OrderDir.desc) s ~= " DESC";
    final switch (ord.nulls) {
        case OrderNulls.unspecified: break;
        case OrderNulls.first: s ~= " NULLS FIRST"; break;
        case OrderNulls.last:  s ~= " NULLS LAST";  break;
    }
    return s;
}

// Resolve a single Ordering term to a SQL fragment, registering join(s) for
// `path` terms via the same fjoins/idx used by where-predicate resolution.
private string _resolveOrdering(M, JoinFields...)(
    in Ordering ord, ref _FilterJoin[] fjoins, ref int idx)
{
    final switch (ord.kind) {
        case OrderKind.raw:    return ord.expr;
        case OrderKind.column: return ord.expr ~ _orderSuffix(ord);
        case OrderKind.path:
            return _resolvePathToCol!(M, JoinFields)(ord.expr, fjoins, idx) ~ _orderSuffix(ord);
    }
}

// Resolve a list of Ordering terms into a comma-separated ORDER BY body.
// Empty/blank fragments are dropped so a single raw "" term suppresses ordering.
private string _resolveOrderTerms(M, JoinFields...)(
    in Ordering[] terms, ref _FilterJoin[] fjoins, ref int idx)
{
    string result;
    foreach (ref ord; terms) {
        auto frag = _resolveOrdering!(M, JoinFields)(ord, fjoins, idx);
        if (!frag.length) continue;
        if (result.length) result ~= ", ";
        result ~= frag;
    }
    return result;
}

// Compile-time-validated order spec → Ordering. A leading '-' means descending.
// Field references (not raw SQL — use orderBy(string) for raw), validated against
// the model end to end: plain names against M's columns; join paths validate every
// relation segment and the final leaf column on the target model.
private Ordering _ctOrderSpec(M, string spec)() {
    static assert(spec.length > 0, "empty orderBy! spec on " ~ M.stringof);
    enum bool   _desc = spec[0] == '-';
    enum string _name = _desc ? spec[1 .. $] : spec;
    enum OrderDir _dir = _desc ? OrderDir.desc : OrderDir.asc;
    static assert(_name.length > 0,
        "orderBy!(\"" ~ spec ~ "\") has no field name after '-'");
    static assert(indexOf(_name, ' ') < 0,
        "orderBy!(\"" ~ spec ~ "\") must be a bare field name or join path (no spaces"
        ~ " or SQL). Use orderBy(\"...\") for raw SQL.");
    static if (indexOf(_name, '.') >= 0) {
        static assert(_assertOrderPath!(M, spec, _name));
        return Ordering(OrderKind.path, _name, _dir);
    } else {
        enum _col = _fieldColName!(M, _name)();
        static assert(_col.length > 0,
            "'" ~ _name ~ "' in orderBy!(\"" ~ spec ~ "\") is not a DB column field on "
            ~ M.stringof);
        return Ordering(OrderKind.column, "_m." ~ _col, _dir);
    }
}

// Validate a 1- or 2-level join path (e.g. "partner.name" / "partner.company.rate")
// against M: each relation segment must be a @related/@many2one field, and the leaf
// must be a DB column on the target model. `spec` is the original token (with any
// leading '-') used only for the diagnostic message.
private template _assertOrderPath(M, string spec, string path) {
    enum   _d1   = indexOf(path, '.');
    enum   _rel1 = path[0 .. _d1];
    enum   _rest = path[_d1 + 1 .. $];
    static assert(_isKnownRelField!M(_rel1),
        "'" ~ _rel1 ~ "' in orderBy!(\"" ~ spec ~ "\") is not a @related/@many2one field on "
        ~ M.stringof);
    alias _Rel1 = _pathRelType!(M, _rel1);
    enum   _d2 = indexOf(_rest, '.');
    static if (_d2 < 0) {
        static assert(_fieldColName!(_Rel1, _rest)().length > 0,
            "'" ~ _rest ~ "' in orderBy!(\"" ~ spec ~ "\") is not a DB column field on "
            ~ _Rel1.stringof);
    } else {
        enum _rel2 = _rest[0 .. _d2];
        enum _leaf = _rest[_d2 + 1 .. $];
        static assert(_isKnownRelField!_Rel1(_rel2),
            "'" ~ _rel2 ~ "' in orderBy!(\"" ~ spec ~ "\") is not a @related/@many2one field on "
            ~ _Rel1.stringof);
        alias _Rel2 = _pathRelType!(_Rel1, _rel2);
        static assert(_fieldColName!(_Rel2, _leaf)().length > 0,
            "'" ~ _leaf ~ "' in orderBy!(\"" ~ spec ~ "\") is not a DB column field on "
            ~ _Rel2.stringof);
    }
    enum bool _assertOrderPath = true;
}

// Build JOIN SQL fragment from a _FilterJoin[].
private string _filterJoinSQL(ref _FilterJoin[] fjoins) {
    string s;
    foreach (ref fj; fjoins)
        s ~= " LEFT JOIN " ~ fj.table ~ " " ~ fj.alias_ ~
             " ON " ~ fj.alias_ ~ "." ~ fj.pkCol ~ " = " ~ fj.parentAlias ~ "." ~ fj.fkCol;
    return s;
}

// ---------------------------------------------------------------------------
// CTFE helpers for select!DTO implicit join inference
// ---------------------------------------------------------------------------

// Returns true at compile time if colName is a DB column on M.
private bool _isMainColCTFE(M, string colName)() {
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (_colName!(F, memberName) == colName)
                return true;
        }
    }}
    return false;
}

// Returns a list of @related member names on M that are needed to satisfy DTO fields.
// Called in CTFE context via enum.
private string[] _neededRelsCTFE(M, DTO)() {
    import peque.model: related;
    import peque.hydration: camelToSnake;

    string[] mainCols;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F)
            mainCols ~= _colName!(F, memberName);
    }}

    string[] needed;
    static foreach (dtoMemberName; FieldNameTuple!DTO) {{
        enum dtoColName = camelToSnake(dtoMemberName);
        bool isMain = false;
        foreach (c; mainCols) if (c == dtoColName) { isMain = true; break; }
        if (!isMain) {
            static foreach (relMemberName; FieldNameTuple!M) {{
                alias RelMem = __traits(getMember, M, relMemberName);
                static if (hasUDA!(RelMem, related)) {
                    enum relSnake  = camelToSnake(relMemberName);
                    enum relPrefix = relSnake ~ "_";
                    static if (dtoColName.length > relPrefix.length &&
                               dtoColName[0 .. relPrefix.length] == relPrefix) {
                        bool found = false;
                        foreach (n; needed) if (n == relMemberName) { found = true; break; }
                        if (!found) needed ~= relMemberName;
                    }
                }
            }}
        }
    }}
    return needed;
}


private struct _QSSet {
    string  colName;
    PGValue value;
}


// ---------------------------------------------------------------------------
// QuerySet
// ---------------------------------------------------------------------------

/** Lazy, composable query builder for model M.
  *
  * JoinFields is a compile-time sequence of D field names (strings) that have
  * been added via .joinOne!(fieldName).  The type expands when joinOne! is
  * called, producing a new QuerySet type.
  *
  * Obtain one from a repository via .query():
  * ---
  * auto rows = repo.query()
  *                 .where("active = $1", true)
  *                 .orderBy("name ASC")
  *                 .limit(20)
  *                 .all();
  * ---
  **/
struct QuerySet(M, Ctx, JoinFields...)
if (isModel!M && isQueryContext!Ctx) {

    alias PrefetchFn = void delegate(ref M[], Ctx*);

    private Ctx*         _ctx;
    private Predicate[]  _wheres;
    private _QSSet[]     _sets;
    private Ordering[]   _orderByTerms;
    private long         _limitVal  = -1;
    private long         _offsetVal = -1;
    private PrefetchFn[] _prefetches;

    // Public because D instantiates template bodies at the call site, which
    // may be outside peque.orm — package(peque.orm) would fail there.
    this(Ctx* ctx) { _ctx = ctx; }

    // -----------------------------------------------------------------------
    // Builder methods — each returns a copy, leaving this unchanged
    // -----------------------------------------------------------------------

    /** Type-safe equality filter — field name validated at compile time.
      *
      * The column expression uses the "_m." table alias, which is always
      * present in the generated SQL (both plain and join paths).
      *
      * Example:
      * ---
      * repo.query().where!"active"(true).all()
      * repo.query().where!"status"("active").where!"score"(10).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) where(string fieldName, V)(V val) {
        return where(F!(M, fieldName)(val));
    }

    /** Type-safe IN filter — field name validated at compile time.
      *
      * Passing an empty slice is equivalent to calling .none() — the query
      * will match no rows (SQL: WHERE FALSE).
      *
      * Example:
      * ---
      * repo.query().whereIn!"status"(["active", "pending"]).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) whereIn(string fieldName, V)(V[] vals) {
        return where(F!(M, fieldName).contains(vals));
    }

    /** Return a QuerySet that matches no rows — SQL: WHERE FALSE.
      *
      * Useful as a safe default when an access-control rule produces an
      * empty allowed-ID set: start from .none() and OR in permitted predicates
      * rather than testing for an empty collection at every call site.
      *
      * Example:
      * ---
      * auto qs = allowedIds.empty ? repo.query().none()
      *                            : repo.query().whereIn!"id"(allowedIds);
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) none() {
        return where(Predicate.none);
    }

    /** Composable predicate filter — supports OR, AND, NOT via F expressions.
      *
      * Example:
      * ---
      * repo.query().where(
      *     F!(Item, "status")("active") | F!(Item, "status")("pending")
      * ).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) where(Predicate pred) {
        auto qs = this;
        qs._wheres ~= pred;
        return qs;
    }

    /** Raw SQL escape hatch — use when typed predicates don't cover the case
      * (date ranges, full-text search, subqueries, etc.).
      *
      * sqlFrag uses local $1/$2/… numbering — placeholders are renumbered
      * relative to prior filters at SQL build time.
      *
      * Security: sqlFrag is embedded in the query verbatim — never pass
      * user-controlled input as sqlFrag.  All runtime values must go through
      * the variadic args, which are bound as PostgreSQL parameters ($N).
      *
      * Example:
      * ---
      * qs.whereRaw("expires_at < $1", cutoff)
      * qs.whereRaw("tsv @@ to_tsquery($1)", query)
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) whereRaw(T...)(string sqlFrag, T args) {
        PGValue[] pgParams;
        static foreach (i, _; T)
            pgParams ~= convertToPG(args[i]);
        return where(Predicate(RawNode(sqlFrag, pgParams)));
    }

    // There are two `orderBy` overloads, disambiguated by HOW they are called,
    // not by a template constraint:
    //  - the RUNTIME form below, `orderBy(values…)`, takes ordinary call
    //    arguments and matches `orderBy(F!"x".desc)`, `orderBy("raw")`, etc.
    //  - the COMPILE-TIME form, `orderBy!("field"…)`, takes explicit template
    //    value arguments and no runtime arguments.
    // `orderBy!("x")` cannot bind the runtime overload (a string value can't be
    // used where a type parameter is expected), and `orderBy("x")` cannot bind
    // the compile-time overload (it has no runtime parameter to receive the
    // argument), so each call form resolves to exactly one overload.

    /** Override the ORDER BY clause with one or more terms.
      *
      * Each argument is one of:
      *  - a raw SQL `string` — passed through verbatim (escape hatch);
      *  - an `F` builder — `F!"field"` / `F!"partner.name"` (ascending), or
      *    `.desc`, optionally chained `.nullsFirst`/`.nullsLast`;
      *  - an `Ordering` value.
      *
      * Field references via `F` are resolved against the model (camelCase →
      * column, implicit LEFT JOINs for join paths). Raw strings are NOT parsed
      * or resolved — they are emitted as-is.
      *
      * Pass a single `""` to suppress all ordering (overrides @defaultOrder).
      *
      * Security: a raw `string` is embedded verbatim — never pass
      * user-controlled input. For compile-time-validated field ordering see the
      * `orderBy!("field", "-other")` form below.
      *
      * ---
      * repo.query().orderBy(F!"createdAt".desc, F!"name")
      * repo.query().orderBy("priority DESC NULLS LAST")        // raw
      * repo.query().orderBy(F!"partner.name")                  // join path
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) orderBy(Specs...)(Specs specs)
    if (Specs.length >= 1) {
        auto qs = this;
        qs._orderByTerms = [];
        static foreach (i; 0 .. Specs.length)
            qs._orderByTerms ~= toOrdering(specs[i]);
        return qs;
    }

    /** Compile-time-validated ORDER BY by field name(s).
      *
      * Each spec is a model field name (or join path), validated against M at
      * compile time. A leading `-` means descending (Django-style):
      * ---
      * repo.query().orderBy!("createdAt")          // ASC, validated
      * repo.query().orderBy!("-createdAt", "name")  // createdAt DESC, name ASC
      * repo.query().orderBy!("partner.name")        // join path, fully validated
      * ---
      * For raw SQL or NULLS placement, use the runtime `orderBy(...)` form.
      **/
    QuerySet!(M, Ctx, JoinFields) orderBy(specs...)()
    if (specs.length >= 1) {
        static foreach (s; specs)
            static assert(is(typeof(s) == string),
                "orderBy!(...) takes field-name string literals (e.g. \"-createdAt\")."
                ~ " For F! terms or Ordering values use the runtime orderBy(...) form.");
        auto qs = this;
        qs._orderByTerms = [];
        static foreach (s; specs)
            qs._orderByTerms ~= _ctOrderSpec!(M, s);
        return qs;
    }

    /// Set a row limit.
    QuerySet!(M, Ctx, JoinFields) limit(long n) {
        auto qs = this;
        qs._limitVal = n;
        return qs;
    }

    /// Set a row offset.
    QuerySet!(M, Ctx, JoinFields) offset(long n) {
        auto qs = this;
        qs._offsetVal = n;
        return qs;
    }

    /** Accumulate a SET assignment for a partial / bulk UPDATE.
      *
      * fieldName must be a DB-column field on M (checked at compile time).
      * Call .update() after one or more .set!() calls to execute the UPDATE.
      *
      * Example:
      * ---
      * repo.query().where("id=$1", id).set!("name")("New name").update();
      * repo.query().where("active=$1", false).set!("active")(true).update();
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) set(string fieldName, V)(V value) {
        enum colName = _fieldColName!(M, fieldName)();
        static assert(colName.length > 0,
            "'" ~ fieldName ~ "' is not a DB column field on " ~ M.stringof);
        auto qs = this;
        qs._sets ~= _QSSet(colName, convertToPG(value));
        return qs;
    }

    /** Explicitly join a @related field and hydrate it in the result.
      *
      * Alias for joinOne! — preferred in application code.
      * Adds a LEFT JOIN and populates the @related field in each result struct.
      *
      * Example:
      * ---
      * repo.query().load!("partner").load!("invoiceAddress").all();
      * ---
      **/
    auto load(string relField)() { return joinOne!relField(); }

    /** Add a LEFT JOIN for a @related field backed by a @many2one FK.
      *
      * Returns a new QuerySet type with relField appended to JoinFields.
      *
      * Example:
      * ---
      * // Partner has @many2one!(Company) int companyId; and
      * //            @related Nullable!Company company;
      * repo.query().joinOne!("company").all();
      * ---
      **/
    auto joinOne(string relField)() {
        // Compile-time validation
        static assert(__traits(hasMember, M, relField),
            "'" ~ relField ~ "' is not a member of " ~ M.stringof);
        alias RelFieldDecl = __traits(getMember, M, relField);
        static assert(hasUDA!(RelFieldDecl, related),
            "'" ~ relField ~ "' on " ~ M.stringof ~ " does not have @related UDA");

        alias RelType = _innerRelType!(M, relField);
        enum fkCol = _fkColForRelatedField!(M, relField, RelType)();
        static assert(fkCol.length > 0,
            "No @many2one!(" ~ RelType.stringof ~ ") FK field found on " ~ M.stringof ~
            " for @related field '" ~ relField ~ "'." ~
            " If you have multiple FKs to the same type, add @related(\"fkFieldName\").");

        QuerySet!(M, Ctx, JoinFields, relField) qs2;
        qs2._ctx            = _ctx;
        qs2._wheres         = _wheres;
        qs2._sets           = _sets;
        qs2._orderByTerms   = _orderByTerms;
        qs2._limitVal       = _limitVal;
        qs2._offsetVal      = _offsetVal;
        qs2._prefetches     = _prefetches;
        return qs2;
    }

    /** Schedule a post-query prefetch for a @one2many or @many2many field.
      *
      * Returns the same QuerySet type (JoinFields unchanged).
      *
      * Example:
      * ---
      * partnerRepo.query().prefetch!("invoices").all();
      * partnerRepo.query().prefetch!("tags").all();
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) prefetch(string relField)() {
        alias RelFieldDecl = __traits(getMember, M, relField);

        // Validate: must have @one2many or @many2many
        enum bool _hasO2M = () {
            bool found = false;
            static foreach (uda; __traits(getAttributes, RelFieldDecl)) {{
                static if (is(uda) && is(uda == one2many!(T, inv), T, string inv))
                    found = true;
            }}
            return found;
        }();
        enum bool _hasM2M = () {
            bool found = false;
            static foreach (uda; __traits(getAttributes, RelFieldDecl)) {{
                static if (is(uda) && is(uda == many2many!(T, jt, sk, tk), T, string jt, string sk, string tk))
                    found = true;
            }}
            return found;
        }();
        static assert(_hasO2M || _hasM2M,
            "'" ~ relField ~ "' on " ~ M.stringof ~
            " does not have @one2many or @many2many UDA");

        auto qs = this;
        qs._prefetches ~= (ref M[] rows, Ctx* ctx) {
            _execPrefetch!(M, Ctx, relField)(rows, ctx);
        };
        return qs;
    }

    /** Group by one or more main-table fields — names validated at compile
      * time.  Returns a GroupedQuerySet, which exposes annotate!/having/
      * where/orderBy/limit/offset and a single terminal: the grouped
      * select!DTO().  Row-returning terminals (all, first, update, delete_,
      * asSubquery, …) do not exist on the grouped type.
      *
      * Restrictions: group keys must be DB-column fields of M (no join paths).
      * joinOne!/load! must be applied before groupBy!.
      *
      * ---
      * @autoHydrate
      * struct TotalsDTO { int orderId; long invoiceCount; double totalAmount; }
      *
      * auto totals = invoiceRepo.query()
      *     .where!"status"("open")
      *     .groupBy!"orderId"
      *     .annotate!("invoiceCount", F!(Invoice, "id").count)
      *     .annotate!("totalAmount",  F!(Invoice, "amount").sum)
      *     .having(F!(Invoice, "amount").sum.gt(100.0))
      *     .select!TotalsDTO();
      * ---
      **/
    auto groupBy(groupFields...)()
    if (groupFields.length >= 1) {
        static foreach (gf; groupFields) {
            static if (!is(typeof(gf) == string)) {
                static assert(false,
                    "groupBy! takes field-name string literals, e.g. groupBy!(\"orderId\")");
            } else {
                static assert(_fieldColName!(M, gf)().length > 0,
                    "'" ~ gf ~ "' in groupBy! is not a DB column field on " ~ M.stringof ~
                    " (must have @field, @primaryKey, or @many2one UDA)");
            }
        }
        return GroupedQuerySet!(typeof(this), groupFields)(this);
    }

    // -----------------------------------------------------------------------
    // Internal — accumulate renumbered WHERE SQL and flat PGValue[].
    // -----------------------------------------------------------------------

    private static void _buildWhereFromArray(
            Predicate[] preds, out string whereSQL, out PGValue[] params,
            int startOffset = 0, string clause = " WHERE ") {
        whereSQL = "";
        params   = [];
        if (preds.length == 0) return;
        whereSQL = clause;
        int offset = startOffset;
        foreach (i, ref p; preds) {
            auto s = serializePredicate(p, offset);
            if (i > 0) whereSQL ~= " AND ";
            whereSQL ~= "(" ~ s.sql ~ ")";
            offset += cast(int)s.params.length;
            params ~= s.params;
        }
    }

    private void _buildWhere(out string whereSQL, out PGValue[] params, int startOffset = 0) {
        _buildWhereFromArray(_wheres, whereSQL, params, startOffset);
    }

    // Resolve the effective ORDER BY body — explicit terms if set, otherwise the
    // model's @defaultOrder — registering any LEFT JOIN a join-path term needs
    // into fjoins/idx. Returns "" when there is nothing to order by. Shared by
    // all() and select!DTO so the two paths cannot diverge.
    private string _resolveOrderBySql(ref _FilterJoin[] fjoins, ref int idx) {
        enum Ordering[] _defTerms = _modelDefaultOrder!M;
        Ordering[] terms = _orderByTerms.length ? _orderByTerms : _defTerms;
        return _resolveOrderTerms!(M, JoinFields)(terms, fjoins, idx);
    }

    // -----------------------------------------------------------------------
    // Terminal methods
    // -----------------------------------------------------------------------

    /** Fetch all matching rows, applying any JoinFields LEFT JOINs and
      * any scheduled prefetches afterwards.
      **/
    M[] all() {
        import peque.hydration: _hydrateAnnotated;

        // Resolve path predicates, collect filter joins
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // Resolve orderBy terms (may add more filter joins)
        string orderBySql = _resolveOrderBySql(fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        // Build SELECT — main model columns (always prefixed with _m.)
        enum _mainSel = _prefixedSelectList!(M, "_m")();
        string sql = "SELECT " ~ _mainSel;

        // Append aliased columns for each hydration join
        static if (JoinFields.length > 0) {
            string joinExtras;
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias = "j" ~ to!string(idx);
                enum _prefix = "__" ~ jf ~ "_";
                enum _extras = _joinSelectExtras!(RelType, _jAlias, _prefix)();
                if (joinExtras.length) joinExtras ~= ", ";
                joinExtras ~= _extras;
            }}
            if (joinExtras.length) sql ~= ", " ~ joinExtras;
        }

        sql ~= " FROM " ~ ormTableName!M ~ " _m";

        // Append LEFT JOINs for hydration joins
        static if (JoinFields.length > 0) {
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias = "j" ~ to!string(idx);
                enum _relTbl = ormTableName!RelType;
                enum _relPk  = ormPkColName!RelType();
                enum _fkCol  = _fkColForRelatedField!(M, jf, RelType)();
                static assert(_fkCol.length > 0,
                    "No @many2one!(" ~ RelType.stringof ~ ") field found on " ~ M.stringof);
                sql ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _jAlias ~
                       " ON " ~ _jAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
            }}
        }

        sql ~= _filterJoinSQL(fjoins);
        sql ~= whereSQL;
        if (orderBySql.length) sql ~= " ORDER BY " ~ orderBySql;
        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        static if (JoinFields.length == 0) {
            // No hydration joins — Result.as handles bulk hydration
            auto rows = _ctx.execParams(sql, params).as!(M[]);
            foreach (fn; _prefetches) fn(rows, _ctx);
            return rows;
        } else {
            // Hydration joins — manual loop to fill joined fields after hydration
            auto result = _ctx.execParams(sql, params);
            M[] rows;
            rows.length = result.ntuples;
            foreach (ri; 0 .. result.ntuples) {
                auto row = result.getRow(ri);
                rows[ri] = _hydrateAnnotated!M(row);
                static foreach (idx, jf; JoinFields) {{
                    alias RelType    = _innerRelType!(M, jf);
                    enum _prefix     = "__" ~ jf ~ "_";
                    enum _pkPrefCol  = _prefix ~ ormPkColName!RelType();
                    immutable pkIdx  = row._fieldIndex(_pkPrefCol);
                    if (pkIdx >= 0 && !row[pkIdx].isNull) {
                        auto rel = _hydrateAnnotated!(RelType, _prefix)(row);
                        alias FT = typeof(__traits(getMember, rows[ri], jf));
                        static if (is(FT == Nullable!RelType))
                            __traits(getMember, rows[ri], jf) = rel.nullable;
                        else
                            __traits(getMember, rows[ri], jf) = rel;
                    }
                }}
            }
            foreach (fn; _prefetches) fn(rows, _ctx);
            return rows;
        }
    }

    /** Fetch the first matching row, or Nullable.init if none. **/
    Nullable!M first() {
        auto results = limit(1).all();
        if (results.length == 0) return Nullable!M.init;
        return results[0].nullable;
    }

    /** Return the number of matching rows (SELECT COUNT(*)). **/
    long count() {
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        string sql = "SELECT COUNT(*) FROM " ~ ormTableName!M ~ " _m";
        sql ~= _filterJoinSQL(fjoins);
        sql ~= whereSQL;
        return _ctx.execParams(sql, params).getValue!long(0, 0);
    }

    /** Compute a single aggregate value over all matching rows.
      *
      * agg is an aggregate builder produced by the typed field form:
      * F!(M, "field").sum / .avg / .min / .max / .count.
      *
      * Returns Nullable!(result type): SUM/AVG/MIN/MAX over zero rows is SQL
      * NULL, which maps to .isNull.  Result types: sum → long (integral
      * fields) or double (floating), avg → double, min/max → the field's own
      * D type, count → long.
      *
      * Like count(), ignores orderBy/limit/offset — the aggregate always runs
      * over the full match set.
      *
      * ---
      * // SELECT SUM(_m.amount) FROM invoices _m WHERE (_m.active = $1)
      * Nullable!double total = repo.query()
      *     .where!"active"(true)
      *     .aggregate!(F!(Invoice, "amount").sum);
      *
      * auto latest = repo.query().aggregate!(F!(Invoice, "createdAt").max);
      * ---
      **/
    auto aggregate(aggSpec...)()
    if (aggSpec.length == 1 && isAggBuilder!(typeof(aggSpec[0]))) {
        alias AggT = typeof(aggSpec[0]);

        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        string sql = "SELECT " ~ AggT.expr ~ " FROM " ~ ormTableName!M ~ " _m";
        sql ~= _filterJoinSQL(fjoins);
        sql ~= whereSQL;
        return _ctx.execParams(sql, params)
                   .getValue!(Nullable!(AggT.ResultType))(0, 0);
    }

    /** Return true if at least one matching row exists. **/
    bool exists() {
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        string sql = "SELECT 1 FROM " ~ ormTableName!M ~ " _m";
        sql ~= _filterJoinSQL(fjoins);
        sql ~= whereSQL ~ " LIMIT 1";
        return _ctx.execParams(sql, params).ntuples > 0;
    }

    /** Capture this QuerySet as a single-column SQL subquery atom.
      *
      * No database call is made.  Returns a SubQuery!T carrying:
      *   SELECT _m.colname FROM table _m [WHERE ...] [LIMIT ...] [OFFSET ...]
      *
      * fieldName must be a DB column field on M (compile-time check).
      * T is the D type of that field, inferred at compile time.
      *
      * Pass the result to F!(M, "f").inSubquery(sub) or F!"f".inSubquery(sub)
      * to embed it as col IN (SELECT ...) in another QuerySet's WHERE clause.
      *
      * Example:
      * ---
      * auto activeCatIds = catRepo.query()
      *     .where!"active"(true)
      *     .asSubquery!"id"();
      *
      * auto products = prodRepo.query()
      *     .where(F!(Product, "categoryId").inSubquery(activeCatIds))
      *     .all();
      * ---
      **/
    auto asSubquery(string fieldName)() {
        enum _col = _fieldColName!(M, fieldName)();
        static assert(_col.length > 0,
            "'" ~ fieldName ~ "' is not a DB column field on " ~ M.stringof);
        alias _FieldType = typeof(__traits(getMember, M.init, fieldName));

        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        string sql = "SELECT _m." ~ _col ~ " FROM " ~ ormTableName!M ~ " _m";
        sql ~= _filterJoinSQL(fjoins);
        sql ~= whereSQL;
        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        return SubQuery!_FieldType(sql, params);
    }

    /** Delete all matching rows and return the number of rows deleted.
      *
      * When filter joins are required (F!"rel.field" in WHERE), PostgreSQL's
      * USING clause is used with join conditions added to the WHERE clause.
      **/
    long delete_() {
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // If filter joins required, add their ON conditions to WHERE
        Predicate[] allPreds = resolved.dup;
        foreach (ref fj; fjoins)
            allPreds ~= Predicate(RawNode(
                fj.alias_ ~ "." ~ fj.pkCol ~ " = " ~ fj.parentAlias ~ "." ~ fj.fkCol, []));

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(allPreds, whereSQL, params);

        string sql;
        if (fjoins.length > 0) {
            sql = "DELETE FROM " ~ ormTableName!M ~ " _m USING";
            foreach (i, ref fj; fjoins) {
                if (i > 0) sql ~= ",";
                sql ~= " " ~ fj.table ~ " " ~ fj.alias_;
            }
        } else {
            sql = "DELETE FROM " ~ ormTableName!M ~ " _m";
        }
        sql ~= whereSQL;
        return _ctx.execParams(sql, params).cmdTuples();
    }

    /** Execute a partial / bulk UPDATE using accumulated set!() assignments.
      *
      * Builds: UPDATE table SET col1=$1, col2=$2 [FROM joins] WHERE (renumbered_where)
      * Set values are bound as $1..$N; WHERE params follow as $(N+1)..$(N+M).
      *
      * Returns the number of rows updated.
      *
      * Example:
      * ---
      * repo.query().where("id=$1", id).set!("name")("New").update();
      * ---
      **/
    long update() {
        enforce!PequeException(_sets.length > 0, "update() called with no set!() assignments");

        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // Include join ON conditions in WHERE for filter joins
        Predicate[] allPreds = resolved.dup;
        foreach (ref fj; fjoins)
            allPreds ~= Predicate(RawNode(
                fj.alias_ ~ "." ~ fj.pkCol ~ " = " ~ fj.parentAlias ~ "." ~ fj.fkCol, []));

        // Build SET clause: col1=$1, col2=$2, ...
        string setClause;
        PGValue[] setParams;
        foreach (i, ref s; _sets) {
            if (i > 0) setClause ~= ", ";
            setClause ~= s.colName ~ " = $" ~ to!string(i + 1);
            setParams ~= s.value;
        }

        string whereSQL;
        PGValue[] whereParams;
        _buildWhereFromArray(allPreds, whereSQL, whereParams, cast(int)_sets.length);

        string sql = "UPDATE " ~ ormTableName!M ~ " _m SET " ~ setClause;
        if (fjoins.length > 0) {
            sql ~= " FROM";
            foreach (i, ref fj; fjoins) {
                if (i > 0) sql ~= ",";
                sql ~= " " ~ fj.table ~ " " ~ fj.alias_;
            }
        }
        sql ~= whereSQL;

        return _ctx.execParams(sql, setParams ~ whereParams).cmdTuples();
    }

    /** Project matching rows into DTO[].
      *
      * DTO fields are matched against:
      *  1. Main-table columns (_m.col)
      *  2. Explicit JoinFields (j0.col AS prefix_col)
      *  3. Implicit @related joins inferred from DTO field names
      *     (partnerName → "partner_" prefix → LEFT JOIN cq_partners dj0)
      *  4. Runtime filter joins from WHERE path predicates (fj0, fj1, …)
      *
      * Example:
      * ---
      * @autoHydrate
      * struct PartnerDTO { int id; string name; string companyName; }
      * // Explicit join:
      * auto dtos = repo.query().load!("company").select!PartnerDTO();
      * // Fully implicit (companyName → company_ prefix):
      * auto dtos = repo.query().select!PartnerDTO();
      * ---
      **/
    DTO[] select(DTO)() {
        import peque.hydration: camelToSnake, _hydrateAnnotated;

        // Resolve path predicates, collect filter joins
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // Resolve orderBy terms now — before filter joins are emitted below —
        // so any join a `path` term needs is included in the FROM clause.
        string orderBySql = _resolveOrderBySql(fjoins, fjIdx);

        // Compute implicit DTO-driven relation names at compile time
        enum neededRelNames = _neededRelsCTFE!(M, DTO)();
        enum nRels = neededRelNames.length;

        // Build SELECT list
        string selList;
        static foreach (i, dtoMemberName; FieldNameTuple!DTO) {{
            enum dtoColName = camelToSnake(dtoMemberName);
            if (selList.length) selList ~= ", ";

            static if (_isMainColCTFE!(M, dtoColName)()) {
                selList ~= "_m." ~ dtoColName;
            } else {
                bool matched = false;

                // Check explicit JoinFields
                static foreach (jfIdx2, jf; JoinFields) {{
                    if (!matched) {
                        enum jfSnake  = camelToSnake(jf);
                        enum jfPrefix = jfSnake ~ "_";
                        static if (dtoColName.length > jfPrefix.length &&
                                   dtoColName[0 .. jfPrefix.length] == jfPrefix) {
                            selList ~= "j" ~ to!string(jfIdx2) ~ "." ~
                                       dtoColName[jfPrefix.length .. $] ~ " AS " ~ dtoColName;
                            matched = true;
                        }
                    }
                }}

                // Check implicit DTO joins (dj0, dj1, …)
                static foreach (ni; 0 .. nRels) {{
                    if (!matched) {
                        enum rn       = neededRelNames[ni];
                        enum rnSnake  = camelToSnake(rn);
                        enum rnPrefix = rnSnake ~ "_";
                        static if (dtoColName.length > rnPrefix.length &&
                                   dtoColName[0 .. rnPrefix.length] == rnPrefix) {
                            selList ~= "dj" ~ to!string(ni) ~ "." ~
                                       dtoColName[rnPrefix.length .. $] ~ " AS " ~ dtoColName;
                            matched = true;
                        }
                    }
                }}

                if (!matched) selList ~= dtoColName; // fallback
            }
        }}

        // Build FROM + explicit JoinField JOINs
        string fromClause = " FROM " ~ ormTableName!M ~ " _m";
        static foreach (jfIdx2, jf; JoinFields) {{
            alias RelType = _innerRelType!(M, jf);
            enum _jAlias = "j" ~ to!string(jfIdx2);
            enum _relTbl = ormTableName!RelType;
            enum _relPk  = ormPkColName!RelType();
            enum _fkCol  = _fkColForRelatedField!(M, jf, RelType)();
            fromClause ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _jAlias ~
                          " ON " ~ _jAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
        }}

        // Implicit DTO joins (dj0, dj1, …)
        static foreach (ni; 0 .. nRels) {{
            enum rn = neededRelNames[ni];
            static foreach (memberName; FieldNameTuple!M) {{
                alias Mem = __traits(getMember, M, memberName);
                static if (hasUDA!(Mem, related)) {
                    static if (memberName == rn) {
                        alias RelType = _innerRelType!(M, memberName);
                        enum _djAlias = "dj" ~ to!string(ni);
                        enum _relTbl  = ormTableName!RelType;
                        enum _relPk   = ormPkColName!RelType();
                        enum _fkCol   = _fkColForRelatedField!(M, memberName, RelType)();
                        fromClause ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _djAlias ~
                                      " ON " ~ _djAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
                    }
                }
            }}
        }}

        // Runtime filter joins from WHERE predicates
        fromClause ~= _filterJoinSQL(fjoins);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        string sql = "SELECT " ~ selList ~ fromClause ~ whereSQL;

        if (orderBySql.length) sql ~= " ORDER BY " ~ orderBySql;

        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        return _ctx.execParams(sql, params).as!(DTO[]);
    }
}


// ---------------------------------------------------------------------------
// GroupedQuerySet — GROUP BY / HAVING / aggregate projection
// ---------------------------------------------------------------------------

/** Annotation marker pairing a SELECT alias with an aggregate builder or a
  * raw SQL expression.  Appears only in GroupedQuerySet type parameters —
  * never constructed at runtime.  Produced by GroupedQuerySet.annotate!.
  **/
struct Annot(string name, string expr) {
    enum _name = name;   // DTO member name the annotation populates
    enum _expr = expr;   // SQL expression, e.g. "SUM(_m.amount)"
}


/** GROUP BY query wrapper produced by QuerySet.groupBy!(...).
  *
  * Specs is a compile-time mix of:
  *  - string values      — group-key field names (accumulated by groupBy!)
  *  - Annot!(name, spec) — aggregate/raw SELECT annotations (annotate!)
  *
  * Builders: annotate!, having, where, whereRaw, orderBy, limit, offset.
  * The only terminal is the grouped select!DTO() — every DTO member must be
  * either a group key or an annotation alias (validated at compile time), so
  * PostgreSQL's "column must appear in the GROUP BY clause" error is caught
  * at build time.
  *
  * ---
  * @autoHydrate
  * struct TotalsDTO { int orderId; long invoiceCount; double totalAmount; }
  *
  * auto totals = invoiceRepo.query()
  *     .where!"status"("open")
  *     .groupBy!"orderId"
  *     .annotate!("invoiceCount", F!(Invoice, "id").count)
  *     .annotate!("totalAmount",  F!(Invoice, "amount").sum)
  *     .having(F!(Invoice, "amount").sum.gt(100.0))
  *     .orderBy(F!(Invoice, "amount").sum.desc)
  *     .select!TotalsDTO();
  * // SELECT _m.order_id AS order_id, COUNT(_m.id) AS invoice_count,
  * //        SUM(_m.amount) AS total_amount
  * // FROM invoices _m WHERE (_m.status = $1)
  * // GROUP BY _m.order_id HAVING (SUM(_m.amount) > $2)
  * // ORDER BY SUM(_m.amount) DESC
  * ---
  **/
struct GroupedQuerySet(QS, Specs...)
if (is(QS == QuerySet!Args, Args...)) {

    static if (is(QS == QuerySet!Args, Args...)) {
        private alias M          = Args[0];
        private alias Ctx        = Args[1];
        private alias JoinFields = Args[2 .. $];
    }

    private QS          _base;      // the QuerySet as of the groupBy! call
    private Predicate[] _havings;

    // Public for the same reason as QuerySet's constructor: template bodies
    // are instantiated at the call site, which may be outside peque.orm.
    this(QS base) { _base = base; }

    // -----------------------------------------------------------------------
    // Builder methods — each returns a copy, leaving this unchanged
    // -----------------------------------------------------------------------

    /** Register an aggregate annotation under a SELECT alias.
      *
      * spec is either:
      *  - a typed aggregate builder:
      *    annotate!("totalAmount", F!(Invoice, "amount").sum)
      *  - a raw SQL expression (compile-time string literal):
      *    annotate!("amountSpread", "MAX(_m.amount) - MIN(_m.amount)")
      *
      * The alias must equal the DTO member name it should populate in
      * select!DTO (the SQL column alias is derived via camelToSnake for
      * hydration).  Annotations not referenced by the DTO are not emitted.
      *
      * Security: a raw expression is embedded in the query verbatim — only
      * trusted, hardcoded strings.  Bound parameters ($N) are not supported
      * inside annotation expressions; runtime values belong in where()/
      * having().
      *
      * Returns a new GroupedQuerySet type with the annotation appended.
      **/
    auto annotate(string name, spec...)()
    if (spec.length == 1 &&
        (isAggBuilder!(typeof(spec[0])) || is(typeof(spec[0]) == string))) {
        static if (is(typeof(spec[0]) == string))
            enum expr = spec[0];                 // raw SQL expression (trusted)
        else
            enum expr = typeof(spec[0]).expr;    // AggBuilder
        auto g2 = GroupedQuerySet!(QS, Specs, Annot!(name, expr))(_base);
        g2._havings = _havings;
        return g2;
    }

    /** HAVING predicate — filters groups after aggregation.
      *
      * Build conditions from aggregate builders' comparison operators; they
      * compose with &, | and ~ like any Predicate:
      * ---
      * .having(F!(Invoice, "amount").sum.gt(100.0))
      * .having(F!(Invoice, "id").count.gte(2) | F!(Invoice, "amount").avg.lt(50.0))
      * ---
      **/
    typeof(this) having(Predicate pred) {
        auto g = this;
        g._havings ~= pred;
        return g;
    }

    /// Type-safe equality WHERE — applied before grouping (delegates to the base QuerySet).
    typeof(this) where(string fieldName, V)(V val) {
        auto g = this;
        g._base = _base.where!(fieldName)(val);
        return g;
    }

    /// Composable predicate WHERE — applied before grouping.
    typeof(this) where(Predicate pred) {
        auto g = this;
        g._base = _base.where(pred);
        return g;
    }

    /// Raw SQL WHERE escape hatch — applied before grouping (see QuerySet.whereRaw).
    typeof(this) whereRaw(T...)(string sqlFrag, T args) {
        auto g = this;
        g._base = _base.whereRaw(sqlFrag, args);
        return g;
    }

    /** ORDER BY — accepts the same terms as QuerySet.orderBy (raw strings,
      * F builders, Ordering values) plus aggregate builders' .asc/.desc:
      * ---
      * .orderBy(F!(Invoice, "amount").sum.desc)
      * ---
      * There is no @defaultOrder fallback on grouped queries — the model's
      * default order column is usually not in GROUP BY.
      **/
    typeof(this) orderBy(OSpecs...)(OSpecs specs)
    if (OSpecs.length >= 1) {
        auto g = this;
        g._base = _base.orderBy(specs);
        return g;
    }

    /// Limit the number of groups returned.
    typeof(this) limit(long n) {
        auto g = this;
        g._base = _base.limit(n);
        return g;
    }

    /// Skip the first n groups.
    typeof(this) offset(long n) {
        auto g = this;
        g._base = _base.offset(n);
        return g;
    }

    // -----------------------------------------------------------------------
    // Terminal
    // -----------------------------------------------------------------------

    /** Project grouped rows into DTO[] — the only terminal on a grouped query.
      *
      * Each DTO member is matched by its D member name:
      *  1. a groupBy! key           → emitted as _m.col AS member_name
      *  2. an annotate! alias       → emitted as <expr> AS member_name
      *  3. neither                  → compile error (GROUP-BY validation)
      *
      * The SQL column alias is camelToSnake(memberName), matching @autoHydrate
      * convention hydration.  Aggregate DTO members should be long (count,
      * integral sum), double (avg, floating sum), or Nullable!T where a group
      * could aggregate over only-NULL values.
      **/
    DTO[] select(DTO)() {
        import peque.hydration: camelToSnake;

        // Compile-time SELECT list + GROUP-BY validation
        string selList;
        static foreach (dtoMemberName; FieldNameTuple!DTO) {{
            enum expr = _groupedExprFor!(dtoMemberName)();
            static assert(expr.length > 0,
                "select!" ~ DTO.stringof ~ ": member '" ~ dtoMemberName ~
                "' is neither a groupBy!(...) key nor an annotate!(...) alias." ~
                " Non-aggregate DTO columns must appear in groupBy!;" ~
                " aggregate columns must be registered via annotate!(\"" ~
                dtoMemberName ~ "\", ...).");
            if (selList.length) selList ~= ", ";
            selList ~= expr ~ " AS " ~ camelToSnake(dtoMemberName);
        }}

        // Resolve WHERE / ORDER BY / HAVING predicates, collecting the filter
        // joins they need — before the FROM clause is assembled below.
        _FilterJoin[] fjoins;
        int fjIdx = 0;
        Predicate[] resolved;
        foreach (ref p; _base._wheres)
            resolved ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // Only explicit orderBy terms — no @defaultOrder fallback here.
        string orderBySql =
            _resolveOrderTerms!(M, JoinFields)(_base._orderByTerms, fjoins, fjIdx);

        Predicate[] resolvedHavings;
        foreach (ref p; _havings)
            resolvedHavings ~= _resolvePred!(M, JoinFields)(p, fjoins, fjIdx);

        // FROM + explicit JoinField JOINs (j0, j1, …) + runtime filter joins
        string fromClause = " FROM " ~ ormTableName!M ~ " _m";
        static foreach (jfIdx2, jf; JoinFields) {{
            alias RelType = _innerRelType!(M, jf);
            enum _jAlias = "j" ~ to!string(jfIdx2);
            enum _relTbl = ormTableName!RelType;
            enum _relPk  = ormPkColName!RelType();
            enum _fkCol  = _fkColForRelatedField!(M, jf, RelType)();
            fromClause ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _jAlias ~
                          " ON " ~ _jAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
        }}
        fromClause ~= _filterJoinSQL(fjoins);

        // WHERE params first, HAVING params numbered after them
        string whereSQL;
        PGValue[] whereParams;
        QS._buildWhereFromArray(resolved, whereSQL, whereParams);

        string havingSQL;
        PGValue[] havingParams;
        QS._buildWhereFromArray(resolvedHavings, havingSQL, havingParams,
                                cast(int) whereParams.length, " HAVING ");

        enum gbClause = _groupByClause();
        string sql = "SELECT " ~ selList ~ fromClause ~ whereSQL ~
                     " GROUP BY " ~ gbClause ~ havingSQL;
        if (orderBySql.length) sql ~= " ORDER BY " ~ orderBySql;
        if (_base._limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_base._limitVal);
        if (_base._offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_base._offsetVal);

        return _base._ctx.execParams(sql, whereParams ~ havingParams).as!(DTO[]);
    }

    // -----------------------------------------------------------------------
    // CTFE helpers
    // -----------------------------------------------------------------------

    // SQL SELECT expression for one DTO member — "_m.col" for a group key,
    // the registered expression for an annotation, "" if unmatched.
    private static string _groupedExprFor(string memberName)() {
        string expr = "";
        static foreach (S; Specs) {{
            static if (is(typeof(S) == string)) {
                static if (S == memberName) {
                    if (expr.length == 0)
                        expr = "_m." ~ _fieldColName!(M, S)();
                }
            } else {
                static if (S._name == memberName) {
                    if (expr.length == 0)
                        expr = S._expr;
                }
            }
        }}
        return expr;
    }

    // Comma-separated GROUP BY column list from the group-key Specs.
    private static string _groupByClause() {
        string s;
        static foreach (S; Specs) {{
            static if (is(typeof(S) == string)) {
                if (s.length) s ~= ", ";
                s ~= "_m." ~ _fieldColName!(M, S)();
            }
        }}
        return s;
    }
}
