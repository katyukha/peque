private import std.exception;
private import std.conv;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception;


@safe unittest {
    import std.stdio;
    import std.typecons;
    import std.datetime;

    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

    // Set timezone for this session
    c.exec("SET TIME ZONE '+4'");

    // Test get value
    auto res = c.exec("SELECT NULL");
    assert(res.getValue(0, 0).isNull);
    res.getValue(0, 0).get!int.assertThrown!ConversionError;
    assert(res.getValue(0, 0).get!int(42) == 42);
    assert(res.getValue(0, 0).get!string("42") == "42");

    res = c.exec("SELECT 42");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "42");
    assert(res.getValue(0, 0).get!int == 42);
    assert(res.getValue(0, 0).get!byte == cast(byte)42);

    res = c.exec("SELECT 7842");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "7842");
    assert(res.getValue(0, 0).get!int == 7842);

    // 7842 is too big for type byt, thus ensure that error is thrown
    res.getValue(0, 0).get!byte.assertThrown!ConvOverflowException;

    res = c.exec("SELECT 'hello world!'");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "hello world!");

    res = c.exec("SELECT ''");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "");

    res = c.exec("SELECT True");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "t");
    assert(res.getValue(0, 0).get!bool == true);

    res = c.exec("SELECT False");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "f");
    assert(res.getValue(0, 0).get!bool == false);

    res = c.exec("SELECT 0.1782788489");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "0.1782788489");
    assert(res.getValue(0, 0).get!float == 0.1782788489f);
    assert(res.getValue(0, 0).get!double == 0.1782788489);

    res = c.exec("SELECT 0.17827");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "0.17827");
    assert(res.getValue(0, 0).get!float == 0.17827f);
    assert(res.getValue(0, 0).get!double == 0.17827);

    // Conversions to date/time
    res = c.exec("SELECT '2023-07-17'::timestamp;");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "2023-07-17 00:00:00");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17));

    res = c.exec("SELECT '2023-07-17 13:42:18'::timestamp;");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "2023-07-17 13:42:18");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17, 13, 42, 18));
    assert(res.getValue(0, 0).get!SysTime == SysTime(DateTime(2023, 7, 17, 13, 42, 18), UTC()));

    res = c.exec("SELECT '2023-07-17'::date;");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "2023-07-17");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));

    res = c.exec("SELECT '2023-07-17 13:42:18+05'::timestamptz;");
    assert(!res.getValue(0, 0).isNull);
    // The result is returned in connection's timezone
    assert(res.getValue(0, 0).get!string == "2023-07-17 12:42:18+04");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17, 12, 42, 18));
    assert(res.getValue(0, 0).get!SysTime == SysTime(DateTime(2023, 7, 17, 12, 42, 18), new immutable(SimpleTimeZone)(4.hours)));
    assert(res.getValue(0, 0).get!SysTime.utcOffset == 4.hours);

    /// Incorrect query
    res = c.exec("SELECT '2023-07'::date;");
    res.ensureQueryOk.assertThrown!QueryError;

    /// Test parameter passing
    res = c.execParams("SELECT $1", 42).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "42");
    assert(res.getValue(0, 0).get!int == 42);
    assert(res.getValue(0, 0).get!byte == cast(byte)42);

    res = c.execParams("SELECT $1", 422).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "422");
    assert(res.getValue(0, 0).get!int == 422);

    c.execParams("SELECT $1::int4", cast(uint)2147483699).ensureQueryOk.assertThrown!QueryError;
    res = c.execParams("SELECT $1::int8", cast(uint)2147483699).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "2147483699");
    assert(res.getValue(0, 0).get!uint == 2147483699);

    c.execParams("SELECT $1::int8", cast(ulong)9223372036854775899).ensureQueryOk.assertThrown!QueryError;
    res = c.execParams("SELECT $1::numeric", cast(ulong)9223372036854775899).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "9223372036854775899");
    assert(res.getValue(0, 0).get!ulong == 9223372036854775899);

    res = c.execParams("SELECT $1::timestamp", Date(2023, 7, 17)).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "2023-07-17 00:00:00");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17, 0, 0, 0));
}


// Separate case to test things that are not allowed in safe code
@system unittest {
    import std.datetime;
    import core.exception: AssertError;

    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

    auto res = c.exec("SELECT 42;");
    res.getValue(0, 0).get!Date.assertThrown!AssertError;
}
