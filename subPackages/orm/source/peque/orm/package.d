/** peque:orm — compile-time ORM layer for peque.
  *
  * Provides:
  *  - isModel!M                     — constraint: M has @model UDA
  *  - CRUDMixin!(M, Ctx)            — mixin template: findAll, findById, insert, update, deleteById
  *  - Repository!(M, Ctx)           — ready-made struct wrapping CRUDMixin
  *  - Compile-time SQL helpers      — buildSelectList, buildInsertColList, etc.
  *
  * Example:
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
  * auto repo = Repository!(Partner, Connection)(&conn);
  * auto all  = repo.findAll();
  * auto one  = repo.findById(42);
  * auto ins  = repo.insert(Partner(0, "Acme", "acme@example.com"));
  * ---
  **/
module peque.orm;

public import peque.orm.repository: isModel, CRUDMixin, Repository;
public import peque.orm.sql:
    buildSelectList, buildInsertColList, buildInsertPlaceholders,
    buildUpdateSetClause, buildInsertValueExpr, buildUpdateValueExpr,
    ormTableName, ormPkColName, countNonPkFields;
