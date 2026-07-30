--!strict
-- games/collect-sim/tests/tier2/persistence.server.luau   [TIER-2 — needs a PUBLISHED place]
--
-- The B2 verification. `smoke.server.luau` proves the game BOOTS in a real engine; it deliberately
-- cannot prove anything about persistence, because a place built by `rojo build` has PlaceId 0 and
-- Roblox refuses DataStore access outright. This script is the other half: it drives the REAL
-- SessionStore against the REAL DataStoreService + MemoryStoreService.
--
-- It does NOT boot the game. It constructs the store directly, so it can run alongside the normal
-- bootstrap without double-registering anything — drop it in ServerScriptService and press Play.
--
-- WHY IT MATTERS: every claim B2 makes — the lock protocol, the write stamp, crash-rejoin, the
-- nil-abort transform semantics — was reasoned about across three adversarial review rounds and
-- never once observed. The `TODO(verify)` markers in SessionStore.luau are the honest record of
-- that. This script converts assumptions into facts, and is the ONLY thing that can.
--
-- SAFETY: operates on a dedicated probe key (never `player_<id>`), and deletes it when finished.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PROBE_KEY = "tier2_probe_do_not_use_for_players"

local results: { any } = {}
local function record(name: string, ok: boolean, detail: any): ()
	table.insert(results, { name = name, ok = ok, detail = detail })
end

local function runPhase(name: string, body: () -> (boolean, any)): ()
	local ranOk, okOrErr, detail = pcall(body)
	if not ranOk then
		record(name, false, `THREW: {tostring(okOrErr)}`)
		return
	end
	record(name, okOrErr == true, detail)
end

-- ══ PHASE 1: are the substrates actually reachable? ══════════════════════════════════════════════
-- Everything below is meaningless if this fails, so it runs first and the rest short-circuits.
local substratesLive = false
runPhase("substrates-reachable", function(): (boolean, any)
	local dsOk, dsErr = pcall(function(): ()
		DataStoreService:GetDataStore("Tier2Probe"):GetAsync("probe")
	end)
	local msOk, msErr = pcall(function(): ()
		MemoryStoreService:GetHashMap("Tier2Probe"):GetAsync("probe")
	end)
	substratesLive = dsOk and msOk
	return substratesLive,
		{
			placeId = game.PlaceId,
			jobId = tostring(game.JobId),
			dataStore = if dsOk then "reachable" else tostring(dsErr),
			memoryStore = if msOk then "reachable" else tostring(msErr),
		}
end)

