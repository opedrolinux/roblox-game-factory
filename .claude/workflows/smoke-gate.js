// smoke-gate.js — L3 of the verification ladder: the Tier-2 IN-ENGINE smoke gate (PARK-MODE).
//
// This is the rung that executes the dead branch the other gates are blind to: it boots the REAL place
// in a REAL DataModel and runs the core loop over the REAL Net.dispatch wire — catching a Start() that
// throws, a WaitForChild infinite-yield, the dead auto-collect ticker nothing drives, real remote
// serialization, and requires that resolve but error at require-time (VERIFICATION-LADDER.md §5).
//
// It runs entirely INSIDE THE FENCE: zero network, no rbxcloud / lune publish / curl-to-roblox, no
// account/money. The ONE human action is opening the rojo-built place in Studio with the MCP plugin
// connected. Until that bridge exposes a run tool, this gate is PARKED: it PREPARES the lane (authors
// the in-engine smoke script + a runbook) and returns `T2-blocked-on-human`. It NEVER claims `T2-green`
// without a real JSON evidence line — degrade honestly (§5.3). The honest label until then is
// `verified-local-T1 (logic only) — NOT engine-verified`.
//
// Two modes:
//   1. PREPARE (default) — author `<gameDir>/tests/tier2/smoke.server.luau` + `RUNBOOK.md`; park.
//   2. INGEST — pass `args.result` = the JSON line a human pasted back from a Studio run; parse it into
//      a T2-green / T2-red verdict. (A future version wires the Studio MCP run tool to close the loop.)
//
// args (JSON): { gameDir, result? }  — result is the pasted `{"tier":2,"ok":...,"phases":[...]}` line.

export const meta = {
  name: 'smoke-gate',
  description: 'L3 verification-ladder Tier-2 in-engine smoke gate (park-mode). Authors the in-engine smoke script (boot-probe + wire-present + core-loop traversal + assert-no-error) and a runbook for a game, then PARKS at awaiting-engine-smoke until Studio MCP is live — never claiming T2-green without a real JSON evidence line. Can ingest a pasted Studio result JSON into a T2-green/T2-red verdict. Fence-clean: no network, no publish, no account/money; the one human action is opening the place in Studio with the plugin.',
  phases: [
    { title: 'Prepare', detail: 'author the in-engine smoke script + runbook from the live bootstrap; park at awaiting-engine-smoke' },
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
const pastedResult = input && input.result

// ── INGEST MODE: a human pasted the JSON line back from a Studio run ──────────────────────────────
// The ONLY path to T2-green: a real evidence line with ok===true and every phase ok. Anything else —
// missing line, malformed, ok:false, a red phase — is T2-red. A missing line is NEVER a silent pass
// (the same fail-closed rule gauntlet.luau's lune stage uses).
if (pastedResult !== undefined && pastedResult !== null && pastedResult !== '') {
  let parsed = pastedResult
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed)
    } catch (_e) {
      parsed = null
    }
  }
  // Fail-closed: a non-array `phases` (e.g. a pasted "phases":"all green") must not throw — it must read
  // as T2-red. And T2-green requires REAL evidence for ALL FOUR named phases, not merely "some all-ok
  // phase" — a single trivial {name:"x",ok:true} must never green a tree.
  const phases = Array.isArray(parsed && parsed.phases) ? parsed.phases : []
  const EXPECTED_PHASES = ['boot-probe', 'wire-present', 'core-loop', 'assert-no-error']
  const okByName = {}
  for (const p of phases) {
    if (p && typeof p.name === 'string') okByName[p.name] = p.ok === true
  }
  const allPhasesOk = EXPECTED_PHASES.every((n) => okByName[n] === true)
  const isGreen = !!(parsed && parsed.tier === 2 && parsed.ok === true && allPhasesOk)
  const verdict = isGreen ? 'T2-green' : 'T2-red'
  log(`smoke-gate INGEST: ${gameDir} -> ${verdict} (evidence parsed: ${parsed ? 'yes' : 'NO — malformed/missing line, fail-closed to T2-red'}).`)
  return { gameDir, mode: 'ingest', verdict, evidence: parsed }
}

