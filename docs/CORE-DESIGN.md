# CORE-DESIGN.md — the contract for the `core/` foundation

The authoritative design for the reusable game foundation (`core/`). `FACTORY.md` owns *policy*,
`ARCHITECTURE.md` owns *structure*, `docs/TESTING.md` owns *how we test*; **this file owns the
`core/` API contract** — every module, its public surface, and which subset we build in this phase
(the **SPINE**) versus which we defer to **B2** while keeping the contracts forward-compatible.

> **Status legend used throughout:**
> **[SPINE]** built now · **[B2]** deferred, contract accounted for now · **[SAMPLE]** deletable
> per game (proves the wiring).

Every Luau rule from `FACTORY.md` §10 is binding on every file listed here: `--!strict`, `task.*`
never `wait/spawn/delay`, server-authoritative validation (type + range + ownership + rate),
concurrency-safe economy, idempotent receipts, DataStore-budget-aware, **injectable server clock**,
all data through the data layer (migration on structural change), filter user-displayed text, never
fabricate a Roblox API (`-- TODO(verify):` if unsure).

> **Two toolchain facts this revision is built on (verified on the pinned set — see §0.1):**
> Lune 0.10.4 has **no `script` global** at module scope (`script` is `nil`), and `fs.readDir` is
> **cwd-relative** while `require("./x")` is **script-relative**. selene 0.31.0 with `std = "roblox"`
> **does NOT flag `wait`/`spawn`/`delay`** out of the box. rojo 7.6.1 **rejects** `"$optional": true`
> as a sibling of `$path`. Each of these breaks the gauntlet if ignored; §0.1 states the decisions
> that make every spine file survive all four gauntlet steps, and the rest of the doc obeys them.

---

## 0. Design principles (why the shape is what it is)

1. **One Start hook, dependencies through context.** Every service/controller is a module returning
   a table with a single `Start(context)`. It never `require`s a sibling service — it pulls
   collaborators from `context`. This kills load-order cycles and makes the bootstrap order the
   *only* source of truth for startup sequencing.
2. **Pure logic is injectable.** Economy math, validators, migrations, and the data layer take
   plain inputs + injected dependencies (clock, store) and return plain outputs. That is the only
   reason Tier-1 (Lune, no DataModel) can test them in milliseconds.
3. **One wire surface.** Features never add a `RemoteEvent`. They register a **named action** on the
   single `Net` gateway, with a validator + rate policy. Every inbound payload is validated
   server-side before a handler sees it. The client is hostile.
4. **One data shape, versioned.** All persistent state is a single `PlayerData` table with a
   `schemaVersion`. Any structural change ships a migration. Features read/write through the data
   layer, never a raw DataStore.
5. **Interfaces, not implementations, are the contract.** The data layer is defined by an interface
   (`Store`). Tier-1 uses an in-memory mock; B2 drops in the real session-locked DataStore behind
   the *same* interface, unchanged.
6. **Forward-compatible by construction.** The spine's `Net`, `Types`, and `Store` already carry the
   seams every deferred module (security, live-ops, analytics, monetization) plugs into, so B2 adds
   modules without rewriting the spine.

---

## 0.1 Dual-runtime + toolchain decisions (the load-bearing invariants)

These were each **reproduced on the pinned toolchain** (rojo 7.6.1, lune 0.10.4, selene 0.31.0,
stylua 2.5.2) before the rest of the design was written. They are non-negotiable for every spine file.

**D1 — Require strategy: Lune-clean modules use a `require`-shim that branches on `script == nil`;
Roblox-only modules use `require(script.Parent.X)`; no spec ever requires a Roblox-only module.**
Verified: in Lune `script` is `nil` at module scope, so `require(script.Parent.X)` throws the instant
a spec requires it; while `require("./X")` resolves **relative to the requiring file** (script-relative,
cwd-independent — verified from repo root AND `core/`, including `../` up-tree paths). In the Roblox
runtime there is no string-path `require` (it resolves against instances). These are mutually
exclusive, so a Lune-clean module that needs a cross-module require uses a **tiny shim** that picks the
right form per runtime (verified to run clean under Lune AND lint clean under the fenced selene std):

```lua
--!strict
-- the require-shim pattern used by every Lune-clean module that needs a sibling (e.g. Net -> Result)
local Result
if script == nil then
	Result = require("../../shared/Result") -- Lune: string path relative to THIS file (cwd-agnostic)
else
	Result = require((script :: any).Parent.Result) -- Roblox runtime: instance require
end
```

