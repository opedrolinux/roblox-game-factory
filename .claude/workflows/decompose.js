// decompose.js — build-game Workflow A, phase 1: turn a game spec into a validated fan-out plan.
//
// The single highest-leverage call in build-game: ONE planner agent determines the entire
// feature fan-out + the shared-contract deltas the serial contract pass will write. So it is
// built maker != checker even here (BUILD-GAME-DESIGN.md §3):
//   PLAN   — one planner agent reads the spec + the shared contracts + the already-built
//            services, and emits {features[], contractDeltas, buildBatches} for the REMAINING
//            features only.
//   VERIFY — (a) pure-JS mechanical validation on the returned object (hyphen-free names,
//            disjoint file-sets, dependsOn closure, batch partition, migration sequencing);
//            (b) an independent SKEPTIC agent re-reads the spec and adversarially checks coverage,
//            true disjointness, and seam-vs-migration correctness (the design intent: prefer a
//            reserved seam — flags / receipts / analytics / the currencies MAP / timestamps —
//            over a schema migration wherever one fits, so features add logic, not schema).
//
// The main session consumes {plan, mechanicalErrors, validation} and, only if clean, surfaces the
// plan as the decompose-approval + contract-diff-review human gate (the ONE pause, §13). Nothing
// here is committed and nothing under src/ is written — decompose only PLANS.
//
// args (JSON object; defensively parsed in case an invocation path stringifies it):
//   {
//     gameDir: "games/collect-sim",
//     specPath: "specs/collect-sim.md",
//     builtFeatures: ["collection", "shop", "daily"],   // hyphen-free service dir stems already shipped
//     currentSchemaVersion: 2,                            // Types.CURRENT_SCHEMA_VERSION today
//     note: "<optional extra steering, e.g. confirmed theme>"
//   }

export const meta = {
  name: 'decompose',
  description: 'build-game Workflow A.1: a planner agent turns a game spec into a fan-out plan (features + disjoint spec slices + shared contractDeltas + dependency-ordered build batches) for the REMAINING features; then pure-JS mechanical validation + an independent skeptic agent adversarially verify coverage, disjointness, and seam-vs-migration correctness. Plans only; writes nothing.',
  phases: [
    { title: 'Plan', detail: 'one planner agent reads the spec + shared contracts + built services and emits the fan-out plan' },
    { title: 'Validate', detail: 'pure-JS mechanical checks + an independent skeptic agent re-reads the spec to verify coverage/disjointness/seam-vs-migration' },
  ],
}

// args normally arrives as an object; accept a JSON string too (some invocation paths stringify it).
let input = args
if (typeof input === 'string') {
  try {
    input = JSON.parse(input)
  } catch (_e) {
    input = {}
  }
}
// No game defaults: silently planning the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
const specPath = input && input.specPath
if (!gameDir || !specPath) {
  throw new Error(`decompose: args must supply {gameDir, specPath} (got gameDir=${JSON.stringify(gameDir)}, specPath=${JSON.stringify(specPath)}).`)
}
const builtFeatures = (input && input.builtFeatures) || []
const currentSchemaVersion = (input && input.currentSchemaVersion) || 2
const note = (input && input.note) || ''
log(`decompose: ${specPath} -> plan REMAINING features for ${gameDir}; already built: [${builtFeatures.join(', ')}]; schema v${currentSchemaVersion}.`)

