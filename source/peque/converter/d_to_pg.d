module peque.converter.d_to_pg;

private import std.array;
private import std.conv;
private import std.format;
private import std.datetime;
private import std.algorithm;
private import std.json: JSONValue;
private import std.uuid: UUID;
private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint, isArray,
    Unqual;
private import std.range: ElementType;
private import std.typecons: Nullable;

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
        if (!(is_null || value.length < int.max))
            throw new ConversionError(
                "Too large value length for PGValue!",
                "char[]", type.to!string, "");
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
    import std.exception: enforce;
    import std.string: indexOf;

    // std.string.indexOf, not countUntil: it scans code units without decoding,
    // so it is cheaper on this hot path (every string parameter passes through
    // here), reports an index consistent with value.length, and keeps the NUL
    // check independent of whether the string is valid UTF.
    //
    // libpq takes text-format params as C strings, so an embedded NUL would
    // silently truncate the value. A runtime check, not a contract/assert: the
    // guard has to survive -release builds.
    //
    // The value itself is never attached to the error — only where the NUL is.
    // convertToPG runs on every string parameter, so echoing it would put
    // passwords and other secrets into an exception that usually reaches a log.
    immutable nulAt = value.indexOf('\0');
    enforce(nulAt < 0, new ConversionError(
        format!("String value cannot contain null (\\0) characters " ~
                "(found at index %d of %d)")(nulAt, value.length),
        T.stringof, "text"));

    // Transcoding validates UTF, so a wstring/dstring holding a lone surrogate
    // raises std.utf's UnicodeException. Translate it: everything peque throws
    // must derive from PequeException.
    //
    // A narrow string needs no transcoding and so is not validated here — that
    // would cost a full UTF-8 scan of every string parameter. PostgreSQL
    // rejects invalid bytes itself with SQLSTATE 22021.
    try
        return PGValue(PGType.TEXT, PGFormat.TEXT, value.to!(char[]) ~ "\0");
    catch (Exception e)
        throw new ConversionError(
            "String value is not valid UTF: " ~ e.msg, T.stringof, "text", "", e);
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

/** PostgreSQL's spelling of a D ISO-extended date/timestamp.
  *
  * Only the year is rewritten; the rest of D's output parses as-is. The two
  * disagree at both ends of the range:
  *
  *  - D numbers years astronomically and writes `-0001-06-15`; PostgreSQL has
  *    no negative years — it counts BC from 1 and wants `0002-06-15 BC`.
  *  - Past 9999 D writes a leading `+`, which PostgreSQL reads as the start of
  *    a UTC offset ("time zone displacement out of range").
  **/
private char[] _pgCalendarText(scope const(char)[] iso, in int year) @safe pure {
    // The year runs to the first '-' that is not its own sign.
    size_t i = (iso.length > 0 && (iso[0] == '-' || iso[0] == '+')) ? 1 : 0;
    while (i < iso.length && iso[i] != '-') ++i;
    auto rest = iso[i .. $];        // "-MM-DD[T…]"

    if (year > 0)
        return (format!"%04d"(year) ~ rest).to!(char[]);
    return (format!"%04d"(1 - year) ~ rest ~ " BC").to!(char[]);
}


/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(Unqual!T == Date)) {
    return PGValue(PGType.DATE, PGFormat.TEXT,
                   _pgCalendarText(value.toISOExtString, value.year) ~ '\0');
}

/// ditto
PGValue convertToPG(T) (in T value)
@safe pure if (is(Unqual!T == DateTime)) {
    return PGValue(PGType.TIMESTAMP, PGFormat.TEXT,
                   _pgCalendarText(value.toISOExtString, value.year) ~ '\0');
}

/** ditto
  *
  * Normalised to UTC first, so the value means the same thing on every server.
  * Without it a `SysTime` in `LocalTime()` — what `Clock.currTime` returns —
  * renders with no UTC offset at all, and PostgreSQL reads the naked wall clock
  * in the session TimeZone. Nothing is lost by sending UTC: timestamptz stores
  * an instant and discards the input offset anyway.
  **/
PGValue convertToPG(T) (in T value)
@safe if (is(Unqual!T == SysTime)) {
    // The year must come from the UTC value: converting can cross a boundary.
    auto utc = value.toUTC;
    return PGValue(
        PGType.TIMESTAMPTZ,
        PGFormat.TEXT,
        _pgCalendarText(utc.toISOExtString, utc.year) ~ '\0',
    );
}

/// ditto
PGValue convertToPG(T)(in T value)
@safe if (is(Unqual!T == JSONValue)) {
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
                is(Unqual!TI == Date) || is(Unqual!TI == DateTime) ||
                is(Unqual!TI == SysTime)) ||
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
@safe pure if (is(Unqual!T == UUID)) {
    return PGValue(PGType.UUID, PGFormat.TEXT, value.toString().to!(char[]) ~ '\0');
}

