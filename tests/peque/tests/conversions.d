module peque.tests.conversations;

private import std.exception;
private import std.conv;
private import std.process: environment;
private import std.math: isClose;
private import std.string: indexOf;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception;


unittest {
    import std.stdio;
    import std.typecons;
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

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

    // 7842 is too big for byte. std.conv's overflow is translated to
    // ConversionError like every other conversion failure, message preserved.
    res.getValue(0, 0).get!byte.assertThrown!ConversionError;

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
    assert(res.getValue(0, 0).get!float.isClose(0.1782788489f));
    assert(res.getValue(0, 0).get!double.isClose(0.1782788489));

    res = c.exec("SELECT 0.17827");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "0.17827");
    assert(res.getValue(0, 0).get!float.isClose(0.17827f));
    assert(res.getValue(0, 0).get!double.isClose(0.17827));

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
    // A wall clock is not an instant: naming one would mean inventing a zone.
    res.getValue(0, 0).get!SysTime.assertThrown!ConversionError;

    res = c.exec("SELECT '2023-07-17'::date;");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "2023-07-17");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));

    res = c.exec("SELECT '2023-07-17 13:42:18+05'::timestamptz;");
    assert(!res.getValue(0, 0).isNull);
    // The result is returned in connection's timezone
    assert(res.getValue(0, 0).get!string == "2023-07-17 12:42:18+04");
    // Neither Date nor DateTime can hold an instant: read into one and the
    // answer would be whatever the session TimeZone renders — a different hour
    // for DateTime, and for Date a different DAY either side of midnight.
    res.getValue(0, 0).get!Date.assertThrown!ConversionError;
    res.getValue(0, 0).get!DateTime.assertThrown!ConversionError;
    // A SysTime always comes back in UTC, whatever offset the server rendered.
    // The expected values below name the same instant in the session's offset;
    // opEquals compares instants, so the zone they carry is irrelevant.
    assert(res.getValue(0, 0).get!SysTime == SysTime(DateTime(2023, 7, 17, 12, 42, 18), new immutable(SimpleTimeZone)(4.hours)));
    assert(res.getValue(0, 0).get!SysTime.utcOffset == Duration.zero);

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
    // Array elements carry no OID, so the offset in the rendering is what the
    // converter goes on — refused there exactly as in the scalar case.
    res[0][0].get!(Date[]).assertThrown!ConversionError;
    res[0][0].get!(DateTime[]).assertThrown!ConversionError;
    assert(res[0][0].get!(SysTime[]) == [
        SysTime(DateTime(2023, 8, 17, 7, 9, 10), new immutable(SimpleTimeZone)(4.hours)),
        SysTime(DateTime(2023, 9, 12, 10, 12, 13), new immutable(SimpleTimeZone)(4.hours)),
    ]);
    assert(res[0][0].get!string == "{\"2023-08-17 07:09:10+04\",\"2023-09-12 10:12:13+04\"}");

    /// Incorrect query
    c.exec("SELECT '2023-07'::date;").assertThrown!QueryError;

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

    // round(v, n) exists only for numeric — float params now arrive as
    // float4/float8 and need an explicit cast
    res = c.execParams("SELECT round($1::numeric,10)", 0.1782788489);
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!float.isClose(0.1782788489f));
    assert(res.getValue(0, 0).get!double.isClose(0.1782788489));
    assert(res.getValue(0, 0).get!string == "0.1782788489");

    res = c.execParams("SELECT round($1::numeric, 5)", 0.17827f);
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!float.isClose(0.1782700000f));
    assert(res.getValue(0, 0).get!double.isClose(0.1782700000));
    assert(res.getValue(0, 0).get!string == "0.17827");

    res = c.execParams("SELECT $1::timestamp", Date(2023, 7, 17)).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "2023-07-17 00:00:00");
    assert(res.getValue(0, 0).get!Date == Date(2023, 7, 17));
    assert(res.getValue(0, 0).get!DateTime == DateTime(2023, 7, 17, 0, 0, 0));

    /// Test array conversions
    res = c.execParams("SELECT $1::int[]", [1, 2, 3, 4, 5]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{1,2,3,4,5}");
    assert(res.getValue(0, 0).get!(int[]) == [1, 2, 3, 4, 5]);

    res = c.execParams("SELECT $1::boolean[]", [true, false]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{t,f}");
    assert(res.getValue(0, 0).get!(bool[]) == [true, false]);

    res = c.execParams("SELECT $1::int[]", [1, 2, 3, 4]).ensureQueryOk;
    assert(res[0][0].get!(int[]) == [1, 2, 3, 4]);
    assert(res[0][0].get!string == "{1,2,3,4}");

    res = c.execParams("SELECT $1::float[]", [1.1f, 2.2f, 3.3f, 4.4f]).ensureQueryOk;
    assert(res[0][0].get!(float[]) == [1.1f, 2.2f, 3.3f, 4.4f]);

    res = c.execParams("SELECT $1::text[]", ["str1", "str2"]).ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["str1", "str2"]);
    assert(res[0][0].get!string == "{str1,str2}");

    res = c.execParams("SELECT $1::text[]", ["str1,24", "str2 \"78\"", "back\\slashed", "simple"]).ensureQueryOk;
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
    // Array elements carry no OID, so the offset in the rendering is what the
    // converter goes on — refused there exactly as in the scalar case.
    res[0][0].get!(Date[]).assertThrown!ConversionError;
    res[0][0].get!(DateTime[]).assertThrown!ConversionError;
    assert(res[0][0].get!(SysTime[]) == [
        SysTime(DateTime(2023, 8, 17, 7, 9, 10), new immutable(SimpleTimeZone)(4.hours)),
        SysTime(DateTime(2023, 9, 12, 10, 12, 13), new immutable(SimpleTimeZone)(4.hours)),
    ]);
    assert(res[0][0].get!string == "{\"2023-08-17 07:09:10+04\",\"2023-09-12 10:12:13+04\"}");

    // Multi-dimensional arrays: they round-trip as text, but decoding into a
    // nested D array is not supported and is rejected rather than mis-parsed.
    res = c.execParams("SELECT $1::int[][]", [[1, 2], [3, 4]]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{{1,2},{3,4}}");
    res.getValue(0, 0).get!(int[][]).assertThrown!ConversionError;

    res = c.execParams("SELECT $1::int[][][]", [[[1, 2], [3, 4]], [[6, 7], [8, 9]]]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{{{1,2},{3,4}},{{6,7},{8,9}}}");
    res.getValue(0, 0).get!(int[][][]).assertThrown!ConversionError;

    res = c.execParams("SELECT $1::text[][]", [["t1", "t2"], ["t3", "t,4"]]).ensureQueryOk;
    assert(res.getValue(0, 0).get!string == "{{t1,t2},{t3,\"t,4\"}}");
}


// ---------------------------------------------------------------------------
// Integer boundary values
// ---------------------------------------------------------------------------

unittest {
    import std.datetime;
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // int (int4) boundaries
    auto res = c.execParams("SELECT $1::int4", int.min).ensureQueryOk;
    assert(res[0][0].get!int == int.min);

    res = c.execParams("SELECT $1::int4", int.max).ensureQueryOk;
    assert(res[0][0].get!int == int.max);

    // long (int8) boundaries
    res = c.execParams("SELECT $1::int8", long.min).ensureQueryOk;
    assert(res[0][0].get!long == long.min);

    res = c.execParams("SELECT $1::int8", long.max).ensureQueryOk;
    assert(res[0][0].get!long == long.max);
}


// ---------------------------------------------------------------------------
// Floating-point special values: NaN and Infinity
// ---------------------------------------------------------------------------

unittest {
    import std.math: isNaN, isInfinity;

    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    auto res = c.exec("SELECT 'NaN'::float8").ensureQueryOk;
    assert(res[0][0].get!double.isNaN, "NaN must round-trip as NaN");
    assert(res[0][0].get!string == "NaN");

    res = c.exec("SELECT 'Infinity'::float8").ensureQueryOk;
    assert(res[0][0].get!double.isInfinity, "Infinity must round-trip as infinity");
    assert(res[0][0].get!double > 0, "Infinity must be positive");

    res = c.exec("SELECT '-Infinity'::float8").ensureQueryOk;
    assert(res[0][0].get!double.isInfinity, "-Infinity must round-trip as infinity");
    assert(res[0][0].get!double < 0, "-Infinity must be negative");

    // Round-trip through execParams
    res = c.execParams("SELECT $1::float8", double.nan).ensureQueryOk;
    assert(res[0][0].get!double.isNaN, "NaN parameter must round-trip as NaN");

    res = c.execParams("SELECT $1::float8", double.infinity).ensureQueryOk;
    assert(res[0][0].get!double.isInfinity && res[0][0].get!double > 0);

    res = c.execParams("SELECT $1::float8", -double.infinity).ensureQueryOk;
    assert(res[0][0].get!double.isInfinity && res[0][0].get!double < 0);
}


// ---------------------------------------------------------------------------
// Floating-point exact round-trip: tiny magnitudes and full double precision
// ---------------------------------------------------------------------------

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // Fixed-point formatting zeroes values below ~5e-21
    auto res = c.execParams("SELECT $1::float8", 1.5e-25).ensureQueryOk;
    assert(res[0][0].get!double == 1.5e-25);

    // smallest subnormal double — spelled via nextUp(0.0) because ldc2's
    // lexer rejects the 4.9e-324 literal as "not representable"
    import std.math: nextUp;
    immutable minSub = nextUp(0.0);
    res = c.execParams("SELECT $1::float8", -minSub).ensureQueryOk;
    assert(res[0][0].get!double == -minSub);

    // Full 17-significant-digit precision must survive the round-trip
    res = c.execParams("SELECT $1::float8", 1.2345678901234567e-10).ensureQueryOk;
    assert(res[0][0].get!double == 1.2345678901234567e-10);

    res = c.execParams("SELECT $1::float8", double.max).ensureQueryOk;
    assert(res[0][0].get!double == double.max);

    res = c.execParams("SELECT $1::float4", 1.1754944e-38f).ensureQueryOk;
    assert(res[0][0].get!float == 1.1754944e-38f);
}


// ---------------------------------------------------------------------------
// Declared parameter OIDs: server must see native integer/float types,
// not NUMERIC (which would defeat btree indexes on integer columns)
// ---------------------------------------------------------------------------

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    static string typeOf(P)(ref Connection c, P param) {
        return c.execParams("SELECT pg_typeof($1)::text", param)
                .getValue(0, 0).get!string;
    }

    assert(typeOf(c, short(1))  == "smallint");
    assert(typeOf(c, 1)         == "integer");
    assert(typeOf(c, 1L)        == "bigint");
    assert(typeOf(c, 1uL)       == "numeric");  // exceeds bigint range
    assert(typeOf(c, 1.0f)      == "real");
    assert(typeOf(c, 1.0)       == "double precision");
    assert(typeOf(c, [1, 2])    == "integer[]");
    assert(typeOf(c, [1.0])     == "double precision[]");
}


