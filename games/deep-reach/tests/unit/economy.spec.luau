--!strict
-- games/deep-reach/tests/unit/economy.spec.luau   [contract pass — infra]
-- The ctx.economy seam: earn/spend as PURE transforms applied inside ONE DataService:update.
--
-- These assert the DELTA, never merely that a write happened: every case reads the balance and the
-- lifetime counter back out of the blob (and, where it matters, back out of the REAL data layer
-- after a real update) and compares them to what they were before. The contract rule under test is
-- "lifetime on all earns, never on spend/reset", plus the mint guards that make a spam-duplicated
-- request unable to produce currency.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local DataService = require("../../src/server/data/DataService")
local Migrations = require("../../src/shared/Migrations")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local function blob(credits: number, pearls: number, lifetime: number): any
	local data = Migrations.default(1000)
	data.currencies.Credits = credits
	data.currencies.Pearls = pearls
	data.stats.lifetimeCredits = lifetime
	return data
end

local function testConfig(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 2, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

describe("services/economy/EconomyService — earn", function()
	it("credits the balance AND the lifetime counter by the same amount", function()
		local economy = EconomyService.new(nil)
		local data = blob(100, 0, 5000)

		local result = economy:earn(data, "Credits", 75, "smelt")
		expect(result):toBeOk()
		expect(data.currencies.Credits):toBe(175)
		expect(data.stats.lifetimeCredits):toBe(5075)
		expect((result :: any).value.balance):toBe(175)
		expect((result :: any).value.lifetimeCredits):toBe(5075)
	end)

	it("does NOT touch lifetimeCredits when the currency is Pearls", function()
		-- contract.earnPaths: "the Pearls mint on resurface — stats.lifetimeCredits counts CREDITS
		-- only, so EconomyService:earn must branch on currency".
		local economy = EconomyService.new(nil)
		local data = blob(100, 2, 5000)

		local result = economy:earn(data, "Pearls", 3, "resurface")
		expect(result):toBeOk()
		expect(data.currencies.Pearls):toBe(5)
		expect(data.currencies.Credits):toBe(100) -- untouched
		expect(data.stats.lifetimeCredits):toBe(5000) -- UNMOVED — the whole point
		expect((result :: any).value.lifetimeCredits):toBe(5000)
	end)

	it("refuses a non-positive / non-finite amount instead of clamping it", function()
		local economy = EconomyService.new(nil)
		local data = blob(100, 0, 5000)

		-- A "negative earn" would be an unguarded debit that skips the balance check entirely.
		expect(economy:earn(data, "Credits", -50, "smelt")):toBeErr(Result.Codes.OutOfRange)
		expect(economy:earn(data, "Credits", 0, "smelt")):toBeErr(Result.Codes.OutOfRange)
		expect(economy:earn(data, "Credits", math.huge, "smelt")):toBeErr(Result.Codes.OutOfRange)
		expect(economy:earn(data, "Credits", 0 / 0, "smelt")):toBeErr(Result.Codes.OutOfRange)
		expect(economy:earn(data, "Credits", "80" :: any, "smelt")):toBeErr(Result.Codes.BadType)
		-- Every refusal left the blob byte-identical.
		expect(data.currencies.Credits):toBe(100)
		expect(data.stats.lifetimeCredits):toBe(5000)
	end)

	it("a REFUSED earn is atomic-or-nothing — no branch may mutate and then refuse", function()
		-- REGRESSION (found by the salvage gate). This check used to sit BELOW the balance write, so
		-- a missing `stats` credited currencies.Credits and THEN returned Err(Internal). Every caller
		-- reads `if not granted.ok then <undo my side> end` as "nothing happened" — and salvage,
		-- correctly written against that contract, restored its smelter and committed a snapshot
		-- holding the amount in BOTH places. A mint, produced by two pieces of correct-looking code.
		--
		-- Asserted as the DELTA on the blob, not as the returned code: the code was always right.
		local clock = Mocks.clock(7000)
		local analytics = AnalyticsService.new(clock)
		local economy = EconomyService.new(analytics)

		local data = blob(100, 7, 5000)
		data.stats = nil :: any -- the one branch that used to refuse AFTER writing

		expect(economy:earn(data, "Credits", 250, "smelt")):toBeErr(Result.Codes.Internal)
		expect(data.currencies.Credits):toBe(100) -- NOT 350 — the refusal cost the player nothing
		expect(data.currencies.Pearls):toBe(7) -- and touched no neighbouring currency
		expect(#analytics:eventsOfType("currency_earned")):toBe(0)

		-- The same guarantee for the non-lifetime currency, which takes the other branch entirely:
		-- Pearls never touch stats, so a missing stats table must not stop a legitimate Pearls earn.
		local pearlsOnly = blob(0, 3, 0)
		pearlsOnly.stats = nil :: any
		expect(economy:earn(pearlsOnly, "Pearls", 2, "resurface")):toBeOk()
		expect(pearlsOnly.currencies.Pearls):toBe(5)
	end)

	it("emits currency_earned through the analytics seam, with the source", function()
		local clock = Mocks.clock(4242)
		local analytics = AnalyticsService.new(clock)
		local economy = EconomyService.new(analytics)
		local data = blob(0, 0, 0)

		economy:earn(data, "Credits", 40, "offline")
		local emitted = analytics:eventsOfType("currency_earned")
		expect(#emitted):toBe(1)
		expect(emitted[1].payload.currency):toBe("Credits")
		expect(emitted[1].payload.amount):toBe(40)
		expect(emitted[1].payload.balance):toBe(40)
		expect(emitted[1].payload.lifetimeCredits):toBe(40)
		expect(emitted[1].payload.source):toBe("offline")
		expect(emitted[1].at):toBe(4242) -- server clock
		-- A refused earn must emit NOTHING — an event that describes a change that never happened
		-- is worse than no event at all.
		economy:earn(data, "Credits", -1, "offline")
		expect(#analytics:eventsOfType("currency_earned")):toBe(1)
	end)
end)

describe("services/economy/EconomyService — spend", function()
	it("debits the balance and leaves lifetimeCredits alone", function()
		local economy = EconomyService.new(nil)
		local data = blob(500, 0, 5000)

		local result = economy:spend(data, "Credits", 200, "structure.drones")
		expect(result):toBeOk()
		expect(data.currencies.Credits):toBe(300)
		expect(data.stats.lifetimeCredits):toBe(5000) -- a spend is NEVER a decrement of lifetime
		expect((result :: any).value.balance):toBe(300)
	end)

	it("refuses an unaffordable spend with Insufficient and writes nothing", function()
		local economy = EconomyService.new(nil)
		local data = blob(199, 0, 5000)

		local result = economy:spend(data, "Credits", 200, "depth.2")
		expect(result):toBeErr(Result.Codes.Insufficient)
		expect(data.currencies.Credits):toBe(199) -- not 199, not -1: untouched
	end)

	it("spends exactly to zero, and the next identical spend is refused", function()
		-- The spam-duplicate shape: the second call must find an empty balance, not a negative one.
		local economy = EconomyService.new(nil)
		local data = blob(200, 0, 0)

		expect(economy:spend(data, "Credits", 200, "structure.hull")):toBeOk()
		expect(data.currencies.Credits):toBe(0)
		expect(economy:spend(data, "Credits", 200, "structure.hull")):toBeErr(
			Result.Codes.Insufficient
		)
		expect(data.currencies.Credits):toBe(0) -- never negative
	end)

	it("treats an absent currency key as a zero balance, not as free money", function()
		local economy = EconomyService.new(nil)
		local data = blob(0, 0, 0)
		data.currencies.Pearls = nil

		expect(economy:balanceOf(data, "Pearls")):toBe(0)
		expect(economy:spend(data, "Pearls", 1, "structure.pearlDrones")):toBeErr(
			Result.Codes.Insufficient
		)
	end)

	it("emits currency_spent with the sink, and nothing on a refusal", function()
		local analytics = AnalyticsService.new(Mocks.clock(77))
		local economy = EconomyService.new(analytics)
		local data = blob(50, 0, 0)

		economy:spend(data, "Credits", 50, "structure.conveyor")
		local emitted = analytics:eventsOfType("currency_spent")
		expect(#emitted):toBe(1)
		expect(emitted[1].payload.sink):toBe("structure.conveyor")
		expect(emitted[1].payload.balance):toBe(0)

		economy:spend(data, "Credits", 1, "structure.conveyor") -- Insufficient
		expect(#analytics:eventsOfType("currency_spent")):toBe(1)
	end)
end)

describe("services/economy/EconomyService — inside ONE data:update", function()
	it("applies earn under the session lock, and the committed blob carries both deltas", function()
		-- The shape every feature builder must copy: the guard, the mutation, the lifetime
		-- increment and the emit ALL happen inside the single lock-held transform. Driven through
		-- the REAL DataService + MockStore, so this is the production write path, not a stand-in.
		local clock = Mocks.clock(1000)
		local store = Mocks.store({ clock = clock })
		local data = DataService.new(store, clock, testConfig(), Mocks.logWarn)
		local analytics = AnalyticsService.new(clock)
		local economy = EconomyService.new(analytics)
		local player = Mocks.player(1)

		expect(data:loadSession(player)):toBeOk()

		local applied: any = nil
		local written = data:update(player, function(d: any): any
			applied = economy:earn(d, "Credits", 120, "smelt")
			return d
		end)
		expect(written):toBeOk()
		expect(applied):toBeOk()

		local after = data:get(player)
		expect(after):toBeOk()
		expect((after :: any).value.currencies.Credits):toBe(120)
		expect((after :: any).value.stats.lifetimeCredits):toBe(120)
		expect(#analytics:eventsOfType("currency_earned")):toBe(1)
	end)

	it("a refused spend inside an update commits no balance change", function()
		local clock = Mocks.clock(1000)
		local store = Mocks.store({ clock = clock })
		local data = DataService.new(store, clock, testConfig(), Mocks.logWarn)
		local economy = EconomyService.new(AnalyticsService.new(clock))
		local player = Mocks.player(2)

		expect(data:loadSession(player)):toBeOk()
		data:update(player, function(d: any): any
			d.currencies.Credits = 10
			return d
		end)

		local applied: any = nil
		data:update(player, function(d: any): any
			applied = economy:spend(d, "Credits", 999, "depth.3")
			return d
		end)
		expect(applied):toBeErr(Result.Codes.Insufficient)

		local after = data:get(player)
		expect((after :: any).value.currencies.Credits):toBe(10)
	end)

	it("five sequential earns accumulate — no lost update on the single-writer path", function()
		local clock = Mocks.clock(1000)
		local store = Mocks.store({ clock = clock })
		local data = DataService.new(store, clock, testConfig(), Mocks.logWarn)
		local economy = EconomyService.new(nil)
		local player = Mocks.player(3)

		expect(data:loadSession(player)):toBeOk()
		for _ = 1, 5 do
			data:update(player, function(d: any): any
				economy:earn(d, "Credits", 10, "smelt")
				return d
			end)
		end

		local after = data:get(player)
		expect((after :: any).value.currencies.Credits):toBe(50)
		expect((after :: any).value.stats.lifetimeCredits):toBe(50)
	end)
end)

describe("services/economy/EconomyService — seam installation", function()
	it("Start refuses to run when ctx.economy is not this service", function()
		local economy = EconomyService.new(nil)
		expect(function()
			economy:Start({ economy = nil })
		end):toThrow()
		expect(function()
			economy:Start({ economy = EconomyService.new(nil) })
		end):toThrow()
		economy:Start({ economy = economy }) -- installed: no throw
	end)
end)
