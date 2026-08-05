--!strict
-- games/deep-reach/tests/unit/contract.spec.luau   [contract pass — the pass's own spec]
-- The SHARED-CONTRACT completeness spec. Every other spec tests a MODULE; this one tests the
-- CONTRACT: that the wire registry, the result codes, the schema, the client projection, the
-- analytics taxonomy, the day helper and the TEST SEAMS all carry exactly what logs/deep-reach/
-- contract.json says they carry, before nine feature builders fan out against them.
--
-- Why it exists as its own file: each of those facts lives in a different module, so no module spec
-- owns the correspondence. And every one of them fails SILENTLY — a missing Net.Actions key is a
-- nil the caller sends as an action name, a missing toView line renders nil in the HUD, a seam
-- dropped by Mocks.net makes nine feature test-suites pass against a no-op. None of that is red
-- anywhere until a human plays the game.
--
-- Pure Tier-1: no Roblox globals, no Start, no yields.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local Types = require("../../src/shared/Types")
local Config = require("../../src/shared/Config")
local Migrations = require("../../src/shared/Migrations")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local EconomyService = require("../../src/server/services/economy/EconomyService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- Set helpers: assert an EXACT key set, so a MISSING entry and an UNDECLARED EXTRA one are both
-- red. "Contains everything expected" alone would let the deleted sample action survive.
local function keysOf(map: { [string]: any }): { string }
	local out: { string } = {}
	for key in map do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

local function expectExactKeys(map: { [string]: any }, expected: { string }): ()
	local actual = keysOf(map)
	local sortedExpected = table.clone(expected)
	table.sort(sortedExpected)
	expect(table.concat(actual, ",")):toBe(table.concat(sortedExpected, ","))
end

-- ---------------------------------------------------------------------------------------------
describe("Net.Actions (the wire registry the whole fan-out addresses)", function()
	-- contract.netActions, key -> wire value. Written out literally rather than derived from the
	-- module, so a typo'd RENAME (which would still be self-consistent) is caught.
	local EXPECTED: { [string]: string } = {
		ClaimPlot = "plot.claim",
		FetchPlot = "plot.fetch",
		CollectSmelter = "salvage.collect",
		FetchSalvage = "salvage.fetch",
		BuyStructure = "structures.buy",
		FetchStructures = "structures.fetch",
		Descend = "depth.descend",
		FetchDepth = "depth.fetch",
		ClaimOffline = "offline.claim",
		FetchOffline = "offline.peek",
		ClaimDaily = "daily.claim",
		Resurface = "resurface.do",
		FetchResurface = "resurface.fetch",
		FetchLeaderboard = "leaderboard.fetch",
	}

	it("declares every contract action, with the exact wire string", function()
		for key, wire in EXPECTED do
			expect((Net.Actions :: any)[key]):toBe(wire)
		end
	end)

	it("declares NOTHING beyond the contract (the sample action is gone — A10a)", function()
		-- SampleAction wrote currencies.Stardust — the FOUNDATION game's currency — from a
		-- client-callable action. An exact-set assertion is what makes its removal permanent: a
		-- "contains" check would let it be re-added by a merge and stay green.
		expectExactKeys(Net.Actions :: any, keysOf(EXPECTED :: any))
		expect((Net.Actions :: any).Sample):toBe(nil)
	end)

	it("maps every key to a DISTINCT wire string (a collision would shadow an action)", function()
		-- Net.newRegistry errors on a duplicate name at boot, so a collision here is a boot crash,
		-- not a subtle bug — but it would be discovered by the ninth feature to merge, not now.
		local seen: { [string]: string } = {}
		for key, wire in Net.Actions :: any do
			expect(seen[wire]):toBe(nil)
			seen[wire] = key
		end
	end)

	it("namespaces every action as `<feature>.<verb>` (one owner per action)", function()
		for _, wire in Net.Actions :: any do
			expect(string.find(wire, "%.") ~= nil):toBe(true)
		end
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("Result.Codes (the refusals the features return)", function()
	it("carries the five contract codes", function()
		expect(Result.Codes.Insufficient):toBe("Insufficient")
		expect(Result.Codes.OnCooldown):toBe("OnCooldown")
		expect(Result.Codes.PrereqUnmet):toBe("PrereqUnmet")
		expect(Result.Codes.Unavailable):toBe("Unavailable")
		expect(Result.Codes.AlreadyClaimed):toBe("AlreadyClaimed")
	end)

	it("keeps each one DISTINCT from the spine code it was almost folded into", function()
		-- Each of these pairs is a success criterion that would become untestable if the two codes
		-- were the same string (contract.resultCodes records the reasoning per code):
		--   AlreadyClaimed vs Rejected  — "a second claim is refused" vs "the server is panicked".
		--   OnCooldown     vs RateLimited — a 20h game cooldown vs the Gate's anti-spam bucket.
		--   PrereqUnmet    vs Insufficient — hull too low vs cannot afford.
		--   Unavailable    vs NoData      — every plot taken vs no record for this key.
		expect(Result.Codes.AlreadyClaimed == Result.Codes.Rejected):toBe(false)
		expect(Result.Codes.OnCooldown == Result.Codes.RateLimited):toBe(false)
		expect(Result.Codes.PrereqUnmet == Result.Codes.Insufficient):toBe(false)
		expect(Result.Codes.Unavailable == Result.Codes.NoData):toBe(false)
		expect(Result.Codes.Insufficient == Result.Codes.OutOfRange):toBe(false)
	end)

	it("still carries every spine code the foundation defined (additive, never renamed)", function()
		for _, code in
			{
				"BadPayload",
				"BadType",
				"OutOfRange",
				"NotOwner",
				"RateLimited",
				"UnknownAction",
				"NoData",
				"Internal",
				"Rejected",
				"SessionLocked",
				"LockStolen",
				"SessionClosed",
			}
		do
			expect((Result.Codes :: any)[code]):toBe(code)
		end
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("The schema (v1 -> v7) and its two code sites", function()
	it("is at version 7 with a registered step for every gap below it", function()
		expect(Types.CURRENT_SCHEMA_VERSION):toBe(7)
		for version = 1, Types.CURRENT_SCHEMA_VERSION - 1 do
			expect(type((Migrations :: any).steps[version])):toBe("function")
		end
	end)

	it(
		"default() and a migrated v1 blob agree on the FIELD SET (the half-migration guard)",
		function()
			-- default() and steps[] are two SEPARATE code sites. A field seeded in one and not the
			-- other ships either fresh players or returning players without it, and only one of those
			-- two populations is usually tested. Comparing the resulting top-level key sets catches
			-- the asymmetry in whichever direction it happens.
			local fresh = Migrations.default(1000)
			local migrated = Migrations.migrate({
				schemaVersion = 1,
				currencies = { Credits = 0 },
				stats = { playtimeSeconds = 0, joinCount = 0 },
				timestamps = { firstJoinUnix = 1000, lastSeenUnix = 1000 },
				upgrades = {},
				flags = {},
				receipts = {},
			})
			expectExactKeys(migrated :: any, keysOf(fresh :: any))
		end
	)

	it("seeds THIS game's currencies and not the foundation game's", function()
		local fresh = Migrations.default(1000)
		expect(fresh.currencies.Credits):toBe(0)
		expect(fresh.currencies.Pearls):toBe(0)
		expect(fresh.currencies.Stardust):toBe(nil)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("Types.toView (the client projection is an ALLOWLIST)", function()
	it("replicates EXACTLY the contract's client-facing field set", function()
		-- Both directions matter. A missing line ships a HUD reading nil; an extra line replicates
		-- server-only state to every client on every write. An exact-set assertion is the only shape
		-- that catches both.
		local view = Types.toView(Migrations.default(1000) :: any)
		expectExactKeys(view :: any, {
			"schemaVersion",
			"currencies",
			"stats",
			"upgrades",
			"flags",
			"plot",
			"smelter",
			"daily",
			"resurfaces",
			"boostExpiresUnix",
		})
	end)

	it(
		"carries stats.lifetimeCredits — the leaderboard's ranking key — to the client",
		function()
			-- stats is copied WHOLESALE, so this has no allowlist line of its own; that is exactly why
			-- it needs an assertion of its own (AMENDMENT A4).
			local data = Migrations.default(1000)
			data.stats.lifetimeCredits = 4242
			expect(Types.toView(data :: any).stats.lifetimeCredits):toBe(4242)
		end
	)

	it("never replicates the receipts ledger (real-money idempotency is server-only)", function()
		local data = Migrations.default(1000)
		data.receipts["receipt_abc"] = true
		expect((Types.toView(data :: any) :: any).receipts):toBe(nil)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("The analytics taxonomy (declared ONCE, on the ctx.analytics seam)", function()
	it("is exactly the contract's seven events, in contract order", function()
		expect(table.concat(AnalyticsService.TAXONOMY, ",")):toBe(
			"session_start,session_end,loop_completed,currency_earned,currency_spent,progression,purchase"
		)
	end)

	it("recognises each declared event and rejects a typo'd one", function()
		local service = AnalyticsService.new(Mocks.clock(1000))
		for _, event in AnalyticsService.TAXONOMY do
			expect(service:isKnownEvent(event)):toBe(true)
		end
		expect(service:isKnownEvent("currency_earnd")):toBe(false)
	end)

	it("stamps every emit with the INJECTED server clock (never a bare os.time)", function()
		local clock = Mocks.clock(1_700_000_000)
		local service = AnalyticsService.new(clock)
		service:emit("loop_completed", { tier = 2 })
		local recorded = service:eventsOfType("loop_completed")
		expect(#recorded):toBe(1)
		expect(recorded[1].at):toBe(1_700_000_000)
		expect(recorded[1].payload.tier):toBe(2)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("The lifetime rule (contract.earnPaths, at its enforcement point)", function()
	-- The rule the whole contract pass exists to make un-forgettable: stats.lifetimeCredits moves on
	-- CREDIT EARNS ONLY — never on a Pearls mint, never on a spend, never on a reset.
	it("a Credits earn increments lifetimeCredits by the earned amount", function()
		local economy = EconomyService.new(nil)
		local data = Mocks.playerData(1000)
		data.stats.lifetimeCredits = 100
		expect(economy:earn(data, "Credits", 40, "smelt")):toBeOk()
		expect(data.currencies.Credits):toBe(40)
		expect(data.stats.lifetimeCredits):toBe(140)
	end)

	it("a Pearls earn does NOT touch lifetimeCredits (it counts Credits only)", function()
		local economy = EconomyService.new(nil)
		local data = Mocks.playerData(1000)
		data.stats.lifetimeCredits = 100
		expect(economy:earn(data, "Pearls", 3, "resurface")):toBeOk()
		expect(data.currencies.Pearls):toBe(3)
		expect(data.stats.lifetimeCredits):toBe(100)
	end)

	it("a spend NEVER touches lifetimeCredits, and a refused spend writes nothing", function()
		local economy = EconomyService.new(nil)
		local data = Mocks.playerData(1000)
		data.currencies.Credits = 50
		data.stats.lifetimeCredits = 900
		expect(economy:spend(data, "Credits", 20, "structure.drones")):toBeOk()
		expect(data.currencies.Credits):toBe(30)
		expect(data.stats.lifetimeCredits):toBe(900)
		-- A shortfall is Insufficient, and it leaves the balance byte-identical.
		expect(economy:spend(data, "Credits", 999, "depth.2")):toBeErr(Result.Codes.Insufficient)
		expect(data.currencies.Credits):toBe(30)
		expect(data.stats.lifetimeCredits):toBe(900)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe("Config.dayIndex (AMENDMENT A10c — ONE definition of a server day)", function()
	it("is floor(nowUnix / 86400)", function()
		expect((Config :: any).dayIndex(0)):toBe(0)
		expect((Config :: any).dayIndex(86399)):toBe(0)
		expect((Config :: any).dayIndex(86400)):toBe(1)
		expect((Config :: any).dayIndex(1_700_000_000)):toBe(math.floor(1_700_000_000 / 86400))
	end)

	it("is stable within a day and advances by exactly 1 across the boundary", function()
		-- The restock rich wreck rotates on THIS index, so every player on every server sees the same
		-- trench restocked on the same day. (The daily supply drop deliberately does NOT use it — it
		-- is a rolling 20-22h window off daily.lastClaimUnix; two rules, named once, in Config.)
		local base = 1_700_000_000 - (1_700_000_000 % 86400)
		expect((Config :: any).dayIndex(base)):toBe((Config :: any).dayIndex(base + 86399))
		expect((Config :: any).dayIndex(base + 86400) - (Config :: any).dayIndex(base)):toBe(1)
	end)

	it("stays SERVER-side: it is not exposed through the client-safe config subset", function()
		expect((Config :: any).clientSubset().dayIndex):toBe(nil)
	end)
end)

-- ---------------------------------------------------------------------------------------------
describe(
	"The TEST seams (a dropped seam makes nine feature suites pass against a no-op)",
	function()
		-- Mocks.net builds its ActionContext by hand, so any seam it does not name is silently dropped
		-- and every handler reading it sees nil. This registers a handler that CAPTURES the ctx it was
		-- called with, which is the only way a test can observe the pass-through.
		local function invokeCapturing(context: any): any
			local harness = Mocks.net(context)
			local captured: any = nil
			harness.register({
				name = "contract.seamprobe",
				validate = function(raw: any): any
					return Result.ok(raw)
				end,
				rate = { maxPerWindow = 100, windowSeconds = 1 },
				handler = function(ctx: any, _payload: any): any
					captured = ctx
					return Result.ok(true)
				end,
			})
			expect(harness.invoke("contract.seamprobe", Mocks.player(1), {})):toBeOk()
			return captured
		end

		it("passes every Deep Reach seam through as the SAME object it was given", function()
			local economy = { marker = "economy" }
			local plot = { marker = "plot" }
			local salvage = { marker = "salvage" }
			local depth = { marker = "depth" }
			local analytics = { marker = "analytics" }
			local ctx = invokeCapturing({
				clock = Mocks.clock(1000),
				data = nil,
				economy = economy,
				plot = plot,
				salvage = salvage,
				depth = depth,
				analytics = analytics,
				persistenceDegraded = true,
			})
			expect(ctx.economy):toBe(economy)
			expect(ctx.plot):toBe(plot)
			expect(ctx.salvage):toBe(salvage)
			expect(ctx.depth):toBe(depth)
			expect(ctx.analytics):toBe(analytics)
			expect(ctx.persistenceDegraded):toBe(true)
		end)

		it("leaves an unsupplied seam nil, so nil-safe readers are genuinely exercised", function()
			-- Every seam reader must default to the IDENTITY (a multiplier to 1, a bonus to 0). A mock
			-- that invented a stub object here would hide exactly the nil the game boots with.
			local ctx = invokeCapturing({ clock = Mocks.clock(1000), data = nil })
			expect(ctx.economy):toBe(nil)
			expect(ctx.plot):toBe(nil)
			expect(ctx.salvage):toBe(nil)
			expect(ctx.depth):toBe(nil)
		end)
	end
)

-- ---------------------------------------------------------------------------------------------
describe("Mocks.playerData (one v7 blob, not nine hand-rolled ones)", function()
	it("returns a blob at CURRENT_SCHEMA_VERSION with every v7 field seeded", function()
		local data = Mocks.playerData(1000)
		expect(data.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(data.currencies.Credits):toBe(0)
		expect(data.currencies.Pearls):toBe(0)
		expect(data.stats.lifetimeCredits):toBe(0)
		expect(data.plot.plotId):toBe("")
		expect(data.smelter.storedCredits):toBe(0)
		expect(data.smelter.lastTickUnix):toBe(0)
		expect(data.daily.streak):toBe(0)
		expect(data.daily.lastClaimUnix):toBe(0)
		expect(data.resurfaces):toBe(0)
		expect(data.boostExpiresUnix):toBe(0)
	end)

	it("seeds the timestamps from the caller's SERVER time", function()
		local data = Mocks.playerData(1_700_000_000)
		expect(data.timestamps.firstJoinUnix):toBe(1_700_000_000)
		expect(data.timestamps.lastSeenUnix):toBe(1_700_000_000)
	end)

	it("returns a FRESH table per call (a shared blob leaks state between tests)", function()
		local first = Mocks.playerData(1000)
		first.currencies.Credits = 500
		expect(Mocks.playerData(1000).currencies.Credits):toBe(0)
	end)
end)
