// playtest-pass.js — the T2.5 AUTOMATED AI PLAYTEST lane (BUILD-CONTRACT §BUILDER C).
//
// INVOCATION GOTCHA (real, has bitten this repo): .claude/workflows/*.js are invoked by
// `Workflow({ scriptPath: '.claude/workflows/playtest-pass.js' }, args)` — NEVER by name. A by-name
// invocation can resolve a STALE CACHED COPY of an earlier version of this file and run it silently;
// fanout.js nests build-features by scriptPath for exactly this reason (fanout.js:20,103).
//
// WHAT THIS RUNG IS. T2 boots the place and proves it does not throw. T2.5 goes one step further and
// asks the only question that matters to a player: WHEN I ACT, DOES ANYTHING CHANGE? It authors a
// spec-derived playtest on top of the harness template at
// .claude/skills/lib/templates/tier2/playtest.server.luau, forks it into <gameDir>/tests/tier2/, runs
// it under run-in-roblox, and ingests the one sentinel-prefixed evidence line it prints.
//
// THE DEFECT THAT PAID FOR THIS FILE. games/collect-sim published `"ok": true` from a playtest run in
// which all four shop upgrades did NOTHING (`capacityBefore: 50, capacityAfter: 50` was serialized as
// a *detail* beside the verdict), every gated island was freely walkable, and rebirth cut income 93%.
// 361 Lune tests were green at the same moment. The assertions were CORRECT and CONTRIBUTED NOTHING TO
// THE VERDICT. That is why every gate below is computed HERE, in JS, from structured data — an agent's
// own `ok: true` is never accepted as a verdict (the same hardening grade.js:68-82 got after a review
// found it trusting an agent boolean: "This keeps the 'deterministic tier' claim true").
//
// THE SECOND DEFECT. Commit 8aa53ce exists solely because tests/tier2/last-playtest.json was STALE —
// from before the JoinRetry fix it was being read as evidence for — and EVERY reader accepted it.
// Nothing in tier-status.luau or smoke-gate.js compares an artifact to the tree it claims to describe.
// C.5's gitSha-ancestry + scriptSha256 clauses are that comparison.
//
// FALSIFICATION IS MANDATORY, NOT DECORATIVE. A gate never observed RED is not known to work. Before
// this lane can say green, every GATING phase must have a recorded proof that deliberately breaking the
// thing it asserts turned it RED — recorded in tests/tier2/last-falsification.json against the SAME
// script sha as the evidence. Without that the honest verdict is `T2.5-unfalsified`, never green.
//
// HONEST DEGRADATION (mirrors smoke-gate.js:112-123): with run-in-roblox absent or GATE_ENGINE_LANE
// unset this lane PREPARES and PARKS at `T2.5-blocked-on-human` with `evidence: null` and the label
// `verified-local-T1 (logic only) — NOT engine-verified`. It never guesses and never skips.
//
// HANDOFF-2 (no builder in this pass owns tier-ladder.luau / tier-status.luau / gauntlet.luau):
//   - RUNGS in tier-ladder.luau:38-45 must admit T2.5 (automatable, engine lane) and T2.7, and the
//     boolean `engineLaneAvailable` must become a PER-RUNG lane map.
//   - tier-status.luau:184-206's T2.5 bolt-on must become manifest-driven (read phases.json) instead of
//     the hardcoded T25_EXPECTED_PHASES list at :117-125.
// HANDOFF-4 (the live hole this file cannot close): tier-status.luau:187 wraps its T2.5 gating in
//   `if t2 == "green"`. With the T2 lane down, a RECORDED RED PLAYTEST IS SILENTLY IGNORED and handoff
//   still returns ready. A red is red regardless of the rung beneath it.
//
// DO NOT RUN THIS CONCURRENTLY WITH ANY WORKFLOW THAT READS THE GAME SOURCE. The Falsify phase's whole
// method is to introduce a REAL defect into the GAME, observe the phase go red, and revert — so for
// minutes at a time the working tree is deliberately broken. Any reader running beside it
// (adversarial-review's hunters, integration-gate, grade's judge) is auditing a game that does not
// exist, and will report defects nobody wrote. The findings look real: they cite a true file, a true
// line, and code that was genuinely there when it looked. Serialize this lane against every reader.
//
// args (JSON): { gameDir, specPath?, mode?, evidencePath?, result?, nowUnix?, engineLane?, engineLaneReason? }
//   mode: 'author' (default — author + falsify + run + ingest) | 'run' (run + ingest) | 'ingest'
//   result: a pasted evidence JSON string/object (ingest without touching the filesystem)

export const meta = {
  name: 'playtest-pass',
  description: 'The T2.5 automated AI playtest lane: derive a game\'s testable claims from its spec + source (what must CHANGE when the player acts), author spec-derived gating phases onto the T2.5 harness template in <gameDir>/tests/tier2/, run the lane under run-in-roblox when the engine lane is up, and REQUIRE A RECORDED FALSIFICATION PROOF (every gating phase observed RED under a deliberate defect, against the same script sha) before reporting green. Fail-closed and JS-computed: the verdict is never an agent\'s boolean; a missing sentinel line, a vacuous roster, a zero-subject phase, a stale gitSha/scriptSha256, or a waiver added in the verification turn all block green. Degrades honestly to T2.5-blocked-on-human with evidence:null when the engine lane is down.',
  phases: [
    { title: 'Author', detail: 'derive gating phases from the spec + Net.Actions; fork the T2.5 template; write phases.json' },
    { title: 'Falsify', detail: 'break each gating phase deliberately; record the observed RED; revert' },
    { title: 'Run', detail: 'rojo build + run-in-roblox; capture the ##T25-EVIDENCE## sentinel line' },
    { title: 'Ingest', detail: 'parse evidence; verify roster, subjects/deltas, provenance, waivers, falsification coverage' },
  ],
}

// ── defensive args (house idiom: a malformed args string reads as {}, never a crash) ───────────────
let input = args
if (typeof input === 'string') {
  try {
    input = JSON.parse(input)
  } catch (_e) {
    input = {}
  }
}
// No game default: a T2.5 verdict attributed to the wrong game is exactly the laundering this
// whole file exists to prevent.
const gameDir = input && input.gameDir
if (!gameDir) throw new Error('playtest-pass: args must supply {gameDir}.')
const slug = gameDir.split('/').filter(Boolean).pop() || 'game'
const specPath = (input && input.specPath) || `specs/${slug}.md`
const mode = (input && input.mode) || 'author'
const evidencePath = (input && input.evidencePath) || `${gameDir}/tests/tier2/last-playtest.json`
const pastedResult = input && input.result

// Fixed paths — BUILD-CONTRACT §S2. last-playtest.json's path is KEPT so the existing
// tier-status.luau reader keeps working with zero edits.
const TEMPLATE_PATH = '.claude/skills/lib/templates/tier2/playtest.server.luau'
const HARNESS_REL = 'tests/tier2/playtest.server.luau'
const PHASES_REL = 'tests/tier2/phases.json'
const FALSIFY_REL = 'tests/tier2/last-falsification.json'
const ALLOW_REL = 'tests/verification-allow.json'
const SENTINEL = '##T25-EVIDENCE## '

// §S5: the only three phases permitted to satisfy their result without a measured state delta. Every
// other phase MUST carry deltas > 0 — "7 pad dispatches" were once counted as 7 proofs when they were
// one empty Sell plus six Err(Insufficient) refusals against a zero-balance session.
const STRUCTURAL_PHASES = ['lane-limits', 'bootstrap-parity', 'no-log-errors']
const THIRTY_DAYS = 30 * 24 * 60 * 60

// The honest label this lane carries until a real evidence line exists (smoke-gate.js:13's wording).
const NOT_ENGINE_VERIFIED = 'verified-local-T1 (logic only) — NOT engine-verified'

const blockers = []
// `Date.now()` THROWS inside a workflow script (it would break resume replay), so this line used to
// abort playtest-pass at load — before phase 1, with no agent spawned and no diagnostic naming the
// cause. The clock comes in through args instead. Absent -> Infinity, which reads EVERY waiver as
// expired: fail-closed, because an unknown clock must never be the thing that keeps a waiver alive.
const nowUnix = (input && typeof input.nowUnix === 'number' && isFinite(input.nowUnix)) ? input.nowUnix : Infinity

