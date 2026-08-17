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
private import std.json: JSONValue, parseJSON;
private import std.uuid: UUID;
private import std.typecons: Nullable;

private import peque.pg_type;
private import peque.exception;

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
    // Transcode via std.conv.to: for `string` this is a plain immutable dup
    // of the libpq bytes, and for `wstring`/`dstring` it decodes the UTF-8
    // payload and re-encodes to the wider code unit. A raw `cast(T)` would
    // reinterpret the UTF-8 bytes as wchar/dchar and yield garbage.
    if (data is null)
        return T.init;
    return data[0 .. length].to!T;
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == Nullable!U, U)) {
    // Wrap value in nullable type
    static if (is(T == Nullable!U, U))
        return T(convertTextTypeToD!U(data, length, pg_type));
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (isScalarType!T) {
    // We have to take into account postgres types here
    static if (isIntegral!T)
        return data[0 .. length].to!T;
    else static if (isFloatingPoint!T) {
        auto s = data[0 .. length];
        if (s == "NaN")       return T.nan;
        if (s == "Infinity")  return T.infinity;
        if (s == "-Infinity") return -T.infinity;
        // Correctly rounded on every platform — std.conv parses through
        // `real` and loses the last ulp where real == double.
        import peque.converter.decimal: parseExactFloat;
        return parseExactFloat!T(s);
    }
    else static if (isBoolean!T)
        switch (data[0 .. length]) {
            case "t":
                return true;
            case "f":
                return false;
            default:
                throw new ConversionError(
                    "Cannot parse boolean value from postgres: " ~ data[0 .. length].idup);
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
            throw new ConversionError(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
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
            enforce!ConversionError(
                length >= 19,
                "Cannot parse DateTime '%s' from postgres: value is too short".format(
                    data[0 .. length]));
            return DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. 19]);
        default:
            throw new ConversionError(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
// Parse "+HH", "+HH:MM" or "+HH:MM:SS" into a signed Duration.
private Duration _parseUtcOffset(scope const(char)[] off) {
    immutable sign = (off[0] == '-') ? -1 : 1;
    immutable h    = to!int(off[1 .. 3]);
    immutable m    = (off.length >= 6) ? to!int(off[4 .. 6]) : 0;
    immutable sec  = (off.length >= 9) ? to!int(off[7 .. 9]) : 0;
    return dur!"seconds"(sign * (h * 3600 + m * 60 + sec));
}

/** Parse a PostgreSQL `timestamptz` rendering into a SysTime.
  *
  * Normally delegates straight to SysTime.fromISOExtString. Two renderings it
  * cannot handle are dealt with here, both produced by ordinary values:
  *
  *  - a UTC offset carrying SECONDS, e.g. "1883-11-18 14:02:04+02:02:04".
  *    PostgreSQL renders timestamps predating the zone's adoption of standard
  *    time in local mean time, whose offset is not a whole number of minutes,
  *    and std.datetime rejects a seconds component outright.
  *  - a " BC" era suffix, e.g. "0001-12-31 19:03:58-04:56:02 BC". Any zone with
  *    a negative offset pushes year 1 back across the era boundary.
  *
  * Neither is exotic: SysTime.init round-tripped through a timestamptz column
  * hits the first in Europe/Kyiv and both in America/New_York, and any
  * historical date before the 1880s hits the first.
  *
  * For those cases the offset is parsed here and the wall-clock part is read as
  * UTC and shifted by it, which is exact. PostgreSQL's BC years are converted
  * to astronomical numbering (1 BC == year 0), which D represents natively.
  * The result is in UTC rather than a fixed-offset zone — the same instant —
  * while the ordinary whole-minute path is left untouched.
  **/
private SysTime _parseTimestampTz(scope const(char)[] str) @trusted {
    import std.datetime.timezone: UTC;

    auto s = str;
    bool bc = false;
    if (s.length > 3 && s[$ - 3 .. $] == " BC") {
        bc = true;
        s = s[0 .. $ - 3];
    }

    // The date part carries '-' separators, so only look past it.
    ptrdiff_t ofs = -1;
    if (s.length > 10)
        foreach_reverse (i; 10 .. s.length)
            if (s[i] == '+' || s[i] == '-') { ofs = i; break; }

    immutable secondsOffset = ofs > 0 && (s.length - ofs) == 9;
    if (!bc && !secondsOffset)
        return SysTime.fromISOExtString(s[0 .. 10] ~ "T" ~ s[11 .. $]);

    immutable delta = (ofs > 0) ? _parseUtcOffset(s[ofs .. $]) : Duration.zero;
    auto localPart  = (ofs > 0) ? s[0 .. ofs] : s;

    // Year field runs to the first '-'; PostgreSQL counts BC years from 1,
    // astronomical numbering from 0.
    size_t dash = 0;
    while (dash < localPart.length && localPart[dash] != '-') ++dash;
    int year = to!int(localPart[0 .. dash]);
    if (bc) year = 1 - year;

    auto rest = localPart[dash .. $];        // "-MM-DD HH:MM:SS[.frac]"
    size_t sp = 0;
    while (sp < rest.length && rest[sp] != ' ') ++sp;

    // Years outside 0..9999 need an explicit sign in ISO extended format.
    immutable ys = (year < 0) ? format("-%04d", -year) : format("%04d", year);
    return SysTime.fromISOExtString(
        ys ~ rest[0 .. sp] ~ "T" ~ rest[sp + 1 .. $] ~ "Z") - delta;
}

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
                return _parseTimestampTz(data[0 .. length]);
        case PGType.TIMESTAMP:
            return SysTime(DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. 19]), UTC());
        case PGType.TIMESTAMPTZ:
            return _parseTimestampTz(data[0 .. length]);
        default:
            throw new ConversionError(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == UUID)) {
    return UUID(data[0 .. length].idup);
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
            throw new ConversionError(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
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

                        // A quoted value is always a literal — a quoted "NULL"
                        // is the string "NULL", not a SQL NULL.
                        result ~= convertTextTypeToD!(ElementType!T)(tmp_value.ptr, cast(int)tmp_value.length, PGType.GUESS);
                        quoted_value = false;
                    } else if (data[start .. pos] == "NULL") {
                        // An unquoted NULL token is a SQL NULL element.
                        static if (is(ElementType!T == Nullable!U, U))
                            result ~= ElementType!T.init;   // null element
                        else
                            throw new ConversionError(
                                "Array contains a NULL element, but the element " ~
                                "type " ~ ElementType!T.stringof ~ " is not " ~
                                "nullable. Hydrate into Nullable!" ~
                                ElementType!T.stringof ~ "[] instead.");
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


// DateTime: value shorter than 19 bytes must throw ConversionError, not slice OOB.
unittest {
    import std.exception: assertThrown;
    import peque.exception: ConversionError;
    immutable(char)* p = "2023-07-17".ptr;
    convertTextTypeToD!DateTime(p, 10, PGType.TIMESTAMP).assertThrown!ConversionError;
    convertTextTypeToD!DateTime(p, 10, PGType.TIMESTAMPTZ).assertThrown!ConversionError;
    convertTextTypeToD!DateTime(p, 10, PGType.GUESS).assertThrown!ConversionError;
}

// Unparseable boolean text must throw ConversionError rather than assert(0)
// (which is UB when compiled with -release).
unittest {
    import std.exception: assertThrown;
    import peque.exception: ConversionError;
    assert(convertTextTypeToD!bool("t".ptr, 1, PGType.BOOL) == true);
    assert(convertTextTypeToD!bool("f".ptr, 1, PGType.BOOL) == false);
    convertTextTypeToD!bool("x".ptr, 1, PGType.BOOL).assertThrown!ConversionError;
}

// An unexpected pg_type for a date/time/JSON target must throw ConversionError
// rather than assert(0) (UB under -release).
unittest {
    import std.exception: assertThrown;
    import peque.exception: ConversionError;
    immutable(char)* d = "2023-07-17".ptr;
    convertTextTypeToD!Date(d, 10, PGType.INT4).assertThrown!ConversionError;
    immutable(char)* dt = "2023-07-17 10:20:30".ptr;
    convertTextTypeToD!DateTime(dt, 19, PGType.INT4).assertThrown!ConversionError;
    convertTextTypeToD!SysTime(dt, 19, PGType.INT4).assertThrown!ConversionError;
    immutable(char)* j = "{}".ptr;
    convertTextTypeToD!JSONValue(j, 2, PGType.INT4).assertThrown!ConversionError;
}

// String conversion transcodes UTF-8 to wide code units instead of
// reinterpreting the bytes (a raw cast produced garbage for wstring/dstring).
unittest {
    // "áé€" — multi-byte UTF-8 that must decode to the same code points.
    enum src = "áé€";
    immutable bytes = cast(immutable(char)[])src;
    assert(convertTextTypeToD!string(bytes.ptr, cast(int)bytes.length, PGType.TEXT) == src);
    assert(convertTextTypeToD!wstring(bytes.ptr, cast(int)bytes.length, PGType.TEXT) == "áé€"w);
    assert(convertTextTypeToD!dstring(bytes.ptr, cast(int)bytes.length, PGType.TEXT) == "áé€"d);

    // null data yields an empty string of the requested width.
    assert(convertTextTypeToD!string(null, 0, PGType.TEXT) == "");
    assert(convertTextTypeToD!wstring(null, 0, PGType.TEXT) == ""w);
}

// Array NULL elements: an unquoted NULL is a SQL NULL. Nullable!U[] hydrates it
// as an empty element; a non-nullable element type throws ConversionError.
unittest {
    import std.exception: assertThrown;
    import std.typecons: nullable;
    import peque.exception: ConversionError;

    static T conv(T)(string s) {
        return convertTextTypeToD!T(s.ptr, cast(int)s.length, PGType.GUESS);
    }

    // Non-nullable element types reject NULL loudly (no more raw ConvException /
    // literal "NULL" string).
    conv!(int[])("{1,NULL,3}").assertThrown!ConversionError;
    conv!(string[])("{a,NULL}").assertThrown!ConversionError;

    // Nullable!U[] hydrates NULL as an empty element, others as values.
    auto ints = conv!(Nullable!int[])("{1,NULL,3}");
    assert(ints.length == 3);
    assert(ints[0] == 1.nullable);
    assert(ints[1].isNull);
    assert(ints[2] == 3.nullable);

    auto strs = conv!(Nullable!string[])("{a,NULL,c}");
    assert(strs.length == 3);
    assert(strs[0] == "a".nullable);
    assert(strs[1].isNull);
    assert(strs[2] == "c".nullable);
}

// A *quoted* "NULL" is the literal string "NULL", never a SQL NULL.
unittest {
    import std.typecons: nullable;
    static T conv(T)(string s) {
        return convertTextTypeToD!T(s.ptr, cast(int)s.length, PGType.GUESS);
    }

    auto strs = conv!(string[])(`{"NULL",b}`);
    assert(strs.length == 2);
    assert(strs[0] == "NULL");   // preserved as the literal string
    assert(strs[1] == "b");

    auto nstrs = conv!(Nullable!string[])(`{"NULL",b}`);
    assert(nstrs.length == 2);
    assert(!nstrs[0].isNull);
    assert(nstrs[0] == "NULL".nullable);
    assert(nstrs[1] == "b".nullable);
}

// timestamptz with a seconds-bearing UTC offset. PostgreSQL renders timestamps
// predating the zone's switch to standard time in local mean time, whose offset
// is not a whole number of minutes; std.datetime's parser rejects it outright,
// so such rows used to be unreadable.
unittest {
    import std.datetime.timezone: UTC;

    // Europe/Kyiv LMT is +02:02:04. Year 1 — what SysTime.init round-trips to.
    enum y1 = "0001-01-01 02:02:04+02:02:04";
    assert(convertTextTypeToD!SysTime(y1.ptr, cast(int)y1.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(1, 1, 1, 0, 0, 0), UTC()));

    // Not just year 1: anything before the 1880s renders the same way.
    enum hist = "1883-11-18 14:02:04+02:02:04";
    assert(convertTextTypeToD!SysTime(hist.ptr, cast(int)hist.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(1883, 11, 18, 12, 0, 0), UTC()));

    // Negative seconds-bearing offset (e.g. America/New_York LMT -04:56:02).
    enum neg = "1883-11-18 07:03:58-04:56:02";
    assert(convertTextTypeToD!SysTime(neg.ptr, cast(int)neg.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(1883, 11, 18, 12, 0, 0), UTC()));

    // Fractional seconds alongside a seconds-bearing offset.
    enum frac = "1883-11-18 14:02:04.5+02:02:04";
    assert(convertTextTypeToD!SysTime(frac.ptr, cast(int)frac.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(1883, 11, 18, 12, 0, 0), msecs(500), UTC()));

    // " BC" era suffix: any negative offset pushes year 1 across the era
    // boundary, so SysTime.init round-trips through BC in the Americas.
    // PostgreSQL counts BC from 1; D uses astronomical numbering (1 BC == 0).
    enum bcNy = "0001-12-31 19:03:58-04:56:02 BC";
    assert(convertTextTypeToD!SysTime(bcNy.ptr, cast(int)bcNy.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(1, 1, 1, 0, 0, 0), UTC()));

    // BC combined with a whole-minute offset also needs the manual path.
    enum bcPlain = "0002-06-15 10:00:00+02:00 BC";
    assert(convertTextTypeToD!SysTime(bcPlain.ptr, cast(int)bcPlain.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(-1, 6, 15, 8, 0, 0), UTC()));

    // Ordinary whole-hour and whole-minute offsets keep the existing path.
    enum modern = "2026-08-14 11:01:34.013441+03";
    assert(convertTextTypeToD!SysTime(modern.ptr, cast(int)modern.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(2026, 8, 14, 8, 1, 34), usecs(13441), UTC()));
    enum halfHour = "2026-08-14 14:31:34+05:30";
    assert(convertTextTypeToD!SysTime(halfHour.ptr, cast(int)halfHour.length, PGType.TIMESTAMPTZ) ==
           SysTime(DateTime(2026, 8, 14, 9, 1, 34), UTC()));
}
