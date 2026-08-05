// amend.js — the orchestrator's adjudication of the decompose skeptic's findings.
// Every amendment is traceable to one skeptic finding. Nothing is invented; where the skeptic found
// an UNDECIDED question (boostExpiresUnix across a resurface) the orchestrator DECIDES and writes
// the decision into BOTH affected slices, so neither builder has to observe the other.
const fs = require('fs')
const r = JSON.parse(fs.readFileSync('logs/deep-reach/decompose.json', 'utf8'))
const plan = r.plan
const applied = []
const f = (name) => {
  const x = plan.features.find((y) => y.name === name)
  if (!x) throw new Error(`no feature ${name}`)
  return x
}
const append = (name, text, id) => {
  f(name).specSlice += `\n\n${text}`
  applied.push(`${id} -> ${name}.specSlice`)
}

// --- A1: overlap(plot, depth) — the dome's placement on a REJOIN belonged to neither slice, so
// "the dome visibly descends" was right on descend and wrong on every rejoin.
append(
  'plot',
  `ORCHESTRATOR AMENDMENT A1 (resolves an overlap the plan left unowned). PLACEMENT AT THE PERSISTED TIER IS YOURS. You place the dome root at claim time — on a FIRST claim AND on every rejoin — at the Y of the player's PERSISTED tier, by reading the nil-safe seam \`ctx.depth:tierYFor(data) -> number\` (when Depth tiers is not yet built the seam is absent and you default to tier 1's Y, which is exactly the fresh-player case). A returning player whose persisted tier is 4 must find their dome at tier 4's Y on join, NOT at Depth 1. Depth tiers owns MOVING the root on a successful descend; you own where it STARTS. The authoritative fact is the persisted tier; the world position is derived from it, never the reverse.`,
  'A1'
)
append(
  'depth',
  `ORCHESTRATOR AMENDMENT A1 (resolves an overlap the plan left unowned). You PROVIDE \`ctx.depth:tierYFor(data) -> number\` (the world Y for the player's persisted tier), which PlotService reads at claim time so a returning player's dome is placed at their persisted tier rather than at Depth 1. You MOVE the root only on a successful descend. Between you, every path that positions a dome is owned: claim/rejoin = plot, descend = depth.`,
  'A1'
)

// --- A2: overlap(salvage, monetization) — the auto-collect grant could be written twice, and a
// second copy is exactly where the lifetime increment and the earn emit get skipped.
append(
  'salvage',
  `ORCHESTRATOR AMENDMENT A2 (resolves a build-twice overlap). AUTO-COLLECT IS ONE GRANT PATH, NOT TWO. Implement the collect grant ONCE, as a single internal function, and have BOTH \`salvage.collect\` and the auto-collect tick call it — so the lifetime-counter increment and the currency_earned emit physically cannot be skipped on one of the two triggers. You build this path now, with \`flags["gamepass.autoCollect"]\` permanently false (Monetization lands later); it must be correct and dormant, not absent. Monetization only SETS that flag — it must never implement a second collect.`,
  'A2'
)
append(
  'monetization',
  `ORCHESTRATOR AMENDMENT A2 (resolves a build-twice overlap). AUTO-COLLECT: you GRANT the flag and your gate ASSERTS the effect lands. SalvageService already implements the auto-collect grant as ONE shared path. Do NOT write a second collect path — a second path is where the lifetime counter and the currency_earned emit get skipped.`,
  'A2'
)

// --- A3: missing-delta — `Rejected` is ALREADY the panic code. Verified in the real scaffold:
// Net.luau:152 returns Result.Codes.Rejected("client writes rejected (panic)"); Result.luau:15
// documents it as the panic flag.
plan.contractDeltas.resultCodes.push({
  name: 'AlreadyClaimed',
  feature: 'plot',
  why: 'The plan refused a second plot claim with Rejected, but this spine already uses Rejected as the PANIC flag — Net.dispatch returns exactly Result.Codes.Rejected("client writes rejected (panic)") at Net.luau:152, and Result.luau:15 documents it as such. The success criterion "a second claim is refused" would then be byte-indistinguishable from "the server is panicked and refusing all client writes". Verified against the real scaffold before adding this code.',
})
const plotSlice = f('plot')
const before = plotSlice.specSlice
plotSlice.specSlice = plotSlice.specSlice.replace(
  'returns Err(Rejected)',
  'returns Err(AlreadyClaimed) — NOT Err(Rejected), which this spine already uses for the panic flag (Net.luau:152), and which would make "a second claim is refused" indistinguishable from "the server is panicked"'
)
if (before === plotSlice.specSlice) throw new Error('A3: the Err(Rejected) retarget did not apply — check the slice text')
applied.push('A3 -> resultCodes += AlreadyClaimed; plot.specSlice retargeted off Rejected')

