// contract-pass.js — build-game Workflow A, phase 2: the SERIAL guarded contract pass.
//
// The serial barrier that runs ONCE, BEFORE feature fan-out, writing every shared-contract delta
// the approved decompose plan foresaw — so parallel feature builders only ever create their own
// disjoint service files and never collide on src/shared (BUILD-GAME-DESIGN.md §4b + §13).
//
// Decision #2 (cross-cutting = contract-pass infrastructure) expands this beyond pure src/shared:
// it also stands up the analytics emitter and RETROFITS already-built/merged services for the
// cross-cutting hooks (lifetime accrual + analytics emission) that no feature builder can make,
// because those earn/spend points live in OTHER, already-merged features. Those built-code edits
// are the highest blast radius — which is exactly why this is GUARDED (hard rules + gauntlet-green
// gates + an independent verifier) and why the human reviews the real diff before any fan-out.
//
// GAME-AGNOSTIC: every noun (fields, seams, services, retrofits, stubs, events) comes from the
// `contract` arg built from the approved plan. Nothing here knows what game it is building. On a
// FRESH scaffold there is nothing built yet, so contract.retrofits is empty and that phase is
// skipped — the cross-cutting hooks are then owned by the feature builders via the plan's
// emitPoints/earnPaths, which the fan-out passes into every builder prompt.
//
// FIVE serial phases, each gated gauntlet-green (early-abort on red so a broken base never piles
// up), then an INDEPENDENT VERIFIER (maker != checker):
//   1. schema    — Net.Actions, Types fields + PlayerView/toView, Migrations steps + default seeds,
//                  CURRENT_SCHEMA_VERSION bump, new nil-safe ctx seams, + SELF-VERIFYING migration
//                  round-trip tests (a broken step must fail them).
//   2. analytics — stand up the emitter on ctx.analytics + the session_start/session_end lifecycle.
//   3. retrofits — the named edits to already-built services (behavior-preserving when feature
//                  seams are absent, so the existing tests stay green). SKIPPED when none.
//   4. stubs     — registered stub services for the new features (+ identity-default ctx seams)
//                  so the wire is complete and fan-out builders just replace the stub.
//   5. verify    — an independent agent audits the whole diff vs the plan; reports discrepancies.
//
// This workflow does NOT commit and does NOT write feature LOGIC (only wiring + stubs). The
// orchestrator (main session) reviews the verifier report + the real git diff, surfaces it to the
// human, and commits to staging on approval.
//
// args (JSON object): { gameDir, contract } where `contract` is the trimmed contract spec derived
// from the approved decompose plan (deltas + contractPassExtras + precision notes). See the call site.

export const meta = {
  name: 'contract-pass',
  description: 'build-game Workflow A.2: the SERIAL guarded contract pass. Writes every shared-contract delta the approved decompose plan foresaw (Net.Actions, Types fields, Migrations steps + self-verifying round-trip tests, schema-version bump, nil-safe ctx seams), stands up the analytics emitter, retrofits any already-built services for cross-cutting accrual + analytics, and registers a stub per new feature — in serial gauntlet-green phases, then an independent verifier audits the whole diff vs the plan. Commits nothing; writes no feature logic.',
  phases: [
    { title: 'Schema', detail: 'Net.Actions, Types fields + PlayerView/toView, Migrations steps + default seeds, version bump, nil-safe ctx seams, + self-verifying migration round-trip tests' },
    { title: 'Analytics', detail: 'stand up every cross-cutting infra module the plan names (the analytics emitter + any economy/framework helper) on its ctx seam' },
    { title: 'Retrofits', detail: 'the named edits to code the contract pass inherits or already shipped (behavior-preserving when feature seams absent); skipped when the plan names none' },
    { title: 'Stubs', detail: 'a registered stub service per new feature + identity-default ctx seams' },
    { title: 'Verify', detail: 'an independent agent audits the whole contract-pass diff against the approved plan' },
  ],
}

