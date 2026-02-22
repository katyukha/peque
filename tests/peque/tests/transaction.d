module peque.tests.transaction;

private import std.process: environment;

private import peque.connection: Connection, Transaction, OnSuccess;
private import peque.result: Result;


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

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_transaction;
        CREATE TABLE peque_transaction (
            id      serial,
            code    varchar(5),
            title   varchar(40)
        );
        INSERT INTO peque_transaction (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('t4', 'Test 4');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);

    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    res.ensureQueryOk;
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4"]);

    // Start transaction
    res = c.begin;
    res.ensureQueryOk;

    // Insert row (via exec)
    res = c.exec("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t5', 'Test 5');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row inserted
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5"]);

    // Insert one more (via execParams)
    res = c.execParams("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t6', 'Test 6')
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row inserted
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5", "t6"]);

    res = c.rollback;
    res.ensureQueryOk;

    // Ensure all changes discarded
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4"]);

    // Start new transaction
    res = c.begin;
    res.ensureQueryOk;

    // Insert row (via exec)
    res = c.exec("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t5', 'Test 5');
    ");
    res.ensureQueryOk;
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row added
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5"]);

    // Commit transaction
    res = c.commit;
    res.ensureQueryOk;

    // Ensure row is still in database
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5"]);
}

// Test transaction() helper — commit on success, rollback on exception
unittest {
    import std.exception: assertThrown;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    c.exec("
        DROP TABLE IF EXISTS peque_transaction2;
        CREATE TABLE peque_transaction2 (code varchar(5));
    ");

    Result res;

    // Successful transaction: changes must be committed
    c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction2 VALUES ('a')");
        tx.execParams("INSERT INTO peque_transaction2 VALUES ('b')");
    });
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction2 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b"]);

    // Failed transaction: changes must be rolled back
    assertThrown(c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction2 VALUES ('c')");
        throw new Exception("abort");
    }));
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction2 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b"]);  // 'c' not committed

    // transaction() with return value
    auto count = c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction2 VALUES ('d')");
        return tx.execParams("SELECT count(*) FROM peque_transaction2")[0][0].get!long;
    });
    assert(count == 3);
}

// Test transaction() with OnSuccess.rollback — dry-run mode
unittest {
    import std.exception: assertThrown;

    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    c.exec("
        DROP TABLE IF EXISTS peque_transaction3;
        CREATE TABLE peque_transaction3 (code varchar(5));
    ");

    // Successful delegate with OnSuccess.rollback: changes must NOT be persisted
    c.transaction!(OnSuccess.rollback)((ref tx) {
        tx.execParams("INSERT INTO peque_transaction3 VALUES ('x')");
        tx.execParams("INSERT INTO peque_transaction3 VALUES ('y')");
    });
    auto res = c.execParams("SELECT count(*) FROM peque_transaction3");
    assert(res[0][0].get!long == 0);  // nothing committed

    // Failed delegate with OnSuccess.rollback: still rolls back (no change)
    assertThrown(c.transaction!(OnSuccess.rollback)((ref tx) {
        tx.execParams("INSERT INTO peque_transaction3 VALUES ('z')");
        throw new Exception("abort");
    }));
    res = c.execParams("SELECT count(*) FROM peque_transaction3");
    assert(res[0][0].get!long == 0);

    // OnSuccess.rollback with return value
    auto count = c.transaction!(OnSuccess.rollback)((ref tx) {
        tx.execParams("INSERT INTO peque_transaction3 VALUES ('a')");
        return tx.execParams("SELECT count(*) FROM peque_transaction3")[0][0].get!long;
    });
    assert(count == 1);  // visible inside the transaction
    res = c.execParams("SELECT count(*) FROM peque_transaction3");
    assert(res[0][0].get!long == 0);  // rolled back after returning
}