// ---------------------------------------------------------------------------
// Arrays: empty array and NULL element
// ---------------------------------------------------------------------------

unittest {
    import std.typecons: Nullable, nullable;
    import peque.exception: ConversionError;

    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // Empty array: must decode to an empty D slice, not throw.
    auto res = c.execParams("SELECT $1::int[]", cast(int[])[]).ensureQueryOk;
    assert(res[0][0].get!(int[]) == [], "empty int array must decode to []");

    res = c.exec("SELECT ARRAY[]::text[]").ensureQueryOk;
    assert(res[0][0].get!(string[]) == [], "empty text array must decode to []");

    // NULL element in a non-nullable array: rejected loudly with
    // ConversionError — never a raw ConvException, and never the silent
    // literal "NULL" string.
    c.exec("SELECT ARRAY[1,NULL,3]::int[]")
        .ensureQueryOk
        [0][0].get!(int[])
        .assertThrown!ConversionError;
    c.exec("SELECT ARRAY['a',NULL,'b']::text[]")
        .ensureQueryOk
        [0][0].get!(string[])
        .assertThrown!ConversionError;

    // NULL element in a Nullable!U[] array: decodes to an empty element.
    res = c.exec("SELECT ARRAY[1,NULL,3]::int[]").ensureQueryOk;
    auto ints = res[0][0].get!(Nullable!int[]);
    assert(ints.length == 3);
    assert(ints[0] == 1.nullable && ints[1].isNull && ints[2] == 3.nullable,
        "NULL in a Nullable!int[] must decode to an empty element");

    res = c.exec("SELECT ARRAY['a',NULL,'b']::text[]").ensureQueryOk;
    auto strs = res[0][0].get!(Nullable!string[]);
    assert(strs.length == 3);
    assert(strs[0] == "a".nullable && strs[1].isNull && strs[2] == "b".nullable);

    // A *quoted* "NULL" is the literal string, distinct from a SQL NULL.
    res = c.exec("SELECT ARRAY['NULL','b']::text[]").ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["NULL", "b"],
        "quoted NULL must stay the literal string \"NULL\"");
}


