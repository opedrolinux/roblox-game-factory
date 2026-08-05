// grade.js — the cross-turn `/goal` grader + LLM-judge (LOOP-ENGINEERING.md §4 upgrades 3 + 4).
//
// The core loop-engineering insight: the agent that BUILT the work is a structural poor judge of whether
// it is done, so a SEPARATE pass decides "done" — not the orchestrator asserting it in-session. This
// grades a game's FACTORY.md §8 definition-of-done against the spec's "## Success criteria" checklist:
//
//   1. DETERMINISTIC tier (the honest verification rung) — runs tier-status.luau (gauntlet + recorded
//      smoke -> the highest CONTIGUOUS green rung). This grounds "done" in the verification ladder: it
//      means *boots-and-reachable* WHEN the engine lane is available; with the lane down (today's
//      default) a ready tier is T1 — Lune-green, NOT engine-booted — and the verdict carries that exact
//      label in `readyFor`, never a bare "done". The ladder (L1+L2) is the rung beneath this grader.
//   2. INDEPENDENT JUDGE (maker != checker) — a fresh agent that did NOT build the game reads the spec's
//      success criteria + the code/tests and grades EACH criterion pass/fail/unknown with concrete
//      evidence, plus the LLM-judge QUALITY layer (does it match the spec? a 0.0-1.0 score with an
//      "Unknown" escape valve). Grounded in tests/code references, never inference.
//
// FAIL-CLOSED: `done` requires the tier to be `ready` AND every criterion explicitly `pass` AND the
// quality judge not `fail`. An "unknown" is surfaced as needs-resolution, NEVER silently counted as pass
// — the whole point is to stop the loop from declaring "done" off a signal that isn't actually green.
// `done: true` means "ready for the human gate (T3)" with the honest tier label, NOT "shipped".
//
// args (JSON): { gameDir, specPath, qualityThreshold? }

