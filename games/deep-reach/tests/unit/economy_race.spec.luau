--!strict
-- core/tests/unit/economy_race.spec.luau   [INDEPENDENT TEST AGENT — authored from CORE-DESIGN §4.1/§4.2/§9.3]
-- Data-interface round-trip via the mock store + the concurrency-safe-economy guarantee, authored
-- from the DESIGN's lock-queue contract (NOT the implementation):
--   * round-trip: load (fresh default) -> set/update -> save -> re-load reflects persisted value.
--   * isLocked reflects the single-writer session lifecycle (held after load, freed after release).
--   * load failure surfaces as Err (failLoad), not a crash.
--   * THE headline: interleaved / spam-DUPLICATED updates on one key apply SEQUENTIALLY against the
--     LATEST value (per-key FIFO lock queue) -> the final balance is the EXACT sum, never a lost
--     update / double-spend. Written FALSIFIABLY: a naive read->yield->write store (no queue) lands
--     at the WRONG value, so a green test distinguishes a correct queue from a no-op (§9.3).
--   * 3-way interleave AND duplicate-of-the-same-request both converge to the exact sum.
-- Drives the REAL MockStore + DataService (production code), exercising the Store interface directly.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local MockStore = require("../../src/server/data/MockStore")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local function testConfig(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Round-robin coroutine driver: resume every suspended coroutine repeatedly until all are dead.
-- Deterministic; guards against deadlock with a bounded iteration count.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 500 then
			error("race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

describe("Store interface round-trip via MockStore", function()
	it("load returns a fresh default when the key is empty, persisted after save", function()
		local clock = Mocks.clock(1000)
		local store = MockStore.new({ clock = clock, config = testConfig() })
		local loaded = store:load("player_1", function()
			return { schemaVersion = 1, currencies = { Stardust = 0 } }
		end)
		expect(loaded):toBeOk()
		local session = (loaded :: any).value
		expect(session.data.currencies.Stardust):toBe(0)
		session:update(function(d)
			d.currencies.Stardust += 40
			return d
		end)
		local saved = session:save()
		expect(saved):toBeOk()
		-- A fresh load of the SAME key sees the persisted value (round-trip through the backing table).
		local reloaded = store:load("player_1", function()
			return { schemaVersion = 1, currencies = { Stardust = -1 } }
		end)
		expect((reloaded :: any).value.data.currencies.Stardust):toBe(40)
	end)

	it("isLocked: a key is locked after load and freed after release (single-writer)", function()
		local clock = Mocks.clock(1000)
		local store = MockStore.new({ clock = clock, config = testConfig() })
		expect(store:isLocked("player_1")):toBe(false)
		local session = (store:load("player_1", function()
			return { v = 0 }
		end) :: any).value
		expect(store:isLocked("player_1")):toBe(true)
		session:release()
		expect(store:isLocked("player_1")):toBe(false)
	end)

	it("a load failure surfaces as Err(Internal), not a crash (failLoad)", function()
		local clock = Mocks.clock(1000)
		local store = MockStore.new({ clock = clock, config = testConfig(), failLoad = true })
		expect(store:load("player_1", function()
			return {}
		end)):toBeErr(Result.Codes.Internal)
	end)

	it(
		"a preloaded (seed) key is migrated/returned as the stored value, not the default",
		function()
			local clock = Mocks.clock(1000)
			local store = MockStore.new({
				clock = clock,
				config = testConfig(),
				seed = { player_7 = { schemaVersion = 1, currencies = { Stardust = 250 } } },
			})
			local loaded = store:load("player_7", function()
				return { schemaVersion = 1, currencies = { Stardust = 0 } }
			end)
			expect((loaded :: any).value.data.currencies.Stardust):toBe(250)
		end
	)
end)

describe("Concurrency-safe economy via the per-key FIFO lock queue (falsifiable)", function()
	-- Build a yielding store + DataService with one loaded player. yieldOnUpdate forces a yield inside
	-- the critical section so a concurrent same-key update MUST park in the FIFO and re-read (§4.1).
	local function setup(): (any, any)
		local clock = Mocks.clock(1000)
		local cfg = testConfig()
		local store = Mocks.store({ clock = clock, config = cfg, yieldOnUpdate = true })
		local service = DataService.new(store, clock, cfg, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		return service, player
	end

	it("TWO interleaved +amount updates land at the EXACT sum (no lost update)", function()
		local service, player = setup()
		local cos = {
			coroutine.create(function()
				service:update(player, function(d)
					d.currencies.Stardust += 5
					return d
				end)
			end),
			coroutine.create(function()
				service:update(player, function(d)
					d.currencies.Stardust += 3
					return d
				end)
			end),
		}
		drain(cos)
		-- Correct queue => 8. A naive read->yield->write would land at 3 (verified counter-case).
		expect((service:get(player) :: any).value.currencies.Stardust):toBe(8)
	end)

	it("THREE interleaved updates converge to the exact sum (queue scales beyond 2)", function()
		local service, player = setup()
		local cos = {}
		for _, amt in { 10, 20, 30 } do
			table.insert(
				cos,
				coroutine.create(function()
					service:update(player, function(d)
						d.currencies.Stardust += amt
						return d
					end)
				end)
			)
		end
		drain(cos)
		expect((service:get(player) :: any).value.currencies.Stardust):toBe(60)
	end)

	it("SPAM-DUPLICATED identical requests each apply exactly once (anti-double-spend)", function()
		-- The spam-click class: the SAME +7 request fired 4 times interleaved. Each must apply once
		-- against the latest value -> 28, never a clobbered subset.
		local service, player = setup()
		local cos = {}
		for _ = 1, 4 do
			table.insert(
				cos,
				coroutine.create(function()
					service:update(player, function(d)
						d.currencies.Stardust += 7
						return d
					end)
				end)
			)
		end
		drain(cos)
		expect((service:get(player) :: any).value.currencies.Stardust):toBe(28)
	end)

	it("FALSIFIABILITY: a naive read->yield->write store (no queue) DOES lose an update", function()
		-- This is the counter-case that proves the queue tests above are meaningful, not trivially
		-- green: the SAME two interleaved updates against a no-queue store land at the WRONG value.
		-- (If this naive store somehow landed at 8, the queue tests would not be distinguishing.)
		local function naiveSession(start: number): any
			local backing = { Stardust = start }
			local function deepCopy(v: any): any
				if type(v) ~= "table" then
					return v
				end
				local o = {}
				for k, c in v do
					o[k] = deepCopy(c)
				end
				return o
			end
			local s = { data = backing }
			function s.update(_self: any, transform: (any) -> any): any
				local current = deepCopy(backing)
				coroutine.yield() -- no lock held: a second update reads the SAME stale snapshot
				backing = transform(current)
				s.data = backing
				return Result.ok(backing)
			end
			return s
		end
		local session = naiveSession(0)
		local cos = {
			coroutine.create(function()
				session:update(function(d)
					d.Stardust += 5
					return d
				end)
			end),
			coroutine.create(function()
				session:update(function(d)
					d.Stardust += 3
					return d
				end)
			end),
		}
		drain(cos)
		-- The naive store loses the first write: lands at 3, NOT 8. This asserts the lost-update is
		-- real, so the lock-queue's correct result of 8 above genuinely distinguishes the mechanism.
		expect(session.data.Stardust):toBe(3)
		expect(session.data.Stardust).never:toBe(8)
	end)
end)

describe("DataService.update is the canonical write path (NoData before load)", function()
	it(
		"update before a session is loaded -> Err(NoData) (no silent mint on an absent session)",
		function()
			local clock = Mocks.clock(1000)
			local cfg = testConfig()
			local store = Mocks.store({ clock = clock, config = cfg })
			local service = DataService.new(store, clock, cfg, Mocks.logWarn)
			local player = Mocks.player(1)
			expect(service:update(player, function(d)
				return d
			end)):toBeErr(Result.Codes.NoData)
		end
	)
end)