// ---------------------------------------------------------------------------
// Arrays: empty-string elements must not crash the parser
// ---------------------------------------------------------------------------

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // A leading empty-string element triggers &tmp_value[0] when tmp_value
    // is empty because the quoted value "" produces no characters.
    auto res = c.exec("SELECT ARRAY['', 'b', '']::text[]").ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["", "b", ""],
        "array with empty-string elements must decode correctly");

    // Single empty element — smallest reproducer.
    res = c.exec("SELECT ARRAY['']::text[]").ensureQueryOk;
    assert(res[0][0].get!(string[]) == [""]);
}


// ---------------------------------------------------------------------------
// UUID round-trip
// ---------------------------------------------------------------------------

unittest {
    import std.uuid: UUID;

    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    auto id = UUID("550e8400-e29b-41d4-a716-446655440000");

    // send as $1, receive as uuid
    auto res = c.execParams("SELECT $1::uuid", id).ensureQueryOk;
    assert(res[0][0].get!UUID == id);
    assert(res[0][0].get!string == "550e8400-e29b-41d4-a716-446655440000");

    // server-generated UUID must parse back to UUID
    res = c.exec("SELECT gen_random_uuid()").ensureQueryOk;
    auto generated = res[0][0].get!UUID;
    assert(generated != UUID.init);
}


// Converting a value whose pg type cannot map to the requested D type must
// throw ConversionError — an assert(0) here would be UB under -release.
unittest {
    import std.datetime;
    import peque.exception: ConversionError;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    auto res = c.exec("SELECT 42;");
    res.getValue(0, 0).get!Date.assertThrown!ConversionError;
}


/// Example of read / write different field types from / to table
unittest {
    import std.datetime;
    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

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
    assert(res[0]["data_dt_tz"].get!SysTime.utcOffset == Duration.zero);
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
    assert(res[0]["data_dt_tz"].get!SysTime.utcOffset == Duration.zero);
    assert(res[0]["data_bool"].get!bool == false);
}


