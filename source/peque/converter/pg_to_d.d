/// This module defines functions used to convert libpq values to d types
module peque.converter.pg_to_d;

private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint;
private import std.format;
private import std.conv;
private import std.datetime;

private import peque.pg_type;


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
        static assert(0, "Unsupported type " ~ T.stringof ~ "X: " ~ isIntegral!T);
}

/// ditto
T convertTextTypeToD(T)(
        scope const char* data,
        in int length,
        in PGType pg_type)
@trusted if (is(T == Date) || is(T == DateTime)) {
    static if (is(T == Date))
        switch(pg_type) {
            case PGType.DATE:
                return Date.fromISOExtString(data[0 .. length]);
            case PGType.TIMESTAMP:
                return DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. length]).date;
            default:
                assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
        }
    else static if (is(T == DateTime))
        switch(pg_type) {
            case PGType.TIMESTAMP:
                return DateTime.fromISOExtString(data[0 .. 10] ~ "T" ~ data[11 .. length]);
            default:
                assert(0, "Cannot convert pg type (%s) to D type %s".format(pg_type, T.stringof));
        }
    else
        static assert(0, "Unsupported type " ~ T.stringof ~ " X: " ~ isIntegral!T);
}
