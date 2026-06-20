// contract-pass.js — build-game Workflow A, phase 2: the SERIAL guarded contract pass.
//
// The serial barrier that runs ONCE, BEFORE feature fan-out, writing every shared-contract delta
// the approved decompose plan foresaw — so parallel feature builders only ever create their own
// disjoint service files and never collide on src/shared (BUILD-GAME-DESIGN.md §4b + §13).
//
// Decision #2 (cross-cutting = contract-pass infrastructure) expands this beyond pure src/shared:
// it also stands up the analytics emitter and RETROFITS already-built/merged services (collection,
// daily, shop) for lifetime accrual + analytics emission. Those built-code edits are the highest
// blast radius — which is exactly why this is GUARDED (hard rules + gauntlet-green gates + an
// independent verifier) and why the human reviews the real diff before any fan-out.
//
// FOUR serial build phases, each gated gauntlet-green (early-abort on red so a broken base never
// piles up), then an INDEPENDENT VERIFIER (maker != checker):
//   1. schema    — Net.Actions, Types fields + PlayerView/toView, Migrations steps + default seeds,
//                  CURRENT_SCHEMA_VERSION bump, new nil-safe ctx seams, + SELF-VERIFYING migration
//                  round-trip tests (a broken step must fail them).
//   2. analytics — stand up the AnalyticsService emitter on ctx.analytics + session_start/end.
//   3. retrofits — the 4 edits to built collection/daily/shop (behavior-preserving when feature
//                  seams are absent, so the existing tests stay green).
//   4. stubs     — registered stub services for the 6 new features (+ identity-default ctx seams)
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
  description: 'build-game Workflow A.2: the SERIAL guarded contract pass. Writes every shared-contract delta the approved decompose plan foresaw (Net.Actions, Types fields, Migrations steps + self-verifying round-trip tests, schema-version bump, nil-safe ctx seams), stands up the analytics emitter, and retrofits the already-built collection/daily/shop services for lifetime accrual + analytics — in four serial gauntlet-green phases, then an independent verifier audits the whole diff vs the plan. Commits nothing; writes no feature logic.',
  phases: [
    { title: 'Schema', detail: 'Net.Actions, Types fields + PlayerView/toView, Migrations steps + default seeds, version bump, nil-safe ctx seams, + self-verifying migration round-trip tests' },
    { title: 'Analytics', detail: 'stand up the AnalyticsService emitter on ctx.analytics + session_start/session_end lifecycle' },
    { title: 'Retrofits', detail: 'the 4 edits to built collection/daily/shop (behavior-preserving when feature seams absent)' },
    { title: 'Stubs', detail: 'registered stub services for the 6 new features + identity-default ctx seams' },
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
const gameDir = (input && input.gameDir) || 'games/collect-sim'
const contract = (input && input.contract) || {}
const contractJson = JSON.stringify(contract, null, 2)
log(`contract-pass: ${gameDir}; schema v${contract.fromSchemaVersion} -> v${contract.toSchemaVersion}; ${(contract.netActions || []).length} Net.Actions, ${(contract.typedFields || []).length} typed field(s), ${(contract.retrofits || []).length} retrofit(s), ${(contract.stubs || []).length} stub(s).`)

// ---- shared guard rules every phase agent must obey ----
const GUARD = `HARD GUARD RULES (every phase of the contract pass):
- You are at repo root, on the staging branch. Do NOT run git. Do NOT commit or stage anything.
- Write ONLY what this phase specifies. Do NOT implement feature LOGIC — the contract pass wires + stubs; feature builders fill logic later. (Exception: the named retrofits to already-built services, which ARE this pass's job.)
- After each edit, run stylua on the files you wrote (a PostToolUse hook nags otherwise; heal with \`stylua <file>\`). Keep --!strict on every module.
- VERIFY by running: lune run .claude/skills/lib/gauntlet.luau ${gameDir} — iterate until it ends {"ok":true,...}. Report the lune stage {"passed":X,"failed":Y,"total":Z}. The existing tests MUST NOT regress.
- The approved contract spec (your single source of truth for WHAT to write):
-----
${contractJson}
-----`

// ---- schemas ----
const SCHEMA_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    currentSchemaVersion: { type: 'number', description: 'the value you set CURRENT_SCHEMA_VERSION to (must equal contract.toSchemaVersion)' },
    netActionsAdded: { type: 'array', items: { type: 'string' } },
    fieldsAdded: { type: 'array', items: { type: 'string' } },
    migrationRoundTrip: { type: 'array', items: { type: 'object', properties: { step: { type: 'string', description: 'e.g. "v2->v3 rebirths"' }, testAdded: { type: 'boolean' }, falsifiability: { type: 'string', description: 'WHY the test is self-verifying: what it asserts that a broken/forgotten step would FAIL (e.g. "asserts schemaVersion==3 after migrate + rebirths present + preserves existing fields; an unstamped step would infinite-loop / a missing seed would nil")' } }, required: ['step', 'testAdded', 'falsifiability'] } },
    defaultSeeds: { type: 'array', items: { type: 'string' }, description: 'the fresh-player Migrations.default fields you seeded (must include Prisms, rebirths, stats.lifetimeStardust)' },
    ctxSeamsDeclared: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'anything that prevented a clean green (empty if fully green)' },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'currentSchemaVersion', 'netActionsAdded', 'fieldsAdded', 'migrationRoundTrip', 'defaultSeeds', 'blockers'],
}
const ANALYTICS_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    emitSeam: { type: 'string', description: 'the emit API you exposed, e.g. "ctx.analytics:emit(event, payload)"' },
    lifecycleSites: { type: 'array', items: { type: 'string' }, description: 'where session_start / session_end fire' },
    testable: { type: 'string', description: 'how a Tier-1 test can observe an emit (e.g. an in-memory event buffer the AnalyticsService exposes)' },
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
    sellBehaviorPreserved: { type: 'boolean', description: 'TRUE if the consolidated Sell formula is identical to the prior Sell when every feature seam is absent (all multipliers default 1) — the existing collection tests must still pass unchanged' },
    retrofitsApplied: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, what: { type: 'string' }, nilSafe: { type: 'boolean' } }, required: ['file', 'what'] } },
    lifetimeOnlyOnEarns: { type: 'boolean', description: 'TRUE if stats.lifetimeStardust is incremented ONLY on earn paths (sell, daily) and NOT on the shop spend' },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesTouched', 'gauntletOk', 'luneResult', 'sellBehaviorPreserved', 'retrofitsApplied', 'lifetimeOnlyOnEarns', 'blockers'],
}
const STUBS_RESULT = {
  type: 'object',
  properties: {
    filesTouched: { type: 'array', items: { type: 'string' } },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    stubsCreated: { type: 'array', items: { type: 'object', properties: { service: { type: 'string' }, registeredActions: { type: 'array', items: { type: 'string' } }, seamProvided: { type: 'string', description: 'identity-default ctx seam this stub exposes, if any (e.g. "ctx.islands:multiplierFor(d) -> 1")' } }, required: ['service', 'registeredActions'] } },
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
    migrationsFalsifiable: { type: 'boolean', description: 'did you confirm each round-trip test genuinely fails if its step is broken/forgotten (reason about it; flip a thing mentally)?' },
    versionBumpCorrect: { type: 'boolean' },
    defaultSeedsComplete: { type: 'boolean' },
    retrofitsBehaviorPreserving: { type: 'boolean' },
    analyticsStoodUp: { type: 'boolean' },
    stubsRegistered: { type: 'boolean' },
    featureLogicLeak: { type: 'boolean', description: 'TRUE if the contract pass wrote real feature LOGIC beyond wiring/stubs/named-retrofits (it should NOT have)' },
    discrepancies: { type: 'array', items: { type: 'object', properties: { area: { type: 'string' }, severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] }, detail: { type: 'string' } }, required: ['area', 'severity', 'detail'] } },
    notes: { type: 'string' },
  },
  required: ['verdict', 'gauntletOk', 'netActionsComplete', 'migrationsFalsifiable', 'versionBumpCorrect', 'defaultSeedsComplete', 'retrofitsBehaviorPreserving', 'analyticsStoodUp', 'stubsRegistered', 'featureLogicLeak', 'discrepancies'],
}

