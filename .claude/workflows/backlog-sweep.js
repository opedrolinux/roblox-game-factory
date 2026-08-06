export const meta = {
  name: 'backlog-sweep',
  description: 'Triage the gate findings the fan-out engine silently dropped, then fix the ones still open (falsify-first)',
  whenToUse:
    'After repairing a gate-aggregation defect, to recover findings that were reported but never routed to a fixer. Per feature: an independent triage agent decides open-vs-closed against the CURRENT tree, then a falsify-first fixer closes what is genuinely open.',
  phases: [
    { title: 'Triage', detail: 'one checker per feature: is each dropped finding still open TODAY?' },
    { title: 'Fix', detail: 'falsify-first fixer per feature with open findings' },
  ],
}

const a = typeof args === 'string' ? JSON.parse(args) : args || {}
const gameDir = a.gameDir
const features = a.features || []
const backlogDir = a.backlogDir
const allowGauntletRedStages = a.allowGauntletRedStages || []
const gauntletRedReason = a.gauntletRedReason || ''
const rerunBughunt = a.rerunBughunt || []

// Every agent that runs the gauntlet is told this, so nobody chases a green that is not reachable
// from inside one slice — and, worse, nobody "fixes" it by writing a read that exists only to
// satisfy the rule.
const KNOWN_RED = allowGauntletRedStages.length
  ? `

KNOWN-RED GAUNTLET STAGE(S): [${allowGauntletRedStages.join(', ')}]. The orchestrator established these are red for a reason outside any single feature's slice${gauntletRedReason ? `: ${gauntletRedReason}` : '.'} "Iterate until ok:true" does not apply to them. Your target is every OTHER stage green, with no NEW failure naming this feature. NEVER satisfy a gate rule with code written only to satisfy it — report gauntletOk honestly and name the red stage in notes.`
  : ''

// The gauntlet's rojo stage writes a FIXED filename inside the game dir (.gauntlet-build.rbxlx) and
// deletes it afterwards, so two agents running it in the same second can trip over each other. The
// failure is loud (a red rojo stage), never a false green — but it is not YOUR red.
const SHARED_WORKTREE = `

SHARED WORKTREE: sibling agents are working other features in this same checkout at the same time. Files outside your feature may change under you — that is expected, and is not a regression you caused. If the rojo stage fails naming the build artifact, re-run the gauntlet once before believing it. Do NOT revert, stash, or "clean up" another feature's work, and do NOT run git.`

const TRIAGE_SCHEMA = {
  type: 'object',
  properties: {
    feature: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'the F<n> heading from the backlog file' },
          title: { type: 'string' },
          stillOpen: { type: 'boolean', description: 'TRUE if the defect is present in the tree AS IT IS TODAY' },
          severity: { type: 'string', description: 'your OWN re-assessment (critical/high/medium/low), not the reporter\'s' },
          evidenceToday: { type: 'string', description: 'what you read in the CURRENT tree, with file:line — the code as it is now, not as the report described it' },
          closedBy: { type: 'string', description: 'if closed: which change closed it, and how you confirmed that' },
          regressionCoverage: { type: 'string', enum: ['covered', 'uncovered', 'n/a'], description: 'for a CLOSED finding: does a test pin it, so it cannot silently come back?' },
          recommendedFix: { type: 'string', description: 'if open: the minimal change that restores the invariant' },
        },
        required: ['id', 'title', 'stillOpen', 'severity', 'evidenceToday'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['feature', 'findings', 'notes'],
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

const FIXER_SCHEMA = {
  type: 'object',
  properties: {
    fixed: { type: 'boolean', description: 'TRUE if you applied a real fix to the implementation' },
    gauntletOk: { type: 'boolean' },
    luneResult: { type: 'string' },
    perFinding: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          outcome: { type: 'string', enum: ['fixed', 'already-closed', 'not-reproducible', 'out-of-scope'] },
          wasRedBeforeFix: { type: 'boolean', description: 'did you WATCH the new test fail on the un-fixed implementation?' },
          falsifiability: { type: 'string', description: 'the exact invariant the test asserts that was RED before and GREEN after' },
        },
        required: ['id', 'outcome', 'wasRedBeforeFix', 'falsifiability'],
      },
    },
    changedFiles: { type: 'array', items: { type: 'string' } },
    rootCause: { type: 'string' },
    stillBroken: {
      type: 'array',
      items: { type: 'string' },
      description: 'ONLY findings from THIS assignment that remain OPEN after your work. Empty means every one is closed or correctly dismissed. Do NOT list: a known-red gauntlet stage, work belonging to another feature, design notes, or anything you judged out of scope — those go in `notes`, which decides nothing. A non-empty value here PARKS the feature for human review.',
    },
    notes: { type: 'string' },
  },
  required: ['fixed', 'gauntletOk', 'luneResult', 'perFinding', 'changedFiles', 'stillBroken'],
}

