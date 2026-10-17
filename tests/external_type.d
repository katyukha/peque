/** Custom types (`fromPGText` / `toPGValue`), as a consumer sees them.
  *
  * Named outside the `peque` package so that package-level access cannot make
  * the hooks look usable when they are not, as `external_consumer.d` does for
  * the ORM.
  **/
module external_type;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.algorithm.searching: canFind;

private import peque;
private import peque.converter: PGValue, hasPGTextReader, hasPGValueWriter, convertTextTypeToD, convertToPG;
private import peque.pg_type: PGType;


// ---------------------------------------------------------------------------
// The custom types
// ---------------------------------------------------------------------------

/** A value type that parses its text rather than passing it through.
  *
  * toPGValue asserts on `Money.init`: peque must not call the writer on
  * `T.init` to find an oid for a SQL NULL or an empty array.
  **/
struct Money {
    private long cents;
    private bool _constructed;

    this(long cents) { this.cents = cents; this._constructed = true; }

    long asCents() const { return cents; }

    static Money fromPGText(scope const(char)[] text, PGType oid) {
        return Money(text.to!long);
    }

    PGValue toPGValue() const {
        assert(_constructed, "peque called toPGValue on Money.init");
        return PGValue.fromText(PGType.GUESS, cents.to!string);
    }
}

/// A text-shaped custom type, for array elements with comma, quote, backslash
/// and braces.
struct Label {
    string text;

    static Label fromPGText(scope const(char)[] t, PGType oid) {
        return Label(t.idup);
    }

    PGValue toPGValue() const {
        return PGValue.fromText(PGType.GUESS, text);
    }
}


private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


// ---------------------------------------------------------------------------
// The predicates recognise a custom type, and still reject peque's own
// ---------------------------------------------------------------------------

unittest {
    import std.datetime: Date, SysTime;
    import std.json: JSONValue;
    import std.uuid: UUID;

    static assert(hasPGTextReader!Money && hasPGValueWriter!Money);
    static assert(hasPGTextReader!Label && hasPGValueWriter!Label);

    // A plain struct with no hooks is not swept in.
    static struct Plain { int x; }
    static assert(!hasPGTextReader!Plain && !hasPGValueWriter!Plain);

    // Near-miss signatures do not qualify, so the catch-all overloads report
    // the expected signature instead of failing inside peque.
    static struct NoOid    { int v; static NoOid    fromPGText(scope const(char)[] t) { return NoOid(0); } }
    static struct NotStatic{ int v;        NotStatic fromPGText(scope const(char)[] t, PGType o) { return NotStatic(0); } }
    static struct BadRet   { int v; string toPGValue() const { return "0"; } }
    static struct NonConst { int v; PGValue toPGValue() { return PGValue.fromText(PGType.GUESS, "0"); } }
    static assert(!hasPGTextReader!NoOid,     "a reader missing the oid parameter must not qualify");
    static assert(!hasPGTextReader!NotStatic, "a non-static reader must not qualify");
    static assert(!hasPGValueWriter!BadRet,   "a writer not returning PGValue must not qualify");
    static assert(!hasPGValueWriter!NonConst, "a non-const writer must not qualify");

    // peque's own struct types never match, or the call would be ambiguous.
    static assert(!hasPGTextReader!Date && !hasPGValueWriter!Date);
    static assert(!hasPGTextReader!SysTime && !hasPGValueWriter!SysTime);
    static assert(!hasPGTextReader!UUID && !hasPGValueWriter!UUID);
    static assert(!hasPGTextReader!JSONValue && !hasPGValueWriter!JSONValue);
    static assert(!hasPGTextReader!(Nullable!int) && !hasPGValueWriter!(Nullable!int));
}


// ---------------------------------------------------------------------------
// Round-trip through execParams — the parameter and the result
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    auto res = c.execParams("SELECT $1::bigint", Money(1234)).ensureQueryOk;
    assert(res.getValue!Money(0, 0).asCents == 1234);

    assert(c.execParams("SELECT $1::bigint", Money(-99)).ensureQueryOk
            .getValue!Money(0, 0).asCents == -99);
}


// ---------------------------------------------------------------------------
// Nullable!T — and the NULL path must not construct T.init
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    auto set = Nullable!Money(Money(500));
    assert(c.execParams("SELECT $1::bigint", set).ensureQueryOk
            .getValue!(Nullable!Money)(0, 0).get.asCents == 500);

    // Must not call Money.init.toPGValue() to find an oid.
    Nullable!Money empty;
    auto r = c.execParams("SELECT $1::bigint", empty).ensureQueryOk;
    assert(r[0][0].isNull);
    assert(r.getValue!(Nullable!Money)(0, 0).isNull);
}


