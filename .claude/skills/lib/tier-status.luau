--!strict
-- tier-status.luau — print a game's HONEST verification-ladder status (VERIFICATION-LADDER.md §4.2).
--
--   lune run .claude/skills/lib/tier-status.luau <gameDir>
--
-- The runnable aggregator: runs the Tier-1 gauntlet for <gameDir>, maps its stages to ladder rungs
-- (T0 static / T0.5 require / T1 Lune + reachability via tier-ladder.fromGauntlet), layers in any
-- RECORDED higher-rung evidence the gauntlet cannot produce, then prints the handoff verdict (the
-- highest CONTIGUOUS green rung, never a bare "ready"). The thin wrapper over tier-ladder.statusFor that
-- turns the policy module into a command the build-game handoff step (and a human) can actually run.
--
--   T2   <gameDir>/tests/tier2/last-smoke.json          in-engine boot smoke
--   T2.5 <gameDir>/tests/tier2/last-playtest.json       automated AI playtest (edit-mode)
--   T2.7 <gameDir>/tests/engine-pass/last-studio.json   agent-driven live Studio pass
--
-- EVERY ONE OF THOSE IS AN EVIDENCE-OR-NOTHING READ. An absent artifact is `unrun`; a present but
-- unparseable one is `red`. A rung is NEVER reported as anything the reader did not measure from a real
-- file on disk — which is the single property this command exists to hold. It is also why each reader
-- re-derives the verdict from the artifact's PHASES rather than trusting its top-level `ok`.
--
-- Lanes (per rung, because one boolean cannot describe three): GATE_ENGINE_LANE=1 declares the
-- run-in-roblox lane, which carries BOTH T2 and T2.5; GATE_STUDIO_LANE=1 declares a live Studio session
-- for T2.7. An undeclared lane is unavailable, so its rung is honestly blocked-on-human rather than a
-- blocker on a machine that could not run it anyway.
--
-- Exit 0 iff the verdict is `ready` (every automatable rung green or blocked-on-human); else 1 — so a
-- script can gate on it. It NEVER claims a rung without that rung's recorded evidence.

local process = require("@lune/process")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

local Ladder = require("./tier-ladder")

-- Lune passes everything after the script path as args (incl. a literal "--"); take the first real one.
local function pickGameDir(): string?
	for _, arg in process.args do
		if arg ~= "--" and arg ~= "" then
			return arg
		end
	end
	return nil
end

local gameDir = pickGameDir()
if gameDir == nil then
	stdio.ewrite("usage: lune run .claude/skills/lib/tier-status.luau <gameDir>\n")
	process.exit(1)
end
local dir = gameDir :: string
if not fs.isDir(dir) then
	stdio.ewrite(string.format("tier-status: %q is not a directory\n", dir))
	process.exit(1)
end