function asObject(v) {
  if (v && typeof v === 'object') return v
  if (typeof v === 'string') {
    try {
      return JSON.parse(v)
    } catch (_e) {
      return null
    }
  }
  return null
}

// phases.json is Builder B's manifest and its exact shape is B's to define; this reader accepts the
// three shapes it can honestly take and FAILS CLOSED (null) on anything else. A roster we cannot read
// is never treated as "no roster to check" — that is the vacuity this whole rung exists to kill.
function rosterFromManifest(manifest) {
  const m = asObject(manifest)
  if (!m) return null
  if (Array.isArray(m)) return m.filter((x) => typeof x === 'string')
  if (Array.isArray(m.roster)) return m.roster.filter((x) => typeof x === 'string')
  if (Array.isArray(m.phases)) {
    const names = m.phases.map((p) => (typeof p === 'string' ? p : p && p.name)).filter((n) => typeof n === 'string')
    return names.length > 0 ? names : null
  }
  if (Array.isArray(m.gating) || Array.isArray(m.nonGating)) {
    return [].concat(Array.isArray(m.gating) ? m.gating : [], Array.isArray(m.nonGating) ? m.nonGating : []).filter((x) => typeof x === 'string')
  }
  return null
}

function setDiff(a, b) {
  const other = new Set(b)
  return a.filter((x) => !other.has(x))
}