-- ══ PHASE 2..N: the SessionStore contract, against real storage ═══════════════════════════════════
if substratesLive then
	local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local Server = ServerScriptService:WaitForChild("Server", 10)
	local Config = require((Shared :: any).Config) :: any
	local Clock = require((Server :: any).data.Clock) :: any
	local SessionStore = require((Server :: any).data.SessionStore) :: any

	local clock = Clock.real(time)
	local store = SessionStore.new({ clock = clock, config = Config })

	local function freshDefault(): any
		return { schemaVersion = 1, currencies = { Stardust = 0 }, probe = true }
	end

	-- The headline claim: a value written and released comes back on the next load. This is
	-- literally "do the player's coins survive a rejoin".
	runPhase("write-release-reload", function(): (boolean, any)
		local first = store:load(PROBE_KEY, freshDefault)
		if not first.ok then
			return false, `initial load failed: {tostring(first.code)} {tostring(first.message)}`
		end
		local session = first.value
		session:set({ schemaVersion = 1, currencies = { Stardust = 4321 }, probe = true })
		local released = session:release()
		if not released.ok then
			return false, `release failed: {tostring(released.code)} {tostring(released.message)}`
		end

		local second = store:load(PROBE_KEY, freshDefault)
		if not second.ok then
			return false, `reload failed: {tostring(second.code)} {tostring(second.message)}`
		end
		local got = ((second.value.data or {}).currencies or {}).Stardust
		local survived = got == 4321
		second.value:abandon()
		return survived, `wrote 4321, reloaded {tostring(got)}`
	end)

	-- The lock must actually be held while a session is live, and freed once it is not. This is the
	-- mechanism that stops two servers writing the same player.
	runPhase("lock-held-then-freed", function(): (boolean, any)
		local s = store:load(PROBE_KEY, freshDefault)
		if not s.ok then
			return false, `load failed: {tostring(s.code)}`
		end
		local heldWhileLive = store:isLocked(PROBE_KEY)
		s.value:abandon()
		local heldAfterAbandon = store:isLocked(PROBE_KEY)
		local live, freed = tostring(heldWhileLive), tostring(heldAfterAbandon)
		return heldWhileLive and not heldAfterAbandon,
			`isLocked while live={live}, after abandon={freed}`
	end)

	-- ══ The TODO(verify) markers, answered by observation ════════════════════════════════════════
	-- SessionStore.luau:211 — the crash-rejoin fix depends on a nil return ABORTING the MemoryStore
	-- write rather than writing nil or raising. If this is wrong, the fix silently inverts.
	runPhase("memorystore-nil-abort", function(): (boolean, any)
		local map = MemoryStoreService:GetHashMap("Tier2Probe")
		map:SetAsync("aborttest", "original", 300)
		local ok, err = pcall(function(): ()
			map:UpdateAsync("aborttest", function(_old: any): any
				return nil
			end, 300)
		end)
		local after = map:GetAsync("aborttest")
		pcall(function(): ()
			map:RemoveAsync("aborttest")
		end)
		-- The assumption holds iff the value is untouched (aborted), whether or not it also raised.
		return after == "original",
			{
				assumption = "returning nil aborts the write, leaving the old value",
				raised = not ok,
				raisedError = if ok then nil else tostring(err),
				valueAfter = tostring(after),
				holds = after == "original",
			}
	end)

	-- SessionStore.luau:328 — same question for DataStore, which is what actually protects a
	-- displaced server from overwriting the record it no longer owns.
	runPhase("datastore-nil-abort", function(): (boolean, any)
		local ds = DataStoreService:GetDataStore("Tier2Probe")
		ds:SetAsync("aborttest", "original")
		local ok, err = pcall(function(): ()
			ds:UpdateAsync("aborttest", function(_old: any): any
				return nil
			end)
		end)
		local after = ds:GetAsync("aborttest")
		pcall(function(): ()
			ds:RemoveAsync("aborttest")
		end)
		return after == "original",
			{
				assumption = "returning nil aborts the write, leaving the old value",
				raised = not ok,
				raisedError = if ok then nil else tostring(err),
				valueAfter = tostring(after),
				holds = after == "original",
			}
	end)

	-- SessionStore.luau:394 — teardown frees the lock by rewriting it with a 1-second TTL. If 1 is
	-- below the accepted minimum, teardown throws and the lock leaks for its full 30s instead.
	runPhase("memorystore-expiration-1-accepted", function(): (boolean, any)
		local map = MemoryStoreService:GetHashMap("Tier2Probe")
		local ok, err = pcall(function(): ()
			map:SetAsync("ttltest", "x", 1)
		end)
		pcall(function(): ()
			map:RemoveAsync("ttltest")
		end)
		return ok, if ok then "expiration=1 accepted" else tostring(err)
	end)

	-- Clean up the probe key so it never shadows a real record.
	runPhase("cleanup", function(): (boolean, any)
		local ok, err = pcall(function(): ()
			DataStoreService:GetDataStore(Config.storeName):RemoveAsync(PROBE_KEY)
		end)
		return ok, if ok then `removed {PROBE_KEY}` else tostring(err)
	end)
end

-- ══ SUMMARY — single line, printed last (fail-closed) ═════════════════════════════════════════════
local allOk = true
for _, r in results do
	if not r.ok then
		allOk = false
	end
end

print("── tier-2 PERSISTENCE detail ──")
for _, r in results do
	print(`  [{if r.ok then "PASS" else "FAIL"}] {r.name}: {HttpService:JSONEncode(r.detail)}`)
end
print(HttpService:JSONEncode({ tier = 2, probe = "persistence", ok = allOk, phases = results }))
