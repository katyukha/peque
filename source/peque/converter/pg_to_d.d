/// This module defines functions used to convert libpq values to d types
module peque.converter.pg_to_d;

private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint,
    isArray;
private import std.range: ElementType;
private import std.format;
private import std.conv;
private import std.datetime;
private import std.exception;

private import peque.pg_type;
private import peque.exception;

//TODO: Handle nullable types here

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
    static if (isIntegral!T || isFloatingPoint!T)
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