// ── INGEST (pure JS, fail-closed) — BUILD-CONTRACT §C.5 ────────────────────────────────────────────
// Every clause that fails pushes a HUMAN-READABLE string onto blockers[]. Nothing here consults an
// agent: `parsed` is data, and the verdict is arithmetic over it.
function ingest(ev) {
  const parsed = asObject(ev.evidence)
  const evidenceBlockers = []
  const falsificationBlockers = []
  const push = (s) => evidenceBlockers.push(s)

  if (!parsed) {
    // §S3: a missing/unparseable sentinel capture is RED, never "absent". `grep '^\{"ok"'` (the old
    // RUNBOOK.md:81 recipe) could never have produced its own artifact — the file begins {"verdict".
    push(`no parseable evidence (expected the ${SENTINEL.trim()} line's JSON at ${ev.sourceLabel}) — fail-closed to red`)
    return { verdict: 'T2.5-red', parsed: null, evidenceBlockers, falsificationBlockers }
  }

  if (parsed.tier !== 2.5) push(`evidence tier is ${JSON.stringify(parsed.tier)}, expected 2.5 (wrong rung's artifact)`)

  // Clause 1 of §S4's hard rules, no exceptions: a verdict/ok disagreement is MALFORMED, and a
  // "parked" run laundered into ok:true is exactly the shape that shipped four inert upgrades as green.
  const claimsGreen = parsed.verdict === 'green'
  const malformed = parsed.ok !== claimsGreen
  if (malformed) push(`malformed evidence: ok=${JSON.stringify(parsed.ok)} but verdict=${JSON.stringify(parsed.verdict)} (ok MUST equal verdict==="green")`)

  const phases = Array.isArray(parsed.phases) ? parsed.phases.filter((p) => p && typeof p.name === 'string') : []
  if (phases.length === 0) push('evidence carries no phases[] — a lane that observed nothing cannot be green')

  // Roster, two-sided and three-way (§S4.5): phases.json (the committed authority a reviewer sees in
  // the diff) vs the harness's inline mirror vs what actually ran. This closes the "author deletes a
  // red phase from both the roster and the runner in one edit" hole.
  const ranNames = phases.map((p) => p.name)
  const mirror = Array.isArray(parsed.roster) ? parsed.roster.filter((x) => typeof x === 'string') : null
  if (!mirror) {
    push('evidence carries no roster[] mirror — cannot verify the harness ran the declared roster')
    // With no mirror, fall back to diffing the committed manifest against what actually ran, so the
    // MISSING PHASES ARE NAMED rather than hidden behind one generic "no mirror" line. A pasted
    // {"phases":[{"name":"x","ok":true}]} must be told exactly which rostered phases it is missing.
    if (ev.roster) {
      const neverRanVsFile = setDiff(ev.roster, ranNames)
      if (neverRanVsFile.length) push(`rostered phases that never ran: [${neverRanVsFile.join(', ')}]`)
    }
  }
  if (!ev.roster) {
    push(`no readable roster manifest at ${gameDir}/${PHASES_REL} — the committed roster authority is missing`)
  } else if (mirror) {
    const missingFromMirror = setDiff(ev.roster, mirror)
    const extraInMirror = setDiff(mirror, ev.roster)
    if (missingFromMirror.length) push(`phases.json declares phases the harness mirror omits: [${missingFromMirror.join(', ')}]`)
    if (extraInMirror.length) push(`harness mirror declares phases phases.json omits: [${extraInMirror.join(', ')}]`)
  }
  if (mirror) {
    const neverRan = setDiff(mirror, ranNames)
    const unrostered = setDiff(ranNames, mirror)
    if (neverRan.length) push(`rostered phases that never ran: [${neverRan.join(', ')}]`)
    if (unrostered.length) push(`phases ran that are not in the roster: [${unrostered.join(', ')}]`)
  }
  const requiredNames = ev.roster || mirror || []
  for (const name of requiredNames) {
    const p = phases.find((x) => x.name === name)
    if (!p) continue // already reported as never-ran
    if (p.ok !== true) push(`phase not ok: ${name}${p.detail ? ` — ${p.detail}` : ''}`)
  }

  // Per-phase non-vacuity. §S8: zero subjects on an APPLICABLE phase is a FAIL, and only a measured
  // before/after (`probe:delta`) counts — `probe:expect` shape checks never satisfy a phase. This is
  // the clause that would have caught the T2 smoke asserting a whole world against a Workspace
  // containing ZERO PARTS, green for weeks, because WorldService was omitted from the mirrored list.
  for (const p of phases) {
    const applicable = p.applicable !== false
    if (!applicable) continue
    if (typeof p.subjects !== 'number' || p.subjects <= 0) {
      push(`phase ${p.name} is applicable but discovered ${p.subjects === undefined ? 'no subjects field' : p.subjects} subjects — either the convention drifted or this phase is now blind`)
    }
    if (!STRUCTURAL_PHASES.includes(p.name)) {
      if (typeof p.deltas !== 'number' || p.deltas <= 0) {
        push(`phase ${p.name} asserted ${p.deltas === undefined ? 'no deltas field' : p.deltas} state deltas — call counts are not proofs; assert the DELTA`)
      }
    }
  }

  // The GATING SET, computed ONCE here because three separate clauses need it. Fallback when no phase
  // carries a `gating` flag: treat the whole declared roster as gating. That is the conservative
  // direction — more phases must be proven RED, never fewer.
  const gatingNames = phases.filter((p) => p.gating === true).map((p) => p.name)
  const gatingSource = gatingNames.length > 0 ? gatingNames : (ev.roster || mirror || [])

  // §C.2 PARITY — the roster floor. The AUTHOR stage rejects a lane with fewer than 3 gating phases
  // (:517), but INGEST had NO floor at all. Ingest mode is exactly how a human grades a pasted or
  // committed artifact and how a rung gets claimed, so a floor on one side only is no floor: a
  // one-phase artifact scored T2.5-green against this file as shipped (falsified 2026-08-02,
  // .verify_tmp/fix2/ppass/test.mjs case CRIT-4e). An empty or tiny roster scores 100% on every
  // per-phase metric — that is the vacuity this whole rung exists to kill.
  if (gatingSource.length < 3) {
    push(`only ${gatingSource.length} gating phase(s) in this run — §C.2 requires >= 3; a lane with a tiny roster scores 100% on every per-phase metric`)
  }

  // A phase that declares itself INAPPLICABLE measured nothing: `applicable:false` skips the subjects
  // clause AND the deltas clause with a single `continue`, so before this clause a lane could mark
  // EVERY phase inapplicable and still report green having probed nothing at all (falsified: case
  // CRIT-4g). A non-gating phase may honestly not apply; a GATING one may not, because it is
  // load-bearing by definition — demote it or make it apply, but do not let it pass by abstaining.
  for (const p of phases) {
    if (p.applicable === false && gatingSource.includes(p.name)) {
      push(`gating phase ${p.name} declared itself applicable:false — a gating phase that did not apply proved nothing (demote it to non-gating or make it apply); abstention is not a pass`)
    }
  }

  // GLOBAL non-vacuity. STRUCTURAL_PHASES is exactly three names and every one of them is EXEMPT from
  // the per-phase delta clause above, so a roster of precisely those three satisfied every check with
  // ZERO measured state deltas anywhere in the run (falsified: case CRIT-4h). T2.5's entire question is
  // "when I act, does anything CHANGE?" — a run that measured no change has not answered it, and that
  // is the exact shape of the collect-sim artifact that shipped `capacityBefore: 50, capacityAfter: 50`
  // beside `"ok": true`.
  const measuringPhases = phases.filter(
    (p) => p.applicable !== false && !STRUCTURAL_PHASES.includes(p.name) && typeof p.deltas === 'number' && p.deltas > 0
  )
  if (measuringPhases.length === 0) {
    push('no phase in this run measured a single state DELTA (every phase was structural, inapplicable, or delta-free) — T2.5 asks whether anything CHANGES when the player acts, and this run never answered that')
  }

  // "Could not check" is never a pass. `unverified` disqualifies green outright.
  const unverified = Array.isArray(parsed.unverified) ? parsed.unverified : []
  if (unverified.length > 0) {
    push(`${unverified.length} unverified item(s): ${unverified.map((u) => (u && u.label) || String(u)).join('; ')}`)
  }

  // Lane limits, INVERTED (§B.3): a blindTo entry citing a limit the harness measured as LIFTED means
  // the harness's own excuses are stale — a run-in-roblox release that starts stepping physics must
  // interrupt a human, not pass quietly.
  const limits = asObject(parsed.laneLimits) || {}
  const blindTo = Array.isArray(parsed.blindTo) ? parsed.blindTo : []
  for (const b of blindTo) {
    if (!b || typeof b.becauseLimit !== 'string') {
      push('blindTo entry with no becauseLimit — an unbound excuse')
      continue
    }
    if (limits[b.becauseLimit] !== false) {
      push(`blindTo "${b.claim || '(unnamed claim)'}" cites limit ${b.becauseLimit}, but laneLimits measured it as ${JSON.stringify(limits[b.becauseLimit])} — the limit LIFTED (or was never measured); this claim is now testable`)
    }
  }

  // Waivers (§S6). A waiver is never invisible and never permanent.
  const waivers = Array.isArray(parsed.waivers) ? parsed.waivers : []
  for (const w of waivers) {
    const subject = (w && w.subject) || '(unnamed subject)'
    if (!w || typeof w.expiresUnix !== 'number') {
      push(`waiver ${subject} has no numeric expiresUnix — a date in a comment expires nothing`)
      continue
    }
    if (w.expiresUnix <= nowUnix) push(`waiver EXPIRED: ${w.rule || '?'} :: ${subject} (expired ${new Date(w.expiresUnix * 1000).toISOString().slice(0, 10)})`)
    if (typeof w.addedUnix === 'number' && w.expiresUnix - w.addedUnix > THIRTY_DAYS) push(`waiver spans >30 days (no permanent waivers): ${w.rule || '?'} :: ${subject}`)
    if (w.matchedNothing === true) push(`waiver matched NOTHING this run (stale waiver for a fixed problem): ${w.rule || '?'} :: ${subject}`)
  }
  // Every ACTIVE allowlist entry must be echoed into waivers[]. An entry present on disk but absent
  // from the evidence matched nothing — that is how an allowlist rots into blanket suppression.
  const allowEntries = (asObject(ev.allowlist) && asObject(ev.allowlist).entries) || []
  if (Array.isArray(allowEntries)) {
    const echoed = new Set(waivers.map((w) => `${w && w.rule}::${w && w.subject}`))
    for (const e of allowEntries) {
      if (!e || typeof e.subject !== 'string') continue
      if (typeof e.subject.indexOf === 'function' && e.subject.indexOf('::') === -1) {
        push(`allowlist subject "${e.subject}" is a bare name — subjects must be file::Table.method (collect-sim's bare-name INTERNAL_ONLY exempted EVERY tuningFor in the game)`)
      }
      if (!echoed.has(`${e.rule}::${e.subject}`)) push(`allowlist entry not echoed in evidence waivers (matched nothing): ${e.rule} :: ${e.subject}`)
    }
  }
  // §S6's defeat-blocker: an agent that trips a RED and adds a waiver in the SAME turn goes green
  // otherwise. Read-only git makes this enforceable today.
  if (ev.allowlistDirty === true) {
    // Wording covers BOTH states `git status --porcelain` reports as unclean: ` M` (edited this turn)
    // and `??` (never committed). Observed 2026-08-02: collect-sim's allowlist is UNTRACKED, and the
    // old "modified in the verification turn" text sent a reader looking for a diff that cannot exist.
    // An untracked allowlist is the WORSE of the two — it can be rewritten with nothing for a reviewer
    // to see — so the verdict direction is unchanged; only the diagnosis is now accurate.
    push(`${gameDir}/${ALLOW_REL} is not clean in git (modified this turn, or never committed) — a waiver added or introduced by the run it exempts is not a waiver`)
  } else if (ev.allowlistDirty !== false) {
    push(`could not determine whether ${gameDir}/${ALLOW_REL} is clean in git — a check that could not run is a FAILURE, not a skip`)
  }

  // Provenance / staleness (the 8aa53ce lesson). "unknown" is a red, by design: the engine cannot
  // shell out, so the CAPTURE script fills these — if it did not, nothing ties this artifact to a tree.
  const prov = asObject(parsed.provenance) || {}
  if (typeof prov.gitSha !== 'string' || prov.gitSha === '' || prov.gitSha === 'unknown') {
    push('provenance.gitSha is missing/"unknown" — the artifact is not tied to any tree (this is the stale-evidence defect commit 8aa53ce paid for)')
  } else if (ev.gitShaIsAncestor === false) {
    push(`provenance.gitSha ${prov.gitSha.slice(0, 8)} is NOT an ancestor of HEAD — this evidence describes a tree that is not this one`)
  } else if (ev.gitShaIsAncestor !== true) {
    push(`could not verify provenance.gitSha ${String(prov.gitSha).slice(0, 8)} against HEAD — fail-closed`)
  }
  if (typeof prov.scriptSha256 !== 'string' || prov.scriptSha256 === '') {
    push('provenance.scriptSha256 missing — cannot prove which harness produced this evidence')
  } else if (typeof ev.scriptSha256OnDisk === 'string' && ev.scriptSha256OnDisk !== '') {
    if (prov.scriptSha256.toLowerCase() !== ev.scriptSha256OnDisk.toLowerCase()) {
      push(`provenance.scriptSha256 ${prov.scriptSha256.slice(0, 12)} != sha256(${gameDir}/${HARNESS_REL}) ${ev.scriptSha256OnDisk.slice(0, 12)} — the harness was edited after this run`)
    }
  } else {
    push(`could not hash ${gameDir}/${HARNESS_REL} to compare against provenance.scriptSha256 — fail-closed`)
  }

  // ── falsification coverage (§C.3) — the JS decides, exactly as grade.js:68-82 re-parses rather than
  // trusting an agent's boolean. A proof recorded against a since-edited harness proves nothing.
  const fals = asObject(ev.falsification)
  if (!fals) {
    falsificationBlockers.push(`no falsification proof at ${gameDir}/${FALSIFY_REL} — a gate never observed RED is not known to work`)
  } else {
    const proofs = Array.isArray(fals.proofs) ? fals.proofs.filter((p) => p && typeof p.phase === 'string') : []
    if (proofs.length === 0) falsificationBlockers.push('falsification file carries no proofs[]')
    const provenRed = proofs.filter((p) => p.observedVerdict === 'red').map((p) => p.phase)
    for (const p of proofs) {
      if (p.observedVerdict !== 'red') falsificationBlockers.push(`falsification proof for ${p.phase} recorded observedVerdict=${JSON.stringify(p.observedVerdict)} — the deliberate defect did NOT turn the phase red, so the phase does not bite`)
      if (typeof p.mutation !== 'string' || p.mutation === '') falsificationBlockers.push(`falsification proof for ${p.phase} names no mutation — "we broke something" is not a proof`)
    }
    // Coverage is measured against the GATING phases in the evidence (a non-gating phase cannot park
    // or red the run, so its proof is optional). `gatingSource` is the SAME set the roster floor and
    // the abstention clause used above — computed once so the three can never disagree about what
    // "gating" means, which is how a phase escapes one check by being counted differently in another.
    const uncovered = setDiff(gatingSource, provenRed)
    if (uncovered.length) falsificationBlockers.push(`gating phases with NO recorded RED (UNPROVEN, not green): [${uncovered.join(', ')}]`)
    if (typeof fals.scriptSha256 !== 'string' || fals.scriptSha256 === '') {
      falsificationBlockers.push('falsification file carries no scriptSha256 — cannot tell which harness was proven')
    } else if (typeof ev.scriptSha256OnDisk === 'string' && ev.scriptSha256OnDisk !== '' && fals.scriptSha256.toLowerCase() !== ev.scriptSha256OnDisk.toLowerCase()) {
      falsificationBlockers.push(`falsification proofs were recorded against harness sha ${fals.scriptSha256.slice(0, 12)}, but ${gameDir}/${HARNESS_REL} now hashes ${ev.scriptSha256OnDisk.slice(0, 12)} — a proof against a since-edited harness proves nothing`)
    }
    if (fals.reverted === false) falsificationBlockers.push('falsification mutations were NOT reverted — the tree still carries a deliberate defect')
  }

  // ── verdict precedence ───────────────────────────────────────────────────────────────────────────
  // malformed/red/parked are decided by the artifact itself; only a self-declared green is a CANDIDATE.
  // Among candidates: INTEGRITY FIRST (T2.5-red), then falsification (T2.5-unfalsified). Rationale —
  // `T2.5-unfalsified` says "the measurements are sound, the proof that they bite is missing", and it
  // would be a LIE about a vacuous artifact whose measurements are not sound at all. §C.8's test 1
  // (a pasted `{"phases":[{"name":"x","ok":true}]}`) must read `T2.5-red` naming the missing roster
  // phases; §C.8's test 3 reaches `T2.5-unfalsified` for a SCHEMA-CONFORMANT green artifact with no
  // proof file — which is what this ordering gives. (Note for the reader of the old artifact: the
  // collect-sim last-playtest.json committed before this contract predates §S4 — no `ok`, no
  // `provenance`, `blindTo` as a prose string — so it reads red here on schema grounds, correctly:
  // it is not evidence in the shape any reader can check.) Neither verdict is green, and blockers[]
  // carries EVERY failed clause in both cases, so the falsification clause is never invisible.
  let verdict
  if (malformed || !parsed.verdict || parsed.verdict === 'red') {
    verdict = 'T2.5-red'
  } else if (parsed.verdict === 'parked') {
    // §S4.4: parked maps to ok:false, so the CURRENT tier-status.luau reader will report T2.5 red for
    // a parked run. That is deliberate and correct — parked is not green — and this distinct workflow
    // verdict is how the distinction survives for humans until HANDOFF-2 gives the reader a 3rd state.
    verdict = 'T2.5-parked'
    if (Array.isArray(parsed.parkedBy) && parsed.parkedBy.length) {
      evidenceBlockers.push(`parked by: [${parsed.parkedBy.join(', ')}]`)
    }
  } else if (!claimsGreen) {
    verdict = 'T2.5-red'
    evidenceBlockers.push(`unrecognised verdict ${JSON.stringify(parsed.verdict)} — fail-closed`)
  } else if (evidenceBlockers.length > 0) {
    verdict = 'T2.5-red'
  } else if (falsificationBlockers.length > 0) {
    verdict = 'T2.5-unfalsified'
  } else {
    verdict = 'T2.5-green'
  }

  return { verdict, parsed, evidenceBlockers, falsificationBlockers, phases, unverified }
}

