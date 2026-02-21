/// This module defines functions used to convert libpq values to d types
module peque.converter.pg_to_d;

private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint,
    isArray, isSigned, isUnsigned;
private import std.range: ElementType;
private import std.format;
private import std.conv;
private import std.datetime;
private import std.exception;
private import std.bitmanip: bigEndianToNative;
private import std.json: JSONValue, parseJSON;

private import peque.pg_type;
private import peque.exception;

//TODO: Handle nullable types here

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read T from a raw byte pointer in big-endian order.
private T beRead(T)(const(ubyte)* p) @trusted pure nothrow {
    ubyte[T.sizeof] buf;
    buf[] = p[0 .. T.sizeof];
    return bigEndianToNative!T(buf);
}

/** Parse a PostgreSQL NUMERIC binary value into a long.
  *
  * PostgreSQL NUMERIC binary layout:
  *   int16 ndigits  — number of base-10000 digits
  *   int16 weight   — most-significant digit weight (power of 10000)
  *   int16 sign     — 0x0000 pos, 0x4000 neg, 0xC000 NaN, 0xD000 +Inf, 0xF000 -Inf
  *   int16 dscale   — display scale (ignored for integer conversion)
  *   int16[ndigits] — base-10000 digits (most significant first)
  **/
private long numericBinaryToLong(const(ubyte)* p, int len) @trusted {
    short ndigits = beRead!short(p);
    short weight  = beRead!short(p + 2);
    short sign    = beRead!short(p + 4);

    enforce!ConversionError(sign != cast(short)0xC000,
        "Cannot convert NUMERIC NaN to integer");
    enforce!ConversionError(
        sign != cast(short)0xD000 && sign != cast(short)0xF000,
        "Cannot convert NUMERIC Infinity to integer");

    if (ndigits == 0) return 0L;

    long value = 0;
    foreach (i; 0 .. cast(int)ndigits)
        value = value * 10_000 + beRead!short(p + 8 + i * 2);

    // weight = index of most-significant digit's position (0 = ones, 1 = 10000s, ...)
    // We have ndigits digits, occupying positions weight .. weight-ndigits+1.
    // Any positions below 0 (i.e. trailing_zeros < 0) represent fractional parts,
    // which we truncate.
    int trailing = weight - ndigits + 1;
    foreach (_; 0 .. trailing) value *= 10_000;

    return sign == cast(short)0x4000 ? -value : value;
}

/// Parse a PostgreSQL NUMERIC binary value into a double.
private double numericBinaryToDouble(const(ubyte)* p, int len) @trusted {
    short ndigits = beRead!short(p);
    short weight  = beRead!short(p + 2);
    short sign    = beRead!short(p + 4);

    if (sign == cast(short)0xC000) return double.nan;
    if (sign == cast(short)0xD000) return double.infinity;
    if (sign == cast(short)0xF000) return -double.infinity;

    if (ndigits == 0) return 0.0;

    double value = 0.0;
    foreach (i; 0 .. cast(int)ndigits)
        value = value * 10_000.0 + beRead!short(p + 8 + i * 2);

    int trailing = weight - ndigits + 1;
    foreach (_; 0 .. trailing) value *= 10_000.0;
    // Trailing < 0 means fractional part: adjust by dividing
    if (trailing < 0) {
        foreach (_; 0 .. -trailing) value /= 10_000.0;
    }

    return sign == cast(short)0x4000 ? -value : value;
}


// ─────────────────────────────────────────────────────────────────────────────
// Text format converters (used by exec() and legacy execParams text results)
// ─────────────────────────────────────────────────────────────────────────────