// --- A4: missing-delta — PlayerView.stats is a NARROW fixed record (Types.luau:48). toView copies
// data.stats wholesale so the VALUE arrives, but the TYPE does not admit the new field.
plan.contractDeltas.typesFields
  .filter((t) => t.field === 'stats.lifetimeCredits')
  .forEach((t) => {
    t.why = `${t.why || ''} AMENDMENT A4: PlayerView.stats is a NARROW fixed record — Types.luau:48 declares stats: { playtimeSeconds: number, joinCount: number }. toView copies data.stats wholesale so the VALUE arrives, but a client reading view.stats.lifetimeCredits is a --!strict property error, and the widened PlayerData.stats may not satisfy the narrower PlayerView.stats annotation. The contract pass MUST widen PlayerView.stats too — widening PlayerData.stats alone ships a leaderboard that cannot read its own ranking key.`.trim()
  })
const typesRetro = plan.contractPassExtras.retrofits.find((x) => /Types\.luau/.test(x.file))
if (!typesRetro) throw new Error('A4: no Types.luau retrofit found to amend')
typesRetro.change +=
  ' AMENDMENT A4: ALSO widen PlayerView.stats to { playtimeSeconds: number, joinCount: number, lifetimeCredits: number } — toView copying stats wholesale delivers the VALUE but not the TYPE, and PlayerView.stats is a narrow fixed record at Types.luau:48.'
applied.push('A4 -> typesFields.why + Types retrofit: widen PlayerView.stats')

// --- A5: missing-delta — the claim-on-join popup must DISPLAY the pending amount before claiming,
// but that amount is server memory (not persisted, so not in PlayerView) and only `offline.claim`
// was declared. There was no read surface at all.
plan.contractDeltas.netActions.push({
  key: 'FetchOffline',
  value: 'offline.peek',
  feature: 'offline',
  comment:
    'AMENDMENT A5 [offline] read the PENDING away-accrual grant (amount + whether it was capped) WITHOUT claiming it, so the claim-on-join popup can show it. The pending amount lives in server memory, not in PlayerData, so it is not in PlayerView and had no read surface at all. Peeking must be SIDE-EFFECT FREE: it never grants, never clears the pending amount, and never re-stamps the away window. JoinRetry-guarded on the client.',
})
append(
  'offline',
  `ORCHESTRATOR AMENDMENT A5 (adds the read surface the popup needed). Your slice requires a claim-on-join popup that SHOWS the amount and whether it was capped BEFORE the player claims — but the pending amount is held in server memory, is not persisted, and is therefore absent from PlayerView, so \`offline.claim\` alone gave the client nothing to display. You now also own \`offline.peek\`: it returns { amount, capped } for the pending grant and is SIDE-EFFECT FREE — it must not grant, must not clear the pending amount, and must not re-stamp the away window. Peek-then-claim must grant exactly the peeked amount, exactly once; peek-peek-claim must grant the same amount once.`,
  'A5'
)

// --- A6: the orchestrator DECIDES an undefined case on a REAL-MONEY field. The skeptic found
// boostExpiresUnix in neither resurface's survive-list nor its wipe-list, with both features
// scheduled in the SAME parallel batch, mutually invisible.
append(
  'resurface',
  `ORCHESTRATOR AMENDMENT A6 (decides an undefined case on a REAL-MONEY field). \`boostExpiresUnix\` SURVIVES a resurface, untouched — add it to your survive-list explicitly. RATIONALE: it is the expiry of a 30-minute 2x boost bought with real money, and the spec requires that expiry to survive a crash/rejoin; a voluntary prestige confiscating paid time the player has not yet spent is a refund request, not a game mechanic. Your slice previously listed it in NEITHER the survive-list nor the wipe-list, leaving a paid field's reset semantics undefined. Your survive-list is therefore: resurfaces, currencies.Pearls, upgrades.pearlDrones, stats.lifetimeCredits, daily, plot, flags, receipts, AND boostExpiresUnix.`,
  'A6'
)
append(
  'monetization',
  `ORCHESTRATOR AMENDMENT A6 (decides an undefined case on YOUR real-money field). \`boostExpiresUnix\` — the persisted expiry of the 30-minute 2x boost — SURVIVES a resurface untouched. ResurfaceService has been told exactly the same thing, so neither of you needs to observe the other. Your gate should assert it: a boost bought, then a resurface performed, must leave the remaining boost time intact AND still multiplying the running rate.`,
  'A6'
)