// ---- helper: abort early if a phase did not go green ----
function aborted(label, r) {
  if (!r || !r.gauntletOk) {
    log(`contract-pass: ${label} did NOT end gauntlet-green — aborting the pass; orchestrator inspects the partial state. blockers: ${r && r.blockers ? r.blockers.join('; ') : 'agent returned null'}`)
    return true
  }
  return false
}

// ============================ PHASE 1: SCHEMA ============================
phase('Schema')
const schema = await agent(`You are the CONTRACT-PASS SCHEMA author for ${gameDir}. Write ALL shared schema deltas the approved plan specifies, plus self-verifying migration round-trip tests. This is the foundation every feature builds on — be exact.

${GUARD}

READ FIRST: ${gameDir}/src/shared/Types.luau (PlayerData + PlayerView + toView + CURRENT_SCHEMA_VERSION), ${gameDir}/src/shared/Migrations.luau (steps[] + default() + migrate() — study the existing v1->v2 step[1]: it MUST stamp the new version or migrate() infinite-loops), ${gameDir}/src/shared/Net.luau (Net.Actions + ActionContext seams: analytics?/monetization? are already reserved), ${gameDir}/src/server/Context.luau (ServerContext), ${gameDir}/tests/unit/migration.spec.luau (the existing round-trip test idioms), ${gameDir}/tests/unit/data.spec.luau if present (default()-shape assertions you may need to update).

WRITE (per the contract spec above):
1. Net.luau: add the ${(contract.netActions || []).length} Net.Actions entries (replace the reserved [B2] placeholder comments for Rebirth/Claim with the real entries). Add the new optional ctx seams ${JSON.stringify(contract.newCtxSeams || [])} to ActionContext (as \`<name>: any?\`) AND to ServerContext in Context.luau — nil in the spine, populated later by feature/stub services.
2. Types.luau: add each typed field. PRECISION (from the plan, do EXACTLY): a TOP-LEVEL field (rebirths) goes on PlayerData AND PlayerView AND needs a toView line. A field that RIDES an existing closed sub-table (stats.lifetimeStardust) is added to the PlayerData.stats AND PlayerView.stats type literals ONLY — toView copies stats wholesale, so add NO toView line for it. Bump CURRENT_SCHEMA_VERSION to ${contract.toSchemaVersion}.
3. Migrations.luau: add one steps[i] per migration (i = fromVersion). Each step MUST seed its field idempotently (preserve any existing value) AND STAMP schemaVersion = toVersion. Seed lifetimeStardust FLOORED at currencies.Stardust (math.floor). Update default() (the fresh-player blob) to ALSO seed the new fields (currencies.Prisms=0, rebirths=0, stats.lifetimeStardust=0) — default() is a SEPARATE code site from the steps.
4. tests/unit/migration.spec.luau: add a SELF-VERIFYING round-trip test per new step. Each must assert that after migrate() on a prior-version blob: schemaVersion == the new CURRENT, the new field is present with the seeded value, AND all prior fields are preserved — so a forgotten stamp (infinite-loop), a missing seed (nil field), or a clobbered field would FAIL the test. Also add an idempotency assertion (re-migrating an already-current blob does not reset an advanced value).

Make the gauntlet green (existing 129 + your new tests; update any default()-shape assertion in data.spec that your new seeds change). Return the StructuredOutput.`, { label: 'contract:schema', phase: 'Schema', schema: SCHEMA_RESULT, effort: 'high' })

