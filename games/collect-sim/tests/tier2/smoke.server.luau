--!strict
-- games/collect-sim/tests/tier2/smoke.server.luau   [TIER-2 — runs ONLY in a real Roblox DataModel]
--
-- L3 of the verification ladder: the in-engine smoke test. This is the rung Tier-1 is structurally
-- blind to. Lune resolves every require through the filesystem; Roblox resolves them across REAL
-- service boundaries (ReplicatedStorage vs ServerScriptService), and a require that is green under
-- Lune can THROW here. That exact class already shipped a collect-sim build that passed 313 tests
-- and did not boot (see docs/VERIFICATION-LADDER.md and the tier1-tier2 blindspot notes).
--
-- Driven by `run-in-roblox` at plugin security. It is mode-adaptive on purpose:
--   * If the real `init.server.luau` Script already ran (run mode), we OBSERVE its result — the
--     strongest possible evidence, because nothing here replicated it.
--   * If it did not (edit mode, where Scripts do not execute), we replicate the bootstrap's require
--     sequence + service order. Weaker on ORDER fidelity, but it still drives every require through
--     the real engine, which is the blindspot we are actually here to close.
-- The printed line records WHICH mode ran, so the evidence is never read as stronger than it is.
--
-- FAIL-CLOSED: the single `{"tier":2,...}` line is printed as the LAST statement. A crash before it
-- means NO line, and a missing line is a FAIL — never a silent pass (the same rule gauntlet.luau's
-- lune stage enforces). Phase names are exactly the four smoke-gate.js INGEST mode requires.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- These MUST match the constants in src/server/net/NetServer.luau (they are file-locals there, not
-- exported, so this is a hand-kept mirror — if a run reports "remotes missing" while boot-probe
-- passed, suspect drift here before suspecting the game).
local REMOTE_FUNCTION_NAME = "CoreGateway"
local REMOTE_EVENT_NAME = "CoreEvents"

-- ── evidence accumulators ─────────────────────────────────────────────────────────────────────────
local phaseOk: { [string]: boolean } = {}
local phaseDetail: { [string]: string } = {}
-- Diagnostics are NOT part of the pass/fail contract. They carry the engine facts no static review
-- can settle — the TODO(verify) assumptions SessionStore is built on.
local diagnostics: { [string]: any } = {}

local function record(name: string, ok: boolean, detail: string): ()
	phaseOk[name] = ok
	phaseDetail[name] = detail
end

-- Run a phase body under pcall so one failure cannot abort the run before the summary line.
-- The body returns (ok, detail); a throw is recorded as a failed phase carrying the error text.
local function runPhase(name: string, body: () -> (boolean, string)): boolean
	local ranOk, okOrErr, detail = pcall(body)
	if not ranOk then
		record(name, false, `THREW: {tostring(okOrErr)}`)
		return false
	end
	record(name, okOrErr == true, tostring(detail))
	return okOrErr == true
end

-- ══ PHASE: boot-probe ════════════════════════════════════════════════════════════════════════════
-- Executes the Roblox instance-require branch of every D1 shim. If any module's cross-service
-- require is wrong, the first require throws here and nothing downstream runs.
local context: any = nil
local registry: any = nil
local gate: any = nil
local net: any = nil
local bootMode = "unknown"

runPhase("boot-probe", function(): (boolean, string)
	local Server = ServerScriptService:WaitForChild("Server", 15)
	if Server == nil then
		return false,
			"ServerScriptService.Server never appeared (15s) — the place is not built from the rojo project"
	end

	-- Did the REAL bootstrap already run? Remotes exist only after NetServer:Start.
	local liveRemote = ReplicatedStorage:FindFirstChild(REMOTE_FUNCTION_NAME)
	if liveRemote ~= nil then
		bootMode = "real-bootstrap"
	else
		bootMode = "replicated-bootstrap"
	end
	diagnostics.bootMode = bootMode

	local Context = require(Server.Context) :: any
	local Bootstrap = require(Server.framework.Bootstrap) :: any

	if bootMode == "replicated-bootstrap" then
		context = Context.build()
		-- The init.server.luau order, mirrored. Earlier = depended-upon-by-later.
		local services = {
			context.net,
			context.data,
			context.analytics,
			require(Server.services.collection.CollectionService),
			require(Server.services.shop.UpgradesShopService),
			require(Server.services.daily.DailyStreakService),
			require(Server.services.islands.IslandsService),
			require(Server.services.leaderboard.LeaderboardService),
			require(Server.services.monetization.MonetizationService),
			require(Server.services.offline.OfflineService),
			require(Server.services.restock.RestockService),
			require(Server.services.rebirth.RebirthService),
		}
		Bootstrap.start(services, context)
	else
		-- Run mode: the real Script booted. We only need a handle on its context, which NetServer
		-- holds after bindContext. Re-running Bootstrap.start here would double-register and throw.
		context = nil
	end

	if context == nil then
		return true,
			"the REAL init.server.luau bootstrap ran (run mode) — requires + Start order are the engine's own, not replicated here"
	end

	net = context.net
	gate = context.gate
	registry = (net :: any)._registry
	-- persistenceDegraded is the honest read on whether DataStores are actually reachable.
	local degraded = tostring(context.persistenceDegraded)
	diagnostics.persistenceDegraded = context.persistenceDegraded == true
	return true,
		`Context.build() + the full Start order returned with no error; persistenceDegraded={degraded}`
end)

