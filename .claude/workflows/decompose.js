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
const gameDir = (input && input.gameDir) || 'games/collect-sim'
const specPath = (input && input.specPath) || 'specs/collect-sim.md'
const builtFeatures = (input && input.builtFeatures) || []
const currentSchemaVersion = (input && input.currentSchemaVersion) || 2
const note = (input && input.note) || ''
log(`decompose: ${specPath} -> plan REMAINING features for ${gameDir}; already built: [${builtFeatures.join(', ')}]; schema v${currentSchemaVersion}.`)

// ---- structured-output schema for the planner ----

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    features: {
      type: 'array',
      description: 'one entry per REMAINING feature (exclude the already-built ones)',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'hyphen-free lowercase dir/spec stem (^[a-z][a-z0-9]*$). Becomes services/<name>/ AND tests/unit/<name>.spec — it is a Luau require segment, so NO hyphens (e.g. "islands", "rebirth", "offline", "leaderboard", "monetization").' },
          serviceName: { type: 'string', description: 'PascalCase module table name ending in Service (e.g. "IslandsService").' },
          specTitle: { type: 'string', description: 'the spec\'s human title for this feature, verbatim, for traceability (e.g. "Islands & unlocks").' },
          specSlice: { type: 'string', description: 'the verbatim spec text this feature owns — the Features bullet PLUS the Progression/economy, re-entry, monetization, and Success-criteria lines that pertain to it. This is the ONLY context its builder + test gate receive, so it must be self-contained and DISJOINT from other slices.' },
          successCriteria: { type: 'array', items: { type: 'string' }, description: 'the exact Success-criteria bullet(s) from the spec this feature must satisfy.' },
          order: { type: 'number', description: 'build order within the remaining set (1-based, unique).' },
          dependsOn: { type: 'array', items: { type: 'string' }, description: 'names of OTHER features (built OR planned) whose contract/behavior this needs first. Use the hyphen-free names. May be empty.' },
          hasUI: { type: 'boolean', description: 'true if the feature needs a client controller/GUI (shop UI, HUD badge, leaderboard GUI).' },
          contractClass: { type: 'string', enum: ['append-only', 'class-B-migration'], description: 'append-only = adds only Net.Actions/Result.Codes and/or rides an EXISTING seam (flags/receipts/analytics, a new currencies MAP key, timestamps.lastSeenUnix) — NO migration. class-B-migration = introduces a genuinely NEW persisted field of fixed shape (not a map key, not a reserved seam) -> needs a Migrations step + CURRENT_SCHEMA_VERSION bump + a self-verifying round-trip test.' },
          seamRationale: { type: 'string', description: 'WHY this contractClass: name the exact existing seam reused (and why it fits) OR the exact new field + why no existing seam can carry it. This is the most error-prone judgment — be explicit.' },
        },
        required: ['name', 'serviceName', 'specTitle', 'specSlice', 'successCriteria', 'order', 'dependsOn', 'hasUI', 'contractClass', 'seamRationale'],
      },
    },
    contractDeltas: {
      type: 'object',
      description: 'every shared-contract change the serial contract pass must write ONCE before fan-out, so parallel features never collide on src/shared.',
      properties: {
        netActions: { type: 'array', items: { type: 'object', properties: { key: { type: 'string', description: 'Net.Actions key, PascalCase (e.g. "Rebirth")' }, value: { type: 'string', description: 'the stable wire string (e.g. "rebirth.do")' }, feature: { type: 'string' }, comment: { type: 'string' } }, required: ['key', 'value', 'feature'] } },
        resultCodes: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['name', 'feature', 'why'] }, description: 'new Result.Codes (only if no existing code fits — reuse OutOfRange/Insufficient/OnCooldown/NotOwner/etc. first).' },
        currencyKeys: { type: 'array', items: { type: 'object', properties: { key: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['key', 'feature', 'why'] }, description: 'new keys in the currencies MAP (e.g. "Prisms"). These need NO migration — the currencies map is open by design.' },
        typesFields: { type: 'array', items: { type: 'object', properties: { field: { type: 'string', description: 'dotted path in PlayerData, e.g. "stats.lifetimeStardust" or a new top-level "rebirths"' }, shape: { type: 'string', description: 'Luau type, e.g. "number" or "{ count: number, multiplier: number }"' }, persisted: { type: 'boolean' }, clientFacing: { type: 'boolean', description: 'true => also add to PlayerView + Types.toView' }, ridesSeam: { type: 'string', description: 'name of the existing seam it rides (flags/receipts/analytics/currencies/timestamps) or "NEW" if a genuinely new fixed-shape field' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['field', 'shape', 'persisted', 'clientFacing', 'ridesSeam', 'feature'] } },
        migrations: { type: 'array', items: { type: 'object', properties: { fromVersion: { type: 'number' }, toVersion: { type: 'number' }, addsField: { type: 'string' }, feature: { type: 'string' }, why: { type: 'string' } }, required: ['fromVersion', 'toVersion', 'addsField', 'feature'] }, description: 'one per class-B feature. toVersion must = fromVersion+1; the sequence must start at the current schema version and be contiguous across the class-B features (ordered by build order).' },
      },
      required: ['netActions', 'resultCodes', 'currencyKeys', 'typesFields', 'migrations'],
    },
    contractPassExtras: {
      type: 'object',
      description: 'CROSS-CUTTING wiring the SERIAL contract pass performs BEYOND pure src/shared deltas — INCLUDING edits to ALREADY-BUILT/merged service files (high blast radius: the human diff-reviews these). This is where a concern that must hook EVERY earn/spend path (analytics emission, a lifetime/aggregate counter) is owned, instead of being (impossibly) wired by a feature builder that cannot touch already-merged code. Use empty arrays if a game truly has none.',
      properties: {
        sharedServices: { type: 'array', items: { type: 'object', properties: { name: { type: 'string', description: 'hyphen-free dir stem for an INFRASTRUCTURE service the contract pass stands up (e.g. "analytics")' }, serviceName: { type: 'string' }, purpose: { type: 'string', description: 'e.g. "emit the analytics taxonomy via ctx.analytics; fire session_start/session_end on the join/leave lifecycle"' } }, required: ['name', 'serviceName', 'purpose'] }, description: 'infra services the contract pass creates (NOT feature slices — they own no spec feature; they provide a ctx seam every feature uses).' },
        retrofits: { type: 'array', items: { type: 'object', properties: { file: { type: 'string', description: 'path to an ALREADY-BUILT file the contract pass must edit, e.g. games/collect-sim/src/server/services/collection/CollectionService.luau' }, change: { type: 'string', description: 'the exact minimal edit, e.g. "in the Sell transform, after crediting Stardust, increment stats.lifetimeStardust by the same amount and emit currency_earned"' }, why: { type: 'string' } }, required: ['file', 'change', 'why'] }, description: 'edits to code OUTSIDE src/shared that no feature builder may make (already-merged services). EVERY such edit is listed so the human review sees the full blast radius.' },
        emitPoints: { type: 'array', items: { type: 'object', properties: { event: { type: 'string', description: 'the analytics event name, e.g. "currency_earned"' }, where: { type: 'string', description: 'where it fires, e.g. "collection Sell handler (retrofit)" or "islands UnlockIsland handler"' }, owner: { type: 'string', description: 'who writes the emit: a feature name, or "contract-pass" for a retrofit/infra emit' } }, required: ['event', 'where', 'owner'] }, description: 'the FULL analytics taxonomy: one entry per event the spec mandates, each mapped to its fire-point + owner. The validator checks every spec-required event appears here.' },
        earnPaths: { type: 'array', items: { type: 'string' }, description: 'the EXHAUSTIVE list of paths that must increment any lifetime/aggregate earn counter (e.g. ["collection Sell", "daily claim", "offline claim", "monetization stardust-pack grant"]) — and, by omission, what must NOT (spend/reset paths). Lets the validator check completeness.' },
      },
      required: ['sharedServices', 'retrofits', 'emitPoints', 'earnPaths'],
    },
    buildBatches: { type: 'array', items: { type: 'array', items: { type: 'string' } }, description: 'dependency-ordered batches of INDEPENDENT feature names: every feature appears exactly once, all features appear, and no feature precedes any feature in its dependsOn. Each batch is a set the fan-out can build in parallel.' },
    planNotes: { type: 'string', description: 'cross-feature contention to watch (e.g. sell+buy+rebirth racing one Stardust balance), ordering rationale, and anything the contract pass / integration gate must know.' },
  },
  required: ['features', 'contractDeltas', 'contractPassExtras', 'buildBatches', 'planNotes'],
}