// ---------------------------------------------------------------------------
// Floats: server round-trip of extreme magnitudes and `real` (NUMERIC)
// ---------------------------------------------------------------------------
unittest {
    import std.math: nextUp;

    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // Extreme doubles through float8: subnormal, max, tiny. Compare the
    // server's text (shortest exact form, PG >= 12) — parse-free, so the
    // check is independent of std.conv parse accuracy on this platform.
    import std.typecons: tuple;
    foreach (t; [tuple(nextUp(0.0),        "5e-324"),
                 tuple(double.max,         "1.7976931348623157e+308"),
                 tuple(double.min_normal,  "2.2250738585072014e-308"),
                 tuple(1.5e-25,            "1.5e-25")])
        assert(c.execParams("SELECT $1::float8", t[0]).ensureQueryOk
            [0][0].get!string == t[1]);

    // Parsed round-trip: result parsing is correctly rounded on every
    // platform, so extreme values recover exactly.
    foreach (v; [nextUp(0.0), double.max, double.min_normal, 1.5e-25])
        assert(c.execParams("SELECT $1::float8", v).ensureQueryOk
            [0][0].get!double == v);
    assert(c.execParams("SELECT $1::float4", 1.1754944e-38f).ensureQueryOk
        [0][0].get!float == 1.1754944e-38f);

    // real goes through NUMERIC (FLOAT8 where real == double): the server
    // must accept the emitted text and return the digits.
    auto res = c.execParams("SELECT $1::numeric", 3.14L).ensureQueryOk;
    assert(res[0][0].get!real == 3.14L);
}


// ---------------------------------------------------------------------------
// NUMERIC with far more digits than the target float type holds
// ---------------------------------------------------------------------------
unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // 100 fractional digits → correctly rounded through the long-digit path.
    assert(c.exec("SELECT round(2::numeric / 3, 100)").ensureQueryOk
        [0][0].get!double == 2.0 / 3.0);
    assert(c.exec("SELECT round(2::numeric / 3, 100)").ensureQueryOk
        [0][0].get!float == 2.0f / 3.0f);

    // 51 integer digits; +1 is far below the double spacing at 1e50.
    assert(c.exec("SELECT 10::numeric ^ 50 + 1").ensureQueryOk
        [0][0].get!double == 1e50);
}


// ---------------------------------------------------------------------------
// const / immutable parameters
// ---------------------------------------------------------------------------

// The trait-based constraints (isIntegral, isSomeString, …) accept a qualified
// type already; the hand-written ones did not, so `is(T == DateTime)` was false
// for immutable(DateTime) and the value matched no overload at all.
unittest {
    import std.datetime;
    import std.json: JSONValue, parseJSON;
    import std.uuid: UUID, randomUUID;
    import std.typecons: Nullable;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec(`SET TimeZone = 'UTC'`);

    immutable d  = Date(2026, 8, 26);
    immutable dt = DateTime(2026, 8, 26, 9, 30, 0);
    immutable st = SysTime(DateTime(2026, 8, 26, 9, 30, 0), UTC());
    immutable u  = randomUUID;
    immutable n  = 42;
    const     j  = parseJSON(`{"a": 1}`);
    const     ns = Nullable!int(7);
    immutable arr = [Date(2026, 8, 26), Date(2026, 8, 27)];

    assert(c.execParams("SELECT $1::date",        d ).getValue!Date(0, 0)     == d);
    assert(c.execParams("SELECT $1::timestamp",   dt).getValue!DateTime(0, 0) == dt);
    assert(c.execParams("SELECT $1::timestamptz", st).getValue!SysTime(0, 0)  == st);
    assert(c.execParams("SELECT $1::uuid",        u ).getValue!UUID(0, 0)     == u);
    assert(c.execParams("SELECT $1::int",         n ).getValue!int(0, 0)      == n);
    assert(c.execParams("SELECT $1::jsonb",       j ).getValue!JSONValue(0, 0) == j);
    assert(c.execParams("SELECT $1::int",         ns).getValue!int(0, 0)      == 7);
    assert(c.execParams("SELECT $1::date[]",      arr).getValue!(Date[])(0, 0) == arr);

    // An empty Nullable still has to reach the server as SQL NULL.
    const Nullable!int empty;
    assert(c.execParams("SELECT $1::int", empty).getValue(0, 0).isNull);
}


// ---------------------------------------------------------------------------
// Every SysTime comes back in UTC
// ---------------------------------------------------------------------------

// The instant is what peque guarantees; the attached zone is a rendering
// detail, and it follows one rule so two rows of a result set cannot print in
// different zones. Nothing here can be caught by an equality assertion —
// opEquals compares stdTime — so a parser returning the session's offset on the
// ordinary path and UTC on the local-mean-time and BC ones passes every other
// test in this file.
unittest {
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    static void mustBeUtc(SysTime t, string what) {
        assert(t.timezone is UTC(), what ~ " came back in " ~ t.timezone.name ~
               " (offset " ~ t.utcOffset.toString ~ "), not UTC");
    }

    foreach (tz; ["UTC", "Europe/Kyiv", "America/New_York", "Asia/Kolkata"]) {
        c.exec(`SET TimeZone = '` ~ tz ~ `'`);

        // Whole-hour, whole-minute and half-hour offsets all take the ordinary
        // path through std.datetime's parser.
        mustBeUtc(c.exec(`SELECT '2026-08-26 09:00:00+00'::timestamptz`)
                   .getValue!SysTime(0, 0), "a modern timestamp under " ~ tz);

        // Pre-1880s values are rendered in local mean time, whose offset carries
        // SECONDS, and a negative one pushes year 1 into the BC era. Both take
        // the hand-rolled path, so it has to reach the same rule.
        mustBeUtc(c.exec(`SELECT '1883-11-18 12:00:00+00'::timestamptz`)
                   .getValue!SysTime(0, 0), "an 1883 timestamp under " ~ tz);
        mustBeUtc(c.exec(`SELECT '0001-01-01 00:00:00+00'::timestamptz`)
                   .getValue!SysTime(0, 0), "year 1 under " ~ tz);

        // Array elements decode through the same parser.
        mustBeUtc(c.exec(`SELECT ARRAY['2026-08-26 09:00:00+00'::timestamptz]`)
                   .getValue!(SysTime[])(0, 0)[0], "an array element under " ~ tz);

        // …and so do the infinity sentinels.
        mustBeUtc(c.exec(`SELECT 'infinity'::timestamptz`).getValue!SysTime(0, 0),
                  "infinity under " ~ tz);
    }

    // Rendering in a zone is the caller's explicit step, and still exact.
    c.exec(`SET TimeZone = 'UTC'`);
    auto ts = c.exec(`SELECT '2026-08-26 09:00:00+00'::timestamptz`).getValue!SysTime(0, 0);
    auto kyiv = ts.toOtherTZ(PosixTimeZone.getTimeZone("Europe/Kyiv"));
    assert(kyiv == ts);                       // same instant
    assert(kyiv.hour == 12);                  // rendered at +03
}


