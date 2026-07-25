# B2-SESSIONSTORE-DESIGN.md — the real persistence layer

> **APPROVED (rev 3, 2026-07-25): the human checkpoint passed — all eight decisions D1–D8 accepted
> as recommended (§13). Build unblocked per FACTORY.md design → checkpoint → build.** Pre-build design for
> B2's #1 piece: the real session-locked DataStore behind the **unchanged `Store` interface**. It makes
> the player-data + receipts-ledger **durable across restarts** — today the runtime store is the
> in-memory `MockStore`, so a restart loses all data + the idempotency ledger (a real-money receipt could
> be re-granted on redelivery; `docs/LEARNINGS.md` §2). This piece **unblocks** that fix; it does not by
> itself contain the idempotent `ProcessReceipt` (that is the monetization slice). Grounded in the live
> contracts (`core/src/server/data/{Store,MockStore,DataService}.luau`, `Config.luau`, `CORE-DESIGN` §4.3)
> and revised against an adversarial review that confirmed the lock's *write-exclusion core is sound* and
> found a crash-rejoin availability flaw + an honest-accounting flaw, now folded in. Nothing built yet —
> high-blast-radius foundation work goes **design → human checkpoint → build**.

---

## 1. Goal + the hard constraint

Drop in a real `SessionStore` implementing the **same `Store` interface**, so **feature/economy call
sites do not change** — `DataService` only sees `Store`/`Session`. **One honest exception (see §9):** the
`LockStolen` reaction requires a bounded, named change *inside `DataService`* (not in any feature code).
Everything else above the interface — every feature service, the gauntlet, all 313 specs — is untouched.

## 2. Two-layer concurrency model (both locks exist for different reasons)

The single most important thing to keep straight — the reviewer confirmed this split is correct:

| Problem | Scope | Mechanism |
|---|---|---|
| Two coroutines on the **same server** mutate one player (spam-dup actions) | in-process | the **§4.1 per-key FIFO queue** (identical to MockStore) on the in-memory value |
| Two **different servers** hold the same player (rejoin race, ghost server) | cross-server | the **session lock** (§4) — only the `lockId`-owner may persist |

`update` uses only the in-process queue (fast, no network). `load`/`save`/`release` touch the backing
store and enforce the session lock. Doing a DataStore write inside `update` is the first way this breaks.

## 3. Storage layout — MemoryStore TTL lock (recommended) + DataStore data + a lockId write-stamp

The reviewer's H1: a **DataStore-embedded** lock needs a manual stale-timeout, and any stale-timeout large
enough to avoid stealing a slow-but-live server (M3) is far larger than the load-retry budget — so a hard
crash leaves a not-yet-stale lock and the rejoining player is **kicked in a loop** until it expires. A
**short-TTL MemoryStore lock dissolves this**: it *auto-expires* on crash in seconds, with no manual
stale-timeout to size. Recommended layout (the ProfileService-style split):

```
-- LIVENESS lock (fast, auto-expiring): MemoryStore, short TTL
lockMap = MemoryStoreService:GetHashMap(Config.storeName .. "_lock")   -- TODO(verify): exact MemoryStore API
lockMap[key] = { lockId }   with expiration = LOCK_TTL (~30s); renewed while held

-- DURABLE data: DataStore, the authoritative record
store = DataStoreService:GetDataStore(Config.storeName)
record = {
  data = <PlayerData>,          -- the migrated blob (Session.data mirrors it)
  lockId = <string> | nil,      -- STAMPED on every save; the final write-exclusion (see §4.2)
  metaVersion = 1,              -- envelope version, distinct from data.schemaVersion
}
```

The MemoryStore lock is the **fast, crash-safe gate** (claim + liveness). The DataStore `lockId` stamp is
the **authoritative save-time write-exclusion** — it closes the MemoryStore↔DataStore TOCTOU (a lock that
expires + is re-claimed between our check and our write): the DataStore `UpdateAsync` re-checks the stored
`lockId` atomically, so a zombie can never clobber the new owner even if the MemoryStore lock lied.

