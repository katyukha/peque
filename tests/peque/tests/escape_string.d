
module peque.tests.escape_string;

private import std.process: environment;
private import std.exception: assertThrown;
private import core.exception: AssertError;

private import versioned: Version;

private import peque.connection: Connection;
private import peque.result: Result;


unittest {
    import std.typecons;
    import std.datetime;

    auto c = Connection(
            environment.get("POSTGRES_DB", "peque-test"),
            environment.get("POSTGRES_USER", "peque"),
            environment.get("POSTGRES_PASSWORD", "peque"),
            environment.get("POSTGRES_HOST", "localhost"),
            environment.get("POSTGRES_PORT", "5432"),
    );
    assert(c.escapeString("Single ' Quote") == "Single '' Quote");

    // LIKE wildcards not escaped
    assert(c.escapeString("Percent %") == "Percent %");
    assert(c.escapeString("Underscore _") == "Underscore _");
}
