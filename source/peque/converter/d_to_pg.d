module peque.converter.d_to_pg;

private import std.array;
private import std.conv;
private import std.format;
private import std.datetime;
private import std.algorithm;
private import std.json: JSONValue;
private import std.uuid: UUID;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint, isArray;
private import std.range: ElementType;
private import std.typecons: Nullable;
private import std.exception: enforce;

private import peque.pg_type;
private import peque.pg_format;
private import peque.exception: ConversionError;

/** Struct that represents value to be passed to PQexecParams.
  **/
@safe pure const struct PGValue {
    PGType type;
    PGFormat format = PGFormat.TEXT;
    char[] value;
    bool isNull = false;

    this(PGType type, PGFormat format, in char[] value, in bool is_null=false) @safe pure {
        assert(
            is_null || (value.length > 0 && value[$ - 1] == '\0'),
             "PGValue value must be null-terminated!");
        // Data-driven (huge user value), so a runtime enforce rather than an
        // assert: length() casts to int for the libpq call.
        enforce!ConversionError(
            is_null || value.length < int.max,
             "Too large value length for PGValue!");
        this.type = type;
        this.format = format;
        this.value = value;
        this.isNull = is_null;
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
@safe pure if (isSomeString!T) {
    // libpq receives text-format params as C strings — an embedded NUL would
    // silently truncate the value. Must be a runtime enforce, not a
    // contract/assert: the guard has to survive -release builds.
    enforce!ConversionError(
        !value.canFind('\0'),
        "String value cannot contain null (\\0) characters!");
    return PGValue(PGType.TEXT, PGFormat.TEXT, value.to!(char[]) ~ "\0");
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isIntegral!T) {
    // The declared OID must be the native integer type covering T's range:
    // a NUMERIC-typed parameter compared to an integer column makes the
    // server cast the COLUMN to numeric, which defeats btree indexes
    // (e.g. `WHERE id = $1` degrades to a seq scan).
    // Range checks rather than exact type matches, so unsigned types (which
    // have no PG counterpart) map across automatically: ubyte → INT2,
    // ushort → INT4, uint → INT8.
    static if (T.min >= short.min && T.max <= short.max)
        enum PGType oid = PGType.INT2;
    else static if (T.min >= int.min && T.max <= int.max)
        enum PGType oid = PGType.INT4;
    else static if (T.min >= long.min && T.max <= long.max)
        enum PGType oid = PGType.INT8;
    else
        enum PGType oid = PGType.NUMERIC;  // ulong: exceeds INT8 range
    return PGValue(
        oid,
        PGFormat.TEXT,
        (value.to!(char[]) ~ '\0'),
    );
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (isFloatingPoint!T) {
    import std.math: isNaN, isInfinity;
    // Significant digits needed for an exact round-trip of T's mantissa
    // (9 for float, 17 for double, 21 for 80-bit real, 36 for binary128).
    // Fixed-point formatting must not be used here: it zeroes magnitudes
    // below the fraction width instead of switching to scientific notation.
    enum int fpDigits = 2 + cast(int)(T.mant_dig * 30103L / 100000L);
    enum fpFormat = "%." ~ fpDigits.to!string ~ "g";
    // Same index-friendliness rule as for integrals: declare the matching
    // native float type. FLOAT4/FLOAT8 also accept Infinity on every server
    // version, while NUMERIC does so only since PostgreSQL 14. `real` keeps
    // NUMERIC: FLOAT8 would silently round its extra mantissa bits.
    static if (T.mant_dig <= float.mant_dig)
        enum PGType oid = PGType.FLOAT4;
    else static if (T.mant_dig <= double.mant_dig)
        enum PGType oid = PGType.FLOAT8;
    else
        enum PGType oid = PGType.NUMERIC;
    string v;
    if (value.isNaN)           v = "NaN";
    else if (value.isInfinity) v = value > 0 ? "Infinity" : "-Infinity";
    else static if (T.mant_dig <= double.mant_dig) {
        v = format(fpFormat, value);
    } else {
        // Reals wider than double: Phobos formats binary128 at double
        // precision only, so use the exact engine.
        import peque.converter.decimal: formatExact;
        v = formatExact(value, fpDigits);
    }
    return PGValue(
        oid,
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
        PGType.JSONB,
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
    static if ((isIntegral!TI || isFloatingPoint!TI || isBoolean!TI ||
                is(TI == Date) || is(TI == DateTime) || is(TI == SysTime)) ||
               (isArray!TI && !isSomeString!TI)) {
        // No quoting needed — numeric, boolean, date, or nested array types
        result ~= value.map!((v) => convertToPG(v).value[0 .. $-1]).join(",");
    } else {
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


/// ditto
PGValue convertToPG(T)(in T value)
@safe pure if (is(T == UUID)) {
    return PGValue(PGType.UUID, PGFormat.TEXT, value.toString().to!(char[]) ~ '\0');
}

/// ditto — Nullable: sends SQL NULL when empty, delegates to inner type when set
PGValue convertToPG(T)(in T value)
@safe if (is(T == Nullable!U, U)) {
    // Re-bind U inside the function body; the constraint's alias is not in scope here.
    static if (is(T == Nullable!Inner, Inner)) {
        if (value.isNull)
            return PGValue(convertToPG!Inner(Inner.init).type, PGFormat.TEXT, value: null, is_null: true);
        return convertToPG!Inner(value.get);
    } else {
        static assert(false, "Unreachable");
    }
}


// Test that conversion of string with null is not allowed
// (must throw ConversionError — a catchable exception that survives -release)
unittest {
    import std.exception: assertThrown;
    convertToPG("t1\0; H").assertThrown!ConversionError;
}

// Test that numeric params are declared with native OIDs — a NUMERIC-typed
// parameter compared to an integer column casts the column to numeric and
// defeats btree indexes.
unittest {
    assert(convertToPG(byte(1)).type    == PGType.INT2);
    assert(convertToPG(ubyte(1)).type   == PGType.INT2);
    assert(convertToPG(short(1)).type   == PGType.INT2);
    assert(convertToPG(ushort(1)).type  == PGType.INT4);
    assert(convertToPG(1).type          == PGType.INT4);
    assert(convertToPG(1u).type         == PGType.INT8);
    assert(convertToPG(1L).type         == PGType.INT8);
    assert(convertToPG(1uL).type        == PGType.NUMERIC);
    assert(convertToPG(1.0f).type       == PGType.FLOAT4);
    assert(convertToPG(1.0).type        == PGType.FLOAT8);
    assert(convertToPG([1, 2]).type     == PGType._INT4);
    assert(convertToPG([1.0, 2.0]).type == PGType._FLOAT8);
}

// Test that float serialization is round-trip exact for tiny and precise
// magnitudes (fixed-point "%.20f" used to zero anything below ~5e-21).
unittest {
    import std.math: nextUp;

    static string pgText(T)(T v) {
        return convertToPG(v).value[0 .. $ - 1].idup;
    }

    assert(pgText(1.5e-25).to!double == 1.5e-25);
    // smallest subnormal double — spelled via nextUp(0.0) because ldc2's
    // lexer rejects the 4.9e-324 literal as "not representable"
    immutable minSub = nextUp(0.0);
    assert(pgText(-minSub).to!double == -minSub);
    assert(pgText(1.2345678901234567e-10).to!double == 1.2345678901234567e-10);
    assert(pgText(double.max).to!double == double.max);
    assert(pgText(1.5f).to!float == 1.5f);
    assert(pgText(1.1754944e-38f).to!float == 1.1754944e-38f);  // near float.min_normal
    static if (real.mant_dig <= 64) {
        assert(pgText(3.14L).to!real == 3.14L);
    } else {
        // binary128: emission is exact, but std.conv.to!real may lose the
        // last ulp when parsing back — compare mantissa agreement.
        import std.math: feqrel;
        assert(pgText(3.14L).to!double == 3.14);
        assert(feqrel(pgText(3.14L).to!real, 3.14L) >= real.mant_dig - 2);
    }
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