// --- A7: uncovered spec item — the restock was reduced to an integer multiplier, but the spec says
// the rich wreck SPAWNS. An integer flipping is the written-never-read shape this game is graded on.
append(
  'depth',
  `ORCHESTRATOR AMENDMENT A7 (covers a spec item the plan reduced to a number). THE RICH WRECK IS A REAL OBJECT, not merely a multiplier. The spec says it "**spawns** in one trench tier and resets each day". Build it as a greybox Part placed in today's restock tier, and CLEAR/RE-PLACE it on the day rollover. The success criterion "the rich wreck resets" must be provable by the wreck's presence/position CHANGING between two server-days — not by an integer flipping, which is exactly the written-never-read shape this game is graded against. The value multiplier it carries still rides your single \`valueMultiplier\` seam.`,
  'A7'
)

// --- A8 / A11: unowned spec items recorded in planNotes.
plan.planNotes += `

ORCHESTRATOR AMENDMENT A8 (assigns an unowned spec number). PACING TARGETS — spec line 26: "~90s to first Credits; first Depth unlock ~10-15 min". No feature slice can own this: salvage owns the base rate, structures its cost curve, depth its tier costs — three numeric tables built in three different batches, and only their COMPOSITION is the player's experience. It is therefore assigned to the INTEGRATION GATE as an explicit, COARSE assertion: from a fresh player at the starting structure set, time-to-first-Credits and time-to-afford-Depth-2 must both land inside a generous band around the spec's targets (an order-of-magnitude check, never a tuned equality). A composed result 10x off is a real defect no per-feature gate can see; the exact numbers are a human tuning judgment at the playtest, and the handoff note must say so rather than implying an offline rung tuned them.

ORCHESTRATOR AMENDMENT A11 (states owners the plan left implicit). The two WHOLE-GAME success criteria own no feature slice by design: "an integration test traverses claim->salvage->buy->descend->resurface and emits loop_completed" is owned by the integration-gate workflow, and "No open exploit — adversarial pass clean" is owned by the adversarial-review workflow. Recorded because an unstated owner for a literal success criterion is how a criterion goes unrun. NOTE FOR THE GATE: loop_completed fires at the FIRST successful descend, which is one step BEFORE the traversal's end — the traversal continues on to resurface, so the gate must observe the event at the descend and keep going, not expect it at the final step.`
applied.push('A8/A11 -> planNotes: pacing assigned to the integration gate; whole-game criteria owners named')

// --- A9: dependency under-declaration. Batch order happened to cover these, but the DECLARED graph
// was wrong, so a feature gate could be authored against a capacity/price that never moves.
f('offline').dependsOn = ['salvage', 'structures']
f('monetization').dependsOn = ['salvage', 'structures', 'depth']
// --- A6 (cont.): declaring the resurface->monetization edge forces them into different batches,
// which is the point — the plan had them parallel and mutually blind on a real-money question.
f('resurface').dependsOn = ['salvage', 'structures', 'depth', 'monetization']
plan.buildBatches = [['plot', 'daily', 'leaderboard'], ['salvage'], ['structures'], ['depth', 'offline'], ['monetization'], ['resurface']]
applied.push('A9 -> dependsOn corrected (offline+structures, monetization+structures, resurface+monetization)')
applied.push('A6 -> batches split: monetization (batch 5) now precedes resurface (batch 6); they were parallel')

