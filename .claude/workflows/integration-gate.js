// integration-gate.js — build-game Workflow B, step 3: the cross-feature integration gate.
//
// The per-feature gates prove each service in isolation; they CANNOT see cross-feature integration
// (the full core loop, the shared-balance race across DIFFERENT features, the join->claim lifecycle,
// the analytics taxonomy firing end-to-end, a multiplier seam actually reaching the Sell it feeds).
// This gate stands up the WHOLE game (the full bootstrap context, every service Started, all ctx
// seams wired) and authors FRESH integration tests from the spec's SUCCESS CRITERIA — the gradable
// done-conditions — then independently reviews them (maker != checker). A success criterion that does
// NOT hold is left RED and reported as an integration bug for the orchestrator to fix falsify-first
// (NOT patched here). Commits nothing; edits no src/ implementation.
//
// args (JSON): { gameDir, specPath, features:[names], successCriteria:[...] }

export const meta = {
  name: 'integration-gate',
  description: 'build-game Workflow B step 3: the cross-feature integration gate. Stands up the whole game (full bootstrap, every service + ctx seam) and authors fresh integration tests from the spec success criteria — the core-loop traversal emitting loop_completed, lifetime-on-all-earns-never-on-spend/reset, the shared-balance race across features, the offline leave->rejoin->claim lifecycle, the full analytics taxonomy, and that the island/2x/restock multipliers actually reach Sell. An independent coverage critic + integration red-team review it. A failing success criterion is left RED and reported as an integration bug to fix, not patched. Commits nothing.',
  phases: [
    { title: 'Author', detail: 'an independent agent stands up the whole game and writes integration tests from the spec success criteria; leaves a failing criterion RED' },
    { title: 'Review', detail: 'a coverage critic (all criteria covered?) + an integration red-team (cross-feature exploits the per-feature gates missed) in parallel' },
  ],
}

let input = args
if (typeof input === 'string') {
  try {
    input = JSON.parse(input)
  } catch (_e) {
    input = {}
  }
}
// No game defaults: silently gating the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
const specPath = input && input.specPath
if (!gameDir || !specPath) throw new Error('integration-gate: args must supply {gameDir, specPath}.')
const features = (input && input.features) || []
// GAME-AGNOSTIC: the cross-feature obligations below come from the approved plan, not from any
// one game's nouns. Each falls back to a spec-derived instruction when the caller omits it.
const coreLoop = (input && input.coreLoopSteps) || []
const seams = (input && input.seams) || [] // [{ name, consumer, effect }]
const lifetimeField = (input && input.lifetimeField) || ''
const earnPaths = (input && input.earnPaths) || []
const nonEarnPaths = (input && input.nonEarnPaths) || []
const analyticsEvents = (input && input.analyticsEvents) || []
const sharedBalance = (input && input.sharedBalance) || 'the shared soft-currency balance'
const reentry = (input && input.reentryHooks) || []
log(`integration-gate: ${gameDir}; whole-game cross-feature gate over [${features.join(', ')}]. Authors integration tests from the spec success criteria; reports failing criteria as integration bugs. Commits nothing.`)

const AUTHOR_SCHEMA = {
  type: 'object',
  properties: {
    specRelPath: { type: 'string', description: 'the integration spec file you created (e.g. tests/integration/coreloop.spec.luau)' },
    registered: { type: 'boolean', description: 'appended to tests/run.luau SPEC_PATHS?' },
    gauntletOk: { type: 'boolean', description: 'TRUE if the full gauntlet ends green WITH your tests (a RED integration bug you intentionally leave makes this false — that is OK, report it)' },
    luneResult: { type: 'string' },
    testCount: { type: 'number' },
    harnessNotes: { type: 'string', description: 'how you stood up the whole game in Tier-1 (which context builder / bootstrap / seams you wired, how you simulated the join/leave lifecycle)' },
    coveredCriteria: { type: 'array', items: { type: 'string' }, description: 'the spec success criteria you wrote genuine tests for' },
    failingCriteria: { type: 'array', items: { type: 'object', properties: { criterion: { type: 'string' }, evidence: { type: 'string', description: 'the exact failing assertion + observed-vs-expected' }, isLikelyRealBug: { type: 'boolean' }, suspectedLocation: { type: 'string', description: 'the file/function you believe holds the integration bug (e.g. DataService.loadSession stamps lastSeenUnix on join)' } }, required: ['criterion', 'evidence', 'isLikelyRealBug', 'suspectedLocation'] }, description: 'success criteria that do NOT hold end-to-end — leave the test RED, do NOT patch the implementation' },
    notes: { type: 'string' },
  },
  required: ['specRelPath', 'registered', 'gauntletOk', 'luneResult', 'testCount', 'coveredCriteria', 'failingCriteria'],
}

