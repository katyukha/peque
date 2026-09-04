/** Exact decimal formatting of floating-point values.
  *
  * Phobos's printFloat covers float, double and 80-bit x87 reals, but
  * formats wider reals (IEEE binary128 — `real` on AArch64) at double
  * precision only. This module computes the decimal expansion exactly
  * with integer arithmetic: every finite value is an integer mantissa
  * times a power of two, and m / 2^k == m·5^k / 10^k.
  *
  * API layers:
  *  - exactDecimalDigits — digits + decimal exponent. Decimal consumers
  *    (e.g. a NUMERIC type) should build on this layer: NUMERIC's binary
  *    wire format is the same digits re-chunked in base-10000 groups.
  *  - formatExact — "%.Ng"-compatible text.
  **/
module peque.converter.decimal;

private import std.bigint: BigInt, toDecimalString;
private import std.conv: to;
private import std.math: frexp, ldexp, isFinite, signbit;


/** Significant digits of a finite non-zero value:
  * (negative ? -1 : 1) × d₀.d₁d₂… × 10^exp10, where digits[0] is d₀
  * (never '0') and trailing zeros are stripped.
  **/
struct DecimalDigits {
    bool negative;
    string digits;
    int exp10;
}


/** Integer mantissa and binary exponent of finite non-zero `x`:
  * |x| = m × 2^e, exactly.
  **/
private void _mantissaExp2(T)(in T x, out BigInt m, out int e)
{
    // x = fr × 2^e2, fr ∈ [0.5, 1); fr × 2^mant_dig is the integer
    // mantissa, exactly (frexp normalizes subnormals too).
    int e2;
    immutable T fr = frexp(x < 0 ? -x : x, e2);
    static if (T.mant_dig <= 64) {
        m = BigInt(cast(ulong) ldexp(fr, T.mant_dig));
    } else {
        // Wider mantissa (binary128: 113 bits): split into two ulongs;
        // power-of-two scaling and the subtraction are exact.
        static assert(T.mant_dig <= 128);
        immutable T scaled = ldexp(fr, T.mant_dig);
        immutable ulong hi = cast(ulong) ldexp(scaled, -64);
        immutable ulong lo = cast(ulong) (scaled - ldexp(cast(T) hi, 64));
        m = (BigInt(hi) << 64) + lo;
    }
    e = e2 - T.mant_dig;
}


/** Decimal digits of `value` (finite, non-zero), correctly rounded
  * half-to-even to at most sigDigits significant digits.
  **/
DecimalDigits exactDecimalDigits(T)(in T value, in uint sigDigits)
if (is(T == float) || is(T == double) || is(T == real))
in (sigDigits > 0)
in (value.isFinite && value != 0)
{
    DecimalDigits result;
    result.negative = value.signbit != 0;

    BigInt m;
    int e;
    _mantissaExp2(value, m, e);  // |value| = m × 2^e

    // Exact expansion: m·2^e is an integer for e >= 0; for e < 0,
    // m / 2^k == m·5^k / 10^k — an integer with the point shifted k left.
    string digits;
    if (e >= 0) {
        digits = toDecimalString(m << e);
        result.exp10 = cast(int) digits.length - 1;
    } else {
        digits = toDecimalString(m * BigInt(5) ^^ cast(uint) (-e));
        result.exp10 = cast(int) digits.length - 1 + e;
    }

    // Round half-to-even to sigDigits.
    if (digits.length > sigDigits) {
        auto kept = digits[0 .. sigDigits].dup;
        immutable char next = digits[sigDigits];
        bool restNonzero = false;
        foreach (c; digits[sigDigits + 1 .. $])
            if (c != '0') { restNonzero = true; break; }
        immutable bool roundUp = next > '5'
            || (next == '5' && (restNonzero || ((kept[$ - 1] - '0') & 1) != 0));
        if (roundUp) {
            size_t i = kept.length;
            while (i > 0) {
                i--;
                if (kept[i] == '9') kept[i] = '0';
                else { kept[i]++; break; }
            }
            if (i == 0 && kept[0] == '0') {
                // 999… carried over: one more decimal magnitude.
                kept[0] = '1';
                result.exp10 += 1;
            }
        }
        digits = kept.idup;
    }

    size_t len = digits.length;
    while (len > 1 && digits[len - 1] == '0')
        len--;
    result.digits = digits[0 .. len];
    return result;
}


