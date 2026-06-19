--!strict
-- games/collect-sim/tests/unit/shop.spec.luau   [INDEPENDENT TEST GATE — authored from the shop spec slice]
-- Adversarial Tier-1 gate for the "Upgrades shop" feature (the Stardust SINK). Authored from the
-- SPEC's behavioral guarantees (NOT the implementation's branch logic — maker != checker):
--   * a purchase deducts EXACTLY the server-derived catalog cost and raises the level by EXACTLY 1,
--     BOTH persisted (read back through ctx.data:get).
--   * CONCURRENCY-SAFE SPEND (the economy red-team target, dual of Collection's Sell): interleaved /
--     spam-duplicated BuyUpgrade for the same player can NEVER spend more Stardust than the player
--     has, NEVER grant a level without the matching deduction, NEVER double-grant a level for one
--     payment. The cost-check + deduction + level-bump must all be INSIDE one update transform.
--   * insufficient Stardust -> Err(Insufficient); balance and level unchanged.
--   * max level -> Err(OutOfRange).
--   * malformed / unknown-upgrade payload -> Err(BadPayload); no state change.
--   * no open exploit: cost is ALWAYS server-derived; no client-supplied price/level/amount honored.
--
-- We drive the action the SAME way production does: call Start({ net = harness.registry }) so the
-- BuyUpgrade action registers onto a Mocks.net harness, then invoke through the REAL Net.dispatch,
-- with a real DataService over a MockStore as ctx.data. Stardust + the upgrade level are read back
-- through DataService:get — the persisted, lock-queued state — so a mint or a phantom grant is
-- observable.
--
-- Constants are DISCOVERED through the API where practical: we never copy the CATALOG. We probe the
-- next-level cost by giving the player a huge balance, buying, and observing the returned `cost` +
-- the persisted balance delta. The four known upgrade kinds are taken from the SPEC text (the wire
-- contract), not from the implementation table.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local UpgradesShopService = require("../../src/server/services/shop/UpgradesShopService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local BUY = Net.Actions.BuyUpgrade -- "shop.buy"

-- The four upgrade kinds are the SPEC's wire contract (the client may name only these).
local KNOWN_UPGRADES = { "collect-speed", "backpack", "magnet", "walk-speed" }

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build a shop wired onto a fresh Mocks.net harness over a DataService with one loaded player.
-- Returns (harness, data, player, clock). `opts` flows to the mock store (yieldOnUpdate) and the
-- harness (gate). gate defaults to false so behavior is isolated from the rate gate.
local function setup(opts: any?): (any, any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(1000)
	local cfg = config()
	local store = Mocks.store({ clock = clock, config = cfg, yieldOnUpdate = o.yieldOnUpdate })
	local data = DataService.new(store, clock, cfg, Mocks.logWarn)
	local player = Mocks.player(o.userId or 1)
	data:loadSession(player)

	local harnessOpts: any = { clock = clock, data = data }
	if o.gate ~= nil then
		harnessOpts.gate = o.gate
	else
		harnessOpts.gate = false
	end
	local harness = Mocks.net(harnessOpts)
	UpgradesShopService:Start({ net = harness.registry })
	return harness, data, player, clock
end

-- Read the persisted Stardust balance through the lock-queued data layer.
local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Read the persisted level of a given upgrade (defaults to 0 when unset).
local function levelOf(data: any, player: any, upgradeId: string): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.upgrades[upgradeId] or 0
end

-- Round-robin coroutine driver: resume every suspended coroutine until all are dead. Used both to
-- seed through a yielding store and to interleave the race invocations. Deterministic, deadlock-
-- guarded. (Identical technique to economy_race.spec / collection.spec.)
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

-- Set the player's Stardust balance to an exact amount through the canonical write path. Driven
-- inside a drained coroutine so it works even when the store has yieldOnUpdate (the race setups):
-- on a non-yielding store the coroutine completes in one resume; on a yielding store the seed
-- update parks once and `drain` resumes it. Either way the MAIN thread never yields.
local function setStardust(data: any, player: any, amount: number): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = data:update(player, function(d)
			d.currencies.Stardust = amount
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

describe(
	"Upgrades shop — successful purchase (deduct exactly, +1 level, both persisted)",
	function()
		it(
			"a buy raises level by exactly 1 and deducts EXACTLY the returned cost, both persisted",
			function()
				local harness, data, player = setup()
				setStardust(data, player, 100000) -- afford anything
				local upgradeId = "collect-speed"
				expect(levelOf(data, player, upgradeId)):toBe(0)

				local before = balanceOf(data, player)
				local r = harness.invoke(BUY, player, { upgradeId = upgradeId })
				expect(r):toBeOk()
				local v = (r :: any).value

				-- Return shape: { upgradeId, level = NEW level, cost = spent, balance = NEW balance }.
				expect(v.upgradeId):toBe(upgradeId)
				expect(v.level):toBe(1) -- level rose by exactly 1 (from 0)
				expect(type(v.cost)):toBe("number")
				expect(v.cost > 0):toBe(true) -- a sink: the next level always costs something

				-- The PERSISTED level rose by exactly 1, and the PERSISTED balance fell by exactly v.cost.
				expect(levelOf(data, player, upgradeId)):toBe(1)
				local after = balanceOf(data, player)
				expect(before - after):toBe(v.cost) -- deducted exactly the cost, no more no less
				expect(v.balance):toBe(after) -- the returned balance matches the persisted balance
			end
		)

		it(
			"the cost is a RISING curve: each successive level costs strictly more (server-derived)",
			function()
				local harness, data, player = setup()
				setStardust(data, player, 100000)
				local upgradeId = "backpack"

				local lastCost = 0
				local lastLevel = 0
				for buy = 1, 5 do
					local before = balanceOf(data, player)
					local r = harness.invoke(BUY, player, { upgradeId = upgradeId })
					expect(r):toBeOk()
					local v = (r :: any).value
					-- level increments by exactly 1 each buy
					expect(v.level):toBe(lastLevel + 1)
					lastLevel = v.level
					-- persisted deduction == reported cost
					expect(before - balanceOf(data, player)):toBe(v.cost)
					-- strictly rising cost (base * (level+1) is monotonic)
					expect(v.cost > lastCost):toBe(true)
					lastCost = v.cost
					expect(buy):toBe(v.level) -- sanity: buy #k yields level k
				end
			end
		)

		it("each known upgrade kind is independently buyable and persists its own level", function()
			local harness, data, player = setup()
			setStardust(data, player, 1000000)
			for _, upgradeId in KNOWN_UPGRADES do
				expect(levelOf(data, player, upgradeId)):toBe(0)
				local r = harness.invoke(BUY, player, { upgradeId = upgradeId })
				expect(r):toBeOk()
				expect((r :: any).value.level):toBe(1)
				expect(levelOf(data, player, upgradeId)):toBe(1)
			end
			-- Buying one kind never bumped a sibling kind: each is exactly level 1.
			for _, upgradeId in KNOWN_UPGRADES do
				expect(levelOf(data, player, upgradeId)):toBe(1)
			end
		end)
	end
)

describe("Upgrades shop — insufficient Stardust (no deduction, no level change)", function()
	it(
		"balance below the next-level cost -> Err(Insufficient); balance AND level unchanged",
		function()
			local harness, data, player = setup()
			local upgradeId = "magnet"

			-- Discover the level-1 cost on a SEPARATE flush-rich player so we know the exact threshold.
			local probeHarness, probeData, probePlayer = setup({ userId = 999 })
			setStardust(probeData, probePlayer, 1000000)
			local probe = probeHarness.invoke(BUY, probePlayer, { upgradeId = upgradeId })
			expect(probe):toBeOk()
			local cost = (probe :: any).value.cost
			expect(cost > 0):toBe(true)

			-- Give the real player ONE LESS than the cost: cannot afford.
			setStardust(data, player, cost - 1)
			local before = balanceOf(data, player)
			expect(levelOf(data, player, upgradeId)):toBe(0)

			local r = harness.invoke(BUY, player, { upgradeId = upgradeId })
			expect(r):toBeErr(Result.Codes.Insufficient)
			-- NO deduction, NO level change.
			expect(balanceOf(data, player)):toBe(before)
			expect(levelOf(data, player, upgradeId)):toBe(0)
		end
	)

	it("zero balance -> Err(Insufficient); a fresh player can never buy for free", function()
		local harness, data, player = setup()
		expect(balanceOf(data, player)):toBe(0) -- fresh player default
		local r = harness.invoke(BUY, player, { upgradeId = "walk-speed" })
		expect(r):toBeErr(Result.Codes.Insufficient)
		expect(balanceOf(data, player)):toBe(0)
		expect(levelOf(data, player, "walk-speed")):toBe(0)
	end)

	it("exactly-equal balance CAN afford (boundary: cost not strict-greater required)", function()
		-- The spec says reject when balance < cost. So balance == cost MUST succeed and zero out.
		local probeHarness, probeData, probePlayer = setup({ userId = 1234 })
		setStardust(probeData, probePlayer, 1000000)
		local probe = probeHarness.invoke(BUY, probePlayer, { upgradeId = "collect-speed" })
		expect(probe):toBeOk()
		local cost = (probe :: any).value.cost

		local harness, data, player = setup()
		setStardust(data, player, cost) -- exactly enough for level 1
		local r = harness.invoke(BUY, player, { upgradeId = "collect-speed" })
		expect(r):toBeOk()
		expect((r :: any).value.cost):toBe(cost)
		expect(balanceOf(data, player)):toBe(0) -- spent it all, exact
		expect((r :: any).value.balance):toBe(0)
		expect(levelOf(data, player, "collect-speed")):toBe(1)
	end)
end)

describe("Upgrades shop — max level (OutOfRange, nothing bought)", function()
	it(
		"buying past the catalog max -> Err(OutOfRange); no further deduction or level change",
		function()
			local harness, data, player = setup()
			setStardust(data, player, 100000000) -- effectively unlimited Stardust
			local upgradeId = "backpack"

			-- Buy until the action refuses with OutOfRange (max reached). Discover the max via the API.
			local maxLevel = 0
			local guard = 0
			while true do
				guard += 1
				if guard > 1000 then
					error("never reached max level (max unexpectedly huge or no cap)")
				end
				local r = harness.invoke(BUY, player, { upgradeId = upgradeId })
				if not r.ok then
					expect(r):toBeErr(Result.Codes.OutOfRange) -- the refusal at max is OutOfRange
					break
				end
				expect((r :: any).value.level):toBe(maxLevel + 1) -- strictly +1 each successful buy
				maxLevel = (r :: any).value.level
			end
			expect(maxLevel > 0):toBe(true) -- there WAS a sequence of successful buys
			expect(levelOf(data, player, upgradeId)):toBe(maxLevel) -- capped at maxLevel, persisted

			-- A further buy attempt at max: still OutOfRange, still no change, even with money to burn.
			local balanceAtMax = balanceOf(data, player)
			local again = harness.invoke(BUY, player, { upgradeId = upgradeId })
			expect(again):toBeErr(Result.Codes.OutOfRange)
			expect(levelOf(data, player, upgradeId)):toBe(maxLevel) -- unchanged
			expect(balanceOf(data, player)):toBe(balanceAtMax) -- NO deduction at max (nothing to buy)
		end
	)
end)

describe("Upgrades shop — malformed / unknown payload (BadPayload, no state change)", function()
	it("non-table payload -> Err(BadPayload); handler never runs, no state change", function()
		local harness, data, player = setup()
		setStardust(data, player, 100000)
		local before = balanceOf(data, player)
		expect(harness.invoke(BUY, player, 7)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(BUY, player, "collect-speed")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(BUY, player, true)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(BUY, player, nil)):toBeErr(Result.Codes.BadPayload)
		expect(balanceOf(data, player)):toBe(before) -- nothing deducted
	end)

	it("missing / non-string upgradeId -> Err(BadPayload)", function()
		local harness, data, player = setup()
		setStardust(data, player, 100000)
		expect(harness.invoke(BUY, player, {})):toBeErr(Result.Codes.BadPayload) -- no upgradeId
		expect(harness.invoke(BUY, player, { upgradeId = 5 })):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(BUY, player, { upgradeId = true })):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(BUY, player, { upgradeId = {} })):toBeErr(Result.Codes.BadPayload)
	end)

	it("unknown upgrade kind -> Err(BadPayload), NOT OutOfRange; no state change", function()
		local harness, data, player = setup()
		setStardust(data, player, 100000)
		local before = balanceOf(data, player)
		-- An upgrade kind not in the four known kinds is a malformed payload, not a range error.
		expect(harness.invoke(BUY, player, { upgradeId = "speed" })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(harness.invoke(BUY, player, { upgradeId = "collect-speeed" })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(harness.invoke(BUY, player, { upgradeId = "Backpack" })):toBeErr( -- case sensitive
			Result.Codes.BadPayload
		)
		expect(harness.invoke(BUY, player, { upgradeId = "" })):toBeErr(Result.Codes.BadPayload)
		expect(balanceOf(data, player)):toBe(before)
	end)

	it(
		"NO open exploit: a client-supplied price/level/amount is ignored; cost is server-derived",
		function()
			-- The client smuggles cost/level/amount/price fields. They must be NEVER honored: the cost is
			-- derived from the catalog + current level, identical to a clean buy with no extra fields.
			local cleanHarness, cleanData, cleanPlayer = setup({ userId = 7777 })
			setStardust(cleanData, cleanPlayer, 100000)
			local clean = cleanHarness.invoke(BUY, cleanPlayer, { upgradeId = "magnet" })
			expect(clean):toBeOk()
			local serverCost = (clean :: any).value.cost

			local harness, data, player = setup()
			setStardust(data, player, 100000)
			local before = balanceOf(data, player)
			local r = harness.invoke(BUY, player, {
				upgradeId = "magnet",
				cost = 0, -- "free", please
				price = 1,
				amount = 99, -- buy 99 levels at once, please
				level = 9, -- jump to level 9, please
				balance = 999999999,
			})
			expect(r):toBeOk()
			local v = (r :: any).value
			expect(v.cost):toBe(serverCost) -- the client's cost=0 was ignored
			expect(v.level):toBe(1) -- the client's level=9 was ignored: still +1 from 0
			expect(before - balanceOf(data, player)):toBe(serverCost) -- deducted the real cost, not 0
			expect(levelOf(data, player, "magnet")):toBe(1) -- not 9
		end
	)
end)

describe("Upgrades shop — concurrency-safe spend (interleaved + spam-duplicated)", function()
	-- The economy_race technique: drive interleaved invocations as coroutines against a yielding
	-- store so the second BuyUpgrade arrives WHILE the first is parked inside the lock-held update.
	-- The round-robin `drain` driver is module-scoped (defined above, alongside setStardust).

	-- Discover the level-1 cost for an upgrade via a clean, no-yield probe player.
	local function probeCost(upgradeId: string): number
		local h, d, p = setup({ userId = 4242 })
		setStardust(d, p, 100000000)
		local r = h.invoke(BUY, p, { upgradeId = upgradeId })
		expect(r):toBeOk()
		return (r :: any).value.cost
	end

	it("DOUBLE-SPEND: two interleaved buys with money for ONLY ONE buy exactly once", function()
		-- yieldOnUpdate forces the first buy to park inside the lock-held data:update, so the second
		-- buy runs against the SAME snapshot during that yield. Guarantee: at most ONE buy succeeds,
		-- exactly its cost is deducted, the level rises by exactly 1 — never two grants for one pay,
		-- never a balance going negative.
		local upgradeId = "collect-speed"
		local cost = probeCost(upgradeId)

		local harness, data, player = setup({ yieldOnUpdate = true })
		-- Enough for EXACTLY ONE level-1 purchase (cost), but not two (the level-2 cost is higher,
		-- and even at cost*1 there is only room for one deduction).
		setStardust(data, player, cost)
		local before = balanceOf(data, player)
		expect(before):toBe(cost)

		local results: { any } = {}
		local cos = {
			coroutine.create(function()
				results.a = harness.invoke(BUY, player, { upgradeId = upgradeId })
			end),
			coroutine.create(function()
				results.b = harness.invoke(BUY, player, { upgradeId = upgradeId })
			end),
		}
		drain(cos)

		-- Exactly ONE Ok, exactly one rejection (the loser cannot afford the now-deducted balance).
		local oks = 0
		local okValue: any = nil
		for _, key in { "a", "b" } do
			local r = results[key]
			if r.ok then
				oks += 1
				okValue = r.value
			else
				expect(r):toBeErr(Result.Codes.Insufficient)
			end
		end
		expect(oks):toBe(1) -- NEVER two grants for the money of one
		-- The single winner deducted exactly its cost; the level rose by exactly 1.
		expect(okValue.cost):toBe(cost)
		expect(okValue.level):toBe(1)
		expect(levelOf(data, player, upgradeId)):toBe(1) -- exactly one level granted
		expect(balanceOf(data, player)):toBe(before - cost) -- exactly one deduction
		expect(balanceOf(data, player) >= 0):toBe(true) -- balance NEVER went negative
	end)

	it(
		"SPAM-DUPLICATED: four interleaved identical buys with money for ONE -> exactly one grant",
		function()
			local upgradeId = "backpack"
			local cost = probeCost(upgradeId)

			local harness, data, player = setup({ yieldOnUpdate = true })
			setStardust(data, player, cost) -- money for exactly one
			local before = balanceOf(data, player)

			local results: { any } = {}
			local cos = {}
			for i = 1, 4 do
				local idx = i
				table.insert(
					cos,
					coroutine.create(function()
						results[idx] = harness.invoke(BUY, player, { upgradeId = upgradeId })
					end)
				)
			end
			drain(cos)

			local oks = 0
			for i = 1, 4 do
				local r = results[i]
				if r.ok then
					oks += 1
					expect((r :: any).value.cost):toBe(cost)
				else
					expect(r):toBeErr(Result.Codes.Insufficient) -- losers shed cleanly
				end
			end
			expect(oks):toBe(1) -- exactly one of four spam clicks bought a level
			expect(levelOf(data, player, upgradeId)):toBe(1) -- exactly one level granted
			expect(before - balanceOf(data, player)):toBe(cost) -- exactly one deduction
			expect(balanceOf(data, player) >= 0):toBe(true) -- never overspent
		end
	)

	it(
		"CONSERVATION: with money for TWO buys, two interleaved buys grant TWO levels, deduct cost1+cost2",
		function()
			-- The dual check: when the player CAN afford both, the queued buys must BOTH land (no lost
			-- grant) and the deduction must be EXACTLY cost(level0->1) + cost(level1->2). The second buy
			-- re-reads the bumped level inside the transform, so its cost is the level-2 cost, not a
			-- repeat of the level-1 cost.
			local upgradeId = "magnet"
			-- Discover both successive costs on a clean serial player.
			local hp, dp, pp = setup({ userId = 5151 })
			setStardust(dp, pp, 100000000)
			local cost1 = (hp.invoke(BUY, pp, { upgradeId = upgradeId }) :: any).value.cost
			local cost2 = (hp.invoke(BUY, pp, { upgradeId = upgradeId }) :: any).value.cost
			expect(cost2 > cost1):toBe(true) -- rising curve

			local harness, data, player = setup({ yieldOnUpdate = true })
			setStardust(data, player, cost1 + cost2) -- exactly enough for two levels
			local before = balanceOf(data, player)

			local results: { any } = {}
			local cos = {
				coroutine.create(function()
					results.a = harness.invoke(BUY, player, { upgradeId = upgradeId })
				end),
				coroutine.create(function()
					results.b = harness.invoke(BUY, player, { upgradeId = upgradeId })
				end),
			}
			drain(cos)

			expect(results.a):toBeOk()
			expect(results.b):toBeOk()
			-- The two buys produced levels {1, 2} in some order (each re-read the latest level).
			local levels = { (results.a :: any).value.level, (results.b :: any).value.level }
			table.sort(levels)
			expect(levels[1]):toBe(1)
			expect(levels[2]):toBe(2)
			-- Final persisted level is exactly 2; the total deducted is exactly cost1+cost2 (no mint/loss).
			expect(levelOf(data, player, upgradeId)):toBe(2)
			expect(before - balanceOf(data, player)):toBe(cost1 + cost2)
			expect(balanceOf(data, player)):toBe(0)
		end
	)
end)

describe(
	"Upgrades shop — rate limit (defence in depth, not the concurrency guarantee)",
	function()
		it(
			"spamming BuyUpgrade past the action's rate window -> Err(RateLimited); refills after window",
			function()
				-- Use a REAL gate + injected clock so the action's own RatePolicy is enforced. We give the
				-- player no money so each buy is an Insufficient (cheap, mints nothing) until the gate sheds.
				local clock = Mocks.clock(1000)
				local gate = Mocks.gate(clock)
				local harness, data, player = setup({ gate = gate })
				expect(balanceOf(data, player)):toBe(0)

				local hitRateLimit = false
				local allowed = 0
				for _ = 1, 50 do
					local r = harness.invoke(BUY, player, { upgradeId = "collect-speed" })
					if not r.ok and r.code == Result.Codes.RateLimited then
						hitRateLimit = true
						break
					end
					-- before the gate sheds, an unaffordable buy is Insufficient (never Ok with no money)
					expect(r):toBeErr(Result.Codes.Insufficient)
					allowed += 1
				end
				expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
				expect(allowed > 0):toBe(true)

				clock:advance(60) -- refill the bucket
				expect(harness.invoke(BUY, player, { upgradeId = "collect-speed" })):toBeErr(
					Result.Codes.Insufficient
				) -- allowed through the gate again (still no money, so Insufficient, NOT RateLimited)
			end
		)
	end
)