> **Decision D1 — lock substrate.** (a) **MemoryStore TTL lock + DataStore data + lockId stamp**
> [**recommended**: auto-expiry kills the crash-rejoin kick-loop (H1), no stale-timeout to mis-size (M3),
> sub-second claims]; (b) **DataStore-embedded lock only** [simpler, one service, but reintroduces H1 —
> needs a *dedicated large `SessionLocked` wait budget* so a rejoining player WAITS out the stale window
> instead of being kicked, and careful stale sizing vs M3]; (c) MemoryStore is a second service with its
> own quota and can evaporate — the DataStore `lockId` stamp (kept in both a & c) is why an evaporated
> lock is still safe (worst case: a brief contention window, never a double-write). Recommend (a).

## 4. The lock protocol

`lockId` = a per-server-lifetime identity. **Decision D2:** `game.JobId` `-- TODO(verify):` non-empty +
unique in a live server; **empty in Studio-solo**, so generate + reuse a GUID fallback there. Timings are
**Decision D3** (the central tension — resolve it, don't hand-wave): `LOCK_TTL ≈ 30s`,
`HEARTBEAT_INTERVAL = LOCK_TTL/2 ≈ 15s` (renew well inside the TTL, with margin for a throttled renew —
see M3), `AUTOSAVE_INTERVAL ≈ 60s`. With a TTL lock the "steal" is just **expiry** — no manual
stale-timeout, no false-steal-of-a-live-server if the heartbeat comfortably beats the TTL under retry
jitter (size `HEARTBEAT_INTERVAL + maxRetries·retryBaseSeconds·… < LOCK_TTL`).

### 4.1 `load` — claim the liveness lock, read the data
1. **Claim** `lockMap[key]` via MemoryStore `UpdateAsync` (atomic CAS): set `{lockId=myId}` with
   `LOCK_TTL` **iff** empty / already `myId` (re-entrant) / expired. If a *live* other-server lock is
   present → not acquired.
2. Acquired → read the DataStore `record` (or a fresh `default()`), start the **heartbeat** (§4.4), build
   the `Session` around `record.data`, `Result.ok(session)`.
3. Not acquired → **retry within budget**; still locked → `Err("SessionLocked")`.
   `DataService.loadSession` already treats `SessionLocked` as retryable. **H1 fix (Decision D3):** the
   short `LOCK_TTL` means a crashed owner's lock is gone in ≤`LOCK_TTL`, so a bounded wait (a
   `SessionLocked`-specific budget ≈ `LOCK_TTL` + margin, **not** the ~10s `Internal` budget) lets the
   player *wait out* a crash instead of being kicked. This budget split is a DataService change (§9).

### 4.2 `save` — persist, gated by the DataStore lockId stamp (the authoritative exclusion)
`DataStore:UpdateAsync(key, fn)`:
```
fn(stored):
  if stored ~= nil and stored.lockId ~= nil and stored.lockId ~= myId then
       return nil                      -- our lock was lost + re-claimed -> DO NOT WRITE
  record       = stored or { metaVersion = 1 }
  record.data  = session.data          -- flush the in-memory (post-transform) value
  record.lockId = myId                 -- stamp: we are the writer
  return record
```
- Wrote → ok. This is the real write-exclusion even if the MemoryStore lock briefly lied (§3 TOCTOU).
- `stored.lockId ~= myId` → **`Err("LockStolen")`, MUST NOT write** (the new owner is authoritative).
  `LockStolen` is **permanent** for this session — the reaction is terminal, not retryable (§9 / H2).
- Budget: honor the throttle floor + retry DataStore throttle/`Internal` up to `maxRetries`
  (`retryBaseSeconds` backoff) — the policy MockStore's `throttleSaves` already lets Tier-1 assert.
  **`LockStolen` is NOT in this retry set** (retrying a permanent failure wastes the budget — H2).

### 4.3 `release` — final save + free both locks
A `save`-shaped `UpdateAsync` that on success clears the DataStore `lockId` (`record.lockId = nil`), then
frees/expires the MemoryStore lock. Idempotent; if the lock isn't ours, touch nothing. Stops the heartbeat.

