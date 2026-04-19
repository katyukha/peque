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

private import vibe.core.core: createFileDescriptorEvent, FileDescriptorEvent, yield;


/** WaitStrategy that yields the current vibe.d fiber until the libpq socket
  * is ready, allowing other tasks to run in the meantime.
  *
  * waitReadable uses vibe.core.core.FileDescriptorEvent (wraps eventcore's
  * socket adoption) to yield until data arrives on the fd.
  *
  * waitWritable uses a single yield() — PQflush returning 1 (send buffer full)
  * is transient; giving the event loop one iteration is sufficient in practice.
  * Full write-readiness detection via FileDescriptorEvent is not yet available
  * in vibe-core (as of 2.x); this will be upgraded once upstream adds support.
  **/
struct VibeWaitStrategy {
    /** Yield the current fiber until the socket has data to read. **/
    void waitReadable(int fd) @safe {
        auto evt = createFileDescriptorEvent(fd, FileDescriptorEvent.Trigger.read);
        evt.wait(FileDescriptorEvent.Trigger.read);
    }

    /** Yield the current fiber once to let the event loop drain the OS send buffer.
      *
      * Note: vibe-core 2.x does not yet expose write-readiness via
      * FileDescriptorEvent. A single yield() is correct because PQflush
      * returning 1 is transient and the retry loop in _flushLoop will
      * call PQflush again immediately after the yield.
      **/
    void waitWritable(int fd) @safe {
        yield();
    }
}
