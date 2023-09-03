module peque.converter.d_to_pg;

private import std.array;
private import std.conv;
private import std.format;
private import std.datetime;
private import std.algorithm;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint, isArray;
private import std.range: ElementType;

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

/// ditto
PGValue convertToPG(T) (in T value)
@safe if (isArray!T && !isSomeString!T) {
    alias TI = ElementType!T;
    auto PGArrayType = getPgTypeInfo(convertToPG!(TI)(TI.init).type).array_type;
    if (value.length == 0)
        // If length of array is 0, than we could return empty array literal
        // without extra processing
        return PGValue(PGArrayType, PGFormat.TEXT, "{}\0");

    /*
     * Here, we have to build array literal in text format.
     *
     * We have to wrap in quotes (possibly) and we have to remove last \0 sign,
     * this we take slice `value[0 ... $-1]`
     */
    char[] result = ['{'];
    static if (isIntegral!TI || isFloatingPoint!TI || isBoolean!TI || is(TI == Date) || is(TI == DateTime) || is(TI == SysTime)) {
        // We do not need escaping for these simple types
        result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
    } else {
        result ~= value.map!((v) {
            // We skip ending \0 symbol in value
            auto rv = convertToPG(v).value[0 .. $-1];

            // Create buffer that will contain escaped value.;
            char[] r = ['\"'];
            r.reserve(rv.length * 2);  // reserve double capacity for possible escaping.
            int start = 0;
            for(int pos=0; pos < rv.length; pos++) {
                // We escape only quote and backslashes in array.
                if (rv[pos] == '\"' || rv[pos] == '\\') {
                    r ~= rv[start .. pos ] ~ '\\' ~ rv[pos];
                    pos += 1;
                    start = pos;
                }
            }
            if (start < rv.length - 1)
                // Is we have some part of value not added to result,
                // that we have to do it now.
                r ~= rv[start .. $];

            // Add final quote to result
            r ~= '\"';

            return r;
        }).join(",");
    }
    result ~= "}";
    return PGValue(PGArrayType, PGFormat.TEXT, result ~ "\0");
}