// ── PREPARE MODE (default, PARK): author the smoke script + runbook, then park ────────────────────
log(`smoke-gate PREPARE (park-mode): ${gameDir}. Authoring the in-engine smoke script + runbook; parking at awaiting-engine-smoke (Studio MCP not driven from here). Will NOT claim T2-green without a pasted JSON evidence line.`)

const smokeRelPath = 'tests/tier2/smoke.server.luau'
const runbookRelPath = 'tests/tier2/RUNBOOK.md'

const PREPARE_SCHEMA = {
  type: 'object',
  properties: {
    smokeScriptPath: { type: 'string', description: `the smoke script you wrote (expected: ${gameDir}/${smokeRelPath})` },
    runbookPath: { type: 'string', description: `the runbook you wrote (expected: ${gameDir}/${runbookRelPath})` },
    bootEntry: { type: 'string', description: 'the exact require + call sequence your script uses to boot the real server (e.g. require(ServerScriptService.Server.Context); Context.build(); the init.server service order)' },
    actionsTraversed: { type: 'array', items: { type: 'string' }, description: 'the Net.Actions the core-loop phase dispatches over the real wire' },
    phasesImplemented: { type: 'array', items: { type: 'string' }, description: 'which of the 4 phases (boot-probe / wire-present / core-loop / assert-no-error) the script implements' },
    failsClosed: { type: 'boolean', description: 'TRUE iff the script prints the {"tier":2,"ok":...} line ONLY at the very end after all phases, so an abort before it reads as FAIL (a missing line is never a silent pass)' },
    uncertain: { type: 'array', items: { type: 'string' }, description: 'anything you could NOT verify statically (API signatures, runtime-only behavior) that the Studio run must confirm — be honest, this script is Lune-inert and unrun until Studio' },
    notes: { type: 'string' },
  },
  required: ['smokeScriptPath', 'runbookPath', 'bootEntry', 'phasesImplemented', 'failsClosed'],
}

