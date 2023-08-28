module peque.converter.d_to_pg;

private import std.conv;
private import std.format;
private import std.datetime;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint;

private import peque.pg_type;
private import peque.pg_format;


/** Struct that represents value to be passed to PQexecParams.
  **/
package(peque) @safe pure const struct PGValue {
    PGType type;
    PGFormat format = PGFormat.TEXT;
    char[] value;

    /// Compute length of value
    int length() @trusted { return cast(int)value.length; }

    string toString() {
        return "type=%s, format=%s, length=%s, value=%s".format(
            this.type, this.format, this.length, this.value);
    }
}


/** Convert provided D value to PGValue
  **/
PGValue convertToPG(T) (in T value)
@safe pure if (isSomeString!T) {
    return PGValue(PGType.TEXT, PGFormat.TEXT, (value.to!(char[]) ~ '\0'));
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isIntegral!T) {
    return PGValue(
        PGType.NUMERIC,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isFloatingPoint!T) {
    auto v = format("%.20f", value);
    return PGValue(
        PGType.NUMERIC,
        PGFormat.TEXT,
        (v.to!(char[]) ~ '\0'),
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isBoolean!T) {
    return PGValue(
        PGType.BOOL,
        PGFormat.TEXT,
        value ? "t" ~ '\0' : "f" ~ '\0',
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(T == Date)) {
    return PGValue(
        PGType.DATE,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(T == DateTime)) {
    return PGValue(
        PGType.TIMESTAMP,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe if (is(T == SysTime)) {
    return PGValue(
        PGType.TIMESTAMPTZ,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