if (aborted('schema', schema)) {
  return { gameDir, ok: false, abortedAt: 'schema', schema, analytics: null, retrofits: null, stubs: null, verify: null }
}
log(`contract-pass: schema green. version=${schema.currentSchemaVersion}; fields=[${(schema.fieldsAdded || []).join(', ')}]; actions=[${(schema.netActionsAdded || []).join(', ')}].`)

// ============================ PHASE 2: ANALYTICS ============================
phase('Analytics')
const analytics = await agent(`You are the CONTRACT-PASS ANALYTICS author for ${gameDir}. Stand up the single analytics emitter every feature emits through (so the taxonomy is built exactly once, not per-feature).

${GUARD}

READ FIRST: ${gameDir}/src/server/services/sample/SampleService.luau (the service { name, Start(context) } pattern + context.net:register), ${gameDir}/src/server/Context.luau (ServerContext — ctx.analytics is the reserved seam to populate), ${gameDir}/src/server/init.server.luau (service registration + the player join/leave lifecycle), ${gameDir}/src/shared/Net.luau (ActionContext.analytics is already \`any?\`).

WRITE per the contract.analytics spec:
- ${gameDir}/src/server/services/analytics/AnalyticsService.luau — a service { name = "AnalyticsService", Start(context) } that exposes the emit seam (contract.analytics.seam) and populates ctx.analytics so any handler can call it. Fire session_start on player join and session_end on player leave/release via the bootstrap lifecycle.
- Make emits Tier-1 OBSERVABLE: expose an in-memory event buffer (or injectable sink) the AnalyticsService keeps, so a test can assert "event X fired with payload Y". Server-clock timestamp each event via ctx.clock:unix().
- Wire ctx.analytics into ServerContext (Context.luau) + the ActionContext projection (NetServer), and register AnalyticsService in init.server.luau.
- Do NOT make features emit yet (that is their job / the retrofit's job) — only stand up the emitter + the session lifecycle. Add a small Tier-1 test for the emitter itself (emit -> buffered + timestamped) so the seam is proven.

Gauntlet green. Return the StructuredOutput.`, { label: 'contract:analytics', phase: 'Analytics', schema: ANALYTICS_RESULT, effort: 'high' })

