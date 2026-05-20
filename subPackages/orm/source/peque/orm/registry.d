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
  * Pass Bind!(M, RepoTpl) instances as template arguments:
  * ---
  * alias AppRegistry = Registry!(
  *     Bind!(Partner, ModelRepo!Partner),
  *     Bind!(Order,   OrderRepo),
  * );
  * ---
  **/
struct Registry(Bindings...) {
    alias _bindings = Bindings;
}


// ---------------------------------------------------------------------------
// RegistryRepoFor — compile-time lookup
// ---------------------------------------------------------------------------

/** Return the repository template bound to model M in registry Reg.
  *
  * Compile-time error if M is not registered or appears more than once.
  *
  * Example:
  * ---
  * alias RepoTpl = RegistryRepoFor!(AppRegistry, Partner);
  * auto repo = RepoTpl!Connection(&conn);
  * ---
  **/
template RegistryRepoFor(Reg, M) if (isModel!M) {
    // CTFE AA lookup: avoids recursive template instantiation that Filter! would cause.
    // Build a mangleof→index map in one static foreach pass, then do an O(1) AA lookup.
    private size_t _findIndex() {
        size_t[string] lookup;
        static foreach (i, B; Reg._bindings) {{
            static if (is(B == Bind!(BM, RepoTpl), BM, alias RepoTpl))
                lookup[BM.mangleof] = i;
        }}
        auto p = M.mangleof in lookup;
        return p ? *p : size_t.max;
    }

    // Duplicate detection: count occurrences of M across all bindings.
    private size_t _countMatches() {
        size_t n = 0;
        static foreach (i, B; Reg._bindings) {{
            static if (is(B == Bind!(BM, RepoTpl), BM, alias RepoTpl))
                if (BM.mangleof == M.mangleof) n++;
        }}
        return n;
    }

    enum _idx = _findIndex();
    enum _cnt = _countMatches();

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