const VALIDATION_SCHEMA = {
  type: 'object',
  properties: {
    coverageVerdict: { type: 'string', enum: ['complete', 'gaps', 'fail'], description: 'complete = every remaining spec feature + every success criterion is owned by exactly one feature slice.' },
    uncoveredSpecItems: { type: 'array', items: { type: 'object', properties: { item: { type: 'string' }, why: { type: 'string' } } }, description: 'spec features / success criteria / re-entry hooks no slice owns (e.g. the daily rich-vein "Restock", the loop_completed integration assertion, analytics taxonomy).' },
    overlaps: { type: 'array', items: { type: 'object', properties: { featureA: { type: 'string' }, featureB: { type: 'string' }, sharedResponsibility: { type: 'string' } } }, description: 'pairs whose slices claim the SAME responsibility (a collision the fan-out would build twice).' },
    contractErrors: { type: 'array', items: { type: 'object', properties: { kind: { type: 'string', enum: ['missing-delta', 'wrong-contract-class', 'needless-migration', 'missing-migration', 'wrong-version', 'invented-result-code'] }, feature: { type: 'string' }, detail: { type: 'string' } } }, description: 'specSlice references a Net.Action/field/code not in contractDeltas (missing-delta); a feature marked append-only that actually adds a new fixed field (missing-migration / wrong-contract-class); a class-B feature that could ride an existing seam (needless-migration); a migration version that is wrong/non-contiguous; a Result.Code invented when an existing one fits.' },
    dependencyIssues: { type: 'array', items: { type: 'object', properties: { feature: { type: 'string' }, issue: { type: 'string' } } }, description: 'wrong/missing dependsOn (e.g. Leaderboard needs lifetime-Stardust accrual wired by whoever owns sell; Rebirth depends on the currencies/upgrades it resets).' },
    notes: { type: 'string' },
  },
  required: ['coverageVerdict', 'uncoveredSpecItems', 'overlaps', 'contractErrors', 'dependencyIssues', 'notes'],
}

