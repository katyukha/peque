module peque.tests.json;

private import std.exception: assertThrown;
private import std.json;
private import std.process: environment;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception;


unittest {
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    // --- Reading JSON/JSONB as string (existing string converter) ---
    auto res = c.exec(`SELECT '{"key": "value"}'::json`);
    assert(res.getValue(0, 0).get!string == `{"key": "value"}`);

    res = c.exec(`SELECT '{"key": "value"}'::jsonb`);
    assert(res.getValue(0, 0).get!string == `{"key": "value"}`);

    // --- Reading JSON as JSONValue ---
    res = c.exec(`SELECT '{"key": "value"}'::json`);
    assert(!res.getValue(0, 0).isNull);
    auto jv = res.getValue(0, 0).get!JSONValue;
    assert(jv["key"].str == "value");

    // --- Reading JSONB as JSONValue ---
    res = c.exec(`SELECT '{"key": "value"}'::jsonb`);
    assert(!res.getValue(0, 0).isNull);
    jv = res.getValue(0, 0).get!JSONValue;
    assert(jv["key"].str == "value");

    // --- JSON array literal ---
    res = c.exec(`SELECT '[1, 2, 3]'::jsonb`);
    auto jarr = res.getValue(0, 0).get!JSONValue;
    assert(jarr.type == JSONType.array);
    assert(jarr.array.length == 3);
    assert(jarr[0].integer == 1);
    assert(jarr[2].integer == 3);

    // --- NULL JSON handling ---
    res = c.exec("SELECT NULL::json");
    assert(res.getValue(0, 0).isNull);
    res.getValue(0, 0).get!JSONValue.assertThrown!ConversionError;
    assert(res.getValue(0, 0).get!JSONValue(parseJSON(`{}`)).type == JSONType.object);

    // --- Writing JSONValue as a parameter ---
    res = c.execParams("SELECT $1::json", parseJSON(`{"x": 1}`)).ensureQueryOk;
    assert(res.getValue(0, 0).get!JSONValue["x"].integer == 1);

    res = c.execParams("SELECT $1::jsonb", parseJSON(`{"x": 1}`)).ensureQueryOk;
    assert(res.getValue(0, 0).get!JSONValue["x"].integer == 1);

    // --- Round-trip of various JSON primitive types ---
    foreach (src; [`42`, `true`, `false`, `null`, `"hello"`,
                   `{"nested":{"a":1}}`, `[1,"two",true,null]`]
    ) {
        res = c.execParams("SELECT $1::jsonb", parseJSON(src)).ensureQueryOk;
        auto got = res.getValue(0, 0).get!JSONValue;
        assert(parseJSON(got.toString()) == parseJSON(src),
            "round-trip failed for: " ~ src);
    }

    // --- Table round-trip ---
    c.exec("
        DROP TABLE IF EXISTS peque_test_json;
        CREATE TABLE peque_test_json (
            id serial,
            data jsonb
        );"
    ).ensureQueryOk;

    c.execParams(
        "INSERT INTO peque_test_json (data) VALUES ($1)",
        parseJSON(`{"score": 99}`)).ensureQueryOk;

    res = c.execParams(
        "SELECT data FROM peque_test_json WHERE data->>'score' = $1", "99");
    assert(res.ntuples == 1);
    assert(res[0]["data"].get!JSONValue["score"].integer == 99);

    // --- PG array of JSON → JSONValue[] ---
    res = c.exec(`SELECT ARRAY['{"a":1}'::json, '{"b":2}'::json]`).ensureQueryOk;
    auto ja = res[0][0].get!(JSONValue[]);
    assert(ja.length == 2);
    assert(ja[0]["a"].integer == 1);
    assert(ja[1]["b"].integer == 2);

    // --- JSONValue[] parameter → PG array round-trip ---
    res = c.execParams(
        "SELECT $1::json[]",
        [parseJSON(`{"x":1}`), parseJSON(`{"y":2}`)],
    ).ensureQueryOk;
    auto ja2 = res[0][0].get!(JSONValue[]);
    assert(ja2.length == 2);
    assert(ja2[0]["x"].integer == 1);
    assert(ja2[1]["y"].integer == 2);

    // --- Strings with special characters survive the JSON round-trip ---
    res = c.execParams(
        "SELECT $1::jsonb",
        parseJSON(`{"msg": "quote\"and\\slash"}`)).ensureQueryOk;
    assert(res[0][0].get!JSONValue["msg"].str == `quote"and\slash`);
}


