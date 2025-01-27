private import peque.connection: Connection;
private import peque.result: Result;


@safe unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

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

    res = c.exec("ALTER TABLE peque_test ADD COLUMN date TIMESTAMP;");
    assert(res.cmdStatus == "ALTER TABLE");
    assert(res.cmdTuples == 0);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);
}

// Test connection keyword arguments
@safe unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection(dbname: "peque-test", user: "peque", password: "peque", host: "localhost", port: "5432");

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


// Test connection builder arguments
@safe unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection([
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
