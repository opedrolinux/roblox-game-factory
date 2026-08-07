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
// No game default: silently auditing the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
if (!gameDir) throw new Error('adversarial-review: args must supply {gameDir}.')
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

// GAME-AGNOSTIC lenses. Each names the CLASS of defect to hunt, not any one game's nouns; the
// hunter is told to enumerate this game's actual services first. args.lenses overrides / extends
// (e.g. to add a lens for a mechanic unique to a game, like a gated-progression bypass).
const DEFAULT_LENSES = [
  {
    key: 'economy-race',
    prompt: `the ECONOMY-RACE lens: interleaved / spam-duplicated requests across DIFFERENT features racing the SAME shared currency balance(s). First list every service that mutates a currency, then reason about every ctx.data:update yield boundary under the per-player FIFO lock: can any interleaving double-spend, dupe a currency, mint from nothing, or lose a write? Pay special attention to any handler that captures or zeroes state BEFORE its yield and restores it after a failure — and to any handler that reads a balance, yields, then writes based on the STALE read. Read the data layer (DataService.update + the store's FIFO lock) and every economy mutator.`,
  },
  {
    key: 'server-authority',
    prompt: `the SERVER-AUTHORITY lens: can a client spoof ANY server-owned value via a crafted payload? Enumerate every registered action, then try to smuggle a price, a multiplier, an elapsed time, a grant amount, an id the player does not own, a receipt amount, a tier/level/count. Verify each action's validate() copies NOTHING trust-bearing out of the raw payload, that ownership is asserted where an action names a target, and that every consequential value (cost, rate, multiplier, elapsed, grant, threshold) is DERIVED server-side from persisted state. Read Net.dispatch (the validate->handler pipeline) + every action's validate.`,
  },
  {
    key: 'time-gate',
    prompt: `the TIME-GATE lens: every time-based feature must use ONLY the injected server clock (ctx.clock), never client time and never a raw os.time in a handler. Enumerate every time-dependent behavior (cooldowns, streaks, offline/idle accrual, daily rollovers, timed boosts, respawn/restock windows) and try to forge or bypass each: a tampered client-supplied elapsed, a cooldown bypass by re-ordering or re-claiming, a day-boundary straddle, a boost whose expiry is session-only rather than persisted. Reason about clock:unix() (persist-safe, comparable across sessions) vs clock:mono() (monotonic, NEVER persisted), and about the accrual base across a real leave/rejoin — does a lifecycle write on JOIN clobber the away-window base before it is read?`,
  },
  {
    key: 'dupe-replay',
    prompt: `the DUPE / REPLAY / IDEMPOTENCY lens: can a purchase be double-granted or a receipt replayed? Can an entitlement/effect be granted without ownership, or an unlock flag set without paying? Verify the receipt handler records the receipt id in the persisted ledger and grants EXACTLY once even under interleaved redelivery of the same receipt (the classic: check-ledger, yield, grant, write-ledger). Verify every entitlement flag is only ever set on the paid/owned server path — never from a client action — and that every consumer of such a flag reads the persisted value rather than a session cache that a rejoin could desynchronize.`,
  },
]
const lenses = (input && input.lenses && input.lenses.length ? input.lenses : DEFAULT_LENSES)
const LENSES = lenses

