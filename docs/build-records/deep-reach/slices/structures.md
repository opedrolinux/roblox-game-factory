# Spec slice — structures (StructuresShopService)

Generated from plan.json features[name="structures"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Structures shop** — server-validated purchases (drone count, conveyor speed, smelter capacity, hull rating); each purchase persisted **and reflected in the running income rate**; shop UI."

CORE LOOP (verbatim, step 4): "Spend Credits on more drones / a faster conveyor / a bigger smelter → income rises."

ECONOMY (verbatim): "Sinks: drones, conveyor speed, smelter capacity, hull-pressure rating, depth unlocks, resurface." (You own drones, conveyor speed, smelter capacity and hull rating. Depth unlocks belong to Depth tiers; resurface belongs to Resurface/prestige.)

LONG GAME (verbatim, the portion you own): "...**resurface** → Pearls → permanent income multipliers + **Pearl-only drones**." You own the Pearl-only drone CATALOG ENTRY (priced in currencies.Pearls). Resurface owns minting Pearls and the permanent multiplier.

WHAT THIS SLICE OWNS
- THE CATALOG, server-owned: `drones` (count), `conveyor` (speed level), `smelter` (capacity level), `hull` (pressure rating) — all priced in Credits — and `pearlDrones`, priced in Pearls. Prices are a server-derived cost curve with a max level; the client NEVER sends a price, only a catalog key.
- `structures.buy`: validate type + range + rate + that the key is in the catalog, then in ONE DataService:update read the level, derive the cost, debit through ctx.economy:spend (Err(Insufficient) if short, never a negative balance, emits currency_spent) and write `upgrades.<key> += 1`. Never read-then-write across a yield. Spam-duplicated and interleaved buys must never double-spend or grant two levels for one debit.
- `structures.fetch`: the catalog with server-derived NEXT-LEVEL prices plus this player's levels, so the shop UI holds no price constants of its own.
- NO PURCHASABLE SHIPS INERT. Each catalog entry must be proven by a DELTA ON A RUNNING SERVER-DERIVED VALUE, not by a persisted field changing: `drones`, `conveyor` and `pearlDrones` must each measurably raise the value `ctx.salvage:rateFor` returns; `smelter` must measurably raise `ctx.salvage:capacityFor` (and therefore the offline cap); `hull` must measurably change the outcome of the Depth pressure gate (it does not touch income — that is its whole point, and it is still forbidden to ship inert).
- The shop UI: a greybox in-world kiosk plus a client panel listing entries, server-fetched prices, owned levels and affordability. Fetches through the shared JoinRetry guard. No client-side price or level authority.

NOT THIS SLICE: the income rate function or the tick (Salvage core owns both — you write the upgrades keys it reads); the depth unlock cost or gate (Depth tiers); minting Pearls or the prestige multiplier (Resurface); gamepass or dev-product purchases (Monetization).

CANONICAL KEYS (registered by the contract pass so parallel features agree): upgrades.drones, upgrades.conveyor, upgrades.smelter, upgrades.hull, upgrades.pearlDrones. Note that resurface wipes every one of these EXCEPT upgrades.pearlDrones.

## Success criteria this slice is graded against

- **Purchased structures actually change the income rate** — every purchasable is asserted by a **delta on the running rate**, not by a persisted field changing. *(This is the written-never-read pattern that produced 26 of collect-sim's 66 defects — no purchasable ships inert.)*
- **Economy is concurrency-safe** — interleaved / spam-duplicated buy + descend + resurface never double-spend Credits or dupe Pearls (race test on the shared balance).
- **Core analytics events fire** — `session_start`/`session_end`, `loop_completed`, `currency_earned` (smelt), `currency_spent` (structure), `progression` (depth unlock / resurface), `purchase`.
- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