### 4.4 The heartbeat (liveness renewal)
While held, a guarded `task.spawn` loop every `HEARTBEAT_INTERVAL` **renews the MemoryStore lock TTL**
(cheap; it is NOT a DataStore write, so it does not compete with the autosave for the DataStore per-key
budget — this resolves M7's fold inconsistency: heartbeat renews the *MemoryStore* lock, autosave flushes
the *DataStore* data; they are different substrates). If a renewal finds the lock is no longer `myId` (a
brownout let it expire + another server claimed), it stops and marks the session a **zombie** (§9).

> **Decision D5 — write cadence.** Autosave every `AUTOSAVE_INTERVAL` (bounds ungraceful-crash data-loss
> to one interval) vs save-on-release-only. Recommend autosave. The heartbeat (MemoryStore) and the
> autosave (DataStore) are **separate** writes on separate substrates, so both cadences coexist.

## 5. `update` — unchanged, in-memory only (no network)

`Session.update(transform)` is **byte-for-byte MockStore's**: acquire the in-process per-key lock (park in
the FIFO + yield if held), re-read the latest in-memory `self.data`, run the **synchronous** transform,
write it back in memory, release + resume the next waiter. **No DataStore call.** The durable write is in
`save` (autosave/release/BindToClose). This keeps the economy hot-path off the network and preserves the
§9.3 race guarantee. `set` likewise only replaces the in-memory value. **Crash window (disclosed):** an
ungraceful crash loses up to `AUTOSAVE_INTERVAL` of in-memory progress. **This window MUST NOT cover
money** — see §10 (receipt save-before-ack).

## 6. Boot wiring — pick the store by real capability (not `game ~= nil`)

`Context.build` must construct the right store. The reviewer's L8: `game ~= nil` is the **wrong** guard —
`Context` already dereferences `game` at module scope so it is never loaded under Lune anyway (the 313
tests `new` `MockStore` directly via `Mocks.store`, never `Context.build`), which makes an
`if game then Session else Mock` branch's `else` **dead** and gives **no MockStore fallback for a
Studio-solo playtest** (where `GetDataStore`/`UpdateAsync` error without API access). Guard on **real
DataStore capability** instead:
```
local canPersist = RunService:IsRunning()                  -- not edit-mode
  and pcall(function() DataStoreService:GetDataStore(Config.storeName):GetAsync("__probe") end)  -- API access
local store = if canPersist then SessionStore.new({...}) else MockStore.new({ clock, config })
```
- `SessionStore.luau` is **Roblox-only** (DataStore/MemoryStore, `game.JobId`, `task`) and is **never
  required under Lune** — the T0.5 require gate treats it like the other Roblox-only entrypoints
  (reachable, not require-executed). MockStore stays the Tier-1 fixture → **all 313 tests untouched.**
- A published-place playtest without Studio API access falls back to MockStore (in-memory, honest — the
  builder sees data not persisting rather than a hard error). This is the *only* wiring change; verify
  `DataService` never references `MockStore` directly (confirmed: injected `store: StoreLike`).

## 7. BindToClose — global write budget, concurrent staggered flush (M5)

The reviewer's M5: `writeMinIntervalSeconds` is **per-key** (different players are different keys → they
do NOT throttle each other), so it does not bound the shutdown burst; the binding constraint is the
**global DataStore write budget** (~`60 + 10·players` writes/min), which the design must model. `Stop`'s
sequential loop behind a 6s per-key floor flushes only ~5 players in the ~30s window and **silently drops
the rest**. Correct strategy: flush **concurrently across keys** (each key writes once), **rate-limited to
the global budget** via a shared token bucket, each save keeping its retry budget inside the window; any
that exhaust are logged data-loss-risk. This needs a **global write-rate limiter** in SessionStore + a
`Stop` that dispatches concurrently rather than serially. **Decision D8.**

## 8. Config additions (append-only, server-side, never in `clientSubset`)