const CRITIC_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'gaps', 'fail'] },
    uncoveredCriteria: { type: 'array', items: { type: 'object', properties: { criterion: { type: 'string' }, why: { type: 'string' } } } },
    weakOrTautologicalTests: { type: 'array', items: { type: 'object', properties: { testName: { type: 'string' }, problem: { type: 'string' } } } },
    integrationBugs: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, severity: { type: 'string' }, evidence: { type: 'string' }, suspectedLocation: { type: 'string' } } }, description: 'cross-feature bugs (the per-feature gates could not see them): a shared-balance race, a lifecycle bug, a seam that never reaches its consumer, a lifetime double-count or miss, an analytics event that never fires end-to-end' },
    notes: { type: 'string' },
  },
  required: ['verdict', 'notes'],
}

const criteriaText = (input && input.successCriteria && input.successCriteria.length)
  ? input.successCriteria.map((c, i) => `  ${i + 1}. ${c}`).join('\n')
  : '  (read them from the spec\'s "## Success criteria" section)'

// The minimum cross-feature coverage, expressed in THIS game's terms via the plan-supplied args.
const COVERAGE_CONTRACT = `- CORE LOOP, END TO END: one player traverses the game's whole core loop in a single test${
  coreLoop.length ? `: ${coreLoop.join(' -> ')}` : ' (derive the exact step sequence from the spec\'s "## Core loop" section)'
}, and the loop-completion analytics event fires at the end of it. Assert the traversal actually PROGRESSES — the balance/state must move the right way at every step, so a step that silently no-ops fails the test.
- EVERY SEAM ACTUALLY REACHES ITS CONSUMER: a multiplier/bonus/gate provided by one feature must demonstrably change the OUTPUT of the feature that consumes it. ${
  seams.length
    ? seams.map((s) => `Prove: ${s.name} -> ${s.consumer} (${s.effect}).`).join(' ')
    : 'Enumerate every ctx seam a service reads and prove each one changes the consumer\'s result when set.'
} This is the written-never-read class of defect: assert the DELTA in the consumer's observable output, NEVER that a persisted field changed.
${
  lifetimeField
    ? `- LIFETIME/AGGREGATE COUNTER ON ALL EARNS, NEVER ON SPEND/RESET: ${lifetimeField} rises on EVERY earn path${earnPaths.length ? ` (${earnPaths.join(', ')})` : ''} — exactly once each, no double-count — and does NOT rise on${nonEarnPaths.length ? ` ${nonEarnPaths.join(', ')}` : ' any spend, unlock or prestige/reset path'}, and a prestige/reset must not ZERO it.`
    : '- Any lifetime/aggregate counter the spec implies rises on every earn path exactly once and never on a spend/reset.'
}
- SHARED-BALANCE RACE ACROSS FEATURES: interleaved / spam-duplicated actions from DIFFERENT features racing ${sharedBalance} (use the economy_race coroutine technique) must never double-spend it or dupe any currency it buys. The per-feature gates cannot see this: each proved its own service alone.
- RE-ENTRY LIFECYCLE (the per-feature gates CANNOT test this at all): simulate a player who EARNS, then LEAVES (releaseSession — which stamps the last-seen timestamp), then time passes on the server clock, then REJOINS (loadSession), then claims.${
  reentry.length ? ` Cover each re-entry hook: ${reentry.join('; ')}.` : ''
} They MUST receive what the away-window earned them. If they receive ZERO, that is an integration bug — a lifecycle write on JOIN clobbering the accrual base before it is read — so leave it RED and report it in failingCriteria with the suspected location. Also assert the claim does not race session load: a claim issued the instant the player joins must not be served against half-loaded data.
- ANALYTICS TAXONOMY END-TO-END: over one full session every event the spec mandates${
  analyticsEvents.length ? ` (${analyticsEvents.join(', ')})` : ''
} fires through the single shared emitter — assert the emitted payloads, not merely that the emitter exists.`