// ---- PLAN ----

phase('Plan')

const planPrompt = `You are the DECOMPOSE PLANNER for the Roblox game at ${gameDir}. Turn its spec into a fan-out plan for the features that are NOT YET BUILT. One planner call determines the whole build, so be precise and complete.

You are at repo root. READ, IN FULL, BEFORE PLANNING:
1. ${specPath} — the game spec. The "## Features (fan-out list)" section enumerates every feature; the "## Success criteria" section is the done-condition. Plan ONLY the features still unbuilt.
2. ALREADY BUILT (do NOT re-plan these; their service dirs already exist): [${builtFeatures.join(', ')}]. Read them to learn the established patterns and what the spine already provides:
   - ${gameDir}/src/server/services/collection/CollectionService.luau (the contract-defining collect/sell core; the Stardust balance every economy feature shares)
   - ${gameDir}/src/server/services/shop/UpgradesShopService.luau, ${gameDir}/src/server/services/daily/DailyStreakService.luau
3. THE SHARED CONTRACTS you will propose deltas to (read every one — your contractDeltas must name the REAL surfaces):
   - ${gameDir}/src/shared/Types.luau — PlayerData. CRITICAL design intent: it ships RESERVED SEAMS so features add logic, not schema. The OPEN seams are: \`currencies: { [string]: number }\` (a MAP — a new currency like Prisms is just a new KEY, NO migration), \`flags: { [string]: boolean }\` (per-player booleans — island-unlock flags, gamepass-effect flags ride here), \`receipts: { [string]: boolean }\` (idempotency ledger — monetization receipts ride here), \`analytics: { lastEventUnix }?\`, \`upgrades: { [string]: number }\`, and \`timestamps.lastSeenUnix\` (already written on save/release — the offline-earnings base). \`CURRENT_SCHEMA_VERSION\` is ${currentSchemaVersion}.
   - ${gameDir}/src/shared/Net.luau — Net.Actions (existing keys: Sample, Collect, Sell, BuyUpgrade, Daily) and Net.dispatch (the ONE pipeline).
   - ${gameDir}/src/shared/Result.luau — Result.Codes (existing: BadPayload, BadType, OutOfRange, Insufficient, OnCooldown, NotOwner, RateLimited, UnknownAction, NoData, Internal, Rejected, SessionLocked, LockStolen). REUSE these — only propose a new code if NONE fits.
   - ${gameDir}/src/shared/Migrations.luau — steps[] + default(). A class-B feature adds a step (i -> i+1) that MUST stamp the new version, and default() must seed the new field.
4. ${gameDir}/CLAUDE.md — the engineering contract (server-authoritative, concurrency-safe economy, server clock, data-only-through-the-layer, idempotent purchases).

PLANNING RULES:
- name: hyphen-free lowercase (^[a-z][a-z0-9]*$) — it is a Luau require segment (services.<name>.<Service>). Hyphens BREAK the dot-require. Map "Islands & unlocks" -> name "islands", serviceName "IslandsService"; "Rebirth/prestige" -> "rebirth"/"RebirthService"; etc. NONE may collide with a built name [${builtFeatures.join(', ')}].
- DISJOINT slices: every feature owns its own services/<name>/ ONLY. No two slices may claim the same responsibility. If the spec couples two things, assign each line to exactly one feature and wire the dependency via dependsOn.
- SEAM OVER MIGRATION (the highest-value judgment): before marking a feature class-B-migration, check whether an OPEN seam carries its state. Prisms -> currencies map KEY (append-only). Per-island unlocks -> flags booleans (append-only). Gamepass effects + receipts -> flags + the receipts ledger (append-only). Offline earnings -> reads the EXISTING timestamps.lastSeenUnix (append-only unless it needs its own cap/claim timestamp). Only a genuinely NEW fixed-shape field with no seam (e.g. a rebirth COUNT, a lifetime-Stardust total that the spent-down currencies.Stardust cannot represent) is class-B. For EACH feature, justify the contractClass in seamRationale by naming the exact seam or the exact new field.
- migrations: order class-B features by build order; versions contiguous starting at ${currentSchemaVersion} (first class-B: ${currentSchemaVersion} -> ${currentSchemaVersion + 1}, next: ${currentSchemaVersion + 1} -> ${currentSchemaVersion + 2}, ...). toVersion = fromVersion + 1 always.
- CROSS-CUTTING CONCERNS -> contractPassExtras, NOT a feature slice: a concern that must hook EVERY earn/spend path (analytics emission across the whole taxonomy; a lifetime/aggregate counter incremented on every earn) CANNOT be owned by a feature builder, because the earn/spend points live in OTHER features — including ALREADY-BUILT, already-merged services a builder may not touch. Own these in contractPassExtras: stand up the infra service(s) (sharedServices, e.g. an analytics emitter on the ctx seam), list EVERY edit to an already-built file (retrofits — full blast radius for the human review), map EVERY spec-mandated analytics event to a fire-point+owner (emitPoints — the validator checks the taxonomy is complete), and give the EXHAUSTIVE earn-path list (earnPaths). Individual features still emit their OWN domain events (e.g. progression on unlock/rebirth, purchase on a receipt) THROUGH the shared emitter — so a feature slice never stands up analytics itself (that would build it twice). A feature whose data is produced cross-cuttingly (e.g. a leaderboard that RANKS a lifetime counter) then only READS the contract-pass-provided field and has NO false dependency on the built services.
- dependsOn + buildBatches: respect that the economy features all mutate the shared Stardust balance (note the contention); order so contract-defining/foundational features come first. buildBatches must partition ALL planned features (each once) with no feature before a dependency.
${note ? `\nEXTRA STEERING: ${note}\n` : ''}
Return the StructuredOutput PLAN_SCHEMA. Be exhaustive: a missing contractDelta or a wrong contractClass misleads the entire downstream build.`

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
  if (!SERVICE_RE.test(s.serviceName)) mechanicalErrors.push(`contractPassExtras infra serviceName "${s.serviceName}" is not PascalCase ending in Service.`)
}
for (const r of retrofits) {
  if (typeof r.file !== 'string' || r.file.indexOf(`${gameDir}/src/`) !== 0) mechanicalErrors.push(`contractPassExtras retrofit file "${r.file}" should be a path under ${gameDir}/src/ (an already-built file).`)
}
const hasAggregateField = (plan.contractDeltas.typesFields || []).some((t) => /lifetime|cumulative|aggregate|total/i.test(`${t.field} ${t.why || ''}`))
if (hasAggregateField && earnPaths.length === 0) mechanicalErrors.push('a lifetime/aggregate counter field is declared but contractPassExtras.earnPaths is empty — the earn paths that increment it are unspecified (the ships-broken gap).')