/** Format finite `value` with sigDigits significant digits, exactly.
  *
  * Output is "%.<sigDigits>g"-compatible: scientific notation when the
  * decimal exponent is outside [-4, sigDigits), fixed otherwise; trailing
  * zeros stripped; exponent signed, min two digits. NaN/Infinity are the
  * caller's responsibility.
  **/
string formatExact(T)(in T value, in uint sigDigits)
if (is(T == float) || is(T == double) || is(T == real))
in (value.isFinite)
{
    if (value == 0)
        return value.signbit ? "-0" : "0";

    immutable dd = exactDecimalDigits(value, sigDigits);
    immutable digits = dd.digits;
    immutable X = dd.exp10;

    string res;
    if (X < -4 || X >= cast(int) sigDigits) {
        res = digits[0 .. 1];
        if (digits.length > 1)
            res ~= "." ~ digits[1 .. $];
        immutable uint absX = X < 0 ? -X : X;
        auto es = absX.to!string;
        if (es.length < 2)
            es = "0" ~ es;
        res ~= (X < 0 ? "e-" : "e+") ~ es;
    } else if (X >= 0) {
        if (digits.length > X + 1)
            res = digits[0 .. X + 1] ~ "." ~ digits[X + 1 .. $];
        else {
            res = digits;
            foreach (_; digits.length .. X + 1)
                res ~= '0';
        }
    } else {
        res = "0.";
        foreach (_; 0 .. -X - 1)
            res ~= '0';
        res ~= digits;
    }
    return dd.negative ? "-" ~ res : res;
}


// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/** Parse decimal text into T with correct rounding (half to even).
  *
  * Accepts `[+-]digits[.digits][(e|E)[+-]digits]`; NaN/Infinity spellings
  * are the caller's responsibility. Throws ConversionError on malformed
  * input.
  *
  * Values in Clinger's exact-arithmetic zone take a single-operation fast
  * path. Everything else parses approximately and the result is verified
  * and adjusted against the exact decimal value (BigInt midpoint
  * comparisons) — std.conv accumulates through `real` and can be off by
  * the last ulp where real has no extra precision over the target type.
  **/
