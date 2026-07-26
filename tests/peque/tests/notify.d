/** Integration tests for LISTEN/NOTIFY support.
  *
  * Covers:
  *  - listen() + waitNotifications() round-trip between two connections
  *  - timeout expiry → empty result after (roughly) the requested duration
  *  - drain-first semantics: buffered notifications returned without waiting
  *  - getNotifications() — non-blocking, empty when nothing pending
  *  - multiple notifications drained in one call, order preserved
  *  - listen/unlisten with a channel name that requires identifier quoting
  *  - escapeIdentifier correctness
  *  - clear error when the WaitStrategy lacks the timed wait overload
  *  - transactional delivery: NOTIFY is invisible until COMMIT
  **/
module peque.tests.notify;

private import core.time: Duration, MonoTime, msecs, seconds;
private import std.exception: assertThrown, collectException;
private import std.process: environment;
private import std.algorithm: canFind;

private import peque;
private import peque.exception: PequeException, QueryEscapingError;


private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


// ---------------------------------------------------------------------------
// Round-trip: listen on one connection, pg_notify from another
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    auto notifier = makeConn();

    listener.listen("peque_test_chan");
    scope(exit) listener.unlisten("peque_test_chan");

    immutable notifierPid = notifier.execParams("SELECT pg_backend_pid()")
        .getValue!int(0, 0);

    notifier.execParams("SELECT pg_notify($1, $2)", "peque_test_chan", "hello");

    auto ns = listener.waitNotifications(5.seconds);
    assert(ns.length == 1);
    assert(ns[0].channel == "peque_test_chan");
    assert(ns[0].payload == "hello");
    assert(ns[0].backendPid == notifierPid);
}


// ---------------------------------------------------------------------------
// Timeout expiry — empty result, elapsed roughly the requested duration
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    listener.listen("peque_quiet_chan");
    scope(exit) listener.unlisten("peque_quiet_chan");

    immutable start = MonoTime.currTime;
    auto ns = listener.waitNotifications(200.msecs);
    immutable elapsed = MonoTime.currTime - start;

    assert(ns.length == 0);
    assert(elapsed >= 180.msecs);   // slack for ms rounding
}


// ---------------------------------------------------------------------------
// Drain-first: a notification consumed during earlier traffic is returned
// immediately, without waiting on the (idle) socket
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    auto notifier = makeConn();

    listener.listen("peque_drain_chan");
    scope(exit) listener.unlisten("peque_drain_chan");

    notifier.execParams("SELECT pg_notify($1, $2)", "peque_drain_chan", "early");

    // This query consumes the socket input; the notification now sits in
    // libpq's internal buffer while the socket shows nothing new.
    listener.exec("SELECT 1");

    immutable start = MonoTime.currTime;
    auto ns = listener.waitNotifications(5.seconds);
    immutable elapsed = MonoTime.currTime - start;

    assert(ns.length == 1);
    assert(ns[0].payload == "early");
    assert(elapsed < 1.seconds);    // returned from the buffer, not the wait
}


// ---------------------------------------------------------------------------
// getNotifications — non-blocking, empty when nothing pending
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    listener.listen("peque_empty_chan");
    scope(exit) listener.unlisten("peque_empty_chan");

    assert(listener.getNotifications().length == 0);
}


// ---------------------------------------------------------------------------
// Multiple notifications drained in one call, order preserved
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    auto notifier = makeConn();

    listener.listen("peque_multi_chan");
    scope(exit) listener.unlisten("peque_multi_chan");

    // Distinct payloads: the server deduplicates identical (channel, payload)
    // pairs within one transaction; separate autocommit statements + distinct
    // payloads keep all three.
    foreach (p; ["p1", "p2", "p3"])
        notifier.execParams("SELECT pg_notify($1, $2)", "peque_multi_chan", p);

    // Socket delivery is not guaranteed to be batched — accumulate until all
    // three arrived.  Delivery order per connection is FIFO.
    Notification[] ns;
    immutable deadline = MonoTime.currTime + 5.seconds;
    while (ns.length < 3 && MonoTime.currTime < deadline)
        ns ~= listener.waitNotifications(500.msecs);
    assert(ns.length == 3);
    assert(ns[0].payload == "p1");
    assert(ns[1].payload == "p2");
    assert(ns[2].payload == "p3");
}


