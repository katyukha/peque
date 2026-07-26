module peque.wait_strategy;

private import core.sys.posix.poll;
private import core.stdc.errno;
private import core.time: Duration, MonoTime;

private import peque.exception;


/** Duck-typing constraint for WaitStrategy implementations.
  *
  * A WaitStrategy must expose:
  *   - waitReadable(int fd) — block/yield until fd has data to read
  *   - waitWritable(int fd) — block/yield until fd can accept writes
  *
  * Optionally, a strategy may also provide a timed variant (see
  * hasTimedWaitReadable):
  *   - bool waitReadable(int fd, Duration timeout) — true = readable,
  *     false = timed out.  Required by Connection.waitNotifications.
  **/
template isWaitStrategy(WS) {
    enum bool isWaitStrategy =
        is(typeof({ WS ws; ws.waitReadable(int.init); })) &&
        is(typeof({ WS ws; ws.waitWritable(int.init); }));
}


/** True when WS additionally provides the OPTIONAL timed-wait overload:
  *
  *   bool waitReadable(int fd, Duration timeout)
  *
  * returning true when fd became readable and false on timeout.  Not part of
  * the isWaitStrategy requirement — strategies without it still work for all
  * query execution; only Connection.waitNotifications(Duration) needs it.
  **/
template hasTimedWaitReadable(WS) {
    enum bool hasTimedWaitReadable =
        is(typeof({ WS ws; bool b = ws.waitReadable(int.init, Duration.init); }));
}


/** Default WaitStrategy using POSIX poll(). No dependencies — works standalone.
  *
  * Blocks the calling OS thread until the fd is ready. Retries automatically
  * on EINTR (signal received mid-wait) so stray signals do not abort queries.
  **/
struct PollWaitStrategy {
    void waitReadable(int fd) @trusted {
        pollfd pfd = {fd: fd, events: POLLIN};
        _poll(pfd);
    }

    /** Wait until fd is readable or timeout elapses.
      *
      * Returns: true = fd is readable; false = timed out.
      *
      * EINTR retries recompute the remaining time from a MonoTime deadline,
      * so interrupted waits never extend the total timeout.  A zero or
      * negative timeout degenerates to a single non-blocking readiness check.
      **/
    bool waitReadable(int fd, Duration timeout) @trusted {
        pollfd pfd = {fd: fd, events: POLLIN};
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
                throw new PequeException("poll() failed while waiting with timeout");
            // else: EINTR, or r == 0 before the (clamped) deadline — retry
        }
    }

    void waitWritable(int fd) @trusted {
        pollfd pfd = {fd: fd, events: POLLOUT};
        _poll(pfd);
    }

    private static void _poll(ref pollfd pfd) @trusted {
        while (true) {
            int r = poll(&pfd, 1, -1);
            if (r > 0) return;
            // r == 0: impossible with timeout=-1 (no timeout)
            // r < 0, errno == EINTR: signal interrupted the wait — retry
            if (r < 0 && errno != EINTR)
                throw new PequeException("poll() failed");
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
  * auto conn = Connection(connStr, MockWS(&mock));
  * conn.execParams("SELECT 1");
  * assert(mock.readableCount >= 1);
  * ---
  **/
struct MockWaitStrategy {
    int readableCount;
    int writableCount;
    int timedReadableCount;
    /// Value returned by the timed waitReadable — set false to simulate timeout.
    bool timedReadableResult = true;

    void waitReadable(int fd) { readableCount++; }
    bool waitReadable(int fd, Duration timeout) {
        timedReadableCount++;
        return timedReadableResult;
    }
    void waitWritable(int fd) { writableCount++; }
}

/** Pointer-forwarding wrapper for MockWaitStrategy.
  * Allows inspecting call counts after Connection construction.
  **/
struct MockWS {
    MockWaitStrategy* inner;

    void waitReadable(int fd) { inner.readableCount++; }
    bool waitReadable(int fd, Duration timeout) {
        inner.timedReadableCount++;
        return inner.timedReadableResult;
    }
    void waitWritable(int fd) { inner.writableCount++; }
}


static assert(isWaitStrategy!PollWaitStrategy);
static assert(isWaitStrategy!MockWaitStrategy);
static assert(isWaitStrategy!MockWS);
static assert(hasTimedWaitReadable!PollWaitStrategy);
static assert(hasTimedWaitReadable!MockWaitStrategy);
static assert(hasTimedWaitReadable!MockWS);
