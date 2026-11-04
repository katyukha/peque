/** ORDER BY term representation for peque:orm.
  *
  * An `Ordering` is the normal form every ORDER BY input is reduced to before
  * SQL generation, so `@defaultOrder`, `QuerySet.orderBy`, and `select!DTO` all
  * resolve ordering through one code path.
  *
  * Four kinds (see `OrderKind`):
  *  - `name`   — a column name parsed from `orderBy(string)` or a
  *               `@defaultOrder` string by `_parseOrderSpec`: bare or
  *               double-quoted, optionally qualified (`t.col`), with the
  *               direction and NULLS placement already split off. Resolved at
  *               query-build time: a bare name that is one of the model's
  *               columns becomes `_m.col` so a join cannot make it ambiguous,
  *               unless the statement outputs a column of that name, which
  *               SQL resolves first.
  *  - `raw`    — an SQL fragment from `orderByRaw`, emitted as written,
  *               direction/NULLS ignored. The escape hatch.
  *  - `column` — a resolved column expression (e.g. `"_m.created_at"`);
  *               direction and NULLS placement are appended.
  *  - `path`   — an unresolved model field path (e.g. `"partner.name"`);
  *               resolved to a column (adding LEFT JOINs as needed) at
  *               query-build time, then direction/NULLS appended.
  *
  * Construct via the `F` builders (`F!"field".desc`, `F!"partner.name"`), a
  * string through `orderBy`/`orderByRaw`, or the compile-time
  * `QuerySet.orderBy!("-field")` form — rather than populating the fields
  * directly.
  **/
module peque.orm.ordering;

private import std.ascii: isAlpha, isDigit, toUpper;
private import std.conv: to;

/// Sort direction for an ORDER BY term.
enum OrderDir : ubyte { asc, desc }

/// NULLS placement for an ORDER BY term (PostgreSQL).  `unspecified` lets the
/// server apply its default (NULLS LAST for ASC, NULLS FIRST for DESC).
enum OrderNulls : ubyte { unspecified, first, last }

/// How an `Ordering.expr` is interpreted.  See module docs.
package(peque.orm) enum OrderKind : ubyte { raw, column, path, name }

/// A single ORDER BY term.  See module docs for the meaning of each kind.
struct Ordering {
    package(peque.orm) OrderKind  kind = OrderKind.raw;
    package(peque.orm) string     expr;
    package(peque.orm) OrderDir   dir   = OrderDir.asc;
    package(peque.orm) OrderNulls nulls = OrderNulls.unspecified;

    /// Ascending (default).  No-op for `raw` terms.
    Ordering asc() const pure nothrow @safe        { return Ordering(kind, expr, OrderDir.asc,  nulls); }
    /// Descending.  No-op for `raw` terms.
    Ordering desc() const pure nothrow @safe       { return Ordering(kind, expr, OrderDir.desc, nulls); }
    /// Append `NULLS FIRST`.  No-op for `raw` terms.
    Ordering nullsFirst() const pure nothrow @safe { return Ordering(kind, expr, dir, OrderNulls.first); }
    /// Append `NULLS LAST`.  No-op for `raw` terms.
    Ordering nullsLast() const pure nothrow @safe  { return Ordering(kind, expr, dir, OrderNulls.last); }
}


/// What `_parseOrderSpec` returns: the terms, or why the text was refused.
package(peque.orm) struct ParsedOrder {
    bool       ok;
    Ordering[] terms;
    string     error;   // "expected …", without the input or the remedy
}

/** Parse the one shape `orderBy(string)` accepts: a comma-separated list of
  * column names, each optionally followed by ASC or DESC and by NULLS FIRST
  * or NULLS LAST.
  *
  * A name is a bare identifier — PostgreSQL's own lexer class: a letter,
  * '_' or any byte above 0x7F to start, those or a digit to continue, so a
  * Cyrillic column needs no quotes — a double-quoted one with no quote
  * inside, or either qualified by one such prefix (`_m.col`, `"Mixed"`).
  * Nothing else is understood, and nothing else is passed through: the text
  * may be a runtime value, so a construct the grammar does not name — a
  * function call, an operator, a comment, a dollar quote, a semicolon — is
  * refused rather than guessed at. An expression goes through `orderByRaw`,
  * which says it is trusted.
  *
  * Byte-based on purpose: nothing is decoded, so a malformed byte cannot
  * throw here. It is emitted as part of a name, and the server rejects the
  * statement as a whole for its encoding; every SQL metacharacter is ASCII,
  * so no high byte can end a name early in any encoding.
  **/
