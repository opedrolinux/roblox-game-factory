--!strict
-- games/collect-sim/tests/unit/upgrade_effects.spec.luau   [EFFECT GATE — the one the old suite lacked]
--
-- WHY THIS FILE EXISTS. 361 Tier-1 tests were green on a build where all four shop upgrades did
-- NOTHING. A human playtested it and hit that within a minute. Every existing test asserted the
-- WRITE — "the level was persisted", "the balance fell by the cost" — and not one asserted the
-- READ, so `d.upgrades[id]` was stored by the shop and consumed by no gameplay code anywhere.
--
-- The root pattern, stated so it can be tested against: THE RULE THAT GOVERNS PLAY WAS A HARDCODED
-- CONSTANT SITTING NEXT TO THE PERSISTED VALUE THAT WAS SUPPOSED TO CONTROL IT. `CAPACITY = 50`
-- sat beside the backpack level; `ABSORB_RADIUS = 6` beside the magnet level.
--
-- So these tests are deliberately shaped differently from the rest of the suite: each one performs
-- a purchase and then asserts a change in something the PLAYER experiences, observed through the
-- same public surface the client sees (the Collect reply, and the ctx.upgrades seam that governs
-- server behavior). A test that only re-read `d.upgrades` would pass on the broken build — that is
-- exactly what the old suite did.
--
-- Authored from the spec's promise (specs/collect-sim.md:16,23,41: "Spend Stardust on upgrades ->
-- collect faster / hold more / magnet wider / move faster"), not from the implementation.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local UpgradesShopService = require("../../src/server/services/shop/UpgradesShopService")
local CollectionService = require("../../src/server/services/collection/CollectionService")
local DataService = require("../../src/server/data/DataService")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local BUY = Net.Actions.BuyUpgrade
local COLLECT = Net.Actions.Collect

-- Every upgrade the spec promises. Iterated as a SET so a fifth upgrade added later is covered
-- automatically, and so no single id can be special-cased into passing (the old in-engine probe
-- hardcoded { upgradeId = "backpack" } and never dispatched the other three at all).
local PROMISED_UPGRADES = { "collect-speed", "backpack", "magnet", "walk-speed" }

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Wire the shop and collection onto ONE shared context, exactly as the runtime does: both services
-- publish onto / read from the same table, and the harness projects that table's seams into every
-- ActionContext. This composition is the thing that was never tested.
local function setup(startingStardust: number?): (any, any, any, any, any)
	local clock = Mocks.clock(1000)
	local cfg = config()
	local store = Mocks.store({ clock = clock, config = cfg })
	local data = DataService.new(store, clock, cfg, Mocks.logWarn)
	local player = Mocks.player(1)
	data:loadSession(player)

	local shared: any = { clock = clock, data = data, gate = false }
	local harness = Mocks.net(shared)
	shared.net = harness.registry

	UpgradesShopService:Start(shared) -- publishes shared.upgrades
	CollectionService:Start(shared) -- consumes it through ctx.upgrades

	if startingStardust ~= nil then
		local updated = data:update(player, function(d: any): any
			d.currencies.Stardust = startingStardust
			return d
		end)
		expect(updated):toBeOk()
	end
	return harness, data, player, shared, clock
end

-- The capacity the SERVER enforces and REPORTS, read through the public Collect reply — the same
-- value the HUD renders as the denominator. Deliberately not read off the seam: the reported number
-- and the enforced number drifting apart is itself a defect (the HUD said 50 while the shop sold
-- levels nothing enforced), so the assertions below compare this against enforcement separately.
local function reportedCapacity(harness: any, player: any): number
	local res = harness.invoke(COLLECT, player, {})
	expect(res):toBeOk()
	return (res :: any).value.capacity
end

-- Collect is CLOCK-GATED, so filling a backpack means letting server time pass — a bare loop of
-- invokes grants exactly one mote however long it runs. Returns how many motes were accepted
-- before the backpack refused.
local function fillUntilRefused(harness: any, clock: any, player: any): number
	local accepted = 0
	local guard = 0
	while guard < 2000 do
		guard += 1
		clock:advance(0.06 * 10)
		local res = harness.invoke(COLLECT, player, {})
		if not res.ok then
			return accepted -- OutOfRange: the backpack refused, so enforcement stopped here
		end
		accepted += (res :: any).value.granted
	end
	error("fillUntilRefused did not converge")