// ---------------------------------------------------------------------------
// listen/unlisten with a channel name that requires quoting
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    auto notifier = makeConn();

    // Mixed case + hyphen: without identifier quoting LISTEN would fail or
    // downcase the name; pg_notify($1, ...) matches the exact string.
    listener.listen("Weird-Channel");

    notifier.execParams("SELECT pg_notify($1, $2)", "Weird-Channel", "quoted");
    auto ns = listener.waitNotifications(5.seconds);
    assert(ns.length == 1);
    assert(ns[0].channel == "Weird-Channel");

    listener.unlisten("Weird-Channel");
    notifier.execParams("SELECT pg_notify($1, $2)", "Weird-Channel", "after");
    assert(listener.waitNotifications(300.msecs).length == 0);
}


// ---------------------------------------------------------------------------
// escapeIdentifier
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    assert(c.escapeIdentifier("simple") == `"simple"`);
    assert(c.escapeIdentifier("MixedCase") == `"MixedCase"`);   // case preserved
    assert(c.escapeIdentifier(`a"b`) == `"a""b"`);              // quote doubling
    assert(c.escapeIdentifier("with space") == `"with space"`);

    assertThrown!QueryEscapingError(c.escapeIdentifier("bad\0name"));
}


// ---------------------------------------------------------------------------
// WaitStrategy without the timed overload — clear error, before any wait
// ---------------------------------------------------------------------------

/// Minimal strategy satisfying only the required isWaitStrategy surface.
private struct NoTimeoutWS {
    void wait(int fd, WaitMask mask) {
        import core.sys.posix.poll;
        short ev = 0;
        if (mask & WaitMask.read)  ev |= POLLIN;
        if (mask & WaitMask.write) ev |= POLLOUT;
        pollfd pfd = {fd: fd, events: ev};
        poll(&pfd, 1, -1);
    }
}

static assert(isWaitStrategy!NoTimeoutWS);
static assert(!hasTimedWait!NoTimeoutWS);

unittest {
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
        NoTimeoutWS(),
    );

    // Ordinary queries work fine without the timed overload…
    assert(c.execParams("SELECT 1").getValue!int(0, 0) == 1);
    assert(c.getNotifications().length == 0);   // non-blocking path also fine

    // …but waitNotifications refuses with an actionable message.
    auto e = collectException!PequeException(c.waitNotifications(1.msecs));
    assert(e !is null);
    assert(e.msg.canFind("wait(int fd, WaitMask mask, Duration timeout)"));
}


// ---------------------------------------------------------------------------
// Timed-overload dispatch through the mock strategy
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
        MockWS(&mock),
    );

    // timedResult=false simulates an immediate timeout: the timed slot is
    // invoked once and waitNotifications returns empty.
    mock.timedResult = false;
    auto before = mock.timedCount;
    assert(c.waitNotifications(50.msecs).length == 0);
    assert(mock.timedCount == before + 1);
}


// ---------------------------------------------------------------------------
// Transactional delivery — NOTIFY is invisible until COMMIT
// ---------------------------------------------------------------------------

unittest {
    auto listener = makeConn();
    auto notifier = makeConn();

    listener.listen("peque_tx_chan");
    scope(exit) listener.unlisten("peque_tx_chan");

    notifier.exec("BEGIN");
    notifier.execParams("SELECT pg_notify($1, $2)", "peque_tx_chan", "gated");

    // Not delivered while the notifying transaction is open.
    assert(listener.waitNotifications(300.msecs).length == 0);

    notifier.exec("COMMIT");

    auto ns = listener.waitNotifications(5.seconds);
    assert(ns.length == 1);
    assert(ns[0].payload == "gated");
}
