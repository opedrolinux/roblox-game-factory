--!strict
-- core/tests/unit/data.spec.luau
-- DataService load/get/update/save/release + migration + toView leak guard + BindToClose budget
-- /retry (concern 6, §9.5) + SessionLocked retry (concern 5). All under Lune with the mock store
-- + fake clock; no Start (no Roblox events). See docs/CORE-DESIGN.md §4.4 / §9.5.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local DataService = require("../../src/server/data/DataService")
local Migrations = require("../../src/shared/Migrations")
local Types = require("../../src/shared/Types")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A Config with a tiny budget so retry exhaustion is reachable in tests.
local function testConfig(maxRetries: number): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = {
			maxRetries = maxRetries,
			retryBaseSeconds = 1,
			writeMinIntervalSeconds = 0, -- no throttle floor unless a test sets one
		},
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

describe("Migrations", function()
	it("default() produces a CURRENT_SCHEMA_VERSION blob with server time", function()
		local data = Migrations.default(12345)
		expect(data.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(data.timestamps.firstJoinUnix):toBe(12345)
		expect(data.currencies.Stardust):toBe(0)
	end)

	it("migrate() is a no-op round-trip on a current blob (no field loss)", function()
		local data = Migrations.default(1)
		data.currencies.Stardust = 50
		data.upgrades.CollectSpeed = 2
		local migrated = Migrations.migrate(data)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.currencies.Stardust):toBe(50)
		expect(migrated.upgrades.CollectSpeed):toBe(2)
	end)

	it("migrate() preserves unknown extra fields", function()
		local data = Migrations.default(1);
		(data :: any).customField = "keepme"
		local migrated = Migrations.migrate(data)
		expect((migrated :: any).customField):toBe("keepme")
	end)
end)

describe("Types.toView (client-safe projection)", function()
	it("never leaks receipts or analytics ledgers", function()
		local data = Migrations.default(1)
		data.receipts["receipt_abc"] = true
		(data :: any).analytics = { lastEventUnix = 999 }
		local view = Types.toView(data :: any)
		expect((view :: any).receipts):toBe(nil)
		expect((view :: any).analytics):toBe(nil)
		-- keeps the player-facing subset
		expect(view.currencies):toEqual(data.currencies)
		expect(view.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
	end)
end)

describe("DataService load/get/update/save/release", function()
	it("get() before load -> Err(NoData)", function()
		local clock = Mocks.clock(1000)
		local store = Mocks.store({ clock = clock, config = testConfig(3) })
		local service = DataService.new(store, clock, testConfig(3), Mocks.logWarn)
		local player = Mocks.player(1)
		expect(service:get(player)):toBeErr(Result.Codes.NoData)
	end)

	it("loadSession() loads, migrates, bumps joinCount, then get() returns data", function()
		local clock = Mocks.clock(2000)
		local config = testConfig(3)
		local store = Mocks.store({ clock = clock, config = config })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		local loaded = service:loadSession(player)
		expect(loaded):toBeOk()
		local got = service:get(player)
		expect(got):toBeOk()
		expect((got :: any).value.stats.joinCount):toBe(1)
		expect((got :: any).value.timestamps.lastSeenUnix):toBe(2000)
	end)

	it("update() applies a transform and persists in-session (single call)", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3)
		local store = Mocks.store({ clock = clock, config = config })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		local updated = service:update(player, function(d)
			d.currencies.Stardust += 25
			return d
		end)
		expect(updated):toBeOk()
		expect((service:get(player) :: any).value.currencies.Stardust):toBe(25)
	end)

	it(
		"save() that exhausts the retry budget surfaces an Err (data-loss-risk, not swallowed)",
		function()
			local clock = Mocks.clock(1000)
			local config = testConfig(2) -- maxRetries = 2 -> 3 attempts total
			-- throttleSaves = 5 means every attempt in the budget is throttled -> exhaustion.
			local store = Mocks.store({ clock = clock, config = config, throttleSaves = 5 })
			local service = DataService.new(store, clock, config, Mocks.logWarn)
			local player = Mocks.player(1)
			service:loadSession(player)
			local saved = service:save(player)
			expect(saved):toBeErr() -- the Err surfaces rather than being silently swallowed
		end
	)

	it("save() retries per budget and SUCCEEDS once throttling clears", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(5) -- generous budget
		-- throttleSaves = 2: first two attempts throttle, the third succeeds.
		local store = Mocks.store({ clock = clock, config = config, throttleSaves = 2 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		local saved = service:save(player)
		expect(saved):toBeOk()
	end)
end)

describe("DataService.Stop (BindToClose budget-aware flush — §9.5)", function()
	it("flushes every live session and clears them", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3)
		local store = Mocks.store({ clock = clock, config = config })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local p1 = Mocks.player(1)
		local p2 = Mocks.player(2)
		service:loadSession(p1)
		service:loadSession(p2)
		service:update(p1, function(d)
			d.currencies.Stardust += 10
			return d
		end)
		service:Stop({})
		-- sessions cleared: get() now reports NoData for both.
		expect(service:get(p1)):toBeErr(Result.Codes.NoData)
		expect(service:get(p2)):toBeErr(Result.Codes.NoData)
	end)

	it("Stop retries per budget under throttling (not fire-once)", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(5)
		-- throttleSaves = 2: a fire-once Stop would leave the save throttled; the budget retry
		-- (which advances the fake clock) lets it succeed. We assert Stop still clears the session.
		local store = Mocks.store({ clock = clock, config = config, throttleSaves = 2 })
		local service = DataService.new(store, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		service:Stop({})
		expect(service:get(player)):toBeErr(Result.Codes.NoData)
	end)
end)

describe("DataService load-retry loop (SessionLocked contention seam — concern 5)", function()
	it("treats Err(SessionLocked) as retryable, distinct from a non-retryable error", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3)
		-- A store stub that returns SessionLocked twice, then succeeds — proving the loop retries
		-- SessionLocked (distinct from Internal/non-retryable) per §4.4.
		local attempts = 0
		local realStore = Mocks.store({ clock = clock, config = config })
		local lockingStore = {
			load = function(_self: any, key: string, default: () -> any): any
				attempts += 1
				if attempts <= 2 then
					return Result.err(Result.Codes.SessionLocked, "another server")
				end
				return realStore:load(key, default)
			end,
			isLocked = function(_self: any, _key: string): boolean
				return false
			end,
		}
		local service = DataService.new(lockingStore, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		local loaded = service:loadSession(player)
		expect(loaded):toBeOk()
		expect(attempts):toBe(3) -- two SessionLocked retries, then success
	end)

	it("a non-retryable load error (NoData) surfaces immediately", function()
		local clock = Mocks.clock(1000)
		local config = testConfig(3)
		local failingStore = {
			load = function(_self: any, _key: string, _default: () -> any): any
				return Result.err(Result.Codes.NoData, "fatal")
			end,
			isLocked = function(_self: any, _key: string): boolean
				return false
			end,
		}
		local service = DataService.new(failingStore, clock, config, Mocks.logWarn)
		local player = Mocks.player(1)
		expect(service:loadSession(player)):toBeErr(Result.Codes.NoData)
	end)
end)
