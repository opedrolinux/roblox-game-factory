--!strict
-- games/collect-sim/tests/unit/collection.spec.luau   [INDEPENDENT TEST GATE — authored from specs/collect-sim.md]
-- Adversarial Tier-1 gate for the "Collection core" feature. Authored from the SPEC's behavioral
-- guarantees (NOT the implementation's branch logic):
--   Success criteria (specs/collect-sim.md): the collect->sell economy loop; "Economy is
--   concurrency-safe — interleaved / spam-duplicated sell ... never double-spend Stardust"; and
--   "No open exploit" (mote-value spoof / overflow). CLAUDE.md §3 (validate type+range+rate),
--   §4 (concurrency-safe economy: no double-spend/dupes).
--
-- The feature registers its Collect/Sell actions INSIDE CollectionService:Start(context) as
-- closures over a private per-player backpack table. We drive them the SAME way production does:
-- call Start({ net = harness }) so the actions register onto a Mocks.net harness, then invoke them
-- through the REAL Net.dispatch (Mocks.net), with a real DataService over a MockStore as ctx.data.
-- Stardust is read back through DataService:get — the persisted, lock-queued balance — so a mint
-- or a lost grant is observable.
--
-- Constants are DISCOVERED through the API where practical (collect until full=true to learn
-- capacity; observe earned/sold to learn mote value) rather than copied from the implementation.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local CollectionService = require("../../src/server/services/collection/CollectionService")
local DataService = require("../../src/server/data/DataService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local COLLECT = Net.Actions.Collect -- "collect.gather"
local SELL = Net.Actions.Sell -- "collect.sell"

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build a CollectionService wired onto a fresh Mocks.net harness over a DataService with one
-- loaded player. Returns (harness, service, player, clock). `opts` flows to the mock store
-- (e.g. yieldOnUpdate) and to the harness (e.g. gate = false / a real gate).
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
		harnessOpts.gate = false -- default: isolate behavior from rate-limiting
	end
	local harness = Mocks.net(harnessOpts)
	-- Register the feature's actions exactly as the runtime does: the service calls
	-- context.net:register(action) (colon syntax). harness.registry IS the real Net registry whose
	-- register(self, action) honors that colon call, so the actions land on the same registry
	-- Net.dispatch reads via harness.invoke.
	CollectionService:Start({ net = harness.registry })
	return harness, data, player, clock
end

local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Collect once and return the unwrapped {count, capacity, full}.
local function collectOnce(harness: any, player: any): any
	local r = harness.invoke(COLLECT, player, {})
	expect(r):toBeOk()
	return (r :: any).value
end

-- Discover capacity by collecting until full=true; returns the capacity (== final count).
local function fillToCapacity(harness: any, player: any): number
	local guard = 0
	local last
	while true do
		guard += 1
		if guard > 10000 then
			error("fillToCapacity did not converge (capacity unexpectedly huge)")
		end
		last = collectOnce(harness, player)
		if last.full then
			return last.count
		end
	end
end

describe("Collection core — Collect behavior", function()
	it("Collect adds exactly one mote and returns {count, capacity, full}", function()
		local harness, _, player = setup()
		local first = collectOnce(harness, player)
		expect(first.count):toBe(1)
		-- the shape is exactly the three documented fields
		expect(type(first.capacity)):toBe("number")
		expect(type(first.full)):toBe("boolean")
		local second = collectOnce(harness, player)
		expect(second.count):toBe(2) -- increments by exactly one each call
		expect(second.capacity):toBe(first.capacity) -- capacity is stable
	end)

	it("full is false below capacity and true exactly at capacity", function()
		local harness, _, player = setup()
		local first = collectOnce(harness, player)
		expect(first.full):toBe(false) -- one mote, well below capacity
		local capacity = fillToCapacity(harness, player)
		expect(capacity):toBe(first.capacity)
		-- The collect that reached capacity reported full=true (fillToCapacity stops on it).
		-- Re-query state via one more collect attempt below (capacity case) covers the boundary.
	end)

	it("Collect at capacity -> Err(OutOfRange); backpack never exceeds capacity", function()
		local harness, _, player = setup()
		local capacity = fillToCapacity(harness, player)
		-- One more collect must be refused (no overflow past capacity).
		local overflow = harness.invoke(COLLECT, player, {})
		expect(overflow):toBeErr(Result.Codes.OutOfRange)
		-- Selling now must convert EXACTLY `capacity` motes — proves the backpack held capacity, no more.
		local sell = harness.invoke(SELL, player, {})
		expect(sell):toBeOk()
		expect((sell :: any).value.sold):toBe(capacity)
	end)
end)

describe("Collection core — Sell economy", function()
	it(
		"Sell converts the WHOLE backpack: earned == N*value, sold == N, balance += earned",
		function()
			local harness, data, player = setup()
			-- Collect a known N (well below capacity).
			local N = 5
			for _ = 1, N do
				collectOnce(harness, player)
			end
			local before = balanceOf(data, player)
			local sell = harness.invoke(SELL, player, {})
			expect(sell):toBeOk()
			local s = (sell :: any).value
			expect(s.sold):toBe(N)
			-- Derive the per-mote value from the observed earnings; it must be a positive integer and
			-- consistent with the persisted balance delta (no skim, no bonus mint).
			expect(s.earned % N):toBe(0)
			local value = s.earned // N
			expect(value > 0):toBe(true)
			expect(s.earned):toBe(N * value)
			local after = balanceOf(data, player)
			expect(after - before):toBe(s.earned) -- persisted balance rose by exactly earned
			expect(s.balance):toBe(after) -- the returned balance matches the persisted balance
		end
	)

	it("Sell empties the backpack: an immediate 2nd Sell -> sold==0, earned==0", function()
		local harness, data, player = setup()
		for _ = 1, 4 do
			collectOnce(harness, player)
		end
		local first = harness.invoke(SELL, player, {})
		expect(first):toBeOk()
		expect((first :: any).value.sold):toBe(4)
		local balanceAfterFirst = balanceOf(data, player)

		local second = harness.invoke(SELL, player, {})
		expect(second):toBeOk()
		expect((second :: any).value.sold):toBe(0) -- backpack already emptied
		expect((second :: any).value.earned):toBe(0)
		-- No further currency minted by the empty second sell.
		expect(balanceOf(data, player)):toBe(balanceAfterFirst)
	end)

	it("Empty Sell: sold==0, earned==0, balance unchanged, NO error, NO currency minted", function()
		local harness, data, player = setup()
		local before = balanceOf(data, player) -- a fresh player: zero backpack, zero Stardust
		local sell = harness.invoke(SELL, player, {})
		expect(sell):toBeOk() -- NOT an error
		local s = (sell :: any).value
		expect(s.sold):toBe(0)
		expect(s.earned):toBe(0)
		expect(s.balance):toBe(before)
		expect(balanceOf(data, player)):toBe(before) -- nothing minted
	end)
end)

describe("Collection core — negative / abuse", function()
	it("malformed (non-table) payload to Collect -> Err(BadPayload), handler never runs", function()
		local harness, _, player = setup()
		expect(harness.invoke(COLLECT, player, 7)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, "gather")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, true)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- The rejected calls minted/changed nothing: a real collect still starts at count 1.
		expect(collectOnce(harness, player).count):toBe(1)
	end)

	it("malformed (non-table) payload to Sell -> Err(BadPayload), no currency minted", function()
		local harness, data, player = setup()
		for _ = 1, 3 do
			collectOnce(harness, player)
		end
		local before = balanceOf(data, player)
		expect(harness.invoke(SELL, player, 99)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(SELL, player, "sell")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(SELL, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- Rejected at validate -> backpack untouched, balance untouched.
		expect(balanceOf(data, player)):toBe(before)
		-- A real sell still finds all 3 motes (the bad payloads did not empty the backpack).
		expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(3)
	end)

	it(
		"rate limit: exceeding the Sell rate window -> Err(RateLimited); a fresh window allows again",
		function()
			-- Use a REAL gate + injected clock (like net.spec) so the action's own RatePolicy is enforced.
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, _, player = setup({ gate = gate })
			-- (setup built its own clock/gate? No — we passed our gate; but setup's data clock differs.
			--  Rate is keyed off the harness clock/gate we supplied, which is what we trip below.)

			-- Discover the Sell window empirically: spam Sell on an empty backpack (each is a valid
			-- Ok sale of 0) until the gate sheds one as RateLimited. Selling empty mints nothing, so
			-- this isolates the rate gate from the economy.
			local hitRateLimit = false
			local allowed = 0
			for _ = 1, 50 do
				local r = harness.invoke(SELL, player, {})
				if not r.ok and r.code == Result.Codes.RateLimited then
					hitRateLimit = true
					break
				end
				expect(r):toBeOk()
				allowed += 1
			end
			expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
			expect(allowed > 0):toBe(true) -- but allowed at least one through first

			-- Advance well past any reasonable window: the bucket refills, a fresh Sell is allowed.
			clock:advance(60)
			expect(harness.invoke(SELL, player, {})):toBeOk()
		end
	)
end)

describe("Collection core — concurrency / economy (double-spend defense)", function()
	-- The economy_race technique: drive interleaved invocations as coroutines against a yielding
	-- store so the second Sell arrives WHILE the first is parked inside the lock-held update.
	-- Round-robin driver: resume every suspended coroutine until all are dead.
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

	it(
		"DOUBLE-SPEND: two interleaved Sells for the SAME backpack credit Stardust AT MOST ONCE",
		function()
			-- yieldOnUpdate forces the first Sell to park inside the lock-held data:update, so the
			-- second Sell runs against the SAME backpack during that yield. The economy guarantee:
			-- total Stardust minted == ONE backpack's value, never two.
			local harness, data, player = setup({ yieldOnUpdate = true })
			local N = 6
			for _ = 1, N do
				collectOnce(harness, player)
			end
			local before = balanceOf(data, player)

			local results: { any } = {}
			local cos = {
				coroutine.create(function()
					results.a = harness.invoke(SELL, player, {})
				end),
				coroutine.create(function()
					results.b = harness.invoke(SELL, player, {})
				end),
			}
			drain(cos)

			expect(results.a):toBeOk()
			expect(results.b):toBeOk()
			-- Exactly ONE of the two sells reports the motes; the other reports an empty sale.
			local soldA = (results.a :: any).value.sold
			local soldB = (results.b :: any).value.sold
			expect(soldA + soldB):toBe(N) -- the backpack was sold exactly ONCE in total
			-- And the minted Stardust equals exactly one backpack's value (no double-spend).
			local earnedA = (results.a :: any).value.earned
			local earnedB = (results.b :: any).value.earned
			local value = (earnedA + earnedB) // N
			expect(value > 0):toBe(true)
			expect(balanceOf(data, player) - before):toBe(N * value)
		end
	)

	it(
		"SPAM-DUPLICATED: four interleaved Sells mint exactly ONE backpack's value (anti-dupe)",
		function()
			local harness, data, player = setup({ yieldOnUpdate = true })
			local N = 9
			for _ = 1, N do
				collectOnce(harness, player)
			end
			local before = balanceOf(data, player)

			local results: { any } = {}
			local cos = {}
			for i = 1, 4 do
				local idx = i
				table.insert(
					cos,
					coroutine.create(function()
						results[idx] = harness.invoke(SELL, player, {})
					end)
				)
			end
			drain(cos)

			local totalSold = 0
			local totalEarned = 0
			for i = 1, 4 do
				expect(results[i]):toBeOk() -- every duplicate returns Ok (no crash, no error code)
				totalSold += (results[i] :: any).value.sold
				totalEarned += (results[i] :: any).value.earned
			end
			expect(totalSold):toBe(N) -- the backpack was sold exactly once across 4 spam requests
			local value = totalEarned // N
			expect(value > 0):toBe(true)
			expect(totalEarned):toBe(N * value) -- earnings reported once
			expect(balanceOf(data, player) - before):toBe(N * value) -- minted exactly once
		end
	)

	it(
		"CONSERVATION: collecting M motes then selling mints exactly M*value (even with an interleaved 2nd sell)",
		function()
			-- Economy conservation: no mint, no loss. We collect M, then race two sells; the persisted
			-- balance delta must equal M*value EXACTLY — proving the data:update yield window cannot be
			-- exploited to mint extra or silently drop the grant.
			local harness, data, player = setup({ yieldOnUpdate = true })
			local M = 12
			for _ = 1, M do
				collectOnce(harness, player)
			end
			local before = balanceOf(data, player)

			-- Establish value independently from a SEPARATE clean player/sell (no race), so the
			-- conservation assertion is anchored to a known per-mote value, not the raced result itself.
			local harness2, data2, player2 = setup() -- fresh, no yield
			collectOnce(harness2, player2)
			local probe = harness2.invoke(SELL, player2, {})
			expect(probe):toBeOk()
			local value = (probe :: any).value.earned -- earned for exactly 1 mote == the per-mote value
			expect(value > 0):toBe(true)
			expect((data2 :: any) ~= nil):toBe(true)

			local cos = {
				coroutine.create(function()
					harness.invoke(SELL, player, {})
				end),
				coroutine.create(function()
					harness.invoke(SELL, player, {})
				end),
			}
			drain(cos)
			-- Exactly M*value minted: conservation holds across the interleaved sell.
			expect(balanceOf(data, player) - before):toBe(M * value)
		end
	)
end)

describe("Collection core — boundary: repeated full cycles accumulate", function()
	it("two full collect->sell cycles accumulate the balance correctly", function()
		local harness, data, player = setup()
		local before = balanceOf(data, player)

		local cap1 = fillToCapacity(harness, player)
		local sell1 = harness.invoke(SELL, player, {})
		expect(sell1):toBeOk()
		local earned1 = (sell1 :: any).value.earned
		expect((sell1 :: any).value.sold):toBe(cap1)
		expect(balanceOf(data, player)):toBe(before + earned1)

		-- Backpack emptied by the sell -> a second full cycle is possible.
		local cap2 = fillToCapacity(harness, player)
		expect(cap2):toBe(cap1) -- capacity is constant across cycles
		local sell2 = harness.invoke(SELL, player, {})
		expect(sell2):toBeOk()
		local earned2 = (sell2 :: any).value.earned
		expect(earned2):toBe(earned1) -- same motes sold -> same earnings

		-- Final balance is the SUM of both cycles — no loss, no double-credit between cycles.
		expect(balanceOf(data, player)):toBe(before + earned1 + earned2)
	end)
end)

-- -------------------------------------------------------------------------------------------------
-- RED-TEAM REGRESSION (independent economy red-team, test gate 2026-06-19): CAPACITY-cap bypass via
-- the Sell failure-restore path. When a Sell's ctx.data:update FAILS, the handler restores the
-- captured motes by ADDING them back to the backpack. The Store/DataService `update` contract may
-- return Err (the restore branch exists precisely for that), and if motes were auto-collected DURING
-- the update's yield window, an UNCLAMPED restore pushes the backpack PAST CAPACITY — a "No open
-- exploit" / range-invariant (CLAUDE.md rule 3; the capacity cap is the range) violation: the player
-- can then sell more than a backpack should ever hold.
--
-- The current spine MockStore never fails `update` (only `save` can fail), so this path is LATENT
-- there; B2's real session-locked store, behind the same Store interface, can fail an update
-- mid-yield. We drive the contract-permitted outcome with a controllable inline fake `ctx.data` that
-- yields-then-fails `update` (the same inline-fake technique economy_race.spec uses for its
-- counter-case). FALSIFIABLE: on the unclamped code the observing sell reports capacity+k (> cap);
-- the clamp (math.min(CAPACITY, ...)) makes it exactly capacity.
-- -------------------------------------------------------------------------------------------------
describe(
	"Collection core — capacity invariant on a failed-sell restore (red-team regression)",
	function()
		-- A ctx.data whose `update` first PARKS (so an interleaving Collect can refill the backpack) then
		-- returns Err; after `mode` is flipped to "succeed" it applies the transform and persists, so a
		-- follow-up sell can OBSERVE how many motes the restore left in the backpack.
		local function controllableData(): any
			local d: any = { stardust = 0, mode = "failYield" }
			function d.get(self: any, _player: any): any
				return Result.ok({ currencies = { Stardust = self.stardust } })
			end
			function d.update(self: any, _player: any, transform: (any) -> any): any
				if self.mode == "failYield" then
					coroutine.yield() -- park inside "update" so an interleaving Collect refills the backpack
					return Result.err(Result.Codes.Internal, "forced update failure")
				end
				local snapshot = { currencies = { Stardust = self.stardust } }
				local newData = transform(snapshot)
				self.stardust = newData.currencies.Stardust
				return Result.ok(newData)
			end
			return d
		end

		it(
			"a Sell whose update fails while Collects refill mid-yield must NOT overfill past capacity",
			function()
				local fakeData = controllableData()
				local clock = Mocks.clock(1000)
				local harness = Mocks.net({ clock = clock, data = fakeData, gate = false })
				local player = Mocks.player(1)
				CollectionService:Start({ net = harness.registry })

				-- Collect a small k; this is the amount the failed sell will try to restore.
				local k = 3
				for _ = 1, k do
					expect(harness.invoke(COLLECT, player, {})):toBeOk()
				end

				-- Fire a Sell that parks inside the failing update (captures k, zeroes the backpack, yields).
				local sellResult: any
				local sellCo = coroutine.create(function()
					sellResult = harness.invoke(SELL, player, {})
				end)
				expect((coroutine.resume(sellCo))):toBe(true)
				expect(coroutine.status(sellCo)):toBe("suspended") -- parked mid-"update"

				-- While the sell is parked, auto-Collect refills the backpack all the way to capacity.
				local capacity = 0
				local guard = 0
				while true do
					guard += 1
					if guard > 10000 then
						error("refill did not converge")
					end
					local r = harness.invoke(COLLECT, player, {})
					expect(r):toBeOk()
					if (r :: any).value.full then
						capacity = (r :: any).value.count
						break
					end
				end

				-- Resume the sell: update returns Err -> the restore branch runs (adds k back).
				expect((coroutine.resume(sellCo))):toBe(true)
				expect(coroutine.status(sellCo)):toBe("dead")
				expect(sellResult):toBeErr(Result.Codes.Internal) -- the sale itself failed: no currency granted

				-- Observe the backpack via a now-succeeding sell. The cap invariant: the backpack can NEVER
				-- hold more than capacity, so this must sell AT MOST capacity. Unclamped restore -> capacity+k.
				fakeData.mode = "succeed"
				local observe = harness.invoke(SELL, player, {})
				expect(observe):toBeOk()
				expect((observe :: any).value.sold <= capacity):toBe(true)
				expect((observe :: any).value.sold):toBe(capacity)
			end
		)
	end
)

describe("Collection core — auto-collect ticker (gamepass-gated, server-clock driven)", function()
	-- The auto-collect ticker (CollectionService.tickAutoCollect, fed at runtime by the guarded
	-- driver) grants a pass-holder one mote per AUTO_COLLECT_INTERVAL of elapsed SERVER MONOTONIC
	-- time, into the SAME backpack Collect/Sell share — so auto-collected motes sell normally.
	-- Authored from the spec's gamepass-gated auto-collect guarantee, driven through the injected
	-- fake clock (deterministic; no task.wait). We grab the ticker AFTER the setup whose backpack we
	-- then Sell from (Start sets CollectionService.tickAutoCollect over that setup's backpack).
	local AUTO_FLAG = "gamepass.autoCollect" -- the spec's auto-collect gamepass ownership flag

	-- Round-robin coroutine driver so a write works whether or not the store yields.
	local function drainOne(thunk: () -> ()): ()
		local co = coroutine.create(thunk)
		local guard = 0
		while coroutine.status(co) ~= "dead" do
			guard += 1
			if guard > 500 then
				error("write did not converge")
			end
			local ok, err = coroutine.resume(co)
			if not ok then
				error(`coroutine errored: {tostring(err)}`)
			end
		end
	end

	-- Grant a persisted flag (the auto-collect gamepass) through the canonical write path.
	local function setFlag(data: any, player: any, key: string): ()
		local r: any = nil
		drainOne(function()
			r = data:update(player, function(d)
				if d.flags == nil then
					d.flags = {}
				end
				d.flags[key] = true
				return d
			end)
		end)
		expect(r):toBeOk()
	end

	it("a NON-holder never auto-collects, no matter how much time elapses", function()
		local harness, data, player, clock = setup()
		local tick = CollectionService.tickAutoCollect
		local ctx = { clock = clock, data = data }
		expect(tick(ctx, player)):toBe(0) -- first observation anchors the clock, grants nothing
		clock:advance(10)
		expect(tick(ctx, player)):toBe(0) -- no gamepass -> strict no-op even after 10s
		expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(0) -- backpack empty
	end)

	it("a HOLDER accrues one mote per elapsed second, and they sell normally", function()
		local harness, data, player, clock = setup()
		setFlag(data, player, AUTO_FLAG)
		local tick = CollectionService.tickAutoCollect
		local ctx = { clock = clock, data = data }
		expect(tick(ctx, player)):toBe(0) -- anchor
		clock:advance(5)
		expect(tick(ctx, player)):toBe(5) -- five seconds -> five motes granted
		local sell = (harness.invoke(SELL, player, {}) :: any).value
		expect(sell.sold):toBe(5) -- the auto-granted motes are in the shared backpack
		expect(sell.earned > 0):toBe(true) -- and convert to Stardust like hand-collected motes
	end)

	it("the sub-interval remainder is carried, never lost", function()
		local _h, data, player, clock = setup()
		setFlag(data, player, AUTO_FLAG)
		local tick = CollectionService.tickAutoCollect
		local ctx = { clock = clock, data = data }
		expect(tick(ctx, player)):toBe(0) -- anchor
		clock:advance(2.5)
		expect(tick(ctx, player)):toBe(2) -- floor(2.5) = 2 granted, 0.5 carried forward
		clock:advance(0.5) -- + the carried 0.5 = one full interval
		expect(tick(ctx, player)):toBe(1) -- the carried remainder completes one more mote
	end)

	it("the grant is clamped to capacity (never overfills the backpack)", function()
		-- Discover capacity on a clean probe (never copy the implementation constant).
		local ph, _pd, pp = setup({ userId = 4242 })
		local capacity = fillToCapacity(ph, pp)

		local harness, data, player, clock = setup({ userId = 77 })
		setFlag(data, player, AUTO_FLAG)
		local tick = CollectionService.tickAutoCollect -- grabbed AFTER the player-77 setup
		local ctx = { clock = clock, data = data }
		expect(tick(ctx, player)):toBe(0) -- anchor
		clock:advance(capacity * 10) -- far more elapsed than a backpack can hold
		expect(tick(ctx, player)):toBe(capacity) -- clamped to capacity, not capacity*10
		clock:advance(capacity * 10)
		expect(tick(ctx, player)):toBe(0) -- already full -> no further grant
		expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(capacity)
	end)
end)
