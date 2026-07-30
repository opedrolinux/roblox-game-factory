--!strict
-- games/collect-sim/tests/tier2/lockdiag.server.luau   [TIER-2 diagnostic — needs a PUBLISHED place]
--
-- WHY THIS EXISTS: the first real-storage run passed 6 of 7 phases but failed `write-release-reload`
-- with `SessionStore.claim: InternalError`, alongside a Studio-level
-- `MemoryStoreService: InternalError. API: HashMap.Update, Data Structure: CollectSimData_v1_lock`.
--
-- That is the SECOND MemoryStore claim in a load -> release -> reload cycle. The obvious story is
-- "teardown rewrites the lock with a 1s TTL and the immediate re-claim trips over the expiring key",
-- but that is a GUESS about engine internals, and guessing about engine internals is exactly the
-- failure mode this whole lane exists to eliminate. So this script measures instead.
--
-- It answers three questions the failure alone cannot:
--   1. Is it DETERMINISTIC or transient? (production retries Internal — a transient blip is a
--      non-event; a deterministic failure means every fast rejoin burns the retry budget.)
--   2. Is it SessionStore or MemoryStore itself? (raw HashMap calls with no SessionStore involved)
--   3. Does the 1s teardown TTL cause it? (same sequence, with and without waiting past the TTL)
--
-- Operates on dedicated diag keys, never `player_<id>`.
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Server = ServerScriptService:WaitForChild("Server", 10)
local Config = require((Shared :: any).Config) :: any
local Clock = require((Server :: any).data.Clock) :: any
local SessionStore = require((Server :: any).data.SessionStore) :: any

local findings: { any } = {}
local function note(name: string, detail: any): ()
	table.insert(findings, { name = name, detail = detail })
end

-- One attempt at a raw HashMap update. Returns ok + the error text so a failure is DATA, not a throw.
local lockMap = MemoryStoreService:GetHashMap(Config.storeName .. "_lock")
local function rawUpdate(key: string, value: any, ttl: number): (boolean, string?)
	local ok, err = pcall(function(): ()
		lockMap:UpdateAsync(key, function(_existing: any): any
			return value
		end, ttl)
	end)
	return ok, if ok then nil else tostring(err)
end

-- ── Q2: is raw MemoryStore itself unhappy with rapid same-key updates? ───────────────────────────
-- No SessionStore anywhere in this test. If this fails, the defect is not ours.
note(
	"A_raw_three_updates_same_key",
	(function(): any
		local key = "diag_a_" .. HttpService:GenerateGUID(false)
		local attempts: { any } = {}
		for i = 1, 3 do
			local ok, err = rawUpdate(key, { n = i }, 30)
			table.insert(attempts, { attempt = i, ok = ok, err = err })
		end
		return attempts
	end)()
)

-- ── Q3: the EXACT teardown -> reclaim sequence, raw ─────────────────────────────────────────────
-- claim(ttl=30) -> free(ttl=1, what teardown does) -> reclaim(ttl=30). If the 1s TTL is the culprit
-- this is where it shows, with no SessionStore in the picture to muddy it.
note(
	"B_raw_claim_free1s_reclaim_immediate",
	(function(): any
		local key = "diag_b_" .. HttpService:GenerateGUID(false)
		local claimOk, claimErr = rawUpdate(key, { lockId = "diag" }, 30)
		local freeOk, freeErr = rawUpdate(key, { lockId = "diag" }, 1)
		local reclaimOk, reclaimErr = rawUpdate(key, { lockId = "diag" }, 30)
		return {
			claim = { ok = claimOk, err = claimErr },
			free1s = { ok = freeOk, err = freeErr },
			reclaimImmediate = { ok = reclaimOk, err = reclaimErr },
		}
	end)()
)

-- Same sequence, but waiting past the 1s TTL. If B fails and C passes, the expiring key IS the cause
-- and teardown's 1s free is the thing to change.
note(
	"C_raw_claim_free1s_wait_then_reclaim",
	(function(): any
		local key = "diag_c_" .. HttpService:GenerateGUID(false)
		rawUpdate(key, { lockId = "diag" }, 30)
		rawUpdate(key, { lockId = "diag" }, 1)
		task.wait(2)
		local reclaimOk, reclaimErr = rawUpdate(key, { lockId = "diag" }, 30)
		return { reclaimAfter2s = { ok = reclaimOk, err = reclaimErr } }
	end)()
)

-- ── Q1: is the SessionStore-level failure deterministic, and does a retry clear it? ──────────────
-- Production (DataService.loadSession) RETRIES Internal. So the question that actually decides
-- whether this is a defect or a blip: does attempt 2 or 3 succeed?
note(
	"D_sessionstore_cycles_with_retry",
	(function(): any
		local clock = Clock.real(time)
		local store = SessionStore.new({ clock = clock, config = Config })
		local function default(): any
			return { schemaVersion = 1, currencies = { Stardust = 0 } }
		end

		local cycles: { any } = {}
		for cycle = 1, 3 do
			local key = "diag_d_" .. HttpService:GenerateGUID(false)
			local row: any = { cycle = cycle }

			local first = store:load(key, default)
			row.firstLoad = { ok = first.ok, code = if first.ok then nil else tostring(first.code) }
			if not first.ok then
				table.insert(cycles, row)
				continue
			end
			first.value:set({ schemaVersion = 1, currencies = { Stardust = 100 + cycle } })
			local rel = first.value:release()
			row.release = { ok = rel.ok, code = if rel.ok then nil else tostring(rel.code) }

			-- Reload with the same retry shape production uses, recording EVERY attempt so a transient
			-- first failure is distinguishable from a hard one.
			local attempts: { any } = {}
			local reloadedValue: any = nil
			for attempt = 1, 3 do
				local again = store:load(key, default)
				table.insert(attempts, {
					attempt = attempt,
					ok = again.ok,
					code = if again.ok then nil else tostring(again.code),
					message = if again.ok then nil else tostring(again.message),
				})
				if again.ok then
					reloadedValue = ((again.value.data or {}).currencies or {}).Stardust
					again.value:abandon()
					break
				end
				task.wait(1)
			end
			row.reloadAttempts = attempts
			row.reloadedStardust = reloadedValue
			row.expectedStardust = 100 + cycle
			row.dataSurvived = reloadedValue == (100 + cycle)
			table.insert(cycles, row)
		end
		return cycles
	end)()
)

-- ── SUMMARY ─────────────────────────────────────────────────────────────────────────────────────
print("── tier-2 LOCK DIAGNOSTIC ──")
for _, f in findings do
	print(`  {f.name}: {HttpService:JSONEncode(f.detail)}`)
end
print(HttpService:JSONEncode({ tier = 2, probe = "lockdiag", findings = findings }))
