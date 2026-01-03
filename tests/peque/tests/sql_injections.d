module peque.tests.sql_injections;

private import std.process: environment;
private import std.exception: assertThrown;
private import core.exception: AssertError;

private import versioned: Version;

private import peque.connection: Connection;
private import peque.result: Result;


unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection(
            environment.get("POSTGRES_DB", "peque-test"),
            environment.get("POSTGRES_USER", "peque"),
            environment.get("POSTGRES_PASSWORD", "peque"),
            environment.get("POSTGRES_HOST", "localhost"),
            environment.get("POSTGRES_PORT", "5432"),
    );

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_test;
        CREATE TABLE peque_test (
            id      serial,
            code    varchar,
            title   varchar
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    res.ensureQueryOk;

    res = c.execParams("SELECT code, title FROM peque_test WHERE code = $1", "t1' --");
    assert(res.empty);

    res = c.execParams("SELECT code, title FROM peque_test WHERE code = $1", "' OR '1'='1");
    assert(res.empty);

    res = c.execParams("SELECT $1", "t1' --");
    assert(res[0][0].as!string == "t1' --");

    // It is not allowed to pass strings that contain nulls to SQL
    c.execParams("SELECT code, title FROM peque_test WHERE code = $1", "t1\0; Hello World").assertThrown!AssertError;
    c.execParams("SELECT $1", "t1\0; Hello World").assertThrown!AssertError;

    // This should fail on null char in string
    c.execParams(
        "INSERT INTO peque_test (code, title) VALUES ('messy', $1)",
        "Double\" Quote, Single' Quote, Backslash\\, Percent%, Underscore_, Newline\n, Tab\t, Emoji 🐇, and a NUL\0 byte.")
    .assertThrown!AssertError;

    // Try to insert messy string
    res = c.execParams(
        "INSERT INTO peque_test (code, title) VALUES ('messy', $1)",
        "Double\" Quote, Single' Quote, Backslash\\, Percent%, Underscore_, Newline\n, Tab\t, Emoji 🐇.");
    res.ensureQueryOk;

    // And ensure it is read correctly.
    res = c.execParams("SELECT title FROM peque_test WHERE code = $1", "messy");
    assert(res.ntuples == 1);
    assert(res[0][0].as!string == "Double\" Quote, Single' Quote, Backslash\\, Percent%, Underscore_, Newline\n, Tab\t, Emoji 🐇.");

    // Add few values: with percent sign and similar without percent
    res = c.execParams(
        "INSERT INTO peque_test (code, title) VALUES ('50p', $1), ('500', $2)",
        "50%", "500");
    res.ensureQueryOk;

    // Test searches for inserted value
    res = c.execParams("SELECT code FROM peque_test WHERE title = $1", "50%");
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!string == "50p");

    res = c.execParams("SELECT code FROM peque_test WHERE title = $1", "500");
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!string == "500");

    // In like expressions % sign is not escaped. And it's ok.
    res = c.execParams("SELECT code FROM peque_test WHERE title LIKE $1 ORDER BY code", "50%");
    res.ensureQueryOk;
    assert(res.ntuples == 2);
    assert(res[0][0].as!string == "500");
    assert(res[1][0].as!string == "50p");

    res = c.execParams("SELECT code FROM peque_test WHERE title LIKE $1 ORDER BY code", "500");
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!string == "500");

    // Test array handling
    res = c.execParams("SELECT $1", ["test", "t1 }, (SELECT 42));"]);
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!(string[]) == ["test", "t1 }, (SELECT 42));"]);

    res = c.execParams("SELECT $1", ["test", "t1\"XXX"]);
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!(string[]) == ["test", "t1\"XXX"]);

    res = c.execParams("SELECT $1", ["test", "t1\\XXX"]);
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!(string[]) == ["test", "t1\\XXX"]);
}