-- ══ PHASE: wire-present ══════════════════════════════════════════════════════════════════════════
-- The remotes NetServer:Start creates must exist, and EVERY Net.Actions entry must be registered —
-- a service whose Start silently failed to register shows up here, not at runtime in front of players.
runPhase("wire-present", function(): (boolean, string)
	local Server = ServerScriptService:WaitForChild("Server", 5)
	local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
	if Server == nil or Shared == nil then
		return false, "Server or Shared folder missing"
	end
	local Net = require((Shared :: any).Net) :: any

	local rf = ReplicatedStorage:FindFirstChild(REMOTE_FUNCTION_NAME)
	local re = ReplicatedStorage:FindFirstChild(REMOTE_EVENT_NAME)
	if rf == nil or re == nil then
		local haveFn, haveEv = tostring(rf ~= nil), tostring(re ~= nil)
		return false, `remotes missing after boot (RemoteFunction={haveFn} RemoteEvent={haveEv})`
	end

	local expected: { string } = {}
	for _, actionName in Net.Actions do
		table.insert(expected, actionName)
	end
	table.sort(expected)
	diagnostics.expectedActions = expected

	if registry == nil then
		-- Run mode: we have the remotes but not the private registry. The wire is provably present;
		-- per-action registration is asserted in the core-loop phase instead. Say so plainly.
		return true,
			`RemoteFunction + RemoteEvent present; action registry not reachable in {bootMode} mode (asserted via dispatch in core-loop instead)`
	end

	local missing: { string } = {}
	for _, actionName in expected do
		if registry:get(actionName) == nil then
			table.insert(missing, actionName)
		end
	end
	if #missing > 0 then
		return false,
			`actions registered on the live wire are MISSING: {table.concat(missing, ", ")}`
	end
	return true,
		`RemoteFunction + RemoteEvent present; all {#expected} Net.Actions registered on the live wire`
end)

-- ══ PHASE: core-loop ═════════════════════════════════════════════════════════════════════════════
-- Drive the real economy loop through the REAL Net.dispatch with the REAL DataService, and assert
-- persisted state actually moved. A loop that returns ok without changing the balance is not a loop.
runPhase("core-loop", function(): (boolean, string)
	if context == nil then
		return false,
			`core-loop needs the server context; unavailable in {bootMode} mode (the real Script owns it privately)`
	end
	local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
	local Net = require((Shared :: any).Net) :: any
	local Result = require((Shared :: any).Result) :: any
	local A = Net.Actions

	local player: any = { UserId = 424242, Name = "Tier2SmokeTester" }

	local loaded = context.data:loadSession(player)
	if not loaded.ok then
		return false, `loadSession failed: {tostring(loaded.code)} {tostring(loaded.message)}`
	end

	local function invoke(actionName: string, payload: any): any
		local ctx = (net :: any):actionContext(player)
		return Net.dispatch(registry, gate, ctx, actionName, payload)
	end

	local before = context.data:get(player)
	local startStardust = 0
	if before ~= nil and before.ok and before.value ~= nil then
		startStardust = (before.value.currencies or {}).Stardust or 0
	end

	-- Gather a few motes, then sell them. Sell is the earn path the whole economy hangs off.
	local gathered = 0
	for _ = 1, 3 do
		local r = invoke(A.Collect, {})
		if r ~= nil and r.ok then
			gathered += 1
		end
	end
	if gathered == 0 then
		return false, `{A.Collect} never succeeded over the real wire`
	end

	local sold = invoke(A.Sell, {})
	if sold == nil or not sold.ok then
		local code = if sold ~= nil then tostring(sold.code) else "nil result"
		return false, `{A.Sell} failed over the real wire: {code}`
	end

	local after = context.data:get(player)
	local endStardust = 0
	if after ~= nil and after.ok and after.value ~= nil then
		endStardust = (after.value.currencies or {}).Stardust or 0
	end
	if endStardust <= startStardust then
		return false,
			`Sell returned ok but the persisted balance did NOT move ({startStardust} -> {endStardust}) — the loop is inert`
	end

	-- A read-only action too, so the loop covers both a mutation and a projection.
	local fetched = invoke(A.FetchIslands, {})
	local fetchOk = fetched ~= nil and fetched.ok == true
	diagnostics.stardustDelta = endStardust - startStardust

	if not fetchOk then
		return false, `{A.FetchIslands} failed over the real wire`
	end
	local delta = endStardust - startStardust
	local envelopeIntact = tostring(Result.isOk(sold))
	return true,
		`gathered x{gathered} -> Sell -> Stardust {startStardust}->{endStardust} (delta {delta}); {A.FetchIslands} ok; Result envelope intact ({envelopeIntact})`
end)

