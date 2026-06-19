# Spec: <game name>

> A spec is the **input** to `build-game`. One page. It is the contract the factory builds to.
> Keep it concrete and loop-focused — vague specs produce vague games.

## One-line pitch
<familiar loop + fresh theme — the "MAYA twist". Never a 1:1 clone.>

## Genre & references
<e.g. collect simulator / tycoon / merge — and 1-2 reference games for the loop, not the art.>

## Core loop (what the player does in the first 60 seconds, then forever)
1. ...
2. ...
3. ...
- **Loop completable in:** <minutes>  (target <15 min; <5 for simulators)

## Progression & economy
- Currencies: ...
- Sources (how currency comes in): ...
- Sinks (what it's spent on — upgrades, unlocks, rebirth): ...
- The long game: <rebirth / prestige / zones / tiers>

## Re-entry hooks (why they come back tomorrow — the heaviest ranking signal)
- <offline earnings / daily streak / restock timers / be-online-to-claim>

## Monetization (launch with 2-3 gamepasses + 1-2 dev products)
- Gamepasses: <e.g. 2x cash, auto-collect, VIP area>
- Dev products: <e.g. cash packs, boosts>

## Features (the fan-out list — each becomes one parallel subagent)
Each must be independently buildable against the shared contracts: a set of server actions +
data fields + (optional) a UI component. Keep them disjoint.
- [ ] feature: ...
- [ ] feature: ...
- [ ] feature: ...

## Art / assets posture
<greybox-in-code first; what (if anything) needs Creator-Store assets or hero meshes>

## Theme & tone
<the fresh skin over the proven loop; IP-safe — no copyrighted characters/audio/names>

## Out of scope (v1)
<explicitly what we are NOT building yet>

## Success criteria (the done-condition the `/goal` grader checks)
> Objective, **checkable** conditions derived from THIS spec — what "done" means for this game. A
> fresh-model grader reads these against the built game + its test suite; each must be verifiable from
> evidence the pipeline produces (a test, a wired feature, a fired analytics event), not vibes.
- [ ] **Core loop completable end-to-end** — <name the spawn→earn→spend→progress path>; an integration
      test traverses it and emits `loop_completed`.
- [ ] **Economy is concurrency-safe** — no double-spend / currency dupe under interleaved or
      spam-duplicated requests (covered by a race test).
- [ ] **Monetization wired + idempotent** — <the launch gamepasses / dev-products> gate their features;
      `ProcessReceipt` is idempotent (no double-grant / loss).
- [ ] **Re-entry hooks work** — <offline earnings / daily streak / restock>: persist and claim correctly
      across a rejoin, on server time.
- [ ] **Core analytics events fire** — at minimum `session_start`, `session_end`, `loop_completed`,
      `currency_earned`, `currency_spent`, `purchase` (assert they emit).
- [ ] **No open exploit** — the adversarial pass found nothing unresolved.
- [ ] **Gauntlet green** — stylua · selene · rojo build · lune tests, and both test gates green.