function triagePrompt(f) {
  return `You are an INDEPENDENT TRIAGE agent for the "${f.name}" feature of the Roblox game at ${gameDir}. You are a CHECKER, not a fixer: change no file, run no git command that writes.

>>> READ ${backlogDir}/${f.name}.md IN FULL, FIRST. <<<
It lists the REAL-BUG findings this feature's independent gate critics returned and the fan-out engine silently discarded (it aggregated only the bug-hunter's findings, so coverage's and quality's were dropped). Each is headed F1, F2, ... Your job is to decide, for EACH ONE, whether it is still open in the tree AS IT IS TODAY.

METHOD, per finding:
1. Locate the exact code the evidence names. LINE NUMBERS IN THE EVIDENCE ARE STALE — they are from when the critic ran, and later commits moved them. Find the code by what it DOES, not by its line number.
2. Read it as it is now. Decide open/closed on the CURRENT behaviour, never on the report's description of it.
3. If CLOSED: name the change that closed it and how you confirmed that (\`git log -p\`/\`git log -S\` on the file are fine — read-only git is allowed). Then answer a second question: is it PINNED BY A TEST? Search ${gameDir}/tests/unit/${f.name}.spec.luau for a case that would go RED if the fix were reverted. A fix nobody tests is a fix that comes back. Report regressionCoverage: covered / uncovered.
4. If the evidence's MECHANISM is wrong but a real defect is still there, say so plainly and describe the actual mechanism — the finding is still open, for a different reason.
5. Re-assess severity yourself. The reporter's severity was assigned without seeing the rest of the game.

SOME ARE ALREADY CLOSED. Later commits fixed the plot dome leak, the salvage restore-after-refused-earn mint (fixed at the shared EconomyService seam, not in salvage), and the structures \`hull\` inertness (closed when depth shipped DepthSeam:hullRatingOf). If one of yours is in that set, CONFIRM it rather than assuming it — and check whether a test pins it.

BE CONSERVATIVE IN THE SAFE DIRECTION: if you cannot demonstrate a finding is closed, mark it stillOpen. A false "closed" ends the only process that would have caught it; a false "open" costs one fixer's time.

You are at repo root. Also read ${gameDir}/CLAUDE.md (§3 server-authoritative, §4 seam-mediated economy) and ${backlogDir.replace('/backlog', '/slices')}/${f.name}.md (the feature's contract) so you judge against the spec rather than against your taste.${SHARED_WORKTREE}

Return the StructuredOutput.`
}

