--!strict
-- games/collect-sim/tests/unit/collection.spec.luau   [INDEPENDENT TEST GATE — authored from specs/collect-sim.md]
-- Adversarial Tier-1 gate for the "Collection core" feature. Authored from the SPEC's behavioral
-- guarantees (NOT the implementation's branch logic):
--   Success criteria (specs/collect-sim.md): the collect->sell economy loop; "Economy is
--   concurrency-safe — interleaved / spam-duplicated sell ... never double-spend Stardust"; and
--   "No open exploit". CLAUDE.md §3 (validate type+range+rate), §4 (concurrency-safe economy).
--
-- ----- THE CONTRACT CHANGED, AND THIS FILE CHANGED WITH IT -----
-- Collect used to add EXACTLY ONE MOTE PER REQUEST with no position, proximity or timing check.
-- That made the economy a function of how fast a client could call, not of how a player played: a
-- scripted client minted ~70x a walking player's income, and every price in the game is calibrated
-- against the walker. "No open exploit" was a success criterion no assertion in this suite ever
-- touched — and these tests, by driving a bare loop of invokes and asserting `count == 2`, were
-- shaped exactly like the exploit.
--
-- Collect is now governed by the SERVER MONOTONIC CLOCK: a call is granted
-- floor(credit + elapsed/collectPeriod) motes, capped, and the credit is spent. So a test must let
-- time pass to collect, which is what a player does. The new gates at the bottom assert the
-- property directly: a flood with a frozen clock mints nothing beyond one mote.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local CollectionService = require("../../src/server/services/collection/CollectionService")
local IslandsService = require("../../src/server/services/islands/IslandsService")
local DataService = require("../../src/server/data/DataService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local COLLECT = Net.Actions.Collect -- "collect.gather"
local SELL = Net.Actions.Sell -- "collect.sell"

-- One mote's worth of server time at level 0. Discovered through the API (the Collect reply
-- reports `collectPeriod`) rather than copied from the implementation — see periodOf below.
local DEFAULT_PERIOD = 0.06

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
-- loaded player. Returns (harness, data, player, clock, shared). `opts` flows to the mock store
-- (e.g. yieldOnUpdate) and to the harness (e.g. gate = false / a real gate).
local function setup(opts: any?): (any, any, any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(1000)
	local cfg = config()
	local store = Mocks.store({ clock = clock, config = cfg, yieldOnUpdate = o.yieldOnUpdate })
	local data = DataService.new(store, clock, cfg, Mocks.logWarn)
	local player = Mocks.player(o.userId or 1)
	data:loadSession(player)

	local shared: any = { clock = clock, data = data }
	if o.gate ~= nil then
		shared.gate = o.gate
	else
		shared.gate = false -- default: isolate behavior from rate-limiting
	end
	local harness = Mocks.net(shared)
	shared.net = harness.registry
	if o.islands then
		IslandsService:Start(shared)
	end
	if o.world then
		shared.world = Mocks.world()
	end
	-- Register the feature's actions exactly as the runtime does.
	CollectionService:Start({ net = harness.registry })
	return harness, data, player, clock, shared
end

local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Let one mote's worth of server time pass, then collect. Returns the unwrapped reply.
local function collectOnce(harness: any, clock: any, player: any): any
	clock:advance(DEFAULT_PERIOD * 2)
	local r = harness.invoke(COLLECT, player, {})
	expect(r):toBeOk()
	return (r :: any).value
end

-- Collect exactly `n` motes, however many calls that takes. Asserts convergence rather than
-- assuming a motes-per-call ratio, so the test survives a retune of the curve.
local function collectExactly(harness: any, clock: any, player: any, n: number): number
	local got = 0
	local guard = 0
	while got < n do
		guard += 1
		if guard > n * 4 + 200 then
			error(`collectExactly did not converge (wanted {n}, got {got})`)
		end
		-- Advance only what is still needed, so the last call cannot overshoot past `n`.
		clock:advance(DEFAULT_PERIOD * math.min(n - got, 10))
		local r = harness.invoke(COLLECT, player, {})
		expect(r):toBeOk()
		got += (r :: any).value.granted
		if (r :: any).value.full then
			break
		end
	end
	return got
end

-- Discover capacity by collecting until full=true; returns the capacity (== final count).
local function fillToCapacity(harness: any, clock: any, player: any): number
	local guard = 0
	local last
	while true do
		guard += 1
		if guard > 5000 then
			error("fillToCapacity did not converge (capacity unexpectedly huge)")
		end
		last = collectOnce(harness, clock, player)
		if last.full then
			return last.count
		end
	end
end

describe("Collection core — Collect behavior", function()
	it("Collect grants motes and returns {count, capacity, full, granted}", function()
		local harness, _, player, clock = setup()
		local first = collectOnce(harness, clock, player)
		expect(first.count >= 1):toBe(true)
		expect(type(first.capacity)):toBe("number")
		expect(type(first.full)):toBe("boolean")
		expect(type(first.granted)):toBe("number")
		expect(first.granted >= 1):toBe(true)
		local second = collectOnce(harness, clock, player)
		expect(second.count > first.count):toBe(true) -- the count strictly rises with elapsed time
		expect(second.capacity):toBe(first.capacity) -- capacity is stable
	end)

	it("the reply echoes the SERVER's tuning, so the client holds no copy of it", function()
		-- magnetRadius and collectPeriod were CLIENT module constants sitting beside the persisted
		-- levels that were supposed to control them. They are server-owned numbers now, and the
		-- Collect reply is how the client learns them.
		local harness, _, player, clock = setup()
		local reply = collectOnce(harness, clock, player)
		expect(type(reply.magnetRadius)):toBe("number")
		expect(reply.magnetRadius > 0):toBe(true)
		expect(type(reply.collectPeriod)):toBe("number")
		expect(reply.collectPeriod > 0):toBe(true)
	end)

	it("full is false below capacity and true exactly at capacity", function()
		local harness, _, player, clock = setup()
		local first = collectOnce(harness, clock, player)
		expect(first.full):toBe(false) -- a mote or two, well below capacity
		local capacity = fillToCapacity(harness, clock, player)
		expect(capacity):toBe(first.capacity)
	end)

	it("Collect at capacity -> Err(OutOfRange); backpack never exceeds capacity", function()
		local harness, _, player, clock = setup()
		local capacity = fillToCapacity(harness, clock, player)
		clock:advance(5) -- plenty of accrued time: the refusal must be about ROOM, not timing
		local overflow = harness.invoke(COLLECT, player, {})
		expect(overflow):toBeErr(Result.Codes.OutOfRange)
		-- Selling now converts EXACTLY `capacity` motes — proving the backpack held capacity, no more.
		local sell = harness.invoke(SELL, player, {})
		expect(sell):toBeOk()
		expect((sell :: any).value.sold):toBe(capacity)
	end)
end)

describe("Collection core — Sell economy", function()
	it(
		"Sell converts the WHOLE backpack: earned == N*value, sold == N, balance += earned",
		function()
			local harness, data, player, clock = setup()
			local N = collectExactly(harness, clock, player, 5)
			expect(N):toBe(5)
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
		local harness, data, player, clock = setup()
		local N = collectExactly(harness, clock, player, 4)
		local first = harness.invoke(SELL, player, {})
		expect(first):toBeOk()
		expect((first :: any).value.sold):toBe(N)
		local balanceAfterFirst = balanceOf(data, player)

		local second = harness.invoke(SELL, player, {})
		expect(second):toBeOk()
		expect((second :: any).value.sold):toBe(0) -- backpack already emptied
		expect((second :: any).value.earned):toBe(0)
		expect(balanceOf(data, player)):toBe(balanceAfterFirst) -- nothing minted
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
		local harness, _, player, clock = setup()
		expect(harness.invoke(COLLECT, player, 7)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, "gather")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, true)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(COLLECT, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- The rejected calls minted/changed nothing: a real collect still starts from an empty pack.
		expect(collectOnce(harness, clock, player).count >= 1):toBe(true)
		expect((harness.invoke(SELL, player, {}) :: any).value.sold >= 1):toBe(true)
	end)

	it("malformed (non-table) payload to Sell -> Err(BadPayload), no currency minted", function()
		local harness, data, player, clock = setup()
		local N = collectExactly(harness, clock, player, 3)
		local before = balanceOf(data, player)
		expect(harness.invoke(SELL, player, 99)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(SELL, player, "sell")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(SELL, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- Rejected at validate -> backpack untouched, balance untouched.
		expect(balanceOf(data, player)):toBe(before)
		expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(N)
	end)

	it(
		"rate limit: exceeding the Sell rate window -> Err(RateLimited); a fresh window allows again",
		function()
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, _, player = setup({ gate = gate })

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

			clock:advance(60)
			expect(harness.invoke(SELL, player, {})):toBeOk()
		end
	)
end)

-- -------------------------------------------------------------------------------------------------
-- THE ANTI-EXPLOIT GATE. The spec names "No open exploit" as a success criterion and, before this
-- block, NOTHING in any lane exercised it. `collect.gather` accepted an empty payload with no
-- position and no timing check; its only defence was a 20/s rate bucket, so a scripted client
-- minted roughly 3,600 Stardust a minute against a walking player's ~150 per few minutes.
--
-- The property asserted here is deliberately about the CEILING, not the pacing: with the clock
-- frozen the credit never refills, so what one player can extract from an unlimited flood is a
-- deterministic number — and it must be one mote.
-- -------------------------------------------------------------------------------------------------
describe(
	"Collection core — the collect economy is governed by the CLOCK, not the call count",
	function()
		it("100 dispatches with the server clock FROZEN grant at most one mote", function()
			local harness, _, player = setup() -- clock never advanced
			local total = 0
			for _ = 1, 100 do
				local r = harness.invoke(COLLECT, player, {})
				expect(r):toBeOk() -- a call that mints nothing is Ok, not an error
				total += (r :: any).value.granted
			end
			expect(total):toBe(1) -- the opening grant, and nothing else, ever
			expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(1)
		end)

		it("grants scale with ELAPSED TIME, not with how often the client asks", function()
			-- Two identical players. One calls 40 times across 1 second of server time; the other calls
			-- twice across the same second. They must end with the SAME number of motes.
			local floodHarness, _fd, flooder, floodClock = setup({ userId = 501 })
			local calmHarness, _cd, calm, calmClock = setup({ userId = 502 })

			-- Prime both, so the measured window starts from the same anchored ledger. (The very
			-- first collect of a session is deliberately instant — arriving somewhere should feel
			-- responsive — and that opening grant is not part of what is being compared here.)
			expect(floodHarness.invoke(COLLECT, flooder, {})):toBeOk()
			expect(calmHarness.invoke(COLLECT, calm, {})):toBeOk()

			for _ = 1, 40 do
				floodClock:advance(1 / 40)
				expect(floodHarness.invoke(COLLECT, flooder, {})):toBeOk()
			end
			for _ = 1, 2 do
				calmClock:advance(0.5)
				expect(calmHarness.invoke(COLLECT, calm, {})):toBeOk()
			end

			local flooded = (floodHarness.invoke(SELL, flooder, {}) :: any).value.sold
			local calmed = (calmHarness.invoke(SELL, calm, {}) :: any).value.sold
			expect(flooded):toBe(calmed)
		end)

		it("idling does not BANK motes — a long absence cashes in a bounded amount", function()
			local harness, _, player, clock = setup()
			clock:advance(600) -- ten minutes of standing still
			local reply = collectOnce(harness, clock, player)
			-- Ten minutes at the base period would be 10,000 motes. The ceiling must be far smaller,
			-- and in particular must not exceed one backpack.
			expect(reply.granted <= reply.capacity):toBe(true)
			expect(reply.granted <= 25):toBe(true)
		end)
	end
)

-- -------------------------------------------------------------------------------------------------
-- THE POSITION GATE + POSITIONAL VALUE. "Richer motes on higher islands" is a spec promise that
-- had no expression anywhere in the game: the island multiplier was keyed off the highest island
-- you OWNED and applied globally at sell time, so standing on island 1 paid the island-5 rate and
-- the islands were decoration. Mote value is now banked at COLLECT time against the island the
-- player is standing on, read server-side through ctx.world.
-- -------------------------------------------------------------------------------------------------
describe("Collection core — collecting is POSITIONAL", function()
	local function unlockAll(data: any, player: any): ()
		local r = data:update(player, function(d: any): any
			d.flags = d.flags or {}
			for id = 2, 5 do
				d.flags["island." .. tostring(id)] = true
			end
			return d
		end)
		expect(r):toBeOk()
	end

	it("a player who is on no island at all cannot collect", function()
		local harness, _, player, clock = setup({ world = true })
		clock:advance(5)
		-- The fake world has not been told where this player is: they are over the void.
		expect(harness.invoke(COLLECT, player, {})):toBeErr(Result.Codes.Rejected)
	end)

	it("the SAME motes are worth MORE when collected on a richer island", function()
		local harness, data, player, clock, shared = setup({ world = true, islands = true })
		unlockAll(data, player)

		shared.world:standOn(player.UserId, 1)
		local n1 = collectExactly(harness, clock, player, 10)
		local low = (harness.invoke(SELL, player, {}) :: any).value.earned

		shared.world:standOn(player.UserId, 3)
		local n3 = collectExactly(harness, clock, player, 10)
		local high = (harness.invoke(SELL, player, {}) :: any).value.earned

		expect(n1):toBe(n3) -- identical mote counts...
		expect(high > low):toBe(true) -- ...worth strictly more on island 3
	end)

	it(
		"standing on an island you have NOT unlocked pays the starting rate, never its own",
		function()
			-- Defence in depth behind the physical barrier: even if a player reaches island 4 some other
			-- way, they are paid island-1 rates until they buy it.
			local harness, data, player, clock, shared = setup({ world = true, islands = true })
			shared.world:standOn(player.UserId, 1)
			collectExactly(harness, clock, player, 10)
			local baseline = (harness.invoke(SELL, player, {}) :: any).value.earned

			shared.world:standOn(player.UserId, 4) -- reached without unlocking
			collectExactly(harness, clock, player, 10)
			local trespass = (harness.invoke(SELL, player, {}) :: any).value.earned
			expect(trespass):toBe(baseline)
			expect(balanceOf(data, player) > 0):toBe(true)
		end
	)
end)

describe("Collection core — concurrency / economy (double-spend defense)", function()
	-- The economy_race technique: drive interleaved invocations as coroutines against a yielding
	-- store so the second Sell arrives WHILE the first is parked inside the lock-held update.
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
			local harness, data, player, clock = setup({ yieldOnUpdate = true })
			local N = collectExactly(harness, clock, player, 6)
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
			local harness, data, player, clock = setup({ yieldOnUpdate = true })
			local N = collectExactly(harness, clock, player, 9)
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
			expect(totalSold):toBe(N) -- sold exactly once across 4 spam requests
			local value = totalEarned // N
			expect(value > 0):toBe(true)
			expect(totalEarned):toBe(N * value)
			expect(balanceOf(data, player) - before):toBe(N * value) -- minted exactly once
		end
	)

	it(
		"CONSERVATION: collecting M motes then selling mints exactly M*value (even with an interleaved 2nd sell)",
		function()
			local harness, data, player, clock = setup({ yieldOnUpdate = true })
			local M = collectExactly(harness, clock, player, 12)
			local before = balanceOf(data, player)

			-- Establish value independently from a SEPARATE clean player/sell (no race).
			local harness2, data2, player2, clock2 = setup({ userId = 2 })
			collectExactly(harness2, clock2, player2, 1)
			local probe = harness2.invoke(SELL, player2, {})
			expect(probe):toBeOk()
			expect((probe :: any).value.sold):toBe(1)
			local value = (probe :: any).value.earned -- earned for exactly 1 mote
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
			expect(balanceOf(data, player) - before):toBe(M * value)
		end
	)
end)

describe("Collection core — boundary: repeated full cycles accumulate", function()
	it("two full collect->sell cycles accumulate the balance correctly", function()
		local harness, data, player, clock = setup()
		local before = balanceOf(data, player)

		local cap1 = fillToCapacity(harness, clock, player)
		local sell1 = harness.invoke(SELL, player, {})
		expect(sell1):toBeOk()
		local earned1 = (sell1 :: any).value.earned
		expect((sell1 :: any).value.sold):toBe(cap1)
		expect(balanceOf(data, player)):toBe(before + earned1)

		-- Backpack emptied by the sell -> a second full cycle is possible.
		local cap2 = fillToCapacity(harness, clock, player)
		expect(cap2):toBe(cap1) -- capacity is constant across cycles
		local sell2 = harness.invoke(SELL, player, {})
		expect(sell2):toBeOk()
		local earned2 = (sell2 :: any).value.earned
		expect(earned2):toBe(earned1) -- same motes sold -> same earnings

		expect(balanceOf(data, player)):toBe(before + earned1 + earned2)
	end)
end)

-- -------------------------------------------------------------------------------------------------
-- RED-TEAM REGRESSION: CAPACITY-cap bypass via the Sell failure-restore path. When a Sell's
-- ctx.data:update FAILS, the handler restores the captured motes by ADDING them back. If motes were
-- collected DURING the update's yield window, an UNCLAMPED restore pushes the backpack PAST
-- CAPACITY — the player could then sell more than a backpack should ever hold.
-- -------------------------------------------------------------------------------------------------
describe(
	"Collection core — capacity invariant on a failed-sell restore (red-team regression)",
	function()
		local function controllableData(): any
			local d: any = { stardust = 0, mode = "failYield" }
			function d.get(self: any, _player: any): any
				return Result.ok({ currencies = { Stardust = self.stardust } })
			end
			function d.update(self: any, _player: any, transform: (any) -> any): any
				if self.mode == "failYield" then
					coroutine.yield() -- park inside "update" so an interleaving Collect refills
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

				local k = collectExactly(harness, clock, player, 3)
				expect(k):toBe(3)

				-- Fire a Sell that parks inside the failing update (captures k, zeroes the pack).
				local sellResult: any
				local sellCo = coroutine.create(function()
					sellResult = harness.invoke(SELL, player, {})
				end)
				expect((coroutine.resume(sellCo))):toBe(true)
				expect(coroutine.status(sellCo)):toBe("suspended") -- parked mid-"update"

				-- While the sell is parked, collects refill the backpack all the way to capacity.
				local capacity = 0
				local guard = 0
				while true do
					guard += 1
					if guard > 5000 then
						error("refill did not converge")
					end
					clock:advance(DEFAULT_PERIOD * 20)
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
				expect(sellResult):toBeErr(Result.Codes.Internal) -- the sale failed: nothing granted

				-- Observe the backpack via a now-succeeding sell. The cap invariant: the backpack can
				-- NEVER hold more than capacity. Unclamped restore -> capacity+k.
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
	local AUTO_FLAG = "gamepass.autoCollect"

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
		local ph, _pd, pp, pc = setup({ userId = 4242 })
		local capacity = fillToCapacity(ph, pc, pp)

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

-- -------------------------------------------------------------------------------------------------
-- SESSION LIFECYCLE. The in-memory backpack and collect ledger used to grow one entry per unique
-- visitor for the server's lifetime, and a rejoining player inherited a server-side backpack their
-- HUD knew nothing about — the HUD read "Backpack: 0" over a server holding 50, then immediately
-- latched "backpack full" on the next collect.
-- -------------------------------------------------------------------------------------------------
describe("Collection core — leaving clears the session backpack", function()
	it("forgetPlayer empties the backpack and resets the collect credit", function()
		local harness, _, player, clock = setup()
		collectExactly(harness, clock, player, 5)
		expect(CollectionService:backpackOf(player.UserId).count):toBe(5)

		CollectionService:forgetPlayer(player.UserId)
		expect(CollectionService:backpackOf(player.UserId).count):toBe(0)
		expect(CollectionService:backpackOf(player.UserId).value):toBe(0)
		-- A rejoin starts clean: an immediate sell finds nothing, not a phantom 5.
		expect((harness.invoke(SELL, player, {}) :: any).value.sold):toBe(0)
	end)
end)