```
dataStore = {
  maxRetries, retryBaseSeconds, writeMinIntervalSeconds,   -- existing
  lockTtlSeconds          = 30,    -- [B2] MemoryStore lock TTL (auto-expiry = crash-safe steal)
  heartbeatIntervalSeconds= 15,    -- [B2] TTL renew (= lockTtl/2, beats the TTL under jitter)
  autosaveIntervalSeconds = 60,    -- [B2] periodic DataStore flush (0 = save-on-release-only)
  sessionLockedWaitSeconds= 40,    -- [B2] load's SessionLocked-specific wait budget (>= lockTtl; H1)
  globalWritesPerMinute   = 60,    -- [B2] shutdown/steady global write budget (D8)
}
```

## 9. LockStolen / zombie handling — the owned `DataService` change (H2 + M4)

The reviewer's H2/M4: `saveSession` retries **any** non-ok up to `maxRetries`, so a **permanent**
`LockStolen` burns ~10s of pointless retries and is mis-logged as transient; during `Stop` that starves
other flushes. And because `update` is in-memory, a stolen-from server keeps serving `get`/`update`
**successfully** until a heartbeat/save notices — the player keeps accruing progress that **can never
persist**. So the honest design **owns these bounded `DataService` changes**:
- `saveSession`/`Stop`: treat `LockStolen` as **terminal** — do not retry, mark the session **dead**,
  stop its heartbeat, and stop serving `update`/`get` for it (return `NoData`/a dead-session code).
- A new **dead-session state**: once `LockStolen` is seen, the in-memory delta is unrecoverable; the
  authoritative data lives on the new owner.
- **Decision D7 — the connected player:** kick (clean: "rejoin to sync", forces a load on the
  authoritative server) vs a write-rejecting read-only session (avoids a kick but silently loses the
  delta + confuses the player). Recommend **kick** with a clear message — it is honest and recovers
  cleanly; guard against a kick-loop (the new owner holds the lock, so the rejoin loads fine).

## 10. Receipts — the SessionStore contract must support save-before-ack (M6)

`ProcessReceipt` (the monetization slice, not this piece) MUST NOT ride the autosave crash window: a grant
that `update`s the ledger+currency in-memory then returns `PurchaseGranted` before the next autosave is
**lost on crash while Roblox considers it delivered** → the player paid and got nothing. The rule (stated
now so `Receipts.luau` is built against it): the receipt handler does the grant in ONE `update` (ledger +
currency atomic), then **forces a confirmed `save()`** and only returns `Granted` on `save().ok`; on
`LockStolen`/Err it returns `NotProcessedYet` (Roblox redelivers). SessionStore already provides the
synchronous confirmed `save()` this needs — no contract change, but it must be documented as load-bearing.

## 11. Verification story (the T1-policy / T2-reality split — `docs/VERIFICATION-LADDER.md`)

- **Tier-1 (Lune, via MockStore) — POLICY:** the `SessionLocked` **wait budget incl. the exhaustion→kick
  path** (H1 — currently *untested*; `data.spec`'s `lockingStore` only returns `SessionLocked` twice then
  succeeds, so the kick path is unexercised), the terminal-`LockStolen` reaction + dead-session teardown
  (H2/D7), the global-budget staggered `Stop` (M5), and the §9.3 FIFO race. **Decision D6:** add MockStore
  hooks — `returnSessionLocked: number?` (first N loads `SessionLocked`), `stealLockAfter: number?` (a
  save returns `LockStolen`) — so all three reactions are Tier-1-**falsify-first** without a real store.
- **Tier-2 (in-engine, Open Cloud / Studio) — REALITY Lune cannot see:** real `UpdateAsync` atomicity +
  budget, data **persisting across a rejoin**, a **receipt not re-granted after a restart** (the point),
  **cross-server contention** (2 servers, one player → one writer; expiry-steal), and MemoryStore TTL
  behavior. Needs the `smoke-gate.js` T2 lane + a 2-server harness → **blocked-on-human** until Studio/Open
  Cloud is live. Until then SessionStore ships `verified-local-T1 (policy only, store behavior NOT
  engine-verified)` — the honest ladder label.

## 12. Risks + honest limits

- **UpdateAsync transform footgun (L9):** the engine may invoke the transform **multiple times**
  (optimistic-concurrency retry) and forbids yielding inside it. The `load`/`save` transforms must be
  **pure + non-yielding + side-effect-free** — `default() = Migrations.default(clock:unix())` inside the
  transform is fine (pure), but **no** analytics/counter increments inside a store transform.