function bughuntPrompt(f) {
  return `You are the ECONOMY RED-TEAM / EXPLOIT HUNTER on the independent test gate for the "${f.name}" feature of the Roblox game at ${gameDir}. You are the third critic; the coverage and quality critics already ran.

YOU ARE A RE-RUN. The original bug-hunter for this feature DIED mid-stream (an API stall), so this feature's gate verdict currently rests on two critics out of three. Nobody has red-teamed it. Everything the other two found is already recorded in ${backlogDir}/${f.name}.md — READ IT so you do not spend your effort re-deriving what is known, and go looking for what they did NOT find.

Read ${gameDir}/src/server/services/${f.name}/${f.serviceName}.luau, ${gameDir}/tests/unit/${f.name}.spec.luau, ${gameDir}/CLAUDE.md, and ${backlogDir.replace('/backlog', '/slices')}/${f.name}.md (the contract this feature owes).

Try HARD to find a REAL bug: double-spend / dupe currency; mint from nothing; lose a player's resources; bypass a range/capacity invariant; bypass a paywall or rate limit; spoof a server-authoritative value via the payload. Reason explicitly about interleavings across every ctx.data:update yield boundary — what if the update FAILS? what if another action interleaves during the yield? what does the restore/cleanup path do to the invariants? Pay attention to per-server memory keyed by userId: what clears it, and what happens to a player who leaves and rejoins the same server before that clearing runs?

For each bug: title, severity, concrete evidence (the exact interleaving or input, with file:line), and the spec line it violates. If after a genuine attempt you find NONE, say so explicitly and return realBugsFound empty — an honest empty result is worth more than a padded one.

You are a critic: change no file.${SHARED_WORKTREE}

verdict: 'pass' (no real bug) / 'fail' (>=1 real bug). Return the StructuredOutput.`
}

function fixPrompt(f, open, uncovered) {
  const openList = open
    .map((b) => `  ${b.id} [${b.severity}] ${b.title}\n     TRIAGE CONFIRMED OPEN: ${b.evidenceToday}\n     RECOMMENDED: ${b.recommendedFix || '(triage gave no recommendation — decide yourself)'}`)
    .join('\n')
  const pinList = uncovered.length
    ? `

SECOND JOB — PIN THE UNTESTED FIXES. Triage found these findings already CLOSED but NOT covered by any test, so nothing would catch them coming back:
${uncovered.map((b) => `  ${b.id} ${b.title}\n     closed by: ${b.closedBy || '(unknown)'}`).join('\n')}
For each, add a test that asserts the CORRECT behaviour, and falsify it the same way: temporarily mutate the implementation so the invariant breaks, WATCH the test go RED, restore the implementation exactly, watch it go GREEN. A test you never saw fail proves nothing. Restore every temporary mutation — verify with a final full gauntlet run.`
    : ''
  return `You are an INDEPENDENT FIXER for the "${f.name}" feature of the Roblox game at ${gameDir}. Independent triage confirmed these findings are STILL OPEN in the current tree. Close them FALSIFY-FIRST: a fix whose test was never observed RED is not known to fix anything.

OPEN FINDINGS:
${openList}

The full report for each — the original critic's evidence verbatim — is in ${backlogDir}/${f.name}.md under the matching F<n> heading. READ IT; the summary above is not the whole finding.

You are at repo root. The service is ${gameDir}/src/server/services/${f.name}/${f.serviceName}.luau; its gate tests are ${gameDir}/tests/unit/${f.name}.spec.luau. READ both, plus ${gameDir}/CLAUDE.md (§3 server-authoritative; §4 concurrency-safe economy: the whole read-check-write goes in ONE ctx.data:update transform on the lock-held snapshot, never read-then-write a balance across a yield) and ${backlogDir.replace('/backlog', '/slices')}/${f.name}.md (the contract). Study ${gameDir}/tests/unit/economy_race.spec.luau for the interleaving technique.

DO, IN ORDER, FOR EACH FINDING:
1. REPRODUCE: add a regression test to ${gameDir}/tests/unit/${f.name}.spec.luau that FAILS on the CURRENT implementation. RUN IT AND WATCH IT GO RED. If you cannot make it fail, the finding is misdiagnosed — report outcome 'not-reproducible' with what you tried, and do NOT invent a fix for it.
2. FIX: the MINIMAL implementation change that restores the invariant. Do NOT weaken an existing test. Do NOT edit src/shared or the bootstrap (report a needed contract amendment in notes instead). Do NOT edit tests/run.luau — every spec file is already registered.
3. PROVE: re-run and confirm the new test is GREEN and nothing else regressed.

MAKE THE MUTATION MATCH THE DEFECT. A regression test only proves something if the mutation you falsify it against is the ACTUAL defect, not a cruder cousin. If the code has two guards that both catch your case, neutering one proves nothing — the other still catches it and the suite stays green. Neuter exactly what the finding describes, confirm the RED names your new test, and if a "falsification" produces no RED, say so rather than reporting a proof you did not get.${pinList}

HARD CONSTRAINTS: do NOT run git-write commands, commit, or stage. Run stylua on files you edit (self-heal). VERIFY with: lune run .claude/skills/lib/gauntlet.luau ${gameDir}${KNOWN_RED}${SHARED_WORKTREE}

Return the StructuredOutput. Set wasRedBeforeFix truthfully per finding — it is the field the orchestrator trusts, and a false one is worse than a parked feature.`
}

