# CORE-STRUCTURE.md — the `core/` spine, in pictures

The **visual** companion to `docs/CORE-DESIGN.md`. That file owns the *rationale* (every module's
contract, why the shape is what it is). This file owns the *map*: the file tree, the Rojo → Roblox
mapping, the dependency-injection graph, and the three runtime flows (net, data, boot) drawn as
diagrams faithful to the committed spine.

> **View this on GitHub** (or any Mermaid-aware viewer) to see the diagrams rendered — the diagrams
> carry the load here, the prose is deliberately thin.

**Cross-links:** `ARCHITECTURE.md` owns the *planned* repo layout and verification tiers ·
`docs/CORE-DESIGN.md` owns the *textual* design rationale and the per-module API contract ·
`docs/TESTING.md` owns *how we test*.

Status legend (same as CORE-DESIGN.md): **[SPINE]** built now · **[B2]** deferred, contract
accounted for · **[SAMPLE]** deletable per game (proves the wiring).

---

## 1. The annotated file tree

`tests/` and `lune/` are Lune tooling and are **not** mounted into the Roblox DataModel by
`default.project.json` — only `src/{shared,server,client}` are.

```
core/
|-- default.project.json      # Rojo: maps src/{shared,server,client} into the DataModel
|-- .luaurc                   # strict Luau + path aliases (shared/server/client)
|-- selene.toml               # lint config: std = roblox-fenced
|-- roblox-fenced.yml         # selene std overlay: wait/spawn/delay marked removed
|-- stylua.toml               # formatter: Luau, tabs, 100-col, prefer-double quotes
|-- wally.toml                # package factory/core 0.1.0; deliberately zero deps
|-- lune/.gitkeep             # placeholder dir (Lune build/tooling scripts)
|
|-- src/
|   |-- shared/               # -> ReplicatedStorage.Shared (server+client contracts)
|   |   |-- init.luau         # barrel: re-exports Result/Types/Net/Config/Migrations
|   |   |-- Result.luau       # Ok/Err Result type + stable Result.Codes (leaf)
|   |   |-- Types.luau        # PlayerData + PlayerView + pure toView allowlist (leaf)
|   |   |-- Net.luau          # action Registry + the ONE pure Net.dispatch pipeline
|   |   |-- Config.luau       # static tunables + clientSubset projection (leaf)
|   |   `-- Migrations.luau   # default() + migrate() pure steps (requires ./Types)
|   |
|   |-- server/              # -> ServerScriptService.Server (init.server -> Script)
|   |   |-- init.server.luau  # THE server bootstrap; only place knowing service order
|   |   |-- Context.luau      # Context.build news up clock/config/data/net/gate
|   |   |-- framework/
|   |   |   |-- Service.luau   # Service type + define() identity helper (leaf)
|   |   |   `-- Bootstrap.luau # pure start(order)/stop(reverse) sequencer
|   |   |-- net/
|   |   |   `-- NetServer.luau # binds CoreGateway RF + CoreEvents RE; register/dispatch
|   |   |-- security/
|   |   |   `-- Gate.luau      # token-bucket check() + assertOwner() (injected clock)
|   |   |-- data/
|   |   |   |-- init.luau       # data barrel (Store/MockStore/Clock/DataService)
|   |   |   |-- Store.luau      # low-level Store + Session INTERFACE types
|   |   |   |-- MockStore.luau  # in-memory Store impl + FIFO lock queue (runtime default)
|   |   |   |-- Clock.luau      # Clock.real/.fake; unix (persist) vs mono (rate)
|   |   |   `-- DataService.luau# per-player session lifecycle: get/update/save + Start/Stop
|   |   `-- services/
|   |       `-- sample/         # [SAMPLE] deletable per new-game
|   |           |-- SampleService.luau # Start() registers the sample action
|   |           `-- SampleAction.luau  # sample.ping action: validate + handler
|   |
|   `-- client/              # -> StarterPlayer.StarterPlayerScripts.Client (init.client -> LocalScript)
|       |-- init.client.luau  # THE client bootstrap; controller order
|       |-- Context.luau      # builds NetClient + client-safe config subset
|       |-- framework/
|       |   |-- Controller.luau# Controller type + define() helper (client mirror of Service)
|       |   `-- Bootstrap.luau # duplicate of server Bootstrap (no cross-tree require)
|       |-- net/
|       |   `-- NetClient.luau # call() over CoreGateway RF, on() over CoreEvents RE
|       `-- controllers/
|           `-- sample/        # [SAMPLE] deletable
|               `-- SampleController.luau # fires sample.ping once; subscribes to data view
|
`-- tests/                    # Lune Tier-1 suite (not mounted into the DataModel)
    |-- run.luau              # runner: explicit sorted SPEC_PATHS; one JSON line out
    |-- lib/
    |   |-- assert.luau        # pure assertion primitives
    |   |-- testkit.luau       # describe/it/expect + JSON reporter
    |   `-- mocks.luau         # Tier-1 fakes requiring the REAL source modules
    `-- unit/
        |-- clock.spec.luau
        |-- data.spec.luau
        |-- economy_race.spec.luau
        |-- framework.spec.luau
        |-- migration.spec.luau
        |-- net.spec.luau
        |-- sample.spec.luau
        |-- validation.spec.luau
        `-- selene_guard.spec.luau
```