end

local function buy(harness: any, player: any, upgradeId: string): any
	return harness.invoke(BUY, player, { upgradeId = upgradeId })
end

describe("upgrade effects — a bought level must be READ by the code governing play", function()
	it("backpack: capacity reported to the client RISES after a purchase", function()
		local harness, _data, player = setup(100000)
		local before = reportedCapacity(harness, player)
		expect(buy(harness, player, "backpack")):toBeOk()
		local after = reportedCapacity(harness, player)
		-- THE assertion the old suite was missing. On the pre-fix build both sides are 50.
		expect(after > before):toBe(true)
	end)

	it("backpack: capacity keeps rising across MANY levels (not a one-off special case)", function()
		local harness, _data, player = setup(100000)
		local previous = reportedCapacity(harness, player)
		for _ = 1, 5 do
			expect(buy(harness, player, "backpack")):toBeOk()
			local now = reportedCapacity(harness, player)
			expect(now > previous):toBe(true)
			previous = now
		end
	end)

	it("backpack: the ENFORCED capacity equals the REPORTED capacity", function()
		-- The reported number is what the HUD draws; the enforced number is where Collect starts
		-- refusing. If they drift, the bar fills to "62/70" and sticks, or claims room that is not
		-- there. Buy several levels first so this is not merely re-checking the level-0 default.
		local harness, _data, player, _shared, clock = setup(100000)
		for _ = 1, 3 do
			expect(buy(harness, player, "backpack")):toBeOk()
		end
		local capacity = reportedCapacity(harness, player) -- this call already banked mote #1
		local accepted = 1 + fillUntilRefused(harness, clock, player)
		expect(accepted):toBe(capacity)
	end)

	it("EVERY promised upgrade changes a server-observable value", function()
		-- The generalisation of the backpack bug. An upgrade with no observable channel is a RED,
		-- not an "unassertable" footnote: if the server cannot see the difference, neither can the
		-- player. Each id is probed on its OWN player so the readings cannot cross-contaminate.
		for _, upgradeId in PROMISED_UPGRADES do
			local harness, data, player, shared = setup(100000)
			local seam = shared.upgrades
			expect(seam ~= nil):toBe(true)

			local function snapshot(): string
				local got = data:get(player)
				expect(got):toBeOk()
				local d = (got :: any).value
				return string.format(
					"cap=%s magnet=%s period=%s walk=%s",
					tostring(seam:capacityFor(d)),
					tostring(seam:magnetRadiusFor(d)),
					tostring(seam:collectPeriodFor(d)),
					tostring(seam:walkSpeedFor(d))
				)
			end

			local before = snapshot()
			expect(buy(harness, player, upgradeId)):toBeOk()
			local after = snapshot()
			-- Named in the failure so a regression says WHICH upgrade went inert.
			expect(`{upgradeId}:{after}`).never:toBe(`{upgradeId}:{before}`)
		end
	end)

	it("the seam defaults to the pre-upgrade constants at level 0", function()
		-- Guards the other direction: the fix must not silently re-tune the un-upgraded game.
		local _harness, data, player, shared = setup()
		local got = data:get(player)
		expect(got):toBeOk()
		local d = (got :: any).value
		local seam = shared.upgrades
		expect(seam:capacityFor(d)):toBe(50)
		expect(seam:magnetRadiusFor(d)):toBe(6)
		expect(seam:walkSpeedFor(d)):toBe(16)
		expect(seam:levelOf(d, "backpack")):toBe(0)
	end)

	it("a missing seam falls back to base capacity, never uncapping it", function()
		-- CollectionService must stay safe when no shop service is wired (the spine, and every
		-- older spec). A nil seam must mean 50, never nil-arithmetic and never an infinite backpack.
		local clock = Mocks.clock(1000)
		local cfg = config()
		local store = Mocks.store({ clock = clock, config = cfg })
		local data = DataService.new(store, clock, cfg, Mocks.logWarn)
		local player = Mocks.player(2)
		data:loadSession(player)
		local shared: any = { clock = clock, data = data, gate = false }
		local harness = Mocks.net(shared)
		shared.net = harness.registry
		CollectionService:Start(shared) -- NO shop service: shared.upgrades stays nil
		expect(reportedCapacity(harness, player)):toBe(50)
	end)
end)