-- ══ PHASE: assert-no-error ═══════════════════════════════════════════════════════════════════════
-- Correct REJECTION over the real wire: an unknown action and a malformed payload must come back as
-- a typed Err, not a thrown error. This is what proves the Result envelope survives the real engine.
runPhase("assert-no-error", function(): (boolean, string)
	if context == nil then
		return false, `needs the server context; unavailable in {bootMode} mode`
	end
	local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
	local Net = require((Shared :: any).Net) :: any
	local ResultMod = require((Shared :: any).Result) :: any

	local player: any = { UserId = 424242, Name = "Tier2SmokeTester" }
	local function invoke(actionName: any, payload: any): any
		local ctx = (net :: any):actionContext(player)
		return Net.dispatch(registry, gate, ctx, actionName, payload)
	end

	local unknown = invoke("definitely.not.an.action", {})
	if unknown == nil or unknown.ok ~= false or unknown.code ~= ResultMod.Codes.UnknownAction then
		local got = if unknown ~= nil then tostring(unknown.code) else "nil"
		return false, `unknown action should return Err(UnknownAction), got {got}`
	end

	-- A non-string action name must also be rejected as a typed Err, never thrown.
	local badName = invoke(12345, {})
	if badName == nil or badName.ok ~= false then
		return false, "a non-string action name did not return a typed Err"
	end

	return true,
		"unknown action + non-string action name both returned typed Errs over the real dispatch; nothing thrown"
end)

-- ══ DIAGNOSTICS: the TODO(verify) engine assumptions ══════════════════════════════════════════════
-- NOT pass/fail. These are the Roblox semantics SessionStore was built on that no static review can
-- settle. Recording them here is the whole reason this lane exists.
pcall(function(): ()
	diagnostics.jobId = tostring(game.JobId)
	diagnostics.jobIdIsEmpty = game.JobId == nil or game.JobId == ""

	-- TODO(verify): does task.cancel on an ALREADY-COMPLETED thread throw? SessionStore.teardown
	-- pcall-wraps it on the assumption that it might.
	local done = task.spawn(function(): () end)
	local cancelOk, cancelErr = pcall(task.cancel, done)
	diagnostics.taskCancelOnCompletedThreadThrows = not cancelOk
	if not cancelOk then
		diagnostics.taskCancelError = tostring(cancelErr)
	end

	-- Are the two persistence substrates actually reachable here? If not, every SessionStore claim
	-- remains unverified regardless of how green the phases above are.
	local dsOk = pcall(function(): ()
		local DataStoreService = game:GetService("DataStoreService")
		DataStoreService:GetDataStore("Tier2SmokeProbe"):GetAsync("probe")
	end)
	diagnostics.dataStoreReachable = dsOk

	local msOk = pcall(function(): ()
		local MemoryStoreService = game:GetService("MemoryStoreService")
		MemoryStoreService:GetHashMap("Tier2SmokeProbe"):GetAsync("probe")
	end)
	diagnostics.memoryStoreReachable = msOk
end)

-- ══ SUMMARY — the single evidence line, printed LAST (fail-closed) ════════════════════════════════
local EXPECTED_PHASES = { "boot-probe", "wire-present", "core-loop", "assert-no-error" }
local phases: { any } = {}
local allOk = true
for _, name in EXPECTED_PHASES do
	local ok = phaseOk[name] == true
	if not ok then
		allOk = false
	end
	table.insert(phases, { name = name, ok = ok, detail = phaseDetail[name] or "phase never ran" })
end

print("── tier-2 smoke detail ──")
for _, p in phases do
	print(`  [{if p.ok then "PASS" else "FAIL"}] {p.name}: {p.detail}`)
end
print(`── diagnostics: {HttpService:JSONEncode(diagnostics)}`)

print(HttpService:JSONEncode({ tier = 2, ok = allOk, phases = phases }))
