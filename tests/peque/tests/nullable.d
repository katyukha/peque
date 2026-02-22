module peque.tests.nullable;

private import std.exception;
private import std.typecons;
private import std.process: environment;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception;


unittest {
    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    // NULL Nullable!int parameter → column reads back as SQL NULL
    Nullable!int nullInt;
    auto res = c.execParams("SELECT $1::int", nullInt);
    res.ensureQueryOk;
    assert(res[0][0].isNull);

    // Non-null Nullable!int parameter → correct round-trip
    Nullable!int someInt = 42;
    res = c.execParams("SELECT $1::int", someInt);
    res.ensureQueryOk;
    assert(!res[0][0].isNull);
    assert(res[0][0].get!int == 42);

    // NULL Nullable!string parameter → column reads back as SQL NULL
    Nullable!string nullStr;
    res = c.execParams("SELECT $1::text", nullStr);
    res.ensureQueryOk;
    assert(res[0][0].isNull);

    // Non-null Nullable!string parameter → correct round-trip
    Nullable!string someStr = "hello";
    res = c.execParams("SELECT $1::text", someStr);
    res.ensureQueryOk;
    assert(!res[0][0].isNull);
    assert(res[0][0].get!string == "hello");

    // get!(Nullable!string) on NULL column → .isNull == true
    res = c.exec("SELECT NULL::text");
    auto nullVal = res[0][0].get!(Nullable!string);
    assert(nullVal.isNull);

    // get!(Nullable!string) on non-NULL column → correct value
    res = c.exec("SELECT 'world'::text");
    auto nonNullVal = res[0][0].get!(Nullable!string);
    assert(!nonNullVal.isNull);
    assert(nonNullVal.get == "world");

    // get!(Nullable!int) on NULL column → .isNull == true
    res = c.exec("SELECT NULL::int");
    assert(res[0][0].get!(Nullable!int).isNull);

    // get!(Nullable!int) on non-NULL column → correct value
    res = c.exec("SELECT 99::int");
    auto nv = res[0][0].get!(Nullable!int);
    assert(!nv.isNull);
    assert(nv.get == 99);

    // get!string on NULL column → still throws ConversionError
    res = c.exec("SELECT NULL::text");
    res[0][0].get!string.assertThrown!ConversionError;

    // get!int on NULL column → still throws ConversionError
    res = c.exec("SELECT NULL::int");
    res[0][0].get!int.assertThrown!ConversionError;
}