---

## 2. Rojo → Roblox: filesystem roots and the suffix convention

`default.project.json` mounts **exactly three** filesystem roots into the DataModel via `$path`.
There is no `Packages` node until wally introduces a first dependency.

```mermaid
flowchart TD
  subgraph FS["Filesystem (core/)"]
    A["src/shared"]
    B["src/server"]
    C["src/client"]
  end
  subgraph DM["Roblox DataModel"]
    RS["ReplicatedStorage.Shared"]
    SS["ServerScriptService.Server"]
    SP["StarterPlayer.StarterPlayerScripts.Client"]
  end
  A -->|"$path"| RS
  B -->|"$path"| SS
  C -->|"$path"| SP
```

The Rojo file-suffix rules, as actually used in this tree: `init.server.luau` makes its folder a
server `Script`; `init.client.luau` makes its folder a `LocalScript`; an `init.luau` makes its
**folder** a `ModuleScript` with siblings as children; any other `*.luau` is a plain `ModuleScript`.

```mermaid
flowchart TD
  F1["init.server.luau (src/server)"] -->|"folder becomes"| I1["Server: server Script"]
  F2["init.client.luau (src/client)"] -->|"folder becomes"| I2["Client: LocalScript"]
  F3["init.luau (shared, data)"] -->|"folder becomes"| I3["folder-as-ModuleScript"]
  F4["plain Name.luau"] -->|"becomes"| I4["ModuleScript named Name"]
  F5["nested folder (framework, net, data, ...)"] -->|"becomes"| I5["Folder with child instances"]
```

---

## 3. Module layering & dependency injection

Require edges only ever point **downward** into the shared leaves; siblings never require each other.
The single composition root `Context.build` is the **only** module that requires the concrete
`data`/`net`/`gate` implementations — so collaborators are constructed once and passed by argument,
and no load-order cycle is possible.

**Lune-clean vs Roblox-only:** every shared module plus all of `data/*`, `security/Gate`,
`framework/*`, and `services/sample/*` are *Lune-clean* — they touch no Roblox global, so a Tier-1
spec can require and exercise them directly. Only `Context.luau`, `net/NetServer.luau`,
`init.server.luau` (and the barrel `init.luau` files, which run only at Roblox runtime) are
*Roblox-only* — they use `game`/`script`/`Instance` and are never required by a spec.

```mermaid
flowchart TD
  subgraph SHARED["shared leaves — Lune-clean"]
    R["Result"]
    T["Types"]
    C["Config"]
    M["Migrations"]
    N["Net + Net.dispatch"]
  end
  subgraph DATA["data + security — Lune-clean"]
    CK["Clock"]
    ST["Store"]
    MS["MockStore"]
    DS["DataService"]
    G["Gate"]
  end
  subgraph FW["framework — Lune-clean"]
    SVC["Service"]
    BS["Bootstrap"]
    SAMP["SampleService + SampleAction"]
  end
  subgraph ROBLOX["Roblox-only"]
    NS["NetServer"]
    CTX["Context.build"]
    BOOT["init.server.luau"]
  end
  M --> T
  N --> R
  ST --> R
  MS --> R
  G --> R
  DS --> M
  DS --> T
  DS --> R
  SAMP --> N
  SAMP --> R
  NS --> N
  NS --> R
  CTX --> C
  CTX --> CK
  CTX --> MS
  CTX --> DS
  CTX --> G
  CTX --> NS
  BOOT --> CTX
  BOOT --> BS
  BOOT --> SAMP
```

Construct-then-inject order inside `Context.build`: every collaborator is built once and handed to
the next by argument (clock into store/data/gate, store/clock/config into data, gate into net). The
deps are the **same** object references later placed in the context table and Started in order.

