# Collect-Sim — Presentation Layer Plan (greybox v1)

> **Status of the game today:** `games/collect-sim` is a server-authoritative logic engine, 313/313
> Lune-green. The full core loop (collect → sell → buy upgrade → unlock island → rebirth, plus
> offline / daily / restock / leaderboard / monetization seams) is *implemented and verified* — but
> it has **no presentation**: no world geometry, no `SpawnLocation`, no HUD, no input handlers, no
> in-world affordances. A player who joins falls into the void; the loop is reachable only by calling
> controller methods from the command bar.
>
> **This plan scopes the presentation layer that makes the engine playable** — greybox-in-code only.
> It binds new UI + input + world geometry to the **already-existing** server actions and client
> controllers. It does **not** rebuild or re-litigate any logic.

---

## 0. Ground truth — what already exists (do not rebuild)

### 0.1 The 5 client controllers and their exposed surface

All live under `games/collect-sim/src/client/controllers/<feature>/`. Each is a thin
`{ name, Start(context) }` controller that calls the server through `context.net` and is **already
wired into the bootstrap** (`src/client/init.client.luau`). The presentation work **binds buttons /
prompts to the methods these already expose** — it does not add new net plumbing.

| Controller | File | Methods / state already exposed | Server actions it calls |
|---|---|---|---|
| `IslandsController` | `controllers/islands/IslandsController.luau` | `self.unlock(islandId)` → Result; `self.refresh()`; `self._islands` = catalog projection `{id, order, cost, multiplier, vip, unlocked}[]`. Subscribes to `"data"` push and re-fetches. | `FetchIslands`, `UnlockIsland` |
| `OfflineController` | `controllers/offline/OfflineController.luau` | `self.claim()` → Result; `self._lastClaim` = `{granted, balance, elapsed}`. **Auto-claims once on Start.** | `ClaimOffline` |
| `RebirthController` | `controllers/rebirth/RebirthController.luau` | `self.rebirth()` → Result; `self._rebirths`, `self._prisms` (mirrored from the `"data"` push). | `Rebirth` |
| `RestockController` | `controllers/restock/RestockController.luau` | `self.refresh()`; `self._restock` = `{islandId, multiplier, dayNumber, resetsAtUnix, eligible}`. Subscribes to `"data"`. | `FetchRestock` |
| `LeaderboardController` | `controllers/leaderboard/LeaderboardController.luau` | `self.refresh()`; `self._entries`. **Already builds its own in-world greybox board** (anchored Part + SurfaceGui) and polls every 5s. | `FetchLeaderboard` |

> **Gap #1 — there is NO controller for Collection (Collect/Sell) and NO controller for the Shop
> (BuyUpgrade).** The server services exist (`CollectionService`, `UpgradesShopService`) and the
> actions are registered, but no client controller calls `Collect` / `Sell` / `BuyUpgrade`. These are
> the two new controllers this plan adds.

### 0.2 The server actions the UI will invoke (`src/shared/Net.luau` → `Net.Actions`)

```
Collect         = "collect.gather"   -- empty payload {}; server adds 1 mote to caller's backpack
Sell            = "collect.sell"     -- empty payload {}; converts whole backpack → Stardust
BuyUpgrade      = "shop.buy"         -- { upgradeId: string }; server derives cost from catalog
UnlockIsland    = "islands.unlock"   -- { islandId: number }; server derives cost
FetchIslands    = "islands.fetch"    -- read-only catalog + unlocked booleans
Rebirth         = "rebirth.do"       -- empty payload {}
ClaimOffline    = "offline.claim"    -- empty payload {}
Daily           = "daily.claim"      -- empty payload {}  (NO controller today — see Gap #2)
FetchRestock    = "restock.fetch"
FetchLeaderboard= "leaderboard.fetch"
```

> **Gap #2 — `Daily` ("daily.claim") has a server service (`DailyStreakService`) but no client
> controller and no affordance.** The HUD badge can *show* the streak from the `"data"` push, but
> nothing *calls* `Daily`. This plan adds a daily-claim affordance + the call (folded into the HUD
> controller — see §7).

