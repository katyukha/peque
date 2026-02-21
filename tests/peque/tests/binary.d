module peque.tests.binary;

private import std.conv: to, ConvException;
private import std.math: isNaN, isInfinity;
private import std.datetime;
private import std.datetime.timezone: UTC;
private import std.json: JSONValue, parseJSON;
private import std.process: environment;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception;


// Helper to open a connection using env vars
private Connection openConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 1: Scalar primitives — bool, int, long, float, double
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    auto c = openConn();

    // bool
    assert(c.execParams("SELECT $1", true).ensureQueryOk[0][0].get!bool  == true);
    assert(c.execParams("SELECT $1", false).ensureQueryOk[0][0].get!bool == false);

    // byte / short → INT2
    assert(c.execParams("SELECT $1", cast(byte)42).ensureQueryOk[0][0].get!int   == 42);
    assert(c.execParams("SELECT $1", cast(short)-32768).ensureQueryOk[0][0].get!short == short.min);

    // int → INT4
    foreach (v; [0, 1, -1, int.min, int.max]) {
        auto got = c.execParams("SELECT $1", v).ensureQueryOk[0][0].get!int;
        assert(got == v, "int round-trip failed for: " ~ v.to!string);
    }

    // long → INT8
    foreach (v; [0L, 1L, -1L, long.min, long.max]) {
        auto got = c.execParams("SELECT $1", v).ensureQueryOk[0][0].get!long;
        assert(got == v, "long round-trip failed for: " ~ v.to!string);
    }

    // float → FLOAT4
    assert(c.execParams("SELECT $1", 0.0f).ensureQueryOk[0][0].get!float == 0.0f);
    assert(c.execParams("SELECT $1", 1.0f).ensureQueryOk[0][0].get!float == 1.0f);
    assert(c.execParams("SELECT $1", -1.0f).ensureQueryOk[0][0].get!float == -1.0f);
    assert(isNaN(c.execParams("SELECT $1", float.nan).ensureQueryOk[0][0].get!float));
    assert(isInfinity(c.execParams("SELECT $1", float.infinity).ensureQueryOk[0][0].get!float));
    assert(isInfinity(c.execParams("SELECT $1", -float.infinity).ensureQueryOk[0][0].get!float));

    // double → FLOAT8
    assert(c.execParams("SELECT $1", 0.0).ensureQueryOk[0][0].get!double == 0.0);
    assert(c.execParams("SELECT $1", 1.5).ensureQueryOk[0][0].get!double == 1.5);
    assert(isNaN(c.execParams("SELECT $1", double.nan).ensureQueryOk[0][0].get!double));
    assert(isInfinity(c.execParams("SELECT $1", double.infinity).ensureQueryOk[0][0].get!double));
    assert(isInfinity(c.execParams("SELECT $1", -double.infinity).ensureQueryOk[0][0].get!double));

    // Read int as string (binary INT4 → string)
    assert(c.execParams("SELECT $1::int4", 42).ensureQueryOk[0][0].get!string == "42");

    // Explicit type casts work round-trip
    assert(c.execParams("SELECT $1::int8", 9999).ensureQueryOk[0][0].get!long == 9999L);
    assert(c.execParams("SELECT $1::float8", 3.14).ensureQueryOk[0][0].get!double == 3.14);
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 2: Date / DateTime / SysTime
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    auto c = openConn();

    // Date round-trips
    foreach (d; [Date(2000, 1, 1), Date(1999, 12, 31), Date(1970, 1, 1),
                 Date(2024, 2, 29), Date(1, 1, 1), Date(9999, 12, 31)]) {
        auto got = c.execParams("SELECT $1::date", d).ensureQueryOk[0][0].get!Date;
        assert(got == d, "Date round-trip failed for: " ~ d.toISOExtString);
    }

    // DateTime round-trips
    foreach (dt; [DateTime(2000, 1, 1, 0, 0, 0),
                  DateTime(2024, 6, 15, 12, 34, 56),
                  DateTime(1999, 12, 31, 23, 59, 59)]) {
        auto got = c.execParams("SELECT $1::timestamp", dt).ensureQueryOk[0][0].get!DateTime;
        assert(got == dt, "DateTime round-trip failed for: " ~ dt.toISOExtString);
    }

    // SysTime round-trips (UTC)
    foreach (st; [SysTime(DateTime(2000, 1, 1, 0, 0, 0), UTC()),
                  SysTime(DateTime(2024, 6, 15, 12, 34, 56), UTC()),
                  SysTime(DateTime(1999, 12, 31, 23, 59, 59), UTC())]) {
        auto got = c.execParams("SELECT $1::timestamptz", st).ensureQueryOk[0][0].get!SysTime;
        // Compare with 1-second tolerance for SysTime (microsecond stored, display may vary)
        assert((got - st).abs < dur!"seconds"(1),
            "SysTime round-trip failed for: " ~ st.toString);
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 3: Unsigned integers (sent as NUMERIC text, received as NUMERIC binary)
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    auto c = openConn();

    // ubyte / ushort / uint sent as NUMERIC, returned as NUMERIC binary
    assert(c.execParams("SELECT $1", 0u).ensureQueryOk[0][0].get!uint == 0u);
    assert(c.execParams("SELECT $1", 255u).ensureQueryOk[0][0].get!uint == 255u);
    assert(c.execParams("SELECT $1", uint.max).ensureQueryOk[0][0].get!uint == uint.max);

    // ulong within safe range (fits in long)
    assert(c.execParams("SELECT $1", 0UL).ensureQueryOk[0][0].get!ulong == 0UL);
    assert(c.execParams("SELECT $1", 9_999_999_999UL).ensureQueryOk[0][0].get!ulong == 9_999_999_999UL);

    // Zero is the NUMERIC with ndigits=0 special case
    assert(c.execParams("SELECT $1::numeric", 0u).ensureQueryOk[0][0].get!uint == 0u);

    // Large multi-digit NUMERIC value
    assert(c.execParams("SELECT $1", 1_000_000u).ensureQueryOk[0][0].get!uint == 1_000_000u);
    assert(c.execParams("SELECT $1", 10_000u).ensureQueryOk[0][0].get!uint == 10_000u);
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 4: Strings and JSONValue (TEXT/JSON wire format, binary results)
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    auto c = openConn();

    // String round-trips — binary TEXT result is raw UTF-8 bytes
    foreach (s; ["", "hello", "unicode: äöü", "special: \"quotes\" and \\slashes\\"]) {
        auto got = c.execParams("SELECT $1", s).ensureQueryOk[0][0].get!string;
        assert(got == s, "String round-trip failed for: " ~ s);
    }

    // JSONValue round-trips via binary JSONB
    auto jv = parseJSON(`{"x": 1, "y": [true, null]}`);
    auto got = c.execParams("SELECT $1::jsonb", jv).ensureQueryOk[0][0].get!JSONValue;
    assert(got["x"].integer == 1);
    assert(got["y"][0].boolean == true);
    assert(got["y"][1].isNull);

    // JSON (not JSONB)
    got = c.execParams("SELECT $1::json", jv).ensureQueryOk[0][0].get!JSONValue;
    assert(got["x"].integer == 1);

    // JSON primitives
    assert(c.execParams("SELECT $1::jsonb", parseJSON("42")).ensureQueryOk[0][0].get!JSONValue.integer == 42);
    assert(c.execParams("SELECT $1::jsonb", parseJSON("true")).ensureQueryOk[0][0].get!JSONValue.boolean == true);
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 5: 1-D array round-trips
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    auto c = openConn();

    // int[] — sent as binary array, returned as binary array
    auto ia = c.execParams("SELECT $1::int4[]", [1, 2, 3]).ensureQueryOk[0][0].get!(int[]);
    assert(ia == [1, 2, 3]);

    // Boundary values in int[]
    auto ia2 = c.execParams("SELECT $1", [int.min, 0, int.max]).ensureQueryOk[0][0].get!(int[]);
    assert(ia2 == [int.min, 0, int.max]);

    // bool[]
    auto ba = c.execParams("SELECT $1", [true, false, true]).ensureQueryOk[0][0].get!(bool[]);
    assert(ba == [true, false, true]);

    // double[]
    auto da = c.execParams("SELECT $1", [1.0, 2.5, -3.14]).ensureQueryOk[0][0].get!(double[]);
    assert(da[0] == 1.0 && da[1] == 2.5 && da[2] == -3.14);

    // Date[]
    auto dates = [Date(2000, 1, 1), Date(1999, 12, 31), Date(2024, 6, 15)];
    auto dateArr = c.execParams("SELECT $1::date[]", dates).ensureQueryOk[0][0].get!(Date[]);
    assert(dateArr == dates);

    // string[] — sent as text array literal, returned as binary _TEXT array
    auto sa = c.execParams("SELECT $1", ["hello", "world"]).ensureQueryOk[0][0].get!(string[]);
    assert(sa == ["hello", "world"]);

    // string[] with special chars
    auto sa2 = c.execParams("SELECT $1",
        [`quote"d`, `back\slash`]).ensureQueryOk[0][0].get!(string[]);
    assert(sa2 == [`quote"d`, `back\slash`]);

    // JSONValue[] — sent as text array, returned as binary _JSON array
    auto ja = c.execParams("SELECT $1::json[]",
        [parseJSON(`{"a":1}`), parseJSON(`{"b":2}`)]).ensureQueryOk[0][0].get!(JSONValue[]);
    assert(ja[0]["a"].integer == 1);
    assert(ja[1]["b"].integer == 2);

    // Empty arrays
    auto emptyI = c.execParams("SELECT $1::int4[]", cast(int[])[]).ensureQueryOk[0][0].get!(int[]);
    assert(emptyI.length == 0);

    auto emptyS = c.execParams("SELECT $1", cast(string[])[]).ensureQueryOk[0][0].get!(string[]);
    assert(emptyS.length == 0);
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 6: Edge cases — NULL, table round-trip, mixed columns
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    import std.exception: assertThrown;

    auto c = openConn();

    // NULL handling: isNull still works in binary mode
    auto res = c.execParams("SELECT NULL::int4");
    assert(res[0][0].isNull);
    res[0][0].get!int.assertThrown!ConversionError;

    res = c.execParams("SELECT NULL::text");
    assert(res[0][0].isNull);

    res = c.execParams("SELECT NULL::float8");
    assert(res[0][0].isNull);

    // Default-value overload works
    assert(res[0][0].get!double(99.0) == 99.0);

    // Table round-trip with multiple column types
    c.exec("
        DROP TABLE IF EXISTS peque_test_binary;
        CREATE TABLE peque_test_binary (
            id      serial,
            ival    int4,
            fval    float8,
            bval    boolean,
            dval    date,
            tsval   timestamp,
            sval    text
        )
    ").ensureQueryOk;

    c.execParams(
        "INSERT INTO peque_test_binary (ival, fval, bval, dval, tsval, sval) " ~
        "VALUES ($1, $2, $3, $4, $5, $6)",
        42, 3.14, true, Date(2024, 6, 15),
        DateTime(2024, 6, 15, 12, 0, 0), "hello"
    ).ensureQueryOk;

    res = c.exec("SELECT ival, fval, bval, dval, tsval, sval FROM peque_test_binary");
    assert(res.ntuples == 1);
    // exec() returns text format — text converters are used
    assert(res[0][0].get!int == 42);
    assert(res[0][2].get!bool == true);
    assert(res[0][5].get!string == "hello");

    // Select back via execParams — binary results
    res = c.execParams(
        "SELECT ival, fval, bval, dval, tsval, sval FROM peque_test_binary WHERE ival = $1",
        42
    ).ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].get!int    == 42);
    assert(res[0][1].get!double == 3.14);
    assert(res[0][2].get!bool   == true);
    assert(res[0][3].get!Date   == Date(2024, 6, 15));
    assert(res[0][4].get!DateTime == DateTime(2024, 6, 15, 12, 0, 0));
    assert(res[0][5].get!string == "hello");

    // NaN and Infinity survive round-trip through a FLOAT8 column
    c.exec("DROP TABLE IF EXISTS peque_test_binary_float; " ~
           "CREATE TABLE peque_test_binary_float (v float8)").ensureQueryOk;
    c.execParams("INSERT INTO peque_test_binary_float VALUES ($1)", double.nan).ensureQueryOk;
    c.execParams("INSERT INTO peque_test_binary_float VALUES ($1)", double.infinity).ensureQueryOk;
    c.execParams("INSERT INTO peque_test_binary_float VALUES ($1)", -double.infinity).ensureQueryOk;

    res = c.execParams("SELECT v FROM peque_test_binary_float ORDER BY v NULLS LAST");
    // ORDER: -inf, nan, +inf (PostgreSQL sorts NaN as largest)
    // Actually PostgreSQL: -Inf < finite < +Inf < NaN for ORDER BY
    // Let's just check all three values are present
    double[] floatVals;
    foreach (row; res) floatVals ~= row[0].get!double;
    assert(floatVals.length == 3);
    bool hasNaN = false, hasPInf = false, hasNInf = false;
    foreach (v; floatVals) {
        if (isNaN(v)) hasNaN = true;
        else if (isInfinity(v) && v > 0) hasPInf = true;
        else if (isInfinity(v) && v < 0) hasNInf = true;
    }
    assert(hasNaN && hasPInf && hasNInf);
}