```mermaid
sequenceDiagram
  participant Boot as "init.server.luau"
  participant Ctx as "Context.build"
  participant Clock as "Clock.real(time)"
  participant Store as "MockStore.new"
  participant Data as "DataService.new"
  participant Gate as "Gate.new"
  participant Net as "NetServer.new"
  Boot->>Ctx: build()
  Ctx->>Clock: real(time global)
  Ctx->>Store: new({clock, config})
  Ctx->>Data: new(store, clock, config)
  Ctx->>Gate: new(clock)
  Ctx->>Net: new(gate)
  Ctx->>Ctx: assemble context table
  Ctx->>Net: bindContext(context)
  Ctx-->>Boot: context
  Boot->>Boot: Bootstrap.start({net, data, SampleService}, context)
```

Handlers receive collaborators through the narrow `ActionContext` that `NetServer` closes over from
the full context; services register via `context.net` and read deps via `ctx` — so feature code
never requires `NetServer`, `Gate`, or `DataService` directly.

```mermaid
flowchart TD
  CTX["Context.build context"] -->|"net:bindContext(context)"| NS["NetServer"]
  NS -->|"builds narrow projection"| AC["ActionContext: player, clock, data"]
  NS -->|"registry + gate + ctx"| DISP["Net.dispatch"]
  DISP -->|"gate:check rate"| G["Gate"]
  DISP -->|"action.validate then pcall handler"| H["Handler reads ctx.data / ctx.clock"]
  SS["SampleService:Start"] -->|"context.net:register"| NS
```

---

## 4. The Net request lifecycle (server authority)

The entire wire surface is **one** `RemoteFunction` (`CoreGateway`) plus one `RemoteEvent`
(`CoreEvents`), both parented to `ReplicatedStorage`. Every inbound client action funnels through the
single RemoteFunction into `Net.dispatch`, the one pure pipeline shared by the real wire and the test
mocks so they cannot diverge.

```mermaid
sequenceDiagram
    participant Client
    participant RF as "RemoteFunction CoreGateway"
    participant NS as NetServer
    participant D as "Net.dispatch"
    participant Reg as Registry
    participant G as Gate
    participant A as "Action (SampleAction)"
    participant Data as "ctx.data (DataService)"

    Client->>RF: invoke(actionName, rawPayload)
    RF->>NS: OnServerInvoke(player, actionName, rawPayload)
    NS->>NS: ctx = actionContext(player)
    NS->>D: pcall(dispatch, registry, gate, ctx, actionName, rawPayload)

    Note over D: step 2 lookup
    D->>Reg: get(actionName)
    alt not string or unknown
        D-->>NS: Err UnknownAction
    end

    Note over D: step 3 panic check
    alt ctx.security set and isPanicked
        D-->>NS: Err Rejected
    end

    Note over D: step 4 rate (if gate)
    D->>G: check(UserId, actionName, action.rate)
    alt no tokens or degenerate
        G-->>D: Err RateLimited
        D-->>NS: Err RateLimited
    else allowed
        G-->>D: Ok true
    end

    Note over D: step 5 ownership (if ownerOf)
    opt action.ownerOf present and gate set
        D->>G: assertOwner(UserId, ownerUserId)
        alt mismatch
            G-->>D: Err NotOwner
            D-->>NS: Err NotOwner
        end
    end

    Note over D: step 6 validate
    D->>A: validate(rawPayload)
    alt invalid
        A-->>D: Err BadPayload or BadType or OutOfRange
        D-->>NS: same Err
    else valid
        A-->>D: Ok value
    end

    Note over D: step 7 pcall(handler)
    D->>A: handler(ctx, value)
    A->>Data: update(player, transform)
    Data-->>A: Ok newData or Err
    A-->>D: Ok balance or Err
    alt handler threw
        D-->>NS: Err Internal
    else returned
        D-->>NS: handler Result
    end

    NS-->>RF: Result (Ok or Err)
    RF-->>Client: Result
```

Each guard short-circuits to a specific `Result.Code` in code order; only after lookup, panic, rate,
ownership, and validate all pass does step 7 `pcall` the handler. A double `pcall` (outer in
`NetServer`, inner in dispatch step 7) means **no** thrown error ever crosses the wire — it becomes
`Err Internal`. The rate policy and ownership predicate come from the registered Action, never the
client payload.