package(peque.orm) ParsedOrder _parseOrderSpec(string spec) pure @safe {
    ParsedOrder r;
    size_t i = 0;

    static bool isSpace(char c) pure @safe {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }
    void skipSpace() { while (i < spec.length && isSpace(spec[i])) ++i; }
    ParsedOrder fail(string why) {
        return ParsedOrder(false, null, why);
    }
    string here() {
        if (i >= spec.length) return "the end";
        // A high byte is part of a multibyte character: name it as a byte
        // rather than print a fragment of one.
        if (spec[i] >= 0x80)
            return "byte 0x" ~ to!string(cast(ubyte) spec[i], 16) ~ " at position " ~ i.to!string;
        return "'" ~ spec[i] ~ "' at position " ~ i.to!string;
    }
    static bool identStart(char c) pure @safe { return isAlpha(c) || c == '_' || c >= 0x80; }
    static bool identChar(char c)  pure @safe { return identStart(c) || isDigit(c); }
    // One identifier, bare or quoted; `s` is the text as written. The cursor
    // moves only on success, so a failure is reported where it started.
    bool ident(out string s) {
        size_t j = i;
        if (j >= spec.length) return false;
        if (spec[j] == '"') {
            ++j;
            while (j < spec.length && spec[j] != '"' && spec[j] != '\0') ++j;
            if (j >= spec.length || spec[j] != '"' || j == i + 1) return false;
            ++j;
        } else {
            if (!identStart(spec[j])) return false;
            while (j < spec.length && identChar(spec[j])) ++j;
        }
        s = spec[i .. j];
        i = j;
        return true;
    }
    // A keyword, case-insensitively, not glued to a following identifier char.
    bool word(string w) {
        if (i + w.length > spec.length) return false;
        foreach (k; 0 .. w.length)
            if (toUpper(spec[i + k]) != w[k]) return false;
        immutable end = i + w.length;
        if (end < spec.length && identChar(spec[end])) return false;
        i = end;
        return true;
    }

    while (true) {
        skipSpace();
        string name;
        if (!ident(name)) return fail("expected a column name, found " ~ here());
        if (i < spec.length && spec[i] == '.') {
            ++i;
            string col;
            if (!ident(col)) return fail("expected a column name after '.', found " ~ here());
            name ~= "." ~ col;
        }
        auto term = Ordering(OrderKind.name, name);
        skipSpace();
        if (!word("ASC") && word("DESC")) term.dir = OrderDir.desc;
        skipSpace();
        if (word("NULLS")) {
            skipSpace();
            if (word("FIRST"))     term.nulls = OrderNulls.first;
            else if (word("LAST")) term.nulls = OrderNulls.last;
            else return fail("expected FIRST or LAST after NULLS, found " ~ here());
        }
        skipSpace();
        r.terms ~= term;
        if (i >= spec.length) break;
        if (spec[i] != ',') return fail("expected ',' or the end, found " ~ here());
        ++i;
    }
    r.ok = true;
    return r;
}

unittest {
    static Ordering[] terms(string s) {
        auto p = _parseOrderSpec(s);
        assert(p.ok, s ~ ": " ~ p.error);
        return p.terms;
    }
    static string refused(string s) {
        auto p = _parseOrderSpec(s);
        assert(!p.ok, s ~ " was accepted");
        assert(p.terms.length == 0);
        return p.error;
    }

    assert(terms("name") == [Ordering(OrderKind.name, "name")]);
    assert(terms("name DESC") == [Ordering(OrderKind.name, "name", OrderDir.desc)]);
    assert(terms("name desc nulls last") ==
        [Ordering(OrderKind.name, "name", OrderDir.desc, OrderNulls.last)]);
    assert(terms(`"Mixed" NULLS FIRST`) ==
        [Ordering(OrderKind.name, `"Mixed"`, OrderDir.asc, OrderNulls.first)]);
    assert(terms("_m.title ASC") == [Ordering(OrderKind.name, "_m.title")]);
    assert(terms(` name ,id DESC , "a,b" `) == [
        Ordering(OrderKind.name, "name"),
        Ordering(OrderKind.name, "id", OrderDir.desc),
        Ordering(OrderKind.name, `"a,b"`)], "a comma inside quotes is part of the name");
    assert(terms("\tname\n") == [Ordering(OrderKind.name, "name")]);

    // Everything the grammar does not name is refused, never passed through.
    assert(refused("lower(name)")          == "expected ',' or the end, found '(' at position 5");
    assert(refused("name; DROP TABLE t")   == "expected ',' or the end, found ';' at position 4");
    assert(refused("name -- c")            == "expected ',' or the end, found '-' at position 5");
    assert(refused("name /* c */")         == "expected ',' or the end, found '/' at position 5");
    assert(refused("$$a$$")                == "expected a column name, found '$' at position 0");
    assert(refused("name DESC garbage")    == "expected ',' or the end, found 'g' at position 10");
    assert(refused("name NULLS")           == "expected FIRST or LAST after NULLS, found the end");
    assert(refused("name DESC назва")      == "expected ',' or the end, found byte 0xD0 at position 10");
    assert(refused("name,")                == "expected a column name, found the end");
    assert(refused("")                     == "expected a column name, found the end");
    assert(refused(`"a""b"`)               == "expected ',' or the end, found '\"' at position 3",
        "a quote inside a quoted name is not understood");
    assert(refused(`"`)                    == "expected a column name, found '\"' at position 0");
    assert(refused(`""`)                   == "expected a column name, found '\"' at position 0");
    assert(terms("DESCname") == [Ordering(OrderKind.name, "DESCname")],
        "a keyword glued to a name is just a name");
    assert(terms("назва DESC, näme") == [
        Ordering(OrderKind.name, "назва", OrderDir.desc), Ordering(OrderKind.name, "näme")],
        "a bare non-ASCII name needs no quotes, as in PostgreSQL");
    assert(terms("name, \xff") == [Ordering(OrderKind.name, "name"), Ordering(OrderKind.name, "\xff")],
        "a malformed byte is a name byte here, not decoded; the server rejects the encoding");
    assert(refused("\"na\0me\"")          == "expected a column name, found '\"' at position 0",
        "a NUL inside a quoted name cannot be emitted");
    assert(terms(`"näme"`) == [Ordering(OrderKind.name, `"näme"`)],
        "a quoted name may hold any byte but a quote: it is emitted between its quotes untouched");
}