/** Convert postgresql's text type value to D type T
  *
  * Params:
  *     data = pointer to data received from libpq result.
  *     length = length of data received from libpq result.
  *     pg_type = postgresql type of received data
  *
  * Returns:
  *     Data converted to type T
  **/
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isSomeString!T) {
    // It seems that it is safe to convert any string postgres string types
    // to string this way.
    return data ? cast(T)data[0 .. length].idup : "";
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isScalarType!T) {
    // We have to take into account postgres types here
    static if (isFloatingPoint!T) {
        // Handle PostgreSQL's special float representations before std.conv
        auto s = data[0 .. length];
        if (s == "Infinity" || s == "infinity") return T.infinity;
        if (s == "-Infinity" || s == "-infinity") return -T.infinity;
        if (s == "NaN" || s == "nan") return T.nan;
        return s.to!T;
    } else static if (isIntegral!T)
        return data[0 .. length].to!T;
    else static if (isBoolean!T)
        switch (data[0 .. length]) {
            case "t":
                return true;
            case "f":
                return false;
            default:
                assert(0, "Cannot parse boolean value from postgres: " ~ data[0 .. length].idup);
        }
    else
        static assert(0, "Unsupported scalar type " ~ T.stringof);
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == Date)) {
    switch(pg_type) {
        case PGType.GUESS:
        case PGType.DATE:
        case PGType.TIMESTAMP:
        case PGType.TIMESTAMPTZ:
            enforce!ConversionError(
                length >= 10,
                "Cannot parse date '%s' from postgres".format(data[0 .. length]));
            return Date.fromISOExtString(data[0 .. 10]);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == DateTime)) {
        import std.datetime.timezone;
    switch(pg_type) {
        case PGType.GUESS:
        case PGType.TIMESTAMP:
        case PGType.TIMESTAMPTZ:
            return DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. 19]);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
