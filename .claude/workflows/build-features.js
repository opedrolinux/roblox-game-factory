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
//         name: "upgradesshop",                  // HYPHEN-FREE lowercase (it is a Luau require segment);
//                                                //   also the services/<name>/ + tests/unit/<name>.spec stem
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
// No game default: silently building into the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
if (!gameDir) throw new Error('build-features: args must supply {gameDir, features}.')
const features = (input && input.features) || []

// ---- ORCHESTRATOR OVERRIDES (both default OFF; both are the orchestrator's to set, never an agent's) ----
//
// WHY THESE EXIST. A workflow script cannot run the gauntlet — it has no filesystem and no shell — so
// all it ever sees is the agent's own `gauntletOk` boolean. That boolean CANNOT distinguish "this
// builder broke the test suite" from "a stage is red for a reason outside every builder's slice".
// Only the orchestrator can tell those apart, because only the orchestrator can actually run the
// gauntlet and read which stages failed. So the distinction is passed IN, explicitly, per run.
//
// THE CONCRETE CASE. gate-reachability fails a replicated field that no client file reads. Between
// the contract pass and the LAST feature merge, that is the honest state of a correctly-built game:
// the schema for nine features exists, the controllers that read it do not yet. A single feature
// builder cannot clear those without leaving its slice, and a builder that TRIES is writing reads
// that exist only to quiet a rule — the precise defect the rule was written to catch.
//
// WHY IT MATTERS MORE HERE THAN ANYWHERE ELSE. `gauntletOk:false` used to record build-failed and
// SKIP THE GATE. So during exactly the window where reachability is red by construction, every
// feature would be recorded failed and the independent test gate — the factory's single most
// important checker — would never run at all. Nine unverified services, each reported as a build
// failure rather than as untested. That is a worse outcome than any red stage.
//
// WHAT THIS IS NOT: a waiver. The named stage stays red, it is reported red, and handoff still
// requires a genuinely green gauntlet. This only stops a known-red stage from suppressing the gate.
const allowGauntletRedStages = (input && input.allowGauntletRedStages) || []
const gauntletRedReason = (input && input.gauntletRedReason) || ''
// 'gate-only' skips the builder and gates whatever is ALREADY on disk. For re-gating a build the
// orchestrator has independently verified — so a control-flow fix does not force a good build to be
// thrown away and redone, which would replace a verified implementation with an unverified one.
const mode = (input && input.mode) || 'full'

log(`build-features: args type=${typeof args}; parsed ${features.length} feature(s) for ${gameDir}; mode=${mode}${allowGauntletRedStages.length ? `; known-red stages ALLOWED: [${allowGauntletRedStages.join(', ')}]` : ''}.`)
if (allowGauntletRedStages.length) {
  log(`build-features: OVERRIDE ACTIVE — a red [${allowGauntletRedStages.join(', ')}] will not suppress the gate. Orchestrator's stated reason: ${gauntletRedReason || '(none given)'}`)
}

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

// Told to every agent that runs the gauntlet, so nobody burns effort chasing a green that is not
// reachable from inside one slice — and, worse, nobody "fixes" it by writing a read that exists only
// to satisfy a rule. An agent handed an unsatisfiable success condition does not stop; it escalates.
const KNOWN_RED = allowGauntletRedStages.length
  ? `\n\nKNOWN-RED GAUNTLET STAGE(S): [${allowGauntletRedStages.join(', ')}]. The orchestrator ran the gauntlet itself and established these are red for a reason OUTSIDE any single feature's slice${gauntletRedReason ? `: ${gauntletRedReason}` : '.'} So "iterate until ok:true" DOES NOT APPLY to these stages — that green is not reachable from where you are standing.
YOUR ACTUAL TARGET: (a) every OTHER stage green, and (b) no NEW failure in a known-red stage that names YOUR feature's files, seams or fields. Check that specifically: capture the known-red stage's failure list BEFORE you start and compare at the end.
DO NOT make a known-red stage green by adding a read, a field, a call or a test whose only purpose is to satisfy the rule. That is the exact defect these rules exist to catch, and it will be found and reverted. Reporting gauntletOk=false with an honest account of which stages are red is CORRECT here and is not counted against you.`
  : ''

