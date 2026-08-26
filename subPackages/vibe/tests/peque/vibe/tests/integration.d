/** Integration tests for the vibe.d fiber path.
  *
  * These are the only tests that exercise VibeWaitStrategy — the main-package
  * async tests run on MockWS/PollWaitStrategy and never touch the
  * FileDescriptorEvent mapping, the per-call fd dup, or the timed overload.
  *
  * Every test body runs inside a vibe.d task via runVibeTest, which converts
  * fiber-side failures into ordinary unittest failures and guards against
  * hangs with a watchdog timer.
  **/
module peque.vibe.tests.integration;

version (unittest):

import core.time;
import std.conv: text;
import std.process: environment;
import std.datetime: SysTime, DateTime, UTC;

import vibe.core.core;
import vibe.core.task: Task;

import peque;
import peque.vibe;


string[string] testParams() {
    return [
        "dbname":   environment.get("POSTGRES_DB", "peque-test"),
        "user":     environment.get("POSTGRES_USER", "peque"),
        "password": environment.get("POSTGRES_PASSWORD", "peque"),
        "host":     environment.get("POSTGRES_HOST", "localhost"),
        "port":     environment.get("POSTGRES_PORT", "5432"),
    ];
}


Connection vibeConnect() {
    auto conn = Connection(testParams(), ws: VibeWaitStrategy());
    conn.setNonBlocking(true);
    return conn;
}


/** Run testBody inside a vibe.d task.
  *
  * A Throwable thrown in the fiber (including failed asserts) is captured and
  * rethrown on the unittest thread after the event loop exits — without this,
  * a fiber-side assert would not fail the test. The watchdog exits the event
  * loop on hang so CI fails fast instead of freezing.
  **/
void runVibeTest(void delegate() testBody, Duration timeout = 30.seconds) {
    Throwable failure;
    bool timedOut;
    bool finished;

    auto watchdog = setTimer(timeout, () nothrow @safe {
        timedOut = true;
        exitEventLoop();
    });

    runTask(() nothrow {
        try {
            testBody();
            finished = true;
        } catch (Throwable t) failure = t;
        exitEventLoop();
    });

    runEventLoop();
    watchdog.stop();

    if (failure !is null)
        throw failure;
    assert(!timedOut, "vibe test timed out");
    assert(finished, "vibe test body did not run to completion");
}


/// Event-loop liveness: quick queries complete while another fiber's slow
/// query is in flight — the OS thread is not blocked inside libpq waits.
unittest {
    runVibeTest({
        auto pool = makeVibePool(2, testParams());
        scope (exit) pool.close();

        Throwable slowErr;
        auto slowTask = runTask(() nothrow {
            try
                pool.borrow((ref Connection c) { c.exec("SELECT pg_sleep(0.5)"); });
            catch (Throwable t)
                slowErr = t;
        });

        // Let the slow task start and send its query.
        sleep(50.msecs);

        foreach (i; 0 .. 5)
            pool.borrow((ref Connection c) {
                auto r = c.execParams("SELECT $1::int", i);
                assert(r[0][0].get!int == i);
            });

        assert(slowTask.running,
            "event loop was blocked: quick queries did not overlap the slow query");

        slowTask.join();
        assert(slowErr is null, slowErr is null ? "" : slowErr.msg);
    });
}


/// Pool contention: more fibers than connections — excess fibers yield on
/// LocalTaskSemaphore until a connection is returned, and all complete.
unittest {
    runVibeTest({
        auto pool = makeVibePool(2, testParams());
        scope (exit) pool.close();

        int done;
        Throwable err;
        Task[] tasks;
        foreach (i; 0 .. 6)
            tasks ~= runTask(() nothrow {
                try {
                    pool.borrow((ref Connection c) { c.exec("SELECT pg_sleep(0.05)"); });
                    ++done;
                } catch (Throwable t)
                    err = t;
            });

        foreach (t; tasks)
            t.join();

        assert(err is null, err is null ? "" : err.msg);
        assert(done == 6, text("expected 6 completed fibers, got ", done));
    });
}


/// LISTEN/NOTIFY through the timed overload (FileDescriptorEvent.wait with
/// timeout): timeout returns empty, a real notification is delivered.
unittest {
    runVibeTest({
        auto listener = vibeConnect();
        auto publisher = vibeConnect();

        listener.listen("peque_vibe_test");

        // Timeout path: nothing pending → empty after ~100ms.
        auto none = listener.waitNotifications(100.msecs);
        assert(none.length == 0);

        publisher.execParams("SELECT pg_notify($1, $2)", "peque_vibe_test", "hello");

        auto got = listener.waitNotifications(5.seconds);
        assert(got.length == 1);
        assert(got[0].channel == "peque_vibe_test");
        assert(got[0].payload == "hello");
    });
}


/// FD-leak regression: every wait dups the libpq fd and hands it to
/// eventcore, which must close it. A leak here grows /proc/self/fd by one
/// per wait cycle (historical bug fixed in "Vibe.d leaking file descriptors").
version (linux)
unittest {
    runVibeTest({
        import std.file: dirEntries, SpanMode;
        import core.memory: GC;

        static size_t fdCount() {
            GC.collect();
            size_t n;
            foreach (e; dirEntries("/proc/self/fd", SpanMode.shallow))
                ++n;
            return n;
        }

        auto conn = vibeConnect();

        // Warm up lazily-created descriptors (eventcore queues, output buffers).
        foreach (i; 0 .. 5) {
            conn.exec("SELECT 1");
            conn.waitNotifications(1.msecs);
        }

        immutable before = fdCount();
        foreach (i; 0 .. 200) {
            conn.execParams("SELECT $1::int", cast(int) i);
            conn.waitNotifications(1.msecs);  // timed wait → dup + event per call
        }
        immutable after = fdCount();

        assert(after <= before + 5,
            text("fd leak: ", before, " fds before, ", after, " after 200 wait cycles"));
    }, 60.seconds);
}


// makeVibePool forwards `timezone` to every connection it creates — the path
// where it is most likely to be dropped unnoticed, since the pool builds its
// connections inside a factory delegate.
unittest {
    runVibeTest({
        auto pool = makeVibePool(2, testParams(), "Asia/Kolkata");

        // Every connection in the pool, not just the first one handed out.
        foreach (_; 0 .. 4)
            pool.borrow((ref Connection c) {
                assert(c.exec(`SHOW TimeZone`).getValue!string(0, 0) == "Asia/Kolkata");
            });

        // Omitted, the pool leaves the zone to the server — and the connection
        // still round-trips an instant unchanged, which is the invariant that
        // must not depend on the setting.
        auto plain = makeVibePool(1, testParams());
        plain.borrow((ref Connection c) {
            auto instant = SysTime(DateTime(2026, 8, 26, 9, 0, 0), UTC());
            assert(c.execParams(`SELECT $1::timestamptz`, instant)
                    .getValue!SysTime(0, 0) == instant);
        });
    });
}
