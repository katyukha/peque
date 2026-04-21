/** Environment — query context + registry + optional application context.
  *
  * Environment is the primary ORM entry point.  It holds a pointer to the
  * active query context (Connection or Transaction), the compile-time registry,
  * and an optional user-defined application context (current user, session, etc.).
  *
  * It satisfies isQueryContext itself (forwarding exec/execParams to the
  * underlying context), so repositories can be bound to an Environment just
  * as they can to a bare Connection or Transaction.
  *
  * Typical use:
  * ---
  * alias AppReg = Registry!(
  *     Bind!(Partner, ModelRepo!Partner),
  *     Bind!(Order,   OrderRepo),
  * );
  *
  * // Without AppContext:
  * alias AppEnv = Environment!(AppReg, Connection);
  * auto env = AppEnv(&conn);
  * auto p   = env.repo!(Partner).findById(1);
  *
  * // With AppContext:
  * alias AppEnv = Environment!(AppReg, Connection, AppCtx);
  * auto env = AppEnv(&conn, AppCtx(userId: 42));
  * env.withTransaction((ref AppEnv.TxEnv txEnv) {
  *     txEnv.repo!(Partner).insert(p);
  *     txEnv.repo!(Order).insert(o);
  * });
  * ---
  **/
module peque.orm.environment;

private import peque.result: Result;
private import peque.query_context: isQueryContext;
private import peque.connection: Connection, Transaction, OnSuccess, IsolationLevel;
private import peque.orm.repository: isModel;
private import peque.orm.registry: RegistryRepoFor;


/** Holds a query context, a compile-time registry, and an optional AppCtx.
  *
  * Type parameters:
  *  - Reg    — a Registry!(Bind!(...), ...) type
  *  - Ctx    — Connection, Transaction, or any isQueryContext type
  *  - AppCtx — user-defined application context struct (default void = none)
  *
  * When Ctx == Connection, the withTransaction() method is available.
  * Inside the delegate, a new Environment bound to the Transaction is provided.
  **/
struct Environment(Reg, Ctx, AppCtx = void)
if (isQueryContext!Ctx) {

    private Ctx* _ctx;

    static if (!is(AppCtx == void))
        AppCtx appCtx;

    /// Type of the transaction-scoped environment (used in withTransaction).
    alias TxEnv = Environment!(Reg, Transaction, AppCtx);

    @disable this();

    static if (is(AppCtx == void)) {
        this(Ctx* ctx) pure nothrow @nogc { _ctx = ctx; }
    } else {
        this(Ctx* ctx, AppCtx appCtx) {
            _ctx = ctx;
            this.appCtx = appCtx;
        }
    }


    // --- isQueryContext forwarding ---

    /// Forward exec to the underlying context.
    auto exec(in string query) { return _ctx.exec(query); }

    /// Forward execParams to the underlying context.
    auto execParams(in string query) { return _ctx.execParams(query); }

    /// ditto
    auto execParams(T...)(in string query, T params) {
        return _ctx.execParams(query, params);
    }


    // --- Repository access ---

    /** Instantiate the repository bound to model M with this environment's context.
      *
      * The repository type is looked up at compile time from the registry.
      * The returned repository is bound to a pointer to this environment's
      * query context — its lifetime must not exceed this environment's.
      *
      * Example:
      * ---
      * auto repo = env.repo!(Partner);
      * auto all  = repo.findAll();
      * ---
      **/
    auto repo(M)() if (isModel!M) {
        alias RepoTpl = RegistryRepoFor!(Reg, M);
        return RepoTpl!Ctx(_ctx);
    }


    // --- Transaction support (Connection only) ---

    static if (is(Ctx == Connection)) {
        /** Execute fun inside a transaction, re-binding the environment to Transaction.
          *
          * Issues BEGIN (with the requested isolation level).  On success, commits
          * or rolls back depending on onSuccess.  On failure, always rolls back.
          *
          * The delegate receives a ref to a TxEnv — an Environment of the same
          * Registry and AppCtx but bound to the Transaction.  All repo! calls
          * inside the delegate participate in the same transaction.
          *
          * Example:
          * ---
          * env.withTransaction((ref AppEnv.TxEnv txEnv) {
          *     txEnv.repo!(Partner).insert(p);
          *     txEnv.repo!(Order).insert(o);
          * });
          * ---
          **/
        auto withTransaction(
                OnSuccess onSuccess = OnSuccess.commit,
                IsolationLevel isolation = IsolationLevel.readCommitted,
                T)(scope T delegate(ref TxEnv) fun) {
            return _ctx.transaction!(onSuccess, isolation)((ref Transaction tx) {
                static if (is(AppCtx == void))
                    auto txEnv = TxEnv(&tx);
                else
                    auto txEnv = TxEnv(&tx, appCtx);
                return fun(txEnv);
            });
        }
    }
}
