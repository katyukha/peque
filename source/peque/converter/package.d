/// This module defines functions used to convert libpq values to d types
module peque.converter;

private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint;
private import std.conv;
private import std.datetime;

private import peque.pg_type;

/* TODO List:
 *
 * - handle different string encondings (utf8, utf16, windows encondings).
 *
 */

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
@trusted if (isSomeString!T) {
    // It seems that it is safe to convert any string postgres string types
    // to string this way.
    return data ? cast(T)data[0 .. length].idup : "";
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (isScalarType!T) {
    // Cast data to stirng to make conversions work
    scope string sdata = data ? cast(string)data[0 .. length] : "";

    // We have to take into account postgres types here
    static if (isIntegral!T || isFloatingPoint!T)
        return sdata.to!T;
    else static if (isBoolean!T)
        switch (sdata) {
            case "t":
                return true;
            case "f":
                return false;
            default:
                assert(0, "Cannot parse boolean value from postgres: " ~ sdata);
        }
    else
        static assert(0, "Unsupported type " ~ T.stringof ~ "X: " ~ isIntegral!T);
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == Date) || is(T == DateTime)) {
    // Cast data to stirng to make conversions work
    scope string sdata = data ? cast(string)data[0 .. length] : "";

    static if (is(T == Date))
        switch(pg_type) {
            case PGType.DATE:
                return Date.fromISOExtString(sdata);
            case PGType.TIMESTAMP:
                return DateTime.fromISOExtString(sdata[0 .. 10] ~ "T" ~ sdata[11 .. $]).date;
            default:
                assert(0, "Cannot parse date value");
        }
    else static if (is(T == DateTime))
        switch(pg_type) {
            case PGType.TIMESTAMP:
                return DateTime.fromISOExtString(sdata[0 .. 10] ~ "T" ~ sdata[11 .. $]);
            default:
                assert(0, "Cannot parse datetime value");
        }
    else
        static assert(0, "Unsupported type " ~ T.stringof ~ " X: " ~ isIntegral!T);
}