export const meta = {
  name: 'grade',
  description: 'The cross-turn /goal grader + LLM-judge (LOOP-ENGINEERING §4 upgrades 3+4). Grades a game against its FACTORY §8 definition-of-done: a deterministic verification tier via tier-status.luau (the honest highest-contiguous-green rung — boots-and-reachable, not just passes-under-Lune) PLUS an independent fresh-agent judge (maker != checker) of the spec\'s "## Success criteria" checklist with concrete evidence + an LLM-judge quality score. Fail-closed: done requires the tier ready AND every criterion pass AND quality not-fail; an Unknown is surfaced, never counted as pass. Reads + reasons only; commits nothing.',
  phases: [
    { title: 'Tier', detail: 'run tier-status.luau for the deterministic, honest verification tier' },
    { title: 'Judge', detail: 'an independent agent grades each spec success criterion + the LLM-judge quality layer' },
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
// No game defaults: silently GRADING the wrong game would launder one game's verdict onto another.
const gameDir = input && input.gameDir
const specPath = input && input.specPath
if (!gameDir || !specPath) throw new Error('grade: args must supply {gameDir, specPath}.')
const qualityThreshold = (input && typeof input.qualityThreshold === 'number') ? input.qualityThreshold : 0.7
log(`grade: ${gameDir} vs ${specPath}. Deterministic tier (tier-status) + an INDEPENDENT judge of the spec success criteria + the LLM-judge quality layer. Fail-closed: an Unknown is never counted as a pass.`)

// ---- PHASE 1: DETERMINISTIC TIER (run tier-status.luau) ----
const TIER_SCHEMA = {
  type: 'object',
  properties: {
    ranOk: { type: 'boolean', description: 'did tier-status.luau run and emit a JSON verdict line?' },
    ready: { type: 'boolean', description: 'the verdict.ready field (every automatable rung green or blocked-on-human)' },
    highestGreen: { type: 'string', description: 'the highest contiguous green rung (none|T0|T0.5|T1|T2|T3)' },
    blockedBy: { type: ['string', 'null'], description: 'the rung that refuses handoff, or null when ready' },
    label: { type: 'string', description: 'the honest tier label (verbatim from the verdict)' },
    rawVerdict: { type: 'string', description: 'the raw JSON line tier-status printed (for the record)' },
  },
  required: ['ranOk', 'ready', 'highestGreen', 'label'],
}

phase('Tier')
const tier = await agent(`Run the verification-ladder status command for the game at ${gameDir} and report its verdict VERBATIM. You are a thin runner — do not judge anything, just run the command and parse its output.

From the repo root, run:
  lune run .claude/skills/lib/tier-status.luau ${gameDir}

It prints ONE JSON line to stdout shaped like {"ready":bool,"highestGreen":"T1","blockedBy":...,"label":"...","reason":"...","t2Evidence":"...","engineLaneAvailable":bool} and exits 0 iff ready. Parse that line and fill the StructuredOutput from it: ready, highestGreen, blockedBy (null when absent), label (verbatim), and rawVerdict = the exact JSON line. If the command fails to run or prints no JSON line, set ranOk=false and ready=false (fail-closed). Do NOT edit any file or run git.`, { label: 'grade:tier', phase: 'Tier', schema: TIER_SCHEMA, effort: 'low' })

// Derive the tier verdict from the DETERMINISTIC JSON line tier-status.luau emitted — NOT the agent's
// interpreted boolean. The agent is only the command runner; the authoritative `ready` comes from
// parsing its captured `rawVerdict`. Fail-closed: any parse failure, a missing line, or ranOk=false
// reads as not-ready. This keeps the "deterministic tier" claim true (HIGH finding from review).
let tierVerdict = null
let tierReady = false
if (tier && tier.ranOk === true && typeof tier.rawVerdict === 'string') {
  try {
    tierVerdict = JSON.parse(tier.rawVerdict)
    tierReady = tierVerdict.ready === true
  } catch (_e) {
    tierVerdict = null
    tierReady = false
  }
}
const tierHighest = (tierVerdict && tierVerdict.highestGreen) || (tier && tier.highestGreen) || 'unrun'
const tierLabel = (tierVerdict && tierVerdict.label) || (tier && tier.label) || '(tier-status did not run)'
const tierBlockedBy = (tierVerdict && (tierVerdict.blockedBy || null)) || (tier && tier.blockedBy) || null
log(`grade: tier = ${tierHighest} | ready=${tierReady} | ${tierLabel}`)

// ---- PHASE 2: INDEPENDENT JUDGE (maker != checker) ----
const JUDGE_SCHEMA = {
  type: 'object',
  properties: {
    criteria: {
      type: 'array',
      description: 'one entry per checkbox in the spec\'s "## Success criteria" section',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'the criterion (the bolded title of the checkbox)' },
          verdict: { type: 'string', enum: ['pass', 'fail', 'unknown'] },
          evidence: { type: 'string', description: 'the CONCRETE test name(s) / file:symbol that demonstrate it — NOT inference. "unknown" if you cannot ground it.' },
        },
        required: ['title', 'verdict', 'evidence'],
      },
    },
    qualityJudge: {
      type: 'object',
      description: 'the LLM-judge quality layer (upgrade 4): does the build MATCH the spec and is it good?',
      properties: {
        specMatchScore: { type: 'number', description: '0.0-1.0: how fully the implementation matches the spec\'s intent (loop, economy, monetization, theme), beyond just passing tests' },
        verdict: { type: 'string', enum: ['pass', 'fail', 'unknown'] },
        strengths: { type: 'string' },
        gaps: { type: 'string', description: 'spec-drift, missing intent, or under-built areas the deterministic gates would not catch' },
      },
      required: ['specMatchScore', 'verdict'],
    },
    notes: { type: 'string' },
  },
  required: ['criteria', 'qualityJudge'],
}

phase('Judge')
const judge = await agent(`You are the INDEPENDENT GRADER for the game at ${gameDir}. You did NOT build it. Decide, against the SPEC, whether each definition-of-done criterion actually holds — grounded in concrete tests/code, never inference or optimism. Default to "unknown" when you cannot ground a verdict; "unknown" is honest and is NOT a pass.

READ FIRST:
1. ${specPath} — the "## Success criteria" section is your RUBRIC: grade EACH checkbox in it (one criteria[] entry per checkbox, using its bolded title).
2. ${gameDir}/tests/ — the unit + integration specs (the EVIDENCE). For each criterion, find the specific test(s) that demonstrate it: e.g. the core-loop traversal emitting loop_completed (integration), the shared-balance race test, the migration round-trips, the monetization/receipt idempotency tests, the offline/daily/restock re-entry tests, the analytics-taxonomy assertions.
3. ${gameDir}/src/ — the implementation, to judge spec-MATCH (the quality layer): does the code realize the spec's loop / economy / monetization / theme intent, or has it drifted / under-built? Read the feature services + the contract (Net.luau, Types.luau).

For EACH success criterion: verdict pass (a real test/code path demonstrates it — cite it in evidence), fail (it is demonstrably not met — cite what's missing/broken), or unknown (you cannot find grounding evidence either way). Be skeptical: a criterion is "pass" ONLY with a concrete reference, never because it "should" work.

Then the QUALITY JUDGE (the LLM-judge layer the deterministic gates can't do): specMatchScore 0.0-1.0 for how fully the build matches the SPEC's intent (not just "tests pass" — does it deliver the designed game?), a verdict (pass/fail/unknown), strengths, and gaps (spec-drift / missing intent / under-built areas).

GROUNDING THE VERIFICATION CRITERIA (do not re-run the gauntlet): a separate DETERMINISTIC stage already ran it via tier-status. Its result is { highestGreen: "${tierHighest}", ready: ${tierReady}, label: "${tierLabel}" }. Ground any gauntlet / static / verification-tier criterion (e.g. "Gauntlet green") from THIS — pass iff the tier reached at least T1 (gauntlet + require-resolve green); cite "deterministic tier: highestGreen=${tierHighest}" as the evidence. Judge the BEHAVIORAL criteria (core loop, economy-safe, monetization, re-entry, analytics, and "no open exploit" — check the named vectors mote-value spoof / magnet-range / offline-time forgery / receipt replay are defended in tests/code) INDEPENDENTLY from the tests + code.

HARD CONSTRAINTS: read + reason only — do NOT edit any file, do NOT run git, do NOT run the build. Return the StructuredOutput.`, { label: 'grade:judge', phase: 'Judge', schema: JUDGE_SCHEMA, effort: 'high' })

