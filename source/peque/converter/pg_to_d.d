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

// ConversionError for a read, carrying the direction and the offending value.
// std.exception.enforce cannot forward extra constructor arguments, so callers
// throw explicitly rather than enforcing.
private ConversionError _readError(T)(
        string msg, in PGType pg_type,
        scope const char* data, in int length,
        Throwable cause = null) pure @trusted {
    return new ConversionError(
        msg, pg_type.to!string, T.stringof,
        (data !is null && length > 0) ? data[0 .. length].idup : "",
        cause);
}

// Run a Phobos parser and translate anything it throws into ConversionError,
// keeping the original message. std.conv, std.datetime, std.json and std.uuid
// each raise their own type; letting those escape would break the guarantee
// that everything peque throws derives from PequeException.
private T _tryParse(T)(lazy T expr, string what, in PGType pg_type,
                       scope const char* data, in int length) pure @trusted {
    try
        return expr();
    catch (PequeException e)
        throw e;                                   // already ours
    catch (Exception e)
        // Chain the original: its type and stack trace are the useful part.
        throw _readError!T(what ~ ": " ~ e.msg, pg_type, data, length, e);
}

// PostgreSQL's date/timestamp rendering -> ISO extended, which Phobos accepts.
//
// Three things differ from ISO. A " BC" suffix means the year is counted from 1
// backwards, while D uses astronomical numbering (1 BC == year 0). Years outside
// 0..9999 need an explicit sign. And the date and time are separated by a space
// rather than 'T'.
//
// Returns null for the "infinity"/"-infinity" sentinels, which are legal
// timestamp values and much shorter than a date, so callers must check the
// flags before indexing.
private const(char)[] _pgTimestampToISO(scope const(char)[] s, out bool infinite,
                                        out bool negInfinite) pure @safe {
    infinite    = (s == "infinity");
    negInfinite = (s == "-infinity");
    if (infinite || negInfinite) return null;

    immutable bc = s.length > 3 && s[$ - 3 .. $] == " BC";
    if (bc) s = s[0 .. $ - 3];

    // Year runs to the first '-' (a leading '-' would be part of the year).
    size_t dash = 0;
    while (dash < s.length && s[dash] != '-') ++dash;
    enforce!ConversionError(dash > 0 && dash < s.length,
        "Cannot parse timestamp: malformed year in: " ~ s.idup);

    int year = to!int(s[0 .. dash]);
    if (bc) year = 1 - year;
    // D stores a year in a short; PostgreSQL goes to 294276. Say so plainly —
    // Phobos would otherwise report a bare "Invalid format".
    enforce!ConversionError(year >= short.min && year <= short.max,
        format!("Year %d is outside the range D can represent (%d .. %d); " ~
                "read the column as text instead.")(year, short.min, short.max));

    const(char)[] ys;
    if (year < 0)          ys = format("-%04d", -year);
    else if (year > 9999)  ys = format("+%04d", year);
    else if (bc)           ys = format("%04d", year);
    else                   ys = s[0 .. dash];   // unchanged — avoid reformatting

    auto rest = s[dash .. $];                   // "-MM-DD[ HH:MM:SS[.frac][+TZ]]"
    // Date and time are space-separated in PostgreSQL, 'T'-separated in ISO.
    size_t sp = 0;
    while (sp < rest.length && rest[sp] != ' ') ++sp;
    if (sp >= rest.length) return ys ~ rest;    // date only
    return ys ~ rest[0 .. sp] ~ "T" ~ rest[sp + 1 .. $];
}

// Index of the 'T' separator in an ISO string produced above, or length when
// the value is date-only. The date part is NOT a fixed 10 characters once the
// year is signed or longer than four digits.
private size_t _isoDateEnd(scope const(char)[] iso) pure @safe nothrow @nogc {
    size_t i = 0;
    while (i < iso.length && iso[i] != 'T') ++i;
    return i;
}

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
    return _tryParse!T(data[0 .. length].to!T,
        "Cannot parse " ~ T.stringof ~ " value", pg_type, data, length);
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
        return _tryParse!T(data[0 .. length].to!T,
            "Cannot parse " ~ T.stringof ~ " value", pg_type, data, length);
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
                throw _readError!T(
                    "Cannot parse boolean value from postgres: " ~ data[0 .. length].idup,
                    pg_type, data, length);
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
            return _tryParse!T({
                    bool inf, negInf;
                    auto iso = _pgTimestampToISO(data[0 .. length], inf, negInf);
                    if (inf)    return Date.max;
                    if (negInf) return Date.min;
                    return Date.fromISOExtString(iso[0 .. _isoDateEnd(iso)]);
                }(), "Cannot parse date", pg_type, data, length);
        default:
            throw _readError!T(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof),
                pg_type, data, length);
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
            return _tryParse!T({
                    bool inf, negInf;
                    auto iso = _pgTimestampToISO(data[0 .. length], inf, negInf);
                    if (inf)    return DateTime.max;
                    if (negInf) return DateTime.min;
                    // Drop any fractional seconds / offset: DateTime has neither.
                    immutable e = _isoDateEnd(iso);
                    enforce!ConversionError(e + 9 <= iso.length,
                        "Cannot parse DateTime from postgres: value is too short");
                    return DateTime.fromISOExtString(iso[0 .. e + 9]);
                }(), "Cannot parse timestamp", pg_type, data, length);
        default:
            throw _readError!T(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof),
                pg_type, data, length);
    }
}

