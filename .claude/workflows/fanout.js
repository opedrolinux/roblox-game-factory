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
const gameDir = (input && input.gameDir) || 'games/collect-sim'
const buildFeaturesPath = input && input.buildFeaturesPath
const autoFixRounds = (input && input.autoFixRounds) || 2
const features = (input && input.features) || []
log(`fanout: ${features.length} feature(s) on ${gameDir} (one batch); autoFixRounds=${autoFixRounds}. Nested build-features via scriptPath. Commits nothing.`)

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
  return `You are an INDEPENDENT FIXER for the "${f.name}" feature of the Roblox game at ${dir}. The independent test gate found a REAL bug (the builder + 2 other critics missed it). Close it FALSIFY-FIRST — the same discipline that closed Collection core's cap-bypass.

THE BUG(S) the economy red-team / gate found:
${bugList || '  (see the gate report; reproduce the failing case from the spec)'}

You are at repo root. The feature's service is ${dir}/src/server/services/${f.name}/${f.serviceName}.luau; its spec-derived gate tests are ${dir}/tests/unit/${f.name}.spec.luau. READ both + ${dir}/CLAUDE.md (esp. §3 server-authoritative, §4 concurrency-safe economy: the whole read-check-write goes in ONE ctx.data:update transform on the lock-held re-read snapshot; never read-then-write a balance across a yield). Study ${dir}/tests/unit/economy_race.spec.luau for the interleaving technique.

DO, IN ORDER (falsify-first):
1. REPRODUCE: add a regression test to ${dir}/tests/unit/${f.name}.spec.luau that FAILS on the CURRENT (buggy) implementation — run the gauntlet and CONFIRM it is RED. If you cannot make it fail, the bug may be misdiagnosed — report that in stillBroken instead of forcing a fix.
2. FIX: apply the MINIMAL implementation change to ${dir}/src/server/services/${f.name}/ that restores the invariant (e.g. clamp to a cap, move an operand inside the transform, derive a value server-side). Do NOT weaken any existing gate test. Do NOT edit src/shared or init.server (report a needed contract amendment instead).
3. PROVE: re-run the gauntlet — the new regression test must now be GREEN and the full suite must pass (no regression). Report the falsifiability (what the test asserts that was RED before and GREEN after).

HARD CONSTRAINTS: do NOT run git / commit / stage. Run stylua on edited files (self-heal). VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${dir} — iterate until {"ok":true,...}. Return the StructuredOutput (set regressionTest.wasRedBeforeFix truthfully).`
}

phase('Fanout')
const results = []

for (let i = 0; i < features.length; i++) {
  const f = features[i]

  // --- build + independent gate via the proven build-features engine (nested, ONE feature) ---
  const bf = await workflow({ scriptPath: buildFeaturesPath }, { gameDir, features: [f] })
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
    // The fixer closes the bug iff it applied a real fix, added a falsify-first (was-RED) regression
    // test, and the gauntlet is green. Otherwise loop (another round) or fall through to park.
    if (fix && fix.fixed && fix.gauntletOk && fix.regressionTest && fix.regressionTest.added && fix.regressionTest.wasRedBeforeFix && (!fix.stillBroken || fix.stillBroken.length === 0)) {
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