// ---------------------------------------------------------------------------
// A zone is never invented, and never discarded
// ---------------------------------------------------------------------------

// The rule the temporal conversions follow: peque returns what the value
// contains, possibly less, but never more — and it never guesses a zone. The
// alternative to each refusal below is a silent wrong answer.
unittest {
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec(`SET TimeZone = 'Europe/Kyiv'`);   // deliberately not UTC

    // Exact correspondences still work.
    assert(c.exec(`SELECT '2023-08-17'::date`).getValue!Date(0, 0) == Date(2023, 8, 17));
    assert(c.exec(`SELECT '2023-08-17 08:09:10'::timestamp`).getValue!DateTime(0, 0)
           == DateTime(2023, 8, 17, 8, 9, 10));
    assert(c.exec(`SELECT '2023-08-17 08:09:10+00'::timestamptz`).getValue!SysTime(0, 0)
           == SysTime(DateTime(2023, 8, 17, 8, 9, 10), UTC()));

    // Returning LESS than the value holds is fine: the date of a wall clock is
    // in the value, and no zone is involved.
    assert(c.exec(`SELECT '2023-08-17 08:09:10'::timestamp`).getValue!Date(0, 0)
           == Date(2023, 8, 17));

    // Returning MORE is not: midnight and a zone are both inventions.
    c.exec(`SELECT '2023-08-17'::date`).getValue!DateTime(0, 0).assertThrown!ConversionError;
    c.exec(`SELECT '2023-08-17'::date`).getValue!SysTime(0, 0).assertThrown!ConversionError;
    c.exec(`SELECT '2023-08-17 08:09:10'::timestamp`)
        .getValue!SysTime(0, 0).assertThrown!ConversionError;

    // Nor is discarding a zone, whose absence changes the answer by an hour
    // (DateTime) or a whole day (Date).
    c.exec(`SELECT '2023-08-17 08:09:10+00'::timestamptz`)
        .getValue!DateTime(0, 0).assertThrown!ConversionError;
    c.exec(`SELECT '2023-08-17 08:09:10+00'::timestamptz`)
        .getValue!Date(0, 0).assertThrown!ConversionError;

    // Array elements arrive without an OID, so the rendering carries the
    // decision. Choosing by string length (`length == 19`) misreads a naive
    // value WITH fractional seconds as local time, and rejects "infinity" as
    // too short.
    c.exec(`SELECT ARRAY['2023-08-17 08:09:10'::timestamp]`)
        .getValue!(SysTime[])(0, 0).assertThrown!ConversionError;
    c.exec(`SELECT ARRAY['2023-08-17 08:09:10.5'::timestamp]`)
        .getValue!(SysTime[])(0, 0).assertThrown!ConversionError;

    assert(c.exec(`SELECT ARRAY['infinity'::timestamptz]`).getValue!(SysTime[])(0, 0)
           == [SysTime.max]);
    assert(c.exec(`SELECT ARRAY['2023-08-17 08:09:10.5+00'::timestamptz]`)
               .getValue!(SysTime[])(0, 0)
           == [SysTime(DateTime(2023, 8, 17, 8, 9, 10), msecs(500), UTC())]);

    // Every refusal names the way out, not just the failure.
    import std.algorithm.searching: canFind;
    auto e = collectException!ConversionError(
        c.exec(`SELECT '2023-08-17 08:09:10'::timestamp`).getValue!SysTime(0, 0));
    assert(e !is null && e.msg.canFind("DateTime"), e is null ? "" : e.msg);

    c.exec(`SET TimeZone = 'UTC'`);
}


// ---------------------------------------------------------------------------
// Dates at the ends of the calendar: BC, and years past 9999
// ---------------------------------------------------------------------------