// A thin reader agent: it RUNS commands and returns raw bytes/exit codes. It judges nothing — every
// decision above is JS over these strings (grade.js's "thin runner" pattern).
const READER_SCHEMA = {
  type: 'object',
  properties: {
    evidenceRaw: { type: ['string', 'null'], description: `VERBATIM contents of ${evidencePath}, or null if the file does not exist. Do not reformat, do not summarise.` },
    rosterRaw: { type: ['string', 'null'], description: `VERBATIM contents of ${gameDir}/${PHASES_REL}, or null if absent` },
    falsificationRaw: { type: ['string', 'null'], description: `VERBATIM contents of ${gameDir}/${FALSIFY_REL}, or null if absent` },
    allowlistRaw: { type: ['string', 'null'], description: `VERBATIM contents of ${gameDir}/${ALLOW_REL}, or null if absent` },
    allowlistPorcelain: { type: 'string', description: `the EXACT stdout of \`git status --porcelain ${gameDir}/${ALLOW_REL}\` (empty string means clean). Read-only git only.` },
    scriptSha256OnDisk: { type: 'string', description: `lowercase hex sha256 of ${gameDir}/${HARNESS_REL} as it exists on disk right now; empty string if the file is absent` },
    headSha: { type: 'string', description: 'stdout of `git rev-parse HEAD`' },
    ancestorExitCode: { type: 'number', description: 'exit code of `git merge-base --is-ancestor <provenance.gitSha> HEAD` using the gitSha you read out of the evidence file (0 = is an ancestor, 1 = not, other = could not tell). Use 2 if you could not run it at all.' },
    notes: { type: 'string' },
  },
  required: ['evidenceRaw', 'rosterRaw', 'falsificationRaw', 'allowlistPorcelain', 'scriptSha256OnDisk', 'ancestorExitCode'],
}

async function readEvidenceFromDisk() {
  return await agent(`You are a THIN READER for the T2.5 playtest lane of ${gameDir}. You judge NOTHING — you run commands and return their raw output verbatim. Any interpretation you add is a bug.

You are at repo root. Do exactly this:
1. Read ${evidencePath} and return its contents VERBATIM in evidenceRaw (null if the file does not exist). If the file happens to begin with the sentinel "${SENTINEL.trim()} ", strip ONLY that prefix — the committed artifact is supposed to be sentinel-free JSON.
2. Read ${gameDir}/${PHASES_REL} -> rosterRaw (null if absent).
3. Read ${gameDir}/${FALSIFY_REL} -> falsificationRaw (null if absent).
4. Read ${gameDir}/${ALLOW_REL} -> allowlistRaw (null if absent).
5. Run \`git status --porcelain ${gameDir}/${ALLOW_REL}\` and return its EXACT stdout in allowlistPorcelain (an empty string means clean). This is READ-ONLY git and is the only git write-free check you need.
6. Compute the sha256 of ${gameDir}/${HARNESS_REL} and return it lowercase-hex in scriptSha256OnDisk (PowerShell: \`(Get-FileHash -Algorithm SHA256 <path>).Hash.ToLower()\`). Empty string if the file is absent.
7. Run \`git rev-parse HEAD\` -> headSha. Then, IF the evidence JSON has provenance.gitSha and it is not "unknown", run \`git merge-base --is-ancestor <that sha> HEAD\` and return its EXIT CODE in ancestorExitCode (0 = ancestor, 1 = not an ancestor, anything else = could not tell). If there is no usable gitSha, return 2.

HARD CONSTRAINTS: read-only git ONLY — no commit/add/checkout/reset/merge/push. No network. Edit NO file. Do not fix anything you notice. Return the StructuredOutput.`, { label: 'playtest:read-evidence', phase: 'Ingest', schema: READER_SCHEMA, effort: 'low' })
}

function ingestFromReader(reader, sourceLabel) {
  const porcelain = reader && typeof reader.allowlistPorcelain === 'string' ? reader.allowlistPorcelain.trim() : null
  const exitCode = reader && typeof reader.ancestorExitCode === 'number' ? reader.ancestorExitCode : 2
  return ingest({
    evidence: reader ? reader.evidenceRaw : null,
    roster: rosterFromManifest(reader && reader.rosterRaw),
    falsification: reader ? reader.falsificationRaw : null,
    allowlist: reader ? reader.allowlistRaw : null,
    // null (the reader itself failed) stays null so ingest reports "could not determine", not "clean".
    allowlistDirty: porcelain === null ? null : porcelain !== '',
    gitShaIsAncestor: exitCode === 0 ? true : exitCode === 1 ? false : null,
    scriptSha256OnDisk: reader ? reader.scriptSha256OnDisk : '',
    sourceLabel,
  })
}