```mermaid
flowchart TD
    W["NetServer OnServerInvoke"] --> P["pcall Net.dispatch"]
    P --> S2{"step 2: string and registered?"}
    S2 -- no --> EUA["Err UnknownAction"]
    S2 -- yes --> S3{"step 3: security set and panicked?"}
    S3 -- yes --> EREJ["Err Rejected"]
    S3 -- no/nil --> S4{"step 4: gate.check passes?"}
    S4 -- no --> ERL["Err RateLimited"]
    S4 -- yes/no gate --> S5{"step 5: ownerOf set and gate present and owner matches?"}
    S5 -- mismatch --> ENO["Err NotOwner"]
    S5 -- ok/skip --> S6{"step 6: validate ok?"}
    S6 -- no --> EVAL["Err BadPayload / BadType / OutOfRange"]
    S6 -- yes --> S7["step 7: pcall handler"]
    S7 --> HU["handler: data.update transform"]
    HU -- throw --> EINT["Err Internal"]
    HU -- update Err --> EUP["return data Err"]
    HU -- ok --> OKR["Ok balance"]
    P -. dispatch itself throws .-> EINT2["NetServer returns Err Internal"]
```

---

## 5. The data layer

`DataService.update(player, transform)` is **the** canonical write path; it delegates to the Store
session, which enforces a per-key FIFO lock queue. A second same-key update **parks and yields
without reading**, so it only re-reads the fresh post-write snapshot *after* the lock is handed to
it — which is exactly what makes `0+5` then `5+3 = 8` exact, never a lost update. (`MockStore`'s
`deepCopy`-on-read is what makes the race real and the falsifiability test pass.)

```mermaid
sequenceDiagram
    participant UA as "update A (+5)"
    participant UB as "update B (+3)"
    participant Q as "per-key FIFO queue"
    participant B as "backing[key] = 0"
    Note over UA,B: DataService.update delegates to session:update on one key
    UA->>Q: "acquire(key)"
    Note right of Q: "not held -> held=true, return"
    UA->>B: "re-read fresh snapshot = 0"
    UB->>Q: "acquire(key)"
    Note right of Q: "held -> insert(queue, B) then yield"
    Note over UB: "B parked, no read yet"
    Note over UA: "yieldOnUpdate yields inside critical section"
    UA->>B: "transform: write 0+5 = 5"
    UA->>Q: "release(key)"
    Q-->>UB: "resume next waiter (lock still held)"
    UB->>B: "re-read fresh snapshot = 5"
    UB->>B: "transform: write 5+3 = 8"
    UB->>Q: "release(key)"
    Note right of Q: "queue empty -> held=false"
    Note over B: "final = 8 exactly once (each +amount applied to latest)"
```

`save()` can fail via `failSave`, the `throttleSaves` counter, or the `writeMinIntervalSeconds` floor
(measured on `clock:mono`). `saveSession` retries up to `maxRetries`, advancing the **injected** clock
between attempts so the throttle floor clears without yielding; on budget exhaustion it **surfaces**
the `Err` with a data-loss-risk warn rather than swallowing it. `Stop` (BindToClose) releases the
lock regardless so a restart can re-acquire.

```mermaid
flowchart TD
    Stop["DataService.Stop (BindToClose)"] --> Loop["for each live session"]
    Loop --> Ts["set lastSeenUnix = clock:unix"]
    Ts --> SS["saveSession(session)"]
    SaveAPI["DataService.save(player)"] --> SS
    SS --> A["attempt = 0"]
    A --> Call["session:save()"]
    Call --> Thr{"throttle? failSave / throttleSaves / writeMinInterval"}
    Thr -->|"ok"| OK["Result.ok -> return saved"]
    Thr -->|"Err Internal"| Budget{"attempt > maxRetries?"}
    Budget -->|"yes"| Warn["logWarn data-loss-risk, return Err (surfaced)"]
    Budget -->|"no"| Back["attempt += 1, backoff(clock, retryBaseSeconds * attempt)"]
    Back --> Adv["fake clock: clock:advance clears writeMinInterval floor; runtime: task.wait"]
    Adv --> Call
    OK --> Rel["Stop only: session:release() then clear slot"]
    Warn --> Rel
    Wmi["writeMinInterval floor uses clock:mono"] -.-> Thr
```

---

## 6. Bootstrap order & the test harness

Two-phase deterministic boot: `Context.build` constructs every field (no I/O) and wires `net` via
`bindContext`, then `Bootstrap.start` runs `Start` in the **fixed** order `net → data →
SampleService`. `BindToClose` drives `Bootstrap.stop` in **reverse** so `DataService.Stop` flushes
every session; a failing `Start` raises loudly, a failing `Stop` only warns.