// ---- COMPOSE the grade (fail-closed) ----
// Guard the rubric against a non-array / null-element criteria (the sibling gates do the same): a
// malformed judge result reads as "no criteria graded", never as a crash or a vacuous pass.
const criteria = Array.isArray(judge && judge.criteria)
  ? judge.criteria.filter((c) => c && typeof c === 'object')
  : []
const fails = criteria.filter((c) => c.verdict === 'fail')
const unknowns = criteria.filter((c) => c.verdict === 'unknown')
// Strictly fail-closed: require EVERY criterion to be explicitly 'pass'. Anything else — fail, unknown,
// or a malformed verdict — prevents allCriteriaPass (an empty rubric is NOT vacuously done).
const passes = criteria.filter((c) => c.verdict === 'pass')
const allCriteriaPass = criteria.length > 0 && passes.length === criteria.length
const quality = judge && judge.qualityJudge
// Quality is OK ONLY on an explicit 'pass' verdict at/above threshold. An 'unknown' quality verdict is
// the escape valve — it is NOT a pass. (tierReady is derived above from the deterministic JSON line.)
const qualityOk = !!(quality && quality.verdict === 'pass' && typeof quality.specMatchScore === 'number' && quality.specMatchScore >= qualityThreshold)

// done = ready for the human gate (T3). Requires the honest tier ready + EVERY criterion pass + quality
// not-fail and at/above threshold. An unknown criterion or a sub-threshold quality score is NOT done.
const done = tierReady && allCriteriaPass && qualityOk

const blockers = []
if (!tierReady) blockers.push(`tier NOT ready: ${tierBlockedBy ? ('blocked at ' + tierBlockedBy) : 'no ready verdict from tier-status'} — ${tierLabel}`)
for (const c of fails) blockers.push(`criterion FAIL: ${c.title} — ${c.evidence}`)
for (const c of unknowns) blockers.push(`criterion UNKNOWN (needs resolution, not a pass): ${c.title} — ${c.evidence}`)
if (!quality) blockers.push('quality judge did not run')
else if (quality.verdict === 'fail') blockers.push(`quality judge FAIL: ${quality.gaps || quality.notes || 'spec-match failed'}`)
else if (quality.verdict === 'unknown') blockers.push(`quality judge UNKNOWN (needs resolution, not a pass): ${quality.gaps || 'judge could not determine spec-match'}`)
else if (typeof quality.specMatchScore !== 'number') blockers.push('quality judge returned no specMatchScore')
else if (quality.specMatchScore < qualityThreshold) blockers.push(`quality below threshold: specMatchScore ${quality.specMatchScore} < ${qualityThreshold}`)

log(`grade DONE. done=${done} | tier=${tier ? tier.highestGreen : 'unrun'} (ready=${tierReady}) | criteria ${criteria.length - fails.length - unknowns.length}/${criteria.length} pass, ${fails.length} fail, ${unknowns.length} unknown | quality ${quality ? quality.specMatchScore : 'n/a'}. ${done ? 'Ready for the human gate (T3) — with the honest tier label.' : 'NOT done; blockers listed.'}`)

return {
  gameDir,
  specPath,
  done,
  tier: tierVerdict || tier || null,
  tierReady,
  tierHighest,
  tierLabel,
  criteria,
  criteriaSummary: { total: criteria.length, pass: passes.length, fail: fails.length, unknown: unknowns.length },
  quality: quality || null,
  qualityThreshold,
  blockers,
  // honest framing: done=true means "ready for the human gate (T3)" carrying the tier label — never a
  // claim of engine-verification or ship-readiness. With the engine lane down (today's default) a ready
  // tier is T1 (Lune-green, NOT engine-booted), and tierLabel says exactly that.
  readyFor: done ? tierLabel : 'in-progress',
}