// ---- structured-output schema for the planner ----
//
// KEEP THIS SCHEMA TERSE. A schema with long per-field descriptions is rejected upstream with
// "output schema too large to classify safely" — the agent then never runs and the workflow
// returns the same {plan:null} shape a genuine no-op would. The FIELD CONTRACT block in the
// planner prompt below carries the semantics instead; the prompt has no size limit.

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    features: {
      type: 'array',
      description: 'one entry per REMAINING feature. See FIELD CONTRACT in the prompt.',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          serviceName: { type: 'string' },
          specTitle: { type: 'string' },
          specSlice: { type: 'string' },
          successCriteria: { type: 'array', items: { type: 'string' } },
          order: { type: 'number' },
          dependsOn: { type: 'array', items: { type: 'string' } },
          hasUI: { type: 'boolean' },
          contractClass: { type: 'string', enum: ['append-only', 'class-B-migration'] },
          seamRationale: { type: 'string' },
        },
        required: ['name', 'serviceName', 'specTitle', 'specSlice', 'successCriteria', 'order', 'dependsOn', 'hasUI', 'contractClass', 'seamRationale'],
      },
    },
    contractDeltas: {
      type: 'object',
      description: 'every shared-contract change the serial contract pass writes ONCE before fan-out.',
      properties: {
        netActions: { type: 'array', items: { type: 'object', properties: { key: { type: 'string' }, value: { type: 'string' }, feature: { type: 'string' }, comment: { type: 'string' } }, required: ['key', 'value', 'feature'] } },
        resultCodes: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['name', 'feature', 'why'] } },
        currencyKeys: { type: 'array', items: { type: 'object', properties: { key: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['key', 'feature', 'why'] } },
        typesFields: { type: 'array', items: { type: 'object', properties: { field: { type: 'string' }, shape: { type: 'string' }, persisted: { type: 'boolean' }, clientFacing: { type: 'boolean' }, ridesSeam: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['field', 'shape', 'persisted', 'clientFacing', 'ridesSeam', 'feature'] } },
        migrations: { type: 'array', items: { type: 'object', properties: { fromVersion: { type: 'number' }, toVersion: { type: 'number' }, addsField: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['fromVersion', 'toVersion', 'addsField', 'feature'] } },
      },
      required: ['netActions', 'resultCodes', 'currencyKeys', 'typesFields', 'migrations'],
    },
    contractPassExtras: {
      type: 'object',
      description: 'cross-cutting wiring the SERIAL contract pass owns beyond src/shared.',
      properties: {
        sharedServices: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, serviceName: { type: 'string' }, kind: { type: 'string', enum: ['service', 'client-framework', 'shared-module'] }, purpose: { type: 'string' } }, required: ['name', 'serviceName', 'purpose'] } },
        retrofits: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, change: { type: 'string' }, why: { type: 'string' } }, required: ['file', 'change', 'why'] } },
        emitPoints: { type: 'array', items: { type: 'object', properties: { event: { type: 'string' }, where: { type: 'string' }, owner: { type: 'string' } }, required: ['event', 'where', 'owner'] } },
        earnPaths: { type: 'array', items: { type: 'string' } },
      },
      required: ['sharedServices', 'retrofits', 'emitPoints', 'earnPaths'],
    },
    buildBatches: { type: 'array', items: { type: 'array', items: { type: 'string' } } },
    planNotes: { type: 'string' },
  },
  required: ['features', 'contractDeltas', 'contractPassExtras', 'buildBatches', 'planNotes'],
}