// peque could READ both long before it could write either: D's ISO output is
// not what PostgreSQL parses at the ends of the range. "-0001-06-15" is rejected
// outright (PostgreSQL counts BC from 1 and wants "0002-06-15 BC"), and the
// leading sign of "+12345-01-01" is read as the start of a UTC offset.
unittest {
    import std.datetime;
    import std.conv: to;         // std.datetime brings its own `to` into scope

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec(`SET TimeZone = 'UTC'`);

    // The boundary is year 1 -> year 0 (= 1 BC) -> year -1 (= 2 BC), and D's
    // rendering changes shape at 9999 -> 10000. Cover both sides of each.
    // -4712 is PostgreSQL's floor: it stores back to 4713 BC, and D year -4712
    // IS 4713 BC. One lower and the server answers "date out of range".
    foreach (y; [-4712, -44, -1, 0, 1, 44, 1999, 9999, 10_000, 12_345, 32_767]) {
        auto d = Date(y, 6, 15);
        assert(c.execParams(`SELECT $1::date`, d).getValue!Date(0, 0) == d,
               "date round-trip failed for year " ~ y.to!string);

        auto dt = DateTime(y, 6, 15, 8, 30, 45);
        assert(c.execParams(`SELECT $1::timestamp`, dt).getValue!DateTime(0, 0) == dt,
               "timestamp round-trip failed for year " ~ y.to!string);

        // SysTime counts hnsecs in a long, so its range (±29227) is narrower
        // than Date/DateTime's (a short year, ±32767). Past that it wraps
        // SILENTLY — a Phobos limit, not peque's, but it means the widest years
        // are testable only for the two calendar types.
        if (y >= -29_000 && y <= 29_000) {
            auto st = SysTime(DateTime(y, 6, 15, 8, 30, 45), UTC());
            assert(c.execParams(`SELECT $1::timestamptz`, st).getValue!SysTime(0, 0) == st,
                   "timestamptz round-trip failed for year " ~ y.to!string);
        }
    }

    // The server agrees about which era each one is: D year 0 is 1 BC, and D
    // year -44 is 45 BC — off-by-one here is the classic way to lose a year.
    assert(c.execParams(`SELECT $1::date::text`, Date(0, 6, 15)).getValue!string(0, 0)
           == "0001-06-15 BC");
    assert(c.execParams(`SELECT $1::date::text`, Date(-44, 3, 15)).getValue!string(0, 0)
           == "0045-03-15 BC");
    assert(c.execParams(`SELECT $1::date::text`, Date(1, 6, 15)).getValue!string(0, 0)
           == "0001-06-15");

    // Fractional seconds survive alongside the era suffix.
    auto frac = SysTime(DateTime(-1, 6, 15, 8, 0, 0), usecs(123_456), UTC());
    assert(c.execParams(`SELECT $1::timestamptz`, frac).getValue!SysTime(0, 0) == frac);

    // A value written under one session zone still means the same instant when
    // read under another — BC does not get its own rules.
    auto bc = SysTime(DateTime(-1, 6, 15, 8, 0, 0), UTC());
    foreach (tz; ["UTC", "Europe/Kyiv", "America/New_York"]) {
        c.exec(`SET TimeZone = '` ~ tz ~ `'`);
        assert(c.execParams(`SELECT $1::timestamptz`, bc).getValue!SysTime(0, 0) == bc,
               "BC instant moved under TimeZone=" ~ tz);
    }
    c.exec(`SET TimeZone = 'UTC'`);
}


// ---------------------------------------------------------------------------
// The session TimeZone must not be able to change what a value MEANS
// ---------------------------------------------------------------------------

// A SysTime is an instant: writing one and reading it back must produce the
// same instant whatever the session TimeZone, and whatever zone the D value
// carries. LocalTime() is the case that matters — SysTime.toString omits the
// UTC offset for it, so without the .toUTC normalisation Clock.currTime goes
// out as a naked wall clock and PostgreSQL reads it in the session zone.
unittest {
    import std.datetime;
    import std.algorithm.searching: canFind;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec(`DROP TABLE IF EXISTS peque_tz_session`);
    c.exec(`CREATE TABLE peque_tz_session (id serial PRIMARY KEY, ts timestamptz)`);

    // The same instant, expressed in four different ways on the D side.
    auto instant = SysTime(DateTime(2026, 8, 26, 9, 0, 0), UTC());
    auto values = [
        "LocalTime"  : instant.toLocalTime,
        "UTC"        : instant,
        "+03:00"     : instant.toOtherTZ(new immutable SimpleTimeZone(3.hours)),
        "-04:30"     : instant.toOtherTZ(new immutable SimpleTimeZone(-270.minutes)),
    ];

    foreach (sessionTz; ["UTC", "Europe/Kyiv", "America/New_York", "Asia/Kolkata"]) {
        c.exec(`SET TimeZone = '` ~ sessionTz ~ `'`);
        foreach (label, v; values) {
            c.exec(`DELETE FROM peque_tz_session`);
            c.execParams(`INSERT INTO peque_tz_session (ts) VALUES ($1)`, v);
            auto got = c.exec(`SELECT ts FROM peque_tz_session`).getValue!SysTime(0, 0);
            assert(got == instant,
                   "instant changed: value in " ~ label ~ " under TimeZone=" ~
                   sessionTz ~ " came back as " ~ got.toUTC.toISOExtString);
        }
    }

    // Reading is equally session-independent for SysTime: the wall clock the
    // server renders differs, the instant does not.
    c.exec(`DELETE FROM peque_tz_session`);
    c.execParams(`INSERT INTO peque_tz_session (ts) VALUES ($1)`, instant);
    foreach (sessionTz; ["UTC", "Europe/Kyiv", "America/New_York"]) {
        c.exec(`SET TimeZone = '` ~ sessionTz ~ `'`);
        assert(c.exec(`SELECT ts FROM peque_tz_session`).getValue!SysTime(0, 0) == instant);
    }

    // …but a DateTime cannot represent it, and says so rather than guessing.
    foreach (sessionTz; ["UTC", "Europe/Kyiv"]) {
        c.exec(`SET TimeZone = '` ~ sessionTz ~ `'`);
        auto res = c.exec(`SELECT ts FROM peque_tz_session`);
        res.getValue!DateTime(0, 0).assertThrown!ConversionError;

        // The message has to name the remedy, not just the failure: this is
        // the one conversion error a user is likely to hit on a working query.
        auto e = collectException!ConversionError(res.getValue!DateTime(0, 0));
        assert(e !is null);
        assert(e.msg.canFind("SysTime"), e.msg);
    }

    // A zoneless `timestamp` column is a wall clock, and DateTime is the right
    // type for it — that path must keep working.
    c.exec(`DROP TABLE IF EXISTS peque_tz_naive`);
    c.exec(`CREATE TABLE peque_tz_naive (id serial PRIMARY KEY, ts timestamp)`);
    auto wall = DateTime(2026, 8, 26, 9, 0, 0);
    foreach (sessionTz; ["UTC", "Europe/Kyiv", "America/New_York"]) {
        c.exec(`SET TimeZone = '` ~ sessionTz ~ `'`);
        c.exec(`DELETE FROM peque_tz_naive`);
        c.execParams(`INSERT INTO peque_tz_naive (ts) VALUES ($1)`, wall);
        assert(c.exec(`SELECT ts FROM peque_tz_naive`).getValue!DateTime(0, 0) == wall,
               "a wall clock must survive TimeZone=" ~ sessionTz);
    }

    c.exec(`SET TimeZone = 'UTC'`);
    c.exec(`DROP TABLE IF EXISTS peque_tz_session`);
    c.exec(`DROP TABLE IF EXISTS peque_tz_naive`);
}