// defensive arg parse (some invocation paths stringify args)
let input = args
if (typeof input === 'string') {
  try {
    input = JSON.parse(input)
  } catch (_e) {
    input = {}
  }
}
// No game default: silently writing the schema of the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
if (!gameDir) throw new Error(`contract-pass: args must supply {gameDir, contract} (got gameDir=${JSON.stringify(gameDir)}).`)
// The contract arrives one of two ways:
//   inline  — args.contract, embedded verbatim into every phase prompt. Fine for small contracts.
//   by file — args.contractFile, a repo-relative path. The SCRIPT cannot read it (workflow scripts
//             have no filesystem), but every phase AGENT can, so the prompt points them at it. This
//             is how a large contract (tens of KB) stays in one canonical place instead of being
//             copied into five prompts. It requires args.outline, because the script itself still
//             branches on the shape (skip the retrofit phase when there are none, etc.).
//
// The failure this guards: a caller passes contractFile without an outline, the script sees an
// EMPTY contract, dutifully writes nothing, ends gauntlet-green, and returns the same shape as a
// clean run — a no-op that looks like a pass. Fail loudly instead.
const contractFile = input && (input.contractFile || input.contractPath)
const inlineContract = (input && input.contract) || {}
const outline = (input && input.outline) || null
const contract = contractFile ? outline || {} : inlineContract

const REQUIRED = ['netActions', 'typedFields', 'migrations', 'stubs']
const missing = REQUIRED.filter((k) => !Array.isArray(contract[k] || contract[k === 'typedFields' ? 'typesFields' : k]))
if (missing.length) {
  throw new Error(
    contractFile
      ? `contract-pass: contractFile "${contractFile}" was given, but args.outline is missing/incomplete: [${missing.join(', ')}]. A workflow script cannot read files, so the outline is the only thing the SCRIPT can branch on — without it this pass would write nothing and return green.`
      : `contract-pass: args.contract is missing/!array: [${missing.join(', ')}]. An empty contract writes nothing and returns green — refusing to run a no-op that would look like a pass.`
  )
}

// What every phase prompt is pointed at as its single source of truth.
const contractSource = contractFile
  ? `READ THE APPROVED CONTRACT SPEC IN FULL, FIRST, BEFORE ANY OTHER FILE: ${contractFile} (repo-relative JSON). It is your SINGLE SOURCE OF TRUTH for what to write — every field, action, seam, service, retrofit and stub you need is named in it. Do not work from the summary below; it is only an index. If you cannot read that file, STOP and report it as a blocker rather than guessing.

Index of what it contains: ${JSON.stringify(outline && outline.index ? outline.index : {}, null, 2)}`
  : `The approved contract spec (your single source of truth for WHAT to write) — every noun you need is in here; do not invent fields, actions, seams or services it does not name:
-----
${JSON.stringify(inlineContract, null, 2)}
-----`

const netActions = contract.netActions || []
const typedFields = contract.typedFields || contract.typesFields || []
const retrofitList = contract.retrofits || []
const stubList = contract.stubs || []
const migrationList = contract.migrations || []
const seedList = contract.defaultSeeds || []
const ctxSeams = contract.newCtxSeams || []
const analyticsSpec = contract.analytics || {}
const analyticsEvents = analyticsSpec.events || []

log(
  `contract-pass: ${gameDir}; schema v${contract.fromSchemaVersion} -> v${contract.toSchemaVersion}; ` +
    `${netActions.length} Net.Action(s), ${typedFields.length} typed field(s), ${migrationList.length} migration(s), ` +
    `${retrofitList.length} retrofit(s), ${stubList.length} stub(s), ${analyticsEvents.length} analytics event(s).`
)

// ---- shared guard rules every phase agent must obey ----
const GUARD = `HARD GUARD RULES (every phase of the contract pass):
- You are at repo root, on the staging branch. Do NOT run git. Do NOT commit or stage anything.
- Write ONLY what this phase specifies. Do NOT implement feature LOGIC — the contract pass wires + stubs; feature builders fill logic later. (Exception: the named retrofits to already-built services, which ARE this pass's job.)
- After each edit, run stylua on the files you wrote (a PostToolUse hook nags otherwise; heal with "stylua <file>"). Keep --!strict on every module.
- VERIFY by running: lune run .claude/skills/lib/gauntlet.luau ${gameDir} — iterate until it ends {"ok":true,...}. Report the lune stage {"passed":X,"failed":Y,"total":Z}. FIRST run it BEFORE you edit anything and note the baseline pass count: the existing tests MUST NOT regress, and you need the baseline to prove that.
- Do not invent fields, actions, seams or services the contract does not name.
${contractSource}`