function finish(payload) {
  const all = [].concat(payload.evidenceBlockers || [], payload.falsificationBlockers || [])
  for (const b of all) blockers.push(b)
  return all
}

// ── MODE: ingest (no authoring, no run — grade an artifact or a pasted line) ───────────────────────
if (mode === 'ingest') {
  phase('Ingest')
  let out
  if (pastedResult !== undefined && pastedResult !== null && pastedResult !== '') {
    // A pasted line still gets the FULL treatment: the roster/allowlist/sha checks run against disk,
    // so `{"tier":2.5,"ok":true,"verdict":"green","phases":[{"name":"x","ok":true}]}` cannot green a tree.
    log(`playtest-pass INGEST: ${gameDir} <- pasted result. Every clause is checked against disk anyway (a pasted artifact is not a trusted one).`)
    const reader = await readEvidenceFromDisk()
    const porcelain = reader && typeof reader.allowlistPorcelain === 'string' ? reader.allowlistPorcelain.trim() : null
    out = ingest({
      evidence: pastedResult,
      roster: rosterFromManifest(reader && reader.rosterRaw),
      falsification: reader ? reader.falsificationRaw : null,
      allowlist: reader ? reader.allowlistRaw : null,
      allowlistDirty: porcelain === null ? null : porcelain !== '',
      // A pasted line has no on-disk counterpart to date-check against; the gitSha clause below still
      // fires from `parsed.provenance`, and an absent/"unknown" sha is a red.
      gitShaIsAncestor: null,
      scriptSha256OnDisk: reader ? reader.scriptSha256OnDisk : '',
      sourceLabel: 'args.result (pasted)',
    })
  } else {
    log(`playtest-pass INGEST: ${gameDir} <- ${evidencePath}.`)
    const reader = await readEvidenceFromDisk()
    out = ingestFromReader(reader, evidencePath)
  }
  finish(out)
  log(`playtest-pass INGEST DONE. verdict: ${out.verdict} | ${blockers.length} blocker(s). ${out.verdict === 'T2.5-green' ? 'T2.5 reached: spec-derived deltas measured in-engine AND every gating phase observed RED under a deliberate defect.' : 'NOT green — blockers listed. A rung is only claimed with a real evidence artifact.'}`)
  return {
    gameDir,
    mode: 'ingest',
    verdict: out.verdict,
    evidence: out.parsed,
    falsification: null,
    blockers,
    readyFor: out.verdict === 'T2.5-green' ? 'T2.5 — automated AI playtest green (edit-mode: no physics, no LocalPlayer, frozen server clock; the CLIENT remains unverified)' : NOT_ENGINE_VERIFIED,
  }
}

// ── MODE: author (default) — derive the claims, fork the harness, write phases.json ───────────────
let authoring = null
if (mode === 'author') {
  const AUTHOR_SCHEMA = {
    type: 'object',
    properties: {
      rosterGating: { type: 'array', items: { type: 'string' }, description: 'the GATING phase names you wrote into phases.json AND the harness roster mirror (identical sets)' },
      rosterNonGating: { type: 'array', items: { type: 'string' }, description: 'the non-gating phase names' },
      actionsRegistered: { type: 'array', items: { type: 'string' }, description: 'every action id you read out of src/shared/Net.luau\'s Net.Actions registry — read it, do not recall it' },
      actionsExercised: { type: 'array', items: { type: 'string' }, description: 'the union of actions your phases actually dispatch via Harness.invokeAs' },
      specPromisesCovered: {
        type: 'array',
        description: 'one entry per player-facing promise in the spec, mapped to the phase + the exact field whose DELTA proves it',
        items: {
          type: 'object',
          properties: {
            promise: { type: 'string', description: 'the spec\'s promise in the spec\'s own words (e.g. "upgrades make you collect faster")' },
            phase: { type: 'string' },
            deltaField: { type: 'string', description: 'the field probe:delta reads BEFORE and AFTER (e.g. currencies.Stardust, capacity). A promise "covered" by a shape check is NOT covered.' },
          },
          required: ['promise', 'phase', 'deltaField'],
        },
      },
      specPromisesUncovered: { type: 'array', items: { type: 'string' }, description: 'spec promises you could NOT write a delta assertion for. Be honest — this is a FAILURE clause, not a skip, and lying here is the exact defect this lane exists to catch.' },
      bootstrapMirrorFilled: { type: 'boolean', description: 'TRUE iff you filled BOOTSTRAP_MIRROR by PARSING src/server/init.server.luau (not from memory) and it is no longer nil' },
      exampleDeleted: { type: 'boolean', description: 'TRUE iff you deleted the example-delta phase and its roster line' },
      harnessPath: { type: 'string' },
      phasesJsonPath: { type: 'string' },
      uncertain: { type: 'array', items: { type: 'string' }, description: 'anything only a real engine run can confirm' },
      notes: { type: 'string' },
    },
    required: ['rosterGating', 'rosterNonGating', 'actionsRegistered', 'actionsExercised', 'specPromisesCovered', 'specPromisesUncovered', 'bootstrapMirrorFilled', 'exampleDeleted', 'harnessPath', 'phasesJsonPath'],
  }

  phase('Author')
  log(`playtest-pass AUTHOR: ${gameDir} vs ${specPath}. Deriving what must CHANGE when the player acts, then forking ${TEMPLATE_PATH}.`)
  authoring = await agent(`You are AUTHORING the T2.5 automated AI playtest for the Roblox game at ${gameDir}. T2 already proves the place boots without throwing. Your rung answers the only question a player cares about: WHEN I ACT, DOES ANYTHING ACTUALLY CHANGE?

THE DEFECT YOU ARE BUILDING AGAINST (read it twice). In games/collect-sim, 361 Lune tests were green while ALL FOUR shop upgrades did nothing. The tests asserted that a level was WRITTEN to the save file; the rule that governed play was a hardcoded constant sitting right next to it, reading nothing. 9,625 Stardust bought exactly zero change in behaviour. Your phases must assert the DELTA — the behaviour the value governs — never the write.

READ FIRST, in this order:
1. ${specPath} — every player-facing PROMISE it makes ("upgrades make you faster", "rebirth pays more", "the daily reward is claimable once"). Each promise becomes a phase with a measured before/after.
2. ${gameDir}/src/shared/Net.luau — the Net.Actions registry. Enumerate EVERY registered action id from the source; your phases must exercise ALL of them (the lane is set-differenced against this list in JS and a lane covering three of nine actions is REJECTED).
3. ${gameDir}/src/server/init.server.luau — the ORDERED service require list. You will fill BOOTSTRAP_MIRROR from this by PARSING IT, never from memory.
4. ${gameDir}/src/server/services/ — where the tuning curves and catalogs live: the seams whose effect you must measure.
5. .claude/skills/lib/templates/tier2/AUTHORING.md and ${TEMPLATE_PATH} — the harness contract. READ THE AUTHORING DOC BEFORE WRITING A LINE.

THEN DO, IN ORDER:
a. Copy ${TEMPLATE_PATH} to ${gameDir}/${HARNESS_REL} (and AUTHORING.md alongside it if it is not already there).
b. Fill BOOTSTRAP_MIRROR from init.server.luau. It ships nil, and nil is RED with the detail "BOOTSTRAP_MIRROR is still nil". This is the single highest-yield check in the file: collect-sim's mirrored list silently omitted WorldService, so every "T2 green" for weeks ran against a Workspace containing ZERO PARTS and every world assertion passed vacuously.
c. Write the phases. A phase BODY RETURNS NOTHING — the harness derives the result from probe state, so you cannot compute your own green. Your vocabulary is: probe:subjects(n, what) for what you DISCOVERED, probe:delta(label, read, act, expect) where the HARNESS calls read() on both sides (you never snapshot yourself), probe:expect for shape checks (which can NEVER satisfy a phase on their own), probe:unmeasurable(label, why) which DISQUALIFIES green, and probe:note for diagnostics. Every spec promise gets at least one probe:delta naming the exact field.
d. Delete the example-delta phase and its roster line. While it is present the harness FORCES verdict "parked" — that is mechanical, not advisory.
e. Write ${gameDir}/${PHASES_REL}: the committed roster authority, shaped {"$schema":"t25-phases/1","phases":[{"name":"...","gating":true}, ...]}. It must set-EQUAL the harness's inline roster mirror in BOTH directions — the ingest side diffs them and any difference is red.

HARD RULES you will be graded on mechanically, in JS, from your structured return — your own opinion of the lane is not consulted:
- at least 3 GATING phases;
- actionsRegistered MINUS actionsExercised must be EMPTY;
- specPromisesUncovered must be EMPTY — a spec promise with no delta assertion is a FAILURE, not a skip. Do NOT trim the promise list to make this pass; an under-declared list is the vacuity defect itself.
- Never write "could not check" into a pass string. If you cannot measure something, it goes to probe:unmeasurable, which disqualifies green. Three such strings exist in the current collect-sim harness ("NOT a defect", two "UNCHECKED"s) and all three are forbidden shapes.

HARD CONSTRAINTS: do NOT run git (read-only git is fine, writes are fenced). No network. Do NOT edit ${gameDir}/${ALLOW_REL} — a waiver added in the verification turn is mechanically rejected downstream. Run stylua on the harness with the game's own stylua.toml. You cannot execute the harness (no engine here) — list anything engine-only in \`uncertain\`. Return the StructuredOutput.`, { label: 'playtest:author', phase: 'Author', schema: AUTHOR_SCHEMA, effort: 'high' })

  // ── JS-computed authoring gates (§C.2). NEVER the agent's word: this is the same hardening
  // grade.js:68-82 got. An empty or tiny roster scores 100% on any per-phase metric, so the roster
  // itself is what gets audited here.
  const rosterGating = Array.isArray(authoring && authoring.rosterGating) ? authoring.rosterGating.filter((x) => typeof x === 'string') : []
  const registered = Array.isArray(authoring && authoring.actionsRegistered) ? authoring.actionsRegistered.filter((x) => typeof x === 'string') : []
  const exercised = Array.isArray(authoring && authoring.actionsExercised) ? authoring.actionsExercised.filter((x) => typeof x === 'string') : []
  const uncovered = Array.isArray(authoring && authoring.specPromisesUncovered) ? authoring.specPromisesUncovered : []
  const covered = Array.isArray(authoring && authoring.specPromisesCovered) ? authoring.specPromisesCovered.filter((c) => c && typeof c === 'object') : []

  if (!authoring) blockers.push('authoring agent returned nothing — the lane was not authored')
  if (rosterGating.length < 3) blockers.push(`too few gating phases: ${rosterGating.length} (need >= 3) — a lane with a tiny roster scores 100% on everything`)
  if (registered.length === 0) blockers.push('authoring reported ZERO registered actions — either Net.Actions was not read or the registry is empty; a lane with no actions to exercise is vacuous')
  const unexercised = setDiff(registered, exercised)
  // The set-difference that caught the missing WorldService, applied to the action registry: it stops a
  // lane that quietly covers three of nine actions from reporting on the whole game.
  if (unexercised.length) blockers.push(`registered actions never exercised by any phase: [${unexercised.join(', ')}]`)
  if (uncovered.length) blockers.push(`spec promises with NO delta assertion (a failure, not a skip): [${uncovered.join(', ')}]`)
  if (covered.length === 0) blockers.push('no spec promise was mapped to a delta assertion — this is exactly how 361 green tests coexisted with four upgrades that did nothing')
  for (const c of covered) {
    if (typeof c.deltaField !== 'string' || c.deltaField === '') blockers.push(`spec promise "${c.promise}" names no deltaField — a promise "covered" by a shape check is not covered`)
  }
  if (authoring && authoring.bootstrapMirrorFilled !== true) blockers.push('BOOTSTRAP_MIRROR was not filled from init.server.luau — the harness will (correctly) report red')
  if (authoring && authoring.exampleDeleted !== true) blockers.push('the example-delta phase is still present — the harness will force verdict "parked"')

  log(`playtest-pass AUTHOR done. gating=${rosterGating.length} | actions ${exercised.length}/${registered.length} exercised | promises ${covered.length} covered, ${uncovered.length} UNCOVERED | ${blockers.length} authoring blocker(s).`)
}

