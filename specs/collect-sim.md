# Spec: Collect Simulator  (codename: stardust)

> First game through the factory — chosen as the fastest, most AI-friendly loop (systems + economy,
> almost no custom art). **The theme below is a proposal — confirm or swap before `build-game`.**

## One-line pitch
A collect-and-upgrade simulator on floating sky-islands: gather glowing stardust, refine it, buy
upgrades, climb to higher islands, rebirth for permanent multipliers.

## Genre & references
Collect/grind simulator (Bee Swarm / Pet Sim *loop*, not their content). Familiar loop, fresh skin.

## Core loop (first 60s, then forever)
1. Walk the starting island; glowing motes spawn around you and auto-collect into your backpack.
2. Backpack fills → return to the refiner pad → sell for **Stardust** (currency).
3. Spend Stardust on upgrades → collect faster / hold more / magnet wider / move faster.
4. Unlock the next island (rarer, richer motes) → repeat → **rebirth** for a permanent multiplier.
- **Loop completable in:** ~2-4 min for the first sell; full first-island clear ~15 min.

## Progression & economy
- Currencies: **Stardust** (soft, primary), **Prisms** (rebirth/prestige currency).
- Sources: motes collected (value scales by island), offline collectors, daily streak.
- Sinks: collect-speed / backpack / magnet-range / walk-speed upgrades; island unlocks; rebirth.
- Long game: 4-6 islands, then rebirth → Prisms → permanent multipliers + Prism-only upgrades.

## Re-entry hooks
- **Offline earnings**: passive collectors accrue capped Stardust while away, claimed on join.
- **Daily streak**: escalating reward with a 20-22h claim window + HUD badge.
- **Restock**: a daily "rich vein" island event that resets each day.

## Monetization (launch set)
- Gamepasses: **2x Stardust**, **Auto-Collect** (no walking needed), **VIP island** (exclusive zone).
  Ownership is **granted server-side** — checked on join via `UserOwnsGamePassAsync` and on a fresh
  purchase via `PromptGamePassPurchaseFinished` — and recorded as persisted `flags['gamepass.*']`
  booleans that gate each effect (never set from a client action).
- Dev products: Stardust packs (S/M/L), a 30-min **2x boost** — **persisted** (the boost expiry survives
  a crash/rejoin, not session-only), stamped atomically with the idempotent receipt ledger.

## Features (fan-out list — each = one parallel subagent, built against the shared contracts)
- [ ] **Collection core** — mote spawning per island, magnet/auto-collect, backpack capacity, sell-at-refiner → Stardust. *(contract-defining; built in the serial contract pass + first.)*
- [ ] **Upgrades shop** — server-validated purchases (collect speed, backpack, magnet, walk speed); persisted; shop UI.
- [ ] **Islands & unlocks** — multiple zones gated by Stardust, teleport pads, per-island mote value.
- [ ] **Rebirth/prestige** — reset for Prisms + permanent multiplier; rebirth count persisted.
- [ ] **Offline earnings** — accrue since last logout, capped, claim-on-join flow.
- [ ] **Daily streak** — claim cooldown, streak counter, HUD badge.
- [ ] **Leaderboard** — top players by lifetime Stardust (in-world GUI).
- [ ] **Monetization** — gamepass checks (2x / auto-collect / VIP) + dev-product receipts + analytics.

## Art / assets posture
100% greybox-in-code for v1: islands = Parts, motes = small Parts with material + PointLight,
refiner/teleport pads = Parts + UICorner/UIStroke billboards. No external assets in v1.

## Theme & tone
Calm, glowy, "cosmic gardener" vibe. Original — no copyrighted characters, names, or audio.

## Out of scope (v1)
Trading, pets/companions, PvP, custom meshes/animations, group/clan systems.

## Success criteria (the done-condition the `/goal` grader checks)
- [ ] **Core loop completable end-to-end** — walk island → motes auto-collect into backpack → sell at
      refiner for Stardust → buy an upgrade → unlock island 2 → rebirth for Prisms; an integration test
      traverses collect→sell→upgrade→unlock→rebirth and emits `loop_completed`.
- [ ] **Economy is concurrency-safe** — interleaved / spam-duplicated sell + buy + rebirth never
      double-spend Stardust or dupe Prisms (race test on the shared balance).
- [ ] **Monetization wired + idempotent** — 2x Stardust, Auto-Collect, and VIP-island gamepasses gate
      their effects, with ownership GRANTED server-side (`UserOwnsGamePassAsync` on join +
      `PromptGamePassPurchaseFinished` on purchase) into persisted `flags['gamepass.*']`; Stardust packs +
      the 30-min 2x boost (persisted expiry, survives rejoin) grant via idempotent `ProcessReceipt`.
- [ ] **Re-entry hooks work** — offline collectors accrue capped Stardust claimed on join; daily streak
      claims in a 20–22h window with the HUD badge; the daily rich-vein restock resets — all on server time.
- [ ] **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`,
      `currency_earned` (sell), `currency_spent` (upgrade), `progression` (island unlock / rebirth), `purchase`.
- [ ] **No open exploit** — adversarial pass clean (mote-value spoof, magnet-range abuse, offline-time
      forgery, receipt replay).
- [ ] **Gauntlet green** — stylua · selene · rojo · lune; per-feature + integration gates green.
