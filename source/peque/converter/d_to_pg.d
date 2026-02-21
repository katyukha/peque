module peque.converter.d_to_pg;

private import std.array;
private import std.conv;
private import std.format;
private import std.datetime;
private import std.algorithm;
private import std.bitmanip: nativeToBigEndian;
private import std.json: JSONValue;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint, isArray,
    isSigned, isUnsigned;
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
            value.length < int.max,
             "Too large value length for PGValue!");
        assert(
            format == PGFormat.BINARY ||
            (value.length > 0 && value[$ - 1] == '\0'),
             "TEXT PGValue value must be null-terminated!");
        this.type = type;
        this.format = format;
        this.value = value;
    }

    /// Compute length of value.
    /// For TEXT, libpq uses strlen and ignores paramLengths — return 0.
    /// For BINARY, libpq reads exactly this many bytes.
    int length() @trusted {
        return format == PGFormat.BINARY ? cast(int)value.length : 0;
    }

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

/// ditto — unsigned integers use TEXT/NUMERIC (may exceed INT8 range)
PGValue convertToPG(T) (in T value)
@safe pure if (isIntegral!T && isUnsigned!T) {
    return PGValue(
        PGType.NUMERIC,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

/// ditto — signed integers use BINARY (INT2/INT4/INT8)
PGValue convertToPG(T) (in T value)
@safe pure if (isIntegral!T && isSigned!T) {
    static if (T.sizeof <= 2) {
        ubyte[2] buf = nativeToBigEndian(cast(short)value);
        return PGValue(PGType.INT2, PGFormat.BINARY, cast(char[])buf.dup);
    } else static if (T.sizeof == 4) {
        ubyte[4] buf = nativeToBigEndian(cast(int)value);
        return PGValue(PGType.INT4, PGFormat.BINARY, cast(char[])buf.dup);
    } else {
        ubyte[8] buf = nativeToBigEndian(cast(long)value);
        return PGValue(PGType.INT8, PGFormat.BINARY, cast(char[])buf.dup);
    }
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isFloatingPoint!T) {
    static if (T.sizeof == 4) {
        ubyte[4] buf = nativeToBigEndian(cast(float)value);
        return PGValue(PGType.FLOAT4, PGFormat.BINARY, cast(char[])buf.dup);
    } else {
        ubyte[8] buf = nativeToBigEndian(cast(double)value);
        return PGValue(PGType.FLOAT8, PGFormat.BINARY, cast(char[])buf.dup);
    }
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isBoolean!T) {
    ubyte[1] buf = [value ? 1 : 0];
    return PGValue(PGType.BOOL, PGFormat.BINARY, cast(char[])buf.dup);
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(T == Date)) {
    int days = cast(int)(value - Date(2000, 1, 1)).total!"days";
    ubyte[4] buf = nativeToBigEndian(days);
    return PGValue(PGType.DATE, PGFormat.BINARY, cast(char[])buf.dup);
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(T == DateTime)) {
    long usecs = (value - DateTime(2000, 1, 1, 0, 0, 0)).total!"usecs";
    ubyte[8] buf = nativeToBigEndian(usecs);
    return PGValue(PGType.TIMESTAMP, PGFormat.BINARY, cast(char[])buf.dup);
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe if (is(T == SysTime)) {
    import std.datetime.timezone: UTC;
    long usecs = (value.toUTC - SysTime(DateTime(2000, 1, 1, 0, 0, 0), UTC())).total!"usecs";
    ubyte[8] buf = nativeToBigEndian(usecs);
    return PGValue(PGType.TIMESTAMPTZ, PGFormat.BINARY, cast(char[])buf.dup);
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

/// Build a PostgreSQL text array literal (no trailing NUL) for embedding
/// inside an outer text-format array.  Used for nested arrays when the inner
/// element type uses binary encoding (signed int, bool, float, Date, …).
private char[] pgTextArrayLiteral(T)(in T value) @safe
if (isArray!T && !isSomeString!T) {
    alias TI = ElementType!T;
    if (value.length == 0) return "{}".dup;
    char[] result = ['{'];
    static if (isArray!TI && !isSomeString!TI) {
        // Nested arrays: recurse
        result ~= value.map!((v) => pgTextArrayLiteral(v)).join(",");
    } else static if (isSomeString!TI || is(TI == JSONValue)) {
        // Strings and JSON: quote and escape
        result ~= value.map!((v) {
            auto rv = convertToPG(v).value[0 .. $-1]; // TEXT, strips NUL
            char[] r = ['"'];
            r.reserve(rv.length * 2);
            int start = 0;
            for (int pos = 0; pos < rv.length; pos++) {
                if (rv[pos] == '"' || rv[pos] == '\\') {
                    r ~= rv[start .. pos] ~ '\\' ~ rv[pos];
                    start = pos + 1;
                }
            }
            if (start < rv.length) r ~= rv[start .. $];
            r ~= '"';
            return r;
        }).join(",");
    } else static if (isBoolean!TI) {
        result ~= value.map!((v) => (v ? "t" : "f").to!(char[])).join(",");
    } else static if (isIntegral!TI && isUnsigned!TI) {
        // Unsigned integers still use TEXT via convertToPG
        result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
    } else {
        // Signed integers, floats, Date, DateTime, SysTime: use to!string
        result ~= value.map!((v) => v.to!(char[])).join(",");
    }
    result ~= "}";
    return result;
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe if (isArray!T && !isSomeString!T) {
    alias TI = ElementType!T;

    static if ((isIntegral!TI && isSigned!TI) || isBoolean!TI || isFloatingPoint!TI ||
               is(TI == Date) || is(TI == DateTime) || is(TI == SysTime)) {
        // Build PostgreSQL binary array format for binary-capable element types.
        // Binary array layout:
        //   [int32 ndims=1][int32 flags=0][int32 elem_oid]
        //   [int32 dim_len][int32 lower_bound=1]
        //   [per element: int32 elem_len, elem_len bytes of element data]
        PGType elemType = convertToPG!(TI)(TI.init).type;
        PGType arrType  = getPgTypeInfo(elemType).array_type;

        if (value.length == 0) {
            // Empty binary array: just the header with dim_len=0
            ubyte[] buf;
            buf ~= nativeToBigEndian!int(1)[];          // ndims
            buf ~= nativeToBigEndian!int(0)[];          // flags
            buf ~= nativeToBigEndian!int(cast(int)elemType)[];  // element OID
            buf ~= nativeToBigEndian!int(0)[];          // dim_len = 0
            buf ~= nativeToBigEndian!int(1)[];          // lower_bound
            return PGValue(arrType, PGFormat.BINARY, cast(char[])buf);
        }

        ubyte[] buf;
        buf.reserve(20 + value.length * 12);  // rough estimate
        buf ~= nativeToBigEndian!int(1)[];                        // ndims
        buf ~= nativeToBigEndian!int(0)[];                        // flags
        buf ~= nativeToBigEndian!int(cast(int)elemType)[];        // element OID
        buf ~= nativeToBigEndian!int(cast(int)value.length)[];    // dim_len
        buf ~= nativeToBigEndian!int(1)[];                        // lower_bound

        foreach (v; value) {
            auto pv = convertToPG(v);
            buf ~= nativeToBigEndian!int(pv.length)[];
            // Copy binary element bytes one-by-one (cast(ubyte[]) is @system)
            foreach (b; pv.value) buf ~= cast(ubyte)b;
        }
        return PGValue(arrType, PGFormat.BINARY, cast(char[])buf);

    } else {
        // Text array format for strings, JSON, unsigned integers, nested arrays.
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
        static if (isIntegral!TI && isUnsigned!TI) {
            // Unsigned integers: TEXT via convertToPG, no quoting needed
            result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
        } else static if (isArray!TI && !isSomeString!TI) {
            // Nested arrays: use recursive text formatter.
            // Cannot use convertToPG(v)[0..$-1] here because inner arrays of
            // binary-capable element types (signed int, bool, float, …) now
            // return BINARY from convertToPG, not a text literal.
            result ~= value.map!((v) => pgTextArrayLiteral(v)).join(",");
        } else {
            // Case when array is array of strings or JSON. Special handling here to
            // escape resulting array correctly
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
}


// Test that convertion of string with null is not allowed
unittest {
    import std.exception: assertThrown;
    import core.exception: AssertError;
    convertToPG("t1\0; H").assertThrown!AssertError;
}

// Test that array element quoting/escaping in convertToPG works correctly
unittest {
    auto v = convertToPG!(string[])([`a"b`, `c\d`]);
    auto s = v.value[0 .. $ - 1].idup; // skip terminating NUL
    assert(s == `{"a\"b","c\\d"}`);

    // Test if last symbol in element of array string escaped
    assert(convertToPG!(string[])([`a"b`, `c\`]).value[0 .. $ - 1] == `{"a\"b","c\\"}`);

    assert(
        convertToPG!(string[][])(
            [
                [`a"b`, `c\`],
                [`ag"42`, `mix"`],
            ]
        ).value[0 .. $ - 1] == `{{"a\"b","c\\"},{"ag\"42","mix\""}}`
    );
}

// Test that binary integer conversion produces correct big-endian bytes
unittest {
    import std.bitmanip: bigEndianToNative;

    auto v = convertToPG(42);
    assert(v.format == PGFormat.BINARY);
    assert(v.type == PGType.INT4);
    assert(v.length == 4);
    assert(bigEndianToNative!int(cast(ubyte[4])v.value[0..4]) == 42);

    auto v2 = convertToPG(-1L);
    assert(v2.type == PGType.INT8);
    assert(v2.length == 8);
    assert(bigEndianToNative!long(cast(ubyte[8])v2.value[0..8]) == -1L);

    // Unsigned still uses TEXT
    auto v3 = convertToPG(42u);
    assert(v3.format == PGFormat.TEXT);
    assert(v3.type == PGType.NUMERIC);
}

// Test that binary float conversion produces correct bytes
unittest {
    import std.bitmanip: bigEndianToNative;
    import std.math: isNaN, isInfinity;

    auto vf = convertToPG(1.0f);
    assert(vf.format == PGFormat.BINARY);
    assert(vf.type == PGType.FLOAT4);
    assert(bigEndianToNative!float(cast(ubyte[4])vf.value[0..4]) == 1.0f);

    auto vd = convertToPG(double.nan);
    assert(isNaN(bigEndianToNative!double(cast(ubyte[8])vd.value[0..8])));

    auto vinf = convertToPG(double.infinity);
    assert(isInfinity(bigEndianToNative!double(cast(ubyte[8])vinf.value[0..8])));
}

// Test that binary bool conversion is correct
unittest {
    import std.bitmanip: bigEndianToNative;

    auto vt = convertToPG(true);
    assert(vt.format == PGFormat.BINARY);
    assert(vt.type == PGType.BOOL);
    assert(vt.length == 1);
    assert(cast(ubyte)(vt.value[0]) == 1);

    auto vf = convertToPG(false);
    assert(cast(ubyte)(vf.value[0]) == 0);
}
