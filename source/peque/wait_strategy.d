module peque.wait_strategy;

private import core.sys.posix.poll;
private import core.stdc.errno;
private import core.time: Duration, MonoTime;

private import peque.exception: ConnectionError;


/** What socket readiness to wait for. Bit flags: readWrite = read | write.
  *
  * readWrite is used by sending loops (PQflush retries): per libpq's
  * protocol a sender must wait for either direction and consume input when
  * the socket turns readable — waiting only for writability can deadlock
  * when both TCP directions are full.
  **/
enum WaitMask {
    read      = 1,
    write     = 2,
    readWrite = read | write,
}


/** Duck-typing constraint for WaitStrategy implementations.
  *
  * A WaitStrategy must expose:
  *   - wait(int fd, WaitMask mask) — block/yield until fd is ready for the
  *     requested direction(s)
  *
  * Optionally, a strategy may also provide a timed variant (see
  * hasTimedWait):
  *   - bool wait(int fd, WaitMask mask, Duration timeout) — true = ready,
  *     false = timed out.  Required by Connection.waitNotifications.
  **/
template isWaitStrategy(WS) {
    enum bool isWaitStrategy =
        is(typeof({ WS ws; ws.wait(int.init, WaitMask.read); }));
}


/** True when WS additionally provides the OPTIONAL timed overload:
  *
  *   bool wait(int fd, WaitMask mask, Duration timeout)
  *
  * returning true when fd became ready and false on timeout.  Not part of
  * the isWaitStrategy requirement — strategies without it still work for all
  * query execution; only Connection.waitNotifications(Duration) needs it.
  **/
template hasTimedWait(WS) {
    enum bool hasTimedWait =
        is(typeof({ WS ws; bool b = ws.wait(int.init, WaitMask.read, Duration.init); }));
}


private short _pollEvents(WaitMask mask) @safe pure nothrow @nogc {
    short ev = 0;
    if (mask & WaitMask.read)  ev |= POLLIN;
    if (mask & WaitMask.write) ev |= POLLOUT;
    return ev;
}


/** Default WaitStrategy using POSIX poll(). No dependencies — works standalone.
  *
  * Blocks the calling OS thread until the fd is ready. Retries automatically
  * on EINTR (signal received mid-wait) so stray signals do not abort queries.
  **/
struct PollWaitStrategy {
    void wait(int fd, WaitMask mask) @trusted {
        pollfd pfd = {fd: fd, events: _pollEvents(mask)};
        _poll(pfd);
    }

    /** Wait until fd is ready or timeout elapses.
      *
      * Returns: true = fd is ready; false = timed out.
      *
      * EINTR retries recompute the remaining time from a MonoTime deadline,
      * so interrupted waits never extend the total timeout.  A zero or
      * negative timeout degenerates to a single non-blocking readiness check.
      **/
    bool wait(int fd, WaitMask mask, Duration timeout) @trusted {
        pollfd pfd = {fd: fd, events: _pollEvents(mask)};
        immutable deadline = MonoTime.currTime + timeout;
        while (true) {
            immutable remaining = deadline - MonoTime.currTime;
            // Ceil to whole milliseconds so a sub-millisecond remainder does
            // not busy-spin with a zero poll timeout.
            long ms = remaining <= Duration.zero ? 0 : remaining.total!"msecs" + 1;
            if (ms > int.max) ms = int.max;
            immutable r = poll(&pfd, 1, cast(int) ms);
            if (r > 0) return true;
            if (r == 0 && MonoTime.currTime >= deadline) return false;
            if (r < 0 && errno != EINTR)
                throw new ConnectionError("poll() failed while waiting with timeout");
            // else: EINTR, or r == 0 before the (clamped) deadline — retry
        }
    }

    private static void _poll(ref pollfd pfd) @trusted {
        while (true) {
            int r = poll(&pfd, 1, -1);
            if (r > 0) return;
            // r == 0: impossible with timeout=-1 (no timeout)
            // r < 0, errno == EINTR: signal interrupted the wait — retry
            if (r < 0 && errno != EINTR)
                throw new ConnectionError("poll() failed");
        }
    }
}


/** Test-only WaitStrategy. Records call counts; does not actually block.
  *
  * Use via a pointer-forwarding wrapper so that mutations to the counters
  * are visible after the Connection is constructed (delegates capture by value):
  *
  * ---
  * MockWaitStrategy mock;
  * auto conn = Connection(connStr, ws: MockWS(&mock));
  * conn.execParams("SELECT 1");
  * assert(mock.readCount >= 1);
  * ---
  **/
struct MockWaitStrategy {
    int readCount;
    int writeCount;
    int duplexCount;
    int timedCount;
    /// Value returned by the timed wait — set false to simulate timeout.
    bool timedResult = true;

    void wait(int fd, WaitMask mask) {
        final switch (mask) {
            case WaitMask.read:      readCount++;   break;
            case WaitMask.write:     writeCount++;  break;
            case WaitMask.readWrite: duplexCount++; break;
        }
    }

    bool wait(int fd, WaitMask mask, Duration timeout) {
        timedCount++;
        return timedResult;
    }
}

/** Pointer-forwarding wrapper for MockWaitStrategy.
  * Allows inspecting call counts after Connection construction.
  **/
struct MockWS {
    MockWaitStrategy* inner;

    void wait(int fd, WaitMask mask) { inner.wait(fd, mask); }
    bool wait(int fd, WaitMask mask, Duration timeout) {
        return inner.wait(fd, mask, timeout);
    }
}


static assert(isWaitStrategy!PollWaitStrategy);
static assert(isWaitStrategy!MockWaitStrategy);
static assert(isWaitStrategy!MockWS);
static assert(hasTimedWait!PollWaitStrategy);
static assert(hasTimedWait!MockWaitStrategy);
static assert(hasTimedWait!MockWS);

// A readWrite wait must return immediately on a writable-only fd (the write
// end of a fresh pipe) — a read-only wait would block forever here.
unittest {
    import core.sys.posix.unistd: pipe, close;
    int[2] fds;
    assert(pipe(fds) == 0);
    scope(exit) { close(fds[0]); close(fds[1]); }
    PollWaitStrategy ws;
    ws.wait(fds[1], WaitMask.readWrite);
    ws.wait(fds[1], WaitMask.write);
    // and the timed read-only wait on the empty read end must time out
    import core.time: msecs;
    assert(!ws.wait(fds[0], WaitMask.read, 1.msecs));
}
