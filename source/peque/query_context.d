module peque.query_context;

private import peque.result;


/** Duck-typing constraint satisfied by Connection, Transaction, and any future wrapper.
  *
  * A query context must expose:
  *   - exec(string query) returning Result
  *   - execParams(string query, T... params) returning Result
  *
  * This constraint is the key that makes the ORM async-agnostic: ORM types
  * parameterised on Ctx where isQueryContext!Ctx never need WaitStrategy
  * propagation — Connection is non-templated, so no !WS anywhere in business logic.
  *
  * Transaction satisfies this automatically because it already forwards both
  * methods to its parent Connection. No changes to Transaction needed.
  **/
template isQueryContext(Ctx) {
    import peque.converter: PGValue;
    enum bool isQueryContext =
        is(typeof(Ctx.init.exec(string.init))                           : Result) &&
        is(typeof(Ctx.init.execParams(string.init))                     : Result) &&
        is(typeof(Ctx.init.execParams(string.init, PGValue[].init))     : Result);
}