> - **Lune-clean modules** (required by specs — `Result`, `Types`, `Net`, `Config`, `Migrations`,
>   `framework/Bootstrap`, `framework/Service`/`Controller`, `security/Gate`, `data/Store`,
>   `data/MockStore`, `data/Clock`, `data/DataService`, the sample's `SampleAction`/`SampleService`,
>   and all of `tests/`) touch **no Roblox global at module scope** *except* the `script == nil`
>   discriminant inside the shim (which is `nil` under Lune and the dead Roblox branch is never taken).
>   **Truly-pure leaves** (`Result`, `Types`, `Config`, `Clock`) require **nothing**, so they need no
>   shim at all. Only modules with a genuine cross-module dependency carry the shim.
>   - *Cheaper alternative where it fits (the reviewer's option b):* a module may instead take **zero
>     cross-module requires** and receive its one dependency **injected** by the caller — already used
>     by `DataService` (gets `store`/`clock`/`config`) and by specs. Prefer injection for runtime deps;
>     use the shim only for **type-bearing** requires (e.g. `type Result<T> = Result.Result<T>`).
> - **Roblox-only modules** (`NetServer`, `NetClient`, both `Context.luau`, both bootstraps,
>   `SampleController`) use `require(script.Parent.X)` / `game:GetService(...)` and are **never
>   required by any spec** — exercised only at Tier-2/3. A spec that imported one would crash under
>   Lune; the runner's per-spec `pcall` (§7.4) records that as a failure rather than a silent hang —
>   but the rule is: **no spec requires a Roblox-only module.**

This replaces the contradictory mix in the previous draft (where `Net.luau` showed
`require(script.Parent.Result)` yet was listed Lune-clean). For brevity the code sketches below show
the **Lune branch** of the shim (the string-relative require); the full module wraps it in the
`script == nil` shim above (or uses injection). `rojo build` (gauntlet step 3) does not execute code,
so it is agnostic to the require form; Lune (step 4) takes the string branch; the Roblox runtime
(Tier-2/3) takes the instance branch.

**D2 — selene does NOT ban `wait`/`spawn`/`delay` by default; the spine ships a custom std overlay
that does.** Verified: `std = "roblox"` lints a file calling `wait(1)`/`spawn(...)`/`delay(...)` with
**0 errors** (it IS loading the roblox std — it correctly flags an undefined global). So the §10
`task.*` rule has **no automated enforcement** under stock config. Fix (verified to fire): ship
`core/roblox-fenced.yml` (the **filename must equal the std name** `roblox-fenced`, and it MUST sit in
the **same directory as `selene.toml`** — both verified: selene errors "could not find std" if named
`roblox.yml` or placed in a `selene/` subdir) with `base: roblox` and
`wait`/`spawn`/`delay` marked `removed: true`, and set `std = "roblox-fenced"` in `selene.toml`. Under
that overlay, a file calling `wait(1)`/`spawn(...)`/`delay(...)`
produces **selene errors and a nonzero exit**, while `task.wait`/`task.spawn`/`task.delay` lint
clean (exit 0). A Tier-1 self-test (§9.4) asserts the overlay actually rejects a `wait()` sample so
this enforcement can't silently regress. **Belt-and-suspenders:** the PreToolUse guard hook
(`ARCHITECTURE.md` → Safety hooks) also regex-denies bare `wait(`/`spawn(`/`delay(` writes; selene is
the gauntlet gate, the hook is the edit-time gate. Neither relies on selene's defaults.

**D3 — rojo `"$optional": true` as a sibling of `$path` is INVALID in 7.6.1; the spine omits the
`Packages` node entirely.** Verified: `{ "$path": "Packages", "$optional": true }` → *"Failed to
deserialize JSON"* (build red), with the folder both absent and present. The spine has **no
`Packages/` folder**, so `core/default.project.json` **omits the `Packages` node** (verified to build
clean). When wally packages first exist, the verified-working optional form is the **path-object**:
`"Packages": { "$path": { "optional": "Packages" } }` (verified to build green with the folder
absent). §11.1 ships the omit form and documents the path-object form for B2.

**D4 — the runner is an explicit, lexically-sorted `specs` list using relative requires; it never
calls `fs.readDir` for discovery.** Verified: from repo root, `fs.readDir("unit")` and
`fs.readDir("core/tests/unit")` both error (cwd-relative), while `require("./lib/testkit")` resolves
fine (script-relative). So `fs.readDir`-based discovery is cwd-fragile and contradicts the gauntlet's
"run from repo root" contract. The runner instead requires an explicit list
(`require("./unit/framework.spec")`, …) — script-relative, so **cwd does not matter** — and each
require is wrapped in `pcall` so a require-time error becomes a recorded failure and the run still
prints exactly one JSON line and exits nonzero (§7.4). `table.sort` is applied to the list's names
for the byte-stable summary ordering guarantee (§9.2).

---

## 1. Full `core/` file layout (mapped through the Rojo v7 tree)

Rojo v7 mapping (from `ARCHITECTURE.md`): `*.server.luau`→`Script`, `*.client.luau`→`LocalScript`,
`*.luau`→`ModuleScript`, `init.luau`→the enclosing folder becomes that module, a directory→`Folder`.
Tree roots: `core/src/shared`→`ReplicatedStorage.Shared`, `core/src/server`→`ServerScriptService.Server`,
`core/src/client`→`StarterPlayer.StarterPlayerScripts.Client`, `Packages`→`ReplicatedStorage.Packages`.

```
core/
  default.project.json        [SPINE] Rojo v7 tree (the four roots above)
  wally.toml                  [SPINE] package manifest (FUTURE deps only; spine runs with none)
  .luaurc                     [SPINE] luau-lsp config (strict, aliases)
  stylua.toml                 [SPINE] formatter config
  selene.toml                 [SPINE] linter config (std = "roblox-fenced" — points at the overlay)
  roblox-fenced.yml           [SPINE] custom std overlay, MUST sit beside selene.toml (same dir) and
                              [SPINE]   be named <std>.yml. base roblox + wait/spawn/delay removed (D2).
  CLAUDE.md                   [B2]    per-game engineering contract forked with the game

  src/shared/                 -> ReplicatedStorage.Shared   (READ-ONLY to feature work)
    init.luau                 [SPINE] Shared barrel: exposes Types, Net, Config, Result
    Types.luau                [SPINE] PlayerData v1 + schemaVersion + PlayerView + toView() + aliases
    Net.luau                  [SPINE] action registry + server gateway + client call shape
    Config.luau               [SPINE] static tunables (store key, budgets, rate defaults, flags seed)
    Result.luau               [SPINE] tiny ok/err result helper (no exceptions across the wire)
    Migrations.luau           [SPINE] ordered migration steps PlayerData v(n-1) -> v(n)

  src/server/                 -> ServerScriptService.Server
    init.server.luau          [SPINE] THE server bootstrap (deterministic Start order)
    Context.luau              [SPINE] builds + holds the server context table
    framework/
      Service.luau            [SPINE] service type + helper to declare a service module
      Bootstrap.luau          [SPINE] ordered Start() driver (pure, testable)
    data/
      init.luau               [SPINE] data folder barrel
      Store.luau              [SPINE] the Store INTERFACE (type) + shared helpers
      MockStore.luau          [SPINE] in-memory Store impl (Tier-1 + spine runtime default)
      Clock.luau              [SPINE] injectable server clock (real + fake factory)
      DataService.luau        [SPINE] session-scoped data: load/get/save/release per player
      SessionStore.luau       [B2]    real session-locked DataStore impl of Store
    net/
      NetServer.luau          [SPINE] server side of Net: wires the gateway to RemoteEvent/Function
    security/
      Gate.luau               [SPINE] minimal token-bucket rate gate + ownership assert (Lune-clean)
      RateLimiter.luau        [B2]    full token-bucket per (player, action) (Gate is the spine seed)
      Validator.luau          [B2]    shared payload/economy/movement sanity helpers
      ViolationTracker.luau   [B2]    strike accounting -> kick/log
      Panic.luau              [B2]    global "reject client writes" flag
    services/
      sample/
        SampleAction.luau     [SAMPLE] Lune-clean action def (validator+handler); spec requires this
        SampleService.luau    [SAMPLE] thin Start() that registers SampleAction (deletable)
    liveops/
      FeatureFlags.luau       [B2]    flags flipped from outside without redeploy
    analytics/
      Analytics.luau          [B2]    batched JSON-line event sink + core taxonomy
    monetization/
      Receipts.luau           [B2]    idempotent ProcessReceipt (records receipt IDs in data)
      Products.luau           [B2]    gamepass / dev-product catalog + ownership checks

  src/client/                 -> StarterPlayer.StarterPlayerScripts.Client
    init.client.luau          [SPINE] THE client bootstrap (deterministic Start order)
    Context.luau              [SPINE] builds + holds the client context table
    framework/
      Controller.luau         [SPINE] controller type (mirror of Service for the client)
      Bootstrap.luau          [SPINE] ordered Start() driver (shared logic with server)
    net/
      NetClient.luau          [SPINE] client side of Net: call(action, payload) -> Result
    controllers/
      sample/
        SampleController.luau [SAMPLE] calls the sample Net action; logs the Result (deletable)

  tests/                      (Tier-1, Lune; NO Roblox DataModel — see §9 & docs/TESTING.md)
    run.luau                  [SPINE] runner: discovers specs, runs, prints ONE JSON summary line
    lib/
      testkit.luau            [SPINE] describe/it/expect + JSON reporter
      assert.luau             [SPINE] assertions
      mocks.luau              [SPINE] mock Store (yield/fail injectable) + fake clock + fake net
    unit/
      framework.spec.luau     [SPINE] bootstrap order + context resolution + non-nil deps on Start
      net.spec.luau           [SPINE] Net.dispatch: validation, rate (Gate), unknown action, pcall
      data.spec.luau          [SPINE] DataService load/get/update/save/release + migration + toView
                              [SPINE]   + BindToClose budget/retry + SessionLocked retry (§9.5)
      sample.spec.luau        [SAMPLE] end-to-end LOGIC: action -> Net.dispatch -> handler -> data
      selene_guard.spec.luau  [SPINE] asserts the selene overlay rejects wait/spawn/delay (§9.4)
    scenarios/                [B2]    Given/When/Then gameplay scenarios (run at Tier 1 & 2)
    engine/                   [B2]    Tier-2 in-engine suites (Open Cloud)

  lune/                       [B2]    build / publish / cloud-test scripts (publish is fenced)
```

> **Spine note on `core/lune/`:** the gauntlet's `rojo build` and `lune run core/tests/run.luau`
> need no script in `core/lune/` — that folder holds the **Tier-2 / publish** scripts which are B2.
> The spine keeps the `.gitkeep` already present.

---

## 2. The service framework

A service (server) or controller (client) is **a module that returns a table with a single
`Start(context)` method**. It resolves every collaborator from `context`. It must never `require`
another service/controller directly — that is what causes load-order cycles. A fixed, ordered list
in each bootstrap is the single source of truth for startup sequencing.

### 2.1 The `Service` / `Controller` shape (`framework/Service.luau`, `framework/Controller.luau`)

Both are the same shape; two names so server and client read clearly. The `Service.luau` module is a
thin type + identity helper (no runtime magic):

```lua
--!strict
-- core/src/server/framework/Service.luau
export type Context = ... -- see §2.3 (the server Context type lives in shared via Net + here)

export type Service = {
	-- Stable name used for diagnostics and (optionally) context lookup. Required.
	name: string,
	-- Called once, in bootstrap order, with the fully-built context.
	-- May yield (e.g. DataService preloads nothing here; per-player load is event-driven).
	-- MUST NOT require sibling services; pull them from `context`.
	Start: (self: Service, context: Context) -> (),
	-- Optional: cleanup on shutdown / BindToClose. Bootstrap calls in REVERSE order.
	Stop: ((self: Service, context: Context) -> ())?,
}

-- Identity helper: lets a module assert its own shape at author time.
local Service = {}
function Service.define(def: Service): Service
	return def
end
return Service
```

`Controller` is byte-identical in intent (client `Context` type). Sharing the literal table shape
keeps the `Bootstrap` driver generic.

### 2.2 The bootstrap driver (`framework/Bootstrap.luau`)

Pure and testable: it takes an **ordered list** of services + a context and drives `Start` in order,
then exposes `Stop` in reverse. It does not know about Roblox; it is just a sequencer, so the
`framework.spec` test can drive it under Lune with fake services.

```lua
--!strict
-- core/src/server/framework/Bootstrap.luau  (client mirror is identical)
local Bootstrap = {}

export type Startable = {
	name: string,
	Start: (self: any, context: any) -> (),
	Stop: ((self: any, context: any) -> ())?,
}

-- Drives Start(context) over `services` IN THE GIVEN ORDER. Deterministic.
-- Returns the started list so Stop can run in reverse. Raises (with the service
-- name) if a Start errors, so a bad service fails the run loudly, not silently.
function Bootstrap.start(services: { Startable }, context: any): { Startable }
	-- for each service in order: service:Start(context)
	return services
end

-- Stops in REVERSE order; missing Stop is a no-op. Used by BindToClose.
function Bootstrap.stop(started: { Startable }, context: any): ()
end

return Bootstrap
```

**Determinism guarantee:** order is the array order passed in by the bootstrap script (§2.4). No
alphabetical/auto-discovery on the server runtime path — discovery is a *test-only* concern.

**Construct-vs-Start split (the invariant that makes the order safe — concern 16).** There are two
distinct phases and they must not be conflated:
> 1. **Construct** happens in `Context.build()`: it news up `clock`, `config`, `data` (`DataService.new(...)`),
>    and `net` (`NetServer.new(...)`) so **every core context field is non-nil from t0**. No I/O, no
>    event connections, no RemoteEvent creation here — just object construction.
> 2. **Start** happens when `Bootstrap.start(services, context)` drives the array: each `Start(context)`
>    does **runtime wiring only** (NetServer creates/finds the RemoteEvent + binds `OnServerInvoke`;
>    DataService connects `PlayerAdded`/`PlayerRemoving`). Construction never happens in `Start`.
>
> **Invariant:** every object that appears in the `services` array **and** as a context field is the
> *identical reference* (`context.net` IS `services[1]`, `context.data` IS `services[2]`). They are in
> the array only to *receive* `Start()`, not to be created by it. Consequence: a feature service later
> in the array, during its own `Start`, always sees fully-constructed `context.net`/`context.data`
> (never nil) — even though NetServer/DataService have *also* had their `Start` run first (so the
> RemoteEvent and PlayerAdded hook are live). `framework.spec` asserts both: (a) Start runs in array
> order, and (b) a fake feature service's `Start` observes non-nil `context.net`/`context.data`/
> `context.clock`/`context.config`.

### 2.3 The context shape

The context is the **dependency-injection table**. It is built once per side (server/client) and
passed to every `Start`. Exact shape (spine fields concrete; deferred fields reserved so B2 adds a
field without changing a signature):

```lua
--!strict
-- Server context (built by core/src/server/Context.luau)
export type ServerContext = {
	-- --- runtime facts ---
	isServer: true,
	clock: Clock,                 -- [SPINE] injectable server clock (§5)

	-- --- core services (CONSTRUCTED in Context.build, never sibling-required) ---
	data: DataService,            -- [SPINE] per-player data access (§4.4)
	net: NetServer,               -- [SPINE] register actions / fire to client (§3)
	gate: Gate,                   -- [SPINE] minimal rate/ownership gate (§3.6); NetServer uses it
	config: Config,               -- [SPINE] static tunables (§3.4 / Config.luau)

	-- --- deferred seams (nil in the spine; populated in B2) ---
	security: Security?,          -- [B2] full rate limiter + validators + panic flag (supersedes gate)
	flags: FeatureFlags?,         -- [B2] live-ops feature flags
	analytics: Analytics?,        -- [B2] event sink
	monetization: Monetization?,  -- [B2] receipts + products
}

-- Client context (built by core/src/client/Context.luau)
export type ClientContext = {
	isServer: false,
	net: NetClient,               -- [SPINE] call(action, payload) -> Result (§3.3)
	config: Config,               -- [SPINE] the client-safe subset of Config
}
```

Rationale: deferred seams are **typed-optional now**. A B2 service does `local sec = context.security`
and the field already exists in the type, so adding it is additive — no spine signature changes.

`ActionContext` (§3.3) is the **typed narrow projection** of this `ServerContext` that `NetServer`
hands each handler: it closes over the *same* `clock`/`data` references and exposes the *same*
optional `security?`/`flags?`/`analytics?`/`monetization?` fields (nil in spine, same identity in B2)
— so a handler reaches a B2 seam with zero Net change (concern 15). **Construct-vs-Start:**
`Context.build()` *constructs* `clock`/`config`/`data`/`net`/`gate` (all non-nil at t0); their `Start`
(for `net`/`data`) does I/O wiring only (§2.2). The `*Like` structural aliases `Net.luau` references
are satisfied by these concrete types.

### 2.4 The server bootstrap (`src/server/init.server.luau`)

The single entry point. It is the ONLY place that knows the concrete service order. Per Rojo,
`init.server.luau` under `src/server` makes the `Server` folder a `Script` that runs on the server.

This module is **Roblox-only** (uses `game`/`script`); no spec ever requires it (D1).

```lua
--!strict
-- core/src/server/init.server.luau   [Roblox-only — never required by a spec]
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

local Context = require(Server.Context)
local Bootstrap = require(Server.framework.Bootstrap)

-- CONSTRUCT phase: every core context field (clock, config, data, net) is non-nil now.
-- B2 seams (security/flags/analytics/monetization) are constructed here too once they exist;
-- nil in the spine. (See §2.2 Construct-vs-Start.)
local context = Context.build()

-- DETERMINISTIC ORDER. Earlier = depended-upon-by-later. Each entry is the SAME object held
-- in `context` (context.net IS services[1]); they appear here only to receive Start().
-- 1. NetServer:Start binds the RemoteEvent/Function before any service registers an action.
-- 2. DataService:Start hooks PlayerAdded/Removing before any service reads/writes data.
-- 3. Feature services (the sample) register their actions last.
local services = {
	context.net,         -- NetServer  (constructed in Context.build; Start binds the remotes)
	context.data,        -- DataService(constructed in Context.build; Start hooks PlayerAdded)
	-- [B2] context.security, context.flags, context.analytics, context.monetization,
	require(Server.services.sample.SampleService), -- [SAMPLE]
}

-- Server-authority fail-loud (concern 7): the spine ships a minimal rate Gate (§3.6) so the
-- gateway is genuinely rate-limited the moment the spine exists. If a future build registers an
-- action while the FULL B2 security suite is still absent in a NON-test environment, NetServer
-- WARNS (publish-safety reminder) — see §3.3. A spine fork is rate-limited + ownership-checked,
-- but NOT publish-safe until B2 security lands (documented in §6 and FACTORY note).

Bootstrap.start(services, context)

game:BindToClose(function()
	Bootstrap.stop(services, context) -- DataService:Stop flushes all sessions within budget (§4.4)
end)
```

> Contract (no longer an "implementation choice"): **`net` and `data` are CONSTRUCTED in
> `Context.build()`** (so context fields are non-nil at t0) and appear in `services` **only to receive
> `Start()`**; they are the identical references. **NetServer:Start runs before DataService:Start
> before any feature service:Start**, and **`BindToClose` triggers a budget-respecting full session
> flush** (§4.4). See §2.2.

### 2.5 The client bootstrap (`src/client/init.client.luau`)

This module is **Roblox-only** (uses `game`/`script`); no spec ever requires it (D1).

```lua
--!strict
-- core/src/client/init.client.luau   [Roblox-only — never required by a spec]
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
-- -- TODO(verify): StarterPlayerScripts replicate into Players.LocalPlayer.PlayerScripts at runtime.

local Context = require(Client.Context)
local Bootstrap = require(Client.framework.Bootstrap)

local context = Context.build() -- builds NetClient (waits for the server's remotes) + config

local controllers = {
	context.net, -- NetClient (resolves the RemoteEvent/Function)
	require(Client.controllers.sample.SampleController), -- [SAMPLE]
}

Bootstrap.start(controllers, context)
```

The client `Bootstrap` is the same `framework/Bootstrap.luau` logic (shared shape), duplicated under
`src/client/framework/` so the two sides have no cross-tree require. (They are tiny and identical;
duplication is cheaper than a shared require crossing the Server/Client boundary.)

---

## 3. Shared contracts (`src/shared`) — READ-ONLY to feature work

These three modules (+ `Result`, `Migrations`) are the **integration seam**. The contract pass edits
them serially up front; parallel features only *append* (a new action, a new data field) and merge by
union. Feature code never edits the framework logic, only the registries.

### 3.1 `Result.luau` — the cross-boundary result

No exceptions cross the Net boundary. Every handler and every client call returns a `Result`.

```lua
--!strict
-- core/src/shared/Result.luau
export type Ok<T> = { ok: true, value: T }
export type Err = { ok: false, code: string, message: string? }
export type Result<T> = Ok<T> | Err

local Result = {}
function Result.ok<T>(value: T): Ok<T> ... end
function Result.err(code: string, message: string?): Err ... end
return Result
```

`Result.luau` is **Lune-clean** and takes **no requires** (it is a leaf — everyone requires *it*).

Stable error codes the spine defines (B2 extends, never renames): `"BadPayload"`, `"BadType"`,
`"OutOfRange"`, `"NotOwner"`, `"RateLimited"`, `"UnknownAction"`, `"NoData"`, `"Internal"`,
`"Rejected"` (panic flag), and the **lock-contention codes** `"SessionLocked"` and `"LockStolen"`.
`RateLimited`/`NotOwner`/`Rejected` are *registered now* so security (B2) returns them without
inventing codes; `SessionLocked`/`LockStolen` are reserved now so the B2 real session lock (§4.3) can
surface contention through the **unchanged** `Store.load` Result without inventing a code (concern 5):

- `"SessionLocked"` — `load` could not acquire the session lock within its budget (another live
  server holds it and it is not yet stale). `DataService.Start`'s load-retry loop treats this as a
  *retryable* contention error (distinct from `Internal`), backing off per `Config.dataStore` budget.
- `"LockStolen"` — this server's previously-held lock was stolen by another server after the stale
  timeout (heartbeat lapsed). A subsequent `save`/`release` returning `LockStolen` means **this
  server must NOT write** (it would clobber the new owner); it drops the write and logs data-loss-risk
  rather than overwriting. The spine `MockStore` is single-process and never returns these; the codes
  exist so the §4.1 `Store` interface is the *same* interface B2's `SessionStore` implements.

### 3.2 `Types.luau` — the player-data shape (v1) + all aliases

`PlayerData` is the single persistent shape. It carries a `schemaVersion`. **Every field a deferred
module touches is reserved now** so migrations stay additive and the union-merge of two features that
each add a field is trivial.

```lua
--!strict
-- core/src/shared/Types.luau

export type SchemaVersion = number
local CURRENT_SCHEMA_VERSION: SchemaVersion = 1

-- The single persisted player shape (v1). One table, versioned.
export type PlayerData = {
	schemaVersion: SchemaVersion,

	-- --- economy (concurrency-safe writes go through DataService) ---
	currencies: { [string]: number },   -- e.g. { Stardust = 0, Prisms = 0 }; numbers are server-authored

	-- --- progression ---
	stats: {
		playtimeSeconds: number,
		joinCount: number,
	},

	-- --- time-based features (server clock only; never client time) [data uses now; logic in B2] ---
	timestamps: {
		firstJoinUnix: number,
		lastSeenUnix: number,           -- written on save/release; offline-earnings base in B2
	},

	-- --- reserved seams (present + empty in v1 so B2 adds logic, not schema) ---
	upgrades: { [string]: number },     -- [B2 shop] purchased upgrade levels
	flags: { [string]: boolean },       -- [B2 live-ops / one-time grants] per-player booleans
	receipts: { [string]: boolean },    -- [B2 monetization] processed receipt IDs (idempotency)
	analytics: { lastEventUnix: number }?, -- [B2 analytics] light per-player bookkeeping
}

export type AnyTable = { [string]: any }

-- The CLIENT-SAFE projection of PlayerData (concern 17). This is the ONLY shape that crosses to the
-- client. It is a TYPE (not `any`) so NetClient:on("data", fn) is typed, and the projection is a
-- pure function so Tier-1 can assert internal ledgers never leak. Strips: receipts (idempotency
-- ledger), analytics (server bookkeeping), and any future internal field. Keeps the player-facing
-- subset (currencies, public stats, public upgrade levels).
export type PlayerView = {
	schemaVersion: SchemaVersion,
	currencies: { [string]: number },
	stats: { playtimeSeconds: number, joinCount: number },
	upgrades: { [string]: number },
	flags: { [string]: boolean },
}

local Types = {}
Types.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

-- PURE projection: PlayerData -> PlayerView. DataService calls this before every push (§4.5).
-- It allowlists fields (never blocklists) so a NEW PlayerData field is invisible to the client by
-- default — a field is only replicated if added here deliberately. Lune-clean, Tier-1 testable.
function Types.toView(data: PlayerData): PlayerView
	return {
		schemaVersion = data.schemaVersion,
		currencies = data.currencies,
		stats = data.stats,
		upgrades = data.upgrades,
		flags = data.flags,
	}
end

return Types
```

`Types.luau` is **Lune-clean** and requires **nothing** (a leaf of types + the pure `toView`).

**Why these reserved fields now:** `receipts` is the idempotency ledger `ProcessReceipt` (B2) writes
into the data layer — it must exist before monetization so receipt recording is just a data write.
`upgrades`/`flags` give shop & live-ops a home. `currencies` is a map (not fixed fields) so a game
adds `Prisms` without a migration. Adding a *new* reserved key later → a migration step (§3.5).

**Why `toView` is allowlist (security check, not cosmetics):** the projection is the single point
where server-only data (`receipts`, `analytics`, any future ledger) is guaranteed *not* to reach the
client. `data.spec` asserts `Types.toView(d).receipts == nil` and `.analytics == nil` for a populated
`d`, so a future field added to `PlayerData` cannot silently leak to clients (it is absent from
`PlayerView` until someone adds it to `toView`, which the test will then guard).

### 3.3 `Net.luau` — action registry + gateway + client call shape

One wire surface. A feature registers a **named action** with a **validator** and a **rate policy**.
The registry is declarative (data); `NetServer`/`NetClient` are the runtime that consumes it.

`Net.luau` is **Lune-clean**: its one cross-module require (`Result`) goes through the D1
`script == nil` require-shim (sketch shows the Lune branch `require("./Result")`). It touches no Roblox
global at module scope except the shim discriminant (the `Player`/`Clock`/`DataService` type
references are *type-only*, erased at runtime).

```lua
--!strict
-- core/src/shared/Net.luau     [Lune-clean — Result via the D1 require-shim; Lune branch shown]
local Result = require("./Result") -- full module: wrap in the `if script == nil` shim (D1)
type Result<T> = Result.Result<T>

-- How often a player may invoke an action. Enforced by the spine rate Gate (§3.6) AND the full
-- B2 token bucket; declared on every action now so enforcement needs no Net change.
export type RatePolicy = {
	maxPerWindow: number,  -- e.g. 5
	windowSeconds: number, -- e.g. 1.0  (measured on the SERVER MONOTONIC clock — ctx.clock:mono())
	burst: number?,        -- optional token-bucket burst; defaults to maxPerWindow
}

-- A validator turns an UNTRUSTED payload into a typed, range-checked value, or an Err.
-- It runs on the server BEFORE the handler. It is pure + injectable => Tier-1 testable.
export type Validator<T> = (rawPayload: any) -> Result<T>

-- ActionContext is a TYPED, NARROW projection of ServerContext (concern 15): NetServer builds it by
-- closing over the real ServerContext, so the deps are the SAME objects and the fields are concrete,
-- not `any`. The deferred seams appear here as the SAME optional fields ServerContext has, so a B2
-- handler reads `ctx.monetization` / `ctx.flags` with ZERO Net change. To avoid a require cycle
-- (Net is shared, ServerContext is server-only), the collaborator types are referenced by name via
-- generic params the NetServer fills; here they are documented type-stubs, not `any`:
--   Clock, DataService, Security, FeatureFlags, Analytics, Monetization are the SAME types
--   ServerContext (§2.3) uses. NetServer passes the real instances through.
export type ActionContext = {
	player: Player,           -- read ONLY .UserId / .Name (Lune-mock compatible, §7.3)
	clock: ClockLike,         -- server clock (§5); handlers read time HERE, never from payload
	data: DataServiceLike,    -- the per-player data layer (§4.4)
	-- deferred seams: nil in the spine, same identity as ServerContext's fields once B2 lands.
	security: SecurityLike?,  -- [B2]
	flags: FlagsLike?,        -- [B2]
	analytics: AnalyticsLike?,-- [B2]
	monetization: MonetizationLike?, -- [B2]
}
-- (ClockLike/DataServiceLike/… are the structural types these modules export; Net references them
--  structurally so the shared module needs no require into server-only code. The concrete server
--  types in §2.3 satisfy these structural aliases.)

export type Handler<TIn, TOut> = (ctx: ActionContext, payload: TIn) -> Result<TOut>

-- One registered action. `name` is the wire identifier (stable string).
export type Action<TIn, TOut> = {
	name: string,
	validate: Validator<TIn>,
	rate: RatePolicy,
	handler: Handler<TIn, TOut>,
	-- [B2] requiresOwnership / requiresProduct hooks live here as optional fields later.
}

export type Registry = {
	-- Register an action. Errors at boot if `name` is already taken (no silent override).
	register: <TIn, TOut>(self: Registry, action: Action<TIn, TOut>) -> (),
	get: (self: Registry, name: string) -> Action<any, any>?,
	names: (self: Registry) -> { string },
}

local Net = {}
-- Creates a fresh, empty registry (one per server; tests create throwaway ones).
function Net.newRegistry(): Registry ... end

-- THE single pure inbound pipeline (concern 19). Called by BOTH NetServer (real wire) and
-- Mocks.net.invoke (tests) so they can never diverge. Runs steps 2-7 of the inbound flow:
-- lookup -> [panic] -> [rate via gate] -> [ownership] -> validate -> pcall(handler).
-- Lune-clean & synchronous-by-contract for the validate/handler portion. `gate` is the §3.6
-- rate/ownership gate (or a no-op gate in tests that don't exercise rate).
function Net.dispatch(
	registry: Registry,
	gate: any,           -- Gate (§3.6); nil-tolerant for panic/ownership seams
	ctx: ActionContext,
	actionName: string,
	rawPayload: any
): Result<any> ... end

-- Stable action-name constants the spine + B2 features share (avoids typos across files).
Net.Actions = {
	Sample = "sample.ping", -- [SAMPLE]
	-- [B2] Shop = "shop.buy", Rebirth = "rebirth.do", Claim = "offline.claim",
	-- [B2] Daily = "daily.claim", Purchase is server-driven (ProcessReceipt), not a client action.
}

return Net
```

**Inbound validation flow — ONE pure dispatch function shared by NetServer AND the mock (concern 19).**
The steps below are factored into a single pure function `Net.dispatch(registry, gate, ctx, actionName,
rawPayload) -> Result<any>` that takes its collaborators injected. **Both** the real `NetServer`
(after it pulls `(player, actionName, rawPayload)` off the wire) **and** `Mocks.net.invoke` call this
*same* function, so the mock's pipeline cannot drift from production — the sample spec then genuinely
covers the dispatch logic, not a re-implementation. `Net.dispatch` is Lune-clean (pure; the wire I/O
that precedes it lives in the Roblox-only `NetServer`).

1. Receive `(player, actionName, rawPayload)` on the single `RemoteEvent`/`RemoteFunction` (NetServer).
2. `actionName` must be a `string` and a registered action → else `Err("UnknownAction")`.
3. **Panic flag check** → if `ctx.security` is non-nil and panic is set, `Err("Rejected")`. Nil-safe:
   skipped in the spine (no panic flag yet).
4. **Rate check** → the spine's minimal `Gate` (§3.6) enforces the action's `RatePolicy` token bucket
   keyed by `(player.UserId, actionName)` on `ctx.clock:mono()` → `Err("RateLimited")` when exhausted.
   This runs **in the spine** (not deferred): the gateway is rate-limited the moment the spine exists
   (concern 7). B2's full `RateLimiter` replaces `Gate` behind the same call (`ctx.security` supersedes
   it when present); the *code* and the *behavior* are present now.