// Appended to the LATER phase prompts only (never to GUARD, which the already-cached earlier phases
// hash on). Without it an agent obeys "iterate until ok:true" against a stage that CANNOT go green
// until fan-out, and the ways out of that loop are all bad: dated waivers written in the same turn
// that caused the findings, or gaming the maturity probe by moving services out of the tree.
const KNOWN_RED = (input && input.knownRedNote) || ''

// ---- schemas (kept terse: an over-large output schema is rejected by the safety classifier
// before the agent ever runs, and the workflow then returns the same shape as a clean no-op) ----
const SCHEMA_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    baselineLune: { type: 'string' },
    currentSchemaVersion: { type: 'number' },
    netActionsAdded: { type: 'array', items: { type: 'string' } },
    fieldsAdded: { type: 'array', items: { type: 'string' } },
    migrationRoundTrip: { type: 'array', items: { type: 'object', properties: { step: { type: 'string' }, testAdded: { type: 'boolean' }, falsifiability: { type: 'string' } }, required: ['step', 'testAdded', 'falsifiability'] } },
    defaultSeeds: { type: 'array', items: { type: 'string' } },
    ctxSeamsDeclared: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'currentSchemaVersion', 'netActionsAdded', 'fieldsAdded', 'migrationRoundTrip', 'defaultSeeds', 'blockers'],
}
const ANALYTICS_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    emitSeam: { type: 'string' },
    lifecycleSites: { type: 'array', items: { type: 'string' } },
    testable: { type: 'string' },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'emitSeam', 'lifecycleSites', 'blockers'],
}
const RETROFIT_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    behaviorPreserved: { type: 'boolean' },
    retrofitsApplied: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, what: { type: 'string' }, nilSafe: { type: 'boolean' } }, required: ['file', 'what'] } },
    lifetimeOnlyOnEarns: { type: 'boolean' },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'behaviorPreserved', 'retrofitsApplied', 'lifetimeOnlyOnEarns', 'blockers'],
}
const STUBS_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    stubsCreated: { type: 'array', items: { type: 'object', properties: { service: { type: 'string' }, registeredActions: { type: 'array', items: { type: 'string' } }, seamProvided: { type: 'string' } }, required: ['service', 'registeredActions'] } },
    registeredInInit: { type: 'boolean' },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'stubsCreated', 'registeredInInit', 'blockers'],
}
const VERIFY_RESULT = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'issues', 'fail'] },
    gauntletOk: { type: 'boolean' },
    netActionsComplete: { type: 'boolean' },
    migrationsFalsifiable: { type: 'boolean' },
    versionBumpCorrect: { type: 'boolean' },
    defaultSeedsComplete: { type: 'boolean' },
    retrofitsBehaviorPreserving: { type: 'boolean' },
    analyticsStoodUp: { type: 'boolean' },
    stubsRegistered: { type: 'boolean' },
    featureLogicLeak: { type: 'boolean' },
    discrepancies: { type: 'array', items: { type: 'object', properties: { area: { type: 'string' }, severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] }, detail: { type: 'string' } }, required: ['area', 'severity', 'detail'] } },
    notes: { type: 'string' },
  },
  required: ['verdict', 'gauntletOk', 'netActionsComplete', 'migrationsFalsifiable', 'versionBumpCorrect', 'defaultSeedsComplete', 'retrofitsBehaviorPreserving', 'analyticsStoodUp', 'stubsRegistered', 'featureLogicLeak', 'discrepancies'],
}