// ─────────────────────────────────────────────────────────────────────────────
// Block 7: Integer and float overflow / range errors
// ─────────────────────────────────────────────────────────────────────────────
unittest {
    import std.exception: assertThrown;

    auto c = openConn();

    // ── Integer narrowing: value does not fit in the requested D type ─────────

    // INT8 (long.max) → int: too large by far
    auto res = c.execParams("SELECT $1", long.max).ensureQueryOk;
    res[0][0].get!int.assertThrown!ConvException;
    assert(res[0][0].get!long == long.max);  // read-back as long itself is fine

    // INT8 (long.min) → int: too small
    c.execParams("SELECT $1", long.min).ensureQueryOk[0][0]
        .get!int.assertThrown!ConvException;

    // INT4 → short: int.max (2 147 483 647) overflows int16
    c.execParams("SELECT $1", int.max).ensureQueryOk[0][0]
        .get!short.assertThrown!ConvException;

    // INT4 → byte: 128 is one above byte.max (127)
    c.execParams("SELECT $1", 128).ensureQueryOk[0][0]
        .get!byte.assertThrown!ConvException;

    // INT4 → byte: -129 is one below byte.min (-128)
    c.execParams("SELECT $1", -129).ensureQueryOk[0][0]
        .get!byte.assertThrown!ConvException;

    // ── Sign mismatch: negative signed value into unsigned type ───────────────

    // -1 as uint: "−1" text cannot be parsed as unsigned
    c.execParams("SELECT $1", -1).ensureQueryOk[0][0]
        .get!uint.assertThrown!ConvException;

    // long.min as ulong: strongly negative
    c.execParams("SELECT $1", long.min).ensureQueryOk[0][0]
        .get!ulong.assertThrown!ConvException;

    // ── Unsigned NUMERIC: value exceeds target type's max ────────────────────

    // uint.max + 1 = 4_294_967_296 — sent as NUMERIC, returned as NUMERIC text
    c.execParams("SELECT $1", cast(ulong)uint.max + 1).ensureQueryOk[0][0]
        .get!uint.assertThrown!ConvException;

    // ── Float narrowing ───────────────────────────────────────────────────────

    // Server-side: PostgreSQL raises an error for out-of-range float8→float4 cast
    c.execParams("SELECT $1::float4",  1e100).assertThrown!QueryError;
    c.execParams("SELECT $1::float4", -1e100).assertThrown!QueryError;

    // Client-side: get!float on a FLOAT8 value outside float range
    // — D's to!float("1e+100") throws ConvException ("Range error")
    c.execParams("SELECT $1",  1e100).ensureQueryOk[0][0].get!float.assertThrown!ConvException;
    c.execParams("SELECT $1", -1e100).ensureQueryOk[0][0].get!float.assertThrown!ConvException;
    c.execParams("SELECT $1", double.max).ensureQueryOk[0][0].get!float.assertThrown!ConvException;
}
