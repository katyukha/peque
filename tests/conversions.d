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

    /// Conversions to array types
    res = c.exec("SELECT ARRAY[1,2,3,4]").ensureQueryOk;
    assert(res[0][0].get!(int[]) == [1, 2, 3, 4]);
    assert(res[0][0].get!string == "{1,2,3,4}");

    res = c.exec("SELECT ARRAY[1.1,2.2,3.3,4.4]").ensureQueryOk;
    assert(res[0][0].get!(float[]) == [1.1f, 2.2f, 3.3f, 4.4f]);
    assert(res[0][0].get!string == "{1.1,2.2,3.3,4.4}");

    res = c.exec("SELECT ARRAY['str1', 'str2']").ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["str1", "str2"]);
    assert(res[0][0].get!string == "{str1,str2}");

    res = c.exec("SELECT ARRAY['str1,24', 'str2 \"78\"', 'back\\slashed', 'simple']").ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["str1,24", "str2 \"78\"", "back\\slashed", "simple"]);
    assert(res[0][0].get!string == "{\"str1,24\",\"str2 \\\"78\\\"\",\"back\\\\slashed\",simple}");

    res = c.execParams("SELECT ARRAY[True, False]").ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{t,f}");
    assert(res.getValue(0, 0).get!(bool[]) == [true, false]);

    res = c.exec("SELECT ARRAY['2023-08-17'::date, '2023-09-12'::date]").ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!string == "{2023-08-17,2023-09-12}");

    res = c.exec("SELECT ARRAY['2023-08-17 08:09:10'::timestamp, '2023-09-12 11:12:13'::timestamp]").ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!(DateTime[]) == [DateTime(2023, 8, 17, 8, 9, 10), DateTime(2023, 9, 12, 11, 12, 13)]);
    assert(res[0][0].get!string == "{\"2023-08-17 08:09:10\",\"2023-09-12 11:12:13\"}");

    res = c.exec("SELECT ARRAY['2023-08-17 08:09:10+05'::timestamptz, '2023-09-12 11:12:13+05'::timestamptz]").ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!(DateTime[]) == [DateTime(2023, 8, 17, 7, 9, 10), DateTime(2023, 9, 12, 10, 12, 13)]);
    assert(res[0][0].get!(SysTime[]) == [
        SysTime(DateTime(2023, 8, 17, 7, 9, 10), new immutable(SimpleTimeZone)(4.hours)),
        SysTime(DateTime(2023, 9, 12, 10, 12, 13), new immutable(SimpleTimeZone)(4.hours)),
    ]);
    assert(res[0][0].get!string == "{\"2023-08-17 07:09:10+04\",\"2023-09-12 10:12:13+04\"}");

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

    res = c.execParams("SELECT $1", 0.1782788489);
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!float == 0.1782788489f);
    assert(res.getValue(0, 0).get!double == 0.1782788489);
    //assert(res.getValue(0, 0).get!string == "0.1782788489");

    //res = c.execParams("SELECT $1", 0.17827f);
    //assert(!res.getValue(0, 0).isNull);
    //assert(res.getValue(0, 0).get!string == "0.17827");
    //assert(res.getValue(0, 0).get!float == 0.1782700000f);
    //assert(res.getValue(0, 0).get!double == 0.1782700000);

    res = c.execParams("SELECT $1::timestamp", Date(2023, 7, 17)).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "2023-07-17 00:00:00");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17, 0, 0, 0));

    /// Test array conversions
    res = c.execParams("SELECT $1", [1, 2, 3, 4, 5]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{1,2,3,4,5}");
    assert(res.getValue(0, 0).get!(int[]) == [1, 2, 3, 4, 5]);

    res = c.execParams("SELECT $1", [true, false]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{t,f}");
    assert(res.getValue(0, 0).get!(bool[]) == [true, false]);

    res = c.execParams("SELECT $1", [1, 2, 3, 4]).ensureQueryOk;
    assert(res[0][0].get!(int[]) == [1, 2, 3, 4]);
    assert(res[0][0].get!string == "{1,2,3,4}");

    res = c.execParams("SELECT $1", [1.1f, 2.2f, 3.3f, 4.4f]).ensureQueryOk;
    assert(res[0][0].get!(float[]) == [1.1f, 2.2f, 3.3f, 4.4f]);
    //assert(res[0][0].get!string == "{1.1,2.2,3.3,4.4}");

    res = c.execParams("SELECT $1", ["str1", "str2"]).ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["str1", "str2"]);
    assert(res[0][0].get!string == "{str1,str2}");

    res = c.execParams("SELECT $1", ["str1,24", "str2 \"78\"", "back\\slashed", "simple"]).ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["str1,24", "str2 \"78\"", "back\\slashed", "simple"]);
    assert(res[0][0].get!string == "{\"str1,24\",\"str2 \\\"78\\\"\",\"back\\\\slashed\",simple}");

    res = c.execParams("SELECT $1", [Date(2023, 8, 17), Date(2023, 9, 12)]).ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!string == "{2023-08-17,2023-09-12}");

    res = c.execParams("SELECT $1", [DateTime(2023, 8, 17, 8, 9, 10), DateTime(2023, 9, 12, 11, 12, 13)]).ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!(DateTime[]) == [DateTime(2023, 8, 17, 8, 9, 10), DateTime(2023, 9, 12, 11, 12, 13)]);
    assert(res[0][0].get!string == "{\"2023-08-17 08:09:10\",\"2023-09-12 11:12:13\"}");

    res = c.execParams("SELECT $1", [
        SysTime(DateTime(2023, 8, 17, 7, 9, 10), new immutable(SimpleTimeZone)(4.hours)),
        SysTime(DateTime(2023, 9, 12, 10, 12, 13), new immutable(SimpleTimeZone)(4.hours)),
    ]).ensureQueryOk;
    assert(res[0][0].get!(Date[]) == [Date(2023, 8, 17), Date(2023, 9, 12)]);
    assert(res[0][0].get!(DateTime[]) == [DateTime(2023, 8, 17, 7, 9, 10), DateTime(2023, 9, 12, 10, 12, 13)]);
    assert(res[0][0].get!(SysTime[]) == [
        SysTime(DateTime(2023, 8, 17, 7, 9, 10), new immutable(SimpleTimeZone)(4.hours)),
        SysTime(DateTime(2023, 9, 12, 10, 12, 13), new immutable(SimpleTimeZone)(4.hours)),
    ]);
    assert(res[0][0].get!string == "{\"2023-08-17 07:09:10+04\",\"2023-09-12 10:12:13+04\"}");
}


