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
  *
  * Terminal methods:
  *  - all()                → M[]          — fetch all matching rows
  *  - first()              → Nullable!M   — fetch at most one row
  *  - count()              → long         — SELECT COUNT(*)
  *  - exists()             → bool         — SELECT 1 … LIMIT 1
  *  - asSubquery!"f"()     → SubQuery!T   — capture as single-column subquery atom (no DB call)
  *  - delete_()            → long         — DELETE, returns rows deleted
  *  - update()             → long         — partial UPDATE using accumulated set!() calls
  *  - select!DTO()         → DTO[]        — project main + join columns into a DTO
  **/
module peque.orm.queryset;

private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.traits: hasUDA, FieldNameTuple, Fields;
private import std.string: indexOf, strip, split;
private import std.exception: enforce;
private import peque.exception: PequeException;

private import peque.model: model, defaultOrder, field, primaryKey, related,
    one2many, many2many, many2one, OnDelete, hasMany2OneUDA, autoHydrate;
private import peque.converter: PGValue, convertToPG;
private import peque.query_context: isQueryContext;
private import peque.orm.repository: isModel;
private import peque.orm.sql;
private import peque.orm.predicate;
private import peque.orm.field: FieldBuilder, PathBuilder, F;
private import peque.orm.predicate: PathNode, LiteralNode, InSubqueryNode;
private import peque.orm.subquery: SubQuery;
private import std.sumtype: match;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Extract the ORDER BY clause from @defaultOrder UDA on M, or "".
private template _modelDefaultOrder(M) {
    static if (hasUDA!(M, defaultOrder)) {
        private static string _compute() {
            static foreach (uda; __traits(getAttributes, M)) {{
                static if (is(uda) && is(uda == defaultOrder!fields, fields...)) {
                    string r;
                    static foreach (f; fields) {
                        if (r.length) r ~= ", ";
                        r ~= f;
                    }
                    return r;
                }
            }}
            return "";
        }
        enum string _modelDefaultOrder = _compute();
    } else {
        enum string _modelDefaultOrder = "";
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
                    // Collect PKs from main rows
                    alias PkType = typeof(__traits(getMember, M, ormPkFieldName!M()));
                    PkType[] pks;
                    foreach (ref r; rows) {
                        bool dup = false;
                        foreach (p; pks) if (p == __traits(getMember, r, ormPkFieldName!M())) { dup = true; break; }
                        if (!dup) pks ~= __traits(getMember, r, ormPkFieldName!M());
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
                    foreach (ref r; rows) {
                        bool dup = false;
                        foreach (p; pks) if (p == __traits(getMember, r, ormPkFieldName!M())) { dup = true; break; }
                        if (!dup) pks ~= __traits(getMember, r, ormPkFieldName!M());
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

    // 3 — create a new filter join
    static foreach (memberName; FieldNameTuple!M) {{
        alias Mem = __traits(getMember, M, memberName);
        // 3a — via @related field
        static if (hasUDA!(Mem, related)) {
            if (memberName == relName && !result.length) {
                alias RelType = _innerRelType!(M, memberName);
                enum relTable = ormTableName!RelType;
                enum relPkCol = ormPkColName!RelType();
                enum fkCol    = _fkColForRelatedField!(M, memberName, RelType)();
                string jAlias = "fj" ~ to!string(idx);
                fjoins ~= _FilterJoin(relName, jAlias, relTable, relPkCol, "_m", fkCol);
                idx++;
                result = jAlias ~ "." ~ _fieldColNameRuntime!RelType(fieldName);
            }
        }
        // 3b — via direct @many2one FK field (field name is the path key)
        static if (hasMany2OneUDA!Mem) {
            if (memberName == relName && !result.length) {
                alias RelTypeM2O = _m2oRelType!(M, memberName);
                enum relTableM2O = ormTableName!RelTypeM2O;
                enum relPkColM2O = ormPkColName!RelTypeM2O();
                enum fkColM2O    = _colName!(Mem, memberName);
                string jAliasM2O = "fj" ~ to!string(idx);
                fjoins ~= _FilterJoin(relName, jAliasM2O, relTableM2O, relPkColM2O, "_m", fkColM2O);
                idx++;
                result = jAliasM2O ~ "." ~ _fieldColNameRuntime!RelTypeM2O(fieldName);
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
    import peque.model: related;
    string result;

    // Helper: given a known RelType1 and a1, resolve level-2
    // Defined as a mixin-style macro via a lambda to avoid code duplication.
    static foreach (m1; FieldNameTuple!M) {{
        alias Mem1 = __traits(getMember, M, m1);

        // Level-1 via @related
        static if (hasUDA!(Mem1, related)) {
            if (m1 == rel1 && !result.length) {
                alias RelType1 = _innerRelType!(M, m1);
                enum t1  = ormTableName!RelType1;
                enum pk1 = ormPkColName!RelType1();
                enum fk1 = _fkColForRelatedField!(M, m1, RelType1)();

                string a1;
                static foreach (jfIdx, jf; JoinFields) {
                    if (jf == rel1 && !a1.length) a1 = "j" ~ to!string(jfIdx);
                }
                if (!a1.length) {
                    foreach (ref fj; fjoins) if (fj.path == rel1) { a1 = fj.alias_; break; }
                }
                if (!a1.length) {
                    a1 = "fj" ~ to!string(idx);
                    fjoins ~= _FilterJoin(rel1, a1, t1, pk1, "_m", fk1);
                    idx++;
                }

                static foreach (m2; FieldNameTuple!RelType1) {{
                    alias Mem2 = __traits(getMember, RelType1, m2);
                    static if (hasUDA!(Mem2, related)) {
                        if (m2 == rel2 && !result.length) {
                            alias RelType2 = _innerRelType!(RelType1, m2);
                            enum t2   = ormTableName!RelType2;
                            enum pk2  = ormPkColName!RelType2();
                            enum fk2  = _fkColForRelatedField!(RelType1, m2, RelType2)();
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
                    static if (hasMany2OneUDA!Mem2) {
                        if (m2 == rel2 && !result.length) {
                            alias RelType2M = _m2oRelType!(RelType1, m2);
                            enum t2m   = ormTableName!RelType2M;
                            enum pk2m  = ormPkColName!RelType2M();
                            enum fk2m  = _colName!(Mem2, m2);
                            string path2m = rel1 ~ "." ~ rel2;
                            string a2m;
                            foreach (ref fj; fjoins) if (fj.path == path2m) { a2m = fj.alias_; break; }
                            if (!a2m.length) {
                                a2m = "fj" ~ to!string(idx);
                                fjoins ~= _FilterJoin(path2m, a2m, t2m, pk2m, a1, fk2m);
                                idx++;
                            }
                            result = a2m ~ "." ~ _fieldColNameRuntime!RelType2M(fieldName);
                        }
                    }
                }}
            }
        }

        // Level-1 via direct @many2one FK field
        static if (hasMany2OneUDA!Mem1) {
            if (m1 == rel1 && !result.length) {
                alias RelType1M = _m2oRelType!(M, m1);
                enum t1m  = ormTableName!RelType1M;
                enum pk1m = ormPkColName!RelType1M();
                enum fk1m = _colName!(Mem1, m1);

                string a1m;
                if (!a1m.length) {
                    foreach (ref fj; fjoins) if (fj.path == rel1) { a1m = fj.alias_; break; }
                }
                if (!a1m.length) {
                    a1m = "fj" ~ to!string(idx);
                    fjoins ~= _FilterJoin(rel1, a1m, t1m, pk1m, "_m", fk1m);
                    idx++;
                }

                static foreach (m2; FieldNameTuple!RelType1M) {{
                    alias Mem2M = __traits(getMember, RelType1M, m2);
                    static if (hasUDA!(Mem2M, related)) {
                        if (m2 == rel2 && !result.length) {
                            alias RelType2 = _innerRelType!(RelType1M, m2);
                            enum t2r   = ormTableName!RelType2;
                            enum pk2r  = ormPkColName!RelType2();
                            enum fk2r  = _fkColForRelatedField!(RelType1M, m2, RelType2)();
                            string path2r = rel1 ~ "." ~ rel2;
                            string a2r;
                            foreach (ref fj; fjoins) if (fj.path == path2r) { a2r = fj.alias_; break; }
                            if (!a2r.length) {
                                a2r = "fj" ~ to!string(idx);
                                fjoins ~= _FilterJoin(path2r, a2r, t2r, pk2r, a1m, fk2r);
                                idx++;
                            }
                            result = a2r ~ "." ~ _fieldColNameRuntime!RelType2(fieldName);
                        }
                    }
                    static if (hasMany2OneUDA!Mem2M) {
                        if (m2 == rel2 && !result.length) {
                            alias RelType2M = _m2oRelType!(RelType1M, m2);
                            enum t2mm   = ormTableName!RelType2M;
                            enum pk2mm  = ormPkColName!RelType2M();
                            enum fk2mm  = _colName!(Mem2M, m2);
                            string path2mm = rel1 ~ "." ~ rel2;
                            string a2mm;
                            foreach (ref fj; fjoins) if (fj.path == path2mm) { a2mm = fj.alias_; break; }
                            if (!a2mm.length) {
                                a2mm = "fj" ~ to!string(idx);
                                fjoins ~= _FilterJoin(path2mm, a2mm, t2mm, pk2mm, a1m, fk2mm);
                                idx++;
                            }
                            result = a2mm ~ "." ~ _fieldColNameRuntime!RelType2M(fieldName);
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

// Parse an orderBy clause and resolve any join-path tokens (e.g. "partner.name ASC").
// Uses the same fjoins/idx as where-predicate resolution so joins are deduplicated.
private string _resolveOrderClause(M, JoinFields...)(
    string clause, ref _FilterJoin[] fjoins, ref int idx)
{
    if (!clause.length) return clause;
    string result;
    foreach (i, part; clause.split(",")) {
        if (i > 0) result ~= ", ";
        string trimmed = part.strip;
        auto spIdx = indexOf(trimmed, ' ');
        string fieldPart = spIdx >= 0 ? trimmed[0 .. spIdx]  : trimmed;
        string suffix    = spIdx >= 0 ? trimmed[spIdx .. $]   : "";
        // Resolve if it looks like a join path (contains dot, first segment is a @related field)
        if (indexOf(fieldPart, '.') >= 0) {
            auto dotAt = indexOf(fieldPart, '.');
            if (_isKnownRelField!M(fieldPart[0 .. dotAt])) {
                result ~= _resolvePathToCol!(M, JoinFields)(fieldPart, fjoins, idx) ~ suffix;
                continue;
            }
        }
        result ~= trimmed;
    }
    return result;
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
    private string       _orderByClause;
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

    /** Override the ORDER BY clause.
      *
      * If never called, the model's @defaultOrder UDA is used (if present).
      * Pass "" to suppress all ordering.
      *
      * Security: clause is embedded in the query verbatim — never pass
      * user-controlled input here.  Use a compile-time constant or a
      * whitelist-validated string.
      **/
    QuerySet!(M, Ctx, JoinFields) orderBy(string clause) {
        auto qs = this;
        qs._orderByClause = clause;
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
        qs2._orderByClause  = _orderByClause;
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

    // -----------------------------------------------------------------------
    // Internal — accumulate renumbered WHERE SQL and flat PGValue[].
    // -----------------------------------------------------------------------

    private static void _buildWhereFromArray(
            Predicate[] preds, out string whereSQL, out PGValue[] params,
            int startOffset = 0) {
        whereSQL = "";
        params   = [];
        if (preds.length == 0) return;
        whereSQL = " WHERE ";
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

        // Resolve orderBy clause (may add more filter joins)
        enum _defOrder = _modelDefaultOrder!M;
        string rawOrder = _orderByClause.length ? _orderByClause : _defOrder;
        string orderBySql = _resolveOrderClause!(M, JoinFields)(rawOrder, fjoins, fjIdx);

        string whereSQL;
        PGValue[] params;
        _buildWhereFromArray(resolved, whereSQL, params);

        static if (JoinFields.length == 0) {
            // No hydration joins — may still have filter joins
            // Use _m. prefix to avoid column ambiguity when filter joins are present
            enum _mainSelNoJoin = _prefixedSelectList!(M, "_m")();
            string sql = "SELECT " ~ _mainSelNoJoin ~
                         " FROM " ~ ormTableName!M ~ " _m";
            sql ~= _filterJoinSQL(fjoins);
            sql ~= whereSQL;
            if (orderBySql.length) sql ~= " ORDER BY " ~ orderBySql;
            if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
            if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

            auto rows = _ctx.execParams(sql, params).as!(M[]);
            foreach (fn; _prefetches) fn(rows, _ctx);
            return rows;

        } else {
            // Hydration joins — aliased SELECT + LEFT JOINs
            enum _mainSel = _prefixedSelectList!(M, "_m")();
            string joinExtras;
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias = "j" ~ to!string(idx);
                enum _prefix = "__" ~ jf ~ "_";
                enum _extras = _joinSelectExtras!(RelType, _jAlias, _prefix)();
                if (joinExtras.length) joinExtras ~= ", ";
                joinExtras ~= _extras;
            }}

            string sql = "SELECT " ~ _mainSel;
            if (joinExtras.length) sql ~= ", " ~ joinExtras;
            sql ~= " FROM " ~ ormTableName!M ~ " _m";

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
            sql ~= _filterJoinSQL(fjoins);
            sql ~= whereSQL;
            if (orderBySql.length) sql ~= " ORDER BY " ~ orderBySql;
            if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
            if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

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

        enum _defOrder = _modelDefaultOrder!M;
        string rawOrder = _orderByClause.length ? _orderByClause : _defOrder;
        if (rawOrder.length) sql ~= " ORDER BY " ~ rawOrder;

        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        return _ctx.execParams(sql, params).as!(DTO[]);
    }
}