T parseExactFloat(T)(scope const(char)[] s)
if (is(T == float) || is(T == double) || is(T == real))
{
    import std.exception: enforce;
    import std.math: nextUp, nextDown, isInfinity;
    import peque.exception: ConversionError;

    // --- tokenize: value = digits × 10^p ---------------------------------
    size_t i = 0;
    bool neg = false;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) {
        neg = s[i] == '-';
        i++;
    }

    char[] dig;               // significant digits, leading zeros stripped
    ulong small = 0;          // value of dig[0 .. min(19, $)]
    ulong small2 = 0;         // value of dig[19 .. min(38, $)]
    long frac = 0;            // digits after the point
    bool seenDigit = false, seenPoint = false;
    for (; i < s.length; i++) {
        immutable c = s[i];
        if (c >= '0' && c <= '9') {
            seenDigit = true;
            if (dig.length > 0 || c != '0') {
                dig ~= c;
                if (dig.length <= 19)
                    small = small * 10 + (c - '0');
                else if (dig.length <= 38)
                    small2 = small2 * 10 + (c - '0');
            }
            if (seenPoint)
                frac++;
        } else if (c == '.' && !seenPoint)
            seenPoint = true;
        else
            break;
    }
    if (!seenDigit)
        throw new ConversionError(
            "Invalid floating-point text: " ~ s.idup, "text", T.stringof, s.idup);

    long expPart = 0;
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        bool eneg = false;
        if (i < s.length && (s[i] == '+' || s[i] == '-')) {
            eneg = s[i] == '-';
            i++;
        }
        if (!(i < s.length && s[i] >= '0' && s[i] <= '9'))
            throw new ConversionError(
                "Invalid exponent in floating-point text: " ~ s.idup,
                "text", T.stringof, s.idup);
        for (; i < s.length && s[i] >= '0' && s[i] <= '9'; i++)
            if (expPart < 10_000_000)   // clamp: magnitude checks below decide
                expPart = expPart * 10 + (s[i] - '0');
        if (eneg)
            expPart = -expPart;
    }
    if (i != s.length)
        throw new ConversionError(
            "Invalid floating-point text: " ~ s.idup, "text", T.stringof, s.idup);

    if (dig.length == 0)                  // ±0 (all digits were zeros)
        return neg ? -T(0) : T(0);
    immutable long pL = expPart - frac;

    // --- fast path: both operands exact in T → one correctly rounded op --
    // Largest k with 5^k exactly representable: k ≤ mant_dig / log2(5).
    enum int fastP = cast(int) (T.mant_dig * 100_000L / 232_193L);
    static immutable T[fastP + 1] p10 = () {
        T[fastP + 1] r;
        r[0] = 1;
        foreach (k; 1 .. fastP + 1)
            r[k] = r[k - 1] * 10;
        return r;
    }();
    static if (T.mant_dig >= 64)
        immutable bool smallFits = dig.length <= 19;
    else
        immutable bool smallFits = dig.length <= 19 && small < (1UL << T.mant_dig);
    if (smallFits && -fastP <= pL && pL <= fastP) {
        immutable T g = pL >= 0
            ? cast(T) small * p10[cast(size_t) pL]
            : cast(T) small / p10[cast(size_t) -pL];
        return neg ? -g : g;
    }

    // --- magnitude pre-checks: certain overflow / underflow-to-zero ------
    // 10^(log10 - 1) ≤ value < 10^log10
    immutable long log10 = pL + cast(long) dig.length;
    if (log10 - 1 > T.max_10_exp)
        return neg ? -T.infinity : T.infinity;
    enum long zeroFloor = T.min_10_exp - T.mant_dig * 30_103L / 100_000L - 3;
    if (log10 < zeroFloor)
        return neg ? -T(0) : T(0);
    immutable int p = cast(int) pL;

    // --- approximate guess (within a few dozen ulps) ---------------------
    // Multiply by exact powers of ten in chunks: each factor is exactly
    // representable in `real`, so every step is one correctly rounded
    // operation and the error grows ~0.5 ulp per chunk. (pow(10, n)'s
    // repeated squaring is far worse — hundreds of ulps where
    // real == double, which overran the verification walk.)
    enum int rChunk = cast(int) (real.mant_dig * 100_000L / 232_193L);
    static immutable real[rChunk + 1] rp10 = () {
        real[rChunk + 1] r;
        r[0] = 1;
        foreach (k; 1 .. rChunk + 1)
            r[k] = r[k - 1] * 10;
        return r;
    }();
    // Seed with up to 38 digits — 19 are not enough where the target needs
    // 36 significant digits (binary128): the truncation error alone would
    // be ~1e16 ulps, unreachable by the unit-step walk.
    immutable size_t used = dig.length > 38 ? 38 : dig.length;
    immutable int gp = cast(int) (pL + (dig.length - used));
    real rg = cast(real) small;
    if (used > 19)
        rg = rg * rp10[cast(size_t) (used - 19)] + cast(real) small2;
    for (int rem = gp; rem != 0;) {
        immutable int step = rem > 0
            ? (rem > rChunk ? rChunk : rem)
            : (rem < -rChunk ? -rChunk : rem);
        rg = step > 0 ? rg * rp10[step] : rg / rp10[-step];
        rem -= step;
    }
    T g = cast(T) rg;
    immutable T minSub = nextUp(T(0));
    if (g.isInfinity || g > T.max)
        g = T.max;
    if (g < minSub)
        g = minSub;

    // --- exact verification against midpoints ----------------------------
    BigInt D = BigInt(dig);
    BigInt f5 = BigInt(5) ^^ cast(uint) (p < 0 ? -p : p);
    BigInt dl = p > 0 ? D * f5 : D;
    // sign of (value − mm × 2^me), mm ≥ 0
    int cmpMid(BigInt mm, in int me) {
        BigInt lhs = dl;
        BigInt rhs = p < 0 ? mm * f5 : mm;
        immutable long net = cast(long) p - me;
        if (net > 0)
            lhs <<= cast(uint) net;
        else if (net < 0)
            rhs <<= cast(uint) -net;
        return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1);
    }

    enum int eQ = T.min_exp - T.mant_dig;   // exponent of minSub
    // m at the format quantum (subnormal-aware), so that the midpoint to
    // the next value is (2m + 1) × 2^(e − 1)
    void quantized(in T x, out BigInt m, out int e) {
        if (x == 0) {                       // frexp(0) reports exponent 0
            m = BigInt(0);
            e = eQ;
            return;
        }
        _mantissaExp2(x, m, e);
        if (e < eQ) {                       // subnormal: trailing zeros only
            m >>= cast(uint) (eQ - e);
            e = eQ;
        }
    }

    // below (or exactly at) the midpoint between 0 and minSub → ±0
    // (m = 0 is the even neighbor)
    if (cmpMid(BigInt(1), eQ - 1) <= 0)
        return neg ? -T(0) : T(0);

    // Chunked scaling bounds the guess error to well under 100 ulps even
    // across binary128's exponent range; 2048 leaves a wide margin.
    foreach (_; 0 .. 2048) {
        BigInt gm;
        int ge;
        quantized(g, gm, ge);
        immutable cHi = cmpMid(gm * 2 + 1, ge - 1);
        if (cHi > 0) {
            g = nextUp(g);
            if (g.isInfinity)
                return neg ? -T.infinity : T.infinity;
            continue;
        }
        immutable T gl = nextDown(g);       // > 0: the minSub/2 check above
        BigInt lm;
        int le;
        quantized(gl, lm, le);
        immutable cLo = cmpMid(lm * 2 + 1, le - 1);
        if (cLo < 0) {
            g = gl;
            continue;
        }
        // bracketed; resolve exact midpoints half-to-even
        if (gm % 2 != 0) {
            if (cHi == 0)
                g = nextUp(g);
            else if (cLo == 0)
                g = gl;
        }
        return neg ? -g : g;
    }
    throw new ConversionError(
        "Floating-point parse did not converge: " ~ s.idup, "text", T.stringof, s.idup);
}