/// ditto — Nullable: sends SQL NULL when empty, delegates to inner type when set
PGValue convertToPG(T)(in T value)
@safe if (is(Unqual!T == Nullable!U, U)) {
    // Re-bind U inside the function body; the constraint's alias is not in scope here.
    static if (is(Unqual!T == Nullable!Inner, Inner)) {
        if (value.isNull)
            return PGValue(convertToPG!Inner(Inner.init).type, PGFormat.TEXT, value: null, is_null: true);
        return convertToPG!Inner(value.get);
    } else {
        static assert(false, "Unreachable");
    }
}


// String parameters: embedded NUL, invalid UTF, and what the error may reveal.
unittest {
    import std.exception: assertThrown, collectException;
    import std.algorithm.searching: canFind;

    // An embedded NUL is rejected for every string width — libpq would
    // otherwise silently truncate the value at that byte.
    convertToPG("t1\0; H").assertThrown!ConversionError;
    convertToPG("t1\0; H"w).assertThrown!ConversionError;
    convertToPG("t1\0; H"d).assertThrown!ConversionError;

    // The reported index counts code units, so it lines up with .length rather
    // than with decoded characters (indexOf, not countUntil).
    enum multibyte = "héllo\0x";          // 'é' occupies two bytes
    auto nul = collectException!ConversionError(convertToPG(multibyte));
    assert(nul !is null);
    assert(nul.msg.canFind("index 6 of 8"), nul.msg);

    // The value never appears in the error: convertToPG runs on every string
    // parameter, so echoing it would leak secrets into logs.
    auto secret = collectException!ConversionError(convertToPG("hunter2\0pw"));
    assert(secret !is null);
    assert(secret.value == "");
    assert(!secret.msg.canFind("hunter2"), secret.msg);

    // A lone surrogate is invalid UTF; transcoding raises std.utf's
    // UnicodeException, which must not escape peque's hierarchy.
    wstring loneSurrogate = cast(wstring)[cast(wchar)0xD800, 'A'];
    auto utf = collectException!ConversionError(convertToPG(loneSurrogate));
    assert(utf !is null, "invalid UTF must raise ConversionError");
    assert(utf.msg.canFind("not valid UTF"), utf.msg);
    assert(utf.value == "", "an invalid parameter must not be echoed either");
    assert(utf.next !is null, "the original UnicodeException must be chained");

    // A dstring holding an invalid code point is rejected the same way.
    dstring badCodePoint = cast(dstring)[cast(dchar)0x110000];
    assertThrown!ConversionError(convertToPG(badCodePoint));

    // A narrow string is NOT validated here: string -> char[] needs no
    // transcoding, so checking it would mean a full UTF-8 scan of every string
    // parameter for something PostgreSQL already rejects precisely (SQLSTATE
    // 22021, "invalid byte sequence for encoding UTF8"). Only wstring/dstring,
    // which must be transcoded anyway, are validated client-side.
    string invalidUtf8 = cast(string)[cast(char)0xFF, cast(char)0xFE];
    assert(convertToPG(invalidUtf8).value.length == 3);   // passed through

    // Valid values of every width still convert.
    assert(convertToPG("ok").value == "ok\0");
    assert(convertToPG("ok"w).value == "ok\0");
    assert(convertToPG("ok"d).value == "ok\0");
    assert(convertToPG("héllo").value == "héllo\0");
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

    // smallest subnormal double — spelled via nextUp(0.0) because ldc2's
    // lexer rejects the 4.9e-324 literal as "not representable"
    immutable minSub = nextUp(0.0);

    // The %.20f regression: tiny magnitudes must switch to scientific
    // notation instead of flushing to zeros.
    assert(pgText(1.5e-25).canFind('e'));
    assert(pgText(-minSub).canFind('e'));

    assert(pgText(1.5f).to!float == 1.5f);
    assert(pgText(1.1754944e-38f).to!float == 1.1754944e-38f);  // near float.min_normal

    // Emission is exact and parseExactFloat is correctly rounded on every
    // platform, so the round-trip is the identity.
    import peque.converter.decimal: parseExactFloat;
    assert(parseExactFloat!double(pgText(1.5e-25)) == 1.5e-25);
    assert(parseExactFloat!double(pgText(-minSub)) == -minSub);
    assert(parseExactFloat!double(pgText(1.2345678901234567e-10))
        == 1.2345678901234567e-10);
    assert(parseExactFloat!double(pgText(double.max)) == double.max);
    assert(parseExactFloat!real(pgText(3.14L)) == 3.14L);
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