```mermaid
flowchart TD
  A["init.server.luau (Roblox Script)"] --> B["WaitForChild Server under SSS"]
  B --> C["Context.build (CONSTRUCT phase)"]
  subgraph CONSTRUCT ["Context.build — all fields non-nil at t0, no I/O"]
    direction TB
    C1["clock = Clock.real(time)"] --> C2["config = Shared.Config"]
    C2 --> C3["store = MockStore.new"]
    C3 --> C4["data = DataService.new(store,clock,config)"]
    C4 --> C5["gate = Gate.new(clock)"]
    C5 --> C6["net = NetServer.new(gate)"]
    C6 --> C7["context table {clock,config,data,net,gate, seams nil}"]
    C7 --> C8["net:bindContext(context)"]
  end
  C --> CONSTRUCT
  CONSTRUCT --> D["services array = {net, data, SampleService}"]
  D --> E["Bootstrap.start(services, context)"]
  subgraph START ["Bootstrap.start — pcall Start in GIVEN order"]
    direction TB
    S1["1. NetServer:Start — bind RemoteFunction/RemoteEvent"] --> S2["2. DataService:Start — hook PlayerAdded/Removing"]
    S2 --> S3["3. SampleService:Start — register actions last"]
  end
  E --> START
  START -->|"Start errors"| ERR["error: service NAME failed to Start (raises loud)"]
  START --> F["game:BindToClose"]
  F --> G["Bootstrap.stop — Stop in REVERSE order"]
  subgraph STOP ["reverse: Sample then Data then Net"]
    direction TB
    T1["SampleService:Stop (no-op if absent)"] --> T2["DataService:Stop — budget-aware flush of EVERY session"]
    T2 --> T3["NetServer:Stop (no-op if absent)"]
  end
  G --> STOP
  STOP -->|"a Stop errors"| W["warn only, never re-raised"]
```

The **gauntlet** is the four-step self-check contract (documented in `docs/TESTING.md` §2 and
`docs/CORE-DESIGN.md` §9 — it is a contract, not a committed script): `stylua --check`, then `selene`
under the `roblox-fenced` overlay that turns `wait`/`spawn`/`delay` into errors, then `rojo build`
(the only gate proving the Roblox-only modules compile), then `lune run tests/run.luau`, which prints
exactly one JSON line and exits nonzero on any failure.

```mermaid
flowchart TD
  G1["1. stylua --check src (stylua.toml)"] --> G2["2. selene src (selene.toml std=roblox-fenced)"]
  G2 --> OV["roblox-fenced.yml overlay: wait/spawn/delay removed:true -> selene errors"]
  OV --> G3["3. rojo build project -o build.rbxl (default.project.json, 3 roots)"]
  G3 --> G4["4. lune run tests/run.luau"]
  G4 --> JSON["ONE stdout line {passed,failed,total}"]
  JSON --> EX["process.exit 0 if failed==0 else 1"]
  EX -->|"nonzero"| FAILGATE["gauntlet fails"]
  G1 -.->|"any step nonzero"| FAILGATE
  G2 -.-> FAILGATE
  G3 -.-> FAILGATE
```

Inside step 4, `run.luau` requires the shared `testkit`, iterates the explicit lexically-sorted
`SPEC_PATHS` with `pcall(require)` (load errors become recorded failures), runs every registered case
via `testkit.run()`, routes failure detail to STDERR, and prints exactly one JSON line to STDOUT.

```mermaid
flowchart TD
  R["run.luau"] --> RK["require ./lib/testkit (script-relative)"]
  R --> SP["SPEC_PATHS (explicit, table.sort'd)"]
  SP --> LOOP["for each path: pcall(require, path)"]
  LOOP -->|"require error"| LF["testkit.recordLoadFailure(path,err)"]
  LOOP -->|"ok"| REG["spec registers describe/it into shared testkit"]
  LF --> RUN["summary = testkit.run() — pcall each case, returns counts"]
  REG --> RUN
  RUN -->|"failed>0"| ERR["stdio.ewrite FAIL lines to STDERR"]
  RUN --> OUT["print ONE JSON line to STDOUT"]
  ERR --> OUT
  OUT --> EXIT["process.exit(failed==0)"]
```

The on-disk `tests/` layout — the runner, three lib helpers, and the nine unit specs that match the
nine `SPEC_PATHS` entries:

```
core/tests/
  run.luau                 runner: explicit SPEC_PATHS, prints ONE JSON line, exits nonzero on fail
  lib/
    testkit.luau           describe/it/expect + JSON reporter data source (run() returns counts)
    assert.luau            deepEqual/isResultOk/isResultErr/approx/fail/render (no Roblox globals)
    mocks.luau             mock store + Mocks.logWarn stderr writer (keeps JSON line clean)
  unit/
    clock.spec.luau
    data.spec.luau
    economy_race.spec.luau
    framework.spec.luau
    migration.spec.luau
    net.spec.luau
    sample.spec.luau
    validation.spec.luau
    selene_guard.spec.luau  structural + best-effort live overlay self-test
```