### 0.3 Server catalogs the world/UI must mirror (read these to drive geometry)

- **Islands** (`server/services/islands/IslandsService.luau`, `CATALOG`):
  `{id=1,cost=0,mult=1}`, `{2,500,2}`, `{3,2500,4}`, `{4,10000,8}`, `{5,40000,16, vip=true}`.
  Index 1 is the **starting island**, always unlocked, no flag. Islands unlock **in order**; the VIP
  island also needs `flags['gamepass.vipIsland']`. The client never sees these numbers except through
  `FetchIslands` — **the world generator must read them the same way (fetch), never hardcode them**.
- **Upgrades** (`server/services/shop/UpgradesShopService.luau`, `CATALOG`):
  `collect-speed`(base 25), `backpack`(40), `magnet`(60), `walk-speed`(50); all `maxLevel = 10`;
  next-level cost = `base * (currentLevel + 1)`. The shop UI shows the four buttons; **cost is
  server-derived** — the UI may *display* a predicted cost but must never *send* one.
- **Collection** (`server/services/collection/CollectionService.luau`): `CAPACITY = 50`,
  `MOTE_VALUE = 3`. Auto-collect: 1 mote per second of mono time **for `gamepass.autoCollect`
  holders only**, via `tickAutoCollect(ctx, player)` — **exposed but driven from nowhere** (see §9).
- **Restock**: rich vein rotates daily over island ids 1..5; `RICH_VEIN_MULTIPLIER = 3`.
- **Rebirth**: threshold `1000` Stardust → Prisms; resets upgrades + island flags.

### 0.4 The data-view push (the HUD's data source)

On load and after relevant writes, the server pushes the **client-safe** `PlayerView` over the shared
RemoteEvent as the `"data"` event:
`DataService` calls `self._net:fireClient(player, "data", Types.toView(data))`.
`PlayerView` (`src/shared/Types.luau`) contains exactly:
`currencies` (`Stardust`, `Prisms`), `rebirths`, `stats` (incl. `lifetimeStardust`), `upgrades`,
`flags`, `daily` (`streak`, `lastClaimUnix`), `boostExpiresUnix`.
**The HUD subscribes via `context.net:on("data", fn)`** — the same channel the existing controllers
use. (Note: the in-memory **backpack count is *not* in `PlayerView`** — it is returned only in the
`Collect`/`Sell` action *replies*. The HUD backpack number is therefore driven by the latest Collect/
Sell reply, not by the data push. See §5 / risk R4.)

### 0.5 Standing constraints (CLAUDE.md §10 — apply to ALL new code)

- `--!strict` on every module. `task.*` only — **never** `wait`/`spawn`/`delay` (selene bans them).
- **Server-authoritative.** The client sends only the existing gated actions with their existing
  payloads. It never sends a cost, a mote identity, a level, or a balance. Validation
  (type+range+ownership+rate) already lives server-side; presentation must not weaken it.
- **Greybox-in-code only.** Islands = anchored `Part`s; motes = small `Part` + `PointLight`; pads =
  `Part` + billboard/`SurfaceGui`. No external assets, meshes, animations, or audio in v1.
- **The factory must never publish.** This is build-only; nothing here ships to Roblox.

---

## 1. Architecture decision: where does the world get built — server or client?

This is the single biggest structural choice, so it is settled up front.

**Decision: the persistent collision world is SERVER-BUILT; cosmetic-only motes and all GUIs are
CLIENT-BUILT.**

