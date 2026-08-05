# Spec slice — monetization (MonetizationService)

Generated from plan.json features[name="monetization"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Monetization** — gamepass checks (2x / auto-collect / VIP trench) + dev-product receipts."

MONETIZATION (verbatim, in full): "Gamepasses: **2x Credits**, **Auto-Collect** (smelter never needs a manual empty), **VIP trench** (an exclusive depth tier). Ownership is **granted server-side** — checked on join via `UserOwnsGamePassAsync` and on a fresh purchase via `PromptGamePassPurchaseFinished` — and recorded as persisted `flags['gamepass.*']` booleans that gate each effect (never set from a client action)." / "Dev products: Credit packs (S/M/L), a 30-min **2x boost** — **persisted** (the expiry survives a crash/rejoin, not session-only), stamped atomically with the idempotent receipt ledger."

WHAT THIS SLICE OWNS
- GAMEPASS OWNERSHIP, GRANTED SERVER-SIDE ONLY. On join, `MarketplaceService:UserOwnsGamePassAsync` for each of the three passes; on a fresh purchase, `MarketplaceService.PromptGamePassPurchaseFinished`. Write the result into persisted `flags["gamepass.doubleCredits"]`, `flags["gamepass.autoCollect"]`, `flags["gamepass.vipTrench"]`. There is deliberately NO Net action for this — a client-settable gamepass flag is a free gamepass. Emit `purchase` on a false->true transition. Both API calls can throw/yield: pcall them, retry within budget, and never let a failed check clear an already-granted flag.
- THE EFFECTS ARE READ BY OTHER FEATURES, and your gate must prove each one actually lands: `doubleCredits` and the boost multiply the value `ctx.salvage:rateFor` returns; `autoCollect` makes Salvage core's tick empty the smelter with no manual collect; `vipTrench` is what lets Depth tiers enter the exclusive tier (Err(PrereqUnmet) without it). Assert each as a DELTA on the running rate / on the gate outcome — a flag written and never read is the exact defect class this game is graded against.
- DEV PRODUCTS via `MarketplaceService.ProcessReceipt`, IDEMPOTENTLY: Credit packs S/M/L (grant Credits through ctx.economy:earn, which increments stats.lifetimeCredits and emits currency_earned) and the 30-min 2x boost (set `boostExpiresUnix = ctx.clock:unix() + 1800`, EXTENDING from the later of now and the current expiry so a stacked purchase is never silently swallowed). The receipt id is recorded in the `receipts` ledger and the grant is applied in the SAME DataService:update — an already-present receipt id grants nothing and returns PurchaseGranted; ANY failure returns `Enum.ProductPurchaseDecision.NotProcessedYet`. Replaying the same receipt must never double-grant. Emit `purchase` after the grant commits.
- REAL MONEY GUARD: if `ctx.persistenceDegraded` is true (the server fell back to the in-memory store — the field already exists in Context.build), a successful save is NOT durability. Do not acknowledge a receipt as processed; return NotProcessedYet so Roblox re-delivers it to a healthy server.
- THE BOOST IS PERSISTED: `boostExpiresUnix` survives a crash/rejoin. Salvage core reads `now < data.boostExpiresUnix` straight off the blob, so there is no session-only state to lose and no seam to race.
- Client: purchase prompts (client-initiated MarketplaceService prompts are fine — the GRANT is server-side) and a HUD boost-remaining timer driven from the replicated PlayerView. Fetches through the shared JoinRetry guard.

NOT THIS SLICE: the rate formula or the smelter tick (Salvage core reads your flags); the depth gate (Depth tiers reads your VIP flag); the shop's Credits-priced catalog (Structures shop).

PERSISTENCE: `boostExpiresUnix: number` at schema v6->v7 (contract pass), plus the flags and receipts seams which already exist.

ORCHESTRATOR AMENDMENT A2 (resolves a build-twice overlap). AUTO-COLLECT: you GRANT the flag and your gate ASSERTS the effect lands. SalvageService already implements the auto-collect grant as ONE shared path. Do NOT write a second collect path — a second path is where the lifetime counter and the currency_earned emit get skipped.

ORCHESTRATOR AMENDMENT A6 (decides an undefined case on YOUR real-money field). `boostExpiresUnix` — the persisted expiry of the 30-minute 2x boost — SURVIVES a resurface untouched. ResurfaceService has been told exactly the same thing, so neither of you needs to observe the other. Your gate should assert it: a boost bought, then a resurface performed, must leave the remaining boost time intact AND still multiplying the running rate.

## Success criteria this slice is graded against

- **Monetization wired + idempotent** — 2x Credits, Auto-Collect and VIP-trench gamepasses gate their effects, ownership GRANTED server-side (`UserOwnsGamePassAsync` on join + `PromptGamePassPurchaseFinished` on purchase) into persisted `flags['gamepass.*']`; Credit packs + the 30-min 2x boost (persisted expiry, survives rejoin) grant via idempotent `ProcessReceipt`.
- **Purchased structures actually change the income rate** — every purchasable is asserted by a **delta on the running rate**, not by a persisted field changing. *(This is the written-never-read pattern that produced 26 of collect-sim's 66 defects — no purchasable ships inert.)*
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time forgery, depth-gate bypass, receipt replay).
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