// The semantics the schema descriptions used to carry. Injected into the planner prompt.
const FIELD_CONTRACT = `FIELD CONTRACT (what each field of the StructuredOutput must contain — the schema itself is deliberately terse):

features[] — one entry per REMAINING feature (exclude anything already built):
- name: hyphen-free lowercase, ^[a-z][a-z0-9]*$. Becomes services/<name>/ AND tests/unit/<name>.spec, and it is a Luau require SEGMENT (services.<name>.<Service>) — a hyphen BREAKS the dot-require.
- serviceName: PascalCase module table name ending in "Service".
- specTitle: the spec's human title for this feature, VERBATIM, for traceability.
- specSlice: the verbatim spec text this feature owns — its Features bullet PLUS the progression/economy, re-entry, monetization and Success-criteria lines that pertain to it. THIS IS THE ONLY CONTEXT ITS BUILDER AND TEST GATE RECEIVE, so it must be self-contained and DISJOINT from every other slice.
- successCriteria: the exact "## Success criteria" bullet(s) this feature must satisfy.
- order: build order within the remaining set — 1-based, unique, a 1..N permutation.
- dependsOn: names of OTHER features (planned or already built) whose contract/behavior this needs first. May be empty.
- hasUI: true if it needs a client controller/GUI (a shop UI, a HUD badge, a leaderboard board).
- contractClass: "append-only" = adds only Net.Actions/Result.Codes and/or rides an EXISTING open seam (the currencies MAP, flags, receipts, upgrades, analytics, timestamps.lastSeenUnix) — NO migration. "class-B-migration" = introduces a genuinely NEW persisted field of fixed shape that no seam can carry -> needs a Migrations step + a CURRENT_SCHEMA_VERSION bump + a self-verifying round-trip test.
- seamRationale: WHY that contractClass — name the exact seam reused and why it fits, OR the exact new field and why no open seam can carry it. This is the most error-prone judgment in the plan; be explicit.

contractDeltas — every src/shared change, written ONCE by the serial contract pass so parallel builders never collide:
- netActions[]: {key: PascalCase Net.Actions key, value: the stable wire string, feature, comment?}.
- resultCodes[]: ONLY if no existing Result.Code fits — reuse BadPayload/BadType/OutOfRange/Insufficient/OnCooldown/NotOwner/RateLimited/Rejected/NoData/Internal first, and say in the "why" field which existing codes you considered.
- currencyKeys[]: new keys in the currencies MAP. These need NO migration — that map is open by design.
- typesFields[]: {field: dotted path in PlayerData (e.g. "stats.lifetimeX" or a new top-level "plot"), shape: the Luau type, persisted, clientFacing (true => also add to PlayerView + Types.toView), ridesSeam: the open seam it rides or "NEW" for a genuinely new fixed-shape field, feature, why}.
- migrations[]: one per class-B feature (or owned by "contract-pass" for a cross-cutting field no single slice owns). toVersion MUST equal fromVersion+1, and the sequence must be contiguous starting at the current schema version, ordered by build order.

contractPassExtras — the cross-cutting wiring the SERIAL pass performs BEYOND pure src/shared deltas, INCLUDING edits to already-built/merged service files (the human diff-reviews these, so the blast radius must be complete). A concern that must hook EVERY earn/spend path cannot be owned by a feature builder, because those points live in OTHER features:
- sharedServices[]: INFRASTRUCTURE modules the pass stands up (they own no spec feature; they provide a seam every feature uses — e.g. the analytics emitter, a single-writer economy helper). Set kind: "service" (default, a server service — serviceName must then be PascalCase ending in Service), "client-framework" (a client-side module every controller uses, e.g. a join-retry guard or a shared HUD root), or "shared-module".
- retrofits[]: {file: a path inside the game that ALREADY EXISTS, change: the exact minimal edit, why}. EVERY edit the contract pass makes to code it did not write goes here — including inherited scaffold code (a test asserting the foundation game's currency, the shared test mocks) — because this list IS the blast radius the human diff-reviews.
- emitPoints[]: the FULL analytics taxonomy — one entry per spec-mandated event, each mapped to {event, where it fires, owner: a feature name or "contract-pass"}. The validator checks the taxonomy is complete.
- earnPaths[]: the EXHAUSTIVE list of paths that must increment any lifetime/aggregate EARN counter — and by omission, what must not (spend/reset paths).

buildBatches — dependency-ordered batches of INDEPENDENT feature names: every planned feature appears EXACTLY once, all appear, and no feature sits in a batch at or before any feature in its dependsOn. Each batch is a set the fan-out builds in parallel.

planNotes — the cross-feature contention to watch (name THIS game's shared soft-currency balance and every feature that mutates it — earn, spend and reset paths racing one balance), the ordering rationale, and anything the contract pass or the integration gate must know.`

// Terse for the same reason as PLAN_SCHEMA — the semantics live in the skeptic prompt.
const VALIDATION_SCHEMA = {
  type: 'object',
  properties: {
    coverageVerdict: { type: 'string', enum: ['complete', 'gaps', 'fail'] },
    uncoveredSpecItems: { type: 'array', items: { type: 'object', properties: { item: { type: 'string' }, why: { type: 'string' } } } },
    overlaps: { type: 'array', items: { type: 'object', properties: { featureA: { type: 'string' }, featureB: { type: 'string' }, sharedResponsibility: { type: 'string' } } } },
    contractErrors: { type: 'array', items: { type: 'object', properties: { kind: { type: 'string', enum: ['missing-delta', 'wrong-contract-class', 'needless-migration', 'missing-migration', 'wrong-version', 'invented-result-code'] }, feature: { type: 'string' }, detail: { type: 'string' } } } },
    dependencyIssues: { type: 'array', items: { type: 'object', properties: { feature: { type: 'string' }, issue: { type: 'string' } } } },
    notes: { type: 'string' },
  },
  required: ['coverageVerdict', 'uncoveredSpecItems', 'overlaps', 'contractErrors', 'dependencyIssues', 'notes'],
}

