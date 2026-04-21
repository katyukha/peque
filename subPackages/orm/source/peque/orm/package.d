/** peque:orm — compile-time ORM layer for peque.
  *
  * Provides:
  *  - isModel!M                     — constraint: M has @model UDA
  *  - CRUDMixin!(M, Ctx)            — mixin template: findAll, findById, insert, update, deleteById
  *  - Repository!(M, Ctx)           — ready-made struct wrapping CRUDMixin
  *  - Compile-time SQL helpers      — buildSelectList, buildInsertColList, etc.
  *  - ModelRepo!M                   — single-Ctx-param generic repo for use in Registry
  *  - Bind!(M, RepoTpl)             — bind a model to a single-Ctx-param repo template
  *  - Registry!(Bindings...)        — compile-time model→repo map
  *  - RegistryRepoFor!(Reg, M)      — look up repo template for model M
  *  - MergeRegistries!(Regs...)     — combine multiple registries
  *  - Environment!(Reg, Ctx, App)   — context + registry + optional app context
  *
  * Example — using Environment:
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
  * alias AppEnv = Environment!(AppReg, Connection);
  *
  * auto env = AppEnv(&conn);
  * auto all = env.repo!(Partner).findAll();
  * auto one = env.repo!(Partner).findById(42);
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
public import peque.orm.environment: Environment;
public import peque.orm.schema: modelDDL, schemaSQL;
