module peque.utils;

import std.process: environment;

import peque.connection: Connection;


auto connectViaEnvParams(in string[string] defaults=null) {
    string[string] params;

    foreach(kv; defaults.byKeyValue)
        params[kv.key] = kv.value;

    if (auto pghost = environment.get("POSTGRES_HOST"))
        params["host"] = pghost;
    if (auto pgport = environment.get("POSTGRES_PORT"))
        params["port"] = pgport;
    if (auto pguser = environment.get("POSTGRES_USER"))
        params["user"] = pguser;
    if (auto pgpassword = environment.get("POSTGRES_PASSWORD"))
        params["password"] = pgpassword;
    if (auto pgdb = environment.get("POSTGRES_DB"))
        params["dbname"] = pgdb;
    return Connection(params);
}

