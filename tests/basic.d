private import peque.connection: Connection;
private import peque.result: Result;


@safe unittest {
    import std.stdio;
    import std.typecons;

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

    // Test get value
    res = c.exec("SELECT NULL");
    assert(res.getValue(0, 0).isNull);
    res = c.exec("SELECT 1");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "1");

    res = c.exec("SELECT 'hello world!'");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "hello world!");

    res = c.exec("SELECT ''");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "");

    res = c.exec("SELECT True");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "t");

    res = c.exec("SELECT False");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "f");

    res = c.exec("SELECT '2023-07-17'::timestamp;");
    assert(!res.getValue(0, 0).isNull);
    assert(res.getValue(0, 0).get!string == "2023-07-17 00:00:00");
}

