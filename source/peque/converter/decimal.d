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

    // value = fr × 2^e2, fr ∈ [0.5, 1); fr × 2^mant_dig is the integer
    // mantissa, exactly (frexp normalizes subnormals too).
    int e2;
    immutable T fr = frexp(result.negative ? -value : value, e2);
    BigInt m;
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
    immutable int e = e2 - T.mant_dig;  // value = ±m × 2^e

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

// Parsing the emitted text recovers the exact value.
unittest {
    foreach (v; [3.14, 1.5e-25, double.max, double.min_normal, -0.001])
        assert(formatExact(v, 17).to!double == v);
    static if (real.mant_dig == 64)
        assert(formatExact(3.14L, 21).to!real == 3.14L);
}