// ── PHASE 2: FALSIFY — mandatory before green (§C.3) ───────────────────────────────────────────────
let falsification = null
if (mode === 'author') {
  const FALSIFY_SCHEMA = {
    type: 'object',
    properties: {
      scriptSha256: { type: 'string', description: `lowercase-hex sha256 of ${gameDir}/${HARNESS_REL} as it stands NOW, after every mutation was reverted` },
      proofScriptSha256: { type: 'string', description: 'the sha256 of the harness AT THE TIME the proofs were taken — if you edited the harness between proofs, these differ and the proofs are void' },
      coveredPhases: { type: 'array', items: { type: 'string' }, description: 'gating phases for which you OBSERVED a red under a deliberate defect' },
      missingPhases: { type: 'array', items: { type: 'string' }, description: 'gating phases you could NOT drive red. Report them honestly — an unproven phase is reported UNPROVEN, never green.' },
      reverted: { type: 'boolean', description: 'TRUE iff every deliberate mutation was reverted and the tree is clean of them' },
      proofsPath: { type: 'string' },
      notes: { type: 'string' },
    },
    required: ['scriptSha256', 'proofScriptSha256', 'coveredPhases', 'missingPhases', 'reverted', 'proofsPath'],
  }

  phase('Falsify')
  log(`playtest-pass FALSIFY: proving each gating phase can go RED. A gate never observed red is not known to work.`)
  falsification = await agent(`You are the FALSIFIER for the T2.5 lane at ${gameDir}. The lane was just authored. Your job is to prove each GATING phase actually BITES — because three of the collect-sim harness's own first-run results turned out to be bugs in the HARNESS, not the game: a check matching an error string Luau never exposes, a check the Baseplate made unfailable, and a check that measured the rate limiter rather than the game.

FOR EACH GATING PHASE in ${gameDir}/${PHASES_REL}: introduce ONE deliberate defect in the GAME (never in the harness) that the phase claims to catch, rerun the lane, and record the observed verdict + the detail line. Then REVERT the mutation before moving to the next. Examples of honest mutations: delete a service from the init.server bootstrap list (bootstrap-parity); replace a tuning curve with a constant so the upgrade delta vanishes (upgrade/effect phases); unanchor or zero-size a part, or delete the SpawnLocation (world-contract / spawn-safety); remove a barrier so a gated region becomes freely walkable (traversal); unregister an action handler (affordance-wiring).

FIRST resolve the run-in-roblox binary, because the bare name is the WRONG BINARY on this repo's machines: this repo pins its toolchain with rokit.toml, and \`run-in-roblox --version\` off PATH can resolve to an Aftman shim that errors with "no aftman.toml files list this tool". Try \`run-in-roblox --version\`; if it does not print a version, use \`~/.rokit/bin/run-in-roblox\`. Call the working one RIR below.

Run the lane exactly like this (the old RUNBOOK.md:81 recipe is BROKEN — it greps '^\\{"ok"' but the artifact begins {"verdict", key order in HttpService:JSONEncode is unspecified, the pipeline's exit status is tail's and is always 0, and '>' truncates the last good artifact before you know the run produced anything):
  set -o pipefail
  rojo build default.project.json -o tier2.rbxlx     # MANDATORY after EVERY mutation — see below
  \$RIR --place tier2.rbxlx --script tests/tier2/playtest.server.luau > .verify_tmp/harvest/t25.out
  grep -m1 '^${SENTINEL}' .verify_tmp/harvest/t25.out | sed 's/^${SENTINEL}//' > .verify_tmp/harvest/t25.json
Scratch files go under ${'C:/Users/opedr/OneDrive/Documents/developer/roblox/roblox-game-factory/.verify_tmp/harvest/'} — never the system temp dir.

**REBUILD THE PLACE AFTER EVERY MUTATION.** run-in-roblox boots a .rbxlx FILE, not your working tree. Skip the rojo build and you rerun the lane against the PREVIOUS place: your deliberate defect never reaches the engine, the phase comes back exactly as it was, and you conclude the gate does not bite when in fact the gate never saw the mutation. That failure has already shipped once in this factory as "the T2 smoke had been building NOTHING". If a mutation produces NO change in the verdict, suspect this before you suspect the phase — verify by grepping your mutation out of the freshly built tier2.rbxlx.

If NEITHER run-in-roblox invocation works you cannot observe anything: do NOT invent proofs. Return every gating phase in missingPhases with a note saying the engine lane was down, and write NO falsification file.

WRITE ${gameDir}/${FALSIFY_REL}:
{"$schema":"t25-falsification/1","scriptSha256":"<sha256 of ${HARNESS_REL} at proof time>","proofs":[{"phase":"...","mutation":"what you broke, concretely","observedVerdict":"red","observedDetail":"the harness's own detail line, verbatim","ranAtUnix":<unix>}]}

THEN VERIFY THE TREE IS CLEAN: every mutation reverted, \`git status --porcelain\` shows no leftover defect. Report reverted honestly.

HARD CONSTRAINTS: read-only git ONLY (no commit/add/checkout/reset/stash — the revert must be a real edit you make, not a git operation). No network. Do NOT edit ${gameDir}/${ALLOW_REL}. Do NOT weaken a phase to make it pass, and do NOT "fix" a game defect you discover — report it. Your booleans are NOT the verdict: the JS re-derives coverage from coveredPhases/missingPhases and the two shas. Return the StructuredOutput.`, { label: 'playtest:falsify', phase: 'Falsify', schema: FALSIFY_SCHEMA, effort: 'high' })

  const missing = Array.isArray(falsification && falsification.missingPhases) ? falsification.missingPhases : []
  if (!falsification) blockers.push('falsifier returned nothing — no phase is known to bite')
  if (missing.length) blockers.push(`gating phases never observed RED (UNPROVEN, not green): [${missing.join(', ')}]`)
  if (falsification && falsification.reverted !== true) blockers.push('falsification mutations not reverted — the tree still carries a deliberate defect')
  if (falsification && falsification.scriptSha256 !== falsification.proofScriptSha256) {
    blockers.push(`harness sha changed between the proofs (${String(falsification.proofScriptSha256).slice(0, 12)}) and now (${String(falsification.scriptSha256).slice(0, 12)}) — a proof against a since-edited harness proves nothing`)
  }
  log(`playtest-pass FALSIFY done. proven=${falsification && Array.isArray(falsification.coveredPhases) ? falsification.coveredPhases.length : 0} | unproven=${missing.length}.`)
}