// Separate case to test things that are not allowed in safe code
@system unittest {
    import std.datetime;
    import core.exception: AssertError;

    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

    auto res = c.exec("SELECT 42;");
    res.getValue(0, 0).get!Date.assertThrown!AssertError;
}


/// Example of read / write different field types from / to table
@safe unittest {
    import std.datetime;
    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

    // Set timezone for this session
    c.exec("SET TIME ZONE '+4'");

    c.exec("
        DROP TABLE IF EXISTS peque_test_conv;
        CREATE TABLE peque_test_conv (
            id               serial,
            code             char(20),
            title            varchar(40),
            description      text,
            data_int2        int2,
            data_int4        int4,
            data_int8        int8,
            data_float       real,
            data_double      double precision,
            data_date        date,
            data_dt          timestamp,
            data_dt_tz       timestamp with time zone,
            data_bool        boolean
        );
        INSERT INTO peque_test_conv(
            code, title, description,
            data_int2, data_int4, data_int8,
            data_float, data_double,
            data_date, data_dt, data_dt_tz,
            data_bool)
        VALUES (
            'test-code-1',
            'Test 1',
            'Some test data should be here',
            31000,
            2111222333,
            9223372036854775800,
            6.123456,
            15.12345678901234,
            '2023-08-02',
            '2023-08-02 23:13:42.1234560',
            '2023-08-02 23:13:42.123456+05',
            true
        );
    ").ensureQueryOk;

    auto res = c.execParams("
        SELECT * FROM peque_test_conv WHERE code = $1
    ", "test-code-1").ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0]["code"].getLength == 20);
    assert(res[0]["code"].get!string == "test-code-1         ");
    assert(res[0]["title"].get!string == "Test 1");
    assert(res[0]["description"].get!string == "Some test data should be here");
    assert(res[0]["data_int2"].get!short == 31000);
    assert(res[0]["data_int4"].get!int == 2111222333);
    assert(res[0]["data_int8"].get!long == 9223372036854775800);
    assert(res[0]["data_float"].get!string == "6.123456");
    assert(res[0]["data_float"].get!float == 6.123456f);
    assert(res[0]["data_double"].get!string == "15.12345678901234");
    assert(res[0]["data_double"].get!double == 15.12345678901234);
    assert(res[0]["data_date"].get!Date == Date(2023, 8, 2));
    assert(res[0]["data_dt"].get!DateTime == DateTime(2023, 8, 2, 23, 13, 42));
    assert(res[0]["data_dt_tz"].get!SysTime == SysTime(DateTime(2023, 8, 2, 22, 13, 42), hnsecs(1_234_560), new immutable(SimpleTimeZone)(4.hours)));
    assert(res[0]["data_dt_tz"].get!SysTime.utcOffset == 4.hours);
    assert(res[0]["data_bool"].get!bool == true);

    auto test_1_id = res[0]["id"].get!int;

    res = c.execParams("
            INSERT INTO peque_test_conv(
                code, title, description,
                data_int2, data_int4, data_int8,
                data_float, data_double,
                data_date, data_dt, data_dt_tz,
                data_bool)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            RETURNING id;
        ",
        /* --- Parameters --- */
        "test-code-2",
        "Test 2",
        "Some new test data",
        21130,
        1222333444,
        8113322445522445566,
        7.54321f,
        13.84277582775485,
        Date(2023, 8, 3),
        DateTime(2023, 8, 3, 23, 10, 42),
        SysTime(DateTime(2023, 8, 3, 22, 10, 42), hnsecs(1_234_560), new immutable(SimpleTimeZone)(4.hours)),
        false,
    ).ensureQueryOk;
    auto test_2_id = res[0]["id"].get!int;

    assert(test_2_id >= test_1_id);

    // Try to read inserted data
    res = c.execParams("SELECT * FROM peque_test_conv WHERE id = $1", test_2_id);
    assert(res.ntuples == 1);
    assert(res[0]["code"].getLength == 20);
    assert(res[0]["code"].get!string == "test-code-2         ");
    assert(res[0]["title"].get!string == "Test 2");
    assert(res[0]["description"].get!string == "Some new test data");
    assert(res[0]["data_int2"].get!short == 21130);
    assert(res[0]["data_int4"].get!int == 1222333444);
    assert(res[0]["data_int8"].get!long == 8113322445522445566);
    assert(res[0]["data_float"].get!string == "7.54321");
    assert(res[0]["data_float"].get!float == 7.54321f);
    assert(res[0]["data_double"].get!string == "13.84277582775485");
    assert(res[0]["data_double"].get!double == 13.84277582775485);
    assert(res[0]["data_date"].get!Date == Date(2023, 8, 3));
    assert(res[0]["data_dt"].get!DateTime == DateTime(2023, 8, 3, 23, 10, 42));
    assert(res[0]["data_dt_tz"].get!SysTime == SysTime(DateTime(2023, 8, 3, 22, 10, 42), hnsecs(1_234_560), new immutable(SimpleTimeZone)(4.hours)));
    assert(res[0]["data_dt_tz"].get!SysTime.utcOffset == 4.hours);
    assert(res[0]["data_bool"].get!bool == false);
}
