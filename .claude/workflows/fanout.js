// fanout.js — build-game Workflow B core: the feature fan-out + N=2 auto-fix loop.
//
// Runs ONE dependency-batch of features (the orchestrator runs it once per batch, adjudicating +
// committing between batches because a later batch may depend on an earlier feature's REAL impl).
// Per feature it REUSES the proven build-features engine (build -> independent gate: author + 3
// adversarial critics) via a nested workflow() call, then adds the bounded auto-fix loop the
// decompose-design locked (§6b, N=2): on a bug-found verdict a falsify-first FIXER agent closes the
// bug (reproduce RED -> fix -> prove GREEN + gauntlet), up to autoFixRounds rounds, else PARK.
//
// Commits NOTHING and edits no src/shared: the contract pass already wrote every shared delta, and
// the orchestrator (main session) adjudicates the returned verdicts, re-runs the gauntlet, and
// union-merges the green features onto staging. This is the maker(builder) != checker(gate) !=
// fixer != orchestrator division the factory is built on.
//
// args (JSON object):
//   {
//     gameDir: "games/collect-sim",
//     buildFeaturesPath: "<abs path to build-features.js>",   // nested by scriptPath (avoids stale-name cache)
//     autoFixRounds: 2,
//     features: [ { name, serviceName, specSlice, contractSummary, hasUI }, ... ]   // ONE batch
//   }