- **`isLocked` (L10)** is **local** ("do I hold this session in memory?"), never a DataStore read
  (budget + wrong cross-server semantics). `economy_race.spec` asserts true-after-load / false-after-release.
- **Re-entrant same-server load (L11):** the `myId`-re-claim path must **tear down the prior in-memory
  session first** (flush-or-discard its delta, stop its heartbeat) so one key never has two live sessions.
- **MemoryStore evaporation (D1c):** the DataStore `lockId` stamp (§4.2) is why an evaporated MemoryStore
  lock is still safe — worst case a brief contention window, never a double-write.
- **Crash data-loss window** = up to `autosaveIntervalSeconds` of non-money progress; money is protected
  by §10 save-before-ack. **Envelope migration (L13):** `metaVersion` has no v2 path yet — deferred, noted.
- **Does NOT contain `ProcessReceipt`** — it makes the ledger *durable*; the idempotent handler is the
  monetization slice this unblocks.

## 13. Decisions for the human checkpoint

> **All eight APPROVED as recommended by the human, 2026-07-25.** D1 = (a) MemoryStore TTL +
> DataStore data + lockId stamp; D3/D5 = the 30/15/60/40s defaults + periodic autosave; D7 = kick
> with a "rejoin to sync" message; D2/D4/D6/D8 accepted as written.

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Lock substrate: MemoryStore-TTL+DataStore / DataStore-only / MemoryStore risks | **(a) MemoryStore TTL + DataStore data + lockId stamp** — dissolves the crash-rejoin kick-loop (H1) |
| **D2** | `lockId` source | `game.JobId` (verify) + a Studio-solo GUID fallback |
| **D3** | `LOCK_TTL` / heartbeat / autosave / `sessionLockedWait` timings — **own the crash-availability vs false-steal tension** | 30 / 15 / 60 / 40s; `heartbeat + retry-jitter < LOCK_TTL`; `sessionLockedWait ≥ LOCK_TTL` |
| **D4** | `LockStolen` = terminal (no retry) + dead-session teardown in `DataService` | Yes — own the bounded DataService change (not "zero-change") |
| **D5** | Write cadence | periodic autosave (DataStore) + separate TTL heartbeat (MemoryStore) |
| **D6** | MockStore Tier-1 hooks (`returnSessionLocked`, `stealLockAfter`) + **test the H1 exhaustion→kick path** | Add both hooks + the kick-path test |
| **D7** | The zombie's **connected player**: kick vs read-only | **Kick** with a "rejoin to sync" message (kick-loop-safe) |
| **D8** | **Global** write-budget limiter + concurrent staggered `Stop` (per-key floor ≠ global budget) | Add a shared token bucket; `Stop` dispatches concurrently within budget |

## 14. Build order (after approval)

1. **Config** append the tunables (no migration; server-side). 2. **MockStore** add the D6 hooks + their
Tier-1 tests, falsify-first (prove the `SessionLocked` exhaustion→kick + the terminal-`LockStolen`
teardown RED before the handling exists). 3. **`DataService`** the owned changes (§9): `SessionLocked`
wait budget, terminal `LockStolen`, dead-session state, the D7 player handling — with tests. 4.
**`SessionStore.luau`** implement §3–§7 + §4 (Roblox-only, behind the §6 capability guard) + the global
write limiter (D8). 5. **`Context.build`** the capability-guarded store pick (§6) — re-run the gauntlet
(still 313/313 under Lune). 6. **T2 smoke** (`smoke-gate.js` + a 2-server harness): persist-across-rejoin,
receipt-not-re-granted, cross-server single-writer, crash-rejoin availability — the reality Lune can't
see. Then the **monetization** slice (`Receipts.luau`, §10) rides the now-durable ledger.

## 15. Related

`docs/CORE-DESIGN.md` §4 · `core/src/server/data/*` · `docs/VERIFICATION-LADDER.md` (the T1/T2 split) ·
`docs/LEARNINGS.md` §2 + §3 (the restart-data-loss + receipt-re-grant classes) · `FACTORY.md` §10.