// ---- PLAN ----

phase('Plan')

const planPrompt = `You are the DECOMPOSE PLANNER for the Roblox game at ${gameDir}. Turn its spec into a fan-out plan for the features that are NOT YET BUILT. One planner call determines the whole build, so be precise and complete.

You are at repo root. READ, IN FULL, BEFORE PLANNING:
1. ${specPath} — the game spec. The "## Features (fan-out list)" section enumerates every feature; the "## Success criteria" section is the done-condition. Plan ONLY the features still unbuilt.
2. ${
    builtFeatures.length
      ? `ALREADY BUILT (do NOT re-plan these; their service dirs already exist): [${builtFeatures.join(', ')}]. Read EVERY ONE of ${builtFeatures
          .map((b) => `${gameDir}/src/server/services/${b}/`)
          .join(', ')} to learn the established patterns, the contract surfaces they already registered, and which shared balance/seams they already mutate.`
      : `NOTHING IS BUILT YET — this is a freshly scaffolded game. The ONLY service under ${gameDir}/src/server/services/ is the deletable \`sample\` smoke-test of the wiring (build-game DELETES it once real features land; do NOT plan around it, do NOT let any feature depend on it, and never plan a feature named "sample"). Plan the FULL feature set from the spec. The earliest batch therefore has to establish this game's core persisted data shape and its core loop from scratch — expect the contract-defining features the spec marks as such to be batch 0.`
  }