// --- A10: contract-pass obligations the skeptic surfaced that no feature slice can own.
plan.contractPassExtras.retrofits.push(
  {
    file: 'games/deep-reach/src/server/services/sample/SampleService.luau',
    change:
      'AMENDMENT A10a: DELETE the sample service AND src/client/controllers/sample/, tests/unit/sample.spec.luau, and the Net.Actions.Sample key, IN THIS PASS (the plan had deferred this to later build-game work). Then remove ./unit/sample.spec from tests/run.luau SPEC_PATHS.',
    why: 'SampleAction writes currencies.Stardust directly and is client-callable. Left alive through batch 0 it mints a currency this game does not have into live blobs, straight past the economy single-writer path; and deleting Net.Actions.Sample later would be a SECOND shared-contract edit outside this guarded pass. Nothing depends on it, and the sample-removal finalization gate would refuse the handoff for it anyway.',
  },
  {
    file: 'games/deep-reach/src/server/init.server.luau',
    change:
      'AMENDMENT A10b: pin the PlayerRemoving hook ORDER explicitly, with a comment saying why: AnalyticsService session_end (needs the still-loaded blob) -> PlotService release (frees the dome) -> DataService session release (invalidates the blob).',
    why: 'Three features hook the same event and nobody owned the ordering. A session_end emitted AFTER the data-layer release reads NoData, so the event fires with an empty payload and the analytics success criterion passes vacuously. The ordering is load-bearing and no single feature builder can own it.',
  },
  {
    file: 'games/deep-reach/src/shared/Config.luau',
    change:
      'AMENDMENT A10c: add ONE shared server-day helper (dayIndex(nowUnix) = math.floor(nowUnix / 86400)) and document the two DIFFERENT time rules this game deliberately has: the daily supply drop uses a ROLLING 20-22h window measured off daily.lastClaimUnix (per the spec), while the restock rich wreck rotates on the ABSOLUTE server-day index.',
    why: 'Both spec bullets say "daily" and they are NOT the same rule. Two features will otherwise each invent a definition of a day, and the restock-resets test and the daily-window test will disagree about what a day is. Pinning one helper and naming the difference is far cheaper than reconciling two drifted clocks at the integration gate.',
  }
)
plan.contractPassExtras.sharedServices.push({
  name: 'hudroot',
  serviceName: 'HudRoot',
  kind: 'client-framework',
  purpose:
    'AMENDMENT A10d: the ONE shared client HUD root — a single ScreenGui plus a simple anchored slot layout every controller mounts into — standing beside JoinRetry in src/client/framework/. Seven feature controllers each say "client controller" and none owned a shared root; without this the merge produces seven overlapping full-screen GUIs, and a pile of stacked panels is the first thing the human sees. Each controller mounts its panel into a NAMED SLOT; no controller creates its own ScreenGui.',
})
// JoinRetry is a client framework module, not a server service — mark the kind so the mechanical
// PascalCase-ending-in-Service rule (correct for services) stops rejecting it.
const jr = plan.contractPassExtras.sharedServices.find((s) => s.name === 'joinretry')
if (jr) jr.kind = 'client-framework'
plan.planNotes += `

ORCHESTRATOR AMENDMENT A10 (contract-pass obligations no feature slice can own). Beyond the retrofits above: (e) \`structures.fetch\` MUST iterate the server-owned CATALOG, never the raw upgrades blob — the plan's own rationale for keeping timestamps out of the upgrades map depends on this, and enumerating the blob would expose upgrades.depth as purchasable. (f) Every service MUST register its actions as CLOSURES over service state inside Start(); the scaffold's SampleService registers a STATIC module table, which cannot reach service state — and offline's in-memory pending amount plus leaderboard's snapshot are exactly the state a static handler cannot see. Both are stated in the contract pass so nine builders do not each guess.`
applied.push('A10 -> sample deleted in-pass; PlayerRemoving order pinned; one day helper; HUD root; catalog-not-blob; closure handlers')

fs.writeFileSync('logs/deep-reach/amended-plan.json', JSON.stringify(plan, null, 2))
console.log('AMENDMENTS APPLIED:')
applied.forEach((a) => console.log('  - ' + a))
console.log('\nbatches:      ' + JSON.stringify(plan.buildBatches))
console.log('resultCodes:  ' + plan.contractDeltas.resultCodes.map((c) => c.name).join(', '))
console.log('netActions:   ' + plan.contractDeltas.netActions.length)
console.log('retrofits:    ' + plan.contractPassExtras.retrofits.length)
console.log('sharedSvcs:   ' + plan.contractPassExtras.sharedServices.map((s) => `${s.name}[${s.kind || 'service'}]`).join(', '))
