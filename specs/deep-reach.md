# Spec: Deep Reach  (codename: abyss)

> Second game through the factory — chosen as the **factory's own acceptance test**: a tycoon reuses
> `core/`'s economy + persistence spine but forces a genuinely new data shape (per-player plot
> ownership, purchased-structure state, continuous accrual instead of discrete pickups). If game #2 is
> cheap, the factory's reuse claim is real. **The theme below is a proposal — confirm or swap before
> `build-game`.**

## One-line pitch
An abyssal salvage tycoon: claim a pressure-dome on the sea floor, buy drones that haul wreck
fragments to your smelter, and push your dome deeper into the trench where the salvage is richer and
the pressure will crush anything you haven't upgraded.

## Genre & references
Tycoon (the *loop* of Miner's Haven / classic dropper-conveyor tycoons, not their content). Familiar
loop, fresh skin. The depth axis replaces the usual flat plot expansion, so progression is **legible
from across the map** — a deeper dome is visibly deeper.

## Core loop (first 60s, then forever)
1. Join → a free dome plot is claimed for you at Depth 1 and its pad lights up.
2. Buy a **salvage drone** (dropper) → it hauls wreck fragments along your conveyor to the smelter.
3. The smelter converts fragments → **Credits**, continuously, while you stand there or not.
4. Spend Credits on more drones / a faster conveyor / a bigger smelter → income rises.
5. Buy the **Depth unlock** → the whole dome descends to a richer trench tier → repeat →
   **resurface** (prestige) for permanent multipliers.
- **Loop completable in:** ~90s to first Credits; first Depth unlock ~10-15 min.

## Progression & economy
- Currencies: **Credits** (soft, primary), **Pearls** (prestige currency, from resurfacing).
- Sources: drone salvage (rate scales with depth tier), offline accrual, daily supply drop.
- Sinks: drones, conveyor speed, smelter capacity, hull-pressure rating, depth unlocks, resurface.
- Long game: 5 depth tiers, then **resurface** → Pearls → permanent income multipliers +
  Pearl-only drones.
- **Pressure gate:** each depth tier requires a minimum hull rating, so depth cannot be bought purely
  with income — it needs the upgrade *and* the Credits. (This is the one rule that stops a rich player
  skipping the middle game.)

## Re-entry hooks
- **Offline accrual**: drones keep salvaging while away, capped by smelter capacity, claimed on join.
  *(Capped by capacity, deliberately: it makes the capacity upgrade matter and bounds the exploit.)*
- **Daily supply drop**: escalating reward on a 20-22h claim window + HUD badge.
- **Restock**: a daily **rich wreck** that spawns in one trench tier and resets each day.

## Monetization (launch set)
- Gamepasses: **2x Credits**, **Auto-Collect** (smelter never needs a manual empty), **VIP trench**
  (an exclusive depth tier). Ownership is **granted server-side** — checked on join via
  `UserOwnsGamePassAsync` and on a fresh purchase via `PromptGamePassPurchaseFinished` — and recorded
  as persisted `flags['gamepass.*']` booleans that gate each effect (never set from a client action).
- Dev products: Credit packs (S/M/L), a 30-min **2x boost** — **persisted** (the expiry survives a
  crash/rejoin, not session-only), stamped atomically with the idempotent receipt ledger.

## Features (fan-out list — each = one parallel subagent, built against the shared contracts)
- [ ] **Plot ownership** — claim a free dome on join, persist which plot, release cleanly on leave, and
      refuse a second claim. *(contract-defining; built in the serial contract pass + first.)*
- [ ] **Salvage core** — drones, the conveyor path, and the smelter converting fragments → Credits on a
      server-authoritative tick. *(contract-defining; built with plot ownership.)*
- [ ] **Structures shop** — server-validated purchases (drone count, conveyor speed, smelter capacity,
      hull rating); each purchase persisted **and reflected in the running income rate**; shop UI.
- [ ] **Depth tiers** — 5 trench tiers gated by Credits **and** hull rating; the dome visibly descends;
      per-tier salvage value.
- [ ] **Resurface/prestige** — reset structures for Pearls + a permanent multiplier; count persisted.
- [ ] **Offline accrual** — accrue since last logout, capped by smelter capacity, claim-on-join flow.
- [ ] **Daily supply drop** — claim cooldown, streak counter, HUD badge.
- [ ] **Leaderboard** — top players by lifetime Credits (in-world GUI).
- [ ] **Monetization** — gamepass checks (2x / auto-collect / VIP trench) + dev-product receipts.

## Art / assets posture
100% greybox-in-code for v1: domes = Parts + transparency, drones = small Parts on TweenService paths,
conveyors/smelter = Parts, trench tiers = stacked Part shells at descending Y. No external assets in v1.

## Theme & tone
Quiet, high-pressure, industrial-deep-sea. Bioluminescent accents against dark water. Original — no
copyrighted characters, names, or audio.

## Out of scope (v1)
Trading, multiplayer co-op on one plot, PvP, custom meshes/animations, group/clan systems, vehicles.

## Success criteria (the done-condition the `/goal` grader checks)
- [ ] **Core loop completable end-to-end** — join → plot claimed → buy drone → smelter yields Credits →
      buy an upgrade → unlock Depth 2 → resurface for Pearls; an integration test traverses
      claim→salvage→buy→descend→resurface and emits `loop_completed`.
- [ ] **Plot ownership is exclusive and released** — a player gets exactly one plot; a second claim is
      refused; the plot is freed on leave and re-claimable by the next player (test covers rejoin and
      the leave→claim race).
- [ ] **Purchased structures actually change the income rate** — every purchasable is asserted by a
      **delta on the running rate**, not by a persisted field changing. *(This is the written-never-read
      pattern that produced 26 of collect-sim's 66 defects — no purchasable ships inert.)*
- [ ] **The pressure gate holds** — a depth tier cannot be entered with Credits alone below the required
      hull rating, and cannot be bypassed by re-ordering purchases.
- [ ] **Economy is concurrency-safe** — interleaved / spam-duplicated buy + descend + resurface never
      double-spend Credits or dupe Pearls (race test on the shared balance).
- [ ] **Monetization wired + idempotent** — 2x Credits, Auto-Collect and VIP-trench gamepasses gate their
      effects, ownership GRANTED server-side (`UserOwnsGamePassAsync` on join +
      `PromptGamePassPurchaseFinished` on purchase) into persisted `flags['gamepass.*']`; Credit packs +
      the 30-min 2x boost (persisted expiry, survives rejoin) grant via idempotent `ProcessReceipt`.
- [ ] **Re-entry hooks work** — offline accrual is capped by smelter capacity and claimed on join
      **without racing session load**; the daily drop claims in a 20–22h window with the HUD badge; the
      rich wreck resets — all on server time.
- [ ] **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`,
      `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface),
      `purchase`.
- [ ] **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time
      forgery, depth-gate bypass, receipt replay).
- [ ] **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates
      green.