// ---- PHASE 1: AUTHOR ----
phase('Author')
const author = await agent(`You are the INDEPENDENT INTEGRATION GATE for the whole game at ${gameDir}. The per-feature gates proved each service alone; you prove the FEATURES WORK TOGETHER, by standing up the WHOLE game and testing the spec's SUCCESS CRITERIA end-to-end. You did not build any feature. Try to find where the integration is broken.

You are at repo root. READ FIRST:
1. ${specPath} — the "## Success criteria" section is your test contract (the gradable done-conditions):
${criteriaText}
2. ${gameDir}/src/server/Context.luau (how the full ServerContext is built — every service + ctx seam), ${gameDir}/src/server/init.server.luau (the bootstrap: service registration order + the join/leave lifecycle), ${gameDir}/src/server/data/DataService.luau (loadSession / releaseSession / saveSession — the join/leave lifecycle that writes timestamps.lastSeenUnix; STUDY when lastSeenUnix is written).
3. The Tier-1 harness + the per-feature specs to learn how each action is driven: ${gameDir}/tests/lib/{testkit,assert,mocks}.luau; ${gameDir}/tests/unit/economy_race.spec.luau (THE coroutine+yielding-store interleave technique for the shared-balance race); and EVERY existing per-feature spec under ${gameDir}/tests/unit/ (list the directory — do not assume which exist) for each action's shape + the seam wiring.
4. ${gameDir}/src/shared/Net.luau (Net.Actions + dispatch) and every feature service in ${gameDir}/src/server/services/* (so you drive the REAL handlers + seams through the REAL Net.dispatch over a REAL DataService + MockStore). The built features are: [${features.join(', ')}].

THEN author integration spec(s) under ${gameDir}/tests/integration/ (a new dir) — stand up the WHOLE game in Tier-1 (build the full context / register EVERY service so that every ctx seam is LIVE, not nil — a seam left nil silently turns this into a per-feature test) and test the success criteria END-TO-END with REAL, falsifiable assertions. Register the spec(s) in ${gameDir}/tests/run.luau. Cover at minimum:
${COVERAGE_CONTRACT}

HARD CONSTRAINTS: do NOT edit any src/ implementation — if a success criterion does not hold, leave the test RED and report it in failingCriteria (do NOT patch the impl to make it pass; that is the orchestrator's falsify-first fix). Do NOT run git. Run stylua on files you create. VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${gameDir} — report the lune total; a RED you intentionally leave for a real integration bug makes gauntletOk false, which is expected — call it out clearly. Return the StructuredOutput.`, { label: 'integration:author', phase: 'Author', schema: AUTHOR_SCHEMA, effort: 'high' })

log(`integration-gate: author wrote ${author ? author.testCount : 0} test(s); covered ${author ? (author.coveredCriteria || []).length : 0} criteria; ${author ? (author.failingCriteria || []).length : 0} failing criteria (integration bugs).`)