// ---- helper: abort early if a phase did not go green ----
//
// ORCHESTRATOR OVERRIDE (args.allowGauntletRedAt: [phaseLabel, ...]).
// A workflow script cannot run the gauntlet — it has no filesystem and no shell — so all it has is
// the agent's own `gauntletOk` boolean. It therefore CANNOT distinguish "only the reachability
// stage is red, because the features it checks for do not exist yet" from "the test suite is red".
// That distinction requires actually running the gauntlet, which only the orchestrator can do.
//
// So the override is deliberately NOT a judgement this script makes. The orchestrator runs the
// gauntlet itself, sees which stages are red, and passes an explicit per-phase allowance. It is
// logged loudly at the point of use so the allowance shows up in the run record and at the human
// gate, rather than quietly turning a red phase into a green one.
//
// Default is empty: with no override, ANY red gauntlet aborts the pass, as before.
const allowGauntletRedAt = (input && input.allowGauntletRedAt) || []
function aborted(label, r) {
  if (!r) {
    log(`contract-pass: ${label} returned null — aborting the pass; orchestrator inspects the partial state.`)
    return true
  }
  if (!r.gauntletOk) {
    if (allowGauntletRedAt.includes(label)) {
      log(
        `contract-pass: ${label} did NOT end gauntlet-green, but the ORCHESTRATOR passed an explicit allowance for this phase (allowGauntletRedAt includes "${label}"). ` +
          `Continuing. This is NOT a pass — the phase is recorded red and the reason must survive to the human gate. Agent blockers: ${(r.blockers || []).join(' ;; ')}`
      )
      return false
    }
    log(`contract-pass: ${label} did NOT end gauntlet-green — aborting the pass; orchestrator inspects the partial state. blockers: ${r && r.blockers ? r.blockers.join('; ') : 'agent returned null'}`)
    return true
  }
  return false
}

// ============================ PHASE 1: SCHEMA ============================
phase('Schema')
const schema = await agent(
  `You are the CONTRACT-PASS SCHEMA author for ${gameDir}. Write ALL shared schema deltas the approved plan specifies, plus self-verifying migration round-trip tests. This is the foundation every feature builds on — be exact.

${GUARD}

READ FIRST (in full):
- ${gameDir}/src/shared/Types.luau — PlayerData + PlayerView + toView + CURRENT_SCHEMA_VERSION. Note which sub-tables are CLOSED literals (e.g. stats, timestamps) and which are OPEN maps (currencies, upgrades, flags, receipts).
- ${gameDir}/src/shared/Migrations.luau — steps[] + default() + migrate(). Study the EXISTING steps: every step MUST stamp the new version or migrate() infinite-loops, and default() is a SEPARATE code site from the steps.
- ${gameDir}/src/shared/Net.luau — Net.Actions + the ActionContext seam list.
- ${gameDir}/src/server/Context.luau — ServerContext.
- ${gameDir}/tests/unit/migration.spec.luau — the existing round-trip test idioms.
- ${gameDir}/tests/unit/data.spec.luau if present — default()-shape assertions your new seeds may change.

WRITE exactly what the contract spec above says, and nothing more:
1. Net.luau: add the ${netActions.length} Net.Actions entries in contract.netActions (key -> wire string). If a reserved placeholder comment already stands in for one, replace it with the real entry. Add each new optional ctx seam in contract.newCtxSeams (${JSON.stringify(ctxSeams)}) to ActionContext as "<name>: any?" AND to ServerContext in Context.luau — nil in the spine, populated later by a stub/feature service.
2. Types.luau: add each field in contract.typedFields. PRECISION — get this right per field:
   - a NEW TOP-LEVEL field goes on PlayerData, and if clientFacing it ALSO goes on PlayerView AND needs its own line in Types.toView.
   - a field that RIDES AN EXISTING CLOSED SUB-TABLE (e.g. "stats.<x>") is added to that sub-table's type literal on PlayerData AND (if clientFacing) on PlayerView — but toView copies that sub-table WHOLESALE, so add NO new toView line for it.
   - a field that rides an OPEN MAP (a new currencies/upgrades/flags/receipts KEY) needs NO type change at all — only a default() seed.
   Then bump CURRENT_SCHEMA_VERSION to ${contract.toSchemaVersion}.
3. Migrations.luau: add one steps[i] per entry in contract.migrations (i = fromVersion). Each step MUST (a) seed its field IDEMPOTENTLY, preserving any existing value, and (b) STAMP schemaVersion = toVersion. Then update default() — the fresh-player blob — to ALSO seed every new field: ${JSON.stringify(seedList)}. A seed present in the steps but missing from default() means fresh players ship without the field; that is the classic gap.
4. tests/unit/migration.spec.luau: add a SELF-VERIFYING round-trip test per new step. Each must assert that after migrate() on a prior-version blob: schemaVersion == the new CURRENT, the new field is present with the seeded value, AND all prior fields are preserved — so a forgotten stamp (infinite loop), a missing seed (nil field), or a clobbered field would FAIL the test. Add an idempotency assertion too (re-migrating an already-current blob must not reset an advanced value).

Make the gauntlet green — the baseline tests you recorded BEFORE editing plus your new ones. If a default()-shape assertion legitimately changes because you added a seed, UPDATE it by ADDING the new expectation; never weaken an assertion to get green. Return the StructuredOutput (baselineLune = the pass count before you edited).`,
  { label: 'contract:schema', phase: 'Schema', schema: SCHEMA_RESULT, effort: 'high' }
)

