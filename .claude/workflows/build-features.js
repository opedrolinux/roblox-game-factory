// build-features.js — B4 piece 2: the feature build + independent-gate engine.
//
// Encodes the pipeline proven manually on collect-sim "Collection core" (2026-06-19):
//   contract pass (SERIAL, orchestrator/human — BEFORE this workflow)
//     -> per feature: independent BUILDER writes the service from its spec slice
//        -> independent TEST GATE (a different agent authors spec-derived tests; impl frozen)
//           + 3 adversarial critics (coverage / anti-tautology / economy red-team)
//        -> merge.luau classify (only-feature-files? else PARK)
//   adjudicate + fix (falsify-first) + union-merge onto staging (SERIAL, orchestrator — AFTER)
//
// WHY a Workflow and not Lune: every step here is *agent* work, and only the Workflow engine can
// spawn agents (BUILD-PIPELINE-DESIGN.md §1). Lune stays the deterministic-helper layer
// (gauntlet.luau, merge.luau), called by the agents.
//
// v1 SCOPE (honest): features run SERIALLY in the main working tree (build then gate share the tree,
// exactly like the proven manual run). The worktree-parallel fan-out (§4) is v2 — it needs
// cross-agent file-sharing (a builder's worktree branch handed to the gate) that serial v1 avoids.
// This workflow does NOT commit and does NOT edit src/shared: the contract pass writes shared deltas
// up front (serial barrier, §5), and the orchestrator adjudicates findings, applies fixes, and
// union-merges green features onto staging (§11.1 staging posture; the human pushes main).
//
// args (JSON, NOT a stringified list):
//   {
//     gameDir: "games/collect-sim",
//     features: [
//       {
//         name: "upgrades-shop",                 // kebab; also the services/<name>/ + tests/unit/<name>.spec dir/file stem
//         serviceName: "UpgradesShopService",    // the module table name
//         specSlice: "<the exact spec text for THIS feature + its success criteria>",
//         contractSummary: "<which Net.Actions / Types fields the contract pass already wrote for it>",
//         hasUI: false                            // if true, the builder also writes a client controller
//       }
//     ]
//   }

export const meta = {
  name: 'build-features',
  description: 'B4 fan-out engine: per feature, an independent builder writes the service from its spec slice, then an independent test gate (author + 3 adversarial critics: coverage / anti-tautology / economy red-team) verifies it. Returns per-feature structured verdicts for the orchestrator to adjudicate, fix (falsify-first), and union-merge onto staging. Contract pass + integrate-merge stay serial orchestrator/human barriers; nothing is committed here.',
  phases: [
    { title: 'Build', detail: 'independent builder writes each feature service from its spec slice; runs the gauntlet' },
    { title: 'Gate', detail: 'independent test gate per feature: author writes spec-derived tests (impl frozen), 3 critics adjudicate' },
  ],
}

// args normally arrives as an object; defensively accept a JSON string too (some invocation
// paths stringify it). Parse before use so args.features is reliably an array.
let input = args
if (typeof input === 'string') {
  try {
    input = JSON.parse(input)
  } catch (_e) {
    input = {}
  }
}
const gameDir = (input && input.gameDir) || 'games/collect-sim'
const features = (input && input.features) || []
log(`build-features: args type=${typeof args}; parsed ${features.length} feature(s) for ${gameDir}.`)

// ---- structured-output schemas (validated at the tool-call layer; agents retry on mismatch) ----

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    serviceRelPath: { type: 'string', description: 'path to the service module you created' },
    extraFiles: { type: 'array', items: { type: 'string' }, description: 'any other files you wrote (e.g. a client controller)' },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string', description: 'the lune stage JSON, e.g. {"passed":N,"failed":0,"total":N}' },
    touchedSharedOrSpine: { type: 'boolean', description: 'TRUE if you had to edit anything under src/shared or init.server (you should NOT have — flag it)' },
    designNotes: { type: 'string', description: 'how the feature works: state ownership, the concurrency-safety argument for any economy mutation, validation' },
    knownLimitations: { type: 'array', items: { type: 'string' }, description: 'anything deliberately out of scope / Tier-3, so the gate is not surprised' },
  },
  required: ['serviceRelPath', 'gauntletOk', 'luneResult', 'touchedSharedOrSpine', 'designNotes'],
}

const AUTHOR_SCHEMA = {
  type: 'object',
  properties: {
    specRelPath: { type: 'string' },
    registered: { type: 'boolean', description: 'appended to tests/run.luau SPEC_PATHS?' },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    testCount: { type: 'number' },
    coveredCases: { type: 'array', items: { type: 'string' } },
    uncoveredCases: { type: 'array', items: { type: 'object', properties: { case: { type: 'string' }, why: { type: 'string' } } } },
    suspectedRealBugs: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, evidence: { type: 'string' }, specReference: { type: 'string' } } }, description: 'failing tests you believe expose a REAL implementation bug (you did NOT patch the impl)' },
    notes: { type: 'string' },
  },
  required: ['specRelPath', 'registered', 'gauntletOk', 'luneResult', 'testCount', 'coveredCases', 'uncoveredCases', 'suspectedRealBugs'],
}