// Digit-layer output shape.
unittest {
    auto dd = exactDecimalDigits(0.25, 17);
    assert(!dd.negative && dd.digits == "25" && dd.exp10 == -1);
    dd = exactDecimalDigits(-3.0, 17);
    assert(dd.negative && dd.digits == "3" && dd.exp10 == 0);
}

// Known exact spellings.
unittest {
    assert(formatExact(0.0, 17) == "0");
    assert(formatExact(-0.0, 17) == "-0");
    assert(formatExact(1.0, 17) == "1");
    assert(formatExact(0.5, 17) == "0.5");
    assert(formatExact(-2.5, 17) == "-2.5");
    // 1e18 = 5^18 × 2^18, exactly representable; exponent 18 ≥ 17 → scientific.
    assert(formatExact(1e18, 17) == "1e+18");
    import std.math: nextUp;
    assert(formatExact(nextUp(0.0), 17) == "4.9406564584124654e-324");
}

// Rounding ties (half-to-even) and the all-nines carry. The tie values are
// exact in binary, so the expansion ends right at the tie digit.
unittest {
    assert(formatExact(1.5, 1) == "2");        // tie, odd last digit → up
    assert(formatExact(2.5, 1) == "2");        // tie, even last digit → down
    assert(formatExact(0.375, 2) == "0.38");   // 3/8: tie, odd → up
    assert(formatExact(0.125, 2) == "0.12");   // 1/8: tie, even → down
    assert(formatExact(99.5, 2) == "1e+02");   // carry through all nines
    assert(formatExact(999.5, 3) == "1e+03");
}