// ---- PHASE 2: REVIEW (coverage + integration red-team, parallel) ----
phase('Review')
const specForCritics = author ? author.specRelPath : `${gameDir}/tests/integration/`
const [coverage, redteam] = await parallel([
  () => agent(`Read-only COVERAGE review of the whole-game INTEGRATION suite at ${gameDir} (do NOT run or edit). Read ${specForCritics}, the spec's "## Success criteria" in ${specPath}, and the feature services under ${gameDir}/src/server/services/. Decide whether EVERY success criterion is covered by a REAL end-to-end integration assertion — not a per-feature unit re-test, and not an assertion that would still pass if the feature under test were replaced by its stub. The required coverage is:
${COVERAGE_CONTRACT}
List any criterion missing or only superficially touched. verdict: pass / gaps / fail. Put specifics in uncoveredCriteria; rationale in notes.`, { label: 'integration:coverage', phase: 'Review', schema: CRITIC_SCHEMA }),
  () => agent(`Independent INTEGRATION RED-TEAM of the whole game at ${gameDir} (reading + reasoning; do NOT edit). The per-feature gates already cleared each service ALONE — your job is the CROSS-FEATURE bugs they could not see. START by listing ${gameDir}/src/server/services/ so you review this game's real surface. Then read ${gameDir}/src/server/data/DataService.luau (the join/leave lifecycle — WHEN is the last-seen timestamp written, and does loadSession on JOIN clobber the accrual base before anything reads it?), every feature service, and ${specForCritics}.

Reason hard about:
(a) ACCRUAL ACROSS A REAL REJOIN — does any away-window/offline grant ever actually PAY, or does a lifecycle write zero the window? Does a client controller that calls the server from its Start() race session load (the grant is then lost PERMANENTLY, because the next autosave erases the away window)?
(b) any LIFETIME/AGGREGATE counter: incremented EXACTLY once per earn across all paths, never on a spend/reset, never zeroed by a prestige — any double-count or miss?
(c) the SHARED BALANCE (${sharedBalance}) under interleavings that mix DIFFERENT features — any double-spend or currency dupe across the per-player FIFO lock?
(d) do the ctx SEAMS actually reach their consumers, or is one passed nil / registered too late / never wired, so a purchased effect is inert? Check each consumer reads the seam rather than a hardcoded constant sitting next to it.
(e) does any mandated analytics event fail to fire end-to-end?
(f) does any post-write side effect (an emit, a client push) run UNGUARDED after a committed write, so its failure turns a successful transaction into an error?
For each real cross-feature bug: title, severity, concrete evidence (the exact interleaving or lifecycle sequence), and the suspected file/function. verdict: pass (no real integration bug) / fail (>=1). Findings in integrationBugs.`, { label: 'integration:redteam', phase: 'Review', schema: CRITIC_SCHEMA, effort: 'high' }),
])

const failing = (author && author.failingCriteria) || []
const redteamBugs = (redteam && redteam.integrationBugs) || []
const totalBugs = failing.length + redteamBugs.length
const verdict = totalBugs > 0 ? 'integration-bugs-found' : (coverage && coverage.verdict === 'pass' && author && author.gauntletOk) ? 'green' : 'needs-review'

// This gate runs entirely under Lune — it proves the logic is correct under the FILESYSTEM loader, NOT
// that the game boots in-engine. So a 'green' verdict is T1-green ONLY, with T2 (in-engine smoke) still
// unverified. This gate only LABELS the tier; it does NOT itself refuse escalation. The refusal lives in
// the handoff guard (.claude/skills/lib/tier-ladder.luau, handoff()) — built + unit-tested — which the
// build-game handoff/FF step calls to refuse a non-engine-verified tree; wiring it in is the remaining
// integration task (VERIFICATION-LADDER.md §4.2). Surfacing verificationTier here keeps any reader from
// laundering Lune-green into "ready/engine-verified" (the conflation).
const verificationTier = verdict === 'green' ? 'T1-green,T2-unverified' : 'below-T1-green'
log(`integration-gate DONE. verdict: ${verdict} | verificationTier: ${verificationTier} | failingCriteria: ${failing.length} | redteamBugs: ${redteamBugs.length} | coverage: ${coverage ? coverage.verdict : 'n/a'}. Orchestrator adjudicates + fixes falsify-first.`)

return { gameDir, verdict, verificationTier, author, coverage, redteam, failingCriteria: failing, redteamBugs }
