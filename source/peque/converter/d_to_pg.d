module peque.converter.d_to_pg;

private import std.array;
private import std.conv;
private import std.format;
private import std.datetime;
private import std.algorithm;
private import std.json: JSONValue;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint, isArray;
private import std.range: ElementType;

private import peque.pg_type;
private import peque.pg_format;

//TODO: Handle nullable types here

/** Struct that represents value to be passed to PQexecParams.
  **/
package(peque) @safe pure const struct PGValue {
    PGType type;
    PGFormat format = PGFormat.TEXT;
    char[] value;

    this(PGType type, PGFormat format, in char[] value) @safe pure {
        assert(
            value.length > 0 && value[$ - 1] == '\0',
             "PGValue value must be null-terminated!");
        assert(
            value.length < int.max,
             "Too large value length for PGValue!");
        this.type = type;
        this.format = format;
        this.value = value;
    }

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
@safe pure if (isSomeString!T)
in (!value.canFind('\0'), "String value cannot contain null (\\0) characters!") {
    return PGValue(PGType.TEXT, PGFormat.TEXT, value.to!(char[]) ~ "\0");
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
    auto s = value.toISOExtString;
    return PGValue(PGType.DATE, PGFormat.TEXT, (s.to!(char[]) ~ '\0'));
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(T == DateTime)) {
    auto s = value.toISOExtString;
    return PGValue(PGType.TIMESTAMP, PGFormat.TEXT, (s.to!(char[]) ~ '\0'));
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
PGValue convertToPG(T)(in T value)
@safe if (is(T == JSONValue)) {
    auto s = value.toString();
    return PGValue(
        PGType.JSON,
        PGFormat.TEXT,
        (s.to!(char[]) ~ '\0'),
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
     * thus we take slice `value[0 ... $-1]`
     */
    char[] result = ['{'];
    static if (isIntegral!TI || isFloatingPoint!TI || isBoolean!TI || is(TI == Date) || is(TI == DateTime) || is(TI == SysTime)) {
        // We do not need escaping for these simple types
        result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
    } else static if (isArray!TI && !isSomeString!TI) {
        result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
    }else {
        // Case when array is array of strings. Special handling. here to escape resulting array correctly
        result ~= value.map!((v) {
            // We skip ending \0 symbol in value
            auto rv = convertToPG(v).value[0 .. $-1];

            // Create buffer that will contain escaped value.;
            char[] r = ['"'];
            r.reserve(rv.length * 2);  // reserve double capacity for possible escaping.
            int start = 0;
            for(int pos=0; pos < rv.length; pos++) {
                // We escape only quote and backslashes in array.
                if (rv[pos] == '"' || rv[pos] == '\\') {
                    r ~= rv[start .. pos ] ~ '\\' ~ rv[pos];
                    start = pos + 1;
                }
            }
            if (start < rv.length)
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


// Test that convertion of string with null is not allowed
unittest {
    import std.exception: assertThrown;
    import core.exception: AssertError;
    convertToPG("t1\0; H").assertThrown!AssertError;
}

// Test that array element quoting/escaping in convertToPG works correctly
unittest {
    auto v = convertToPG!(string[])(["a\"b", "c\\d"]);
    auto s = v.value[0 .. $ - 1].idup; // skip terminating NUL
    assert(s == "{\"a\\\"b\",\"c\\\\d\"}");

    // Test if last symbol in element of array string escaped
    assert(convertToPG!(string[])(["a\"b", "c\\"]).value[0 .. $ - 1] == "{\"a\\\"b\",\"c\\\\\"}");

    assert(
        convertToPG!(string[][])(
            [
                ["a\"b", "c\\"],
                ["ag\"42", "mix\""],
            ]
        ).value[0 .. $ - 1] == "{{\"a\\\"b\",\"c\\\\\"},{\"ag\\\"42\",\"mix\\\"\"}}"
    );
}