const CRITIC_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'gaps', 'fail'] },
    missingCases: { type: 'array', items: { type: 'object', properties: { case: { type: 'string' }, why: { type: 'string' } } } },
    weakOrTautologicalTests: { type: 'array', items: { type: 'object', properties: { testName: { type: 'string' }, problem: { type: 'string' } } } },
    realBugsFound: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, severity: { type: 'string' }, evidence: { type: 'string' }, specReference: { type: 'string' } } } },
    notes: { type: 'string' },
  },
  required: ['verdict', 'notes'],
}

// ---- prompt builders (parameterized by feature; mirror the proven collect-sim run) ----

function buildPrompt(dir, f) {
  const ui = f.hasUI
    ? `\n- This feature HAS UI: also write a client controller at ${dir}/src/client/controllers/${f.name}/ following the sample controller pattern. Keep it thin — all authority stays server-side.`
    : ''
  return `You are an INDEPENDENT BUILDER for the "${f.name}" feature of the Roblox game at ${dir}. Build the feature's authoritative server logic to its spec slice and the game's engineering contract. You build; a SEPARATE agent will test you — so build it right, not just green.

You are at repo root. The CONTRACT PASS already wrote this feature's shared wiring (Net.Actions constants / Types fields / a registered stub service) — src/shared and init.server are READ-ONLY to you.

READ FIRST:
1. ${dir}/CLAUDE.md — the non-negotiable engineering rules. Especially: §1 --!strict; §3 server-authoritative (validate type+range+ownership+rate on EVERY inbound action); §4 concurrency-safe economy (mutate balances ONLY through the single-writer ctx.data:update; NEVER read-then-write a balance across a yield); §5 idempotent purchases (if this feature touches monetization); §7 server clock via ctx.clock; §8 data only through the data layer; "The shared contracts are READ-ONLY to feature work".
2. The feature's spec slice (verbatim):
-----
${f.specSlice}
-----
3. The contract this feature builds on (already written): ${f.contractSummary}
4. ${dir}/src/shared/Net.luau — the action registry (your action name constants are already in Net.Actions) and Net.dispatch (the ONE pipeline). ${dir}/src/shared/Result.luau — the EXACT Result.Codes names (never invent one — CLAUDE.md §10).
5. ${dir}/src/server/services/sample/SampleService.luau and (if present) services/collection/CollectionService.luau — the concrete service pattern: a module returning a table with Start(context); build actions as closures over private state INSIDE Start(); register via context.net:register(action) (COLON syntax). ${dir}/src/server/data/DataService.luau — get/update/save; ctx.data:update runs the transform under the per-player FIFO lock and may YIELD.

THEN BUILD ${dir}/src/server/services/${f.name}/${f.serviceName}.luau (replacing any stub):
- A module table { name = "${f.serviceName}" } with a Start(context) hook. Resolve deps through context (context.net, ctx.data, ctx.clock) — never sibling-require another service.
- Register the feature's action(s) inside Start via context.net:register(action). Each action = { name, validate, rate, handler, ownerOf? }: validate turns the UNTRUSTED payload into a typed value or Err(BadPayload/OutOfRange/...); rate is its RatePolicy; handler is server-authoritative and pure-ish over ctx.
- Economy mutations: zero/capture session state BEFORE any ctx.data:update yield so an interleaved/spam-duplicated request can't double-grant; restore on update failure WITHOUT violating invariants (e.g. clamp to a capacity cap). Trust ZERO client-supplied numbers — derive value server-side.${ui}

HARD CONSTRAINTS:
- Do NOT edit anything under ${dir}/src/shared or ${dir}/src/server/init.server.luau. If you believe you genuinely need a new shared action/field, STOP and report it in designNotes as a needed contract amendment (set touchedSharedOrSpine appropriately) — do NOT edit shared yourself.
- Do NOT run git. Do NOT commit or stage anything.
- After each edit run stylua on the files you wrote (self-heal formatting; a PostToolUse hook nags otherwise).
- VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${dir} — iterate until it ends {"ok":true,...}. Report the lune stage's {"passed":X,"failed":Y,"total":Z}.

Return the StructuredOutput: the service path, gauntletOk + luneResult, whether you touched shared/spine (you should not have), your design notes (state ownership + the concurrency-safety argument), and any known limitations so the test gate is not surprised.`
}