| Thing | Built by | Why |
|---|---|---|
| `SpawnLocation` + baseplate/ground | **Server** | A player must not fall into the void; spawn + collision geometry must exist authoritatively for everyone before the first client loads. Built once at boot. |
| Per-island anchored greybox Parts | **Server** | Real collision platforms players stand on. Generated from the `FetchIslands` catalog so geometry stays in lockstep with server authority. |
| Unlock pads, refiner/sell pad, rebirth pad, shop pad | **Server** | They carry `ProximityPrompt`s whose `.Triggered` fires **on the server** (see R2) — cleanest when the part itself is server-owned. |
| Collectible motes (visual) | **Client** | Motes are *purely cosmetic* — the server's `Collect` action trusts **no** client mote identity (it just adds 1 to the caller's backpack). So motes can be client-local eye-candy; spawning them server-side would waste replication for zero authority gain. |
| HUD, shop GUI, welcome-back popup, rebirth/streak panels | **Client** | Per-player UI; lives in `ScreenGui`s under `PlayerGui`. |

> **Consequence:** the world generator is a **new server service** (it needs `workspace` + boot
> ordering), while motes + all GUIs are **new/extended client controllers**. The existing
> `LeaderboardController` already builds its board client-side — that pattern is fine for a read-only
> cosmetic board, but the *playable* world goes server-side per the table above.

---

## 2. SpawnLocation + baseplate/ground — server-built

**Where:** new server service `src/server/services/world/WorldService.luau`
(`{ name = "WorldService", Start(context) }`), registered in `src/server/init.server.luau`'s
`services` list **after** `IslandsService` (it reads the island catalog through the same fetch path /
a shared seam — see §3) but it needs no net action.

**How:**
- In `Start`, guard the Roblox globals exactly like `LeaderboardService`/`DataService` do
  (`local realGame = game; if realGame == nil then return end`) so the module stays Lune-inert and
  the gauntlet's `lune run` never touches `workspace`.
- Create one anchored baseplate `Part` (large, `Anchored = true`, `CanCollide = true`) as the floor
  under the starting island, and a `SpawnLocation` (`Anchored = true`, `Neutral = true`) parented to
  `workspace` above the starting island platform.
- Idempotent: `FindFirstChild` before `Instance.new` so a re-run (or the Studio default baseplate)
  doesn't double-build.

**New files:** 1 (`WorldService.luau`). **Touches:** `init.server.luau` (1 line to register).

> v1 may simply *keep* Studio's default baseplate and only add the `SpawnLocation` — but building both
> in code keeps the place reproducible from `rojo build` with zero manual Studio editing, which the
> factory wants. Build the baseplate.

---

## 3. Per-island greybox Parts from the catalog — server-built

**Where:** same `WorldService` (§2), or a sibling `src/server/services/world/IslandGeometry.luau`
helper it requires. Server-built so the platforms are real collision for everyone.

**How:**
- WorldService needs the island catalog (ids/costs/multipliers/order/vip). Two clean options; pick
  **(b)**:
  - **(a)** Call `FetchIslands` server-side — awkward, that's a net action shaped for clients.
  - **(b) Add a tiny read-only seam on IslandsService**: `IslandsService` already publishes
    `context.islands = IslandsSeam`. Extend that seam with a pure `IslandsSeam.catalog()` returning
    the catalog projection (id/order/cost/multiplier/vip). WorldService reads `context.islands:catalog()`
    in `Start`. This is a **contract-respecting** addition (a new method on an existing server seam,
    no shared-contract `Net.luau`/`Types.luau` change) — note it as a small controlled amendment to
    `IslandsService` only.
- For each catalog entry, `Instance.new("Part")` anchored, sized as a platform, positioned along a
  fixed lateral layout (e.g. island `order` → `Position.X = (order-1) * GAP`), increasing height/size
  per order to read as "higher, richer islands". Tag each with an `IntValue`/attribute `islandId` so
  pads and motes can find their island.
- Each non-starting island gets an **unlock pad** (§6) and is the spawn region for its tier of motes
  (§4).

**New files:** 0–1 (helper optional). **Touches:** `IslandsService.luau` (add `catalog()` to the
seam — small amendment), `WorldService` body.

---

## 4. Collectible motes + the collect trigger — client motes, server-authoritative Collect