-- Run the gauntlet as a subprocess and return its parsed { ok, stages } line, or nil if it could not be
-- produced (fail-closed: a gauntlet that won't run is NOT a green tree).
local function runGauntlet(): { ok: boolean, stages: { { name: string, ok: boolean } } }?
	local ok, result = pcall(function()
		return process.exec("lune", { "run", ".claude/skills/lib/gauntlet.luau", dir })
	end)
	if not ok then
		stdio.ewrite("tier-status: could not run gauntlet: " .. tostring(result) .. "\n")
		return nil
	end
	local out = ((result :: any).stdout or "") .. ""
	local found: any = nil
	for line in string.gmatch(out, "[^\r\n]+") do
		local decoded
		local decodeOk, err = pcall(function()
			decoded = serde.decode("json", line)
		end)
		if decodeOk and type(decoded) == "table" and type((decoded :: any).stages) == "table" then
			found = decoded
		end
		local _ = err
	end
	return found
end

-- The four phases the in-engine smoke MUST cover (must match smoke-gate.js EXPECTED_PHASES). T2 is green
-- ONLY with real evidence for all four — fail-closed, exactly like smoke-gate ingest.
local EXPECTED_PHASES = { "boot-probe", "wire-present", "core-loop", "assert-no-error" }

-- Read the recorded smoke result, if any, and map it to a T2 Status. Absent file -> nil (-> "unrun").
local function readT2(): Ladder.Status?
	local path = dir .. "/tests/tier2/last-smoke.json"
	if not fs.isFile(path) then
		return nil
	end
	local decoded: any = nil
	local ok = pcall(function()
		decoded = serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(decoded) ~= "table" then
		return "red" -- a present-but-unparseable evidence file is RED, never silently ignored
	end
	local okByName: { [string]: boolean } = {}
	if type(decoded.phases) == "table" then
		for _, p in decoded.phases do
			if type(p) == "table" and type(p.name) == "string" then
				okByName[p.name] = p.ok == true
			end
		end
	end
	local allPhasesOk = true
	for _, name in EXPECTED_PHASES do
		if okByName[name] ~= true then
			allPhasesOk = false
		end
	end
	if decoded.tier == 2 and decoded.ok == true and allPhasesOk then
		return "green"
	end
	return "red"
end

-- T2.5 — the automated AI playtest (games/<dir>/tests/tier2/playtest.server.luau). Sits between the
-- in-engine smoke (does it BOOT and does the loop RUN) and the human playtest (is it any GOOD): it
-- clears everything that is merely BROKEN so the human never spends attention on it.
--
-- The seven phase names below are the roster the T2.5 harness template ships, and they are pinned here
-- rather than read from the game's phases.json ON PURPOSE FOR NOW: this reader is the fail-closed side
-- of the two-sided roster check, so it must be a SEPARATE authority from the artifact it is judging.
-- (Making it manifest-driven — so a game with no 3D world can honestly drop world-contract /
-- spawn-safety / traversal instead of reading T2.5-red — is the remaining piece of HANDOFF-2.)
local T25_EXPECTED_PHASES = {
	"world-contract",
	"spawn-safety",
	"traversal",
	"no-log-errors",
	"affordance-wiring",
	"client-load",
	"lane-limits",
}

-- Decode an evidence artifact. Three outcomes, and the middle one is the whole point: `nil` = no
-- artifact (the rung is un-run), `false` = an artifact exists but could not be read (RED — a check that
-- could not run is a FAILURE, never a skip), otherwise the decoded table.
local function readEvidence(path: string): (any | boolean)?
	if not fs.isFile(path) then
		return nil
	end
	local decoded: any = nil
	local ok = pcall(function()
		decoded = serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(decoded) ~= "table" then
		return false
	end
	return decoded
end

local function phaseOkByName(decoded: any): { [string]: boolean }
	local okByName: { [string]: boolean } = {}
	if type(decoded.phases) == "table" then
		for _, p in decoded.phases do
			if type(p) == "table" and type(p.name) == "string" then
				okByName[p.name] = p.ok == true
			end
		end
	end
	return okByName
end

-- The `ok` / `verdict` agreement check, shared by T2.5 and T2.7 (verification-evidence/1). A harness
-- that reports `verdict: "parked"` alongside `ok: true` is MALFORMED, and malformed is red — it is
-- exactly how a run that found something broken gets laundered into a pass. `parked` itself is a
-- deliberate non-green: "I found something broken" and "everything is fine" must never both be true of
-- the same run.
local function verdictAgrees(decoded: any): boolean
	if decoded.verdict == nil then
		return true -- pre-schema artifact (T2's last-smoke.json shape): judged on phases + ok alone
	end
	return decoded.ok == (decoded.verdict == "green")
end

local function readT25(): Ladder.Status?
	local decoded = readEvidence(dir .. "/tests/tier2/last-playtest.json")
	if decoded == nil then
		return nil
	end
	if decoded == false then
		return "red" -- present-but-unparseable is RED, never silently ignored
	end
	local d = decoded :: any
	if not verdictAgrees(d) then
		return "red"
	end
	local okByName = phaseOkByName(d)
	for _, name in T25_EXPECTED_PHASES do
		if okByName[name] ~= true then
			return "red" -- a missing or renamed phase fails closed, exactly like T2
		end
	end
	if d.ok == true then
		return "green"
	end
	return "red"
end

-- T2.7 — the agent-driven LIVE Studio pass (.claude/skills/engine-pass). The only rung that can see the
-- client at all: Lune cannot even require a controller (LocalPlayer at module scope), the T2 smoke drives
-- only the server, and T2.5 runs edit-mode with no LocalPlayer — so every automated rung below this one
-- being green says NOTHING about whether a controller is wired correctly.
local T27_EXPECTED_PHASES = {
	"sync-provenance",
	"boot-console",
	"server-authority",
	"client-wire",
	"world-present",
	"screens",
}

local function readT27(): Ladder.Status?
	local decoded = readEvidence(dir .. "/tests/engine-pass/last-studio.json")
	if decoded == nil then
		return nil
	end
	if decoded == false then
		return "red"
	end
	local d = decoded :: any
	if not verdictAgrees(d) or d.tier ~= 2.7 or d.ok ~= true then
		return "red"
	end
	local okByName = phaseOkByName(d)
	for _, name in T27_EXPECTED_PHASES do
		if okByName[name] ~= true then
			return "red"
		end
	end
	-- PROVENANCE. The factory's single best in-engine proof (the JoinRetry RED->GREEN) had to ship with
	-- the caveat that two scripts were hand-injected, so "the place is now a hybrid, current on those two
	-- and stale everywhere else". A pass against a place that is not the tree on disk verifies a
	-- different program than the one being shipped.
	if type(d.provenance) ~= "table" or d.provenance.mismatchCount ~= 0 then
		return "red"
	end
	-- SCREENSHOTS ARE NOT DECORATION. Three of the five defects the live session found were invisible in
	-- every log and only obvious in a picture. An image with no written assertion is not evidence, it is
	-- a way to FEEL verified — and `cannot-tell` is a first-class verdict that is NOT a pass.
	local assertedPass = 0
	if type(d.screens) == "table" then
		for _, s in d.screens do
			if type(s) == "table" then
				if type(s.assertion) ~= "string" or s.assertion == "" then
					return "red"
				end
				if s.verdict == "pass" then
					assertedPass += 1
				elseif s.verdict == "fail" then
					return "red" -- a picture that shows the assertion FAILING is a red, wherever it is filed
				elseif s.verdict ~= "cannot-tell" then
					return "red" -- an unrecognised verdict is not a pass
				end
			end
		end
	end
	if assertedPass == 0 then
		return "red"
	end
	return "green"
end

local gauntlet = runGauntlet()
local laneEnv = process.env.GATE_ENGINE_LANE
local engineLaneAvailable = laneEnv == "1" or laneEnv == "true"
local studioEnv = process.env.GATE_STUDIO_LANE
local studioLaneAvailable = studioEnv == "1" or studioEnv == "true"
-- Per-rung lanes. T2 and T2.5 ride the SAME run-in-roblox lane, so one flag declares both; T2.7 needs a
-- live Studio session with the MCP bridge, which is a different thing entirely and gets its own flag.
local lanes = {
	["T2"] = engineLaneAvailable,
	["T2.5"] = engineLaneAvailable,
	["T2.7"] = studioLaneAvailable,
}

if gauntlet == nil then
	-- No gauntlet line at all: the lowest rung is unproven. Emit an honest in-progress verdict.
	local verdict = {
		gameDir = dir,
		ready = false,
		highestGreen = "none",
		blockedBy = "T0",
		label = "in-progress (T0 unrun), NOT ready — the gauntlet produced no result",
		engineLaneAvailable = engineLaneAvailable,
	}
	print(serde.encode("json", verdict))
	stdio.ewrite("tier-status: " .. verdict.label .. "\n")
	process.exit(1)
end

local t2 = readT2()
local t25 = readT25()
local t27 = readT27()

-- T2.5 and T2.7 are now REAL RUNGS in tier-ladder (HANDOFF-2), so the verdict comes out of the one
-- policy module instead of being patched afterwards here. The bolt-on this replaces had a real bug:
-- it wrapped its T2.5 gating in `if t2 == "green"`, so with the engine lane down and T2 never run, a
-- RECORDED RED PLAYTEST WAS SILENTLY IGNORED and handoff still returned ready-for-human (HANDOFF-4).
-- The ladder now sweeps recorded reds across every engine rung BEFORE it walks the chain.
local handoff = Ladder.statusFor(gauntlet :: any, t2, nil, lanes, {
	["T2.5"] = t25 or "unrun",
	["T2.7"] = t27 or "unrun",
})

local verdict = {
	gameDir = dir,
	ready = handoff.ready,
	highestGreen = handoff.highestGreen,
	lastAutomatable = handoff.lastAutomatable,
	blockedBy = handoff.blockedBy,
	label = handoff.label,
	reason = handoff.reason,
	-- Every rung's evidence is reported SEPARATELY from the verdict, and "unrun" is spelled out rather
	-- than omitted: a reader must be able to see WHICH artifact was missing, not just that the ladder
	-- stopped somewhere.
	t2Evidence = t2 or "unrun",
	t25Evidence = t25 or "unrun",
	t27Evidence = t27 or "unrun",
	engineLaneAvailable = engineLaneAvailable,
	studioLaneAvailable = studioLaneAvailable,
}
print(serde.encode("json", verdict))
stdio.ewrite(
	string.format("tier-status %s: highest=%s | %s\n", dir, handoff.highestGreen, handoff.label)
)
process.exit(if handoff.ready then 0 else 1)
