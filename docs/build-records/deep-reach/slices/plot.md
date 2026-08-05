# Spec slice — plot (PlotService)

Generated from plan.json features[name="plot"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Plot ownership** — claim a free dome on join, persist which plot, release cleanly on leave, and refuse a second claim. *(contract-defining; built in the serial contract pass + first.)*"

CORE LOOP, step 1 (verbatim): "Join → a free dome plot is claimed for you at Depth 1 and its pad lights up."

ART POSTURE (verbatim, the portion you own): "100% greybox-in-code for v1: domes = Parts + transparency ... No external assets in v1." You build the dome plots and their pads. (Drones/conveyors/smelter belong to Salvage core; the stacked trench shells at descending Y belong to Depth tiers.)

WHAT THIS SLICE OWNS
- A per-SERVER plot registry built at boot: a fixed set of dome plots, each free or held by exactly ONE UserId. Exclusivity is enforced entirely server-side.
- Claim on join: once the session's data has loaded, claim the first free plot, persist its id into PlayerData.plot ({ plotId, claimedAtUnix }, server clock), and light its pad. Claiming is idempotent within a session.
- Refuse a second claim: plot.claim from a player who already holds one returns Err(AlreadyClaimed) — NOT Err(Rejected), which this spine already uses for the panic flag (Net.luau:152), and which would make "a second claim is refused" indistinguishable from "the server is panicked". plot.claim when every plot is held returns Err(Unavailable). Never two players on one plot; never two plots for one player — including under interleaved and spam-duplicated claims arriving in the same frame.
- Release on leave: on PlayerRemoving / session release the plot is freed and is immediately re-claimable by the NEXT player. The leave→claim race must neither leak a plot forever nor hand one plot to two players.
- Rejoin: a returning player re-claims a free plot. A persisted plotId whose plot is already held on THIS server must not be honoured — re-claim a free one and rewrite the field.
- The ctx.plot seam every later feature builds on: plotIdFor(player) -> string?, rootFor(player) -> Instance? (the world root every structure parents under), ownerOf(plotId) -> number?. Salvage core parents the smelter/conveyor/drones under this root; Depth tiers moves this root down the Y axis.
- Actions: `plot.claim` — the payload carries NO plot id (the server picks; a client-named plot IS the plot-claim-hijack exploit) — and `plot.fetch` for the HUD/highlight.
- Client controller: highlight and label the local player's dome. Zero authority. It MUST fetch through the shared JoinRetry guard — a Start()-time fetch races loadSession's yield.

NOT THIS SLICE: income of any kind, drones, the conveyor, the smelter (Salvage core); descending the dome (Depth tiers); any currency mutation whatsoever.

PERSISTENCE: `plot: { plotId: string, claimedAtUnix: number }` at schema v2->v3. The contract pass writes the Types field, the migration step, the default seed and the toView line — you only read/write the field through DataService:update.

ORCHESTRATOR AMENDMENT A1 (resolves an overlap the plan left unowned). PLACEMENT AT THE PERSISTED TIER IS YOURS. You place the dome root at claim time — on a FIRST claim AND on every rejoin — at the Y of the player's PERSISTED tier, by reading the nil-safe seam `ctx.depth:tierYFor(data) -> number` (when Depth tiers is not yet built the seam is absent and you default to tier 1's Y, which is exactly the fresh-player case). A returning player whose persisted tier is 4 must find their dome at tier 4's Y on join, NOT at Depth 1. Depth tiers owns MOVING the root on a successful descend; you own where it STARTS. The authoritative fact is the persisted tier; the world position is derived from it, never the reverse.

## Success criteria this slice is graded against

- **Plot ownership is exclusive and released** — a player gets exactly one plot; a second claim is refused; the plot is freed on leave and re-claimable by the next player (test covers rejoin and the leave→claim race).
- **No open exploit** — adversarial pass clean (salvage-rate spoof, plot-claim hijack, offline-time forgery, depth-gate bypass, receipt replay).
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
