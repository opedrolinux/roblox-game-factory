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
const gameDir = (input && input.gameDir) || 'games/collect-sim'
const specPath = (input && input.specPath) || 'specs/collect-sim.md'
const features = (input && input.features) || []
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

// ---- PHASE 1: AUTHOR ----
phase('Author')
const author = await agent(`You are the INDEPENDENT INTEGRATION GATE for the whole game at ${gameDir}. The per-feature gates proved each service alone; you prove the FEATURES WORK TOGETHER, by standing up the WHOLE game and testing the spec's SUCCESS CRITERIA end-to-end. You did not build any feature. Try to find where the integration is broken.

You are at repo root. READ FIRST:
1. ${specPath} — the "## Success criteria" section is your test contract (the gradable done-conditions):
${criteriaText}
2. ${gameDir}/src/server/Context.luau (how the full ServerContext is built — every service + ctx seam), ${gameDir}/src/server/init.server.luau (the bootstrap: service registration order + the join/leave lifecycle), ${gameDir}/src/server/data/DataService.luau (loadSession / releaseSession / saveSession — the join/leave lifecycle that writes timestamps.lastSeenUnix; STUDY when lastSeenUnix is written).
3. The Tier-1 harness + the per-feature specs to learn how each action is driven: ${gameDir}/tests/lib/{testkit,assert,mocks}.luau; ${gameDir}/tests/unit/economy_race.spec.luau (THE coroutine+yielding-store interleave technique for the shared-balance race); and the existing per-feature specs (collection/shop/daily/islands/leaderboard/monetization/offline/restock/rebirth) for each action's shape + the seam wiring.
4. ${gameDir}/src/shared/Net.luau (Net.Actions + dispatch) and the feature services in ${gameDir}/src/server/services/* (so you drive the REAL handlers + seams through the REAL Net.dispatch over a REAL DataService + MockStore).

THEN author ${gameDir}/tests/integration/ (a new dir) integration spec(s) — stand up the WHOLE game in Tier-1 (build the full context / register every service so the ctx seams ctx.islands/ctx.restock/ctx.monetization/ctx.analytics are all LIVE, not nil) and test the success criteria END-TO-END with REAL, falsifiable assertions. Register the spec(s) in ${gameDir}/tests/run.luau. Cover at minimum:
- CORE LOOP: a single player traverses collect -> sell -> buy an upgrade -> unlock island 2 -> rebirth, and a loop_completed analytics event fires at the rebirth. Assert the traversal actually progresses (balance moves the right way at each step).
- MULTIPLIERS ACTUALLY REACH SELL: with islands wired, unlocking a richer island makes a subsequent Sell pay MORE (the island multiplier reaches the consolidated Sell formula via ctx.islands:multiplierFor(d)); with the 2x gamepass flag set, Sell pays double; on today's restock vein the bonus applies. (These prove the contract-pass Sell amendment + the seams compose.)
- LIFETIME ON ALL EARNS, NEVER ON SPEND/RESET: stats.lifetimeStardust rises on sell, daily claim, offline claim, and a monetization Stardust-pack grant — and does NOT rise on a shop buy, an island unlock, or a rebirth reset (and rebirth does not RESET it).
- SHARED-BALANCE RACE: interleaved/spam-duplicated sell + buy + unlock + rebirth against the ONE shared currencies.Stardust (the economy_race technique) never double-spends Stardust or dupes Prisms.
- RE-ENTRY LIFECYCLE (the per-feature gates CANNOT test this): simulate a player who EARNS, then LEAVES (releaseSession — which stamps lastSeenUnix), then time passes on the server clock, then REJOINS (loadSession), then claims offline -> they MUST receive the offline grant for the elapsed-away window. If they get ZERO, that is an integration bug (a lifecycle timestamp issue) — leave it RED + report it in failingCriteria with the suspected location.
- ANALYTICS TAXONOMY END-TO-END: over a full session the 7 events fire through the single ctx.analytics (session_start/session_end via the lifecycle, loop_completed, currency_earned, currency_spent, progression, purchase).

HARD CONSTRAINTS: do NOT edit any src/ implementation — if a success criterion does not hold, leave the test RED and report it in failingCriteria (do NOT patch the impl to make it pass; that is the orchestrator's falsify-first fix). Do NOT run git. Run stylua on files you create. VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${gameDir} — report the lune total; a RED you intentionally leave for a real integration bug makes gauntletOk false, which is expected — call it out clearly. Return the StructuredOutput.`, { label: 'integration:author', phase: 'Author', schema: AUTHOR_SCHEMA, effort: 'high' })

