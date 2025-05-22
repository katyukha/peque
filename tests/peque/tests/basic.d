module peque.tests.basic;

private import std.process: environment;

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
    foreach(row; res) res_arr_1 ~= row["code"].as!string;
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

