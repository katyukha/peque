module peque.tests.basic;

private import std.process: environment;
private import std.exception: collectException;

private import versioned: Version;

private import peque.connection: Connection;
private import peque.result: Result;
private import peque.exception: ConnectionError;


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
            code    char(5),
            title   varchar(40)
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);

    res = c.exec("SELECT code, title FROM peque_test;");
    assert(res.cmdStatus == "SELECT 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 4);
    assert(res.nfields == 2);
    assert(res.fieldName(0).get == "code");
    assert(res.fieldName(1).get == "title");
    assert(res.fieldName(2).isNull);
    assert(res.fieldNumber("code").get == 0);
    assert(res.fieldNumber("TItle").get == 1);
    assert(res.fieldNumber("unknown").isNull);

    // Test result value access
    assert(res.getValue!string(1, 1) == "Test 2");

    res = c.exec("ALTER TABLE peque_test ADD COLUMN date TIMESTAMP;");
    assert(res.cmdStatus == "ALTER TABLE");
    assert(res.cmdTuples == 0);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);
}

// Test connection keyword arguments
unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_test;
        CREATE TABLE peque_test (
            id      serial,
            code    char(5),
            title   varchar(40)
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);
}


// Test connection env params
unittest {
    import std.typecons;
    import std.datetime;
    import peque.utils: connectViaEnvParams;

    auto c = connectViaEnvParams([
        "dbname": "peque-test",
        "user": "peque",
        "password": "peque",
        "host": "localhost",
        "port": "5432",
    ]);

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_test;
        CREATE TABLE peque_test (
            id      serial,
            code    char(5),
            title   varchar(40)
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);
}

// execMulti — returns every result from a multi-statement string
unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    auto results = c.execMulti("SELECT 1; SELECT 2; SELECT 3");
    assert(results.length == 3, "execMulti must return one Result per statement");
    assert(results[0].getValue!int(0, 0) == 1);
    assert(results[1].getValue!int(0, 0) == 2);
    assert(results[2].getValue!int(0, 0) == 3);

    // exec returns the LAST result (matching PQexec behaviour)
    auto last = c.exec("SELECT 1; SELECT 2; SELECT 3");
    assert(last.getValue!int(0, 0) == 3, "exec must return the last result");
}


// Test connection.serverVersion
unittest {
    import std.typecons;
    import std.datetime;
    import std.process: environment;
    import peque.utils: connectViaEnvParams;


    auto c = connectViaEnvParams(defaults: [
        "dbname": "peque-test",
        "user": "peque",
        "password": "peque",
        "host": "localhost",
        "port": "5432",
    ]);

    if (environment.get("PEQUE_EXPECT_PG_VERSION"))
        assert(c.serverVersion == Version(environment.get("PEQUE_EXPECT_PG_VERSION")));

}

// Test range API
unittest {
    import std.typecons;
    import std.datetime;
    import std.algorithm;
    import std.array;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_test;
        CREATE TABLE peque_test (
            id      serial,
            code    varchar(5),
            title   varchar(40)
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);

    // Test via exec
    res = c.exec("SELECT code FROM peque_test;");
    res.ensureQueryOk;
    string[] res_arr_1;
    foreach (row; res)
        res_arr_1 ~= row["code"].as!string;
    assert(res_arr_1 == ["t1", "t2", "t3", "r4"]);
    assert(res.map!((row) => row["code"].as!string).array == ["t1", "t2", "t3", "r4"]);

    // Test via execParams
    res = c.execParams("SELECT code FROM peque_test;");
    res.ensureQueryOk;
    string[] res_arr_2;
    foreach(row; res) res_arr_2 ~= row["code"].as!string;
    assert(res_arr_2 == ["t1", "t2", "t3", "r4"]);
    assert(res.map!((row) => row["code"].as!string).array == ["t1", "t2", "t3", "r4"]);

    // Test via execParams
    res = c.execParams("SELECT code FROM peque_test WHERE code in ($1, $2);", "t1", "t2");
    res.ensureQueryOk;
    string[] res_arr_3;
    foreach(row; res) res_arr_3 ~= row["code"].as!string;
    assert(res_arr_3 == ["t1", "t2"]);
    assert(res.map!((row) => row["code"].as!string).array == ["t1", "t2"]);
}


// ---------------------------------------------------------------------------
// Result range API on zero-row result — foreach must simply not iterate
// ---------------------------------------------------------------------------

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    auto res = c.exec("SELECT 1 WHERE FALSE");
    assert(res.ntuples == 0);

    int count = 0;
    foreach (row; res) count++;
    assert(count == 0, "foreach over zero-row result must not execute the body");

    // Sanity: nfields is still defined even for empty results.
    assert(res.nfields == 1);
}