function authorPrompt(dir, f) {
  return `You are the INDEPENDENT TEST GATE for the "${f.name}" feature at ${dir}. You did NOT write it. Author Tier-1 (Lune) tests from the SPEC's behavioral guarantees — NOT by mirroring the implementation's branch logic (maker != checker). Try to BREAK it, especially the economy.

You are at repo root. READ FIRST:
1. The feature's spec slice (verbatim) — your contract to test against:
-----
${f.specSlice}
-----
2. ${dir}/CLAUDE.md — the "## Independent test gates" section is your REQUIRED coverage checklist: behavior, negative/abuse (malformed payloads -> BadPayload, rate limits, economy mint/overflow, ownership), concurrency/races (interleaved + spam-duplicated -> double-spend/dupes), boundaries, migration round-trips (only if this feature persists a new field). Plus §3 (validate type+range+ownership+rate) and §4 (concurrency-safe economy).
3. ${dir}/src/shared/Net.luau (the action names + Net.dispatch you drive) and ${dir}/src/shared/Result.luau (the EXACT Result.Codes names — never invent one).
4. The harness + an existing spec to mirror idioms EXACTLY: ${dir}/tests/lib/{testkit,assert,mocks}.luau; ${dir}/tests/unit/sample.spec.luau; ${dir}/tests/unit/net.spec.luau (dispatch + Gate + rate via injected clock); ${dir}/tests/unit/economy_race.spec.luau (THE pattern for forcing interleaved/duplicated requests against the per-player FIFO lock with coroutines + a yielding store — your concurrency test MUST use this technique; sequential calls do NOT prove concurrency-safety).
5. ${dir}/src/server/services/${f.name}/${f.serviceName}.luau — read ONLY to learn the observable interface (return shapes, concrete constants) so you can parametrize expectations. Do NOT copy its control flow into your assertions; encode the SPEC's guarantees independently. Prefer discovering constants through the API where practical.

THEN author ${dir}/tests/unit/${f.name}.spec.luau and append "./unit/${f.name}.spec" to SPEC_PATHS in ${dir}/tests/run.luau. Cover the full matrix above with REAL, falsifiable assertions (no tautologies; the concurrency test must genuinely interleave so a double-spend would FAIL it).

HARD CONSTRAINTS:
- Do NOT edit any file under src/ — the implementation is FROZEN. You only create the spec + register it.
- Do NOT run git / commit / stage.
- If a test FAILS: if it's YOUR test's bug (syntax, wrong harness usage, wrong Result code / constant) -> fix YOUR test and rerun (up to ~5 iterations). If it's a genuine SPEC violation by the implementation -> STOP patching, leave that test RED, and report it under suspectedRealBugs. NEVER edit the implementation to make a test pass.
- After each edit run stylua on the spec + run.luau. VERIFY with lune run .claude/skills/lib/gauntlet.luau ${dir} — report the lune total (existing tests + yours, no regression).

Return the StructuredOutput.`
}

function coveragePrompt(dir, f) {
  return `Read-only COVERAGE review (do NOT run or edit anything). Read: ${dir}/tests/unit/${f.name}.spec.luau (the just-authored suite), the "${f.name}" spec slice below, and ${dir}/CLAUDE.md "## Independent test gates".
-----
${f.specSlice}
-----
Decide whether the suite COVERS the required matrix with REAL assertions: behavioral; abuse (malformed -> BadPayload, rate-limit + window reset); concurrency (interleaved/spam-duplicated -> no double-spend/dupe; economy conservation over a cycle); boundaries; migration round-trip if the feature persists a new field. List every required case MISSING or only superficially touched. Verify assertions against ground truth (the impl + harness), not just the test's own comments.
verdict: 'pass' (matrix covered) / 'gaps' / 'fail' (core economy/abuse cases absent). Put specifics in missingCases; rationale in notes.`
}

function qualityPrompt(dir, f) {
  return `Read-only ANTI-TAUTOLOGY / adversarial review (do NOT run or edit anything). Read: ${dir}/tests/unit/${f.name}.spec.luau, ${dir}/src/server/services/${f.name}/${f.serviceName}.luau, and ${dir}/tests/unit/economy_race.spec.luau.
Find tests that are WEAK or TAUTOLOGICAL: assert nothing meaningful; mirror the implementation's control flow instead of the spec's guarantee; or CLAIM to test concurrency while actually calling the action sequentially. The concurrency test MUST force interleaving against the per-player FIFO lock the way economy_race.spec does — verify it genuinely does (driving the data:update transform across a yield with coroutines); if it just calls the action twice in a row, FLAG it (it would pass even under a double-spend). Also flag any assertion that would still pass under a double-spend or minted-from-nothing bug.
verdict: 'pass' / 'gaps' / 'fail' (the critical concurrency test does not actually interleave). Specifics in weakOrTautologicalTests; rationale in notes.`
}