if (aborted('schema', schema)) {
  return { gameDir, ok: false, abortedAt: 'schema', schema, analytics: null, retrofits: null, stubs: null, verify: null }
}
log(`contract-pass: schema green. version=${schema.currentSchemaVersion}; fields=[${(schema.fieldsAdded || []).join(', ')}]; actions=[${(schema.netActionsAdded || []).join(', ')}].`)

// ============================ PHASE 2: INFRA (analytics + every other shared service) ============================
// The plan's contractPassExtras.sharedServices are the cross-cutting concerns NO feature builder can
// own, because the sites they hook live in OTHER features. Whatever the plan names gets stood up
// here — an analytics emitter, a single-writer economy helper, a client-framework guard — not just
// analytics. Building any of them per-feature would build them once per feature.
phase('Analytics')
const sharedServiceSpec = (contract.sharedServices || [])
  .map((s, i) => `  ${i + 1}. ${s.name} (${s.serviceName})\n     PURPOSE: ${s.purpose}`)
  .join('\n')
const analytics = await agent(
  `You are the CONTRACT-PASS INFRASTRUCTURE author for ${gameDir}. Stand up the shared, cross-cutting modules every feature will lean on — so each is built EXACTLY ONCE here, instead of once per feature during fan-out.

${GUARD}

READ FIRST: ${gameDir}/src/server/services/sample/SampleService.luau (the service { name, Start(context) } pattern + context.net:register), ${gameDir}/src/server/Context.luau (ServerContext — the reserved seams to populate), ${gameDir}/src/server/init.server.luau (service registration order + the player join/leave lifecycle), ${gameDir}/src/client/init.client.luau and ${gameDir}/src/client/framework/ (if a client-side module is in scope), ${gameDir}/src/shared/Net.luau (the ActionContext seams the schema phase just declared).

STAND UP EACH OF THESE, exactly as its purpose describes:
${sharedServiceSpec || '  (none listed — then stand up the analytics emitter only, per contract.analytics)'}

RULES THAT APPLY TO ALL OF THEM:
- Populate the matching ctx seam in ServerContext (Context.luau) AND make sure it reaches the ActionContext projection (NetServer), then register the service in init.server.luau in an order where a dependency starts before its dependents. A seam declared but never assigned is a nil every handler will silently fall through.
- TIER-1 OBSERVABLE: whatever these modules do must be assertable from a Lune test with no Roblox runtime. For an event emitter that means an in-memory buffer or injectable sink the service exposes. Server-clock timestamp everything via ctx.clock:unix() — never client time, never a bare os.time inside a handler.
- The analytics taxonomy this game must eventually emit is ${JSON.stringify(analyticsEvents)}, and the emit seam is ${JSON.stringify(analyticsSpec.seam || 'ctx.analytics:emit(event, payload)')}. You stand up the SEAM plus the session lifecycle events (${JSON.stringify(analyticsSpec.lifecycle || ['session_start on join', 'session_end on leave/release'])}) ONLY — the per-feature domain emits belong to each feature builder, and writing them here too would build them twice.
- Any economy/currency helper you stand up must be a PURE transform designed to be applied INSIDE one ctx.data:update, so a feature builder physically cannot mint by reading a balance, yielding, then writing a stale value back.
- Add a small Tier-1 test per module you create, proving the seam actually works — not that it merely exists.

Gauntlet green. Return the StructuredOutput (filesTouched must list EVERY module you created).`,
  { label: 'contract:infra', phase: 'Analytics', schema: ANALYTICS_RESULT, effort: 'high' }
)

