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

private import vibe.core.core : createFileDescriptorEvent, FileDescriptorEvent;


/** WaitStrategy that yields the current vibe.d fiber until the libpq socket
  * is ready, allowing other tasks to run in the meantime.
  *
  * waitReadable duplicates libpq's fd via dup(2) and passes the duplicate to
  * FileDescriptorEvent. eventcore adopts and eventually closes the duplicate,
  * leaving libpq's original fd intact. Both fds share the same kernel socket
  * buffer, so when data arrives the duplicate becomes readable at the same
  * time as the original — PQconsumeInput() on the original works normally
  * after the wait returns.
  *
  * We cannot pass libpq's fd directly to FileDescriptorEvent: adoptStream()
  * takes ownership, and its destructor calls closeSocket() when the refcount
  * reaches zero, which would close libpq's fd and cause every subsequent
  * PQconsumeInput() to fail with EBADF.
  *
  * waitWritable uses a single yield() — PQflush returning 1 (send buffer full)
  * is transient; giving the event loop one iteration is sufficient in practice.
  **/
struct VibeWaitStrategy {
    /** Yield the current fiber until the socket has data to read.
      *
      * dup(2) creates a second fd for the same socket. FileDescriptorEvent
      * adopts and will close that duplicate; libpq's original fd is untouched.
      **/
    void waitReadable(int fd) @trusted {
        auto dupFd = dup(fd);
        auto evt = createFileDescriptorEvent(dupFd, FileDescriptorEvent.Trigger.read);
        evt.wait(FileDescriptorEvent.Trigger.read);
    }

    /** Yield the current fiber once to let the event loop drain the OS send buffer.
      *
      * PQflush returning 1 is transient and the retry loop in _flushLoop
      * calls PQflush again immediately after the yield.
      **/
    void waitWritable(int fd) @safe {
        import vibe.core.core : yield;
        yield();
    }
}