// String parity with %g where printFloat is exact (float/double/x87):
// deterministic bit-pattern sweep over normals, subnormals, both signs,
// both fixed and scientific regimes.
unittest {
    import std.format: format;

    static double bitsToDouble(ulong u) @trusted {
        return *cast(double*) &u;
    }
    static float bitsToFloat(uint u) @trusted {
        return *cast(float*) &u;
    }

    foreach (v; [3.14, 0.1, 1.5e-25, 1.2345678901234567e-10,
                 double.max, double.min_normal, 123456789.0, 1e17, 1e-4,
                 9.9999999999999999e2])
        assert(formatExact(v, 17) == format("%.17g", v),
            formatExact(v, 17) ~ " != " ~ format("%.17g", v));

    ulong seed = 0x9E3779B97F4A7C15;
    foreach (i; 0 .. 2000) {
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        if (((seed >> 52) & 0x7FF) != 0x7FF) {   // skip NaN/Inf
            immutable d = bitsToDouble(seed);
            assert(formatExact(d, 17) == format("%.17g", d),
                formatExact(d, 17) ~ " != " ~ format("%.17g", d));
        }
        immutable fbits = cast(uint) (seed >> 16);
        if (((fbits >> 23) & 0xFF) != 0xFF) {
            immutable f = bitsToFloat(fbits);
            assert(formatExact(f, 9) == format("%.9g", f),
                formatExact(f, 9) ~ " != " ~ format("%.9g", f));
        }
    }

    static if (real.mant_dig == 64) {
        import std.math: nextUp;
        foreach (v; [3.14L, 0.1L, real.max, real.min_normal, nextUp(0.0L),
                     12345.6789L])
            assert(formatExact(v, 21) == format("%.21g", v),
                formatExact(v, 21) ~ " != " ~ format("%.21g", v));
    }
}

// parseExactFloat(formatExact(v)) == v, exactly, on every platform — both
// directions are exact, so the round-trip is the identity.
unittest {
    foreach (v; [3.14, 1.5e-25, double.max, double.min_normal, -0.001])
        assert(parseExactFloat!double(formatExact(v, 17)) == v);
    enum uint realDigits = 2 + cast(uint) (real.mant_dig * 30103L / 100000L);
    assert(parseExactFloat!real(formatExact(3.14L, realDigits)) == 3.14L);
}

// Parser: fast path, hard cases, boundaries, ties, malformed input.
unittest {
    import std.exception: assertThrown;
    import std.math: nextUp, nextDown, signbit;
    import peque.exception: ConversionError;

    // fast path
    assert(parseExactFloat!double("1.5") == 1.5);
    assert(parseExactFloat!double("-12345.6789") == -12345.6789);
    assert(parseExactFloat!double("00123.4500e2") == 12345.0);
    assert(parseExactFloat!double("0") == 0.0);
    assert(parseExactFloat!double("0.00") == 0.0);
    assert(signbit(parseExactFloat!double("-0")) == 1);
    assert(signbit(parseExactFloat!double("-0.0e10")) == 1);

    // slow path: exponents beyond the exact-arithmetic zone
    assert(parseExactFloat!double("0.1") == 0.1);
    assert(parseExactFloat!double("1.5e-25") == 1.5e-25);
    assert(parseExactFloat!double("1.7976931348623157e+308") == double.max);
    assert(parseExactFloat!double("2.2250738585072014e-308") == double.min_normal);

    // the value that famously hung PHP/Java parsers: just below the
    // subnormal/normal boundary → max subnormal
    assert(parseExactFloat!double("2.2250738585072011e-308")
        == nextDown(double.min_normal));

    // subnormal floor and overflow
    immutable minSub = nextUp(0.0);
    assert(parseExactFloat!double("5e-324") == minSub);
    assert(parseExactFloat!double("3e-324") == minSub);   // above minSub/2
    assert(parseExactFloat!double("1e-324") == 0.0);      // below minSub/2
    assert(parseExactFloat!double("4.9406564584124654e-324") == minSub);
    assert(parseExactFloat!double("1e400") == double.infinity);
    assert(parseExactFloat!double("-1e400") == -double.infinity);
    assert(signbit(parseExactFloat!double("-1e-400")) == 1);
    assert(parseExactFloat!double("-1e-400") == 0.0);

    // decimal halfway cases resolve half-to-even (2^53 = 9007199254740992)
    assert(parseExactFloat!double("9007199254740993") == 9007199254740992.0);
    assert(parseExactFloat!double("9007199254740995") == 9007199254740996.0);

    // more significant digits than the guess mantissa (19) holds — the
    // extended 38-digit seed must kick in, or binary128's 36-digit spelling
    // of 2/3 overruns the verification walk
    assert(parseExactFloat!double("0.666666666666666666666666666666666635")
        == 2.0 / 3.0);
    assert(parseExactFloat!double(
        "3.1415926535897932384626433832795028841971693993751") // 50 digits
        == 3.141592653589793);
    assert(parseExactFloat!double(  // 60 digits, truncation past the seed
        "0.666666666666666666666666666666666666666666666666666666666666")
        == 2.0 / 3.0);
    assert(parseExactFloat!float("0.66666666666666666666666666666666666666")
        == 2.0f / 3.0f);

    // float target (no double-rounding through a wider parse)
    assert(parseExactFloat!float("1.1754944e-38") == 1.1754944e-38f);
    assert(parseExactFloat!float("1e-45") == nextUp(0.0f));
    assert(parseExactFloat!float("1e39") == float.infinity);

    // malformed input
    assertThrown!ConversionError(parseExactFloat!double(""));
    assertThrown!ConversionError(parseExactFloat!double("."));
    assertThrown!ConversionError(parseExactFloat!double("12x"));
    assertThrown!ConversionError(parseExactFloat!double("1e"));
    assertThrown!ConversionError(parseExactFloat!double("--1"));
    assertThrown!ConversionError(parseExactFloat!double("1.2.3"));
}

