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

describe("DataService durable-write policy (§7 budget · §4.2 retry)", function()
	it("releaseSession RETRIES a throttled final write instead of losing the delta", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(5, 10)
		-- throttleSaves = 2: the first two final-write attempts are throttled. A single
		-- unretried release (the pre-fix leave path) would surface that Err and drop the
		-- session's whole delta — the most common durable write in a live game.
		local store = Mocks.store({ clock = clock, config = config, throttleSaves = 2 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		expect(service:releaseSession(service._sessions[1])):toBeOk()
	end)

	it("Stop performs ONE durable write per key (release IS the final save)", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3, 10)
		local real = Mocks.store({ clock = clock, config = config })
		local saveCalls = 0
		-- Count writes at the session boundary. NOTE MockStore's own release() delegates to
		-- session.save, so exactly ONE save call means DataService called release alone; the
		-- pre-fix Stop called saveSession AND release, giving 2 — double the shutdown burst.
		local counting = {
			load = function(_self: any, key: string, default: () -> any): any
				local loaded = real:load(key, default)
				if not loaded.ok then
					return loaded
				end
				local session = (loaded :: any).value
				local realSave = session.save
				session.save = function(s: any): any
					saveCalls += 1
					return realSave(s)
				end
				return loaded
			end,
			isLocked = function(_self: any, key: string): boolean
				return real:isLocked(key)
			end,
		}
		local service = DataService.new(counting, clock, config, Mocks.logWarn)
		service:loadSession(Mocks.player(1))
		service:Stop({})
		expect(saveCalls):toBe(1)
	end)

	it("Stop flushes EVERY session durably under throttling, not just the first few", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(5, 10)
		-- throttleSaves is PER KEY: each of the 5 players throttles once, then succeeds.
		local store = Mocks.store({ clock = clock, config = config, throttleSaves = 1 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		for index = 1, 5 do
			local player = Mocks.player(index)
			service:loadSession(player)
			service:update(player, function(d)
				d.currencies.Stardust = index * 10
				return d
			end)
		end
		service:Stop({})
		-- Load-bearing: re-load each key and confirm the value actually reached the backing
		-- store. A Stop that dropped or truncated flushes would lose these.
		for index = 1, 5 do
			local player = Mocks.player(index)
			service:loadSession(player)
			expect((service:get(player) :: any).value.currencies.Stardust):toBe(index * 10)
		end
	end)
end)

describe("DataService load budgets are independent (SessionLocked vs Internal)", function()
	it("a mixed SessionLocked -> Internal -> ok sequence still loads", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3, 20)
		local attempts = 0
		local real = Mocks.store({ clock = clock, config = config })
		-- Two contention errors then two transient I/O errors: each budget is consumed by its
		-- own error class, so neither exhausts the other and the load ultimately succeeds.
		local flaky = {
			load = function(_self: any, key: string, default: () -> any): any
				attempts += 1
				if attempts <= 2 then
					return Result.err(Result.Codes.SessionLocked, "contended")
				elseif attempts <= 4 then
					return Result.err(Result.Codes.Internal, "transient")
				end
				return real:load(key, default)
			end,
			isLocked = function(_self: any, _key: string): boolean
				return false
			end,
		}
		local service = DataService.new(flaky, clock, config, Mocks.logWarn)
		expect(service:loadSession(Mocks.player(1))):toBeOk()
		expect(attempts):toBe(5)
	end)
end)

describe("MockStore update is exception-safe (the per-key lock must never leak)", function()
	it("a throwing transform releases the lock, so later updates still run", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3, 10)
		local store = Mocks.store({ clock = clock, config = config })
		local loaded = store:load("k", function()
			return { n = 0 }
		end)
		local session = (loaded :: any).value
		-- Pre-fix this errored out of update holding the key's lock forever; every later
		-- update on that key then parked with nothing to resume it.
		expect(session:update(function(_d)
			error("boom")
		end)):toBeErr(Result.Codes.Internal)
		local after = session:update(function(d)
			d.n += 1
			return d
		end)
		expect(after):toBeOk()
		expect((after :: any).value.n):toBe(1)
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