if (aborted('analytics', analytics)) {
  return { gameDir, ok: false, abortedAt: 'analytics', schema, analytics, retrofits: null, stubs: null, verify: null }
}
log(`contract-pass: analytics green. emit=${analytics.emitSeam}; lifecycle=[${(analytics.lifecycleSites || []).join(', ')}].`)

// ============================ PHASE 3: RETROFITS ============================
phase('Retrofits')
const retrofits = await agent(`You are the CONTRACT-PASS RETROFIT author for ${gameDir}. Apply the named edits to ALREADY-BUILT, already-merged services. These are cross-cutting hooks no feature builder may make. Minimal, surgical, BEHAVIOR-PRESERVING.

${GUARD}

READ FIRST: ${gameDir}/src/server/services/collection/CollectionService.luau (the Sell + Collect handlers + the backpack/economy concurrency pattern — study how Sell credits Stardust inside the ctx.data:update transform), ${gameDir}/src/server/services/daily/DailyStreakService.luau (the claim transform), ${gameDir}/src/server/services/shop/UpgradesShopService.luau (the BuyUpgrade transform + its rejectCode pattern), and how ctx.analytics:emit is called (from the analytics phase). Note the new player-data fields (rebirths, stats.lifetimeStardust) exist now and every player has them post-migration.

APPLY the ${(contract.retrofits || []).length} retrofits in contract.retrofits EXACTLY:
- collection Sell -> the CONSOLIDATED server-derived earn formula. CRITICAL: it MUST be behavior-IDENTICAL to the current Sell when every feature seam is absent — read the seams NIL-SAFELY so each multiplier defaults to 1 (e.g. \`local im = (ctx.islands and ctx.islands:multiplierFor(d)) or 1\`; same for restock; \`local sm = (ctx.monetization and ctx.monetization:stardustMultiplier(player.UserId)) or 1\`; \`local rm = 1 + (d.rebirths or 0) * REBIRTH_STEP\`). earned = baseSellValue * im * rm_restock * sm * rm. With stubs returning 1 and rebirths=0 this equals the current earned, so the existing 129 tests pass UNCHANGED. After crediting Stardust, increment stats.lifetimeStardust by the SAME earned inside the same transform, and after a successful update emit currency_earned via ctx.analytics.
- collection Auto-Collect -> a minimal, concurrency-safe, clock-driven grant gated on flags["gamepass.autoCollect"] (motes through the same backpack/ctx.data:update path; deterministic via ctx.clock; off for non-holders). Keep it small + Tier-1 testable via the injected clock; if it genuinely cannot be made testable/minimal, record that in blockers rather than over-building.
- daily claim -> after adding the reward to Stardust, increment stats.lifetimeStardust by the SAME reward + emit currency_earned.
- shop BuyUpgrade -> on a successful purchase emit currency_spent (cost + upgradeId). Do NOT touch lifetimeStardust (spend != earn).

Make the gauntlet green WITHOUT changing existing test expectations (the retrofits are additive/behavior-preserving). If a built test needs updating because a field legitimately appears, prefer ADDING assertions over weakening. Return the StructuredOutput (set sellBehaviorPreserved + lifetimeOnlyOnEarns truthfully).`, { label: 'contract:retrofits', phase: 'Retrofits', schema: RETROFIT_RESULT, effort: 'high' })

if (aborted('retrofits', retrofits)) {
  return { gameDir, ok: false, abortedAt: 'retrofits', schema, analytics, retrofits, stubs: null, verify: null }
}
log(`contract-pass: retrofits green. sellPreserved=${retrofits.sellBehaviorPreserved}; lifetimeOnlyOnEarns=${retrofits.lifetimeOnlyOnEarns}.`)

