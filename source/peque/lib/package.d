module peque.lib;

private import std.format: format;
private import std.string: join, fromStringz;
private import std.algorithm: map;

public import peque.lib.libpq;


version(PequeDynamic) {
    private import bindbc.loader;
    private import bindbc.common: Version;

    private SharedLib lib;

    private enum supportedLibNames = mixin(makeLibPaths(["pq"]));

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

    shared static this() {
        auto err_count_start = bindbc.loader.errorCount;
        bool load_status = loadLib;
        if (!load_status) {
            auto errors = bindbc.loader.errors[err_count_start .. bindbc.loader.errorCount]
                .map!((e) => "%s: %s".format(e.error.fromStringz.idup, e.message.fromStringz.idup))
                .join(",\n");
            assert(0, "Cannot load libpq library! Errors: %s".format(errors));
        }
    }
}

