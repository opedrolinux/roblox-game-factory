// adversarial-review.js — build-game Workflow B, step 4: the whole-game adversarial review.
//
// The per-feature gates ran an economy red-team on each service ALONE; the integration gate checked
// cross-feature correctness. This is the final security sweep: loop-until-dry parallel exploit
// hunters across the INTEGRATED whole, each a DIFFERENT lens (economy-race / server-authority /
// time-gate / dupe-replay), with an independent skeptic verifying each NEW finding (default to
// refuted unless the exploit genuinely reproduces). Keep spawning rounds until K consecutive rounds
// surface nothing new. Confirmed exploits are returned for the orchestrator to fix falsify-first.
// Reads + reasons only; writes no code, commits nothing.
//
// args (JSON): { gameDir, vectors:[spec exploit vectors], maxRounds, dryRoundsToStop }

export const meta = {
  name: 'adversarial-review',
  description: 'build-game Workflow B step 4: the whole-game adversarial review. Loop-until-dry parallel exploit hunters over the integrated whole, each a different lens (economy-race / server-authority / time-gate / dupe-replay), each NEW finding verified by an independent skeptic (default refuted unless it reproduces). Confirmed exploits returned for falsify-first fixing. Reads + reasons only; commits nothing.',
  phases: [
    { title: 'Hunt', detail: 'parallel exploit hunters (diverse lenses) over the whole game, then a skeptic verifies each new finding; repeats until K dry rounds' },
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
const vectors = (input && input.vectors) || []
const maxRounds = (input && input.maxRounds) || 3
const dryRoundsToStop = (input && input.dryRoundsToStop) || 2
log(`adversarial-review: ${gameDir}; loop-until-dry (maxRounds=${maxRounds}, stop after ${dryRoundsToStop} dry rounds). Spec vectors: [${vectors.join(' | ')}].`)

const FINDING_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          lens: { type: 'string' },
          exploit: { type: 'string', description: 'the concrete attack: the exact inputs / interleaving / clock sequence that breaks an invariant' },
          invariantBroken: { type: 'string', description: 'what server-authoritative / economy / time-gate guarantee it violates' },
          suspectedLocation: { type: 'string', description: 'file/function' },
        },
        required: ['title', 'severity', 'lens', 'exploit', 'invariantBroken', 'suspectedLocation'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean', description: 'TRUE if after genuinely trying to reproduce, the exploit does NOT actually break an invariant (a false alarm). Default to TRUE when uncertain.' },
    reasoning: { type: 'string', description: 'the trace: why it reproduces (real) or why it cannot (refuted) — cite the exact guard / lock / validation that stops it, or the exact path that lets it through' },
    severityIfReal: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'n/a'] },
  },
  required: ['refuted', 'reasoning'],
}

const LENSES = [
  { key: 'economy-race', prompt: `the ECONOMY-RACE lens: interleaved / spam-duplicated requests across DIFFERENT features racing the ONE shared currencies.Stardust / currencies.Prisms — sell vs buy vs island-unlock vs rebirth vs offline-claim vs monetization-grant. Reason about every ctx.data:update yield boundary under the per-player FIFO lock: can any interleaving double-spend, dupe a currency, mint from nothing, or lose a write? Read CollectionService (Sell empties backpack before the yield + the consolidated formula), the data layer (DataService.update / MockStore FIFO lock), and every economy mutator.` },
  { key: 'server-authority', prompt: `the SERVER-AUTHORITY lens: can a client spoof ANY server-owned value via a crafted payload? Try smuggling a price, a mote/island multiplier, an elapsed time, a grant amount, an island id it does not own, a receipt amount, a rebirth count. Verify every action's validate() copies NOTHING trust-bearing out of the raw payload and that every value (cost, multiplier, elapsed, grant, threshold) is server-derived. Read Net.dispatch (the validate->handler pipeline) + every action's validate.` },
  { key: 'time-gate', prompt: `the TIME-GATE lens: every time-based feature must use ONLY the server clock (ctx.clock), never client/os time. Try to forge offline elapsed (a tampered client clock), bypass the daily cooldown, or game the restock day boundary. Reason about clock:unix() (persist-safe) vs clock:mono() (never persisted) usage, the offline lastSeenUnix base across a leave/rejoin (does loadSession preserve it?), the daily 20h cooldown + 48h reset, and the restock math.floor(now/86400) rollover. Read OfflineService, DailyStreakService, RestockService, and DataService's lifecycle writes to lastSeenUnix.` },
  { key: 'dupe-replay', prompt: `the DUPE / REPLAY / IDEMPOTENCY lens: can a purchase be double-granted or a receipt replayed? Can a gamepass effect be granted without ownership, or an island/upgrade flag set without paying? Verify ProcessReceipt records the receipt id in the ledger and grants exactly once even under interleaved redelivery; verify flags['gamepass.*'] / flags['island.*'] are only set via the paid/owned path. Read MonetizationService (the receipts ledger + ProcessReceipt), IslandsService (the flag set), and how the Sell/auto-collect retrofits read those flags.` },
]