// ---------------------------------------------------------------------------
// T[] — composition, and the array literal must survive hostile text
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    auto money = [Money(1), Money(22), Money(333)];
    auto back = c.execParams("SELECT $1::bigint[]", money).ensureQueryOk
                 .getValue!(Money[])(0, 0);
    assert(back.length == 3);
    assert(back[0].asCents == 1 && back[1].asCents == 22 && back[2].asCents == 333);

    auto hostile = [Label(`a,b`), Label(`he said "hi"`), Label(`back\slash`),
                    Label(`{braced}`), Label(``)];
    auto labels = c.execParams("SELECT $1::text[]", hostile).ensureQueryOk
                   .getValue!(Label[])(0, 0);
    assert(labels.length == 5, "got " ~ labels.length.to!string);
    assert(labels[0].text == `a,b`,          labels[0].text);
    assert(labels[1].text == `he said "hi"`, labels[1].text);
    assert(labels[2].text == `back\slash`,   labels[2].text);
    assert(labels[3].text == `{braced}`,     labels[3].text);

    // Must not call Money.init.toPGValue() either.
    Money[] none;
    assert(c.execParams("SELECT $1::bigint[]", none).ensureQueryOk
            .getValue!(Money[])(0, 0).length == 0);
}


// ---------------------------------------------------------------------------
// A custom type as a field of a hydrated struct
// ---------------------------------------------------------------------------

@model("ext_custom_type")
private struct Wallet {
    @primaryKey int     id;
    @field      string  owner;
    @field      Money   balance;
    @field      Nullable!Money overdraft;
}

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS ext_custom_type`);
    c.exec(`CREATE TABLE ext_custom_type (
                id serial PRIMARY KEY, owner text, balance bigint, overdraft bigint)`);
    scope(exit) c.exec(`DROP TABLE IF EXISTS ext_custom_type`);

    c.execParams(
        `INSERT INTO ext_custom_type (owner, balance, overdraft) VALUES ($1, $2, $3)`,
        "ann", Money(7500), Nullable!Money(Money(-200)));
    c.execParams(
        `INSERT INTO ext_custom_type (owner, balance, overdraft) VALUES ($1, $2, $3)`,
        "bob", Money(0), Nullable!Money.init);

    auto rows = c.exec(
        `SELECT id, owner, balance, overdraft FROM ext_custom_type ORDER BY owner`)
        .as!(Wallet[]);

    assert(rows.length == 2);
    assert(rows[0].owner == "ann");
    assert(rows[0].balance.asCents == 7500);
    assert(!rows[0].overdraft.isNull && rows[0].overdraft.get.asCents == -200);
    assert(rows[1].owner == "bob");
    assert(rows[1].balance.asCents == 0);
    assert(rows[1].overdraft.isNull);
}


// ---------------------------------------------------------------------------
// @safe is earned, not asserted
// ---------------------------------------------------------------------------

/** A @system custom reader stays @system through the array and Nullable
  * overloads, and peque's own types stay @safe.
  **/
unittest {
    static struct SysReader {
        int v;
        static SysReader fromPGText(scope const(char)[] t, PGType o) {
            int* p; auto q = p + 1;    // pointer arithmetic: @system
            return SysReader(0);
        }
        PGValue toPGValue() const {
            int* p; auto q = p + 1;
            return PGValue.fromText(PGType.GUESS, "0");
        }
    }
    static struct SafeReader {
        int v;
        static SafeReader fromPGText(scope const(char)[] t, PGType o) @safe { return SafeReader(0); }
        PGValue toPGValue() const @safe { return PGValue.fromText(PGType.GUESS, "0"); }
    }

    // peque's own types keep @safe.
    static assert(__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!(int[])(null, 0, PGType.GUESS); }),
        "int[] must stay @safe-callable");
    static assert(__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!(Nullable!int)(null, 0, PGType.GUESS); }),
        "Nullable!int must stay @safe-callable");

    // A @safe custom reader composes and stays @safe.
    static assert(__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!(SafeReader[])(null, 0, PGType.GUESS); }),
        "a @safe reader must compose through an array and stay @safe");

    // A @system one is refused — directly AND through every composition.
    static assert(!__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!SysReader(null, 0, PGType.GUESS); }));
    static assert(!__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!(SysReader[])(null, 0, PGType.GUESS); }),
        "an array must not launder a @system reader into @safe");
    static assert(!__traits(compiles, () @safe {
        cast(void) convertTextTypeToD!(Nullable!SysReader)(null, 0, PGType.GUESS); }),
        "Nullable must not launder a @system reader into @safe");

    // Same on the write side.
    static assert(!__traits(compiles, () @safe { cast(void) convertToPG(SysReader(1)); }));
    static assert(__traits(compiles,  () @safe { cast(void) convertToPG(SafeReader(1)); }));
}
