module peque.wait_strategy;

private import core.sys.posix.poll;
private import core.stdc.errno;

private import peque.exception;


/** Duck-typing constraint for WaitStrategy implementations.
  *
  * A WaitStrategy must expose:
  *   - waitReadable(int fd) — block/yield until fd has data to read
  *   - waitWritable(int fd) — block/yield until fd can accept writes
  **/
template isWaitStrategy(WS) {
    enum bool isWaitStrategy =
        is(typeof({ WS ws; ws.waitReadable(int.init); })) &&
        is(typeof({ WS ws; ws.waitWritable(int.init); }));
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

    void waitReadable(int fd) { readableCount++; }
    void waitWritable(int fd) { writableCount++; }
}

/** Pointer-forwarding wrapper for MockWaitStrategy.
  * Allows inspecting call counts after Connection construction.
  **/
struct MockWS {
    MockWaitStrategy* inner;

    void waitReadable(int fd) { inner.readableCount++; }
    void waitWritable(int fd) { inner.writableCount++; }
}


static assert(isWaitStrategy!PollWaitStrategy);
static assert(isWaitStrategy!MockWaitStrategy);
static assert(isWaitStrategy!MockWS);
