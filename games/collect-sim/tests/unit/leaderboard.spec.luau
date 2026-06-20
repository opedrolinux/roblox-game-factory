--!strict
-- games/collect-sim/tests/unit/leaderboard.spec.luau   [INDEPENDENT TEST GATE — authored from the leaderboard spec slice]
-- Adversarial Tier-1 gate for the "Leaderboard" feature. Authored from the SPEC's behavioral
-- guarantees, NOT from the implementation's branch logic (maker != checker). The spec slice:
--   * Top players by LIFETIME Stardust: ranks present players by the stats.lifetimeStardust field
--     (the contract-pass monotonic earn aggregate), NOT the spent-down currencies.Stardust.
--   * READ-ONLY: only READS lifetimeStardust across present players, builds an in-world ranking,
--     exposes a read-only fetch returning the current top-N ranking, refreshes on a server-time
--     interval. It does NOT compute or write lifetimeStardust. No economy mutation. No analytics.
--   * Success: an in-world leaderboard ranks players by lifetime Stardust.
--
-- We drive the SAME action production exposes: call Start({ net = harness.registry }) so the
-- FetchLeaderboard action registers onto a Mocks.net harness, then invoke through the REAL
-- Net.dispatch. Because LeaderboardService is a singleton module table (no .new), Start's `self`
-- IS the module table, and the registered handler closes over that same instance — so driving
-- refresh/maybeRefresh on the module table mutates the exact snapshot the fetch handler returns.
--
-- The cross-player snapshot is rebuilt by refresh(now, players, dataGet): the runtime driver
-- (Roblox-only) feeds the live Players list; here a spec feeds FAKE players + a fake getter, EXACTLY
-- as the implementation comment documents. We assert ONLY spec guarantees: ranking by lifetime (not
-- spendable), top-N truncation, server-time cadence, read-only-ness, malformed payload rejection,
-- the rate gate, and — via the economy_race technique — that an interleaved fetch can NEVER mint or
-- double-spend currency (a pure reader holds no lock and writes nothing).
--
-- Constants (TOP_N, REFRESH_INTERVAL) are DISCOVERED through the observable API, never copied from
-- the implementation source.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local LeaderboardService = require("../../src/server/services/leaderboard/LeaderboardService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local FETCH = Net.Actions.FetchLeaderboard -- "leaderboard.fetch"

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- A fake per-player data getter built from a {userId -> lifetimeStardust} (and optional spendable)
-- map. Returns a Result<PlayerData>-shaped value EXACTLY like ctx.data:get would: ok with a stats
-- table. This is the cross-player read path the refresh consumes (production binds ctx.data:get).
type FakeSpec = { lifetime: number?, spendable: number?, missing: boolean?, badStats: boolean? }
local function fakeGetter(byUserId: { [number]: FakeSpec }): (any) -> any
	return function(player: any): any
		local spec = byUserId[player.UserId]
		if spec == nil or spec.missing then
			-- model an unloaded player: get -> Err (the impl must degrade this to 0, never crash).
			return Result.err(Result.Codes.NoData, "not loaded")
		end
		local data: any = {
			currencies = { Stardust = spec.spendable or 0 },
			stats = { lifetimeStardust = spec.lifetime or 0 },
		}
		if spec.badStats then
			data.stats = nil -- absent stats must contribute 0, not crash the rebuild.
		end
		return Result.ok(data)
	end
end

-- Stand up the leaderboard onto a fresh Mocks.net harness. gate defaults to false so behavior is
-- isolated from the rate gate (a focused rate test passes its own real gate). Start's self is the
-- module table; we return it so the spec can drive refresh/maybeRefresh on the SAME instance whose
-- handler closure the fetch invokes. Each setup re-inits the snapshot to empty (Start sets it).
local function setup(opts: any?): (any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(o.startUnix or 1000)
	local harnessOpts: any = { clock = clock }
	if o.gate ~= nil then
		harnessOpts.gate = o.gate
	else
		harnessOpts.gate = false
	end
	local harness = Mocks.net(harnessOpts)
	LeaderboardService:Start({ net = harness.registry })
	return harness, clock, LeaderboardService
end

-- Invoke the read-only fetch and return its entries array (asserting Ok along the way).
local function fetchEntries(harness: any, player: any): { any }
	local r = harness.invoke(FETCH, player, {})
	expect(r):toBeOk()
	return (r :: any).value.entries
end

-- Build N fake players { UserId, Name }. Names are stable so we can assert identity.
local function makePlayers(userIds: { number }): { any }
	local out: { any } = {}
	for _, id in userIds do
		table.insert(out, Mocks.player(id))
	end
	return out
end

describe("Leaderboard — ranks present players by lifetime Stardust (descending)", function()
	it("orders entries by lifetimeStardust DESCENDING, with 1-based ranks", function()
		local harness, clock, svc = setup()
		local players = makePlayers({ 10, 20, 30 })
		local getter = fakeGetter({
			[10] = { lifetime = 50 },
			[20] = { lifetime = 300 },
			[30] = { lifetime = 150 },
		})
		svc:refresh(clock:unix(), players, getter)

		local entries = fetchEntries(harness, Mocks.player(10))
		expect(#entries):toBe(3)
		-- highest lifetime first.
		expect(entries[1].userId):toBe(20)
		expect(entries[1].lifetimeStardust):toBe(300)
		expect(entries[1].rank):toBe(1)
		expect(entries[2].userId):toBe(30)
		expect(entries[2].lifetimeStardust):toBe(150)
		expect(entries[2].rank):toBe(2)
		expect(entries[3].userId):toBe(10)
		expect(entries[3].lifetimeStardust):toBe(50)
		expect(entries[3].rank):toBe(3)
	end)

	it("each entry carries the player's userId + name from the present-player list", function()
		local harness, clock, svc = setup()
		local players = { Mocks.player(7, "Alice"), Mocks.player(8, "Bob") }
		svc:refresh(
			clock:unix(),
			players,
			fakeGetter({ [7] = { lifetime = 10 }, [8] = { lifetime = 20 } })
		)
		local entries = fetchEntries(harness, Mocks.player(7))
		expect(entries[1].userId):toBe(8)
		expect(entries[1].name):toBe("Bob")
		expect(entries[2].userId):toBe(7)
		expect(entries[2].name):toBe("Alice")
	end)

	it(
		"a present player with the SAME spendable but more lifetime outranks — it is LIFETIME, not spendable",
		function()
			-- THE headline distinction: rank by stats.lifetimeStardust, NOT currencies.Stardust.
			-- Player A has spent down to 0 spendable but earned 1000 lifetime; player B is a fresh
			-- whale with 999 spendable but only 5 lifetime. The earner (A) MUST rank above the holder (B).
			-- If the impl ranked by currencies.Stardust, B (999) would wrongly top A (0) — this FAILS that.
			local harness, clock, svc = setup()
			local players = makePlayers({ 1, 2 })
			local getter = fakeGetter({
				[1] = { lifetime = 1000, spendable = 0 }, -- big earner, spent it all
				[2] = { lifetime = 5, spendable = 999 }, -- holds a lot, earned little
			})
			svc:refresh(clock:unix(), players, getter)
			local entries = fetchEntries(harness, Mocks.player(1))
			expect(entries[1].userId):toBe(1) -- the lifetime earner tops the board
			expect(entries[1].lifetimeStardust):toBe(1000)
			expect(entries[2].userId):toBe(2)
			expect(entries[2].lifetimeStardust):toBe(5) -- reports lifetime, never the 999 spendable
		end
	)

	it("ties break deterministically (the board does not flicker between equal earners)", function()
		-- Two equal earners must order STABLY across repeated fetches (no nondeterministic flicker).
		local harness, clock, svc = setup()
		local players = makePlayers({ 99, 11, 55 })
		local getter = fakeGetter({
			[99] = { lifetime = 100 },
			[11] = { lifetime = 100 },
			[55] = { lifetime = 100 },
		})
		svc:refresh(clock:unix(), players, getter)
		local first = fetchEntries(harness, Mocks.player(11))
		local second = fetchEntries(harness, Mocks.player(11))
		-- identical order on two reads of the same snapshot: deterministic.
		for i = 1, 3 do
			expect(first[i].userId):toBe(second[i].userId)
		end
		-- and all three are present exactly once.
		local seen: { [number]: boolean } = {}
		for _, e in first do
			expect(seen[e.userId]).never:toBe(true)
			seen[e.userId] = true
		end
	end)
end)

describe("Leaderboard — top-N truncation (the board shows only the top slice)", function()
	-- Discover TOP_N through the API: feed strictly-descending lifetimes to MANY players; the fetch
	-- returns at most TOP_N, and the returned slice is exactly the highest earners in order.
	local function discoverTopN(): number
		local harness, clock, svc = setup()
		local ids: { number } = {}
		local specs: { [number]: FakeSpec } = {}
		-- 40 players, each with a unique strictly-rising lifetime (id*10), far more than any sane TOP_N.
		for id = 1, 40 do
			table.insert(ids, id)
			specs[id] = { lifetime = id * 10 }
		end
		svc:refresh(clock:unix(), makePlayers(ids), fakeGetter(specs))
		return #fetchEntries(harness, Mocks.player(1))
	end

	it("with far more present players than the cap, fetch returns exactly TOP_N entries", function()
		local n = discoverTopN()
		expect(n >= 1):toBe(true)
		expect(n < 40):toBe(true) -- it DID truncate (not all 40 leaked)
	end)

	it(
		"the truncated slice is the HIGHEST earners, in descending order, ranks 1..N contiguous",
		function()
			local harness, clock, svc = setup()
			local n = discoverTopN()
			local ids: { number } = {}
			local specs: { [number]: FakeSpec } = {}
			for id = 1, 40 do
				table.insert(ids, id)
				specs[id] = { lifetime = id * 10 } -- id 40 is the richest (400), id 1 the poorest (10)
			end
			svc:refresh(clock:unix(), makePlayers(ids), fakeGetter(specs))
			local entries = fetchEntries(harness, Mocks.player(1))
			expect(#entries):toBe(n)
			-- rank 1 is the global max (id 40 -> 400); strictly descending; ranks contiguous 1..n.
			expect(entries[1].userId):toBe(40)
			expect(entries[1].lifetimeStardust):toBe(400)
			for i = 1, n do
				expect(entries[i].rank):toBe(i)
				if i > 1 then
					expect(entries[i - 1].lifetimeStardust > entries[i].lifetimeStardust):toBe(true)
				end
			end
			-- the LOWEST earners (below the cut) are absent: id 1 (lifetime 10) is not on the board.
			for _, e in entries do
				expect(e.userId == 1).never:toBe(true)
			end
		end
	)

	it(
		"fewer present players than the cap -> the board has exactly that many (no padding)",
		function()
			local harness, clock, svc = setup()
			svc:refresh(
				clock:unix(),
				makePlayers({ 3, 4 }),
				fakeGetter({ [3] = { lifetime = 9 }, [4] = { lifetime = 8 } })
			)
			expect(#fetchEntries(harness, Mocks.player(3))):toBe(2)
		end
	)

	it("an empty server (no present players) -> an empty board, not an error", function()
		local harness, clock, svc = setup()
		svc:refresh(clock:unix(), {}, fakeGetter({}))
		local entries = fetchEntries(harness, Mocks.player(1))
		expect(#entries):toBe(0)
	end)

	it("before any refresh (fresh Start), fetch returns an empty board, not nil/crash", function()
		local harness = setup()
		-- no refresh driven: the snapshot is the empty init from Start.
		local entries = fetchEntries(harness, Mocks.player(1))
		expect(#entries):toBe(0)
	end)
end)

describe(
	"Leaderboard — degrades missing/malformed player data to 0 (never crashes, never skews)",
	function()
		it(
			"a present player whose get -> Err contributes 0 and still appears (present-but-not-earned)",
			function()
				local harness, clock, svc = setup()
				local players = makePlayers({ 1, 2 })
				-- player 2's data is not loaded (get -> Err). It must show as 0, never crash, never poison rank.
				local getter = fakeGetter({ [1] = { lifetime = 100 }, [2] = { missing = true } })
				svc:refresh(clock:unix(), players, getter)
				local entries = fetchEntries(harness, Mocks.player(1))
				expect(#entries):toBe(2)
				expect(entries[1].userId):toBe(1)
				expect(entries[1].lifetimeStardust):toBe(100)
				expect(entries[2].userId):toBe(2)
				expect(entries[2].lifetimeStardust):toBe(0) -- degraded to 0, present, not dropped
			end
		)

		it("absent stats table contributes 0 without poisoning another player's rank", function()
			local harness, clock, svc = setup()
			local players = makePlayers({ 1, 2 })
			local getter = fakeGetter({ [1] = { badStats = true }, [2] = { lifetime = 42 } })
			svc:refresh(clock:unix(), players, getter)
			local entries = fetchEntries(harness, Mocks.player(2))
			expect(entries[1].userId):toBe(2) -- the real earner still ranks first
			expect(entries[1].lifetimeStardust):toBe(42)
			expect(entries[2].lifetimeStardust):toBe(0)
		end)

		it(
			"a NaN lifetime can never sort sanely -> treated as 0, the board stays consistent",
			function()
				local harness, clock, svc = setup()
				local players = makePlayers({ 1, 2 })
				-- player 1 supplies a NaN lifetime; it must be neutralized to 0, not poison the comparator.
				local getter = function(player: any): any
					if player.UserId == 1 then
						return Result.ok({ stats = { lifetimeStardust = 0 / 0 } })
					end
					return Result.ok({ stats = { lifetimeStardust = 77 } })
				end
				svc:refresh(clock:unix(), players, getter)
				local entries = fetchEntries(harness, Mocks.player(2))
				expect(#entries):toBe(2)
				-- 77 outranks the neutralized NaN(->0); every reported lifetime is a real (non-NaN) number.
				expect(entries[1].userId):toBe(2)
				expect(entries[1].lifetimeStardust):toBe(77)
				for _, e in entries do
					expect(e.lifetimeStardust == e.lifetimeStardust):toBe(true) -- not NaN
				end
			end
		)
	end
)

describe(
	"Leaderboard — refreshes on a SERVER-TIME interval (cadence is server clock, never wall)",
	function()
		-- Discover REFRESH_INTERVAL through maybeRefresh's observable cadence: maybeRefresh returns true
		-- iff it rebuilt this call. The first call always rebuilds; a call within the interval is coalesced
		-- (returns false); a call at/after the interval rebuilds again.
		it("the FIRST maybeRefresh always rebuilds (returns true)", function()
			local _harness, clock, svc = setup()
			expect(
				svc:maybeRefresh(
					clock:unix(),
					makePlayers({ 1 }),
					fakeGetter({ [1] = { lifetime = 1 } })
				)
			):toBe(true)
		end)

		it(
			"a second maybeRefresh BEFORE the interval elapses is coalesced (returns false, snapshot unchanged)",
			function()
				local harness, clock, svc = setup()
				local g1 = fakeGetter({ [1] = { lifetime = 100 } })
				expect(svc:maybeRefresh(clock:unix(), makePlayers({ 1 }), g1)):toBe(true)
				local first = fetchEntries(harness, Mocks.player(1))
				expect(first[1].lifetimeStardust):toBe(100)

				-- advance only a tiny bit (well under any sane interval) and feed a DIFFERENT value.
				clock:advance(0.001)
				local g2 = fakeGetter({ [1] = { lifetime = 999999 } })
				expect(svc:maybeRefresh(clock:unix(), makePlayers({ 1 }), g2)):toBe(false)
				-- coalesced: the board still shows the OLD value, not the would-be new one.
				expect(fetchEntries(harness, Mocks.player(1))[1].lifetimeStardust):toBe(100)
			end
		)

		it(
			"after enough SERVER time elapses, maybeRefresh rebuilds again and the snapshot updates",
			function()
				local harness, clock, svc = setup()
				svc:maybeRefresh(
					clock:unix(),
					makePlayers({ 1 }),
					fakeGetter({ [1] = { lifetime = 100 } })
				)
				-- Discover the interval by advancing server time until maybeRefresh rebuilds again. A generous
				-- ceiling bounds the search; if it never rebuilds within it, the cadence is broken (caught here).
				local rebuilt = false
				local advanced = 0
				for _ = 1, 100 do
					clock:advance(1)
					advanced += 1
					if
						svc:maybeRefresh(
							clock:unix(),
							makePlayers({ 1 }),
							fakeGetter({ [1] = { lifetime = 500 } })
						)
					then
						rebuilt = true
						break
					end
				end
				expect(rebuilt):toBe(true) -- it DID re-gate on server time and rebuild
				expect(advanced >= 1):toBe(true)
				-- the rebuilt snapshot now reflects the new value.
				expect(fetchEntries(harness, Mocks.player(1))[1].lifetimeStardust):toBe(500)
			end
		)

		it("maybeRefresh re-gates on the SERVER clock argument, not wall/os time", function()
			-- Two maybeRefresh calls at the SAME server-time value (clock not advanced) -> the second is
			-- always coalesced, proving the gate reads the passed server `now`, not real elapsed wall time.
			local _harness, clock, svc = setup()
			local now = clock:unix()
			expect(
				svc:maybeRefresh(now, makePlayers({ 1 }), fakeGetter({ [1] = { lifetime = 1 } }))
			):toBe(true)
			expect(
				svc:maybeRefresh(now, makePlayers({ 1 }), fakeGetter({ [1] = { lifetime = 1 } }))
			):toBe(false)
		end)
	end
)

describe(
	"Leaderboard — malformed / abusive fetch payloads (BadPayload, no state change)",
	function()
		it("non-table payload -> Err(BadPayload); the handler never runs", function()
			local harness, clock, svc = setup()
			svc:refresh(clock:unix(), makePlayers({ 1 }), fakeGetter({ [1] = { lifetime = 10 } }))
			local player = Mocks.player(1)
			expect(harness.invoke(FETCH, player, 5)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(FETCH, player, "top")):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(FETCH, player, true)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(FETCH, player, nil)):toBeErr(Result.Codes.BadPayload)
		end)

		it(
			"a smuggled client count/userId/score is IGNORED — the server decides N and the ranking",
			function()
				-- The client cannot widen the board or inject a fake score: extra fields are never read.
				-- A payload with a huge count + a fake score must return the SAME board as a clean empty intent.
				local harness, clock, svc = setup()
				local ids: { number } = {}
				local specs: { [number]: FakeSpec } = {}
				for id = 1, 30 do
					table.insert(ids, id)
					specs[id] = { lifetime = id }
				end
				svc:refresh(clock:unix(), makePlayers(ids), fakeGetter(specs))
				local clean = fetchEntries(harness, Mocks.player(1))
				local abusive = harness.invoke(FETCH, Mocks.player(1), {
					count = 9999, -- "show me everyone", please
					n = 9999,
					userId = 1, -- "put ME first", please
					lifetimeStardust = 999999999, -- a fake score, please
				})
				expect(abusive):toBeOk()
				local abusiveEntries = (abusive :: any).value.entries
				-- identical count and identical top entry: the client's smuggled fields changed NOTHING.
				expect(#abusiveEntries):toBe(#clean)
				expect(abusiveEntries[1].userId):toBe(clean[1].userId)
				expect(abusiveEntries[1].lifetimeStardust):toBe(clean[1].lifetimeStardust)
				-- the requesting player did NOT get hoisted to rank 1 by the smuggled userId.
				expect(abusiveEntries[1].lifetimeStardust):toBe(30) -- still the real top earner, not 999999999
			end
		)

		it("an empty-table intent is the accepted happy path -> Ok", function()
			local harness, clock, svc = setup()
			svc:refresh(clock:unix(), makePlayers({ 1 }), fakeGetter({ [1] = { lifetime = 10 } }))
			expect(harness.invoke(FETCH, Mocks.player(1), {})):toBeOk()
		end)
	end
)

describe("Leaderboard — rate limit (a spammer cannot abuse the UI poll)", function()
	it(
		"hammering FetchLeaderboard past the action's rate window -> Err(RateLimited); refills after window",
		function()
			-- A REAL gate + injected clock enforces the action's own RatePolicy (a UI poll: generous, but
			-- still shed). Each allowed call is a clean Ok read; once exhausted the gate sheds.
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, _clock2, svc = setup({ gate = gate })
			svc:refresh(clock:unix(), makePlayers({ 1 }), fakeGetter({ [1] = { lifetime = 10 } }))
			local player = Mocks.player(1)

			local hitRateLimit = false
			local allowed = 0
			for _ = 1, 100 do
				local r = harness.invoke(FETCH, player, {})
				if not r.ok and r.code == Result.Codes.RateLimited then
					hitRateLimit = true
					break
				end
				expect(r):toBeOk() -- before shedding: a clean read, never an error
				allowed += 1
			end
			expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
			expect(allowed > 0):toBe(true)

			clock:advance(60) -- refill the window
			expect(harness.invoke(FETCH, player, {})):toBeOk() -- through the gate again
		end
	)

	it(
		"rate buckets are per (player, action): a second player is unaffected by the first's spam",
		function()
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, _clock2, svc = setup({ gate = gate })
			svc:refresh(
				clock:unix(),
				makePlayers({ 1, 2 }),
				fakeGetter({ [1] = { lifetime = 10 }, [2] = { lifetime = 20 } })
			)
			local p1 = Mocks.player(1)
			local p2 = Mocks.player(2)
			-- spam p1 until it sheds.
			for _ = 1, 100 do
				local r = harness.invoke(FETCH, p1, {})
				if not r.ok and r.code == Result.Codes.RateLimited then
					break
				end
			end
			expect(harness.invoke(FETCH, p1, {})):toBeErr(Result.Codes.RateLimited)
			-- p2's independent bucket still serves a clean read.
			expect(harness.invoke(FETCH, p2, {})):toBeOk()
		end
	)
end)

describe(
	"Leaderboard — READ-ONLY: it NEVER mutates currency or lifetimeStardust (no mint, no sink)",
	function()
		-- The strongest economy guarantee: the leaderboard does ZERO economy mutation. We drive a REAL
		-- DataService over a MockStore as the cross-player read source, snapshot the economy before, run
		-- many refreshes + fetches, and assert NOTHING the reader touched changed — not the spendable
		-- balance, not the lifetime aggregate, not for the read player nor any other present player.
		local function dataSetup(
			seedByUserId: { [number]: { lifetime: number, spendable: number } }
		): (any, any, { any })
			local clock = Mocks.clock(1000)
			local cfg = config()
			local store = Mocks.store({ clock = clock, config = cfg })
			local data = DataService.new(store, clock, cfg, Mocks.logWarn)
			local players: { any } = {}
			for userId, seed in seedByUserId do
				local player = Mocks.player(userId)
				data:loadSession(player)
				-- seed lifetime + spendable through the canonical write path (the ONLY writer here is US, the test).
				data:update(player, function(d)
					d.currencies.Stardust = seed.spendable
					d.stats.lifetimeStardust = seed.lifetime
					return d
				end)
				table.insert(players, player)
			end
			return data, clock, players
		end

		it(
			"refresh + repeated fetch leave every present player's lifetime AND spendable UNCHANGED",
			function()
				local data, clock, players = dataSetup({
					[1] = { lifetime = 1000, spendable = 7 },
					[2] = { lifetime = 50, spendable = 4000 },
				})
				local harness = Mocks.net({ clock = clock, data = data, gate = false })
				LeaderboardService:Start({ net = harness.registry })
				local dataGet = function(player: any): any
					return data:get(player)
				end

				-- snapshot economy BEFORE.
				local function snap(): { [number]: { number } }
					local out: { [number]: { number } } = {}
					for _, p in players do
						local d = (data:get(p) :: any).value
						out[p.UserId] = { d.currencies.Stardust, d.stats.lifetimeStardust }
					end
					return out
				end
				local before = snap()

				-- run MANY refreshes + fetches (the read path, hard).
				for _ = 1, 25 do
					LeaderboardService:refresh(clock:unix(), players, dataGet)
					for _, p in players do
						expect(harness.invoke(FETCH, p, {})):toBeOk()
					end
					clock:advance(10)
				end

				-- economy is byte-identical: the reader minted nothing, spent nothing, wrote no lifetime.
				local after = snap()
				for _, p in players do
					expect(after[p.UserId][1]):toBe(before[p.UserId][1]) -- spendable unchanged
					expect(after[p.UserId][2]):toBe(before[p.UserId][2]) -- lifetime unchanged
				end
				-- and the board ranked by the (untouched) lifetime: player 1 (1000) tops player 2 (50).
				local entries = (harness.invoke(FETCH, players[1], {}) :: any).value.entries
				table.sort(entries, function(a, b)
					return a.rank < b.rank
				end)
				expect(entries[1].userId):toBe(1)
				expect(entries[1].lifetimeStardust):toBe(1000)
			end
		)

		it(
			"fetch reports lifetime but does NOT couple to the spendable balance (read source is lifetime)",
			function()
				-- player 2 holds a huge spendable but tiny lifetime; the board must report lifetime (50), and
				-- must NOT have changed that spendable just by being read.
				local data, clock, players = dataSetup({
					[1] = { lifetime = 1000, spendable = 0 },
					[2] = { lifetime = 50, spendable = 999999 },
				})
				local harness = Mocks.net({ clock = clock, data = data, gate = false })
				LeaderboardService:Start({ net = harness.registry })
				LeaderboardService:refresh(clock:unix(), players, function(p: any)
					return data:get(p)
				end)
				local entries = (harness.invoke(FETCH, players[1], {}) :: any).value.entries
				local byUser: { [number]: number } = {}
				for _, e in entries do
					byUser[e.userId] = e.lifetimeStardust
				end
				expect(byUser[2]):toBe(50) -- reports lifetime, NOT the 999999 spendable
				-- the read did not touch player 2's spendable.
				expect((data:get(players[2]) :: any).value.currencies.Stardust):toBe(999999)
			end
		)
	end
)

describe("Leaderboard — pure-reader integrity: stable snapshots, no economy surface", function()
	-- WHY NO economy_race / FIFO-lock interleaving test lives here: an economy race is the wrong tool
	-- for a PURE READER. LeaderboardService does ZERO ctx.data:update — it holds no lock and its read
	-- path (refresh -> topN -> rankTopN) is fully synchronous with no yields, so under any coroutine
	-- driver it runs to completion in a single resume and cannot GENUINELY interleave with a competing
	-- writer. A "the spend applies exactly once" assertion driven that way is tautological: the spend is
	-- the only writer and is uncontended, so it would pass identically if called sequentially. The real
	-- economy guarantee a reader CAN make — that many refreshes + fetches mutate NOTHING (no mint, no
	-- sink, lifetime + spendable byte-identical) — is already proven over 25 real cycles in the
	-- read-only describe block above ("refresh + repeated fetch leave every present player's lifetime
	-- AND spendable UNCHANGED"); we do NOT duplicate it. What IS falsifiable and untested is the
	-- reader's OWN contract: every board it hands out is a fresh, caller-owned COPY decoupled from the
	-- owned _snapshot, and refresh REPLACES that snapshot wholesale. Those are the properties below.

	it(
		"topN returns a fresh, caller-owned board (vandalizing it cannot corrupt a later fetch)",
		function()
			-- rankTopN copies the rows and builds FRESH Entry tables each call, so a returned board is the
			-- caller's to mutate. If topN aliased the owned snapshot (or shared Entry tables across calls),
			-- vandalizing board1 would bleed into board2 — this test FAILS in that broken impl.
			local harness, clock, svc = setup()
			local players = makePlayers({ 10, 20, 30 })
			local getter = fakeGetter({
				[10] = { lifetime = 50 },
				[20] = { lifetime = 300 },
				[30] = { lifetime = 150 },
			})
			svc:refresh(clock:unix(), players, getter)

			local board1 = fetchEntries(harness, Mocks.player(10))
			expect(#board1):toBe(3)
			-- VANDALIZE the caller's copy: corrupt a value and tear a row out.
			board1[1].lifetimeStardust = -999
			table.remove(board1, 2)
			expect(#board1):toBe(2) -- the vandalized copy is genuinely mangled

			-- a fresh fetch must be wholly intact — it cannot have aliased the mutated board1.
			local board2 = fetchEntries(harness, Mocks.player(10))
			expect(#board2):toBe(3)
			expect(board2[1].userId):toBe(20)
			expect(board2[1].lifetimeStardust):toBe(300) -- NOT the -999 we wrote into board1
			expect(board2[2].userId):toBe(30)
			expect(board2[3].userId):toBe(10)
			for i = 1, 3 do
				expect(board2[i].rank):toBe(i) -- ranks 1..3 contiguous
			end
		end
	)

	it(
		"an earlier board is decoupled from a later refresh (a returned board is a stable copy)",
		function()
			-- refresh REPLACES _snapshot wholesale and rankTopN snapshots fresh Entry tables, so a board
			-- handed out before a refresh must be frozen at the values it was built from. If a returned board
			-- aliased the live _snapshot, refreshing to set B would retroactively mutate `before` — FAILS here.
			local harness, clock, svc = setup()
			-- set A.
			svc:refresh(
				clock:unix(),
				makePlayers({ 1, 2 }),
				fakeGetter({ [1] = { lifetime = 100 }, [2] = { lifetime = 40 } })
			)
			local before = fetchEntries(harness, Mocks.player(1))
			expect(before[1].userId):toBe(1)
			expect(before[1].lifetimeStardust):toBe(100) -- reflects set A
			expect(before[2].userId):toBe(2)
			expect(before[2].lifetimeStardust):toBe(40)

			-- set B at a LATER server time: same players, different lifetimes.
			clock:advance(10)
			svc:refresh(
				clock:unix(),
				makePlayers({ 1, 2 }),
				fakeGetter({ [1] = { lifetime = 7 }, [2] = { lifetime = 9999 } })
			)

			-- the earlier board is UNCHANGED — a stable copy, not a window onto the live snapshot.
			expect(before[1].userId):toBe(1)
			expect(before[1].lifetimeStardust):toBe(100)
			expect(before[2].userId):toBe(2)
			expect(before[2].lifetimeStardust):toBe(40)

			-- a fresh fetch reflects set B (now player 2 tops, with the new lifetimes).
			local after = fetchEntries(harness, Mocks.player(1))
			expect(after[1].userId):toBe(2)
			expect(after[1].lifetimeStardust):toBe(9999)
			expect(after[2].userId):toBe(1)
			expect(after[2].lifetimeStardust):toBe(7)
		end
	)

	it(
		"churn — a departed player drops off the board (refresh REPLACES, never merges)",
		function()
			-- refresh sets self._snapshot = rows wholesale, so a player absent from the new present-player
			-- list vanishes from the next board. If refresh MERGED into the prior snapshot instead, the
			-- departed player 3 would linger — this test FAILS that broken (merging) impl.
			local harness, clock, svc = setup()
			svc:refresh(
				clock:unix(),
				makePlayers({ 1, 2, 3 }),
				fakeGetter({
					[1] = { lifetime = 30 },
					[2] = { lifetime = 20 },
					[3] = { lifetime = 10 },
				})
			)
			expect(#fetchEntries(harness, Mocks.player(1))):toBe(3)

			-- player 3 leaves: the present-player list is now just {1, 2}.
			clock:advance(10)
			svc:refresh(
				clock:unix(),
				makePlayers({ 1, 2 }),
				fakeGetter({ [1] = { lifetime = 30 }, [2] = { lifetime = 20 } })
			)

			local entries = fetchEntries(harness, Mocks.player(1))
			expect(#entries):toBe(2) -- exactly two — the snapshot was replaced, not merged
			for _, e in entries do
				expect(e.userId == 3).never:toBe(true) -- the departed player is gone
			end
		end
	)
end)
