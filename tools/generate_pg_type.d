#!/usr/bin/env dub

/+ dub.sdl:
    name "peque-generate-pg-type"
    dependency "theprocess" version=">=0.0.5"
+/


import std.stdio;
import std.string;
import std.typecons;
import std.conv;
import std.exception;

import theprocess;


// See docs: https://www.postgresql.org/docs/current/catalog-pg-type.html
immutable string sql_type_info = "
    SELECT pt.typname AS type_name,
           pt.oid     AS type_oid,
           pat.typname   AS array_type_name,
           pat.oid    AS array_type_oid
    FROM pg_type AS pt
    LEFT JOIN pg_type AS pat ON pt.typarray = pat.oid
    WHERE pt.typtype = 'b'
      AND pt.typname !~ '^(_|pg_)'
      AND pt.oid < 10000
    ;
";


immutable struct PGTypeInfo {
    string name;
    int oid;
    string array_name;
    int array_oid;

    @disable this();

    this(in string name, in int oid, in string array_name, in int array_oid) {
        this.name = name;
        this.oid = oid;
        this.array_name = array_name;
        this.array_oid = array_oid;
    }
}


auto parsePGTypeInfo(in string data) {
    // TODO: Change guess on UNDEFINED
    PGTypeInfo[] result = [PGTypeInfo("guess", 0, "guess", 0)];

    foreach(row; data.split("\n")) {
        if (row.length == 0)
            continue;
        auto parts = row.split("|");
        enforce(
            parts.length == 4,
            "Cannot parse row '%s'".format(row));
        result ~= PGTypeInfo(
            parts[0],
            parts[1].to!int,
            parts[2],
            parts[3].to!int,
        );
    }

    // Generate type info for arrays of base elements
    foreach(type; result.dup)
        if (type.array_oid)
            result ~= PGTypeInfo(
                type.array_name,
                type.array_oid,
                null,
                0);
    return result;
}


auto generateHeader() {
    immutable string result = q"</**
  * This module contains constants for Postgres Oids for postgres types
  * and some unitities to work with postgres types information.
  *
  * This module is automatcially by `tools/generate_pg_types.d` script.
  **/
module peque.pg_type;

private import peque.c: Oid;


>";
    return result;
}


auto generatePGTypeEnum(in PGTypeInfo[] types) {
    immutable indent = "    ";
    string result = q"</**
  * Mapping for Postgres types and Oids.
  * See docs: https://www.postgresql.org/docs/current/catalog-pg-type.html
  *
  * Generated automatcially by `tools/generate_pg_types.d` script.
  **/
>";
    result ~= "enum PGType : Oid {\n";
    foreach(type; types) {
        result ~= indent ~ type.name.toUpper ~ " = " ~ type.oid.to!string ~ ",\n";
    }
    result ~= "}\n";
    return result;
}


auto getPGTypeInfoByOid(in PGTypeInfo[] types, in int oid) {
    foreach(type; types) {
        if (type.oid == oid)
            return type;
    }
    throw new Exception("Cannot find type by oid (%s)!".format(oid));
}


auto generatePGTypeInfoFunc(in PGTypeInfo[] types) {
    immutable indent = "    ";
    immutable dindent = indent ~ indent;
    string result = q"<
/** This struct represents info about postgres type
  **/
immutable struct PGTypeInfo {
    PGType type;
    PGType array_type;
}


/** Return extra info about postgres type
  *
  * Params:
  *     type = PGType to get extra info for
  * Returns: PGTypeInfo struct that represents extra info about this PGType
  **/
PGTypeInfo getPgTypeInfo(in PGType type) @safe pure {
    with(PGType) final switch(type) {
>";

    foreach(type; types) {
        result ~= dindent ~ "case %s: return PGTypeInfo(%s, %s);\n".format(
            type.name.toUpper,
            type.name.toUpper,
            types.getPGTypeInfoByOid(type.array_oid).name.toUpper);

    }

    result ~= indent ~ "}\n";
    result ~= "}\n";
    return result;
}

void main() {
    auto data = Process("psql")
        .withArgs(
            "-U", "peque",
            "-h", "localhost",
            "-p", "5432",
            "-d", "postgres",
            "-A", "-t",
            "-c", sql_type_info)
        .withEnv("PGPASSWORD", "peque")
        .execute
        .ensureOk
        .output;
    auto pg_types = parsePGTypeInfo(data);

    string result = generateHeader();
    result ~= generatePGTypeEnum(pg_types);
    result ~= "\n";
    result ~= generatePGTypeInfoFunc(pg_types);
    write(result);
}