if (aborted('analytics', analytics)) {
  return { gameDir, ok: false, abortedAt: 'analytics', schema, analytics, retrofits: null, stubs: null, verify: null }
}
log(`contract-pass: analytics green. emit=${analytics.emitSeam}; lifecycle=[${(analytics.lifecycleSites || []).join(', ')}].`)

// ============================ PHASE 3: RETROFITS (skipped when none) ============================
phase('Retrofits')
let retrofits = null
if (retrofitList.length === 0) {
  log('contract-pass: no retrofits in the contract (fresh scaffold — nothing is built yet). Skipping the retrofit phase; the cross-cutting earn/emit hooks are owned by the feature builders via the plan emitPoints/earnPaths.')
  retrofits = { skipped: true, gauntletOk: true, filesTouched: [], retrofitsApplied: [], behaviorPreserved: true, lifetimeOnlyOnEarns: true, luneResult: 'n/a (skipped)', blockers: [] }
} else {
  retrofits = await agent(
    `You are the CONTRACT-PASS RETROFIT author for ${gameDir}. Apply the named edits to ALREADY-BUILT, already-merged services. These are cross-cutting hooks no feature builder may make, because the code is outside their slice. Minimal, surgical, BEHAVIOR-PRESERVING.

${GUARD}

READ FIRST, IN FULL, every file named in contract.retrofits: ${JSON.stringify(retrofitList.map((r) => r.file))}. Study how each one mutates player data inside its ctx.data:update transform (the concurrency-safe pattern), and how the analytics emit seam is called (from the infra phase you just saw). The new player-data fields from the schema phase exist now and every player has them post-migration.

contract.retrofits is the FULL BLAST RADIUS — every file this whole pass touches, listed so the human diff-review sees all of it. That means SOME entries were already applied by the earlier phases (the shared schema files, the infra services, the context/bootstrap wiring, the stub registrations). So, for EACH of the ${retrofitList.length} entries, FIRST determine which case it is:
- ALREADY APPLIED by the schema or infra phase -> VERIFY it actually landed as described (read the file; if it did NOT land, that is a real gap — apply it now and say so in notes). Do NOT redo or re-litigate work that is already correct.
- NOT YET APPLIED -> apply it now, EXACTLY as its "change" describes.
Report each entry in retrofitsApplied either way, so nothing is silently assumed done.

Two invariants govern all of them:

1. BEHAVIOR-PRESERVING under absent seams — with ONE deliberate exception, below. Where a retrofit consolidates a formula that will later be influenced by not-yet-built features, read every such seam NIL-SAFELY so it defaults to the identity (a multiplier defaults to 1, an additive bonus to 0), e.g. "local m = (ctx.<seam> and ctx.<seam>:<method>(...)) or 1". With the stubs returning identity and the new counters at 0, the consolidated formula MUST equal the CURRENT behavior exactly — so every existing test passes UNCHANGED. That equality is the whole safety property of this phase.

2. EARN vs SPEND. Any lifetime/aggregate EARN counter is incremented ONLY on the earn paths the contract lists (contract.earnPaths = ${JSON.stringify(contract.earnPaths || [])}) and NEVER on a spend, reset or prestige path. Increment it inside the SAME ctx.data:update transform that credits the currency — never in a second, racing update. Emit the contract's event for that site AFTER the update succeeds, never before (a post-write emit that can itself fail must not turn a committed transaction into an error — guard it).

THE ONE DELIBERATE EXCEPTION to invariant 1: a retrofit whose stated purpose is to CORRECT something this game INHERITED from the foundation it was forked from (most commonly: scaffold code and tests still naming the FOUNDATION game's currency or constants) is meant to change that value — that is the entire point of the edit. For those, "preserving behavior" means preserving the test's INTENT while retargeting its subject: an assertion about a balance must still assert the same property about THIS game's balance. Retarget it; do not delete it, and do not weaken it to make the suite green. Where the retrofit list names a set of files to retarget, GREP THE WHOLE GAME for the old identifier afterwards — a list assembled by reading is usually a few sites short, and a missed site is a nil read at runtime, not a test failure.

Make the gauntlet green. Existing tests must not be weakened: if a built test must change because a field legitimately appears or a subject was legitimately retargeted, prefer ADDING assertions over removing one. Return the StructuredOutput and set behaviorPreserved + lifetimeOnlyOnEarns TRUTHFULLY — a false claim here is worse than a red gauntlet.
${KNOWN_RED}`,
    { label: 'contract:retrofits', phase: 'Retrofits', schema: RETROFIT_RESULT, effort: 'high' }
  )

  if (aborted('retrofits', retrofits)) {
    return { gameDir, ok: false, abortedAt: 'retrofits', schema, analytics, retrofits, stubs: null, verify: null }
  }
  log(`contract-pass: retrofits green. behaviorPreserved=${retrofits.behaviorPreserved}; lifetimeOnlyOnEarns=${retrofits.lifetimeOnlyOnEarns}.`)
}