function bughuntPrompt(dir, f) {
  return `Independent ECONOMY RED-TEAM (do NOT edit anything; reading + reasoning only). Read ${dir}/src/server/services/${f.name}/${f.serviceName}.luau against the "${f.name}" spec slice below and ${dir}/CLAUDE.md rules §3 (validate type+range+ownership+rate) and §4 (single-writer; no read-then-write across a yield). Skim ${dir}/src/shared/Net.luau (dispatch) and ${dir}/tests/unit/economy_race.spec.luau (how interleaving happens here).
-----
${f.specSlice}
-----
Try HARD to find a REAL bug: double-spend / dupe currency; mint from nothing; lose a player's resources; bypass a range/capacity invariant; bypass the rate limit; spoof a server-authoritative value via the payload. Reason explicitly about interleavings across every ctx.data:update yield boundary (what if the update FAILS? what if another action interleaves during the yield? what does the restore/cleanup path do to invariants?). For each bug: title, severity (critical/high/medium/low), concrete evidence (the exact interleaving or input), and the spec line it violates. If after a genuine attempt you find NONE, say so explicitly and return realBugsFound empty.
verdict: 'pass' (no real bug) / 'fail' (>=1 real bug). Findings in realBugsFound.`
}

// ---- the run: serial per feature; build then gate; classify; suggest a verdict ----

if (features.length === 0) {
  log('build-features: no features supplied (args.features is empty) — nothing to build.')
  return { gameDir, featureCount: 0, results: [] }
}

log(`build-features: ${features.length} feature(s) on ${gameDir} — serial build+gate (v1). Contract pass assumed done; nothing is committed here.`)

const results = []

for (let i = 0; i < features.length; i++) {
  const f = features[i]

  phase(`Build:${f.name}`)
  const builder = await agent(buildPrompt(gameDir, f), {
    label: `build:${f.name}`,
    phase: `Build:${f.name}`,
    schema: BUILD_SCHEMA,
    effort: 'high',
  })

  if (!builder || !builder.gauntletOk) {
    log(`build-features: ${f.name} did not build green — recording build-failed, skipping its gate.`)
    results.push({ feature: f.name, verdict: 'build-failed', builder: builder || null, gate: null })
    continue
  }

  phase(`Gate:${f.name}`)
  const author = await agent(authorPrompt(gameDir, f), {
    label: `gate-author:${f.name}`,
    phase: `Gate:${f.name}`,
    schema: AUTHOR_SCHEMA,
    effort: 'high',
  })

  const [coverage, quality, bughunt] = await parallel([
    () => agent(coveragePrompt(gameDir, f), { label: `critic-coverage:${f.name}`, phase: `Gate:${f.name}`, schema: CRITIC_SCHEMA }),
    () => agent(qualityPrompt(gameDir, f), { label: `critic-quality:${f.name}`, phase: `Gate:${f.name}`, schema: CRITIC_SCHEMA }),
    () => agent(bughuntPrompt(gameDir, f), { label: `critic-bughunt:${f.name}`, phase: `Gate:${f.name}`, schema: CRITIC_SCHEMA, effort: 'high' }),
  ])

  // Aggregate the gate signal. The workflow SUGGESTS a verdict; the orchestrator adjudicates,
  // applies fixes (falsify-first), and decides the merge — it does not auto-fix impl bugs here.
  const realBugs = []
    .concat((author && author.suspectedRealBugs) || [])
    .concat((bughunt && bughunt.realBugsFound) || [])
  const critics = [coverage, quality, bughunt]
  const anyCriticGap = critics.some((c) => !c || c.verdict !== 'pass')
  const gateGreen = !!(author && author.gauntletOk)

  let verdict
  if (realBugs.length > 0) {
    verdict = 'bug-found' // orchestrator must fix the impl (with a falsify-first regression test) and re-gate
  } else if (!gateGreen || anyCriticGap) {
    verdict = 'needs-review' // suite red without a named impl bug, or a critic flagged coverage/quality gaps
  } else {
    verdict = 'green' // builder green + author green + all three critics pass -> ready to union-merge onto staging
  }

  log(`build-features: ${f.name} -> ${verdict}${realBugs.length ? ` (${realBugs.length} suspected bug(s))` : ''}`)
  results.push({
    feature: f.name,
    verdict,
    realBugs,
    builder,
    gate: { author, coverage, quality, bughunt },
  })
}

const green = results.filter((r) => r.verdict === 'green').map((r) => r.feature)
const flagged = results.filter((r) => r.verdict !== 'green').map((r) => `${r.feature}:${r.verdict}`)
log(`build-features done. green: [${green.join(', ')}] | needs orchestrator: [${flagged.join(', ')}]`)

return { gameDir, featureCount: features.length, green, flagged, results }