log(`backlog-sweep: ${features.length} feature(s) — triage first, fix only what triage confirms open.`)

const results = await pipeline(
  features,
  // STAGE 1 — triage. depth additionally gets the bug-hunter it never had (its original one died
  // mid-stream), run concurrently so the missing third critic costs no extra wall-clock.
  (f) =>
    rerunBughunt.includes(f.name)
      ? parallel([
          () => agent(triagePrompt(f), { label: `triage:${f.name}`, phase: 'Triage', schema: TRIAGE_SCHEMA, effort: 'high' }),
          () => agent(bughuntPrompt(f), { label: `bughunt-rerun:${f.name}`, phase: 'Triage', schema: CRITIC_SCHEMA, effort: 'high' }),
        ]).then(([triage, bughunt]) => ({ triage, bughunt }))
      : agent(triagePrompt(f), { label: `triage:${f.name}`, phase: 'Triage', schema: TRIAGE_SCHEMA, effort: 'high' }).then((triage) => ({ triage, bughunt: null })),

  // STAGE 2 — fix, only if something is genuinely open.
  (t, f) => {
    const triage = t && t.triage
    const bughunt = t && t.bughunt
    const findings = (triage && triage.findings) || []
    const open = findings.filter((x) => x.stillOpen)
    const uncovered = findings.filter((x) => !x.stillOpen && x.regressionCoverage === 'uncovered')

    // A re-run bug-hunter's finding has been through no triage, so it enters as an open finding whose
    // reproduction step IS its verification: a fixer that cannot make it go RED reports
    // 'not-reproducible' and applies nothing. That is the same falsify-first discipline, one stage later.
    const fromBughunt = ((bughunt && bughunt.realBugsFound) || []).map((b, i) => ({
      id: `BH${i + 1}`,
      title: b.title,
      severity: b.severity || 'unknown',
      stillOpen: true,
      evidenceToday: `[from the RE-RUN bug-hunter, not yet triaged — reproduce it before you fix it] ${b.evidence || ''}`,
      recommendedFix: '',
    }))
    const allOpen = open.concat(fromBughunt)

    if (allOpen.length === 0 && uncovered.length === 0) {
      log(`backlog-sweep: ${f.name} — nothing open, nothing unpinned. No fixer needed.`)
      return { feature: f.name, triage, bughunt, open: [], uncovered: [], fix: null }
    }
    log(`backlog-sweep: ${f.name} — ${allOpen.length} open (${fromBughunt.length} from the re-run bug-hunter), ${uncovered.length} closed-but-unpinned. Dispatching a fixer.`)
    return agent(fixPrompt(f, allOpen, uncovered), {
      label: `fix:${f.name}`,
      phase: 'Fix',
      schema: FIXER_SCHEMA,
      effort: 'high',
    }).then((fix) => ({ feature: f.name, triage, bughunt, open: allOpen, uncovered, fix }))
  }
)

const clean = results.filter(Boolean)
const parked = clean.filter((r) => r.fix && r.fix.stillBroken && r.fix.stillBroken.length > 0).map((r) => r.feature)
const fixedFeatures = clean.filter((r) => r.fix && r.fix.fixed).map((r) => r.feature)
const untouched = clean.filter((r) => !r.fix).map((r) => r.feature)
log(`backlog-sweep done. fixed: [${fixedFeatures.join(', ')}] | nothing-to-do: [${untouched.join(', ')}] | PARKED: [${parked.join(', ')}]`)

return { gameDir, fixedFeatures, untouched, parked, results: clean }