3. THE SHARED CONTRACTS you will propose deltas to (read every one — your contractDeltas must name the REAL surfaces; enumerate what each ACTUALLY contains today rather than assuming):
   - ${gameDir}/src/shared/Types.luau — PlayerData. CRITICAL design intent: it ships RESERVED SEAMS so features add logic, not schema. The OPEN seams are: \`currencies: { [string]: number }\` (a MAP — a new currency like Prisms is just a new KEY, NO migration), \`flags: { [string]: boolean }\` (per-player booleans — island-unlock flags, gamepass-effect flags ride here), \`receipts: { [string]: boolean }\` (idempotency ledger — monetization receipts ride here), \`analytics: { lastEventUnix }?\`, \`upgrades: { [string]: number }\`, and \`timestamps.lastSeenUnix\` (already written on save/release — the offline-earnings base). \`CURRENT_SCHEMA_VERSION\` is ${currentSchemaVersion}.
   - ${gameDir}/src/shared/Net.luau — read Net.Actions and list the keys that EXIST TODAY (a fresh scaffold has only \`Sample\`); every action a specSlice invokes that is not already there must appear in contractDeltas.netActions. Net.dispatch is the ONE inbound pipeline.
   - ${gameDir}/src/shared/Result.luau — READ the Result.Codes table and list what it ACTUALLY contains today; do not assume, and do not carry over a list from another game (the scaffold's set is deliberately smaller than a mature game's). REUSE an existing code wherever one fits; propose a new one only when NONE does, and name the ones you rejected.
   - ${gameDir}/src/shared/Migrations.luau — steps[] + default(). A class-B feature adds a step (i -> i+1) that MUST stamp the new version, and default() must seed the new field.
4. ${gameDir}/CLAUDE.md — the engineering contract (server-authoritative, concurrency-safe economy, server clock, data-only-through-the-layer, idempotent purchases).

PLANNING RULES:
- name: hyphen-free lowercase (^[a-z][a-z0-9]*$) — it is a Luau require segment (services.<name>.<Service>). Hyphens BREAK the dot-require. Map "Islands & unlocks" -> name "islands", serviceName "IslandsService"; "Rebirth/prestige" -> "rebirth"/"RebirthService"; etc. NONE may collide with a built name [${builtFeatures.join(', ')}].
- DISJOINT slices: every feature owns its own services/<name>/ ONLY. No two slices may claim the same responsibility. If the spec couples two things, assign each line to exactly one feature and wire the dependency via dependsOn.
- SEAM OVER MIGRATION (the highest-value judgment): before marking a feature class-B-migration, check whether an OPEN seam carries its state. A second/prestige CURRENCY -> a new key in the currencies MAP (append-only). Per-thing unlock booleans, and gamepass EFFECT flags -> the flags map (append-only). Purchase idempotency -> the receipts ledger (append-only). Purchased LEVELS/COUNTS of a named upgradable -> the upgrades map (append-only). Offline accrual -> reads the EXISTING timestamps.lastSeenUnix (append-only unless it genuinely needs its OWN claim timestamp). Only a genuinely NEW fixed-shape field that no seam can carry is class-B: e.g. a prestige COUNT, or a LIFETIME earned total (the spent-down currency balance cannot represent it), or a per-player OWNED-PLOT/slot identity, or a structured record the maps cannot express. For EACH feature, justify the contractClass in seamRationale by naming the exact seam or the exact new field — and say why the seam does NOT fit when you choose class-B.
- migrations: order class-B features by build order; versions contiguous starting at ${currentSchemaVersion} (first class-B: ${currentSchemaVersion} -> ${currentSchemaVersion + 1}, next: ${currentSchemaVersion + 1} -> ${currentSchemaVersion + 2}, ...). toVersion = fromVersion + 1 always.
- CROSS-CUTTING CONCERNS -> contractPassExtras, NOT a feature slice: a concern that must hook EVERY earn/spend path (analytics emission across the whole taxonomy; a lifetime/aggregate counter incremented on every earn) CANNOT be owned by a feature builder, because the earn/spend points live in OTHER features — including ALREADY-BUILT, already-merged services a builder may not touch. Own these in contractPassExtras: stand up the infra service(s) (sharedServices, e.g. an analytics emitter on the ctx seam), list EVERY edit to an already-built file (retrofits — full blast radius for the human review), map EVERY spec-mandated analytics event to a fire-point+owner (emitPoints — the validator checks the taxonomy is complete), and give the EXHAUSTIVE earn-path list (earnPaths). Individual features still emit their OWN domain events (e.g. progression on unlock/rebirth, purchase on a receipt) THROUGH the shared emitter — so a feature slice never stands up analytics itself (that would build it twice). A feature whose data is produced cross-cuttingly (e.g. a leaderboard that RANKS a lifetime counter) then only READS the contract-pass-provided field and has NO false dependency on the built services.
- dependsOn + buildBatches: identify this game's SHARED soft-currency balance and note in planNotes that every economy feature mutates it (the cross-feature contention the integration gate will race). Order so contract-defining/foundational features (the ones the spec marks contract-defining, and anything the rest read) come first. buildBatches must partition ALL planned features (each once) with no feature before a dependency.
${note ? `\nEXTRA STEERING: ${note}\n` : ''}
${FIELD_CONTRACT}

Return the StructuredOutput. Be exhaustive: a missing contractDelta or a wrong contractClass misleads the entire downstream build.`

const plan = await agent(planPrompt, { label: 'decompose:plan', phase: 'Plan', schema: PLAN_SCHEMA, effort: 'high' })

if (!plan || !Array.isArray(plan.features) || plan.features.length === 0) {
  log('decompose: planner returned no features — aborting (nothing to validate).')
  return { gameDir, specPath, plan: plan || null, mechanicalErrors: ['planner returned no features'], validation: null, ok: false }
}

log(`decompose: planner proposed ${plan.features.length} feature(s): [${plan.features.map((f) => f.name).join(', ')}].`)

// ---- VALIDATE (a): pure-JS mechanical checks on the returned object ----

phase('Validate')

const mechanicalErrors = []
const NAME_RE = /^[a-z][a-z0-9]*$/
const SERVICE_RE = /^[A-Z][A-Za-z0-9]*Service$/
const features = plan.features
const planNames = features.map((f) => f.name)
const builtSet = new Set(builtFeatures)
const nameCount = {}
for (const n of planNames) nameCount[n] = (nameCount[n] || 0) + 1