// SQL injection tests for JSON/JSONB parameter handling
unittest {
    import core.exception: AssertError;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    c.exec("
        DROP TABLE IF EXISTS peque_json_inj;
        CREATE TABLE peque_json_inj (
            id serial,
            data jsonb
        );"
    ).ensureQueryOk;

    // Insert a known-good row used to verify injection attempts don't leak data.
    c.execParams(
        "INSERT INTO peque_json_inj (data) VALUES ($1)",
        parseJSON(`{"secret": "s3cr3t"}`),
    ).ensureQueryOk;

    // --- Injection attempt in a JSON string value used in a WHERE clause ---
    // The attack string tries to close the jsonb operator expression and add OR
    // logic. As a bound parameter it must be treated as a plain string value.
    auto injection = parseJSON(`{"key": "' OR '1'='1"}`);
    auto res = c.execParams(
        "SELECT data FROM peque_json_inj WHERE data->>'key' = $1",
        injection["key"].str
    ).ensureQueryOk;
    assert(res.empty, "injection via JSON string value must not match rows");

    // --- Classic SELECT injection embedded as a JSON value ---
    injection = parseJSON(`{"key": "x'; SELECT * FROM peque_json_inj; --"}`);
    res = c.execParams(
        "SELECT data FROM peque_json_inj WHERE data->>'key' = $1",
        injection["key"].str,
    ).ensureQueryOk;
    assert(res.empty, "injection via JSON string value must not match rows");

    // --- Injection strings stored and read back intact ---
    // Verify the raw injection text is stored verbatim and returned unchanged.
    immutable injStrings = [
        `'; DROP TABLE peque_json_inj; --`,
        `' OR '1'='1`,
        `" OR "1"="1`,
        `\'; DROP TABLE peque_json_inj; --`,
        `} , (SELECT 42) --`,
        `{"injected": true}`,
    ];
    foreach (s; injStrings) {
        auto payload = JSONValue(["attack": JSONValue(s)]);
        c.execParams(
            "INSERT INTO peque_json_inj (data) VALUES ($1)",
            payload).ensureQueryOk;

        res = c.execParams(
            "SELECT data FROM peque_json_inj WHERE data->>'attack' = $1", s);
        assert(res.ntuples == 1, "injection string not stored/retrieved correctly: " ~ s);
        assert(res[0]["data"].get!JSONValue["attack"].str == s,
            "injection string value corrupted: " ~ s);
    }

    // --- PG array syntax characters inside JSON values in a JSONValue[] ---
    // Braces, commas and quotes in JSON text must not break the PG array literal
    // built by the array converter.
    auto arrayInjection = [
        parseJSON(`{"x": "}, (SELECT 42); --"}`),
        parseJSON(`{"x": "{\"nested\": true}"}`),
        parseJSON(`{"x": "a,b,c"}`),
    ];
    res = c.execParams("SELECT $1::jsonb[]", arrayInjection).ensureQueryOk;
    auto got = res[0][0].get!(JSONValue[]);
    assert(got.length == 3);
    assert(got[0]["x"].str == `}, (SELECT 42); --`);
    assert(got[1]["x"].str == `{"nested": true}`);
    assert(got[2]["x"].str == `a,b,c`);

    // --- Null byte inside a JSONValue string is re-encoded by JSON, not passed raw ---
    // std.json encodes the D null byte (\0) as the JSON escape \u0000, so no
    // literal NUL byte reaches libpq. However, PostgreSQL's text encoding does
    // not allow \u0000 in jsonb values, so the server rejects it with an error
    // rather than peque passing a raw null byte.
    auto nullByteJson = parseJSON(`{"k": "\u0000"}`);
    c.execParams("SELECT $1::jsonb", nullByteJson).assertThrown!QueryError;
}