5. **Ownership assert** → if the action declares an ownership requirement, `Gate.assertOwner(ctx,
   payload)` checks the acting player owns the target (`Err("NotOwner")`). The spine sample needs none,
   but the helper and code exist so a feature added before B2 is ownership-checked (concern 7).
6. `action.validate(rawPayload)` → on `Err`, return it (`BadType`/`OutOfRange`/`BadPayload`).
7. Build the narrow `ActionContext` (closing over the real ServerContext deps) and call
   `action.handler` **inside `pcall`** (concern 18): any thrown error → `Err("Internal")`, so **no
   exception ever crosses the Net boundary** (matches the Result contract). The handler's `Result` is
   returned as-is on success.

Steps 3–5 are **ordered before** validation so an exploiter's spam is rejected cheaply. The spine runs
1,2,(4 via Gate),6,7 — panic/ownership (3,5) are nil-safe no-ops until a feature/B2 needs them. The
seam shape never changes: B2 sets `ctx.security` and 3–5 light up with zero handler edits.

**Authoring rule — never hold a lock across a client-controllable yield (concern 11).** A handler
must do all client-facing work *before or after* the locked transform, and the transform passed to
`DataService:update` / `Session:update` **must be synchronous** (no yields inside the transform, and
nothing inside it that waits on client input). Because the single `RemoteFunction` runs each
`OnServerInvoke` on its own thread, a handler that acquired a Session lock and then yielded on
something the client controls would stall every other update on that key. The transform is pure
read-modify-write over the current value; client I/O happens outside the lock. The sample sets this
pattern; every feature copies it.