phase('Hunt')
const seen = new Set()
const confirmed = []
let dryRounds = 0
let round = 0
// Coverage bookkeeping, reported on the result so the orchestrator can tell a CONVERGED review from
// a TRUNCATED one. Without these, both return `clean: true` and look identical.
let huntersRun = 0
let huntersDead = 0
let abandoned = false

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
START by listing ${gameDir}/src/server/services/ so you are hunting over THIS game's real surface, not an assumed one. Then read ${gameDir}/src/shared/Net.luau (dispatch + Gate), ${gameDir}/src/server/data/* (the lock + the join/leave lifecycle), every service under ${gameDir}/src/server/services/*, and ${gameDir}/tests/integration/ + ${gameDir}/tests/unit/economy_race.spec.luau (how interleaving is forced here). Try HARD to find a REAL exploit that breaks a server-authoritative / economy / time-gate / idempotency invariant. For each: the concrete attack, the invariant broken, and the suspected file/function. If after a genuine attempt you find none through this lens, return findings: []. Do NOT invent low-value nitpicks.${seenList}`,
        { label: `hunt:${lens.key}#${round}`, phase: 'Hunt', schema: FINDING_SCHEMA, effort: 'high' }
      )
    )
  )

  // A HUNTER THAT DIED IS NOT A HUNTER THAT FOUND NOTHING. `parallel` resolves a failed agent to
  // null, and this loop's ENTIRE termination condition is "K consecutive rounds surfaced nothing
  // new" — so silently dropping the nulls lets a round in which every hunter DIED count as a dry
  // round. That is how this review terminates itself when the account hits a spend limit, an API
  // stalls, or a model is briefly unavailable: it stops being able to look, and returns a result
  // shaped exactly like convergence (`rounds: 3, clean: true`). It happened on deep-reach
  // 2026-08-06 — rounds 2 and 3 lost all four hunters to a spend limit and the run reported itself
  // done. A review whose value is "we kept looking until we stopped finding things" must never
  // confuse the two.
  const live = hunts.filter(Boolean)
  const deadThisRound = LENSES.length - live.length
  if (deadThisRound > 0) {
    log(`adversarial-review round ${round}: ${deadThisRound}/${LENSES.length} hunter(s) DIED (no result). This round proves nothing about those lenses.`)
  }
  huntersDead += deadThisRound
  huntersRun += live.length
  if (live.length === 0) {
    // Nothing looked. Abandon rather than bank a dry round on an empty round.
    abandoned = true
    log(`adversarial-review: ABANDONING after round ${round} — EVERY hunter died, so no further round can be trusted either. This review is INCOMPLETE, not clean.`)
    break
  }

  // collect new (unseen) findings
  const fresh = []
  for (const h of live) {
    for (const f of h.findings || []) {
      const k = `${f.suspectedLocation}::${f.title}`.toLowerCase().replace(/\s+/g, ' ')
      if (!seen.has(k)) {
        seen.add(k)
        fresh.push(f)
      }
    }
  }
  log(`adversarial-review round ${round}: ${fresh.length} fresh candidate finding(s) across ${live.length}/${LENSES.length} live lenses.`)

  if (fresh.length === 0) {
    // Only a round in which every lens actually RAN may bank a dry round. A partial round found
    // nothing new through the lenses that survived, which is weaker evidence than it looks.
    if (deadThisRound === 0) {
      dryRounds++
    } else {
      log(`adversarial-review round ${round}: nothing fresh, but ${deadThisRound} lens(es) never ran — NOT counting this as a dry round.`)
    }
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
// CONVERGED means the loop stopped because it genuinely stopped finding things: it banked its dry
// rounds (or exhausted maxRounds) with every lens alive throughout. Anything else is TRUNCATED, and
// `clean` is then a statement about what was looked at, not about the game.
const converged = !abandoned && huntersDead === 0
const coverage = {
  converged,
  abandoned,
  huntersRun,
  huntersDead,
  lenses: LENSES.length,
  roundsRun: round,
  dryRoundsBanked: dryRounds,
  dryRoundsRequired: dryRoundsToStop,
}
log(`adversarial-review ${converged ? 'CONVERGED' : 'TRUNCATED'} after ${round} round(s); hunters run ${huntersRun}, died ${huntersDead}. CONFIRMED exploits: ${confirmed.length} (critical:${bySeverity('critical')} high:${bySeverity('high')} medium:${bySeverity('medium')} low:${bySeverity('low')}).${converged ? ' Orchestrator fixes falsify-first.' : ' THIS REVIEW IS INCOMPLETE — re-run the lost rounds before reading `clean` as a pass.'}`)

return {
  gameDir,
  rounds: round,
  confirmed,
  // `clean` now means "converged AND found nothing" — it can no longer be true of a run that was cut
  // short, because a truncated review has no standing to certify anything.
  clean: converged && confirmed.length === 0,
  coverage,
}
