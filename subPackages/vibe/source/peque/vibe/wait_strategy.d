/** VibeWaitStrategy — vibe.d fiber-aware WaitStrategy for peque.
  *
  * Satisfies the isWaitStrategy concept from peque.wait_strategy.
  * Pass it as the WS constructor parameter when creating a Connection
  * inside a vibe.d application:
  *
  * ---
  * auto conn = Connection(params, VibeWaitStrategy());
  * ---
  *
  * Or let makeVibePool inject it automatically (recommended).
  **/
module peque.vibe.wait_strategy;

private import core.sys.posix.unistd : dup;
private import core.time : Duration;

private import vibe.core.core : createFileDescriptorEvent, FileDescriptorEvent;

private import peque.wait_strategy : isWaitStrategy, hasTimedWait, WaitMask;


/** WaitStrategy that yields the current vibe.d fiber until the libpq socket
  * is ready, allowing other tasks to run in the meantime.
  *
  * Each wait duplicates libpq's fd via dup(2) and passes the duplicate to
  * FileDescriptorEvent. eventcore adopts and eventually closes the duplicate,
  * leaving libpq's original fd intact. Both fds share the same kernel socket
  * buffer, so when the socket becomes ready the duplicate sees it at the same
  * time as the original — PQconsumeInput()/PQflush() on the original work
  * normally after the wait returns.
  *
  * We cannot pass libpq's fd directly to FileDescriptorEvent: adoptStream()
  * takes ownership, and its destructor calls closeSocket() when the refcount
  * reaches zero, which would close libpq's fd and cause every subsequent
  * PQconsumeInput() to fail with EBADF.
  *
  * The dup + event are deliberately created per call (not cached): the fd may
  * change across a reconnect, and the churn is negligible next to a query
  * round-trip.
  **/
struct VibeWaitStrategy {
    /// Yield the current fiber until the socket is ready for `mask`.
    void wait(int fd, WaitMask mask) @trusted {
        auto dupFd = dup(fd);
        auto evt = createFileDescriptorEvent(dupFd, _trigger(mask));
        evt.wait(_trigger(mask));
    }

    /** Yield the current fiber until the socket is ready or timeout elapses.
      *
      * Returns: true = ready, false = timed out.
      **/
    bool wait(int fd, WaitMask mask, Duration timeout) @trusted {
        auto dupFd = dup(fd);
        auto evt = createFileDescriptorEvent(dupFd, _trigger(mask));
        return evt.wait(timeout, _trigger(mask));
    }

    private static FileDescriptorEvent.Trigger _trigger(WaitMask mask) @safe {
        final switch (mask) {
            case WaitMask.read:      return FileDescriptorEvent.Trigger.read;
            case WaitMask.write:     return FileDescriptorEvent.Trigger.write;
            case WaitMask.readWrite: return FileDescriptorEvent.Trigger.any;
        }
    }
}


static assert(isWaitStrategy!VibeWaitStrategy);
static assert(hasTimedWait!VibeWaitStrategy);