log(`integration-gate: author wrote ${author ? author.testCount : 0} test(s); covered ${author ? (author.coveredCriteria || []).length : 0} criteria; ${author ? (author.failingCriteria || []).length : 0} failing criteria (integration bugs).`)

// ---- PHASE 2: REVIEW (coverage + integration red-team, parallel) ----
phase('Review')
const specForCritics = author ? author.specRelPath : `${gameDir}/tests/integration/`
const [coverage, redteam] = await parallel([
  () => agent(`Read-only COVERAGE review of the whole-game INTEGRATION suite at ${gameDir} (do NOT run or edit). Read ${specForCritics}, the spec's "## Success criteria" in ${specPath}, and the feature services. Decide whether EVERY success criterion is covered by a REAL end-to-end integration assertion (not a per-feature unit re-test): the core-loop traversal + loop_completed; multipliers reaching Sell; lifetime on all 4 earns + never on spend/reset; the shared-balance cross-feature race; the offline leave->rejoin->claim lifecycle; the full analytics taxonomy. List any criterion missing or only superficially touched. verdict: pass / gaps / fail. Put specifics in uncoveredCriteria; rationale in notes.`, { label: 'integration:coverage', phase: 'Review', schema: CRITIC_SCHEMA }),
  () => agent(`Independent INTEGRATION RED-TEAM of the whole game at ${gameDir} (reading + reasoning; do NOT edit). The per-feature gates already cleared each service alone — your job is the CROSS-FEATURE bugs they could not see. Read ${gameDir}/src/server/data/DataService.luau (the join/leave lifecycle + when timestamps.lastSeenUnix is written — does loadSession on JOIN clobber the offline base?), ${gameDir}/src/server/services/collection/CollectionService.luau (the consolidated Sell formula consuming ctx.islands/ctx.restock/ctx.monetization), and every feature service + ${specForCritics}. Reason hard about: (a) the offline accrual base across a real leave/rejoin — does offline ever actually PAY, or does a lifecycle write zero the window? (b) lifetimeStardust: is it incremented EXACTLY once per earn across all paths, and never on a spend/reset? any double-count or miss? (c) the shared Stardust balance under interleavings that mix DIFFERENT features (sell vs unlock vs rebirth) — any double-spend / Prism dupe across the per-player FIFO lock? (d) do the island/2x/restock multipliers actually reach Sell, or is a seam passed nil / never wired? (e) does any analytics event fail to fire end-to-end? For each real cross-feature bug: title, severity, concrete evidence (the interleaving or lifecycle sequence), and the suspected file/function. verdict: pass (no real integration bug) / fail (>=1). Findings in integrationBugs.`, { label: 'integration:redteam', phase: 'Review', schema: CRITIC_SCHEMA, effort: 'high' }),
])

const failing = (author && author.failingCriteria) || []
const redteamBugs = (redteam && redteam.integrationBugs) || []
const totalBugs = failing.length + redteamBugs.length
const verdict = totalBugs > 0 ? 'integration-bugs-found' : (coverage && coverage.verdict === 'pass' && author && author.gauntletOk) ? 'green' : 'needs-review'
log(`integration-gate DONE. verdict: ${verdict} | failingCriteria: ${failing.length} | redteamBugs: ${redteamBugs.length} | coverage: ${coverage ? coverage.verdict : 'n/a'}. Orchestrator adjudicates + fixes falsify-first.`)

return { gameDir, verdict, author, coverage, redteam, failingCriteria: failing, redteamBugs }
