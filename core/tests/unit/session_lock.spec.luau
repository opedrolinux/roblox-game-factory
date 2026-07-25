--!strict
-- core/tests/unit/session_lock.spec.luau
-- B2 SessionStore POLICY tests (B2-SESSIONSTORE-DESIGN §11, Tier-1 via the MockStore D6 hooks):
-- the SessionLocked wait budget incl. the exhaustion->kick path (H1), the terminal-LockStolen
-- reaction + dead-session teardown (H2/D4), the D7 onDead seam, and the D6 hooks themselves.
-- Authored FALSIFY-FIRST: the DataService reaction tests were proven RED against the pre-B2
-- DataService (which gave SessionLocked only the ~10s Internal budget, retried the permanent
-- LockStolen, and kept serving a stolen session) before the handling was built.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- Full B2 config shape with tiny budgets so exhaustion paths are reachable fast.
local function testConfig(maxRetries: number, sessionLockedWaitSeconds: number): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = {
			maxRetries = maxRetries,
			retryBaseSeconds = 1,
			writeMinIntervalSeconds = 0,
			lockTtlSeconds = 6,
			heartbeatIntervalSeconds = 3,
			autosaveIntervalSeconds = 60,
			sessionLockedWaitSeconds = sessionLockedWaitSeconds,
			globalWritesPerMinute = 60,
		},
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

local function freshDefault(): any
	return { v = 1 }
end

describe("MockStore D6 contention hooks", function()
	it(
		"returnSessionLocked: first N loads per key are SessionLocked, then the lock grants",
		function()
			local clock = Mocks.clock(1000)
			local store = Mocks.store({
				clock = clock,
				config = testConfig(3, 10),
				returnSessionLocked = 2,
			})
			expect(store:load("k", freshDefault)):toBeErr(Result.Codes.SessionLocked)
			expect(store:load("k", freshDefault)):toBeErr(Result.Codes.SessionLocked)
			expect(store:load("k", freshDefault)):toBeOk()
		end
	)

	it(
		"stealLockAfter: after N successful saves every further save is LockStolen (permanent)",
		function()
			local clock = Mocks.clock(1000)
			local store = Mocks.store({
				clock = clock,
				config = testConfig(3, 10),
				stealLockAfter = 1,
			})
			local loaded = store:load("k", freshDefault)
			expect(loaded):toBeOk()
			local session = (loaded :: any).value
			expect(session:save()):toBeOk()
			expect(session:save()):toBeErr(Result.Codes.LockStolen)
			-- Permanent: a stolen lock never comes back.
			expect(session:save()):toBeErr(Result.Codes.LockStolen)
		end
	)

	it("stealLockAfter=0: release() surfaces the LockStolen (must-not-write path)", function()
		local clock = Mocks.clock(1000)
		local store = Mocks.store({
			clock = clock,
			config = testConfig(3, 10),
			stealLockAfter = 0,
		})
		local loaded = store:load("k", freshDefault)
		expect(loaded):toBeOk()
		local session = (loaded :: any).value
		expect(session:release()):toBeErr(Result.Codes.LockStolen)
	end)
end)

describe("DataService SessionLocked wait budget (H1 crash-rejoin availability)", function()
	it(
		"waits out a lock that clears within sessionLockedWaitSeconds (past the Internal budget)",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(2, 10) -- Internal budget would give up after ~3s
			local store = Mocks.store({
				clock = clock,
				config = config,
				-- 5 locked attempts at the 1s retry cadence clear at ~5s: inside the 10s wait budget,
				-- but PAST the maxRetries=2 Internal budget the pre-B2 loop applied.
				returnSessionLocked = 5,
			})
			local service = DataService.new(store, clock, config, Mocks.logWarn)
			local player = Mocks.player(1)
			expect(service:loadSession(player)):toBeOk()
		end
	)

	it(
		"a lock that never clears exhausts the WAIT budget then surfaces SessionLocked (kick path)",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(2, 10) -- old loop would stop after 1+2 = 3s of backoff
			local store = Mocks.store({
				clock = clock,
				config = config,
				returnSessionLocked = 1000000, -- never clears
			})
			local service = DataService.new(store, clock, config, Mocks.logWarn)
			local player = Mocks.player(1)
			local startMono = clock:mono()
			expect(service:loadSession(player)):toBeErr(Result.Codes.SessionLocked)
			-- The budget spent must be the SessionLocked-specific wait (>= 10s), not the Internal one.
			local waited = clock:mono() - startMono
			expect(waited >= 10):toBe(true)
		end
	)
end)

