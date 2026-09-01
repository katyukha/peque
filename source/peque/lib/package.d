module peque.lib;

private import std.format: format;
private import std.string: join, fromStringz;
private import std.algorithm: map;

private import peque.exception: LibpqLoadError;

public import peque.lib.libpq;


version(PequeDynamic) {
    private import bindbc.loader;
    private import bindbc.common: Version;

    private SharedLib lib;

    private enum supportedLibNames = mixin(
        makeLibPaths(
            names: ["pq"],
            platformPaths: [
                "OSX": [
                    "/opt/homebrew/opt/libpq/lib/",
                    "/usr/local/opt/libpq/lib/",
                ],
            ]
        )
    );

    /** Try to load dynamically
      *
      * Params:
      *     libname = name of library to load
      *
      * Returns:
      *     true if library was loaded successfully, otherwise false
      **/
    bool loadLib(in string libname) {
        lib = bindbc.loader.load(libname.ptr);
        if (lib == bindbc.loader.invalidHandle) {
            return false;
        }

        auto err_count = bindbc.loader.errorCount;
        peque.lib.libpq.bindModuleSymbols(lib);
        if (bindbc.loader.errorCount == err_count)
            return true;

        return false;
    }

    ///
    bool loadLib() {
        foreach(libname; supportedLibNames)
            if (loadLib(libname))
                return true;

        // Cannot load library
        return false;
    }

    /** Load libpq before anything can use it.
      *
      * A missing or unloadable libpq is an environment problem, not a broken
      * invariant, so it is thrown rather than asserted: an `assert(0)` here
      * halts with no message under `-release`, which is the build most likely
      * to meet a machine without the library installed. Thrown from a module
      * constructor the message reaches the user and the process exits non-zero.
      **/
    shared static this() {
        auto err_count_start = bindbc.loader.errorCount;
        bool load_status = loadLib;
        if (!load_status) {
            auto errors = bindbc.loader.errors[err_count_start .. bindbc.loader.errorCount]
                .map!((e) => "%s: %s".format(e.error.fromStringz.idup, e.message.fromStringz.idup))
                .join(",\n");
            throw new LibpqLoadError(
                "Cannot load libpq library! Tried: %-(%s, %). Errors: %s".format(
                    supportedLibNames, errors));
        }
    }
}