for (const f of features) {
  if (!NAME_RE.test(f.name)) mechanicalErrors.push(`name "${f.name}" is not hyphen-free lowercase (^[a-z][a-z0-9]*$) — would break the Luau dot-require.`)
  if (nameCount[f.name] > 1) mechanicalErrors.push(`name "${f.name}" is duplicated across features.`)
  if (builtSet.has(f.name)) mechanicalErrors.push(`name "${f.name}" collides with an already-built feature.`)
  if (!SERVICE_RE.test(f.serviceName)) mechanicalErrors.push(`serviceName "${f.serviceName}" is not PascalCase ending in Service.`)
  for (const dep of f.dependsOn || []) {
    if (!planNames.includes(dep) && !builtSet.has(dep)) mechanicalErrors.push(`feature "${f.name}" dependsOn "${dep}" which is neither planned nor built.`)
  }
}

// order is a unique 1..N permutation
const orders = features.map((f) => f.order).sort((a, b) => a - b)
for (let i = 0; i < orders.length; i++) {
  if (orders[i] !== i + 1) { mechanicalErrors.push(`order values are not a 1..${features.length} permutation (got [${features.map((f) => f.order).join(', ')}]).`); break }
}

// buildBatches must partition exactly the planned feature set, once each, deps-before-dependents
const flatBatch = (plan.buildBatches || []).flat()
const batchCount = {}
for (const n of flatBatch) batchCount[n] = (batchCount[n] || 0) + 1
for (const n of planNames) if (!batchCount[n]) mechanicalErrors.push(`feature "${n}" is missing from buildBatches.`)
for (const n of flatBatch) {
  if (batchCount[n] > 1) mechanicalErrors.push(`feature "${n}" appears in buildBatches more than once.`)
  if (!planNames.includes(n)) mechanicalErrors.push(`buildBatches references unknown feature "${n}".`)
}
// dependency ordering across batches
const batchIndexOf = {}
;(plan.buildBatches || []).forEach((batch, bi) => batch.forEach((n) => { batchIndexOf[n] = bi }))
for (const f of features) {
  for (const dep of f.dependsOn || []) {
    if (builtSet.has(dep)) continue
    if (batchIndexOf[dep] === undefined || batchIndexOf[f.name] === undefined) continue
    if (batchIndexOf[dep] >= batchIndexOf[f.name]) mechanicalErrors.push(`"${f.name}" (batch ${batchIndexOf[f.name]}) depends on "${dep}" (batch ${batchIndexOf[dep]}) — a dependency must build in an EARLIER batch.`)
  }
}

// migration sequencing: contiguous, starting at currentSchemaVersion, toVersion = fromVersion+1
const migrations = (plan.contractDeltas && plan.contractDeltas.migrations) || []
const sortedMig = migrations.slice().sort((a, b) => a.fromVersion - b.fromVersion)
let expectFrom = currentSchemaVersion
for (const m of sortedMig) {
  if (m.fromVersion !== expectFrom) mechanicalErrors.push(`migration for "${m.feature}" has fromVersion ${m.fromVersion}; expected ${expectFrom} (must be contiguous from the current schema v${currentSchemaVersion}).`)
  if (m.toVersion !== m.fromVersion + 1) mechanicalErrors.push(`migration for "${m.feature}" has toVersion ${m.toVersion}; must be fromVersion+1 (${m.fromVersion + 1}).`)
  expectFrom = m.fromVersion + 1
}
// every class-B feature must have exactly one migration; a migration may also be owned by the
// SERIAL contract pass itself (feature tag "contract-pass") for a cross-cutting field (e.g. a
// lifetime counter wired into every earn path) that no single feature slice owns.
const classBNames = features.filter((f) => f.contractClass === 'class-B-migration').map((f) => f.name)
const migFeatures = migrations.map((m) => m.feature)
for (const n of classBNames) if (!migFeatures.includes(n)) mechanicalErrors.push(`feature "${n}" is class-B-migration but has no entry in contractDeltas.migrations.`)
for (const mf of migFeatures) {
  // a migration owner that is a PLANNED FEATURE must be class-B; an owner that is not a feature
  // (e.g. "contract-pass") is a legitimate contractPassExtras-owned migration.
  if (planNames.includes(mf) && !classBNames.includes(mf)) mechanicalErrors.push(`contractDeltas.migrations names feature "${mf}" but it is not marked class-B-migration.`)
}

