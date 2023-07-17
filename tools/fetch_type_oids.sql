-- See docs: https://www.postgresql.org/docs/current/catalog-pg-type.html
-- Run with command:
--     psql -U peque -h localhost -p 5432 -d postgres -At -F ' = ' -R $',\n' -f ./tools/fetch_type_oids.sql | cat

SELECT UPPER(typname), oid
FROM pg_type
WHERE typtype = 'b'
  AND typname !~ '^(_|pg_)'
  AND oid < 10000;