phase('Prepare')
const prep = await agent(`You are preparing the TIER-2 IN-ENGINE SMOKE GATE for the game at ${gameDir}. You are NOT running it (there is no engine here — it is Lune-inert and will only run when a human opens the place in Roblox Studio). Your job is to AUTHOR a correct in-engine smoke script + a runbook, reading the game's REAL bootstrap so the script matches it exactly.

You are at repo root. READ FIRST (these define the real boot + wire + loop you must drive):
1. ${gameDir}/src/server/Context.luau — how the full ServerContext is built (every service + ctx seam); note the exact require form and the build entrypoint.
2. ${gameDir}/src/server/init.server.luau — the real bootstrap: the ORDERED service list and how Start is invoked (Bootstrap.start wraps each Start and re-raises with the failing service name). This is the [Roblox-only] entrypoint — the integration suite only MIRRORS it under Lune; your script must run the REAL one.
3. ${gameDir}/src/shared/Net.luau — Net.Actions + the dispatch pipeline (rate gate -> ownership -> validate -> handler) and the real ctx the handlers need.
4. ${gameDir}/src/server/net/NetServer.luau — the remotes it creates in Start (RemoteFunction/RemoteEvent) and how the action registry is populated.
5. ${gameDir}/src/server/data/DataService.luau — loadSession (so you can drive the loop with a real persisted player) and the real Clock source.

THEN WRITE ${gameDir}/${smokeRelPath} — a server Script (NOT a ModuleScript; it runs at boot in ServerScriptService) implementing the 4 phases from docs/VERIFICATION-LADDER.md §5.1, each wrapped so a throw is caught and recorded as a failed phase (never an uncaught error that aborts before the summary):
- PHASE 0 boot-probe: pcall the REAL bootstrap (require the real Context, build it, run the real init.server service order). This single assertion executes the Roblox instance-require branch of EVERY D1 shim + Context's pure-instance requires — the cross-service-require class throws here at the first require if present. Record which service threw (Bootstrap re-raises the name).
- PHASE 1 wire-present: assert the remotes NetServer.Start created exist after boot AND the registry contains the FULL Net.Actions set (every service registered its action on the LIVE wire).
- PHASE 2 core-loop traversal: load a session for a synthetic Player, then dispatch the core loop through the REAL Net.dispatch (e.g. ${(input && input.actions) || 'collect.gather -> collect.sell -> shop.buy -> daily.claim'}) with the real ctx (real Clock, real DataService). Assert each returns Result.ok AND the persisted PlayerView actually changed (balance moved the right way).
- PHASE 3 assert-no-error / correct-rejection: zero errors during boot+loop; a malformed payload / over-rate / not-owner request returns the EXPECTED Err code over the real wire (proves the Result envelope survives real remote serialization).
- FINALLY print EXACTLY ONE line as the LAST thing the script does: \`{"tier":2,"ok":<AND of all phases>,"phases":[{"name":"boot-probe","ok":..},{"name":"wire-present","ok":..},{"name":"core-loop","ok":..},{"name":"assert-no-error","ok":..}]}\`. The four phase \`name\`s MUST be EXACTLY \`boot-probe\`, \`wire-present\`, \`core-loop\`, \`assert-no-error\` (the smoke-gate INGEST mode requires all four present + ok to record T2-green — a missing/renamed phase fails closed to T2-red). Print it ONLY at the end — a crash before it must read as FAIL (fail-closed, exactly like gauntlet.luau's lune stage). Use a require form that works in the real DataModel (instance requires rooted at game:GetService(...) / script) — this runs in Roblox, NOT Lune, so do NOT use the script==nil Lune branch here.

THEN WRITE ${gameDir}/${runbookRelPath} — a short runbook: (a) build the place: \`rojo build default.project.json --output tier2.rbxlx\` from ${gameDir}; (b) open tier2.rbxlx in Studio with the Roblox Studio MCP plugin connected; (c) the script auto-runs at server start (or paste it into the command bar) — copy the printed JSON line; (d) feed it back via \`smoke-gate\` INGEST mode: run this workflow with args.result = that JSON line to get the T2-green/T2-red verdict. State plainly: until that line exists the honest status is \`verified-local-T1 (logic only) — NOT engine-verified\`; never record T2-green without it.

HARD CONSTRAINTS: do NOT run git. Do NOT publish / call any Roblox API / network. Run stylua on the files you create (note: this is a Roblox Script, so the game's selene roblox-fenced std applies — use task.* not wait/spawn). You CANNOT run the script (no engine) — be explicit in \`uncertain\` about anything that only a real Studio run can confirm. Return the StructuredOutput.`, { label: 'smoke:prepare', phase: 'Prepare', schema: PREPARE_SCHEMA, effort: 'high' })

const verdict = 'T2-blocked-on-human'
log(`smoke-gate DONE (park-mode). verdict: ${verdict}. Prepared: ${prep ? prep.smokeScriptPath : '(prepare failed)'} + ${prep ? prep.runbookPath : ''}. Status stays verified-local-T1 (logic only, NOT engine-verified) until a human runs the smoke in Studio and feeds the JSON line back via INGEST mode. NEVER record T2-green without that evidence.`)

return {
  gameDir,
  mode: 'prepare',
  verdict, // T2-blocked-on-human — the lane is prepared, awaiting the one human action
  smokeScriptPath: prep ? prep.smokeScriptPath : `${gameDir}/${smokeRelPath}`,
  runbookPath: prep ? prep.runbookPath : `${gameDir}/${runbookRelPath}`,
  evidence: null, // no JSON line yet -> T2 is NOT verified
  prepare: prep,
}