// Parser round-trip sweep: emission is exact and parsing is correctly
// rounded, so parse(format(v)) must be the identity for random bit patterns.
unittest {
    import std.format: format;

    static double bitsToDouble(ulong u) @trusted {
        return *cast(double*) &u;
    }

    ulong seed = 0x243F6A8885A308D3;
    foreach (i; 0 .. 500) {
        seed = seed * 6364136223846793005UL + 1442695040888963407UL;
        if (((seed >> 52) & 0x7FF) != 0x7FF) {
            immutable d = bitsToDouble(seed);
            assert(parseExactFloat!double(formatExact(d, 17)) == d);
            assert(parseExactFloat!double(format("%.17g", d)) == d);
            immutable f = cast(float) d;
            if (f == f && f != float.infinity && f != -float.infinity)
                assert(parseExactFloat!float(formatExact(f, 9)) == f);
        }
    }
}

// Wide reals (binary128): direct tests of the two-word mantissa split.
// Exact binary fractions have the same spelling in every float format.
static if (real.mant_dig > 64) unittest {
    import std.algorithm: endsWith;
    import std.math: nextUp;

    assert(formatExact(1.0L, 36) == "1");
    assert(formatExact(0.5L, 36) == "0.5");
    assert(formatExact(-2.5L, 36) == "-2.5");
    assert(formatExact(1e18L, 36) == "1000000000000000000");
    assert(formatExact(0.375L, 2) == "0.38");   // tie, odd → up
    assert(formatExact(999.5L, 3) == "1e+03");  // carry through all nines

    // Extremes must format without error; 2^-16494 ≈ 6.5e-4966.
    assert(formatExact(nextUp(0.0L), 36).endsWith("e-4966"));

    // Full-width mantissas: emission is exact and parseExactFloat is
    // correctly rounded, so the round-trip is the identity.
    foreach (v; [3.14L, 0.1L, 2.0L / 3.0L, 1.23456789e300L])
        assert(parseExactFloat!real(formatExact(v, 36)) == v);

    // Round-trip sweep over synthesized full-width quad mantissas
    // (double pair → high + low mantissa bits).
    {
        import std.math: ldexp;
        static double bitsToDouble(ulong u) @trusted {
            return *cast(double*) &u;
        }
        ulong seed = 0x452821E638D01377;
        foreach (i; 0 .. 50) {
            seed = seed * 6364136223846793005UL + 1442695040888963407UL;
            immutable ulong b1 = seed;
            seed = seed * 6364136223846793005UL + 1442695040888963407UL;
            if (((b1 >> 52) & 0x7FF) == 0x7FF)
                continue;
            immutable d1 = bitsToDouble(b1);
            immutable d2 = bitsToDouble((seed & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000);
            immutable real v = cast(real) d1 * (cast(real) d2 + ldexp(cast(real) d2, -55));
            assert(parseExactFloat!real(formatExact(v, 36)) == v);
        }
    }
}
