/** Compile-time registry mapping model types to repository templates.
  *
  * Provides:
  *  - ModelRepo!M        — single-Ctx-param generic CRUD repository template
  *  - Bind!(M, RepoTpl)  — associate a model with its repository template
  *  - Registry!(Bindings...) — collect bindings into a named registry type
  *  - RegistryRepoFor!(Reg, M) — look up the repository template for model M
  *  - MergeRegistries!(Regs...) — combine multiple registries into one
  *
  * Repository templates used with Bind must take a single query-context type
  * parameter (Ctx), e.g.:
  * ---
  * struct PartnerRepo(Ctx) {
  *     private Ctx* _ctx;
  *     this(Ctx* ctx) { _ctx = ctx; }
  *     mixin CRUDMixin!(Partner, Ctx);
  *
  *     Partner[] findActive() { ... }
  * }
  * alias MyReg = Registry!(Bind!(Partner, PartnerRepo));
  * ---
  *
  * For models that need no custom methods, use ModelRepo!M directly:
  * ---
  * alias MyReg = Registry!(Bind!(Partner, ModelRepo!Partner));
  * ---
  **/
module peque.orm.registry;

private import std.meta: AliasSeq;

private import peque.query_context: isQueryContext;
private import peque.orm.repository: isModel, CRUDMixin;


// ---------------------------------------------------------------------------
// ModelRepo — default single-Ctx-param repository template
// ---------------------------------------------------------------------------

/** Generic repository template parameterised on Ctx only.
  *
  * Use as the RepoTpl argument of Bind!(M, ModelRepo!M) when you need only
  * standard CRUD operations.  For custom domain queries, define your own
  * single-Ctx-param struct and use that instead.
  *
  * Borrows its context exactly as Repository does, and must not outlive it.
  **/
template ModelRepo(M) if (isModel!M) {
    struct ModelRepo(Ctx) if (isQueryContext!Ctx) {
        private Ctx* _ctx;

        @disable this();
        this(Ctx* ctx) pure nothrow @nogc { _ctx = ctx; }

        mixin CRUDMixin!(M, Ctx);
    }
}


// ---------------------------------------------------------------------------
// Bind
// ---------------------------------------------------------------------------

/** Bind model M to a single-Ctx-param repository template RepoTpl.
  *
  * RepoTpl must be a template whose single template parameter is the query
  * context type:
  * ---
  * struct MyRepo(Ctx) { ... }
  * alias B = Bind!(Partner, MyRepo);
  * ---
  **/
struct Bind(M, alias RepoTpl) if (isModel!M) {}


// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/** Compile-time registry of model→repository bindings.
  *
  * Pass Bind!(M, RepoTpl) instances as template arguments.
  **/
struct Registry(Bindings...) {
    alias _bindings = Bindings;
}

/// Composing a registry and looking a model up in it.
unittest {
    import peque.connection: Connection;
    import peque.model: model, field, primaryKey;

    static @model("doc_reg_partner") struct Partner {
        @primaryKey int    id;
        @field      string name;
    }
    static @model("doc_reg_order") struct Order {
        @primaryKey int    id;
        @field      string code;
    }

    alias AppRegistry = Registry!(
        Bind!(Partner, ModelRepo!Partner),
        Bind!(Order,   ModelRepo!Order),
    );

    // The lookup is resolved entirely at compile time.
    static assert(__traits(isSame, RegistryRepoFor!(AppRegistry, Partner),
                                   ModelRepo!Partner));

    // D cannot chain ! instantiations, so resolve the lookup into an alias
    // first, then instantiate it with the context type.
    alias RepoTpl = RegistryRepoFor!(AppRegistry, Partner);
    static assert(is(RepoTpl!Connection));

    // A model that was never bound is a compile-time error, not a runtime one.
    static @model("doc_reg_unbound") struct Unbound {
        @primaryKey int id;
        @field      string name;
    }
    static assert(!__traits(compiles, RegistryRepoFor!(AppRegistry, Unbound)));
}


// ---------------------------------------------------------------------------
// RegistryRepoFor — compile-time lookup
// ---------------------------------------------------------------------------

/** Return the repository template bound to model M in registry Reg.
  *
  * Compile-time error if M is not registered or appears more than once.
  * See the Registry example for usage — note that D cannot chain `!`
  * instantiations, so the lookup must be resolved into an alias first.
  **/
template RegistryRepoFor(Reg, M) if (isModel!M) {
    // One CTFE pass collects both the index and the match count. A direct
    // static foreach rather than Filter!, which would recurse once per binding.
    private struct _Hit { size_t idx = size_t.max; size_t count; }

    private _Hit _findBinding() {
        _Hit hit;
        static foreach (i, B; Reg._bindings) {{
            static if (is(B == Bind!(BM, RepoTpl), BM, alias RepoTpl))
                if (BM.mangleof == M.mangleof) {
                    if (hit.count == 0) hit.idx = i;
                    hit.count++;
                }
        }}
        return hit;
    }

    private enum _hit = _findBinding();
    enum _idx = _hit.idx;
    enum _cnt = _hit.count;

    static assert(_cnt >= 1,
        "No binding found for " ~ M.stringof ~ " in " ~ Reg.stringof ~
        ". Add Bind!(" ~ M.stringof ~ ", ...) to the registry.");
    static assert(_cnt == 1,
        "Duplicate binding for " ~ M.stringof ~ " in " ~ Reg.stringof ~ ".");

    static if (_cnt == 1) {
        static if (is(Reg._bindings[_idx] == Bind!(BM, RepoTpl), BM, alias RepoTpl))
            alias RegistryRepoFor = RepoTpl;
        else
            static assert(false, "Internal registry error");
    }
}


// ---------------------------------------------------------------------------
// MergeRegistries
// ---------------------------------------------------------------------------

/** Merge multiple registries into one.
  *
  * The resulting Registry contains all bindings from all input registries.
  * Duplicate model bindings (same M in two registries) are detected at
  * RegistryRepoFor call time.
  *
  * Example:
  * ---
  * alias CoreReg = Registry!(Bind!(Partner, ModelRepo!Partner));
  * alias AppReg  = Registry!(Bind!(Order,   OrderRepo));
  * alias FinalReg = MergeRegistries!(CoreReg, AppReg);
  * ---
  **/
template MergeRegistries(Regs...) {
    private template _collectBindings(size_t i = 0) {
        static if (i >= Regs.length)
            alias _collectBindings = AliasSeq!();
        else
            alias _collectBindings = AliasSeq!(Regs[i]._bindings, _collectBindings!(i + 1));
    }

    alias MergeRegistries = Registry!(_collectBindings!());
}