// contractPassExtras structural checks: infra service names hyphen-free + non-colliding;
// retrofit paths well-formed; an aggregate/lifetime field implies a non-empty earnPaths list.
const extras = plan.contractPassExtras || {}
const sharedServices = extras.sharedServices || []
const retrofits = extras.retrofits || []
const earnPaths = extras.earnPaths || []
for (const s of sharedServices) {
  if (!NAME_RE.test(s.name)) mechanicalErrors.push(`contractPassExtras infra service name "${s.name}" is not hyphen-free lowercase.`)
  if (nameCount[s.name] || builtSet.has(s.name)) mechanicalErrors.push(`contractPassExtras infra service "${s.name}" collides with a feature/built name — infra services must NOT be feature slices.`)
  // Not every cross-cutting module the contract pass stands up is a SERVER SERVICE. A client
  // framework module (a join-retry guard, a shared HUD root) is exactly the kind of cross-cutting
  // thing no feature builder can own, and forcing it to be named "<X>Service" would either misname
  // it or push it out of the plan entirely. Only enforce the suffix on kind 'service' (the default).
  const kind = s.kind || 'service'
  if (kind === 'service' && !SERVICE_RE.test(s.serviceName)) {
    mechanicalErrors.push(`contractPassExtras infra serviceName "${s.serviceName}" is not PascalCase ending in Service (set kind:"client-framework" or "shared-module" if it is not a server service).`)
  }
  if (!['service', 'client-framework', 'shared-module'].includes(kind)) {
    mechanicalErrors.push(`contractPassExtras infra service "${s.name}" has unknown kind "${kind}" (expected service | client-framework | shared-module).`)
  }
}
for (const r of retrofits) {
  // Anywhere inside the GAME, not just src/. Retargeting an inherited test that asserts the
  // FOUNDATION game's currency, or widening the shared mock context, is legitimate contract-pass
  // work with real blast radius — the human review needs to see it, so it must not be rejected here.
  if (typeof r.file !== 'string' || r.file.indexOf(`${gameDir}/`) !== 0) {
    mechanicalErrors.push(`contractPassExtras retrofit file "${r.file}" should be a path under ${gameDir}/ (a file that already exists in this game).`)
  }
}
const hasAggregateField = (plan.contractDeltas.typesFields || []).some((t) => /lifetime|cumulative|aggregate|total/i.test(`${t.field} ${t.why || ''}`))
if (hasAggregateField && earnPaths.length === 0) mechanicalErrors.push('a lifetime/aggregate counter field is declared but contractPassExtras.earnPaths is empty — the earn paths that increment it are unspecified (the ships-broken gap).')

log(`decompose: mechanical validation -> ${mechanicalErrors.length} error(s).`)

// ---- VALIDATE (b): independent skeptic agent re-reads the spec ----