//pure
@trusted if (is(T == SysTime)) {
    import std.datetime.timezone;
    switch(pg_type) {
        case PGType.GUESS:
            enforce!ConversionError(
                length >= 19,
                "Cannot parse value as timestamp: value is too short");
            if (length == 19)
                // no timezone suffix: treat as UTC timestamp
                return SysTime(DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. 19]), UTC());
            else
                // timezone suffix present: parse as timestamp with timezone
                return SysTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. length]);
        case PGType.TIMESTAMP:
            return SysTime(DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. 19]), UTC());
        case PGType.TIMESTAMPTZ:
            return SysTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. length]);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == JSONValue)) {
    switch(pg_type) {
        case PGType.GUESS:
        case PGType.JSON:
        case PGType.JSONB:
            return parseJSON(data[0 .. length].idup);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (isArray!T && !isSomeString!T) {
    if (length <= 2)
        return T.init;
    enforce!ConversionError(
        data[0] == '{',
        "Value is not array!\n Value: %s".format(data[0 .. length]));
    enforce!ConversionError(
        data[1] != '{',
        "Multidimentional arrays are not supported at the moment");
    T result;
    bool quoted = false;        // opened quote
    bool backslash = false;     // opened backslash
    bool quoted_value = false;  // if value is quoted
    for(uint start=1, pos=1; pos < length; pos++) {
        switch(data[pos]) {
            case '\"':
                if (!quoted && !backslash)
                    // start quote of value
                    quoted = true;
                else if(backslash)
                    // escaped quote inside quoted string
                    backslash = false;
                else if (quoted) {
                    // second unescaped quote
                    quoted = false;
                    quoted_value = true;  // enable parsing of quoted value
                }
                break;
            case '\\':
                if (backslash)
                    // Escaped backslash
                    backslash = false;
                else
                    backslash = true;
                break;
            case ',', '}':
                if (!backslash && !quoted) {
                    if (quoted_value ) {

                        // TODO: determine if backslashes were found in base loop
                        //       and if there is no backslashes in array, then there is no need to unescape them
                        char[] tmp_value;
                        tmp_value.reserve(pos - start);
                        uint ts = start + 1; // start iteration just after first quote

                        /* This loop is needed here to handle backslashes in output of psycopg2
                         * If we encounter backslash, then we just skip it
                         * and add to array escaped symbol
                         */
                        for(uint t=ts; t < pos-1; t++) {
                            if (data[t] == '\\') {
                                // Add to value data before backslash
                                tmp_value ~= data[ts .. t];
                                // skip back slash and move to next element just after backslash
                                ts = t + 1;
                                t += 1;
                            }
                        }
                        if (ts < (pos -1))
                            // if we have something not added yet to tmp_value,
                            // add it
                            tmp_value ~= data[ts .. pos - 1];

                        result ~= convertTextTypeToD!(ElementType!T)(&tmp_value[0], cast(int)tmp_value.length, PGType.GUESS);
                        quoted_value = false;
                    } else {
                        result ~= convertTextTypeToD!(ElementType!T)(&data[start], pos-start, PGType.GUESS);
                    }

                    start = pos + 1;  // on next iteration pos will be +1, so pos and start will be equal;
                }
                break;
            default:
                continue;
        }
    }
    return result;
}


// ─────────────────────────────────────────────────────────────────────────────
// Binary format converters (used by execParams() binary results)
// ─────────────────────────────────────────────────────────────────────────────

/** Convert postgresql's binary type value to D type T.
  *
  * Params:
  *     data = pointer to binary data received from libpq result.
  *     length = length of data received from libpq result.
  *     pg_type = postgresql type OID of received data
  **/
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isSomeString!T) {
    return data ? cast(T)data[0 .. length].idup : "";
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isBoolean!T) {
    return (cast(const ubyte*)data)[0] != 0;
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isIntegral!T && isSigned!T) {
    auto p = cast(const ubyte*)data;
    switch(pg_type) {
        case PGType.INT2:
        case PGType.BOOL:
        case PGType.GUESS:
            return cast(T)beRead!short(p);
        case PGType.INT4:
            return cast(T)beRead!int(p);
        case PGType.INT8:
            return cast(T)beRead!long(p);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto — unsigned integers may come back as NUMERIC binary (when sent as NUMERIC text)
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (isIntegral!T && isUnsigned!T) {
    auto p = cast(const ubyte*)data;
    switch(pg_type) {
        case PGType.NUMERIC:
            return cast(T)numericBinaryToLong(p, length);
        case PGType.INT2:
            return cast(T)beRead!short(p);
        case PGType.INT4:
            return cast(T)beRead!int(p);
        case PGType.INT8:
            return cast(T)beRead!long(p);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (isFloatingPoint!T) {
    auto p = cast(const ubyte*)data;
    switch(pg_type) {
        case PGType.FLOAT4:
        case PGType.GUESS:
            return cast(T)beRead!float(p);
        case PGType.FLOAT8:
            return cast(T)beRead!double(p);
        case PGType.NUMERIC:
            return cast(T)numericBinaryToDouble(p, length);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == Date)) {
    // DATE binary: int32 days since 2000-01-01
    int days = beRead!int(cast(const ubyte*)data);
    return Date(2000, 1, 1) + dur!"days"(days);
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == DateTime)) {
    // TIMESTAMP binary: int64 microseconds since 2000-01-01 00:00:00
    long usecs = beRead!long(cast(const ubyte*)data);
    return DateTime(2000, 1, 1, 0, 0, 0) + dur!"usecs"(usecs);
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == SysTime)) {
    // TIMESTAMPTZ binary: int64 microseconds since 2000-01-01 00:00:00 UTC
    import std.datetime.timezone: UTC;
    long usecs = beRead!long(cast(const ubyte*)data);
    return SysTime(DateTime(2000, 1, 1, 0, 0, 0), UTC()) + dur!"usecs"(usecs);
}

/// ditto
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == JSONValue)) {
    switch(pg_type) {
        case PGType.JSON:
        case PGType.GUESS:
            // JSON binary: raw UTF-8 bytes
            return parseJSON(data[0 .. length].idup);
        case PGType.JSONB:
            // JSONB binary: 0x01 version byte + raw UTF-8
            enforce!ConversionError(length >= 1, "JSONB binary data too short");
            enforce!ConversionError(
                cast(ubyte)data[0] == 0x01, "Unknown JSONB binary version");
            return parseJSON(data[1 .. length].idup);
        default:
            assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto — parse PostgreSQL binary array format
T convertBinaryTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (isArray!T && !isSomeString!T) {
    alias TI = ElementType!T;

    // Binary array layout:
    //   int32 ndims
    //   int32 flags  (bit 0 = has null bitmap)
    //   int32 element_oid
    //   [ndims times:] int32 dim_len, int32 lower_bound
    //   [per element:] int32 elem_len (-1 = NULL), elem_len bytes
    const(ubyte)* p = cast(const ubyte*)data;

    int ndims    = beRead!int(p);
    // flags     = beRead!int(p + 4);  // ignored
    int elem_oid = beRead!int(p + 8);

    enforce!ConversionError(ndims <= 1,
        "Multi-dimensional arrays are not supported");

    if (ndims == 0) return T.init;

    int dim_len = beRead!int(p + 12);
    // lower_bound = beRead!int(p + 16);  // always 1, ignored

    T result;
    result.reserve(dim_len);
    int offset = 20;  // past header (5 × int32)

    foreach (_; 0 .. dim_len) {
        int elem_len = beRead!int(p + offset);
        offset += 4;
        if (elem_len == -1) {
            result ~= TI.init;  // NULL element
        } else {
            result ~= convertBinaryTypeToD!TI(
                cast(char*)(p + offset), elem_len, cast(PGType)elem_oid);
            offset += elem_len;
        }
    }
    return result;
}