/// ditto
// Parse "+HH", "+HH:MM" or "+HH:MM:SS" into a signed Duration.
// Shape is validated rather than inferred from length: "+0230" would otherwise
// silently read as +02:00 and lose 30 minutes.
private Duration _parseUtcOffset(scope const(char)[] off) {
    enforce!ConversionError(
        off.length == 3 || off.length == 6 || off.length == 9,
        "Malformed UTC offset in timestamp: " ~ off.idup);
    enforce!ConversionError(
        (off.length < 6 || off[3] == ':') && (off.length < 9 || off[6] == ':'),
        "Malformed UTC offset in timestamp: " ~ off.idup);

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
    bool inf, negInf;
    auto iso = _pgTimestampToISO(str, inf, negInf);
    if (inf)    return SysTime.max;
    if (negInf) return SysTime.min;

    // Locate the UTC offset: search past the date, whose length varies once the
    // year is signed or longer than four digits.
    immutable dateEnd = _isoDateEnd(iso);
    enforce!ConversionError(dateEnd < iso.length,
        "Cannot parse timestamp: no time part in: " ~ str.idup);

    ptrdiff_t ofs = -1;
    foreach_reverse (i; dateEnd .. iso.length)
        if (iso[i] == '+' || iso[i] == '-') { ofs = i; break; }

    // A whole-minute offset is what std.datetime accepts; only a seconds-bearing
    // one (local mean time) needs to be applied by hand.
    immutable secondsOffset = ofs > 0 && (iso.length - ofs) == 9;
    if (!secondsOffset)
        return SysTime.fromISOExtString(iso);

    immutable delta = _parseUtcOffset(iso[ofs .. $]);
    return SysTime.fromISOExtString(iso[0 .. ofs] ~ "Z") - delta;
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
            enforce(length >= 19, _readError!T(
                "Cannot parse value as timestamp: value is too short",
                pg_type, data, length));
            if (length == 19)
                // no timezone suffix: treat as UTC timestamp
                return _tryParse!T({
                        bool inf, negInf;
                        auto iso = _pgTimestampToISO(data[0 .. length], inf, negInf);
                        if (inf)    return SysTime.max;
                        if (negInf) return SysTime.min;
                        return SysTime.fromISOExtString(iso ~ "Z");
                    }(), "Cannot parse timestamp", pg_type, data, length);
            else
                // timezone suffix present: parse as timestamp with timezone
                return _tryParse!T(_parseTimestampTz(data[0 .. length]),
                    "Cannot parse timestamp with time zone", pg_type, data, length);
        case PGType.TIMESTAMP:
            return _tryParse!T({
                    bool inf, negInf;
                    auto iso = _pgTimestampToISO(data[0 .. length], inf, negInf);
                    if (inf)    return SysTime.max;
                    if (negInf) return SysTime.min;
                    return SysTime.fromISOExtString(iso ~ "Z");
                }(), "Cannot parse timestamp", pg_type, data, length);
        case PGType.TIMESTAMPTZ:
            return _tryParse!T(_parseTimestampTz(data[0 .. length]),
                "Cannot parse timestamp with time zone", pg_type, data, length);
        default:
            throw _readError!T(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof),
                pg_type, data, length);
    }
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
pure @trusted if (is(T == UUID)) {
    return _tryParse!T(UUID(data[0 .. length].idup),
        "Cannot parse uuid", pg_type, data, length);
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
            return _tryParse!T(parseJSON(data[0 .. length].idup),
                "Cannot parse json", pg_type, data, length);
        default:
            throw _readError!T(
                "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof),
                pg_type, data, length);
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
    enforce(data[0] == '{', _readError!T(
        "Value is not array!\n Value: %s".format(data[0 .. length]),
        pg_type, data, length));
    enforce(data[1] != '{', _readError!T(
        "Multidimensional arrays are not supported at the moment",
        pg_type, data, length));
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
                            throw _readError!T(
                                "Array contains a NULL element, but the element " ~
                                "type " ~ ElementType!T.stringof ~ " is not " ~
                                "nullable. Hydrate into Nullable!" ~
                                ElementType!T.stringof ~ "[] instead.",
                                pg_type, data, length);
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

// Malformed timestamp text must raise ConversionError, never an Error: a bad
// slice would be uncatchable and, under -release, a segfault.
unittest {
    import std.exception: assertThrown;

    static void mustThrow(string v, PGType t = PGType.TIMESTAMPTZ) {
        assertThrown!ConversionError(
            convertTextTypeToD!SysTime(v.ptr, cast(int)v.length, t));
    }

    mustThrow("");                              // empty
    mustThrow("2020-01-01");                    // date only, no time
    mustThrow("0001-01-01 BC");                 // BC, no time part
    mustThrow("1883-11-18 14:02:04+ BC");       // truncated offset
    mustThrow("0001-01-01-01-01-01-01 BC");     // no space separator
    mustThrow("garbage");

    // A whole-minute offset must not be inferred from length alone: "+0230"
    // would otherwise silently read as +02:00 and lose 30 minutes.
    mustThrow("2020-01-01 00:00:00+0230");

    // The forms PostgreSQL does emit still parse.
    enum ok = "2020-01-01 00:00:00+02";
    assert(convertTextTypeToD!SysTime(ok.ptr, cast(int)ok.length, PGType.TIMESTAMPTZ)
           == SysTime(DateTime(2019, 12, 31, 22, 0, 0), UTC()));
}