// ============================ PHASE 4: STUBS ============================
phase('Stubs')
const stubs = await agent(
  `You are the CONTRACT-PASS STUB author for ${gameDir}. Create a registered STUB service per new feature so the wire is complete before fan-out — feature builders will REPLACE each stub with real logic.

${GUARD}

READ FIRST: ${gameDir}/src/server/services/sample/SampleService.luau (the service + Start + context.net:register pattern), ${gameDir}/src/server/init.server.luau (registration), ${gameDir}/src/shared/Net.luau (the Net.Actions you just added + the Action shape { name, validate, rate, handler, ownerOf? }), ${gameDir}/src/shared/Result.luau (the EXACT Result.Codes — use them verbatim).

For EACH feature in contract.stubs (${JSON.stringify(stubList.map((s) => s.name || s))}) create ${gameDir}/src/server/services/<name>/<serviceName>.luau:
- A module { name = "<serviceName>", Start(context) } that registers its listed action(s) on context.net with a STUB handler: a valid validate (permissive passthrough -> Result.ok(payload), or a minimal typed value), a sane default rate policy, and a handler returning Result.err(Result.Codes.Internal, "stub: <name> not implemented"). For a read-only fetch action, Result.ok of an empty/default shape is fine. The stub must COMPILE and pass dispatch wiring — nothing more.
- IDENTITY-DEFAULT ctx seam: where contract.stubs says this feature PROVIDES a seam that another site already consumes, the stub populates that seam NOW with the identity default (returns 1 for a multiplier, 0 for a bonus, false for a gate, a no-op for a command) so every consuming formula composes to current behavior. The real builder replaces it. This is what keeps the retrofits behavior-preserving.
- Register EVERY stub service in init.server.luau.
- Do NOT write feature LOGIC — these are stubs. Do NOT write client controllers (each hasUI builder writes its own).

Gauntlet green (all actions registered, dispatch wiring intact, no regression against the baseline). Return the StructuredOutput.
${KNOWN_RED}`,
  { label: 'contract:stubs', phase: 'Stubs', schema: STUBS_RESULT, effort: 'high' }
)