**Client call shape (`NetClient`):**

```lua
-- Returns a Result<TOut>. Uses a RemoteFunction for request/response actions.
-- payload is plain data; the client cannot be trusted, so this is just a transport.
function NetClient:call(actionName: string, payload: any): Result<any> ... end
-- For server->client pushes (e.g. data replication, HUD), NetClient also exposes:
function NetClient:on(eventName: string, fn: (payload: any) -> ()): RBXScriptConnection ... end
```

> **Wire shape decision (scrutinize):** request/response actions use **one shared `RemoteFunction`**
> (`Net` gateway) keyed by `actionName`; server→client notifications use **one shared `RemoteEvent`**.
> One of each, not one pair per feature. Validation + dispatch happen in `NetServer` off the registry
> via the single pure `Net.dispatch`. `-- TODO(verify):` `RemoteFunction.OnServerInvoke` runs each
> invocation on its own thread, so a hostile client can hang its own invocation only, not the server.
> **Contractual safety rules for the single OnServerInvoke dispatcher (concern 18):**
> - It **wraps every handler in `pcall`** and converts any error to `Result.err("Internal")`, so a
>   handler error never propagates back across the RemoteFunction as a thrown exception (which would
>   violate the Result-only contract and could drop the response). No exceptions cross the wire.
> - Handlers **must not unboundedly yield**; B2's DataStore calls run under a timeout/budget. A
>   handler must never hold a Session lock across a client-controllable yield (the §3.3 authoring rule).
> - **B2 escape hatch (noted now, LOW):** if RemoteFunction head-of-line behavior ever bites (one slow
>   action stalling the shared path), the alternative is a `RemoteEvent` + correlation-id
>   request/response. Not needed in the spine; recorded so B2 has a known exit.

### 3.4 `Config.luau` — static tunables

```lua
--!strict
-- core/src/shared/Config.luau
export type Config = {
	storeName: string,        -- DataStore name (new-game renames this per game for isolation)
	schemaKeyPrefix: string,  -- per-player key prefix, e.g. "player_"
	dataStore: {
		maxRetries: number,     -- same-key write retry budget (DataStore budget awareness)
		retryBaseSeconds: number, -- backoff base (uses injected clock in tests)
		writeMinIntervalSeconds: number, -- throttle floor between same-key writes
	},
	rateDefaults: { maxPerWindow: number, windowSeconds: number }, -- fallback RatePolicy
	flagsSeed: { [string]: boolean }, -- [B2 live-ops] compile-time default flag values
}
local Config: Config = { ... }
return Config
```

`Config` is split conceptually: the whole table is server-side; only a documented client-safe subset
is exposed via `ClientContext.config` (no store names / budgets leak to the client). `Config.luau` is
**Lune-clean** and requires nothing (pure data + types).

### 3.5 `Migrations.luau` — structural change handling

```lua
--!strict
-- core/src/shared/Migrations.luau
-- Ordered steps; index i migrates schemaVersion i -> i+1. PURE functions (Tier-1 testable).
export type MigrationStep = (old: { [string]: any }) -> { [string]: any }

local steps: { MigrationStep } = {
	-- [1] = function(v1) ... -> v2 end,  -- added when the shape first changes
}

local Migrations = {}
-- Returns a fresh default PlayerData at CURRENT_SCHEMA_VERSION (new player).
function Migrations.default(nowUnix: number): { [string]: any } ... end
-- Runs every step from data.schemaVersion up to CURRENT, returning a current-version blob.
-- Never loses fields; unknown extra fields are preserved. Round-trip tested.
function Migrations.migrate(data: { [string]: any }): { [string]: any } ... end
return Migrations
```

The data layer calls `Migrations.migrate` on every load. A new player gets `Migrations.default(now)`
where `now` is the **injected server clock** (never client time). `Migrations.luau` is **Lune-clean**;
it may `require("./Types")` for `CURRENT_SCHEMA_VERSION` (relative require, D1) and touches no Roblox
global.

### 3.6 `security/Gate.luau` — the minimal spine rate/ownership gate [SPINE]

