/** vibe.d integration for peque.
  *
  * Provides:
  * - VibeWaitStrategy  — WaitStrategy that yields the current vibe.d fiber
  *                       instead of blocking the OS thread.
  * - VibeConnectionPool — ConnectionPool instantiated with LocalTaskSemaphore
  *                        and TaskMutex so that pool exhaustion yields the fiber
  *                        rather than blocking the event thread.
  * - makeVibePool       — Convenience factory that wires everything together:
  *                        creates connections with VibeWaitStrategy, enables
  *                        non-blocking mode, and returns a VibeConnectionPool.
  *
  * Usage:
  * ---
  * import peque.vibe;
  *
  * // At application startup (inside a vibe.d runApplication callback):
  * auto pool = makeVibePool(8, [
  *     "dbname": "myapp",
  *     "user":   "app",
  *     "host":   "localhost",
  *     "port":   "5432",
  * ]);
  *
  * // Inside any vibe.d request handler:
  * auto result = pool.borrow((ref Connection conn) {
  *     return conn.execParams("SELECT name FROM users WHERE id = $1", userId);
  * });
  * ---
  **/
module peque.vibe;

public import peque.vibe.wait_strategy: VibeWaitStrategy;
public import peque.vibe.pool:          VibeConnectionPool, makeVibePool;