// ── PHASE 3: RUN, or degrade honestly (§C.4) ───────────────────────────────────────────────────────
// Lane availability = a run-in-roblox binary that MEASURABLY RUNS (at the bare name or the rokit path)
// AND rojo AND a declaration (GATE_ENGINE_LANE, or an orchestrator declaration carrying a reason). A
// workflow cannot read the environment, so a thin probe agent reports the raw facts and the JS decides
// — mirroring smoke-gate.js:112-123: PREPARE THE LANE AND PARK, never skip and never guess.
const LANE_SCHEMA = {
  type: 'object',
  properties: {
    runInRobloxOnPath: { type: 'boolean', description: 'does the BARE `run-in-roblox --version` print a version? FALSE if it errors (e.g. an Aftman shim that refuses).' },
    runInRobloxRokit: { type: 'boolean', description: 'does `~/.rokit/bin/run-in-roblox --version` print a version?' },
    runInRobloxInvocation: { type: ['string', 'null'], description: 'the EXACT command that printed a version — "run-in-roblox" or "~/.rokit/bin/run-in-roblox". null if neither worked.' },
    runInRobloxVersion: { type: ['string', 'null'], description: 'the version string it printed, verbatim' },
    gateEngineLane: { type: 'string', description: 'the literal value of the GATE_ENGINE_LANE env var, or "" if unset' },
    rojoOnPath: { type: 'boolean' },
    notes: { type: 'string' },
  },
  required: ['runInRobloxOnPath', 'runInRobloxRokit', 'runInRobloxInvocation', 'gateEngineLane', 'rojoOnPath'],
}

phase('Run')
const lane = await agent(`Report, factually, whether the T2.5 ENGINE LANE is available on this machine. You judge nothing else and change nothing.

From the repo root, run all three and report exactly what happened:
  1. \`run-in-roblox --version\`            <- the BARE name, resolved off PATH
  2. \`~/.rokit/bin/run-in-roblox --version\` <- the ROKIT-PINNED binary
  3. \`rojo --version\`
This repo pins its toolchain with rokit.toml, NOT aftman.toml, and on at least one machine the bare
name resolves to an Aftman shim that errors with "Tried to run an Aftman-managed version of
run-in-roblox, but no aftman.toml files list this tool". That is a WRONG SHIM, not a missing tool —
report runInRobloxOnPath=false for it and runInRobloxRokit=true if the rokit path works, and set
runInRobloxInvocation to whichever one actually printed a version (prefer the bare name when both work).
Also report the literal value of the GATE_ENGINE_LANE environment variable (PowerShell:
\`$env:GATE_ENGINE_LANE\`), or "" if unset.

Do NOT install anything, do NOT run git, do NOT edit any file, no network. Return the StructuredOutput.`, { label: 'playtest:lane-probe', phase: 'Run', schema: LANE_SCHEMA, effort: 'low' })

// The binary is MEASURED (the probe ran it), never declared. Only WHICH invocation works is in doubt:
// the bare name is an Aftman shim on this machine and errors, which used to read as "the engine lane is
// down" and park a lane that was in fact up. ENGINE-FACTS.md recorded that trap months before this
// probe stopped falling into it.
const RIR = (lane && typeof lane.runInRobloxInvocation === 'string' && lane.runInRobloxInvocation) || 'run-in-roblox'
const runInRobloxWorks = !!(lane && (lane.runInRobloxOnPath === true || lane.runInRobloxRokit === true) && lane.runInRobloxInvocation)

// The DECLARATION is separate from the binary, and either source satisfies it: the GATE_ENGINE_LANE env
// var, or an explicit orchestrator declaration in args. A workflow script cannot read the environment
// and its agents get fresh shells, so on a machine where the operator cannot export a variable into
// every subagent, the env check alone can only ever say "down" — it stops being a measurement of the
// lane and becomes a measurement of the shell. This mirrors `allowGauntletRedStages` in fanout.js: the
// orchestrator is the only party who CAN measure the machine, so it declares, WITH A REASON, and the
// declaration is logged. It is not a bypass — `runInRobloxWorks` above is still measured by the probe,
// and a declaration with no working binary still parks.
const gateFlag = lane && typeof lane.gateEngineLane === 'string' ? lane.gateEngineLane.trim().toLowerCase() : ''
const envDeclared = gateFlag === '1' || gateFlag === 'true'
const declaredReason = (input && typeof input.engineLaneReason === 'string' && input.engineLaneReason.trim()) || ''
const orchestratorDeclared = !!(input && input.engineLane === true && declaredReason)
if (input && input.engineLane === true && !declaredReason) {
  blockers.push('args.engineLane was declared with no engineLaneReason — an undocumented lane declaration is not a declaration')
}
const laneDeclared = envDeclared || orchestratorDeclared
if (orchestratorDeclared && !envDeclared) {
  log(`playtest-pass: engine lane declared by the ORCHESTRATOR (GATE_ENGINE_LANE is unset in the agent shell). Reason, verbatim: ${declaredReason}`)
}
const laneAvailable = !!(runInRobloxWorks && lane && lane.rojoOnPath === true && laneDeclared)

if (!laneAvailable) {
  // Honest degradation. The lane is PREPARED (authored + a falsification plan), not run, and the
  // verdict says so. evidence: null — there is no evidence line, so no rung above T1 is claimed.
  const why = !lane
    ? 'lane probe did not run'
    : [runInRobloxWorks ? null : 'run-in-roblox not runnable at either the bare name or ~/.rokit/bin', lane.rojoOnPath === true ? null : 'rojo not on PATH', laneDeclared ? null : `lane undeclared (GATE_ENGINE_LANE=${JSON.stringify(lane.gateEngineLane)}, no args.engineLane+engineLaneReason)`].filter(Boolean).join('; ')
  blockers.push(`engine lane unavailable: ${why}`)
  log(`playtest-pass PARK: engine lane unavailable (${why}). The lane is AUTHORED and the falsification plan is written, but nothing ran. verdict: T2.5-blocked-on-human. Honest status: ${NOT_ENGINE_VERIFIED}.`)
  return {
    gameDir,
    specPath,
    mode,
    verdict: 'T2.5-blocked-on-human',
    evidence: null, // no evidence line exists — T2.5 is NOT claimed, and never guessed at
    falsification,
    authoring,
    blockers,
    readyFor: NOT_ENGINE_VERIFIED,
  }
}

