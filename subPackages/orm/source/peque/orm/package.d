/** peque:orm — compile-time ORM layer for peque.
  *
  * Provides:
  *  - isModel!M                — constraint: M has @model UDA
  *  - CRUDMixin!(M, Ctx)       — mixin template: findAll, findById, insert, update, deleteById
  *  - Repository!(M, Ctx)      — ready-made struct wrapping CRUDMixin
  *  - Compile-time SQL helpers — buildSelectList, buildInsertColList, etc.
  *  - ModelRepo!M              — single-Ctx-param generic repo for use in Registry
  *  - Bind!(M, RepoTpl)        — bind a model to a single-Ctx-param repo template
  *  - Registry!(Bindings...)   — compile-time model→repo map
  *  - RegistryRepoFor!(Reg, M) — look up repo template for model M
  *  - MergeRegistries!(Regs...)— combine multiple registries
  *  - modelDDL!M()             — CREATE TABLE SQL for one model
  *  - schemaSQL!Reg()          — CREATE TABLE SQL for every model in a registry
  *
  * peque:orm intentionally does not provide an "Environment" or request-context
  * abstraction — that is an application-level concern.  Applications compose
  * the building blocks above into their own context struct, gaining full control
  * over what extra state (current user, logger, tenant id, …) lives alongside
  * the connection.
  *
  * Recommended application pattern:
  * ---
  * import peque;
  * import peque.orm;
  *
  * @model("res_partner")
  * struct Partner {
  *     @primaryKey int    id;
  *     @field      string name;
  *     @field      string email;
  * }
  *
  * alias AppReg = Registry!(Bind!(Partner, ModelRepo!Partner));
  *
  * struct AppEnv {
  *     Connection* conn;
  *     // … add currentUser, logger, tenantId, etc. as needed …
  *
  *     auto repo(M)() {
  *         return RegistryRepoFor!(AppReg, M)!Connection(conn);
  *     }
  *
  *     auto withTransaction(T)(scope T delegate(ref TxEnv) fun) {
  *         return conn.transaction((ref Transaction tx) {
  *             auto txEnv = TxEnv(&tx);
  *             return fun(txEnv);
  *         });
  *     }
  *
  *     struct TxEnv {
  *         Transaction* tx;
  *         auto repo(M)() {
  *             return RegistryRepoFor!(AppReg, M)!Transaction(tx);
  *         }
  *     }
  * }
  *
  * auto env = AppEnv(&conn);
  * auto all = env.repo!(Partner).findAll();
  * auto one = env.repo!(Partner).findById(42);
  * env.withTransaction((ref AppEnv.TxEnv tx) {
  *     auto p = Partner(0, "Acme", "acme@example.com");
  *     tx.repo!(Partner).insert(p);
  * });
  * ---
  **/
module peque.orm;

public import peque.orm.repository: isModel, CRUDMixin, Repository;
public import peque.orm.sql:
    buildSelectList, buildInsertColList, buildInsertPlaceholders,
    buildUpdateSetClause, buildInsertValueExpr, buildUpdateValueExpr,
    ormTableName, ormPkColName, countNonPkFields;
public import peque.orm.registry:
    ModelRepo, Bind, Registry, RegistryRepoFor, MergeRegistries;
public import peque.orm.schema: modelDDL, schemaSQL;