// ============================ PHASE 4: STUBS ============================
phase('Stubs')
const stubs = await agent(`You are the CONTRACT-PASS STUB author for ${gameDir}. Create a registered STUB service per new feature so the wire is complete before fan-out — feature builders will REPLACE each stub with real logic.

${GUARD}

READ FIRST: ${gameDir}/src/server/services/sample/SampleService.luau (service + Start + context.net:register pattern), ${gameDir}/src/server/init.server.luau (registration), ${gameDir}/src/shared/Net.luau (Net.Actions you just added + the Action shape { name, validate, rate, handler, ownerOf? }), ${gameDir}/src/shared/Result.luau (exact Result.Codes).

For EACH feature in contract.stubs create ${gameDir}/src/server/services/<name>/<serviceName>.luau:
- module { name = "<serviceName>", Start(context) } that registers its listed action(s) on context.net with a STUB handler: a valid validate (permissive passthrough -> Result.ok(payload) or a minimal typed value), a sane default rate policy, and a handler returning Result.err(Result.Codes.Internal, "stub: <name> not implemented") (or, for read-only fetch actions, Result.ok of an empty/default shape). The stub must COMPILE and pass dispatch wiring, nothing more.
- IDENTITY-DEFAULT ctx seam: if the contract notes this feature provides a ctx seam the Sell retrofit consumes (islands:multiplierFor(d)->1, restock:multiplierFor(d, now)->1, monetization:stardustMultiplier(userId)->1), the stub populates that seam with the identity-default method now (returns 1 / no-op) so the consolidated Sell formula composes to current behavior. The real builder replaces it.
- Register every stub service in init.server.luau.
- Do NOT write feature LOGIC — these are stubs. Do NOT write client controllers (the hasUI builder does that).

Gauntlet green (all actions registered, dispatch wiring intact, no regression). Return the StructuredOutput.`, { label: 'contract:stubs', phase: 'Stubs', schema: STUBS_RESULT, effort: 'high' })

if (aborted('stubs', stubs)) {
  return { gameDir, ok: false, abortedAt: 'stubs', schema, analytics, retrofits, stubs, verify: null }
}
log(`contract-pass: stubs green. created=[${(stubs.stubsCreated || []).map((s) => s.service).join(', ')}].`)

// ============================ PHASE 5: VERIFY (independent) ============================
phase('Verify')
const verify = await agent(`You are an INDEPENDENT VERIFIER of a just-completed contract pass for ${gameDir}. You did NOT write it. Audit the WHOLE diff against the approved contract spec and try to find what is wrong, missing, or over-reaching. Reading + reasoning + running the gauntlet only — do NOT edit anything.

The approved contract spec:
-----
${contractJson}
-----

INSPECT the current working tree (the contract pass already ran): ${gameDir}/src/shared/Net.luau, Types.luau, Migrations.luau, Result.luau; ${gameDir}/src/server/Context.luau, init.server.luau; ${gameDir}/src/server/services/{analytics,collection,daily,shop, and the 6 new stub dirs}/; ${gameDir}/tests/unit/migration.spec.luau + any new tests. Run \`lune run .claude/skills/lib/gauntlet.luau ${gameDir}\` to confirm green.

CHECK and report (be specific, cite file+line):
- netActionsComplete: all ${(contract.netActions || []).length} Net.Actions present AND each registered (by a stub or a retrofit)?
- migrationsFalsifiable: read each new migration step + its round-trip test. Reason adversarially: if the step FORGOT to stamp the version (infinite loop) or FORGOT to seed the field (nil), would the test FAIL? If a test would still pass under a broken step, it is NOT self-verifying — flag it. Confirm versions are contiguous and CURRENT_SCHEMA_VERSION == ${contract.toSchemaVersion}.
- defaultSeedsComplete: does Migrations.default seed ALL new fields (Prisms, rebirths, stats.lifetimeStardust) for fresh players, NOT just the migrate() steps?
- retrofitsBehaviorPreserving: is the consolidated Sell formula behavior-identical to the prior Sell when feature seams are absent (multipliers default 1, rebirths default 0)? Is lifetimeStardust incremented ONLY on earns (sell, daily) and NOT on the shop spend? Are the seam reads genuinely nil-safe?
- analyticsStoodUp: is ctx.analytics:emit wired + observable in Tier-1, with session_start/session_end on the lifecycle? Do feature emit sites exist where the plan's emitPoints say (or are they correctly deferred to the not-yet-built feature)?
- stubsRegistered: all 6 stubs registered + the identity-default seams present so the Sell formula composes to current behavior?
- featureLogicLeak: did the pass write real feature LOGIC beyond wiring/stubs/the 4 named retrofits? It should NOT have.

verdict: 'pass' (faithful to the plan, gauntlet green, migrations falsifiable, behavior preserved) / 'issues' (green but discrepancies to fix) / 'fail' (not green, or a migration is not self-verifying, or feature logic leaked). Put every finding in discrepancies with severity. Return the StructuredOutput.`, { label: 'contract:verify', phase: 'Verify', schema: VERIFY_RESULT, effort: 'high' })

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