log(`decompose: mechanical validation -> ${mechanicalErrors.length} error(s).`)

// ---- VALIDATE (b): independent skeptic agent re-reads the spec ----

const planJson = JSON.stringify(plan, null, 2)
const validatePrompt = `You are an INDEPENDENT SKEPTIC validating a decompose PLAN for the Roblox game at ${gameDir}. You did NOT write the plan. Re-read the spec FROM SCRATCH and try to find where the plan is WRONG or INCOMPLETE. Do not trust the plan's own justifications.

You are at repo root. READ:
1. ${specPath} — the spec. Independently enumerate the unbuilt features and EVERY success criterion + re-entry hook (offline, daily streak, the rich-vein "Restock"), and the analytics-event taxonomy.
2. The shared contracts (so you can judge seam-vs-migration correctly): ${gameDir}/src/shared/Types.luau (note the OPEN seams: currencies MAP, flags, receipts, analytics, upgrades, timestamps.lastSeenUnix — design intent is to reuse these, NOT migrate), Net.luau, Result.luau, Migrations.luau. CURRENT_SCHEMA_VERSION = ${currentSchemaVersion}.
3. Already built (excluded from the plan, correctly): [${builtFeatures.join(', ')}].

THE PLAN UNDER REVIEW:
-----
${planJson}
-----

Adversarially check and report:
- COVERAGE: does every unbuilt spec feature AND every success criterion map to exactly one feature slice? Flag anything no slice owns — especially cross-cutting items (the loop_completed end-to-end assertion, the analytics taxonomy, the "Restock" rich-vein event, the no-open-exploit adversarial pass). Put these in uncoveredSpecItems.
- DISJOINTNESS: do any two slices claim the same responsibility (would be built twice)? overlaps.
- SEAM-VS-MIGRATION (highest value): for EACH feature, is contractClass right? Flag a feature marked append-only that actually introduces a new fixed-shape persisted field (missing-migration/wrong-contract-class), AND a feature marked class-B-migration whose state could ride an existing open seam (needless-migration). Check migration versions are contiguous from v${currentSchemaVersion}. Flag any invented Result.Code that duplicates an existing one. contractErrors.
- DELTAS: does every Net.Action / field / Result.Code a specSlice implies actually appear in contractDeltas? Missing ones = missing-delta.
- DEPENDENCIES: are dependsOn correct (e.g. Rebirth resets currencies/upgrades + island flags so it depends on them)? NOTE: a concern owned by contractPassExtras (see below) is provided BEFORE fan-out, so a feature that only READS a contract-pass-provided field should have NO dependency on the built services — flag a FALSE dependency too. dependencyIssues.
- CROSS-CUTTING (contractPassExtras): verify the plan OWNS every concern that hooks every earn/spend path. Check emitPoints against the spec's analytics taxonomy: every spec-mandated event (e.g. session_start, session_end, loop_completed, currency_earned, currency_spent, progression, purchase) MUST have an entry — any missing event is an uncoveredSpecItem. Check retrofits name REAL already-built files and cover what must change in them (e.g. the built Sell/daily handlers must increment the lifetime counter + emit currency_earned/currency_spent — if a lifetime field exists but no retrofit wires it into the built earn paths, that is the leaderboard-ships-broken gap → dependencyIssue or missing-delta). Check earnPaths is exhaustive (sell, daily, offline, and any monetization grant) and excludes spend/reset paths. Flag any feature slice that stands up its OWN analytics emitter instead of emitting through the shared one (a build-twice overlap).

Return the StructuredOutput VALIDATION_SCHEMA. Be specific and cite the spec line or contract field.`

const validation = await agent(validatePrompt, { label: 'decompose:validate', phase: 'Validate', schema: VALIDATION_SCHEMA, effort: 'high' })

const clean =
  mechanicalErrors.length === 0 &&
  !!validation &&
  validation.coverageVerdict === 'complete' &&
  (validation.overlaps || []).length === 0 &&
  (validation.contractErrors || []).length === 0

log(`decompose done. mechanicalErrors: ${mechanicalErrors.length} | coverage: ${validation ? validation.coverageVerdict : 'n/a'} | overlaps: ${validation ? (validation.overlaps || []).length : 'n/a'} | contractErrors: ${validation ? (validation.contractErrors || []).length : 'n/a'} | clean: ${clean}`)

return { gameDir, specPath, builtFeatures, currentSchemaVersion, plan, mechanicalErrors, validation, ok: clean }