// ---------------------------------------------------------------------------
// execParams with zero bound parameters
// ---------------------------------------------------------------------------

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    // No parameters at all — the variadic template must handle the empty case.
    auto res = c.execParams("SELECT 42");
    res.ensureQueryOk;
    assert(res.ntuples == 1);
    assert(res[0][0].as!int == 42, "execParams with zero params must return correct result");
}


// ---------------------------------------------------------------------------
// Out-of-range column index on a row must throw ColNotExistsError, not read
// silently as NULL (PQgetisnull returns 1 for out-of-range indices).
// ---------------------------------------------------------------------------

unittest {
    import peque.exception: ColNotExistsError;

    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );

    auto res = c.execParams("SELECT 1, 2");  // two columns: valid indices 0, 1
    res.ensureQueryOk;
    auto row = res[0];

    assert(row.nfields == 2, "ResultRow.nfields must report the column count");
    assert(row[0].as!int == 1);
    assert(row[1].as!int == 2);

    // nfields enables iterating a row's columns by index.
    int sum = 0;
    foreach (i; 0 .. row.nfields) sum += row[i].as!int;
    assert(sum == 3);

    // Out-of-range and negative indices must both throw, mirroring the
    // string-name overload and Result.getValue.
    assert(collectException!ColNotExistsError(row[2]) !is null,
        "column index past the last field must throw ColNotExistsError");
    assert(collectException!ColNotExistsError(row[-1]) !is null,
        "negative column index must throw ColNotExistsError");
}


// ---------------------------------------------------------------------------
// Connection failure: bad credentials / unreachable host throws ConnectionError
// ---------------------------------------------------------------------------

unittest {
    // Wrong password — connection must fail immediately with ConnectionError.
    auto ex = collectException!ConnectionError(Connection(
        dbname:   environment.get("POSTGRES_DB", "peque-test"),
        user:     "no_such_user_xyz",
        password: "wrong_password",
        host:     environment.get("POSTGRES_HOST", "localhost"),
        port:     environment.get("POSTGRES_PORT", "5432"),
    ));
    assert(ex !is null, "bad credentials must throw ConnectionError");

    // Unreachable port — connection must also throw ConnectionError.
    auto ex2 = collectException!ConnectionError(Connection(
        dbname:   "irrelevant",
        user:     "irrelevant",
        password: "irrelevant",
        host:     "127.0.0.1",
        port:     "19999",
    ));
    assert(ex2 !is null, "unreachable host/port must throw ConnectionError");
}



// ---------------------------------------------------------------------------
// execMulti / exec: an error mid-batch throws QueryError and the connection
// stays usable (the failure path frees already-collected results)
// ---------------------------------------------------------------------------
unittest {
    import std.exception: assertThrown;
    import peque.exception: QueryError;

    auto c = Connection(
            environment.get("POSTGRES_DB", "peque-test"),
            environment.get("POSTGRES_USER", "peque"),
            environment.get("POSTGRES_PASSWORD", "peque"),
            environment.get("POSTGRES_HOST", "localhost"),
            environment.get("POSTGRES_PORT", "5432"),
    );

    c.execMulti("SELECT 1; SELECT no_such_column_xyz; SELECT 3")
        .assertThrown!QueryError;
    assert(c.exec("SELECT 42").getValue!int(0, 0) == 42);

    c.exec("SELECT 1; SELECT no_such_column_xyz; SELECT 3")
        .assertThrown!QueryError;
    assert(c.exec("SELECT 43").getValue!int(0, 0) == 43);
}

// ---------------------------------------------------------------------------
// Row bounds: an out-of-range row index throws RowNotExistsError
// ---------------------------------------------------------------------------
unittest {
    import std.exception: assertThrown;
    import peque.exception: RowNotExistsError;

    auto c = Connection(
            environment.get("POSTGRES_DB", "peque-test"),
            environment.get("POSTGRES_USER", "peque"),
            environment.get("POSTGRES_PASSWORD", "peque"),
            environment.get("POSTGRES_HOST", "localhost"),
            environment.get("POSTGRES_PORT", "5432"),
    );

    auto res = c.exec("SELECT 1");
    res[5].assertThrown!RowNotExistsError;
    res[-1].assertThrown!RowNotExistsError;
    res.getValue(3, 0).assertThrown!RowNotExistsError;
}