**Where:** new client controller `src/client/controllers/collection/CollectionController.luau`
(register it in `src/client/init.client.luau`'s `controllers` list).

**The authority subtlety (keep intact):** the server's `Collect` action takes an **empty payload** and
just increments the caller's backpack by 1 (capped at `CAPACITY`). It **deliberately does not trust
any client mote identity** — "mote identity/proximity is a Tier-3 server-authority concern, not trusted
here." So the visual mote and the authoritative collect are **decoupled**: the mote is a client prop;
collecting is "ask the server to add one mote." We must **not** smuggle a mote id or position into the
payload (that would invent trust the server refuses).

**How (mote representation):**
- CollectionController spawns small `Part` + `PointLight` motes client-side around the player's
  current island (cosmetic, `CanCollide = false`). A modest pool (e.g. ~20) recycled with `task.spawn`
  + `task.wait` loops (never `wait`/`spawn`).
- Material/colour shift per island tier so richer islands read differently (purely cosmetic).

**How (the collect trigger) — three options, recommended hybrid:**
- **Magnet / proximity (auto):** a client `Heartbeat`/`task` loop checks motes within a radius of the
  character; when one is "absorbed", play the absorb visual locally **and** call
  `net:call(Collect, {})`. On `Result.ok`, update the HUD backpack from the reply
  (`{count, capacity, full}`); on `OutOfRange` ("backpack full") stop absorbing and flash the HUD
  capacity bar. This matches the spec's "motes auto-collect into your backpack."
- **`ProximityPrompt` fallback / manual:** optionally a per-mote `ProximityPrompt` whose
  `.Triggered` calls `Collect` — useful before the magnet upgrade exists. (If used, see R2 on
  client-vs-server prompt event flow.)
- Either way the **payload stays `{}`** — the client decides *when* to ask, the server decides *what a
  collect does*. Rate is already bucketed server-side (`maxPerWindow=20, burst=30`), so the magnet
  loop must throttle its calls to stay under that (e.g. ≥1 mote per ~50ms) or it will be rate-shed.

**New files:** 1 (`CollectionController.luau`). **Touches:** `init.client.luau` (1 line).

---

## 5. Refiner / sell pad — server pad, Sell call

**Where:** the pad **Part + `ProximityPrompt`** is built by `WorldService` (server, §2/§3) on the
starting island; the **call** to `Sell` is made by `CollectionController` (§4).

**How:**
- `WorldService` builds a "Refiner" pad Part with a `ProximityPrompt` ("Sell stardust") and a
  billboard label.
- Wire `prompt.Triggered` → `net:call(Sell, {})`. **Decision on where Triggered is handled:** to keep
  the *call* in the client controller (which owns the HUD), connect the prompt **on the client** in
  `CollectionController:Start` by finding the pad in `workspace` (`WaitForChild`) and connecting
  `prompt.Triggered`. (`ProximityPrompt.Triggered` fires on **both** server and client; handling it
  client-side lets us update the HUD from the `Sell` reply directly. See R2.)
- On `Result.ok`, the reply is `{sold, earned, balance}` → update HUD Stardust + clear the backpack
  bar. The data push will *also* arrive (Stardust changed), refreshing the HUD redundantly — fine.

**New files:** 0 (pad built in WorldService, wired in CollectionController). **Touches:** both.

---

## 6. Unlock pads (per island) + rebirth pad — wired to existing controller methods

**Where:** pads built by `WorldService` (server); prompts wired in the **existing** controllers.

**How:**
- **Unlock pads:** `WorldService` builds one pad Part + `ProximityPrompt` per **non-starting** island,
  tagged with its `islandId` (attribute). `IslandsController:Start` is extended to find these pads
  (`workspace`, `WaitForChild`/`CollectionService`-style scan) and connect each
  `prompt.Triggered` → `self.unlock(islandId)` (the method **already exists**). On the returned Result,
  flash success/failure on the pad billboard; `unlock()` already re-fetches and the `"data"` push
  refreshes the HUD.
  - The pad billboard shows cost/multiplier/locked-state read from `self._islands` (the
    `FetchIslands` projection) — display only, never sent.
- **Rebirth pad:** `WorldService` builds one rebirth pad + prompt; `RebirthController:Start` connects
  `prompt.Triggered` → `self.rebirth()` (method **already exists**). Result `{rebirths, prisms,
  multiplier}` → confirmation popup; `"data"` push updates the HUD Prisms/rebirth count.
- **Daily pad (optional):** a "Daily reward" pad whose prompt fires `Daily` — but `Daily` has no
  controller (Gap #2). Simplest: fold the daily claim into the HUD controller (§7) as a button, and/or
  build the pad and have the HUD controller connect it.

**New files:** 0. **Touches:** `IslandsController.luau` (+ prompt wiring), `RebirthController.luau`
(+ prompt wiring), `WorldService` (builds the pads).

---

## 7. HUD `ScreenGui` — new client controller bound to existing state + the data push

**Where:** new client controller `src/client/controllers/hud/HudController.luau` (register in
`init.client.luau`). It is the central display surface; other controllers feed it.

**What it shows (all already available):**
| HUD element | Source |
|---|---|
| **Stardust** | `"data"` push → `view.currencies.Stardust` |
| **Prisms** | `"data"` push → `view.currencies.Prisms` (also `RebirthController._prisms`) |
| **Backpack count / capacity** | `Collect`/`Sell` **action replies** `{count, capacity}` (NOT in the data push — see R4). HudController exposes `setBackpack(count, capacity)` that CollectionController calls. |
| **Rebirth count** | `"data"` push → `view.rebirths` (also `RebirthController._rebirths`) |
| **Daily streak badge** | `"data"` push → `view.daily.streak` (+ a claim button firing `Daily`, covering Gap #2) |
| **Restock "rich vein" hint** | `RestockController._restock` (`islandId`, `multiplier`, `eligible`, `resetsAtUnix` for a countdown) |
| **Welcome-back popup** | `OfflineController._lastClaim` (`granted`, `balance`) — show on first claim if `granted > 0` |
| **2x boost timer** (nice-to-have) | `"data"` push → `view.boostExpiresUnix` vs server time |

**How:**
- `HudController:Start` builds one `ScreenGui` under `PlayerGui` with labels/frames (greybox:
  `TextLabel`/`Frame` + `UICorner`/`UIStroke`, no art).
- Subscribe `context.net:on("data", fn)` and re-render currency/rebirth/streak/boost on every push
  (same channel the islands/rebirth/restock controllers already use).
- For backpack + restock + offline, the controller either reads the sibling controllers' `self._*`
  state on a light `task` refresh loop, **or** (cleaner, avoids cross-controller reads which the
  framework discourages) expose small setter methods on HudController and have CollectionController /
  RestockController / OfflineController call them. **Recommended:** setter methods — controllers
  resolve HudController off `context` is *not* the pattern (controllers don't require siblings), so
  instead pass updates by having each controller publish to a tiny shared client event bus, **or**
  the simplest pragmatic route: HudController polls the read-only `self._*` fields via a short
  `task.wait` loop (the restock/offline state changes rarely). Choose the poll loop for v1 to avoid
  new plumbing; note it as a known seam to tidy later.

**New files:** 1 (`HudController.luau`). **Touches:** `init.client.luau` (1 line).

---

## 8. Shop `ScreenGui` — NEW controller (UpgradesShopService has none) firing BuyUpgrade

**Where:** new client controller `src/client/controllers/shop/ShopController.luau` (register in
`init.client.luau`). **This is the missing controller called out in Gap #1.**

**How:**
- `ShopController:Start` builds a shop `ScreenGui` (greybox panel) with **four** `TextButton`s — one
  per upgrade kind (`collect-speed`, `backpack`, `magnet`, `walk-speed`). The four ids are the
  server catalog keys; the controller may carry them as a local constant list (display-only labels)
  but **must not** carry costs — cost is server-derived.
- Each button's `.Activated` → `net:call(BuyUpgrade, { upgradeId = <id> })` (the **only** field the
  server reads). On `Result.ok` the reply is `{upgradeId, level, cost, balance}` → update the button
  label to the new level and the HUD Stardust. On `Insufficient`/`OutOfRange` (maxed) → flash the
  button.
- A shop **open trigger:** either a HUD "Shop" button (built by HudController, but the call lives in
  ShopController — so add a small `toggle()` on ShopController and a shop pad/prompt in `WorldService`
  whose `.Triggered` opens it), or a `ProximityPrompt` on a "Shop" pad. Recommended: a shop pad +
  prompt (consistent with the other affordances) opening the `ScreenGui`.
- Optionally display the **predicted** next-level cost (`base*(level+1)`) computed client-side **for
  display only** — clearly never sent. Simpler v1: show only the current level and let the server
  reply carry the cost actually charged.

**New files:** 1 (`ShopController.luau`). **Touches:** `init.client.luau` (1 line), `WorldService`
(shop pad).

---

## 9. Auto-collect runtime driver — NEW server loop calling tickAutoCollect

**Where:** `CollectionService:Start` (extend it) — the ticker is already a field on the service
instance (`self.tickAutoCollect = makeAutoCollectTicker(backpacks)`), it just has **no driver**.

**The gap:** `tickAutoCollect(ctx, player)` is "exposed but driven from nowhere." It is a pure,
clock-driven, gamepass-gated grant (1 mote per second of mono time for `gamepass.autoCollect`
holders), deliberately built without `task.wait` so it stays Tier-1 testable.

**How:**
- In `CollectionService:Start`, after registering the actions, add a **runtime-only** `Heartbeat`/
  `task` driver behind the same Lune guard the other services use
  (`local realGame = game; local realTask = task; if realGame == nil or realTask == nil then return end`).
- The driver builds a per-player `ActionContext` the ticker needs (`{ player, clock, data, ... }`) —
  it can reuse `context.net:actionContext(player)` (NetServer already builds the narrow ctx) or
  construct a minimal `{ clock = context.clock, data = context.data, player = player }`.
- On a loop (`RunService.Heartbeat:Connect` **or** `task.spawn` + `task.wait`), iterate
  `Players:GetPlayers()` and call `self.tickAutoCollect(ctx, player)` per live player. The ticker
  itself no-ops for non-gamepass holders and carries the sub-interval remainder, so a coarse loop
  (e.g. every 1s) is fine and never grants ahead of real time.
- Granted motes land in the same `backpacks` table `Collect`/`Sell` share — so auto-collected motes
  sell normally. No new action, no client involvement.

**New files:** 0. **Touches:** `CollectionService.luau` (`Start` gets the guarded driver). **Note:**
this is a *server* code change to a tested service — keep it strictly inside the runtime guard so the
existing Lune tests (which drive `tickAutoCollect` directly via the fake clock) stay green and
untouched.

---

## 10. Input wiring — the affordance → controller-method map

All input connects existing affordances to **existing** controller methods (except the two new
controllers). No new RemoteEvents — only the existing gated actions.

| Affordance (greybox) | Input event | Calls | Built where / wired where |
|---|---|---|---|
| Motes (magnet radius) | client `Heartbeat`/`task` loop | `Collect` `{}` | mote: CollectionController; loop: CollectionController |
| Mote `ProximityPrompt` (fallback) | `prompt.Triggered` | `Collect` `{}` | CollectionController |
| Refiner pad | `ProximityPrompt.Triggered` | `Sell` `{}` | pad: WorldService; wire: CollectionController |
| Unlock pad ×(islands−1) | `ProximityPrompt.Triggered` | `IslandsController.unlock(islandId)` | pad: WorldService; wire: IslandsController |
| Rebirth pad | `ProximityPrompt.Triggered` | `RebirthController.rebirth()` | pad: WorldService; wire: RebirthController |
| Shop pad / HUD button | `ProximityPrompt.Triggered` / `GuiButton.Activated` | open ShopController panel | pad: WorldService; panel+toggle: ShopController |
| Shop upgrade buttons ×4 | `TextButton.Activated` | `BuyUpgrade {upgradeId}` | ShopController |
| Daily claim button | `GuiButton.Activated` | `Daily {}` | HudController (covers Gap #2) |
| Offline welcome-back | auto on join (already) | `ClaimOffline {}` | OfflineController (exists) |

`UserInputService` is optional for v1 (e.g. a keybind to toggle the shop) — `ProximityPrompt` +
`GuiButton.Activated` cover the loop without it.

---

## 11. Out of scope for greybox v1 / what stays server-authoritative

**Out of scope (v1):** all art (meshes, textures, custom models), animations, particle systems beyond
a `PointLight`, sound/music, polished UI theming, camera work, tweened transitions, mobile-tuned
layouts, the Leaderboard board rework (it already renders), trading/pets/PvP (spec out-of-scope).
Motes are `Part`s; islands are `Part`s; pads are `Part`s + billboards; HUD/shop are plain
`TextLabel`/`TextButton`/`Frame` greybox.

**Must remain server-authoritative (do not weaken):**
- `Collect`/`Sell`/`BuyUpgrade`/`UnlockIsland`/`Rebirth`/`Daily`/`ClaimOffline` payloads stay exactly
  as the server defines them. The client sends **no** cost, level, mote id, balance, time, or
  multiplier.
- The `Collect` action's **no-client-mote-trust** property is preserved: motes are cosmetic;
  collecting is "add one to the caller's backpack," capacity-capped server-side.
- All economy mutation stays inside the existing lock-held `ctx.data:update` transforms. Presentation
  reads the `"data"` push and action replies; it never writes data.
- Time-based hints (restock countdown, boost timer) render from **server-supplied** unix values, never
  client clocks.

---

## 12. Suggested BUILD ORDER (smallest playable slice first)

Each step is independently runnable in Studio and leaves the game more playable.

1. **Slice 0 — "don't fall in the void."** `WorldService` builds baseplate + `SpawnLocation` +
   the **starting island** platform only. Player can join and stand. *(1 new server file.)*
2. **Slice 1 — the minimum loop.** Add to CollectionController: cosmetic motes on the starting island
   + magnet-loop `Collect`; WorldService builds the refiner pad; CollectionController wires the
   refiner prompt → `Sell`. Add HudController showing **Stardust + backpack count/capacity**. → A
   player can now *collect → sell → watch Stardust rise*. **This is the first genuinely playable
   slice.** *(2 new client files: Collection, Hud.)*
3. **Slice 2 — spend it.** ShopController + shop panel + 4 `BuyUpgrade` buttons + shop pad. → collect
   → sell → **buy upgrade**. *(1 new client file.)*
4. **Slice 3 — climb.** WorldService builds island 2..5 platforms (from the catalog seam) + unlock
   pads; wire `IslandsController.unlock`. HUD/island billboards show cost/locked. → **unlock island**.
5. **Slice 4 — prestige.** Rebirth pad + `RebirthController.rebirth` wiring + HUD rebirth/Prisms. →
   **rebirth.** *(Now the full spec core loop is reachable by walking + prompts.)*
6. **Slice 5 — re-entry hooks on the HUD.** Welcome-back popup (OfflineController already claims),
   daily streak badge + claim button (covers Gap #2), restock rich-vein hint (RestockController
   exists). *(No new files — HUD wiring.)*
7. **Slice 6 — auto-collect driver.** Add the guarded Heartbeat driver in `CollectionService:Start`
   calling `tickAutoCollect` per player. *(Server change, behind the Lune guard.)*
8. **Slice 7 — polish/edges (optional v1 tail):** boost timer, shop predicted-cost display, mote
   tiering per island, UserInputService shop keybind.

> After **Slice 5** the full spec loop (collect → sell → buy → unlock → rebirth) is playable by a
> human in Studio with no command bar. Slices 6–7 round out the re-entry hooks and gamepass path.

---

## 13. New-file / module estimate

| Piece | New files | Touched files |
|---|---|---|
| WorldService (spawn + baseplate + island platforms + all pads) | 1 (`world/WorldService.luau`) [+1 optional geometry helper] | `init.server.luau`, `IslandsService.luau` (catalog seam) |
| CollectionController (motes + magnet Collect + refiner Sell wiring) | 1 (`collection/CollectionController.luau`) | `init.client.luau` |
| ShopController (shop GUI + BuyUpgrade) | 1 (`shop/ShopController.luau`) | `init.client.luau` |
| HudController (HUD + daily claim) | 1 (`hud/HudController.luau`) | `init.client.luau` |
| Auto-collect driver | 0 | `CollectionService.luau` (`Start` guarded loop) |
| Unlock/rebirth/daily prompt wiring | 0 | `IslandsController.luau`, `RebirthController.luau` |

**Total: ~4 new files** (1 server, 3 client) + ~6 touched files. Plus tests: any **server** change
(WorldService catalog seam, the auto-collect driver) needs a spec-derived Tier-1 test through the
independent gate; the pure-presentation client controllers are Roblox-only (Lune-inert, like the
existing controllers) and are validated by `rojo build` + manual Studio play, not Lune unit tests.

---

## 14. Biggest risks

- **R1 — server-built vs client-built world.** Mixing them wrong = duplicated or missing geometry
  (e.g. WorldService builds an island Part *and* a client controller also builds one). **Mitigation:**
  the §1 table is the contract — collision world + pads are server-only; motes + GUIs are client-only;
  WorldService is idempotent (`FindFirstChild` guards).
- **R2 — `ProximityPrompt.Triggered` server/client event flow.** `Triggered` fires on **both** the
  server and the triggering client. If both a server `Script` and the client controller connect it and
  both call the action, the action fires twice (rate-shed, but confusing). **Mitigation:** connect each
  prompt in **exactly one place** — the client controller that owns the resulting UI update — and never
  also connect it server-side. The server stays authoritative because the *action* is server-validated
  regardless of who triggered the prompt.
- **R3 — keeping the `Collect` no-client-trust property intact.** The temptation is to send the mote's
  id/position so the server can "verify" it. **Do not.** The server's design is "add one to the caller's
  backpack, capacity-capped"; the mote is cosmetic. Sending mote identity invents trust the server
  refuses and creates a spoof surface. **Mitigation:** payload stays `{}`; the magnet loop just decides
  *when* to ask.
- **R4 — backpack count is not in the data push.** The HUD backpack number comes only from
  `Collect`/`Sell` action replies, not the `"data"` event. If the HUD tries to read it from the push it
  will always show stale/zero. **Mitigation:** CollectionController feeds the HUD the backpack count
  from each action reply; on (re)join the count starts at 0 (session-state backpack), which is correct.
- **R5 — auto-collect driver touching a tested service.** The driver lives in `CollectionService:Start`,
  a Lune-tested module. A bare `task.wait`/`game` reference would break `lune run`. **Mitigation:** put
  the driver strictly behind the `realGame == nil`/`realTask == nil` runtime guard (the established
  `LeaderboardService`/`DataService` pattern) so Lune never executes it and the existing
  `tickAutoCollect` tests stay green.
- **R6 — rate limits throttling the magnet loop.** `Collect` allows `maxPerWindow=20, burst=30` per
  second. A magnet loop firing faster gets `Rejected`/rate-shed, dropping motes silently.
  **Mitigation:** throttle client `Collect` calls under the bucket; treat a rate rejection as
  back-pressure (slow the loop), not an error.
- **R7 — `IslandsService` catalog seam is a contract amendment.** Adding `catalog()` to the islands
  seam is a (small) change to a built/tested server service. **Mitigation:** make it a pure read-only
  method that returns a projection (no behavior change to `multiplierFor`), and add a focused Tier-1
  test so the gate stays green — treat it as the "controlled contract amendment" CLAUDE.md describes,
  not a silent edit.
- **R8 — HUD cross-controller reads.** The framework says controllers don't `require` siblings. The HUD
  needs restock/offline/backpack state that other controllers hold. **Mitigation (v1):** HUD polls the
  read-only `self._*` fields via a light `task` loop, or controllers push to the HUD via setters /a
  tiny client event bus; pick the poll loop for v1 and note the seam.