phase('Hunt')
const seen = new Set()
const confirmed = []
let dryRounds = 0
let round = 0

while (round < maxRounds && dryRounds < dryRoundsToStop) {
  round++
  const seenList = confirmed.length
    ? `\n\nALREADY-CONFIRMED exploits (find something DIFFERENT, do not re-report these):\n${confirmed.map((c, i) => `  ${i + 1}. ${c.title}`).join('\n')}`
    : ''

  // parallel hunters, one per lens
  const hunts = await parallel(
    LENSES.map((lens) => () =>
      agent(`Independent ADVERSARIAL EXPLOIT HUNTER (round ${round}) on the WHOLE integrated game at ${gameDir}. Reading + reasoning ONLY — do NOT edit or run anything. The per-feature gates already cleared each service alone; your job is to BREAK the integrated whole through ${lens.prompt}

Spec "No open exploit" vectors to specifically attempt: [${vectors.join(' | ')}].
Read ${gameDir}/src/shared/Net.luau (dispatch + Gate), ${gameDir}/src/server/data/* (the lock + lifecycle), ${gameDir}/src/server/services/* (every feature), and ${gameDir}/tests/integration/ + tests/unit/economy_race.spec.luau (how interleaving is forced here). Try HARD to find a REAL exploit that breaks a server-authoritative / economy / time-gate / idempotency invariant. For each: the concrete attack, the invariant broken, and the suspected file/function. If after a genuine attempt you find none through this lens, return findings: []. Do NOT invent low-value nitpicks.${seenList}`,
        { label: `hunt:${lens.key}#${round}`, phase: 'Hunt', schema: FINDING_SCHEMA, effort: 'high' }
      )
    )
  )

  // collect new (unseen) findings
  const fresh = []
  for (const h of hunts.filter(Boolean)) {
    for (const f of h.findings || []) {
      const k = `${f.suspectedLocation}::${f.title}`.toLowerCase().replace(/\s+/g, ' ')
      if (!seen.has(k)) {
        seen.add(k)
        fresh.push(f)
      }
    }
  }
  log(`adversarial-review round ${round}: ${fresh.length} fresh candidate finding(s) across ${LENSES.length} lenses.`)

  if (fresh.length === 0) {
    dryRounds++
    continue
  }

  // skeptic-verify each fresh finding (default refuted unless it reproduces)
  const verdicts = await parallel(
    fresh.map((f) => () =>
      agent(`Independent SKEPTIC verifying a claimed exploit in ${gameDir} (round ${round}). Reading + reasoning ONLY. Try to REFUTE it — default to refuted=true unless it GENUINELY reproduces and breaks an invariant.

CLAIM: "${f.title}" (${f.severity}, lens ${f.lens})
ATTACK: ${f.exploit}
INVARIANT IT CLAIMS TO BREAK: ${f.invariantBroken}
SUSPECTED LOCATION: ${f.suspectedLocation}

Read the cited code + the surrounding guards (the validate(), the lock-held transform, the server-derived values, the ledger). Trace the EXACT path the attack would take. Does a guard / the FIFO lock / a validation / a server-side derivation stop it? Then refuted=true (cite the exact stopper). Does the attack genuinely get through and break the invariant? Then refuted=false (cite the exact gap + the reproduction). Be rigorous: a plausible-sounding exploit that a guard actually stops is REFUTED.`,
        { label: `verify:${f.lens}#${round}`, phase: 'Hunt', schema: VERDICT_SCHEMA, effort: 'high' }
      ).then((v) => ({ finding: f, verdict: v }))
    )
  )

  const newlyConfirmed = verdicts.filter(Boolean).filter((x) => x.verdict && x.verdict.refuted === false)
  for (const x of newlyConfirmed) confirmed.push({ ...x.finding, verification: x.verdict.reasoning, severityIfReal: x.verdict.severityIfReal })
  log(`adversarial-review round ${round}: ${newlyConfirmed.length} CONFIRMED (real) of ${fresh.length} candidate(s); ${fresh.length - newlyConfirmed.length} refuted.`)

  if (newlyConfirmed.length === 0) {
    dryRounds++
  } else {
    dryRounds = 0
  }
}

const bySeverity = (s) => confirmed.filter((c) => (c.severityIfReal || c.severity) === s).length
log(`adversarial-review DONE after ${round} round(s). CONFIRMED exploits: ${confirmed.length} (critical:${bySeverity('critical')} high:${bySeverity('high')} medium:${bySeverity('medium')} low:${bySeverity('low')}). Orchestrator fixes falsify-first.`)

return { gameDir, rounds: round, confirmed, clean: confirmed.length === 0 }
