--!strict
-- tier-status.luau — print a game's HONEST verification-ladder status (VERIFICATION-LADDER.md §4.2).
--
--   lune run .claude/skills/lib/tier-status.luau <gameDir>
--
-- The runnable aggregator: runs the Tier-1 gauntlet for <gameDir>, maps its stages to ladder rungs
-- (T0 static / T0.5 require / T1 Lune via tier-ladder.fromGauntlet), layers in any RECORDED higher-rung
-- evidence the gauntlet cannot produce — an in-engine smoke at <gameDir>/tests/tier2/last-smoke.json
-- (T2) — then prints the handoff verdict (the highest CONTIGUOUS green rung, never a bare "ready").
-- This is the thin wrapper over tier-ladder.statusFor that turns the policy module into a command the
-- build-game handoff step (and a human) can actually run.
--
-- Engine lane: defaults to UNAVAILABLE (Studio MCP not wired). Set GATE_ENGINE_LANE=1 once the in-engine
-- smoke is automatable, so an un-run T2 becomes a handoff BLOCKER instead of an honest blocked-on-human.
--
-- Exit 0 iff the verdict is `ready` (every automatable rung green or blocked-on-human); else 1 — so a
-- script can gate on it. It NEVER claims engine-verification (T2) without the recorded smoke evidence.

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
-- Layered in HERE rather than inside tier-ladder.luau on purpose. tier-ladder is the pure T0..T3
-- policy with a 60-case corpus pinning it; introducing a fractional rung there means reopening that
-- contract. This aggregator can gate on T2.5 honestly today, and folding it into the ladder proper
-- (with its own corpus cases) is a deliberate follow-up rather than a drive-by.
local T25_EXPECTED_PHASES = {
	"world-contract",
	"spawn-safety",
	"traversal",
	"no-log-errors",
	"affordance-wiring",
	"client-load",
	"lane-limits",
}

local function readT25(): Ladder.Status?
	local path = dir .. "/tests/tier2/last-playtest.json"
	if not fs.isFile(path) then
		return nil
	end
	local decoded: any = nil
	local ok = pcall(function()
		decoded = serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(decoded) ~= "table" then
		return "red" -- present-but-unparseable is RED, never silently ignored
	end
	local okByName: { [string]: boolean } = {}
	if type(decoded.phases) == "table" then
		for _, p in decoded.phases do
			if type(p) == "table" and type(p.name) == "string" then
				okByName[p.name] = p.ok == true
			end
		end
	end
	for _, name in T25_EXPECTED_PHASES do
		if okByName[name] ~= true then
			return "red" -- a missing or renamed phase fails closed, exactly like T2
		end
	end
	if decoded.ok == true then
		return "green"
	end
	return "red"
end

local gauntlet = runGauntlet()
local laneEnv = process.env.GATE_ENGINE_LANE
local engineLaneAvailable = laneEnv == "1" or laneEnv == "true"

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
local handoff = Ladder.statusFor(gauntlet :: any, t2, nil, engineLaneAvailable)

-- T2.5 gates the handoff the same way every automatable rung does: never escalate to the human
-- while a cheaper machine rung is red or un-run. A RED playtest means the human would be walking
-- into something already known to be broken, which is precisely what this rung exists to prevent.
local ready = handoff.ready
local label = handoff.label
local blockedBy = handoff.blockedBy
if t2 == "green" then
	if t25 == "red" then
		ready = false
		blockedBy = "T2.5"
		label =
			"T2.5 RED — the automated playtest found something broken; do NOT hand this to a human yet"
	elseif t25 == nil then
		ready = false
		blockedBy = "T2.5"
		label =
			"T2.5 UNRUN — the automated playtest has not been run; run it before spending a human's attention"
	elseif ready then
		-- The label names what is STILL unverified rather than implying the game is ready. A green
		-- here means "nothing obviously broken", never "good to play": the entire client (HUD,
		-- motes, leaderboard, bootstrap, prompts) and ALL physics are structurally unreachable in
		-- the edit-mode lane and remain the human's first job on pressing Play.
		label =
			"scene-verified-T2.5 — geometry, wiring and server effects checked. The ENTIRE CLIENT (HUD, motes, leaderboard, client bootstrap, prompt reachability) and ALL physics are UNVERIFIED and are the human's first job at T3."
	end
end

local verdict = {
	gameDir = dir,
	ready = ready,
	highestGreen = handoff.highestGreen,
	lastAutomatable = handoff.lastAutomatable,
	blockedBy = blockedBy,
	label = label,
	reason = handoff.reason,
	t2Evidence = t2 or "unrun",
	t25Evidence = t25 or "unrun",
	engineLaneAvailable = engineLaneAvailable,
}
print(serde.encode("json", verdict))
stdio.ewrite(string.format("tier-status %s: highest=%s | %s\n", dir, handoff.highestGreen, label))
process.exit(if ready then 0 else 1)