if (aborted('stubs', stubs)) {
  return { gameDir, ok: false, abortedAt: 'stubs', schema, analytics, retrofits, stubs, verify: null }
}
log(`contract-pass: stubs green. created=[${(stubs.stubsCreated || []).map((s) => s.service).join(', ')}].`)

// ============================ PHASE 5: VERIFY (independent) ============================
phase('Verify')
const verify = await agent(
  `You are an INDEPENDENT VERIFIER of a just-completed contract pass for ${gameDir}. You did NOT write it. Audit the WHOLE diff against the approved contract spec and try to find what is wrong, missing, or over-reaching. Reading + reasoning + running the gauntlet ONLY — do NOT edit anything.

${contractSource}

INSPECT the current working tree (the contract pass already ran). Use "git status" and "git diff" to see EVERY file it touched rather than guessing, then read: ${gameDir}/src/shared/{Net,Types,Migrations,Result}.luau; ${gameDir}/src/server/Context.luau and init.server.luau; every service dir under ${gameDir}/src/server/services/; ${gameDir}/tests/unit/migration.spec.luau and any new tests. Run "lune run .claude/skills/lib/gauntlet.luau ${gameDir}" to confirm green yourself — do not take the makers' word for it.

CHECK and report (be specific, cite file + line):
- netActionsComplete: are all ${netActions.length} contract Net.Actions present AND each actually REGISTERED by some service (a declared action nobody registers is a dead wire)?
- migrationsFalsifiable: read each new migration step WITH its round-trip test. Reason adversarially: if the step FORGOT to stamp the version (infinite loop) or FORGOT to seed the field (nil), would the test FAIL? If a test would still pass under a broken step, it is NOT self-verifying — flag it. Confirm the versions are contiguous and CURRENT_SCHEMA_VERSION == ${contract.toSchemaVersion}.
- defaultSeedsComplete: does Migrations.default() seed ALL of ${JSON.stringify(seedList)} for FRESH players, not just the migrate() steps? A field seeded only in a step means every brand-new player is missing it.
- retrofitsBehaviorPreserving: ${retrofitList.length === 0 ? 'no retrofits were in scope (fresh scaffold) — report true, and instead CHECK that the contract pass did NOT silently edit code outside src/shared, the analytics service, and the new stub dirs.' : 'is each consolidated formula behavior-identical to the prior behavior when the feature seams are absent (multipliers default 1, new counters 0)? Is the lifetime/aggregate counter incremented ONLY on the contract earnPaths and NEVER on a spend/reset? Are the seam reads genuinely nil-safe? Is each post-write emit guarded so it cannot turn a committed write into an error?'}
- analyticsStoodUp: is the emit seam wired and Tier-1 OBSERVABLE, with the session lifecycle events firing on join/leave? Are events server-clock timestamped?
- stubsRegistered: is every stub in contract.stubs created AND registered in init.server.luau, with the identity-default seams present?
- featureLogicLeak: did the pass write real feature LOGIC beyond wiring, stubs, and the named retrofits? It should NOT have. A stub that "helpfully" implements its feature is a leak — flag it.

verdict: 'pass' (faithful to the plan, gauntlet green, migrations falsifiable, behavior preserved) / 'issues' (green but discrepancies to fix) / 'fail' (not green, or a migration is not self-verifying, or feature logic leaked). Put EVERY finding in discrepancies with a severity. Return the StructuredOutput.`,
  { label: 'contract:verify', phase: 'Verify', schema: VERIFY_RESULT, effort: 'high' }
)

const critical = (verify && verify.discrepancies ? verify.discrepancies : []).filter((d) => d.severity === 'critical' || d.severity === 'high')
log(`contract-pass DONE. verify verdict: ${verify ? verify.verdict : 'n/a'} | gauntletOk: ${verify ? verify.gauntletOk : 'n/a'} | ${critical.length} critical/high discrepancy(ies). Orchestrator reviews the diff + this report, then the human reviews before fan-out.`)

return {
  gameDir,
  ok: !!(verify && verify.verdict === 'pass' && verify.gauntletOk && !verify.featureLogicLeak),
  schema,
  analytics,
  retrofits,
  stubs,
  verify,
}
