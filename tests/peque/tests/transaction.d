module peque.tests.transaction;

private import std.process: environment;

private import peque.connection: Connection, Transaction, OnSuccess, IsolationLevel;
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
    assert(res.cmdStatus == "INSERT 0 4");
    assert(res.cmdTuples == 4);
    assert(res.ntuples == 0);
    assert(res.nfields == 0);

    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4"]);

    // Start transaction
    c.begin;

    // Insert row (via exec)
    res = c.exec("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t5', 'Test 5');
    ");
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row inserted
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5"]);

    // Insert one more (via execParams)
    res = c.execParams("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t6', 'Test 6')
    ");
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row inserted
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5", "t6"]);

    c.rollback;

    // Ensure all changes discarded
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4"]);

    // Start new transaction
    c.begin;

    // Insert row (via exec)
    res = c.exec("
        INSERT INTO peque_transaction (code, title)
        VALUES ('t5', 'Test 5');
    ");
    assert(res.cmdStatus == "INSERT 0 1");

    // Ensure row added
    res = c.execParams("SELECT ARRAY(SELECT code FROM peque_transaction ORDER BY code ASC)");
    assert(res[0][0].get!(string[]) == ["t1", "t2", "t3", "t4", "t5"]);

    // Commit transaction
    c.commit;

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

// Test Transaction.savepoint() — partial rollbacks within a transaction
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
        DROP TABLE IF EXISTS peque_transaction4;
        CREATE TABLE peque_transaction4 (code varchar(5));
    ");

    // Successful savepoint: both outer and savepoint changes are committed
    c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction4 VALUES ('a')");
        tx.savepoint((ref tx) {
            tx.execParams("INSERT INTO peque_transaction4 VALUES ('b')");
        });
    });
    auto res = c.execParams(
        "SELECT ARRAY(SELECT code FROM peque_transaction4 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b"]);

    // Failed savepoint: only savepoint changes rolled back; outer transaction survives
    c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction4 VALUES ('c')");
        assertThrown(tx.savepoint((ref tx) {
            tx.execParams("INSERT INTO peque_transaction4 VALUES ('d')");
            throw new Exception("abort savepoint");
        }));
        // 'd' rolled back to savepoint; 'c' still in the transaction
    });
    res = c.execParams(
        "SELECT ARRAY(SELECT code FROM peque_transaction4 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b", "c"]);  // 'd' not committed

    // OnSuccess.rollback savepoint: savepoint changes rolled back even on success
    c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction4 VALUES ('e')");
        tx.savepoint!(OnSuccess.rollback)((ref tx) {
            tx.execParams("INSERT INTO peque_transaction4 VALUES ('f')");
        });
        // 'f' rolled back by savepoint; 'e' still in the transaction
    });
    res = c.execParams(
        "SELECT ARRAY(SELECT code FROM peque_transaction4 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b", "c", "e"]);  // 'f' not committed

    // Savepoint with return value
    auto count = c.transaction((ref tx) {
        return tx.savepoint((ref tx) {
            tx.execParams("INSERT INTO peque_transaction4 VALUES ('g')");
            return tx.execParams(
                "SELECT count(*) FROM peque_transaction4")[0][0].get!long;
        });
    });
    assert(count == 5);  // a, b, c, e, g visible inside savepoint
    res = c.execParams(
        "SELECT ARRAY(SELECT code FROM peque_transaction4 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b", "c", "e", "g"]);
}

// Test nested savepoints
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
        DROP TABLE IF EXISTS peque_transaction5;
        CREATE TABLE peque_transaction5 (code varchar(5));
    ");

    // Nested savepoints: inner failure only rolls back inner changes
    c.transaction((ref tx) {
        tx.execParams("INSERT INTO peque_transaction5 VALUES ('a')");
        tx.savepoint((ref tx) {
            tx.execParams("INSERT INTO peque_transaction5 VALUES ('b')");
            assertThrown(tx.savepoint((ref tx) {
                tx.execParams("INSERT INTO peque_transaction5 VALUES ('c')");
                throw new Exception("abort inner savepoint");
            }));
            // 'c' rolled back; 'b' still in outer savepoint
        });
        // 'a' and 'b' in the transaction
    });
    auto res = c.execParams(
        "SELECT ARRAY(SELECT code FROM peque_transaction5 ORDER BY code)");
    assert(res[0][0].get!(string[]) == ["a", "b"]);  // 'c' not committed
}

// Test IsolationLevel template parameter — verify the level is actually applied
unittest {
    auto c = Connection(
            dbname: environment.get("POSTGRES_DB", "peque-test"),
            user: environment.get("POSTGRES_USER", "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host: environment.get("POSTGRES_HOST", "localhost"),
            port: environment.get("POSTGRES_PORT", "5432"),
    );

    // Default (readCommitted) — always set explicitly
    c.transaction((ref tx) {
        auto level = tx.execParams(
            "SELECT current_setting('transaction_isolation')")[0][0].get!string;
        assert(level == "read committed");
    });

    // repeatableRead
    c.transaction!(OnSuccess.commit, IsolationLevel.repeatableRead)((ref tx) {
        auto level = tx.execParams(
            "SELECT current_setting('transaction_isolation')")[0][0].get!string;
        assert(level == "repeatable read");
    });

    // serializable
    c.transaction!(OnSuccess.commit, IsolationLevel.serializable)((ref tx) {
        auto level = tx.execParams(
            "SELECT current_setting('transaction_isolation')")[0][0].get!string;
        assert(level == "serializable");
    });

    // serverDefault — defers to server config; just verify it opens without error
    // and that the session default (read committed on a stock server) is in effect
    c.transaction!(OnSuccess.commit, IsolationLevel.serverDefault)((ref tx) {
        auto level = tx.execParams(
            "SELECT current_setting('transaction_isolation')")[0][0].get!string;
        assert(level == "read committed");  // stock server default
    });

    // OnSuccess.rollback combined with non-default isolation level
    c.transaction!(OnSuccess.rollback, IsolationLevel.repeatableRead)((ref tx) {
        auto level = tx.execParams(
            "SELECT current_setting('transaction_isolation')")[0][0].get!string;
        assert(level == "repeatable read");
    });
}
