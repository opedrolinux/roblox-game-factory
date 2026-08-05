# Spec slice — offline (OfflineService)

Generated from plan.json features[name="offline"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Offline accrual** — accrue since last logout, capped by smelter capacity, claim-on-join flow."

RE-ENTRY HOOK (verbatim): "**Offline accrual**: drones keep salvaging while away, capped by smelter capacity, claimed on join. *(Capped by capacity, deliberately: it makes the capacity upgrade matter and bounds the exploit.)*"

ECONOMY (verbatim, the source line you own): "Sources: drone salvage (rate scales with depth tier), offline accrual, daily supply drop."

WHAT THIS SLICE OWNS
- THE AWAY WINDOW, and it is yours exclusively: `[timestamps.lastSeenUnix, ctx.clock:unix()]`. Salvage core stamps `smelter.lastTickUnix = now` at session load specifically so its online tick never re-counts this window — do not widen or re-stamp the window yourself, and do not touch smelter.storedCredits.
- The computation, at session load, from server state only: `min(ctx.salvage:rateFor(data) * awaySeconds, ctx.salvage:capacityFor(data))`. The cap IS the smelter capacity, so upgrading the smelter visibly raises the offline grant and an enormous away time cannot mint more than one smelter-full. Clamp awaySeconds at 0 for a negative/absurd delta (a clock skew must never mint).
- THE CLAIM FLOW: `offline.claim` grants the computed amount through ctx.economy:earn (increments stats.lifetimeCredits, emits currency_earned, source="offline") in ONE DataService:update. ONE-SHOT PER SESSION — a second or spam-duplicated claim grants 0, and the guard lives inside the same lock-held transform, not in a client flag.
- NO CLIENT TIME ANYWHERE. The payload carries no timestamp, no duration and no amount; a forged away time is one of the named exploits.
- CLAIM-ON-JOIN WITHOUT RACING SESSION LOAD. This is the single highest-risk wire in this game: a controller that calls the server from Start() races loadSession's yield, and the autosave then erases the away window, so the earnings are lost PERMANENTLY and no offline verification rung can see it. Compute server-side once the session's data is loaded, hold the pending amount, and have the client claim it through the shared JoinRetry guard.
- Client: the claim-on-join popup showing the amount, whether it was capped, and a claim button.

NOT THIS SLICE: the rate or capacity formulas (Salvage core — you call its seam); the smelter tick or storedCredits (Salvage core); the daily supply drop (Daily supply drop); the restock (Depth tiers).

PERSISTENCE: none of your own — you read the EXISTING `timestamps.lastSeenUnix` (already written by the data layer on save/release) and write only currencies.Credits + stats.lifetimeCredits through ctx.economy.

ORCHESTRATOR AMENDMENT A5 (adds the read surface the popup needed). Your slice requires a claim-on-join popup that SHOWS the amount and whether it was capped BEFORE the player claims — but the pending amount is held in server memory, is not persisted, and is therefore absent from PlayerView, so `offline.claim` alone gave the client nothing to display. You now also own `offline.peek`: it returns { amount, capped } for the pending grant and is SIDE-EFFECT FREE — it must not grant, must not clear the pending amount, and must not re-stamp the away window. Peek-then-claim must grant exactly the peeked amount, exactly once; peek-peek-claim must grant the same amount once.

## Success criteria this slice is graded against

- **Re-entry hooks work** — offline accrual is capped by smelter capacity and claimed on join **without racing session load**; the daily drop claims in a 20–22h window with the HUD badge; the rich wreck resets — all on server time.
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time forgery, depth-gate bypass, receipt replay).
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