const RUN_SCHEMA = {
  type: 'object',
  properties: {
    ranOk: { type: 'boolean', description: 'did rojo build + run-in-roblox both complete?' },
    sentinelLineCount: { type: 'number', description: `how many lines in the captured stdout begin with "${SENTINEL.trim()} " (must be exactly 1, and it must be the LAST line)` },
    sentinelWasLastLine: { type: 'boolean' },
    evidenceJson: { type: ['string', 'null'], description: 'the sentinel-stripped JSON, VERBATIM. null if no sentinel line was produced — do NOT fabricate one.' },
    wroteArtifact: { type: 'boolean', description: `did you move the validated JSON onto ${gameDir}/${HARNESS_REL.replace('playtest.server.luau', 'last-playtest.json')}? Only after it parsed.` },
    stdoutTail: { type: 'string', description: 'the last ~30 lines of captured stdout, for diagnosis' },
    notes: { type: 'string' },
  },
  required: ['ranOk', 'sentinelLineCount', 'sentinelWasLastLine', 'evidenceJson', 'wroteArtifact'],
}

log(`playtest-pass RUN: engine lane UP — binary MEASURED at \`${RIR}\` (${lane.runInRobloxVersion || 'version unreported'}), rojo present, lane declared by ${envDeclared ? `GATE_ENGINE_LANE=${lane.gateEngineLane}` : 'the orchestrator'}. Building the place and running the T2.5 harness.`)
const run = await agent(`RUN the T2.5 playtest lane for ${gameDir} and capture its evidence line. You are a runner: you do not judge the result and you do not fix anything you see.

From the repo root, using EXACTLY this capture recipe (§S3 of the build contract — the RUNBOOK.md:81 recipe is broken and must not be used: it greps '^\\{"ok"' while the artifact begins {"verdict", HttpService:JSONEncode key order is unspecified, the pipeline's exit status is tail's and so is always 0, and '>' truncates the previous good artifact before you know the run produced anything):

  set -o pipefail
  cd ${gameDir} && rojo build default.project.json -o tier2.rbxlx    # ALWAYS rebuild: run-in-roblox boots the FILE, not your tree
  ${RIR} --place tier2.rbxlx --script ${HARNESS_REL} > ../../.verify_tmp/harvest/t25.out
  grep -c '^${SENTINEL}' ../../.verify_tmp/harvest/t25.out          # MUST be exactly 1
  grep -m1 '^${SENTINEL}' ../../.verify_tmp/harvest/t25.out | sed 's/^${SENTINEL}//' > ../../.verify_tmp/harvest/t25.json
  node -e 'JSON.parse(require("fs").readFileSync("../../.verify_tmp/harvest/t25.json","utf8"))'

(\`${RIR}\` is the invocation the lane probe MEASURED as working on this machine — do not substitute the bare name. And note \`lune run -e\` DOES NOT EXIST in lune 0.10.4: it exits 1, so a \`&& mv\` chained behind it never fires and the previous, stale artifact silently survives as the "result". \`node -e\` is the working decode check.)

ONLY after that decode succeeds, move .verify_tmp/harvest/t25.json onto ${gameDir}/tests/tier2/last-playtest.json (the committed artifact contains the JSON ONLY, sentinel stripped — tier-status.luau serde.decodes the whole file). If NO sentinel line was produced, or it is not the last line, or it does not parse: report that honestly with evidenceJson=null and wroteArtifact=false, and LEAVE THE EXISTING ARTIFACT UNTOUCHED. A missing sentinel is a RED, never an "absent" — and a truncated good artifact destroys the only prior evidence.

Scratch under ${'.verify_tmp/harvest/'} only. HARD CONSTRAINTS: no git writes, no network, do NOT edit the harness, the game source, or ${gameDir}/${ALLOW_REL}. Return the StructuredOutput.`, { label: 'playtest:run', phase: 'Run', schema: RUN_SCHEMA, effort: 'medium' })

if (!run || run.ranOk !== true) blockers.push('the lane did not run to completion (rojo build or run-in-roblox failed)')
if (run && run.sentinelLineCount !== 1) blockers.push(`expected exactly ONE ${SENTINEL.trim()} line, saw ${run ? run.sentinelLineCount : 'none'} — an evidence line printed more than once (or not at all) is not evidence`)
if (run && run.sentinelWasLastLine !== true) blockers.push('the evidence line was not the LAST line of stdout — the harness must print its verdict only after every phase, so an abort reads as a failure')

// ── PHASE 4: INGEST the artifact this run just produced ────────────────────────────────────────────
phase('Ingest')
const reader = await readEvidenceFromDisk()
// Prefer the freshly-captured line if the runner has it; fall back to the on-disk artifact. Either way
// every clause is checked against DISK (roster, harness sha, allowlist cleanliness, gitSha ancestry).
const freshJson = run && typeof run.evidenceJson === 'string' && run.evidenceJson !== '' ? run.evidenceJson : null
const porcelain = reader && typeof reader.allowlistPorcelain === 'string' ? reader.allowlistPorcelain.trim() : null
const exitCode = reader && typeof reader.ancestorExitCode === 'number' ? reader.ancestorExitCode : 2
const out = ingest({
  evidence: freshJson !== null ? freshJson : reader && reader.evidenceRaw,
  roster: rosterFromManifest(reader && reader.rosterRaw),
  falsification: reader ? reader.falsificationRaw : null,
  allowlist: reader ? reader.allowlistRaw : null,
  allowlistDirty: porcelain === null ? null : porcelain !== '',
  gitShaIsAncestor: exitCode === 0 ? true : exitCode === 1 ? false : null,
  scriptSha256OnDisk: reader ? reader.scriptSha256OnDisk : '',
  sourceLabel: freshJson !== null ? 'the captured sentinel line' : evidencePath,
})
finish(out)

// The workflow verdict is the ingest verdict UNLESS an earlier stage already blocked green. An
// authoring/falsification/run blocker can never be laundered away by a green-looking artifact.
let verdict = out.verdict
if (verdict === 'T2.5-green' && blockers.length > 0) {
  verdict = 'T2.5-red'
  blockers.unshift('the artifact reads green but an earlier stage blocked the lane (see below) — an artifact cannot vouch for the lane that produced it')
}

// Say plainly WHICH RUNG WAS REACHED. Never a bare "done": a T2.5 green is an EDIT-MODE result — the
// server clock does not advance, physics does not step, there is no LocalPlayer, and game.JobId is "".
// The entire client and all physics remain unverified until the T2.7 live-Studio pass.
const readyFor = verdict === 'T2.5-green'
  ? 'T2.5 — automated AI playtest green (edit-mode: frozen server clock, no physics stepping, no LocalPlayer, JobId=""). The CLIENT and ALL PHYSICS remain UNVERIFIED; next rung is T2.7 (live Studio), then T3 (human).'
  : verdict === 'T2.5-parked'
    ? 'T2.5 PARKED — every gating phase passed but something is unverified/non-gating-red. Parked is NOT green; the current tier-status.luau reader will (correctly) show T2.5 red until HANDOFF-2.'
    : verdict === 'T2.5-unfalsified'
      ? 'T2.5 UNPROVEN — the artifact reads green but at least one gating phase has never been observed RED. A gate never observed red is not known to work.'
      : NOT_ENGINE_VERIFIED

log(`playtest-pass DONE. verdict: ${verdict} | rung: ${readyFor} | ${blockers.length} blocker(s)${blockers.length ? ': ' + blockers.slice(0, 3).join(' | ') + (blockers.length > 3 ? ' | ...' : '') : ''}`)

return {
  gameDir,
  specPath,
  mode,
  verdict,
  evidence: out.parsed,
  falsification,
  authoring,
  blockers,
  readyFor,
}