function buildPrompt(dir, f) {
  // The client conventions are whatever the scaffold's framework/ establishes — DISCOVERED, not
  // named here. A hardcoded exemplar rots: this prompt used to point at `controllers/sample/`, which
  // both shipped games have since deleted, so every UI builder was being sent to a missing file.
  const ui = f.hasUI
    ? `\n- This feature HAS UI: also write a client controller at ${dir}/src/client/controllers/${f.name}/. READ ${dir}/src/client/framework/Controller.luau (the module shape: a table with ONE Start(context); resolve collaborators from \`context\`, NEVER require a sibling controller), ${dir}/src/client/Context.luau (what \`context\` carries — the net you call through is already assembled there, guards included), and ${dir}/src/client/net/NetClient.luau (context.net:call / :on). THEN LIST ${dir}/src/client/framework/ AND ${dir}/src/client/controllers/ and read what is actually there — a shared HUD root, a join-race guard, existing sibling controllers. Those files ARE the client contract; follow them. In particular: if a shared HUD root module exists, mount your panel into one of ITS named slots and NEVER call Instance.new("ScreenGui") yourself (n controllers with n ScreenGuis is n overlapping full-screen layers, and that is the first thing a human sees). Keep the controller thin — zero authority, all of it stays server-side.`
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
5. LIST ${dir}/src/server/services/ and read at least one ALREADY-IMPLEMENTED sibling for the concrete service pattern. Tell them apart before you copy one: a real service registers actions and owns private state; a contract-pass STUB is a few lines with no registered action and is NOT a model to imitate. The cross-cutting services the contract pass stands up (an economy helper, an analytics emitter, and the like) are always real, and if one exists you go THROUGH it rather than reimplementing what it owns. The pattern: a module returning a table with Start(context); build actions as closures over private state INSIDE Start(); register via context.net:register(action) (COLON syntax). ${dir}/src/server/data/DataService.luau — get/update/save; ctx.data:update runs the transform under the per-player FIFO lock and may YIELD.

THEN BUILD ${dir}/src/server/services/${f.name}/${f.serviceName}.luau (replacing any stub):
- A module table { name = "${f.serviceName}" } with a Start(context) hook. Resolve deps through context (context.net, ctx.data, ctx.clock) — never sibling-require another service.
- Register the feature's action(s) inside Start via context.net:register(action). Each action = { name, validate, rate, handler, ownerOf? }: validate turns the UNTRUSTED payload into a typed value or Err(BadPayload/OutOfRange/...); rate is its RatePolicy; handler is server-authoritative and pure-ish over ctx.
- Economy mutations: zero/capture session state BEFORE any ctx.data:update yield so an interleaved/spam-duplicated request can't double-grant; restore on update failure WITHOUT violating invariants (e.g. clamp to a capacity cap). Trust ZERO client-supplied numbers — derive value server-side.${ui}

HARD CONSTRAINTS:
- Do NOT edit anything under ${dir}/src/shared or ${dir}/src/server/init.server.luau. If you believe you genuinely need a new shared action/field, STOP and report it in designNotes as a needed contract amendment (set touchedSharedOrSpine appropriately) — do NOT edit shared yourself.
- Do NOT run git. Do NOT commit or stage anything.
- After each edit run stylua on the files you wrote (self-heal formatting; a PostToolUse hook nags otherwise).
- VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${dir} — iterate until it ends {"ok":true,...}. Report the lune stage's {"passed":X,"failed":Y,"total":Z}.${KNOWN_RED}

Return the StructuredOutput: the service path, gauntletOk + luneResult, whether you touched shared/spine (you should not have), your design notes (state ownership + the concurrency-safety argument), and any known limitations so the test gate is not surprised. If a known-red stage is the ONLY thing keeping gauntletOk false, say so explicitly in designNotes and name the stage — the orchestrator reads that to tell your build apart from a broken one.`
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
4. The harness + existing specs to mirror idioms EXACTLY: ${dir}/tests/lib/{testkit,assert,mocks}.luau; ${dir}/tests/unit/net.spec.luau (dispatch + Gate + rate via injected clock); ${dir}/tests/unit/economy_race.spec.luau (THE pattern for forcing interleaved/duplicated requests against the per-player FIFO lock with coroutines + a yielding store — your concurrency test MUST use this technique; sequential calls do NOT prove concurrency-safety). Also LIST ${dir}/tests/unit/ and read one more passing feature spec for house style (do not assume a particular filename exists — a scaffold's sample spec is deleted once real features land).
5. ${dir}/src/server/services/${f.name}/${f.serviceName}.luau — read ONLY to learn the observable interface (return shapes, concrete constants) so you can parametrize expectations. Do NOT copy its control flow into your assertions; encode the SPEC's guarantees independently. Prefer discovering constants through the API where practical.

THEN author ${dir}/tests/unit/${f.name}.spec.luau and append "./unit/${f.name}.spec" to SPEC_PATHS in ${dir}/tests/run.luau. Cover the full matrix above with REAL, falsifiable assertions (no tautologies; the concurrency test must genuinely interleave so a double-spend would FAIL it).

HARD CONSTRAINTS:
- Do NOT edit any file under src/ — the implementation is FROZEN. You only create the spec + register it.
- Do NOT run git / commit / stage.
- If a test FAILS: if it's YOUR test's bug (syntax, wrong harness usage, wrong Result code / constant) -> fix YOUR test and rerun (up to ~5 iterations). If it's a genuine SPEC violation by the implementation -> STOP patching, leave that test RED, and report it under suspectedRealBugs. NEVER edit the implementation to make a test pass.
- After each edit run stylua on the spec + run.luau. VERIFY with lune run .claude/skills/lib/gauntlet.luau ${dir} — report the lune total (existing tests + yours, no regression).${KNOWN_RED}

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

  let builder = null
  if (mode === 'gate-only') {
    // The build is already on disk and was verified by the orchestrator (who can run the gauntlet).
    // Re-running the builder would discard a verified implementation for an unverified one.
    log(`build-features: ${f.name} — mode=gate-only; skipping the builder and gating what is on disk.`)
  } else {
    phase(`Build:${f.name}`)
    builder = await agent(buildPrompt(gameDir, f), {
      label: `build:${f.name}`,
      phase: `Build:${f.name}`,
      schema: BUILD_SCHEMA,
      effort: 'high',
    })

    // A null builder is always fatal: no agent ran, so nothing was built and there is nothing to gate.
    // A FALSE gauntletOk is only fatal when no known-red stage was declared — see the override note
    // at the top. Skipping the gate is the most expensive thing this workflow can do wrong, because
    // an ungated feature and a failed build are reported identically and only one of them is honest.
    if (!builder) {
      log(`build-features: ${f.name} — builder agent returned nothing; recording build-failed, skipping its gate.`)
      results.push({ feature: f.name, verdict: 'build-failed', builder: null, gate: null })
      continue
    }
    if (!builder.gauntletOk && allowGauntletRedStages.length === 0) {
      log(`build-features: ${f.name} did not build green — recording build-failed, skipping its gate.`)
      results.push({ feature: f.name, verdict: 'build-failed', builder, gate: null })
      continue
    }
    if (!builder.gauntletOk) {
      log(`build-features: ${f.name} — builder reports gauntletOk=false; PROCEEDING TO THE GATE under the declared known-red override [${allowGauntletRedStages.join(', ')}]. The gate re-runs the gauntlet independently, and the orchestrator re-verifies which stages are red before any merge.`)
    }
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
  // EVERY critic carries realBugsFound (see CRITIC_SCHEMA) — this used to read ONLY the bug-hunter's,
  // so a real defect named by the coverage or quality critic was silently dropped: the feature landed
  // on 'needs-review' (a park) instead of 'bug-found' (the falsify-first auto-fix loop), and the
  // finding survived only if a human happened to read the gate transcript. It bit every batch of this
  // game — depth's paywall-bypassing tier clamp and offline's residual join race were both found
  // TWICE, by two independent critics, and both reported as realBugs: 0. The bug-hunter is the critic
  // whose JOB is exploits; it is not the only one that finds them, and a gate that can only hear one
  // of its three voices is not the gate that was designed.
  const CRITIC_ROLES = [['coverage', coverage], ['quality', quality], ['bughunt', bughunt]]
  const realBugs = [].concat((author && author.suspectedRealBugs) || []).map((b) => ({ ...b, foundBy: 'gate-author' }))
  for (const [role, critic] of CRITIC_ROLES) {
    for (const bug of (critic && critic.realBugsFound) || []) realBugs.push({ ...bug, foundBy: role })
  }
  const critics = CRITIC_ROLES.map(([, c]) => c)
  const anyCriticGap = critics.some((c) => !c || c.verdict !== 'pass')
  // A critic that DIED (API error, stall) returns null, which is indistinguishable from one that ran
  // and found gaps once it is folded into anyCriticGap. It is not the same thing at all: "the exploit
  // hunter looked and found nothing" and "the exploit hunter never looked" produce the same verdict
  // string but a completely different amount of evidence. Named here so the orchestrator can re-run
  // the missing critic instead of adjudicating a gate that is quietly one-third absent.
  const criticsMissing = CRITIC_ROLES.filter(([, c]) => !c).map(([role]) => role)
  if (criticsMissing.length > 0) {
    log(`build-features: ${f.name} — GATE INCOMPLETE: ${criticsMissing.join(', ')} critic(s) did not return. This verdict rests on ${3 - criticsMissing.length}/3 critics; re-run the missing one(s) before trusting it.`)
  }
  // Same override, same reasoning, applied to the gate author: it runs the SAME gauntlet and sees the
  // SAME known-red stage, so without this every feature lands on needs-review for a reason that has
  // nothing to do with the tests it just wrote. `author` still has to EXIST and have run — the
  // override relaxes which stages may be red, never whether the gate ran.
  const gateGreen = !!(author && (author.gauntletOk || allowGauntletRedStages.length > 0))

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
    criticsMissing,
    builder,
    gate: { author, coverage, quality, bughunt },
    // Recorded on EVERY result, so a verdict reached under an override can never be read back as a
    // clean unconditional green. mode is carried for the same reason: a gate-only run means the
    // build in this result was verified elsewhere, not by this workflow.
    mode,
    gauntletOverride: allowGauntletRedStages.length ? { allowedRedStages: allowGauntletRedStages, reason: gauntletRedReason } : null,
  })
}

const green = results.filter((r) => r.verdict === 'green').map((r) => r.feature)
const flagged = results.filter((r) => r.verdict !== 'green').map((r) => `${r.feature}:${r.verdict}`)
log(`build-features done. green: [${green.join(', ')}] | needs orchestrator: [${flagged.join(', ')}]`)

return { gameDir, featureCount: features.length, green, flagged, results }
