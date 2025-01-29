# Peque - simple wraper over libpq


**Warning** - this is dev version. Use on your own risk.

The idea of project is to have small, reliable, convenient PostgreSQL client (libpq wrapper) library,
that use reference counting to store libpq objects, and automatically free them, when they go out of the scope (do not wait for GC).

Also, one more feature, that is implemented in this lib, is automatic covnersion of postgres values to D and D values to postgres values.
(currently implemented only for basic types)

Example:

```d
import std.typecons;
import std.datetime;

auto c = Connection(
        environment.get("POSTGRES_DB", "peque-test"),
        environment.get("POSTGRES_USER", "peque"),
        environment.get("POSTGRES_PASSWORD", "peque"),
        environment.get("POSTGRES_HOST", "localhost"),
        environment.get("POSTGRES_PORT", "5432"),
);

auto res = c.exec("
    DROP TABLE IF EXISTS peque_test;
    CREATE TABLE peque_test (
        id      serial,
        code    char(5),
        title   varchar(40)
    );
    INSERT INTO peque_test (code, title)
    VALUES ('t1', 'Test 1'),
           ('t2', 'Test 2'),
           ('t3', 'Test 3'),
           ('r4', 'Test 4');
");
res.ensureQueryOk;
assert(res.cmdStatus == "INSERT 0 4");
assert(res.cmdTuples == 4);
assert(res.ntuples == 0);
assert(res.nfields == 0);

res = c.exec("SELECT code, title FROM peque_test;");
assert(res.cmdStatus == "SELECT 4");
assert(res.cmdTuples == 4);
assert(res.ntuples == 4);
assert(res.nfields == 2);
assert(res.fieldName(0).get == "code");
assert(res.fieldName(1).get == "title");
assert(res.fieldName(2).isNull);
assert(res.fieldNumber("code").get == 0);
assert(res.fieldNumber("TItle").get == 1);
assert(res.fieldNumber("unknown").isNull);

res = c.exec("ALTER TABLE peque_test ADD COLUMN date TIMESTAMP;");
assert(res.cmdStatus == "ALTER TABLE");
assert(res.cmdTuples == 0);
assert(res.ntuples == 0);
assert(res.nfields == 0);
```