The previous draft deferred *all* rate-limiting and ownership enforcement to B2, leaving the spine
gateway with type+range validation only — which violates FACTORY.md §10 ("validate type + range +
ownership + rate on EVERY request") and makes a pre-B2 fork exploitable (concern 7). The fix: ship a
**minimal, original, Lune-clean** gate now. It is the seed B2's full `RateLimiter`/`ViolationTracker`
grow from, behind the same call site.

```lua
--!strict
-- core/src/server/security/Gate.luau   [SPINE — Lune-clean: relative require + injected clock]
local Result = require("../../shared/Result")  -- relative require (D1); Gate touches no Roblox global
type Result<T> = Result.Result<T>

export type Gate = {
	-- Token-bucket rate check keyed by (userId, actionName), measured on the MONOTONIC clock.
	-- Returns ok or Err("RateLimited"). Pure logic over an injected clock => Tier-1 testable.
	check: (self: Gate, userId: number, actionName: string, policy: RatePolicy) -> Result<true>,
	-- Ownership assertion helper: a feature passes the acting userId and the target it claims to own;
	-- returns Err("NotOwner") on mismatch. The spine ships the helper; features declare the predicate.
	assertOwner: (self: Gate, actingUserId: number, ownerUserId: number) -> Result<true>,
}

local Gate = {}
-- clock is injected (the server Clock §5). Buckets live in-memory keyed by userId|actionName.
function Gate.new(clock: ClockLike): Gate ... end
return Gate
```

- **Rate** uses `clock:mono()` (monotonic, process-local — never persisted; concern 9). Buckets are
  in-memory only.
- **Ownership** is a tiny equality helper now; B2's `Validator` extends it (e.g. plot/pet ownership).
- `Net.dispatch` calls `gate:check(...)` at step 4 for every action. When `ctx.security` (B2) is
  present, the full `RateLimiter` supersedes `Gate` at the same call site — no handler change.
- **Fail-loud seam:** `NetServer:register` warns once (non-test env) if an action is registered while
  the **full B2 security suite** is absent, as a publish-safety reminder. The spine is rate-limited +
  ownership-capable; it is **not publish-safe** until B2 (panic flag, violation tracking, full
  validators) lands — see the publish-safety note in §6.

---

## 4. The data layer

Crash-safe, session-locked, single-writer, schema-versioned, DataStore-budget-aware, injectable
clock. Defined by an **interface** so the Tier-1 mock and the B2 real store are interchangeable.

### 4.1 The `Store` interface (`data/Store.luau`)

The low-level persistence contract. `MockStore` (spine) and `SessionStore` (B2) both implement it.
All methods **may yield** and return a `Result` (no throwing across the boundary).

`Store.luau` is **Lune-clean**: relative require (D1), no Roblox global. Store sits in
`src/server/data`; `Result` is in `src/shared`, so the cross-tree relative path is `../../shared/Result`.

```lua
--!strict
-- core/src/server/data/Store.luau   [Lune-clean — relative require only]
local Result = require("../../shared/Result")  -- script-relative; resolves from any cwd under Lune
type Result<T> = Result.Result<T>

-- A loaded, session-locked record. The lock is the single-writer guarantee:
-- only the server holding the lock may write; a second server's load waits/steals per the impl's
-- policy (B2 SessionStore). The mock grants instantly (single process).
export type Session<T> = {
	key: string,
	data: T,                         -- the current in-memory value (already migrated)
	-- Replace the in-memory value (does NOT write to backing store).
	set: (self: Session<T>, value: T) -> (),
	-- Atomically transform under a PER-KEY LOCK QUEUE (read-modify-write); the canonical
	-- concurrency-safe mutation. Returns the new value. See the lock-queue contract below.
	update: (self: Session<T>, transform: (current: T) -> T) -> Result<T>,
	-- Flush the in-memory value to the backing store (throttled + retried per budget).
	save: (self: Session<T>) -> Result<T>,
	-- Save (final) + release the session lock. Idempotent.
	release: (self: Session<T>) -> Result<T>,
}

export type Store = {
	-- Acquire a session lock for `key`, returning the migrated value (or a fresh default).
	-- `default` supplies the new-record value when the key is empty.
	-- May return Err("SessionLocked") if another server holds the lock and it cannot acquire within
	-- budget (B2 contention seam — concern 5); the mock never returns it (single process).
	load: (self: Store, key: string, default: () -> any) -> Result<Session<any>>,
	-- True if this Store currently holds a session for `key` (single-writer check).
	isLocked: (self: Store, key: string) -> boolean,
}

local Store = {}
return Store -- the module exports the TYPES + any shared helpers; impls are separate files.
```

**Concurrency-safety contract — the per-key lock queue (concern 4, the headline mechanism).** This is
specified explicitly because the whole anti-double-spend claim hinges on it, and because a naive
read→yield→write *without* a queue demonstrably loses updates. (Reproduced on the pinned Lune: two
interleaved `+5` then `+3` updates on a no-queue store land at **3**, not 8 — a lost update. The same
two updates on the lock-queue store below land at **8**.)

> `Session:update(transform)` MUST behave as follows, and `MockStore` MUST implement it literally:
> 1. **Acquire** the key's lock. If the lock is already held (a prior `update` on this key is
>    mid-transform/yielded), the caller **parks in a FIFO queue and yields** — it does **not** read
>    the current value yet.
> 2. Once it owns the lock, it **(re-)reads the latest in-memory value** — *after* any earlier update
>    has written, so it never starts from stale state.
> 3. It runs `transform(current)` (which is **synchronous** — §3.3 rule: no client-controllable yield
>    inside a transform) and writes the result.
> 4. **Release** the lock and resume the next FIFO waiter, which then performs its own re-read at (2).
>
> Therefore two interleaved/spam-duplicated updates on the same key apply **sequentially against the
> latest value** — no lost update, no double-spend. The Tier-1 mock exposes a `yieldOnUpdate` hook
> that forces a yield **inside the critical section** (step 3's boundary) so a second `update` arriving
> during the yield is *forced* to exercise the queue (step 1 park). **Falsifiability requirement
> (concern 4):** the race spec (§9.3) is written so that it **lands at the wrong sum if the queue is
> absent** (i.e. if `update` were implemented as read→yield→write with no FIFO park/re-read). A green
> race test therefore *distinguishes* a correct queue from a no-op; the test cannot pass against the
> broken implementation.

### 4.2 `MockStore.luau` — in-memory implementation [SPINE]

Implements `Store` against an in-process table. It is the spine runtime default **and** the Tier-1
fixture. **Lune-clean** (relative require, no Roblox global — verified the partition holds). Capabilities:
- Instant lock grant (single process); `isLocked` reflects the in-memory lock set.
- `update` implements the **per-key FIFO lock queue** of §4.1 literally (park-yield-rewread-release).
  By default the critical section does not yield; `yieldOnUpdate = true` forces a yield inside it so a
  second same-key `update` is made to park and re-read — the mechanism the race test (§9.3) exercises.
- `failSave`/`failLoad` make `save`/`load` return `Err("Internal")`. `throttleSaves` (+ a counter)
  makes the first N `save`s on a key return a throttled `Err` before succeeding, so the **retry-per-
  budget** and **BindToClose-under-throttle** paths (concern 6) are testable without real DataStores.
- Honors `Config.dataStore.writeMinIntervalSeconds` against the **injected clock** so throttle logic
  is exercised without real time. A `save` that exhausts `maxRetries` returns `Err` (data-loss-risk),
  never silently succeeds — the spec asserts the error surfaces rather than being swallowed.

```lua
--!strict
-- core/src/server/data/MockStore.luau   [SPINE — Lune-clean]
export type MockOptions = {
	clock: ClockLike,             -- injected (required)
	config: ConfigLike,           -- injected: supplies maxRetries / writeMinIntervalSeconds
	failLoad: boolean?,
	failSave: boolean?,
	throttleSaves: number?,       -- first N saves per key return a throttled Err, then succeed
	yieldOnUpdate: boolean?,      -- force a yield in the update critical section (race tests)
	seed: { [string]: any }?,     -- preload keys
}
local MockStore = {}
function MockStore.new(options: MockOptions): Store ... end
return MockStore
```

### 4.3 `SessionStore.luau` — real session-locked DataStore [B2]

Deferred. Implements the **same `Store` interface, unchanged**. B2 responsibilities (contracted now
so the interface already fits):

- `DataStoreService:GetDataStore(Config.storeName)`.
- A **session-lock record** = `{ lockId, heartbeatUnix }` written on the **server clock**, so only one
  server writes a key. `lockId` is this server's identity (e.g. `game.JobId` `-- TODO(verify):`).
- `UpdateAsync` for atomic read-modify-write (the engine's own per-key serialization complements the
  in-process FIFO queue of §4.1).
- **Lock contention + steal (concern 5):** `load` that finds a *live* lock owned by another server
  retries within budget and returns **`Err("SessionLocked")`** if it cannot acquire; if the existing
  lock's `heartbeatUnix` is older than the stale timeout, it **steals** it (writes its own lockId).
  A `save`/`release` that discovers its `lockId` was overwritten returns **`Err("LockStolen")`** and
  **must not write** (the new owner is authoritative). `DataService.Start`'s load loop already handles
  the `SessionLocked` retry (§4.4); these codes are reserved in `Result` now (§3.1), so adding the real
  lock surfaces no new code and changes no call site.
- **DataStore-budget-aware throttle + retry** on same-key writes (`Config.dataStore.maxRetries`,
  `retryBaseSeconds`, `writeMinIntervalSeconds`).
- **BindToClose flush respects the budget (concern 6):** the shutdown flush MUST **batch/stagger**
  saves (honor `writeMinIntervalSeconds` + the global write budget) rather than firing N concurrent
  `UpdateAsync` calls that get throttled and silently fail. Each save still gets its retry budget
  within the ~30s `BindToClose` window; a save that **exhausts retries is logged as data-loss-risk**,
  never silently dropped. The mock's `throttleSaves` lets Tier-1 assert the staggered-retry behavior
  even though the mock is instant (the *policy* is tested against the mock; the real DataStore budget
  is a Tier-2 check).

None of this changes a single call site — `DataService` only ever sees `Store`.

### 4.4 `DataService.luau` — session-scoped per-player data [SPINE]

The service feature code actually uses. It owns the player→session lifecycle and is the *only* thing
that holds `Store` sessions. It is a `Service` (has `Start(context)`).

```lua
--!strict
-- core/src/server/data/DataService.luau
export type DataService = {
	name: "DataService",
	Start: (self: DataService, context: any) -> (),
	Stop: (self: DataService, context: any) -> (),  -- flush all sessions (BindToClose)

	-- Returns the loaded PlayerData for a player, or Err("NoData") if not loaded yet.
	get: (self: DataService, player: Player) -> Result<PlayerData>,
	-- Concurrency-safe mutation: transform runs under the session lock (Session:update).
	-- THE canonical write path for all economy/state changes.
	update: (self: DataService, player: Player, transform: (PlayerData) -> PlayerData) -> Result<PlayerData>,
	-- Force a save (throttled/retried). Normally automatic on release.
	save: (self: DataService, player: Player) -> Result<PlayerData>,
}
local DataService = {}
-- store/clock/config injected (the §0.1-D1 fallback: DataService takes deps, never sibling-requires
-- a Roblox-only module). Lune-clean; specs call get/update/save directly with a Mocks.player.
function DataService.new(store: Store, clock: Clock, config: Config): DataService ... end
return DataService
```

**`DataService.update` serializes per player.** Every economy/state write funnels through
`update(player, transform)`, which resolves the player's `Session` and calls `Session:update` — so the
per-key lock queue (§4.1) makes interleaved/spam writes for one player apply sequentially against the
latest value. This is the spine-level statement of the anti-double-spend guarantee.

**Lifecycle (`Start`) — Roblox event wiring only (construct already happened in Context.build, §2.2):**
connect `Players.PlayerAdded` → `store:load(key, () -> Migrations.default(clock:unix()))` in a
**load-retry loop** that distinguishes outcomes (concern 5): `Err("SessionLocked")` → back off per
`Config.dataStore` budget and **retry** (another server is releasing); `Err("Internal")` → retry
within `maxRetries`; exhausted → log + kick the player (cannot serve un-loadable data). On success:
cache the session and push `Types.toView(session.data)` via `NetServer` (§4.5). Connect
`Players.PlayerRemoving` → `session:release()` (final save). `get` returns `Err("NoData")` until load
completes.

**`Stop` (BindToClose) — budget-aware full flush (concern 6).** `-- TODO(verify):` `BindToClose` has a
~30s soft budget and the server is terminating. `Stop` flushes **every** live session, but **respects
the write budget**: with the mock (instant) it fans out via `task.spawn` and awaits all; with the real
`SessionStore` (B2) the flush **staggers** to honor `writeMinIntervalSeconds` + the global write budget
rather than blind concurrent fan-out, retries each save per `maxRetries`, and **awaits completion or a
deadline** before returning. A save that exhausts its retries is **logged as data-loss-risk, not
silently dropped**. Tier-1 asserts (via `throttleSaves`) that `Stop` retries per budget rather than
firing once — see §9.5.

**Injection:** `DataService.new(store, clock, config)` — `store` is `MockStore` in the spine and in
Tier-1 (with a fake clock), `SessionStore` in B2 production. The service code is identical across all
three. This is the load-bearing seam that makes B2 a drop-in.

### 4.5 Net replication of data to the client (the typed, projected view)

Feature controllers do not read the DataStore. `DataService` pushes the **typed client-safe view**
`Types.toView(data): PlayerView` (§3.2) over the shared `RemoteEvent` on load and on change;
`NetClient:on("data", fn: (PlayerView) -> ())` receives it (concern 17). The projection is the single
named pure function that strips internal ledgers (`receipts`, `analytics`) — it is **Tier-1 tested**
(`data.spec` asserts `toView` never leaks `receipts`/`analytics`), so the client view is a *typed,
testable* contract, not a second drifting `any` shape. The spine wires a minimal version (push on
load) so the sample can display `currencies.Stardust`; richer diffing is a feature concern, but every
feature pushes through `toView`, never a raw `PlayerData`.

---

## 5. The injectable clock (`data/Clock.luau`)

Server time, never client time, and injectable for tests. The clock is a tiny interface so the same
code path runs on the real server clock in production and a fake in Tier-1.

```lua
--!strict
-- core/src/server/data/Clock.luau
export type Clock = {
	-- Unix seconds (server wall clock) — for timestamps, streaks, offline accrual.
	unix: (self: Clock) -> number,
	-- Monotonic seconds — for rate windows / throttle intervals (immune to wall-clock jumps).
	mono: (self: Clock) -> number,
}

local Clock = {}
-- Real clock: unix = os.time() (server wall clock). SERVER ONLY.
-- mono()'s source is INJECTED so the module references no Roblox global and stays Lune-clean:
-- on Roblox, os.clock() is Lua-VM CPU time (advances only while Lua runs) — NOT monotonic wall
-- time — so the Roblox bootstrap (Context.build) passes the `time` global (seconds since the
-- server started, a monotonic high-resolution wall clock) as monoSource; Lune/tests fall back to
-- os.clock, which under standalone Lune DOES advance with wall time (verified). This removes the
-- os.clock()-CPU-time runtime risk: rate/throttle windows measure real elapsed seconds in-engine.
function Clock.real(monoSource: (() -> number)?): Clock ... end -- mono := monoSource or os.clock
-- Fake clock for tests: starts at `startUnix`; advance(seconds) moves BOTH unix and mono.
function Clock.fake(startUnix: number): Clock & { advance: (self: any, seconds: number) -> () } ... end
return Clock
```

`Clock.luau` is **Lune-clean** (uses only `os.time`/`os.clock`, which exist under Lune — verified —
and no Roblox global; the monotonic Roblox `time` global is injected from the Roblox-only
`Context.build`, never referenced inside the module), so DataService/Gate/MockStore that depend on
it stay spec-requirable.

**Mono vs unix usage rule (concern 9):**
- `unix()` (wall clock) is the **only** value that may be **persisted** in `PlayerData`
  (`timestamps.*`, future streak/accrual bases). It is comparable across sessions and servers.
- `mono()` is **process-local and ephemeral** — used purely in-memory for rate windows
  (`Gate`/`RateLimiter`) and the `writeMinIntervalSeconds` throttle. **It must NEVER be persisted or
  compared across sessions/servers/restarts** (it resets per process and is not cross-server
  comparable). Throttling reads `mono()` in-memory only. This invariant is stated so a B2 author
  cannot accidentally store a `mono()` value and get wrong throttling after a reload.

Every time-based decision (throttle interval, rate window, future offline-earnings/streak/restock in
B2) reads `context.clock`. Tests advance the fake clock and assert correct accrual **and** that a
client-supplied timestamp in a payload is ignored (the clock-rollback exploit is structurally
impossible because handlers read `ctx.clock`, never the payload's time).

---

## 6. Deferred modules (B2) — contracted, not implemented

Each is accounted for by an existing seam so B2 is additive. Summary of where each plugs in:

| Module | Spine seam it uses | What B2 adds |
|---|---|---|
| **Security** (`security/`) | `ServerContext.security?` + `ActionContext.security?`, `RatePolicy` on every `Action`, `Result` codes `RateLimited`/`NotOwner`/`Rejected`, `Net.dispatch` steps 3–5, **the spine `Gate` (§3.6) it supersedes** | full token-bucket `RateLimiter`, shared `Validator` helpers, `ViolationTracker`, global `Panic` flag |
| **Live-ops** (`liveops/`) | `ServerContext.flags?` + `ActionContext.flags?`, `Config.flagsSeed`, `PlayerData.flags` | externally-flippable `FeatureFlags` (no redeploy) |
| **Analytics** (`analytics/`) | `ServerContext.analytics?` + `ActionContext.analytics?`, `PlayerData.analytics`, JSON-line reporter style already in testkit | batched JSON-line sink + core taxonomy (`session_start`, … `feature_used`) |
| **Monetization** (`monetization/`) | `ServerContext.monetization?` + `ActionContext.monetization?`, `PlayerData.receipts` (idempotency ledger), `DataService:update` (one atomic transform), `Result` (`NotProcessedYet`) | `ProcessReceipt`, `Products` ownership checks, emits `purchase` |
| **Real persistence** (`data/SessionStore.luau`) | the `Store` interface (§4.1) unchanged + reserved `SessionLocked`/`LockStolen` codes | session-locked `UpdateAsync` impl with throttle/retry/steal + budget-aware BindToClose |

**How a B2 handler reaches its seams (concern 15).** Handlers receive the narrow but **typed**
`ActionContext`, which `NetServer` builds by closing over the real `ServerContext`. `ActionContext`
carries the **same optional `security?`/`flags?`/`analytics?`/`monetization?` fields** (nil in the
spine, the *same object identity* as `ServerContext`'s once B2 lands). So a B2 monetization handler
reads `ctx.monetization` with **zero Net contract change** — `ActionContext` is a typed subset, not a
redundant second type, and its deps are concrete types (`Clock`, `DataService`), never `any`.

**ProcessReceipt atomicity invariant (concern 8 — the real-money rule, stated now though impl is B2).**
`ProcessReceipt` MUST perform the **receipt-id check, the currency grant, and the receipt-id stamp
inside ONE `DataService:update` transform** (one atomic read-modify-write under the session lock):
```
update(player, function(d)
  if d.receipts[receiptId] then return d end   -- already processed: no-op (idempotent)
  d.currencies[cur] += amount                  -- grant
  d.receipts[receiptId] = true                 -- stamp, SAME transform
  return d
end)
```
and it MUST return `PurchaseGranted` **only if the subsequent `save` Result is `ok`** — otherwise it
returns `NotProcessedYet` so Roblox re-delivers the receipt. Returning `PurchaseGranted` before a
confirmed save is **forbidden** (the classic crash-between-grant-and-record dupe/loss). Two separate
updates (grant in one, stamp in another) are forbidden. The spine's single-transform `DataService:update`
already supports this; reserving the rule here means the B2 builder cannot get it wrong.

**Forward-compatibility checks built into the spine:**
- `Net` already carries a `RatePolicy` per action, reserves `Result` codes for
  security/monetization/lock-contention, and ships the `Gate` that enforces rate **now**, so the
  actions security and monetization add need no `Net` change.
- `Types.PlayerData` already holds `receipts`, `upgrades`, `flags`, `analytics`, so data/analytics/
  monetization touch existing fields (no schema bump just to make room).
- `Context` **and** `ActionContext` type every deferred service as an optional field of identical name.

**Publish-safety note (concern 7) — a spine-only fork is rate-limited but NOT publish-safe.** The
spine ships real type+range validation (per-action validators) **and** real rate-limiting + ownership
asserts (the `Gate`, §3.6), so a forked game is *not* trivially spammable. But the spine does **not**
ship the panic flag, violation tracking, or the full shared validators — so `new-game`/`build-game`
MUST require **B2 security before any monetized or exploitable action is exposed to the public**.
`NetServer:register` warns (non-test env) when the full B2 suite is absent, as a loud reminder. This
keeps the "server-authoritative" claim honest: the *gateway* is genuinely guarded at spine, the *full*
anti-exploit posture is a B2 completion.

---

## 7. The test harness (Tier-1, Lune)

Must `require` + run cleanly under **standalone Lune** — no `game`, `Instance`, `task`, etc. All pure
modules and the testkit avoid Roblox globals; anything needing a Roblox service takes it injected and
gets a mock from `tests/lib/mocks.luau`. (See `docs/TESTING.md` §8 for the layout this matches.)

### 7.1 `tests/lib/testkit.luau` — describe/it/expect + JSON reporter

```lua
--!strict
-- core/tests/lib/testkit.luau
export type Expectation = {
	toBe: (self: Expectation, expected: any) -> (),
	toEqual: (self: Expectation, expected: any) -> (),   -- deep equality
	toBeOk: (self: Expectation) -> (),                   -- Result.ok
	toBeErr: (self: Expectation, code: string?) -> (),   -- Result.err (optionally a code)
	toThrow: (self: Expectation) -> (),
	never: Expectation,                                  -- negation
}
export type TestKit = {
	describe: (name: string, body: () -> ()) -> (),
	it: (name: string, body: () -> ()) -> (),
	expect: (value: any) -> Expectation,
	-- Runs every registered describe/it, collects results, RETURNS the summary.
	-- Does NOT print here (the runner prints exactly one line) — see run.luau.
	run: () -> { passed: number, failed: number, total: number, failures: { string } },
}
return ... -- a fresh TestKit (state is per-require; the runner requires once per process)
```

The reporter prints **exactly one JSON line**, but that print lives in `run.luau` (§7.4) so importing
the testkit in another context never emits stray output.

### 7.2 `tests/lib/assert.luau` — assertions

Pure assertion primitives used by `testkit` (`deepEqual`, `isResultOk`, `isResultErr(code)`,
`approx`). No Roblox globals. Failures raise a Lua error with a readable message; `it` catches it and
records a failure so one bad assertion never aborts the run.

### 7.3 `tests/lib/mocks.luau` — Tier-1 fakes

```lua
--!strict
-- core/tests/lib/mocks.luau
local Mocks = {}
-- A Store impl backed by an in-memory table. Re-exports MockStore semantics but
-- requires NO Roblox globals (MockStore itself must also avoid them).
function Mocks.store(options): Store ... end   -- failLoad/failSave/throttleSaves/yieldOnUpdate/seed
function Mocks.clock(startUnix: number): Clock & { advance: ... } ... end -- the fake clock
-- A fake Player surrogate (just { UserId, Name }) so DataService can key sessions
-- without a real Instance. Handlers must only read .UserId/.Name (documented constraint).
function Mocks.player(userId: number, name: string?): { UserId: number, Name: string } ... end
-- A NetServer-EQUIVALENT harness that calls the SAME pure `Net.dispatch` production uses (concern 19),
-- so the mock pipeline CANNOT drift from NetServer. register actions, then `invoke(name, player,
-- payload)` runs lookup -> [panic] -> [rate via Gate] -> [ownership] -> validate -> pcall(handler)
-- via Net.dispatch and returns the Result. No RemoteEvent. This is why sample.spec genuinely covers
-- the dispatch logic, not a re-implementation of it.
function Mocks.net(context): { registry: Registry, invoke: (name, player, payload) -> Result<any> } ... end
return Mocks
```

> **Cross-cutting constraint this enforces:** server handlers and `DataService` may only read
> `player.UserId` / `player.Name` from the `Player` they receive — never call Roblox methods on it —
> so the same code runs under Lune with `Mocks.player`. This is a documented authoring rule for every
> feature, and what makes Tier-1 economy/race tests possible.

### 7.4 `tests/run.luau` — the runner [SPINE] (explicit list, cwd-independent — concerns 10 & 12)

The runner uses an **explicit, lexically-ordered `specs` list** of **relative requires** — it does
**NOT** use `fs.readDir` discovery. This was a verified break in the prior draft: from repo root
(the gauntlet's stated invocation), `fs.readDir("unit")` and `fs.readDir("core/tests/unit")` both
**error** because `fs.readDir` is **cwd-relative**, while `require("./lib/testkit")` resolves
**script-relative** and works from any cwd. So discovery-by-`fs.readDir` would fail the gauntlet as
specified; an explicit relative-require list does not.

Each spec require is wrapped in **`pcall`** so a require-time error (e.g. a spec accidentally pulling
a Roblox-only module, or any load error) is converted into a **recorded failure** — the run still
prints **exactly one JSON line** with `failed > 0` and exits nonzero, instead of aborting with no
output (which CI would misread as a hang). The one-JSON-line invariant holds on **success AND on any
failure**.

```lua
--!strict
-- core/tests/run.luau   (run: `lune run core/tests/run.luau` — from ANY cwd; repo root is the
--                        gauntlet's choice, but relative requires are script-relative so cwd is moot)
local process = require("@lune/process")
local testkit = require("./lib/testkit")  -- script-relative; verified to resolve from repo root

-- EXPLICIT, LEXICALLY-ORDERED spec list (no fs.readDir). Each entry is a script-relative path.
-- Adding a feature appends one line here; keep the list sorted so the JSON summary is byte-stable.
local SPEC_PATHS = {
	"./unit/data.spec",
	"./unit/framework.spec",
	"./unit/net.spec",
	"./unit/sample.spec",
	"./unit/selene_guard.spec",  -- §9.4 self-test that the selene overlay rejects wait/spawn/delay
}
table.sort(SPEC_PATHS)  -- belt-and-suspenders determinism (concern 10)

local loadFailures = 0
for _, path in SPEC_PATHS do
	-- pcall the require so a require-time error becomes a recorded failure, not an aborted run.
	local ok, err = pcall(require, path)
	if not ok then
		testkit.recordLoadFailure(path, tostring(err))  -- registers a synthetic failing case
		loadFailures += 1
	end
end

local summary = testkit.run()  -- runs every registered describe/it; returns the counts
-- Exactly ONE line to stdout, on success AND on failure:
print(string.format(
	'{"passed":%d,"failed":%d,"total":%d}',
	summary.passed, summary.failed, summary.total
))
process.exit(summary.failed == 0 and 0 or 1)  -- nonzero exit fails the gauntlet
```

`-- TODO(verify):` Lune 0.10.4 exposes `@lune/process` (used) — verified present. `@lune/fs` is **not**
used by the runner (only by B2 tooling). The explicit-list form removes the prior `fs.readDir`
TODO(verify) entirely: there is no cwd dependency to verify because there is no cwd-relative call.

---

## 8. The SAMPLE feature (end-to-end LOGIC proof; real-wire verified at Tier-2) [SAMPLE]

A deliberately tiny, clearly-marked, **deletable** feature that exercises every spine seam: the
service framework, a Net action with a validator + rate policy, and a data read/write — with a
passing Tier-1 test. `build-game` removes `services/sample/`, `controllers/sample/`, the sample line
in each bootstrap, and `sample.spec.luau` as real features replace it — `new-game` keeps it so a fresh
fork is gauntlet-green from the first commit.

**Behavior:** action `"sample.ping"`. Payload `{ amount: number }` (1..100). The handler validates,
then `DataService:update` increments `currencies.Stardust` by `amount` (concurrency-safe), and
returns `Result.ok({ balance = newBalance })`.

**Structure (so the spec can require the action without crashing under Lune — D1).** The action
*definition* lives in a **Lune-clean** module `SampleAction.luau` (relative requires only, no Roblox
global); the thin `SampleService.luau` only *registers* it (and is Lune-clean too — it touches no
Roblox global; `register` is called via `context.net`, never a sibling require). The spec requires
`SampleAction` directly and drives it through `Mocks.net` (which calls the real `Net.dispatch`).

```lua
--!strict
-- core/src/server/services/sample/SampleAction.luau   [SAMPLE — Lune-clean: relative requires only]
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- The action is plain data + pure functions => spec-requirable under Lune, no Roblox global.
local SampleAction: Net.Action<{ amount: number }, { balance: number }> = {
	name = Net.Actions.Sample, -- "sample.ping"
	rate = { maxPerWindow = 5, windowSeconds = 1 },
	validate = function(raw)
		if typeof(raw) ~= "table" then return Result.err("BadPayload") end
		local amount = (raw :: any).amount
		if type(amount) ~= "number" then return Result.err("BadType") end
		if amount < 1 or amount > 100 or amount % 1 ~= 0 then return Result.err("OutOfRange") end
		return Result.ok({ amount = amount })
	end,
	handler = function(ctx, payload)
		-- SYNCHRONOUS transform under the lock (§3.3 rule); no client-controllable yield inside.
		local updated = ctx.data:update(ctx.player, function(d)
			d.currencies.Stardust = (d.currencies.Stardust or 0) + payload.amount
			return d
		end)
		if not updated.ok then return updated end
		return Result.ok({ balance = updated.value.currencies.Stardust })
	end,
}
return SampleAction
```

```lua
--!strict
-- core/src/server/services/sample/SampleService.luau   [SAMPLE — deletable; Lune-clean]
local SampleAction = require("./SampleAction")
local SampleService = { name = "SampleService" }
function SampleService:Start(context)
	context.net:register(SampleAction) -- registration only; the action is the pure module above
end
return SampleService
```

`typeof`/`type` both exist under Lune (verified), so the validator is genuinely Tier-1 testable.

The matching `SampleController.luau` (**Roblox-only**: uses `script`/`game` via the client bootstrap)
calls `context.net:call("sample.ping", { amount = 10 })` once on start and logs the `Result`; no spec
requires it. The matching `sample.spec.luau` requires `SampleAction` + drives the **full inbound
pipeline** via `Mocks.net` (→ real `Net.dispatch`) + `Mocks.store` + `Mocks.clock`: asserts a valid
call increments the balance exactly once, a bad type returns `Err("BadType")`, out-of-range returns
`Err("OutOfRange")`, and **two interleaved calls against a yielding store land the balance at exactly
the sum** (concurrency-safety proof, §9.3). Because `Mocks.net` runs the *production* `Net.dispatch`,
this spec covers the real dispatch logic (lookup→rate→validate→pcall(handler)), not a re-implementation
(concern 19). That passing spec is the **end-to-end LOGIC proof**; the real-wire dispatch
(RemoteFunction → NetServer → `Net.dispatch`) is verified at Tier-2, and `rojo build` proves the
Roblox-only bootstraps/NetServer/NetClient compile (§9, §12 DoD).

---

## 9. How the gauntlet stays green (Tier-1 under Lune)

1. **stylua** — `stylua.toml` (§11) governs `core/src` + `core/tests`. Every file is pre-formatted.
2. **selene** — `core/selene.toml` with `std = "roblox-fenced"` (the custom overlay, §11.5). The
   overlay marks `wait`/`spawn`/`delay` as `removed`, so a file calling them is a **selene error
   (nonzero exit)** — verified on selene 0.31.0 (stock `std = "roblox"` does NOT flag them). The spine
   uses only `task.*`. A Tier-1 self-test (§9.4) asserts the overlay actually rejects a `wait()`
   sample so this enforcement cannot silently regress; the PreToolUse guard hook is the edit-time
   backstop (D2).
3. **rojo build** — `core/default.project.json` maps the four roots (Packages node **omitted** — D3);
   `init.server.luau`/`init.client.luau` make `Server`/`Client` runnable; the tree compiles to
   `build.rbxl`. This is the only gate that proves the Roblox-only modules
   (`NetServer`/`NetClient`/`Context`/bootstraps) compile.
4. **lune** — `lune run core/tests/run.luau` (explicit spec list, relative requires, cwd-independent)
   requires the testkit + Lune-clean modules (no DataModel), runs the specs, prints **one JSON line**
   (on success AND on any failure — §7.4), exits nonzero on any failure.

### 9.1 The non-negotiable Lune boundary (the require partition — D1)

`tests/run.luau`, `tests/lib/*`, `tests/unit/*`, and **every module a spec requires** must not touch
a Roblox global at module scope, and must use **`require("./Sibling")` relative requires only**
(verified: `require("./x")` is script-relative and resolves from any cwd; `script` is `nil` under
Lune so `require(script.Parent.x)` would crash a spec instantly). Concretely the spine keeps these
**Lune-clean** (relative requires, no Roblox global): `Result`, `Types` (incl. `toView`), `Net`
(registry + types + `dispatch`), `Config`, `Migrations`, `framework/Bootstrap`, `framework/Service`/
`Controller`, `security/Gate`, `data/Store` (types), `data/MockStore`, `data/Clock`, `data/DataService`
(it takes `store`/`clock`/`config` injected — it only *connects* Roblox events inside `Start`, which
tests don't call; tests call `get`/`update`/`save` directly with a `Mocks.player`), plus the sample's
`SampleAction`/`SampleService`. **Roblox-only** (use `script`/`game`; **never required by any spec**):
`NetServer`, `NetClient`, both `Context.luau`, both bootstraps, `SampleController`. A spec that
required a Roblox-only module would crash under Lune; the runner's per-spec `pcall` (§7.4) records that
as a failure rather than a silent hang — but the rule is **no spec requires a Roblox-only module**.
The sample spec drives logic through `Mocks.net` (→ real `Net.dispatch`), never `NetServer`.

### 9.2 Determinism

The runner's `specs` list is `table.sort`ed (concern 10); the fake clock is the only time source in
tests; `Mocks.store` is deterministic; no `math.random` without a seed. The JSON line is byte-stable
for a given suite.

### 9.3 Race / concurrency proof (single-server, simulated — the headline deliverable, concern 4)

`Mocks.store({ yieldOnUpdate = true })` makes the **per-key lock queue** of §4.1 exercise: `update`'s
critical section yields once, so a second same-key `update` arriving during that yield is forced to
**park in the FIFO and re-read** after the first writes. A spec fires two `sample.ping` calls without
awaiting the first, resumes both, and asserts the final `Stardust` equals the **exact sum**.

**Why this test is falsifiable (not unfalsifiable or trivially-green):** it is constructed so that the
*broken* implementation (naive read→yield→write with **no** queue/park/re-read) lands at the **wrong**
value (the second write clobbers the first), which the assertion rejects — reproduced on the pinned
Lune: naive lands at **3**, the lock-queue lands at **8** for `+5`/`+3` from 0. So a green race test
*distinguishes* a correct queue from a no-op, and the store is genuinely yielding (not made
non-yielding to cheat). This is the Tier-1 reproduction of the spam-click double-spend class, per
`docs/TESTING.md` §7.

### 9.4 selene-enforcement self-test (`tests/unit/selene_guard.spec.luau`) [SPINE]

A Tier-1 spec that guards the §0.1-D2 enforcement so it can't silently regress: it asserts that the
shipped `core/roblox-fenced.yml` overlay marks `wait`/`spawn`/`delay` as `removed` (parses the YAML)
**and** — where the runner can shell out — that running selene with the overlay against a
`wait(1)`/`spawn(...)`/`delay(...)` fixture yields a nonzero exit, while a `task.*` fixture is clean.
(If shelling out from Lune is impractical, the spec asserts the overlay's structural contract and the
gauntlet's own selene step + the PreToolUse guard provide the live enforcement; documented in the
spec header.) `-- TODO(verify):` Lune's `@lune/process.spawn` for the optional shell-out leg.

### 9.5 BindToClose budget / data-loss-risk test (in `data.spec.luau`) [SPINE]

Asserts (concern 6) that `DataService:Stop` against a `Mocks.store({ throttleSaves = N })`
**retries per budget** (not fire-once) and that a save which exhausts `maxRetries` surfaces an `Err`
(logged data-loss-risk) rather than being silently swallowed. Also asserts the load-retry loop treats
`Err("SessionLocked")` as retryable (distinct from `Internal`) — the contention seam (concern 5).

---

## 10. Authoring rules every `core/` file obeys (checklist)

- `--!strict` first line. `task.*` only. No `wait/spawn/delay` (enforced by the selene overlay §11.5
  **and** the PreToolUse guard — selene's stock roblox std does NOT catch these).
- Lune-clean modules use **`require("./Sibling")`** relative requires; Roblox-only modules use
  `require(script.Parent.X)`. No spec ever requires a Roblox-only module (D1).
- Server handlers validate **type + range + ownership + rate**: type+range via the action `validate`,
  **rate + ownership via the spine `Gate` now** (§3.6) and the full B2 security later — both via the
  same `Net.dispatch` seam. (Spine is rate-limited; full anti-exploit is a B2 completion — §6.)
- All economy mutations go through `DataService:update` (→ `Session:update` per-key lock queue) —
  never a raw field write — so interleaved/spam requests cannot double-spend. The transform is
  **synchronous** (no client-controllable yield inside it; never hold a lock across such a yield).
- `ProcessReceipt` (B2) does its check+grant+stamp in **one** `update` transform and returns
  `PurchaseGranted` only after a confirmed save (else `NotProcessedYet`) — never two updates (§6).
- Time comes from `context.clock` (server). Never read a timestamp from a client payload. `unix()`
  may be persisted; `mono()` is process-local and **never persisted** (§5).
- All persistent reads/writes go through `DataService`; structural changes ship a `Migrations` step.
  Anything pushed to the client goes through `Types.toView` (never a raw `PlayerData`).
- No exception crosses the Net boundary: `Net.dispatch` `pcall`-wraps every handler → `Err("Internal")`.
- User-displayed text is filtered (`TextService:FilterStringAsync`) `-- TODO(verify):` before display
  (no user text in the spine sample, so this is a documented rule, enforced when a feature adds it).
- No fabricated APIs: anything unverified is marked `-- TODO(verify):` (the spine flags
  `RemoteFunction.OnServerInvoke` threading, `PlayerScripts` replication, `BindToClose` budget,
  `game.JobId` as lock id, and Lune's `@lune/process`
  surface). The `mono()` clock no longer depends on `os.clock()` semantics: production injects the
  monotonic Roblox `time` global (seconds since server start) as `monoSource` from `Context.build`,
  so the prior `os.clock()` CPU-time risk is removed (Clock.luau stays Lune-clean — §5).
  **Verified on the pinned toolchain (not TODO):** Lune `script==nil` + relative-require
  resolution, `fs.readDir` cwd-relativity, selene overlay rejecting `wait/spawn/delay`, rojo Packages
  omission + path-object optional form, and the lock-queue vs lost-update race outcome.

---

## 11. Project config (the SPINE config files)

### 11.1 `core/default.project.json` (Rojo v7) — Packages node OMITTED (D3, verified)

Maps the four roots exactly as `ARCHITECTURE.md` requires. The spine ships **no `Packages/` folder**,
so the `Packages` node is **omitted** — this is the **primary, verified-green** config on rojo 7.6.1
(builds clean). The previous draft's `{ "$path": "Packages", "$optional": true }` is **invalid in
7.6.1** ("Failed to deserialize JSON" — verified, build red) and is removed.

```json
{
  "name": "core",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Shared": { "$path": "src/shared" }
    },
    "ServerScriptService": { "Server": { "$path": "src/server" } },
    "StarterPlayer": {
      "StarterPlayerScripts": { "Client": { "$path": "src/client" } }
    }
  }
}
```

**When wally packages first exist (B2 / per-game):** add the `Packages` node using the
**verified-working optional path-object** form (builds green with the folder absent on 7.6.1):

```json
"Packages": { "$path": { "optional": "Packages" } }
```

(Not `"$optional": true` as a sibling of `$path` — that is the broken form.) Until a package is
actually added, the node stays omitted.

### 11.2 `core/wally.toml`

Declares the project for the FUTURE; **lists no dependency** the spine requires (Tier-1 uses mocks,
the framework is original). Realm `shared`. Documented as "deps are added per game when a feature
genuinely needs one; the foundation itself is dependency-free."

### 11.3 `core/.luaurc`

```json
{ "languageMode": "strict", "aliases": { "shared": "src/shared", "server": "src/server", "client": "src/client" } }
```

`-- TODO(verify):` `.luaurc` alias support in luau-lsp 1.68.0 (LSP-only; Rojo resolves requires via
the tree, not aliases — so aliases are a dev-ergonomics nicety, not a build dependency).

### 11.4 `core/stylua.toml`

Standard config (column width, indent = tabs to match Roblox conventions) applied to `core/src` and
`core/tests`. Chosen so `stylua --check core/src core/tests` is green on every authored file.

### 11.5 `core/selene.toml` + the custom std overlay (D2, verified)

**Verified false claim corrected:** selene 0.31.0 with stock `std = "roblox"` reports **0 errors** for
a file calling `wait(1)`/`spawn(...)`/`delay(...)` (it IS loading the roblox std — it correctly flags
undefined globals — but those three are *defined* and not deprecated in the bundled std). So stock
selene gives the §10 `task.*` rule **no automated enforcement**. The spine fixes this with a **custom
std overlay** that the gauntlet's selene step actually fails on.

`core/selene.toml`:
```toml
std = "roblox-fenced"
```

`core/roblox-fenced.yml` (the overlay — **filename must equal the std name** `roblox-fenced` and sit
**next to `selene.toml`**, both verified; `base: roblox`, ban the three globals):
```yaml
base: roblox
name: roblox-fenced
globals:
  wait: { removed: true }
  spawn: { removed: true }
  delay: { removed: true }
```

selene resolves `std = "roblox-fenced"` against `core/roblox-fenced.yml` (same directory as the config).
**Verified
on 0.31.0:** a file calling `wait(1)`/`spawn(...)`/`delay(...)` then produces selene **errors** and a
**nonzero exit** (each flagged "`wait` was found in the roblox standard library"), while
`task.wait`/`task.spawn`/`task.delay` lint clean (exit 0). The §9.4 self-test asserts this so it can't
regress. The PreToolUse guard hook (regex-deny bare `wait(`/`spawn(`/`delay(`) is the independent
edit-time backstop. `-- TODO(verify):` exact overlay file path resolution if a future selene version
changes std-lookup — re-run §9.4 after any selene bump. Lune-only test files use no Roblox globals, so
they lint clean under the overlay too.

`ARCHITECTURE.md` (Safety hooks) and `docs/TESTING.md` §2 still say "selene ... bans `wait()/spawn()`":
that prose now means **"selene with the spine's roblox-fenced overlay"**, not stock selene — those two
docs should be read with this section as the authoritative mechanism. (FACTORY.md §10 states the
*rule*; this section states *how it is enforced*.)

---

## 12. What this phase delivers vs. defers (the SPINE boundary, restated)

**Build now (SPINE + SAMPLE):**
- Config: `default.project.json` (Packages node omitted), `wally.toml`, `.luaurc`, `stylua.toml`,
  `selene.toml` + `roblox-fenced.yml` (the banned-API overlay; same dir, filename == std name).
- Service framework: `framework/Service.luau` + `framework/Controller.luau` + `framework/Bootstrap.luau`
  (both sides), `Context.luau` (both sides, **constructs** net/data/clock/config), and both bootstraps.
- Shared contracts: `Types.luau` (+ `PlayerView`/`toView`), `Net.luau` (+ `dispatch`), `Config.luau`,
  `Result.luau`, `Migrations.luau`, `shared/init.luau`.
- Data: `Store.luau` (interface + lock-queue contract), `MockStore.luau` (lock-queue + throttle/fail),
  `Clock.luau`, `DataService.luau`, `data/init.luau`.
- Security seed: `security/Gate.luau` (minimal token-bucket rate + ownership assert — Lune-clean).
- Net runtime: `NetServer.luau`, `NetClient.luau` (Roblox-only; both call the shared `Net.dispatch`).
- Test harness: `tests/run.luau` (explicit list, pcall-guarded), `tests/lib/{testkit,assert,mocks}.luau`,
  and specs `framework.spec`, `net.spec`, `data.spec`, `selene_guard.spec`, plus the sample's `sample.spec`.
- One sample feature: `SampleAction.luau` (Lune-clean def) + `SampleService.luau` + `SampleController.luau`.

**Defer to B2 (contracts present, no implementation):**
- `data/SessionStore.luau` (real session-locked DataStore behind the unchanged `Store` interface;
  uses the reserved `SessionLocked`/`LockStolen` codes + budget-aware BindToClose).
- `security/` full suite: `RateLimiter` (supersedes `Gate`), `Validator`, `ViolationTracker`, `Panic`.
- `liveops/FeatureFlags.luau`.
- `analytics/Analytics.luau` (sink + taxonomy).
- `monetization/Receipts.luau` + `Products.luau` (idempotent `ProcessReceipt` — one-transform atomicity §6).
- `tests/scenarios/`, `tests/engine/`, `lune/` Tier-2/publish scripts, `CLAUDE.md`.

The spine proves the wiring (LOGIC end-to-end via `Net.dispatch`; real-wire at Tier-2) and is itself
rate-limited/ownership-checked; B2 fills the seams without touching a spine signature.

---

## 13. Concern → resolution traceability (this revision)

| # | Sev | Concern | Resolution in this doc |
|---|---|---|---|
| 1 | HIGH | dual-runtime require contradiction | §0.1-D1: Lune-clean modules use a `script==nil` require-shim (or dep injection); Roblox-only use `script.Parent`; no spec requires a Roblox-only module; every sketch fixed (verified shim runs under Lune + lints clean) |
| 2/13 | HIGH | selene doesn't ban wait/spawn/delay | §0.1-D2, §11.5: custom `roblox-fenced` overlay (verified to error); §9.4 self-test; guard-hook backstop; prose corrected |
| 3/14 | HIGH | rojo `$optional` invalid | §0.1-D3, §11.1: Packages node **omitted** (verified green); path-object form documented for B2 |
| 4 | HIGH | economy race lock mechanism implicit | §4.1: explicit per-key FIFO lock-queue contract; §9.3: falsifiable test (naive→3, queue→8, verified) |
| 5 | MED | session-lock contention seam | §3.1 reserves `SessionLocked`/`LockStolen`; §4.1 `load` may return them; §4.4 retry loop handles `SessionLocked`; §4.3 steal flow |
| 6 | MED | BindToClose vs DataStore budget | §4.3/§4.4: budget-aware staggered flush, retry-per-budget, data-loss-risk logged; §9.5 Tier-1 test via `throttleSaves` |
| 7 | MED | spine actions unprotected (rate/ownership) | §3.6 `Gate` ships rate+ownership in the SPINE; §6 publish-safety note; register-warns-if-no-B2 |
| 8 | MED | ProcessReceipt atomicity | §6: one-`update`-transform invariant (check+grant+stamp); `PurchaseGranted` only after confirmed save |
| 9 | LOW | mono vs unix persistence rule | §5: `mono()` never persisted; `unix()` only persisted value; `mono()` source injected (Roblox `time` global in prod, `os.clock` under Lune) — no more `os.clock` CPU-time risk |
| 10 | LOW | runner determinism + failure isolation | §7.4: `table.sort` + per-spec `pcall` → one JSON line on success AND failure |
| 11 | LOW | lock held across client yield | §3.3 authoring rule: synchronous transforms, never hold lock across client-controllable yield |
| 12 | HIGH | runner cwd-fragile (fs.readDir) | §0.1-D4, §7.4: explicit relative-require `specs` list, no `fs.readDir` (verified cwd-independent) |
| 15 | MED | ActionContext vs ServerContext | §3.3: `ActionContext` is a typed subset closing over `ServerContext`; same optional B2 fields; no `any` |
| 16 | MED | bootstrap construct-vs-start | §2.2/§2.4: Context.build CONSTRUCTS; Start does I/O only; same-reference invariant; framework.spec asserts non-nil deps |
| 17 | MED | client-safe view untyped | §3.2: `PlayerView` type + pure `Types.toView`; §4.5 push through it; `data.spec` asserts no `receipts`/`analytics` leak |
| 18 | LOW | RemoteFunction exceptions across wire | §3.3 wire note: single OnServerInvoke `pcall`-wraps → `Err("Internal")`; bounded yield; RemoteEvent+id escape hatch |
| 19 | LOW | sample not exercised through real wire | §3.3/§7.3/§8: one pure `Net.dispatch` used by BOTH NetServer and `Mocks.net`; DoD reworded "LOGIC proof; real-wire at Tier-2" |