// ---------------------------------------------------------------------------
// Pinning the session TimeZone at connect
// ---------------------------------------------------------------------------

// What pinning buys is reproducible server-side RENDERING. What it must not be
// needed for is the meaning of a value, which the converters keep
// session-independent on their own.
unittest {
    import std.datetime;
    import std.algorithm.searching: canFind;

    string[string] baseParams = [
        "dbname":   environment.get("POSTGRES_DB",       "peque-test"),
        "user":     environment.get("POSTGRES_USER",     "peque"),
        "password": environment.get("POSTGRES_PASSWORD", "peque"),
        "host":     environment.get("POSTGRES_HOST",     "localhost"),
        "port":     environment.get("POSTGRES_PORT",     "5432"),
    ];

    // (1) alongside the params map — the path a pool factory and
    // connectViaEnvParams take. It is a separate argument, not an entry in the
    // map: everything in the map goes to libpq untouched, and libpq rejects
    // keywords it does not know.
    foreach (tz; ["UTC", "Europe/Kyiv", "America/New_York", "Asia/Kolkata"]) {
        auto c = Connection(baseParams, tz);
        assert(c.exec(`SHOW TimeZone`).getValue!string(0, 0) == tz);
    }

    // A libpq keyword peque does not know is still libpq's business, and a
    // peque setting must not be smuggled through the map.
    assertThrown!ConnectionError(Connection(() {
        auto p = baseParams.dup;
        p["timezone"] = "UTC";        // not a libpq keyword
        return p;
    }()));

    // (2) via the named parameter on the convenience constructor.
    auto c = Connection(
            dbname:   baseParams["dbname"],
            user:     baseParams["user"],
            password: baseParams["password"],
            host:     baseParams["host"],
            port:     baseParams["port"],
            timezone: "Europe/Kyiv");
    assert(c.exec(`SHOW TimeZone`).getValue!string(0, 0) == "Europe/Kyiv");

    // Rendering now follows the pinned zone…
    assert(c.exec(`SELECT '2026-08-26 09:00:00+00'::timestamptz::text`)
            .getValue!string(0, 0).canFind("12:00:00+03"));

    // …while the value itself did not move: a SysTime is an instant either way.
    auto instant = SysTime(DateTime(2026, 8, 26, 9, 0, 0), UTC());
    assert(c.execParams(`SELECT $1::timestamptz`, instant)
            .getValue!SysTime(0, 0) == instant);

    // (3) via the conninfo-string constructor.
    auto viaStr = Connection(
        "host=" ~ baseParams["host"] ~ " port=" ~ baseParams["port"] ~
        " dbname=" ~ baseParams["dbname"] ~ " user=" ~ baseParams["user"] ~
        " password=" ~ baseParams["password"],
        "Asia/Kolkata");
    assert(viaStr.exec(`SHOW TimeZone`).getValue!string(0, 0) == "Asia/Kolkata");

    // Omitting it changes nothing about how peque behaves — that is the point
    // of the converters being session-independent — so a connection without the
    // parameter still round-trips the same instant.
    auto plain = Connection(baseParams);
    assert(plain.execParams(`SELECT $1::timestamptz`, instant)
            .getValue!SysTime(0, 0) == instant);

    // An invalid zone fails at construction, naming the zone, rather than
    // leaving a connection whose rendering silently differs from the request.
    auto e = collectException!ConnectionError(Connection(baseParams, "Not/AZone"));
    assert(e !is null, "an invalid timezone must not yield a usable connection");
    assert(e.msg.canFind("Not/AZone"), e.msg);
}