describe("DataService terminal LockStolen + dead session (H2/D4/D7)", function()
	it("LockStolen is terminal: the save returns immediately, burning NO retry backoff", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(4, 10) -- a retrying loop would burn 1+2+3+4 = 10s
		local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		expect(service:loadSession(player)):toBeOk()
		local startMono = clock:mono()
		expect(service:save(player)):toBeErr(Result.Codes.LockStolen)
		expect(clock:mono() - startMono):toBe(0)
	end)

	it(
		"after a steal the session is DEAD: get/update serve the dead-session code, not stale data",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(4, 10)
			local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
			local service = DataService.new(store, clock, config, Mocks.logWarn)
			local player = Mocks.player(1)
			service:loadSession(player)
			service:save(player) -- LockStolen -> the session dies
			expect(service:get(player)):toBeErr(Result.Codes.LockStolen)
			expect(service:update(player, function(d)
				return d
			end)):toBeErr(Result.Codes.LockStolen)
		end
	)

	it(
		"onDead fires with the userId + code (the D7 kick seam, injectable so Tier-1-testable)",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(4, 10)
			local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
			local deadCalls: { { userId: number, code: string } } = {}
			local service = DataService.new(
				store,
				clock,
				config,
				Mocks.logWarn,
				function(userId, code)
					table.insert(deadCalls, { userId = userId, code = code })
				end
			)
			local player = Mocks.player(7)
			service:loadSession(player)
			service:save(player)
			expect(#deadCalls):toBe(1)
			expect(deadCalls[1].userId):toBe(7)
			expect(deadCalls[1].code):toBe(Result.Codes.LockStolen)
		end
	)

	it("a fresh loadSession after death clears the dead state (rejoin recovers)", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(4, 10)
		local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		service:save(player) -- dies
		expect(service:loadSession(player)):toBeOk()
		expect(service:get(player)):toBeOk()
	end)

	it("Stop with a stolen session tears down terminally (no retry burn, session dead)", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(4, 10)
		local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		local startMono = clock:mono()
		service:Stop({})
		expect(clock:mono() - startMono):toBe(0)
		expect(service:get(player)):toBeErr(Result.Codes.LockStolen)
	end)
end)

describe("DataService.autosaveTick (D5 periodic flush, Tier-1-callable)", function()
	it("flushes every live session and reports the count", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3, 10)
		local store = Mocks.store({ clock = clock, config = config })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		service:loadSession(Mocks.player(1))
		service:loadSession(Mocks.player(2))
		local summary = service:autosaveTick()
		expect(summary.flushed):toBe(2)
		expect(summary.stolen):toBe(0)
	end)

	it(
		"advances lastSeenUnix on flush (the offline base moves while the player is online)",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(3, 10)
			local store = Mocks.store({ clock = clock, config = config })
			local service = DataService.new(store, clock, config, Mocks.logWarn)
			local player = Mocks.player(1)
			service:loadSession(player)
			clock:advance(120)
			service:autosaveTick()
			local got = service:get(player)
			expect((got :: any).value.timestamps.lastSeenUnix):toBe(1120)
		end
	)

	it(
		"a stolen session found by the tick is marked dead (onDead fires), others still flush",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(3, 10)
			local store = Mocks.store({ clock = clock, config = config, stealLockAfter = 0 })
			local deadCalls: { number } = {}
			local service = DataService.new(
				store,
				clock,
				config,
				Mocks.logWarn,
				function(userId, _code)
					table.insert(deadCalls, userId)
				end
			)
			local player = Mocks.player(1)
			service:loadSession(player)
			local summary = service:autosaveTick()
			expect(summary.flushed):toBe(0)
			expect(summary.stolen):toBe(1)
			expect(#deadCalls):toBe(1)
			expect(service:get(player)):toBeErr(Result.Codes.LockStolen)
		end
	)
end)