const planJson = JSON.stringify(plan, null, 2)
const validatePrompt = `You are an INDEPENDENT SKEPTIC validating a decompose PLAN for the Roblox game at ${gameDir}. You did NOT write the plan. Re-read the spec FROM SCRATCH and try to find where the plan is WRONG or INCOMPLETE. Do not trust the plan's own justifications.

You are at repo root. READ:
1. ${specPath} — the spec. Independently enumerate the unbuilt features and EVERY success criterion, EVERY re-entry hook the spec lists (offline accrual, the daily claim, any recurring restock/respawn event), and the analytics-event taxonomy. Build your list from the spec ALONE before you look at the plan, then diff.
2. The shared contracts (so you can judge seam-vs-migration correctly): ${gameDir}/src/shared/Types.luau (note the OPEN seams: currencies MAP, flags, receipts, analytics, upgrades, timestamps.lastSeenUnix — design intent is to reuse these, NOT migrate), Net.luau, Result.luau, Migrations.luau. CURRENT_SCHEMA_VERSION = ${currentSchemaVersion}.
3. ${builtFeatures.length ? `Already built (excluded from the plan, correctly): [${builtFeatures.join(', ')}].` : 'NOTHING is built yet — the game is a fresh scaffold whose only service is the deletable `sample`. So the plan must cover the ENTIRE feature list, and no feature may depend on `sample`.'}

THE PLAN UNDER REVIEW:
-----
${planJson}
-----

Adversarially check and report:
- COVERAGE: does every unbuilt spec feature AND every success criterion map to exactly one feature slice? Flag anything no slice owns — especially cross-cutting items (the loop_completed end-to-end assertion, the analytics taxonomy, any recurring restock/respawn event named only in a re-entry-hooks bullet and never in the feature list, the no-open-exploit adversarial pass). Put these in uncoveredSpecItems.
- DISJOINTNESS: do any two slices claim the same responsibility (would be built twice)? overlaps.
- SEAM-VS-MIGRATION (highest value): for EACH feature, is contractClass right? Flag a feature marked append-only that actually introduces a new fixed-shape persisted field (missing-migration/wrong-contract-class), AND a feature marked class-B-migration whose state could ride an existing open seam (needless-migration). Check migration versions are contiguous from v${currentSchemaVersion}. Flag any invented Result.Code that duplicates an existing one. contractErrors.
- DELTAS: does every Net.Action / field / Result.Code a specSlice implies actually appear in contractDeltas? Missing ones = missing-delta.
- DEPENDENCIES: are dependsOn correct (e.g. a prestige/reset feature RESETS the currencies/upgrades/flags other features own, so it depends on every one of them; a gated-progression feature depends on whatever produces the resource AND the rating that gates it)? NOTE: a concern owned by contractPassExtras (see below) is provided BEFORE fan-out, so a feature that only READS a contract-pass-provided field should have NO dependency on the built services — flag a FALSE dependency too. dependencyIssues.
- CROSS-CUTTING (contractPassExtras): verify the plan OWNS every concern that hooks every earn/spend path. Check emitPoints against the spec's analytics taxonomy: every spec-mandated event (e.g. session_start, session_end, loop_completed, currency_earned, currency_spent, progression, purchase) MUST have an entry — any missing event is an uncoveredSpecItem. Check retrofits name REAL already-built files and cover what must change in them (e.g. the built Sell/daily handlers must increment the lifetime counter + emit currency_earned/currency_spent — if a lifetime field exists but no retrofit wires it into the built earn paths, that is the leaderboard-ships-broken gap → dependencyIssue or missing-delta). Check earnPaths is exhaustive (sell, daily, offline, and any monetization grant) and excludes spend/reset paths. Flag any feature slice that stands up its OWN analytics emitter instead of emitting through the shared one (a build-twice overlap).

RETURN the StructuredOutput. Field contract (the schema is deliberately terse):
- coverageVerdict: "complete" only if every remaining spec feature AND every success criterion is owned by exactly one feature slice (or explicitly by contractPassExtras). Otherwise "gaps"; "fail" if the plan is unusable.
- uncoveredSpecItems[]: {item, why} — spec features / success criteria / re-entry hooks / analytics events no slice owns.
- overlaps[]: {featureA, featureB, sharedResponsibility} — pairs whose slices claim the SAME responsibility, which the fan-out would build twice.
- contractErrors[]: {kind, feature, detail} where kind is one of: missing-delta (a specSlice references a Net.Action/field/code absent from contractDeltas), wrong-contract-class, missing-migration (marked append-only but actually adds a new fixed-shape field), needless-migration (marked class-B but an open seam carries it), wrong-version (non-contiguous / toVersion != fromVersion+1), invented-result-code (a new code where an existing one fits).
- dependencyIssues[]: {feature, issue} — wrong, missing, or FALSE dependsOn.
- notes: anything else the human gate should see.
Be specific and cite the spec line or the contract field.`

const validation = await agent(validatePrompt, { label: 'decompose:validate', phase: 'Validate', schema: VALIDATION_SCHEMA, effort: 'high' })

const clean =
  mechanicalErrors.length === 0 &&
  !!validation &&
  validation.coverageVerdict === 'complete' &&
  (validation.overlaps || []).length === 0 &&
  (validation.contractErrors || []).length === 0

log(`decompose done. mechanicalErrors: ${mechanicalErrors.length} | coverage: ${validation ? validation.coverageVerdict : 'n/a'} | overlaps: ${validation ? (validation.overlaps || []).length : 'n/a'} | contractErrors: ${validation ? (validation.contractErrors || []).length : 'n/a'} | clean: ${clean}`)

return { gameDir, specPath, builtFeatures, currentSchemaVersion, plan, mechanicalErrors, validation, ok: clean }