// ---------------------------------------------------------------------------
// timestamptz values that PostgreSQL renders in local mean time
// ---------------------------------------------------------------------------

// The session timezone decides how a timestamptz comes back, so it is pinned
// here rather than left to the server's default: with a zone that used local
// mean time (all of them, before the 1880s) PostgreSQL emits a UTC offset with
// SECONDS, and with a negative one it also pushes year 1 into the BC era.
// Both forms are rejected by std.datetime's parser, so peque parses them
// itself — writing SysTime.init to a column is enough to produce one.
unittest {
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec(`DROP TABLE IF EXISTS peque_tz_lmt`);
    c.exec(`CREATE TABLE peque_tz_lmt (id serial PRIMARY KEY, ts timestamptz)`);

    auto historical = SysTime(DateTime(1883, 11, 18, 12, 0, 0), UTC());

    foreach (tz; ["UTC",                  // whole-hour offset
                  "Europe/Kyiv",          // LMT +02:02:04 — seconds in offset
                  "America/New_York",     // LMT -04:56:02 — seconds + BC era
                  "Asia/Kolkata"]) {      // +05:30 — whole-minute, not whole-hour
        c.exec(`SET TimeZone = '` ~ tz ~ `'`);
        c.exec(`DELETE FROM peque_tz_lmt`);
        c.execParams(`INSERT INTO peque_tz_lmt (ts) VALUES ($1)`, SysTime.init);
        c.execParams(`INSERT INTO peque_tz_lmt (ts) VALUES ($1)`, historical);

        auto rows = c.exec(`SELECT ts FROM peque_tz_lmt ORDER BY id`);
        assert(rows.getValue!SysTime(0, 0) == SysTime.init,
               "SysTime.init must round-trip under TimeZone=" ~ tz);
        assert(rows.getValue!SysTime(1, 0) == historical,
               "a pre-1880s timestamp must round-trip under TimeZone=" ~ tz);
    }

    c.exec(`SET TimeZone = 'UTC'`);
    c.exec(`DROP TABLE IF EXISTS peque_tz_lmt`);
}


// ---------------------------------------------------------------------------
// Timestamp edge values PostgreSQL produces routinely
// ---------------------------------------------------------------------------

// These share one path (_pgTimestampToISO). Before it existed, `infinity` —
// 8 bytes, shorter than a date — was sliced as if it were "YYYY-MM-DD", which
// is an Error rather than an Exception and a segfault under -release.
unittest {
    import std.datetime;
    import peque.exception: ConversionError;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );
    c.exec("SET TimeZone = 'Europe/Kyiv'");

    // Infinite sentinels map to the D type's extremes.
    assert(c.exec("SELECT 'infinity'::timestamptz").getValue!SysTime(0, 0)  == SysTime.max);
    assert(c.exec("SELECT '-infinity'::timestamptz").getValue!SysTime(0, 0) == SysTime.min);
    c.exec("SELECT 'infinity'::timestamp").getValue!SysTime(0, 0).assertThrown!ConversionError;
    assert(c.exec("SELECT 'infinity'::timestamp").getValue!DateTime(0, 0)   == DateTime.max);
    assert(c.exec("SELECT 'infinity'::date").getValue!Date(0, 0)            == Date.max);
    assert(c.exec("SELECT '-infinity'::date").getValue!Date(0, 0)           == Date.min);

    // " BC" years: PostgreSQL counts from 1, D from 0 (astronomical numbering),
    // so 44 BC is year -43. Dropping the suffix would silently return the
    // positive year.
    assert(c.exec("SELECT '0001-01-01 BC'::date").getValue!Date(0, 0)
           == Date(0, 1, 1));
    assert(c.exec("SELECT '0044-03-15 12:00:00 BC'::timestamp").getValue!DateTime(0, 0)
           == DateTime(-43, 3, 15, 12, 0, 0));
    // The BC year is decoded the same way for an instant — but it has to come
    // from a column that HAS a zone; a naive one cannot become a SysTime.
    assert(c.exec("SELECT '0044-03-15 12:00:00+00 BC'::timestamptz").getValue!SysTime(0, 0)
           == SysTime(DateTime(-43, 3, 15, 12, 0, 0), UTC()));
    c.exec("SELECT '0044-03-15 12:00:00 BC'::timestamp")
        .getValue!SysTime(0, 0).assertThrown!ConversionError;

    // D stores a year in a short, so PostgreSQL's upper range is unreachable.
    // The error must say that rather than "Invalid format".
    auto tooBig = collectException!ConversionError(
        c.exec("SELECT '294276-01-01'::timestamptz").getValue!SysTime(0, 0));
    assert(tooBig !is null);
    assert(tooBig.msg.indexOf("outside the range D can represent") >= 0, tooBig.msg);

    // Ordinary values are unaffected.
    assert(c.exec("SELECT now()").getValue!SysTime(0, 0).year >= 2020);
    c.exec("SET TimeZone = 'UTC'");
}
