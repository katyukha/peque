/** Custom types, defined OUTSIDE the peque package.
  *
  * `hasPGTextReader` / `hasPGValueWriter` are the extension point for types
  * peque does not know — an extension type such as PostGIS geometry, or an
  * application's own value type. Whether they actually work for a CONSUMER is
  * not something a `peque.tests.*` module can answer: it sits inside the
  * package and can reach what an outsider cannot. This module is named outside
  * the namespace on purpose, exactly as `external_consumer.d` is for the ORM.
  *
  * Both directions are covered, plus the composition that should come for free
  * because the Nullable and array overloads recurse into the element type.
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

/** A value type that PARSES rather than passing text through, so the hooks are
  * doing real work in both directions.
  *
  * `_constructed` is false in `Money.init`, and toPGValue asserts on it. That
  * is deliberate: peque must never call the write hook on `T.init` merely to
  * discover an oid for a SQL NULL or an empty array — a real custom type's
  * `.init` is often not a valid value. If that guard regresses, these tests
  * fail here rather than somewhere subtle.
  **/
struct Money {
    private long cents;
    private bool _constructed;

    this(long cents) { this.cents = cents; this._constructed = true; }

    long asCents() const { return cents; }

    static Money fromPGText(scope const(char)[] text, PGType oid) {
        // Sent as a plain numeric string; oid is whatever the column declares.
        return Money(text.to!long);
    }

    PGValue toPGValue() const {
        assert(_constructed, "peque called toPGValue on Money.init");
        // GUESS lets the server infer the type from context, which is what a
        // type with no compile-time oid must do.
        return PGValue.fromText(PGType.GUESS, cents.to!string);
    }
}

/** A text-shaped custom type whose value can contain the characters that make
  * a PostgreSQL array literal ambiguous — comma, quote, backslash, braces.
  **/
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

    // Near-miss signatures must NOT satisfy the predicate — a lenient one would
    // silently take a hook peque then calls wrongly. The catch-all overloads
    // turn each of these into a static assert naming the expected signature.
    static struct NoOid    { int v; static NoOid    fromPGText(scope const(char)[] t) { return NoOid(0); } }
    static struct NotStatic{ int v;        NotStatic fromPGText(scope const(char)[] t, PGType o) { return NotStatic(0); } }
    static struct BadRet   { int v; string toPGValue() const { return "0"; } }
    static assert(!hasPGTextReader!NoOid,     "a reader missing the oid parameter must not qualify");
    static assert(!hasPGTextReader!NotStatic, "a non-static reader must not qualify");
    static assert(!hasPGValueWriter!BadRet,   "a writer not returning PGValue must not qualify");

    // peque's own struct types must never match, or the call would be
    // ambiguous between two overloads rather than resolving to one.
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

    // A negative value, to be sure the text is not being mangled.
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

    // The empty case names a type without a value to ask — if peque reached for
    // Money.init.toPGValue() to find one, the assert in Money would fire.
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

    // Comma, double quote, backslash and braces all have meaning inside an
    // array literal; a custom element type must be quoted and escaped like any
    // other non-numeric one.
    auto hostile = [Label(`a,b`), Label(`he said "hi"`), Label(`back\slash`),
                    Label(`{braced}`), Label(``)];
    auto labels = c.execParams("SELECT $1::text[]", hostile).ensureQueryOk
                   .getValue!(Label[])(0, 0);
    assert(labels.length == 5, "got " ~ labels.length.to!string);
    assert(labels[0].text == `a,b`,          labels[0].text);
    assert(labels[1].text == `he said "hi"`, labels[1].text);
    assert(labels[2].text == `back\slash`,   labels[2].text);
    assert(labels[3].text == `{braced}`,     labels[3].text);

    // An empty array names a type with no element to ask — same guard as the
    // Nullable case above.
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

/** A reader peque has never seen must not be laundered into @safe.
  *
  * A blanket @trusted on the composing overloads (array, Nullable) would let
  * @safe code reach a @system custom reader THROUGH them, even while the direct
  * call is refused. Only peque's own pointer arithmetic is trusted, so the
  * element conversion's attributes decide.
  *
  * Both directions matter: refusing the @system case must not cost peque's own
  * types their @safe-callability.
  **/
unittest {
    static struct SysReader {          // deliberately @system
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

    // peque's own types keep @safe — the trusted narrowing must not cost this.
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