export const meta = {
  name: 'fanout',
  description: 'build-game Workflow B core: fan out ONE dependency-batch of features. Per feature it reuses the proven build-features engine (independent builder + independent gate of author + 3 adversarial critics) via a nested workflow call, then runs the bounded N=2 auto-fix loop on a bug-found verdict (a falsify-first fixer closes the bug: reproduce RED -> fix -> prove GREEN + gauntlet), else parks. Commits nothing; edits no src/shared; the orchestrator adjudicates + union-merges the green features.',
  phases: [
    { title: 'Fanout', detail: 'per feature: build + independent gate (via build-features), then the N=2 falsify-first auto-fix loop on bug-found' },
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
// No game default: silently building into the WRONG game is worse than failing here.
const gameDir = input && input.gameDir
if (!gameDir) throw new Error('fanout: args must supply {gameDir, buildFeaturesPath, features}.')
const buildFeaturesPath = input && input.buildFeaturesPath
const autoFixRounds = (input && input.autoFixRounds) || 2
const features = (input && input.features) || []
// Passed straight through to build-features — see the long note at the top of that script for why
// these exist. Repeating the reasoning here would let the two copies drift; this is the pipe, not
// the policy. Both default OFF, and both are the orchestrator's to set.
const allowGauntletRedStages = (input && input.allowGauntletRedStages) || []
const gauntletRedReason = (input && input.gauntletRedReason) || ''
const mode = (input && input.mode) || 'full'
log(`fanout: ${features.length} feature(s) on ${gameDir} (one batch); autoFixRounds=${autoFixRounds}; mode=${mode}${allowGauntletRedStages.length ? `; known-red ALLOWED: [${allowGauntletRedStages.join(', ')}]` : ''}. Nested build-features via scriptPath. Commits nothing.`)

if (!buildFeaturesPath) {
  log('fanout: ERROR — no buildFeaturesPath supplied; cannot nest build-features. Aborting.')
  return { gameDir, error: 'missing buildFeaturesPath', results: [] }
}
if (features.length === 0) {
  log('fanout: no features supplied — nothing to build.')
  return { gameDir, results: [] }
}

const FIXER_SCHEMA = {
  type: 'object',
  properties: {
    fixed: { type: 'boolean', description: 'TRUE if you applied a real fix to the implementation' },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    regressionTest: {
      type: 'object',
      properties: {
        added: { type: 'boolean' },
        wasRedBeforeFix: { type: 'boolean', description: 'did you confirm the new test FAILS on the un-fixed impl (falsify-first) before applying the fix?' },
        falsifiability: { type: 'string', description: 'what the test asserts that was RED before / GREEN after (the exact invariant)' },
      },
      required: ['added', 'wasRedBeforeFix', 'falsifiability'],
    },
    changedFiles: { type: 'array', items: { type: 'string' } },
    rootCause: { type: 'string' },
    stillBroken: { type: 'array', items: { type: 'string' }, description: 'anything not closed (empty if fully fixed + green)' },
    notes: { type: 'string' },
  },
  required: ['fixed', 'gauntletOk', 'luneResult', 'regressionTest', 'changedFiles', 'stillBroken'],
}

function fixerPrompt(dir, f, bugs) {
  const bugList = (bugs || [])
    .map((b, i) => `  ${i + 1}. [${b.severity || 'n/a'}] ${b.title || b.case || 'bug'} — ${b.evidence || b.why || ''} (spec: ${b.specReference || 'n/a'})`)
    .join('\n')
  return `You are an INDEPENDENT FIXER for the "${f.name}" feature of the Roblox game at ${dir}. The independent test gate found a REAL bug (the builder + 2 other critics missed it). Close it FALSIFY-FIRST: a fix whose test was never observed RED is not known to fix anything.

THE BUG(S) the economy red-team / gate found:
${bugList || '  (see the gate report; reproduce the failing case from the spec)'}

You are at repo root. The feature's service is ${dir}/src/server/services/${f.name}/${f.serviceName}.luau; its spec-derived gate tests are ${dir}/tests/unit/${f.name}.spec.luau. READ both + ${dir}/CLAUDE.md (esp. §3 server-authoritative, §4 concurrency-safe economy: the whole read-check-write goes in ONE ctx.data:update transform on the lock-held re-read snapshot; never read-then-write a balance across a yield). Study ${dir}/tests/unit/economy_race.spec.luau for the interleaving technique.

DO, IN ORDER (falsify-first):
1. REPRODUCE: add a regression test to ${dir}/tests/unit/${f.name}.spec.luau that FAILS on the CURRENT (buggy) implementation — run the gauntlet and CONFIRM it is RED. If you cannot make it fail, the bug may be misdiagnosed — report that in stillBroken instead of forcing a fix.
2. FIX: apply the MINIMAL implementation change to ${dir}/src/server/services/${f.name}/ that restores the invariant (e.g. clamp to a cap, move an operand inside the transform, derive a value server-side). Do NOT weaken any existing gate test. Do NOT edit src/shared or init.server (report a needed contract amendment instead).
3. PROVE: re-run the gauntlet — the new regression test must now be GREEN and the full suite must pass (no regression). Report the falsifiability (what the test asserts that was RED before and GREEN after).

HARD CONSTRAINTS: do NOT run git / commit / stage. Run stylua on edited files (self-heal). VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${dir} — iterate until {"ok":true,...}.${allowGauntletRedStages.length ? `

KNOWN-RED GAUNTLET STAGE(S): [${allowGauntletRedStages.join(', ')}]. The orchestrator established these are red for a reason outside any single feature's slice${gauntletRedReason ? `: ${gauntletRedReason}` : '.'} "Iterate until ok:true" does not apply to them and that green is not reachable from here. Your target is every OTHER stage green plus your regression test RED-then-GREEN, with no NEW known-red failure naming this feature. Never satisfy a gate rule with code written only to satisfy it — set gauntletOk honestly and name the red stage in notes.` : ''} Return the StructuredOutput (set regressionTest.wasRedBeforeFix truthfully).`
}

phase('Fanout')
const results = []

for (let i = 0; i < features.length; i++) {
  const f = features[i]

  // --- build + independent gate via the proven build-features engine (nested, ONE feature) ---
  const bf = await workflow({ scriptPath: buildFeaturesPath }, { gameDir, features: [f], allowGauntletRedStages, gauntletRedReason, mode })
  const r = bf && bf.results && bf.results[0] ? bf.results[0] : null
  if (!r) {
    log(`fanout: ${f.name} — build-features returned no result; recording build-failed.`)
    results.push({ feature: f.name, verdict: 'build-failed', buildFeatures: bf || null, fixes: [] })
    continue
  }

  let verdict = r.verdict
  const fixes = []

  // --- bounded N=2 auto-fix loop on a real bug ---
  let round = 0
  while (verdict === 'bug-found' && round < autoFixRounds) {
    round++
    log(`fanout: ${f.name} — bug-found; auto-fix round ${round}/${autoFixRounds} (falsify-first fixer).`)
    const fix = await agent(fixerPrompt(gameDir, f, r.realBugs), {
      label: `fix:${f.name}#${round}`,
      phase: 'Fanout',
      schema: FIXER_SCHEMA,
      effort: 'high',
    })
    fixes.push(fix || { round, fixed: false, note: 'fixer agent returned null' })

    // ALREADY-CLOSED IS NOT A FAILURE. A fixer that finds the bug already fixed — because an earlier
    // round in this same loop landed it — correctly reports fixed=false (it changed no code) with an
    // EMPTY stillBroken. Without this branch that is indistinguishable from "I could not fix it", so
    // the loop burns its remaining rounds and then PARKS a feature whose bugs are closed. Observed on
    // salvage: round 1 fixed both findings, round 2 re-derived the falsification independently by
    // reverting each fix line-by-line, confirmed both tests bite, added one more — and parked it.
    //
    // The bar is deliberately the same evidence any close requires: a was-RED regression test and a
    // green gauntlet. What is relaxed is ONLY the "did you personally edit the implementation"
    // clause, which is a question about authorship, not about whether the bug is closed.
    if (fix && !fix.fixed && (!fix.stillBroken || fix.stillBroken.length === 0) && fix.regressionTest && fix.regressionTest.added && fix.regressionTest.wasRedBeforeFix && (fix.gauntletOk || allowGauntletRedStages.length > 0)) {
      log(`fanout: ${f.name} — fixer applied no code change but reports NOTHING still broken, with a was-RED regression test and a green gauntlet: the finding was already closed (earlier round). Treating as fixed rather than parking a closed bug.`)
      verdict = 'fixed'
      break
    }
    // The fixer closes the bug iff it applied a real fix, added a falsify-first (was-RED) regression
    // test, and the gauntlet is green. Otherwise loop (another round) or fall through to park.
    // The gauntlet clause carries the same known-red override as the build and gate steps: without
    // it, a fixer that genuinely closed the bug would still be looped and then PARKED because a stage
    // no fix can reach is red. Every OTHER condition here is untouched — a fix with no was-RED test
    // still does not close a bug, override or not.
    const fixGauntletOk = !!(fix && (fix.gauntletOk || allowGauntletRedStages.length > 0))
    if (fix && fix.fixed && fixGauntletOk && fix.regressionTest && fix.regressionTest.added && fix.regressionTest.wasRedBeforeFix && (!fix.stillBroken || fix.stillBroken.length === 0)) {
      verdict = 'fixed'
      break
    }
  }
  if (verdict === 'bug-found') {
    verdict = 'parked' // auto-fix exhausted without a clean falsify-first close
    log(`fanout: ${f.name} — auto-fix exhausted after ${round} round(s); PARKED for human review.`)
  }

  log(`fanout: ${f.name} -> ${verdict}${fixes.length ? ` (after ${fixes.length} fix round(s))` : ''}`)
  results.push({ feature: f.name, verdict, fixRounds: fixes.length, buildFeatures: r, fixes })
}

const ready = results.filter((x) => x.verdict === 'green' || x.verdict === 'fixed').map((x) => x.feature)
const needsHuman = results.filter((x) => x.verdict !== 'green' && x.verdict !== 'fixed').map((x) => `${x.feature}:${x.verdict}`)
log(`fanout done. ready-to-merge (orchestrator re-adjudicates): [${ready.join(', ')}] | needs human: [${needsHuman.join(', ')}]`)

return { gameDir, featureCount: features.length, ready, needsHuman, results }
