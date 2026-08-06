--!strict
-- games/deep-reach/tests/unit/daily.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/daily.md, NOT from
--  DailyDropService's control flow. The implementation was read ONLY to learn its observable
--  interface (method names, return shape, the names of its exported constants); every EXPECTATION
--  below is derived from the slice, and every reward number is DISCOVERED through the public API
--  (rewardFor / the exported window constants) rather than copied out of the module.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   * "The `daily.claim` action: server-clock gated. Refuse with Err(OnCooldown) until the window
--      opens; grant on a valid claim; never trust any client-supplied time (the payload carries no
--      timestamp at all)."
--   * "The 20-22h claim window, evaluated ONLY against ctx.clock:unix() and the persisted
--      daily.lastClaimUnix. The claim opens once 20h have elapsed since the last claim. A claim made
--      while the window is open continues the streak (streak += 1); a player who lets the window
--      lapse comes back to a reset streak (streak = 1)."
--   * "Both bounds are server-derived constants in your module — the client never sends or
--      influences them."
--   * "The escalating reward: Credits granted as a server-derived function of the streak, with a
--      documented cap so an unbounded streak cannot mint an unbounded balance. Grant through
--      ctx.economy:earn (which increments stats.lifetimeCredits and emits currency_earned) inside
--      ONE DataService:update."
--   * "Concurrency: two claims in the same frame must grant exactly once — the window check and the
--      lastClaimUnix stamp happen in the same lock-held transform, never read-then-write across a
--      yield."
--   * "the HUD badge showing streak and time-until-next-claim, driven from the replicated PlayerView
--      (daily rides toView)."
--   * PERSISTENCE: "daily: { streak: number, lastClaimUnix: number } at schema v3->v4 ...
--      lastClaimUnix is SERVER unix time."
--   * NOT THIS SLICE: offline accrual, the rich wreck / restock, any structure or depth purchase —
--      so a claim must move Credits and daily ONLY.
--
-- WHY THE ECONOMY CASES ASSERT DELTAS. A daily drop is a pure MINT: it is the one path in this
-- feature that creates currency from nothing but a clock. So every case below reads the balance,
-- stats.lifetimeCredits and daily.lastClaimUnix BEFORE and AFTER, and compares — never "a write
-- happened". A refusal that quietly stamped the window, or a grant that skipped the lifetime
-- counter, would pass a write-only assertion and is red here.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The slice names the lock-held transform as the
-- mechanism, so the headline race is driven the way economy_race.spec drives the economy: a
-- MockStore with `yieldOnUpdate` (a forced yield inside the update critical section) plus a
-- round-robin coroutine driver. The service ALSO carries an in-memory single-flight reservation,
-- which would short-circuit the interleave before it ever reaches the data layer and make the race
-- test vacuous — so the headline case NEUTRALISES that reservation and proves the transform alone
-- grants exactly once, which is precisely the guarantee the slice states. A falsification
-- counter-case (a decide-then-yield-then-write daily, driven at the same yield point) double-grants,
-- proving the interleave is real.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DailyDropService = require("../../src/server/services/daily/DailyDropService")
local DataService = require("../../src/server/data/DataService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Migrations = require("../../src/shared/Migrations")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- ── the window constants, as the SLICE states them ──────────────────────────────────────────────
-- The slice fixes these numbers ("the 20-22h claim window", "opens once 20h have elapsed"), so they
-- are asserted here once and then used as the arithmetic basis for every later case. If the module
-- ever moves a bound, exactly one test goes red and names the reason.
local HOUR = 3600
local OPENS: number = DailyDropService.CLAIM_OPENS_AFTER_SECONDS
local LAPSES: number = DailyDropService.STREAK_LAPSES_AFTER_SECONDS
local START_UNIX = 1_700_000_000

-- ── reward shape, DISCOVERED through the public API ─────────────────────────────────────────────
-- The slice does NOT fix the reward numbers — it fixes their SHAPE: "escalating ... with a
-- documented cap". So the cap and the maximum are discovered by probing rewardFor, and every later
-- expectation is expressed in terms of what was discovered. A module that changed 100/50/7 to
-- 250/25/10 stays green here; a module that removed the cap goes red.
local function rewardOf(streak: any): number
	return DailyDropService:rewardFor(streak)
end

-- The smallest streak at which the reward stops growing (nil if it never stops within the probe).
local function discoverCapStreak(): number?
	for streak = 1, 5000 do
		if rewardOf(streak + 1) <= rewardOf(streak) then
			return streak
		end
	end
	return nil
end

local CAP_STREAK: number = discoverCapStreak() or -1
local MAX_REWARD: number = if CAP_STREAK > 0 then rewardOf(CAP_STREAK) else math.huge
local FIRST_REWARD: number = rewardOf(1)

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- A structural copy, so a "before" snapshot of a whole blob cannot be mutated out from under the
-- comparison (DataService hands the transform a fresh deep copy, but a spec must not rely on that).
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out: any = {}
	for key, child in value do
		out[key] = deepCopy(child)
	end
	return out
end

-- A pass-through ctx.data that COUNTS the updates that actually reached the data layer AND tracks
-- the PEAK number of them in flight simultaneously.
--
-- `updates` alone cannot tell an interleave from two strictly sequential calls — two sequential
-- claims count 2 as well. So if Mocks.store ever stopped forwarding `yieldOnUpdate` (option renamed,
-- mocks refactored, MockStore's forced yield deleted), every race case in section 7 would silently
-- degrade to two sequential claims and stay green. `peak` is the guard: it can only reach 2 if the
-- second claim entered ctx.data:update while the first was still parked inside it.
local function countingData(data: any): any
	local proxy: any = { updates = 0, inFlight = 0, peak = 0 }
	function proxy.update(self: any, player: any, transform: any): any
		self.updates += 1
		self.inFlight += 1
		if self.inFlight > self.peak then
			self.peak = self.inFlight
		end
		local result = data:update(player, transform)
		self.inFlight -= 1
		return result
	end
	function proxy.get(_self: any, player: any): any
		return data:get(player)
	end
	return proxy
end

-- Round-robin coroutine driver (the economy_race.spec idiom): resume every suspended coroutine
-- repeatedly until all are dead. Deterministic, deadlock-bounded.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 500 then
			error("daily race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`daily race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- Run `body` with the service's IN-MEMORY single-flight reservation neutralised, so an interleaved
-- pair genuinely reaches the data layer. The slice's stated mechanism is "the window check and the
-- lastClaimUnix stamp happen in the same lock-held transform" — a per-server memo is belt-and-braces
-- for it (and says nothing about the same player on another server), so the guarantee must hold
-- without it. The real table is ALWAYS restored, even when the body throws.
local function withoutSingleFlight(body: () -> ()): ()
	local real = DailyDropService._claiming
	DailyDropService._claiming = setmetatable({}, {
		__newindex = function() end, -- every reservation is silently dropped
	}) :: any
	local ok, err = pcall(body)
	DailyDropService._claiming = real
	if not ok then
		error(err, 0)
	end
end

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, and DailyDropService Started against a recording `net`. Start is the only way the
-- action + the view-push context are obtained, which is deliberate.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	local store = Mocks.store({
		clock = clock,
		config = Config,
		yieldOnUpdate = opts.yieldOnUpdate,
	})
	local data = DataService.new(store, clock, Config, Mocks.logWarn)
	local analytics = AnalyticsService.new(clock)
	local economy = EconomyService.new(analytics)

	local registered: { [string]: any } = {}
	local pushes: { any } = {}
	local net: any = {}
	function net.register(_self: any, action: any): ()
		registered[action.name] = action
	end
	function net.fireClient(_self: any, player: any, channel: string, payload: any): ()
		if opts.fireClientThrows then
			error("daily spec: the wire is down")
		end
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local startContext: any = {
		clock = clock,
		data = data,
		net = net,
		economy = economy,
		analytics = analytics,
	}
	DailyDropService:Start(startContext)

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		registered = registered,
		pushes = pushes,
	}

	-- The ActionContext a direct `claim` call receives. `overrides` lets a case swap ONE seam (a
	-- missing economy, a throwing economy) without rebuilding the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			economy = if o.economy ~= nil then o.economy else self.economy,
		}
	end

	function h.claim(self: any, player: any, overrides: any?): any
		return DailyDropService:claim(self:ctx(player, overrides))
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net with daily.claim registered from
	-- the service's own action factory. `gate = true` opts INTO the spine rate Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local harness = Mocks.net({
			clock = self.clock,
			data = self.data,
			economy = self.economy,
			gate = if w.gate == true then Mocks.gate(self.clock) else false,
		})
		harness.register(DailyDropService:claimAction())
		return harness
	end

	function h.join(self: any, userId: number): any
		local player = Mocks.player(userId)
		expect(self.data:loadSession(player)):toBeOk()
		return player
	end

	function h.leave(self: any, player: any): ()
		self.data:onPlayerRemoving(player)
	end

	function h.blob(self: any, player: any): any
		local got = self.data:get(player)
		expect(got):toBeOk()
		return (got :: any).value
	end

	-- The three numbers every economy case compares before/after.
	function h.snapshot(self: any, player: any): any
		local blob = self:blob(player)
		return {
			credits = blob.currencies.Credits,
			lifetime = blob.stats.lifetimeCredits,
			streak = blob.daily.streak,
			lastClaimUnix = blob.daily.lastClaimUnix,
			earned = #self.analytics:eventsOfType("currency_earned"),
			pushes = #self.pushes,
		}
	end

	return h
end

local function claimVia(harness: any, player: any, payload: any?): any
	return harness.invoke(Net.Actions.ClaimDaily, player, payload)
end

-- ── 1. the window constants + the pure window math ──────────────────────────────────────────────

describe("daily: the claim window is SERVER-derived and matches the slice", function()
	it("[A12] the bounds are exactly 20h and 44h, in seconds", function()
		-- The drop opens at 20h and STAYS OPEN for a further 24h. The lapse bound was 22h, which put
		-- the ordinary 24h cadence outside the window and made the escalating ladder unreachable —
		-- see amendment A12 in DailyDropService and docs/build-records/deep-reach/README.md.
		expect(OPENS):toBe(20 * HOUR)
		expect(LAPSES):toBe(44 * HOUR)
		expect(LAPSES - OPENS):toBe(24 * HOUR) -- a full day to come back, once it opens
	end)

	it("windowFor: never-claimed is open immediately and owes no wait", function()
		local status, wait = DailyDropService:windowFor(0, START_UNIX)
		expect(status):toBe(DailyDropService.Status.Never)
		expect(wait):toBe(0)
	end)

	it("windowFor: CLOSED for the whole first 20h, and the wait counts down", function()
		local base = START_UNIX
		for _, elapsed in { 0, 1, HOUR, 10 * HOUR, OPENS - 1 } do
			local status, wait = DailyDropService:windowFor(base, base + elapsed)
			expect(status):toBe(DailyDropService.Status.Closed)
			expect(wait):toBe(OPENS - elapsed)
		end
	end)

	it("windowFor: OPEN across [20h, 44h] — both named bounds are inside the window", function()
		local base = START_UNIX
		for _, elapsed in { OPENS, OPENS + 1, 21 * HOUR, 24 * HOUR, LAPSES - 1, LAPSES } do
			local status, wait = DailyDropService:windowFor(base, base + elapsed)
			expect(status):toBe(DailyDropService.Status.Open)
			expect(wait):toBe(0)
		end
	end)

	it("windowFor: LAPSED the second past 44h, and stays lapsed forever", function()
		local base = START_UNIX
		for _, elapsed in { LAPSES + 1, 48 * HOUR, 365 * 24 * HOUR } do
			local status = DailyDropService:windowFor(base, base + elapsed)
			expect(status):toBe(DailyDropService.Status.Lapsed)
		end
	end)

	it("streakAfter: ONLY the open window continues; never and lapsed both restart at 1", function()
		expect(DailyDropService:streakAfter(6, DailyDropService.Status.Open)):toBe(7)
		expect(DailyDropService:streakAfter(0, DailyDropService.Status.Open)):toBe(1)
		expect(DailyDropService:streakAfter(6, DailyDropService.Status.Lapsed)):toBe(1)
		expect(DailyDropService:streakAfter(6, DailyDropService.Status.Never)):toBe(1)
		-- A granted claim never leaves the badge showing 0 for a day the player did show up for.
		expect(DailyDropService:streakAfter(0, DailyDropService.Status.Never)):toBe(1)
	end)
end)

-- ── 2. the escalating reward and its CAP (the mint bound) ───────────────────────────────────────

describe("daily: the reward escalates, then is CAPPED (an unbounded streak cannot mint)", function()
	it("a cap exists at all — the reward stops growing at a finite streak", function()
		-- The slice's words: "with a documented cap so an unbounded streak cannot mint an unbounded
		-- balance". A module whose reward grew forever leaves CAP_STREAK at -1 and fails HERE, which
		-- is the single most valuable assertion in this file.
		expect(CAP_STREAK > 0):toBe(true)
		expect(MAX_REWARD < math.huge):toBe(true)
		expect(DailyDropService.MAX_REWARD_CREDITS):toBe(MAX_REWARD)
	end)

	it("STRICTLY escalating below the cap — every extra day is worth more", function()
		for streak = 1, CAP_STREAK - 1 do
			expect(rewardOf(streak + 1) > rewardOf(streak)):toBe(true)
		end
		expect(rewardOf(CAP_STREAK) > rewardOf(1)):toBe(true)
	end)

	it("FLAT at and above the cap, out to an absurd streak", function()
		for _, streak in { CAP_STREAK, CAP_STREAK + 1, CAP_STREAK + 50, 1000, 1e9, 1e15 } do
			expect(rewardOf(streak)):toBe(MAX_REWARD)
		end
	end)

	it(
		"GARBAGE streaks can never mint more than the cap (nil / NaN / inf / negative / fractional)",
		function()
			-- A persisted streak is a number from a blob an exploiter's earlier state could have
			-- shaped. Every one of these must land inside [rewardOf(1), MAX_REWARD] and must be a
			-- finite number — a NaN reward would poison the balance permanently.
			local function assertSaneReward(poison: any): ()
				local reward = rewardOf(poison)
				expect(type(reward)):toBe("number")
				expect(reward == reward):toBe(true) -- not NaN
				expect(reward >= FIRST_REWARD):toBe(true)
				expect(reward <= MAX_REWARD):toBe(true)
			end
			-- nil is asserted OUTSIDE the loop, and that is not a style choice: Luau's generalized
			-- table iteration SKIPS a nil hole, so a `nil` entry in the list below is never passed to
			-- rewardFor at all. The first case this test's name advertises used to be dead.
			assertSaneReward(nil)
			for _, poison in { 0 / 0, math.huge, -math.huge, -5, 0, 0.5, 6.9, 1e308, "999" } do
				assertSaneReward(poison)
			end
		end
	)

	it("the reward is a whole number of Credits (no fractional currency)", function()
		for _, streak in { 1, 2, CAP_STREAK, CAP_STREAK + 3 } do
			expect(rewardOf(streak) % 1):toBe(0)
		end
	end)
end)

-- ── 3. the claim lifecycle: grant, cooldown, continue, lapse ────────────────────────────────────

describe("daily: the first claim ever grants and starts the streak at 1", function()
	it("grants exactly rewardOf(1), moves lifetimeCredits, stamps the SERVER clock", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:snapshot(player)
		expect(before.streak):toBe(0)
		expect(before.lastClaimUnix):toBe(0)

		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		local info = (claimed :: any).value
		expect(info.streak):toBe(1)
		expect(info.reward):toBe(FIRST_REWARD)
		expect(info.status):toBe(DailyDropService.Status.Never)
		expect(info.continued):toBe(false)
		expect(info.lastClaimUnix):toBe(h.clock:unix()) -- SERVER time, not anything else

		local after = h:snapshot(player)
		expect(after.credits - before.credits):toBe(FIRST_REWARD)
		expect(after.lifetime - before.lifetime):toBe(FIRST_REWARD)
		expect(after.streak):toBe(1)
		expect(after.lastClaimUnix):toBe(START_UNIX)
		expect(after.earned - before.earned):toBe(1) -- exactly one currency_earned
		expect(info.balance):toBe(after.credits)
		expect(info.opensAtUnix):toBe(START_UNIX + OPENS)
		expect(info.lapsesAtUnix):toBe(START_UNIX + LAPSES)
	end)

	it("touches ONLY Credits and daily — no smelter, plot, depth or Pearls movement", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:blob(player)
		local pearls, stored, resurfaces =
			before.currencies.Pearls, before.smelter.storedCredits, before.resurfaces

		expect(h:claim(player)):toBeOk()

		local after = h:blob(player)
		expect(after.currencies.Pearls):toBe(pearls)
		expect(after.smelter.storedCredits):toBe(stored)
		expect(after.resurfaces):toBe(resurfaces)
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(0)
	end)

	it(
		"moves Credits, lifetimeCredits and daily — and NOTHING ELSE anywhere in the blob",
		function()
			-- The case above names "no smelter, plot, depth or Pearls movement" but only reads three
			-- fields, so `plot`, `depth`, `upgrades`, `flags`, `receipts`, `timestamps` and every stats
			-- field but lifetimeCredits could all move unseen. "NOT THIS SLICE: offline accrual, the rich
			-- wreck / restock, any structure or depth purchase" is a claim about the WHOLE blob, so it is
			-- asserted against the whole blob: the post-claim record must equal the pre-claim record with
			-- exactly four numbers moved, and nothing else touched at all.
			local h = newServer()
			local player = h:join(1)
			local before = deepCopy(h:blob(player))

			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			local info = (claimed :: any).value

			local expected = deepCopy(before)
			expected.currencies.Credits = before.currencies.Credits + info.reward
			expected.stats.lifetimeCredits = before.stats.lifetimeCredits + info.reward
			expected.daily.streak = info.streak
			expected.daily.lastClaimUnix = info.lastClaimUnix
			expect(h:blob(player)):toEqual(expected)
		end
	)

	it("costs EXACTLY ONE ctx.data:update and EXACTLY ONE view push", function()
		-- The slice says it in one clause: "Grant through ctx.economy:earn ... inside ONE
		-- DataService:update." An implementation that read the blob in one update and wrote in a
		-- second satisfies every other assertion in this file — and re-opens the read-then-write
		-- window the concurrency clause exists to close. The push count matters for the same reason
		-- the refusal case checks it: the badge is fed by these pushes, and three pushes per claim is
		-- three times the bandwidth for one fact.
		local h = newServer()
		local player = h:join(1)

		local granting = countingData(h.data)
		local beforePushes = #h.pushes
		expect(h:claim(player, { data = granting })):toBeOk()
		expect(granting.updates):toBe(1)
		expect(#h.pushes - beforePushes):toBe(1)

		-- A REFUSAL is one update too (the window is judged inside the transform), and pushes nothing.
		local refusing = countingData(h.data)
		expect(h:claim(player, { data = refusing })):toBeErr(Result.Codes.OnCooldown)
		expect(refusing.updates):toBe(1)
		expect(#h.pushes - beforePushes):toBe(1)
	end)
end)

describe("daily: inside the 20h cooldown the claim is REFUSED with OnCooldown", function()
	it("an immediate second claim mints nothing and does not re-stamp the window", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local after1 = h:snapshot(player)

		local second = h:claim(player)
		expect(second):toBeErr(Result.Codes.OnCooldown)

		local after2 = h:snapshot(player)
		expect(after2.credits):toBe(after1.credits)
		expect(after2.lifetime):toBe(after1.lifetime)
		expect(after2.streak):toBe(after1.streak)
		expect(after2.lastClaimUnix):toBe(after1.lastClaimUnix) -- a refusal never moves the window
		expect(after2.earned):toBe(after1.earned) -- and never emits currency_earned
	end)

	it(
		"OnCooldown is NOT RateLimited — a game cooldown and the anti-spam bucket differ",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:claim(player)):toBeOk()
			local refused = h:claim(player)
			expect(refused):toBeErr(Result.Codes.OnCooldown)
			expect((refused :: any).code == Result.Codes.RateLimited):toBe(false)
		end
	)

	it("refused at 20h MINUS ONE SECOND, granted at exactly 20h (the open boundary)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()

		h.clock:advance(OPENS - 1)
		expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD) -- still exactly one day's pay

		h.clock:advance(1) -- now exactly 20h since the stamp
		local opened = h:claim(player)
		expect(opened):toBeOk()
		expect((opened :: any).value.streak):toBe(2)
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD + rewardOf(2))
	end)

	it("a 19h55m grind of spam claims mints exactly ZERO extra Credits", function()
		-- The abuse shape: a client that simply retries. Every refusal must be inert.
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local paid = h:snapshot(player).credits

		for _ = 1, 60 do
			h.clock:advance(1195) -- 60 x 1195s = 71_700s < 20h, so the window never opens
			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
		end
		expect(h:snapshot(player).credits):toBe(paid)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(1)
	end)
end)

describe("daily: the streak CONTINUES inside the window and RESETS after it lapses", function()
	it("claiming at 20h, 21h and 22h keeps continuing the streak", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		for _, gap in { OPENS, 21 * HOUR, LAPSES } do
			h.clock:advance(gap)
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.continued):toBe(true)
		end
		expect(h:snapshot(player).streak):toBe(4)
	end)

	it("22h + 1s: the drop is STILL GRANTED, but the streak resets to 1", function()
		-- The slice: "a player who lets the window lapse comes back to a reset streak (streak = 1)".
		-- Refusing here would make the drop unclaimable forever after one missed day.
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h.clock:advance(OPENS)
		expect(h:claim(player)):toBeOk() -- streak 2
		expect(h:snapshot(player).streak):toBe(2)

		h.clock:advance(LAPSES + 1)
		local lapsed = h:claim(player)
		expect(lapsed):toBeOk()
		expect((lapsed :: any).value.status):toBe(DailyDropService.Status.Lapsed)
		expect((lapsed :: any).value.streak):toBe(1)
		expect((lapsed :: any).value.continued):toBe(false)
		expect((lapsed :: any).value.reward):toBe(FIRST_REWARD) -- back to the bottom of the ladder
		expect(h:snapshot(player).streak):toBe(1)
	end)

	it("[A12] a REAL 24h cadence CLIMBS the ladder — the feature's whole point", function()
		-- THE TEST THIS FILE USED TO ASSERT THE OPPOSITE OF. With the lapse bound at 22h, continuing
		-- a streak required every claim to land in a 2h window that walks BACKWARD 2-4h per day, so a
		-- player who logs in at the same wall-clock time each day arrived 24h later, lapsed, and was
		-- pinned at streak 1 / the first rung forever. Six of the seven rungs, the cap, and the entire
		-- "escalating reward" re-entry hook were dead content — and this suite pinned that as intended,
		-- which is why no gate could see it. Amendment A12 moved the bound; this is its falsification
		-- target, and it must go RED against a lapse bound at or below 24h.
		local h = newServer()
		local player = h:join(1)
		expect(LAPSES > 24 * HOUR):toBe(true) -- the ordinary cadence must fit INSIDE the window
		local rewards = {}
		for day = 1, 5 do
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.streak):toBe(day)
			expect((claimed :: any).value.continued):toBe(day > 1)
			table.insert(rewards, (claimed :: any).value.reward)
			h.clock:advance(24 * HOUR)
		end
		-- Escalating, not merely non-decreasing: every rung must pay strictly more than the one before
		-- it, or "escalating reward" is still a word rather than a mechanic.
		expect(rewards[1]):toBe(FIRST_REWARD)
		for day = 2, 5 do
			expect(rewards[day] > rewards[day - 1]):toBe(true)
		end
		-- And the total must beat five days of the bottom rung — the exact quantity the old behaviour
		-- capped the player at.
		expect(h:snapshot(player).credits > 5 * FIRST_REWARD):toBe(true)
	end)

	it(
		"[A12] missing a whole day still lapses — the window is forgiving, not infinite",
		function()
			-- The other side of A12. Moving the bound out must not turn the streak into something you
			-- cannot lose, or the ladder escalates for everyone forever and the re-entry hook stops
			-- being a hook. One skipped day (48h since the last claim) is past the bound and resets.
			local h = newServer()
			local player = h:join(1)
			expect(48 * HOUR > LAPSES):toBe(true)
			h:claim(player)
			h.clock:advance(24 * HOUR)
			local second = h:claim(player)
			expect((second :: any).value.streak):toBe(2)
			h.clock:advance(48 * HOUR) -- skipped a day
			local afterSkip = h:claim(player)
			expect((afterSkip :: any).value.streak):toBe(1)
			expect((afterSkip :: any).value.continued):toBe(false)
			expect((afterSkip :: any).value.reward):toBe(FIRST_REWARD)
		end
	)

	it("a year-long absence still grants — the drop is never permanently unclaimable", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h.clock:advance(365 * 24 * HOUR)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expect((claimed :: any).value.streak):toBe(1)
	end)

	it("after a lapse the ladder climbs again from 1 (the reset is a real restart)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h.clock:advance(LAPSES + 1) -- lapse -> streak 1
		expect(h:claim(player)):toBeOk()
		h.clock:advance(OPENS) -- back inside the window -> streak 2
		local third = h:claim(player)
		expect(third):toBeOk()
		expect((third :: any).value.streak):toBe(2)
		expect((third :: any).value.reward):toBe(rewardOf(2))
	end)

	it(
		"a MISSED day costs the ladder: 3 in a row then a lapse pays less than 4 in a row",
		function()
			-- Every claim in these loops is asserted Ok. Discarding the Results would let this case
			-- pass for the WRONG reason: if claims started refusing mid-loop both totals shrink
			-- together and the final inequality still holds.
			local streaky = newServer()
			local p1 = streaky:join(1)
			for _ = 1, 4 do
				expect(streaky:claim(p1)):toBeOk()
				streaky.clock:advance(OPENS)
			end

			local lapser = newServer()
			local p2 = lapser:join(2)
			for _ = 1, 3 do
				expect(lapser:claim(p2)):toBeOk()
				lapser.clock:advance(OPENS)
			end
			lapser.clock:advance(LAPSES + 1) -- the 4th claim arrives late
			expect(lapser:claim(p2)):toBeOk()

			expect(lapser:snapshot(p2).credits < streaky:snapshot(p1).credits):toBe(true)
			expect(lapser:snapshot(p2).streak):toBe(1)
			expect(streaky:snapshot(p1).streak):toBe(4)
		end
	)
end)

-- ── 4. the ECONOMY: the mint is bounded over time ───────────────────────────────────────────────

describe("daily: 40 consecutive days mint exactly the capped ladder, never more", function()
	it("the balance equals the sum of the per-claim rewards, and the cap BINDS", function()
		local h = newServer()
		local player = h:join(1)
		local expectedTotal = 0
		for day = 1, 40 do
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			local info = (claimed :: any).value
			expect(info.streak):toBe(day)
			expect(info.reward):toBe(rewardOf(day))
			expect(info.reward <= MAX_REWARD):toBe(true)
			expectedTotal += info.reward
			h.clock:advance(OPENS)
		end

		local after = h:snapshot(player)
		expect(after.credits):toBe(expectedTotal)
		expect(after.lifetime):toBe(expectedTotal) -- lifetime moved on EVERY earn
		expect(after.streak):toBe(40)
		expect(after.earned):toBe(40) -- one currency_earned per granted claim, never two
		-- The whole point of the cap: 40 days of a linear ladder would be ~2x this.
		expect(after.credits <= 40 * MAX_REWARD):toBe(true)
		expect(rewardOf(40)):toBe(MAX_REWARD) -- the last days were flat, not escalating
	end)

	it("100 days of the fastest legal cadence mint the EXACT ladder total", function()
		-- The old bound here was `credits <= 100 * MAX_REWARD` — 40,000 against a true total of
		-- 38,950, so an over-mint of up to ~1,050 Credits sailed through. And `credits == lifetime`
		-- cannot catch a mint at all: EconomyService.earn increments the balance and lifetimeCredits
		-- from the SAME amount in the same block, so they move together under a double-grant too.
		-- The exact expected total is still DISCOVERED (summed from rewardOf), never copied.
		local h = newServer()
		local player = h:join(1)
		local expectedTotal = 0
		for day = 1, 100 do
			expect(h:claim(player)):toBeOk()
			expectedTotal += rewardOf(day)
			h.clock:advance(OPENS)
		end
		local after = h:snapshot(player)
		expect(after.credits):toBe(expectedTotal)
		expect(after.lifetime):toBe(expectedTotal)
		expect(after.credits <= 100 * MAX_REWARD):toBe(true)
		expect(after.credits):toBe(after.lifetime)
		expect(after.earned):toBe(100)
		expect(after.streak):toBe(100)
	end)

	it("a HUGE persisted streak still pays only the cap (no overflow mint)", function()
		local h = newServer()
		local player = h:join(1)
		h.data:update(player, function(d: any): any
			d.daily.streak = 1e15
			d.daily.lastClaimUnix = START_UNIX - OPENS
			return d
		end)
		local before = h:snapshot(player)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expect((claimed :: any).value.reward):toBe(MAX_REWARD)
		expect(h:snapshot(player).credits - before.credits):toBe(MAX_REWARD)
	end)

	it("a NaN / negative persisted streak cannot poison the balance", function()
		for _, poison in { 0 / 0, -50, math.huge } do
			local h = newServer()
			local player = h:join(1)
			h.data:update(player, function(d: any): any
				d.daily.streak = poison
				d.daily.lastClaimUnix = START_UNIX - OPENS
				return d
			end)
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			local credits = h:snapshot(player).credits
			expect(credits == credits):toBe(true) -- never NaN
			expect(credits > 0):toBe(true)
			expect(credits <= MAX_REWARD):toBe(true)
			expect(h:snapshot(player).streak % 1):toBe(0) -- and the badge shows an integer
		end
	end)
end)

-- ── 5. the grant MUST go through ctx.economy:earn ────────────────────────────────────────────────

describe("daily: the grant goes through the economy seam or does not happen", function()
	it("an absent ctx.economy REFUSES rather than writing currencies directly", function()
		-- Granting around the seam would leave stats.lifetimeCredits (the leaderboard key) unmoved
		-- and currency_earned unemitted — a silent, untracked mint.
		local h = newServer()
		local player = h:join(1)
		local ctx = h:ctx(player)
		ctx.economy = nil

		local refused = DailyDropService:claim(ctx)
		expect(refused):toBeErr(Result.Codes.Internal)

		local after = h:snapshot(player)
		expect(after.credits):toBe(0)
		expect(after.lifetime):toBe(0)
		expect(after.lastClaimUnix):toBe(0) -- the window was not burned either
	end)

	it("every granted Credit is mirrored by a currency_earned carrying the daily source", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local events = h.analytics:eventsOfType("currency_earned")
		expect(#events):toBe(1)
		expect(events[1].payload.currency):toBe("Credits")
		expect(events[1].payload.amount):toBe(FIRST_REWARD)
		expect(events[1].payload.balance):toBe(FIRST_REWARD)
		expect(events[1].payload.lifetimeCredits):toBe(FIRST_REWARD)
		expect(events[1].at):toBe(START_UNIX) -- stamped on the SERVER clock
		-- THE SOURCE LABEL, which the title of this case promises. The slice's ECONOMY line names
		-- the daily supply drop as one of three distinct Credit sources, and the success criterion
		-- "Core analytics events fire" grades earn-path attribution — a grant labelled "smelt" (or
		-- "" or nil) is a mint this feature would never be billed for. Tier-1 is the only rung that
		-- can see it.
		expect(events[1].payload.source):toBe("daily")
	end)

	it("an economy whose earn THROWS grants nothing and leaves the player claimable", function()
		-- The reservation must be released on EVERY path: a stranded flag would lock this player out
		-- of the drop for the life of the server.
		local h = newServer()
		local player = h:join(1)
		local exploding: any = {
			earn = function(): any
				error("economy exploded")
			end,
		}
		local boom = h:claim(player, { economy = exploding })
		expect(boom):toBeErr()

		local after = h:snapshot(player)
		expect(after.credits):toBe(0)
		expect(after.lastClaimUnix):toBe(0)

		-- and the very next claim, with a healthy seam, works.
		local recovered = h:claim(player)
		expect(recovered):toBeOk()
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
	end)

	it("an economy that REFUSES the earn never burns the window", function()
		local h = newServer()
		local player = h:join(1)
		local stingy: any = {
			earn = function(): any
				return Result.err(Result.Codes.Internal, "no")
			end,
		}
		expect(h:claim(player, { economy = stingy })):toBeErr()
		expect(h:snapshot(player).lastClaimUnix):toBe(0)
		expect(h:claim(player)):toBeOk() -- the day was not consumed by the failure
	end)
end)

-- ── 6. negative / abuse: the payload, the rate bucket, ownership, the session ────────────────────

describe("daily: the payload carries NO time — a forged one is REFUSED, not ignored", function()
	it(
		"nil and an empty table are accepted — and NOTHING a client sent survives validation",
		function()
			-- [TITLE REPAIRED. This case used to be titled "nil and an empty table are the ONLY
			--  accepted payloads" and then only proved that those two are Ok — it proved exclusivity
			--  of nothing, and the word ONLY was false besides: the validator refuses a FIXED KEY
			--  LIST, so `{ foo = 1 }` and `{ Now = 9e9 }` (capital N) validate Ok. The slice does not
			--  guarantee an allowlist; it guarantees "the payload carries no timestamp at all". The
			--  guarantee that actually holds — and that makes the blocklist's near-misses harmless —
			--  is that validation hands the handler a FRESH EMPTY table, so no client-supplied value
			--  reaches the claim path whatever the client sent. That is what is asserted here.]
			expect(DailyDropService.validate(nil)):toBeOk()
			expect(DailyDropService.validate({})):toBeOk()

			-- Every accepted payload is replaced by an EMPTY table. NOTE the nil case is asserted
			-- OUTSIDE the loop on purpose: Luau's generalized iteration silently skips a nil hole in
			-- a table literal, so a `nil` entry in a list like this is never actually exercised.
			local function assertHandsOverNothing(payload: any): ()
				local validated = DailyDropService.validate(payload)
				expect(validated):toBeOk()
				local passed = (validated :: any).value
				expect(type(passed)):toBe("table")
				expect(next(passed)):toBe(nil) -- nothing the client sent is in it
			end
			assertHandsOverNothing(nil)
			for _, accepted in { {}, { foo = 1 }, { Now = 9e9 }, { nowMs = 9e9 } } do
				assertHandsOverNothing(accepted)
			end

			-- ...and it is a FRESH table, never the client's own (which the client could otherwise
			-- keep a reference to, or which could carry a metatable).
			local sent: any = { foo = 1 }
			local out = DailyDropService.validate(sent)
			expect(out):toBeOk()
			expect((out :: any).value == sent):toBe(false)
		end
	)

	it("an UNLISTED near-miss time key reaches the HANDLER as an empty table", function()
		-- The validator is a 16-entry BLOCKLIST, so `nowMs`, a capital-N `Now`, a positional [1] and
		-- `elapsedHours` all slip PAST it and validate Ok. That is safe only because of the
		-- fresh-empty-table rule, and this is the case that observes it where it matters: at the
		-- boundary the handler actually sees, through the real Net.dispatch. The handler is wrapped
		-- in a spy (the real action's own handler is still what runs) so the payload it was HANDED is
		-- an observable fact rather than an inference.
		local h = newServer()
		local player = h:join(1)
		local seen: { any } = {}
		local action = DailyDropService:claimAction()
		local realHandler = action.handler
		local spied: any = {
			name = action.name,
			validate = action.validate,
			rate = action.rate,
			handler = function(ctx: any, payload: any): any
				table.insert(seen, payload)
				return realHandler(ctx, payload)
			end,
		}
		local net = Mocks.net({
			clock = h.clock,
			data = h.data,
			economy = h.economy,
			gate = false,
		})
		net.register(spied)

		for _, nearMiss in
			{
				{ nowMs = 9e9 },
				{ Now = 9e9 },
				{ [1] = 9e9 },
				{ elapsedHours = 30 },
				{ foo = "bar" },
			}
		do
			net.invoke(Net.Actions.ClaimDaily, player, nearMiss)
		end

		expect(#seen):toBe(5)
		for _, payload in seen do
			expect(type(payload)):toBe("table")
			expect(next(payload)):toBe(nil) -- not one smuggled key survived the validator
		end

		-- ...and end to end, five near-miss forgeries bought exactly one ordinary first day.
		local after = h:snapshot(player)
		expect(after.credits):toBe(FIRST_REWARD)
		expect(after.streak):toBe(1)
		expect(after.earned):toBe(1)
	end)

	it("a payload naming a time / streak / reward is Err(BadPayload)", function()
		for _, forged in
			{
				{ now = 9e9 },
				{ nowUnix = 0 },
				{ timestamp = START_UNIX + 99 * HOUR },
				{ lastClaimUnix = 0 },
				{ streak = 999 },
				{ reward = 1e9 },
				{ amount = 1e9 },
				{ currency = "Pearls" },
				{ userId = 2 },
			}
		do
			expect(DailyDropService.validate(forged)):toBeErr(Result.Codes.BadPayload)
		end
	end)

	it("a non-table payload is Err(BadType)", function()
		for _, junk in { 1, "claim", true, print } do
			expect(DailyDropService.validate(junk)):toBeErr(Result.Codes.BadType)
		end
	end)

	it("through the REAL dispatch pipeline, a forged time mints nothing at all", function()
		local h = newServer()
		local net = h:wire()
		local player = h:join(1)

		expect(claimVia(net, player, { now = START_UNIX + 99 * HOUR })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(h:snapshot(player).credits):toBe(0)

		-- A legitimate claim, then a forged "it has been 30 hours" — the refusal is the same and the
		-- streak cannot be walked forward by a client number.
		expect(claimVia(net, player, nil)):toBeOk()
		expect(claimVia(net, player, { now = START_UNIX + 30 * HOUR })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(claimVia(net, player, { streak = 7 })):toBeErr(Result.Codes.BadPayload)
		local after = h:snapshot(player)
		expect(after.credits):toBe(FIRST_REWARD)
		expect(after.streak):toBe(1)
	end)

	it("a well-formed empty payload is judged on the SERVER clock alone", function()
		local h = newServer()
		local net = h:wire()
		local player = h:join(1)
		expect(claimVia(net, player, {})):toBeOk()
		-- The client's table is empty; only the injected clock can open the window.
		expect(claimVia(net, player, {})):toBeErr(Result.Codes.OnCooldown)
		h.clock:advance(OPENS)
		expect(claimVia(net, player, {})):toBeOk()
	end)
end)

describe("daily: the anti-spam rate bucket is enforced, and is a DIFFERENT refusal", function()
	it("a burst is cut off with RateLimited once the bucket empties", function()
		local h = newServer()
		local net = h:wire({ gate = true })
		local player = h:join(1)

		local codes: { string } = {}
		for _ = 1, 8 do
			local outcome = claimVia(net, player, nil)
			table.insert(codes, if outcome.ok then "ok" else (outcome :: any).code)
		end
		expect(codes[1]):toBe("ok")
		expect(codes[#codes]):toBe(Result.Codes.RateLimited)

		local sawCooldown = false
		local sawRateLimited = false
		for _, code in codes do
			if code == Result.Codes.OnCooldown then
				sawCooldown = true
			elseif code == Result.Codes.RateLimited then
				sawRateLimited = true
			end
		end
		expect(sawCooldown):toBe(true) -- the window refusal
		expect(sawRateLimited):toBe(true) -- the bucket refusal, distinguishable
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD) -- one day's pay, whatever the burst
	end)

	it("the bucket REFILLS: the window RESET serves a rate-limited player again", function()
		-- The missing half of "rate limit + window reset". Everything above proves the burst is CUT
		-- OFF; nothing proved the cut-off ever ENDS. Gate is a token bucket refilling at
		-- maxPerWindow/windowSeconds on the monotonic clock — a regression that zeroed the refill, or
		-- made the bucket sticky, would leave an honest player permanently unable to claim and every
		-- other case in this file would stay green, because they all measure the burst and stop.
		local h = newServer()
		local net = h:wire({ gate = true })
		local player = h:join(1)
		local policy = h.registered[Net.Actions.ClaimDaily].rate

		local last: any = nil
		for _ = 1, 8 do
			last = claimVia(net, player, nil)
		end
		expect(last):toBeErr(Result.Codes.RateLimited) -- the bucket is empty

		-- The honest player waits out exactly one policy window and is SERVED again: the pipeline
		-- reaches the transform, which refuses on the GAME cooldown — a different code entirely.
		h.clock:advance(policy.windowSeconds)
		local served = claimVia(net, player, nil)
		expect(served):toBeErr(Result.Codes.OnCooldown)
		expect((served :: any).code == Result.Codes.RateLimited):toBe(false)

		-- ...and once the 20h window itself opens, the refilled bucket lets the claim through. This
		-- is the assertion that a permanently-empty bucket cannot survive: the player must be able to
		-- collect tomorrow's drop after today's spam.
		h.clock:advance(OPENS)
		local granted = claimVia(net, player, nil)
		expect(granted):toBeOk()
		expect((granted :: any).value.streak):toBe(2)
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD + rewardOf(2))
	end)

	it("the bucket is per player: a rate-limited exploiter never blocks an honest one", function()
		local h = newServer()
		local net = h:wire({ gate = true })
		local spammer = h:join(1)
		local honest = h:join(2)
		for _ = 1, 8 do
			claimVia(net, spammer, nil)
		end
		expect(claimVia(net, honest, nil)):toBeOk()
		expect(h:snapshot(honest).credits):toBe(FIRST_REWARD)
	end)
end)

describe("daily: a claim is scoped to the ACTING player only", function()
	it("player A's claim moves nothing of player B's, and B is still claimable", function()
		local h = newServer()
		local net = h:wire()
		local a = h:join(1)
		local b = h:join(2)
		local beforeB = h:snapshot(b)

		expect(claimVia(net, a, nil)):toBeOk()
		local afterB = h:snapshot(b)
		expect(afterB.credits):toBe(beforeB.credits)
		expect(afterB.streak):toBe(beforeB.streak)
		expect(afterB.lastClaimUnix):toBe(beforeB.lastClaimUnix)

		expect(claimVia(net, b, nil)):toBeOk() -- B's own window is untouched by A
		expect(h:snapshot(b).credits):toBe(FIRST_REWARD)
		expect(h:snapshot(a).credits):toBe(FIRST_REWARD)
	end)

	it("cooldowns are per player, not per server", function()
		local h = newServer()
		local a = h:join(1)
		local b = h:join(2)
		expect(h:claim(a)):toBeOk()
		expect(h:claim(a)):toBeErr(Result.Codes.OnCooldown)
		expect(h:claim(b)):toBeOk() -- B is not swept up in A's cooldown
	end)
end)

describe("daily: a claim without a loaded session grants nothing and strands nothing", function()
	it("Err(NoData) before loadSession, and the claim works once the session lands", function()
		local h = newServer()
		local player = Mocks.player(9)
		expect(h:claim(player)):toBeErr(Result.Codes.NoData)

		expect(h.data:loadSession(player)):toBeOk()
		local claimed = h:claim(player) -- the reservation was NOT left stranded by the failure
		expect(claimed):toBeOk()
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
	end)

	it("a player with no numeric UserId is refused, not crashed through", function()
		local h = newServer()
		expect(DailyDropService:claim(h:ctx({ Name = "ghost" } :: any))):toBeErr(
			Result.Codes.BadType
		)
	end)

	it(
		"a claim on a DEAD session (the lock was stolen) grants nothing and strands nothing",
		function()
			-- The sibling above covers NoData (never loaded). This is the other half: a session whose
			-- DataStore lock was taken by another server. The record on this server can never be
			-- persisted again, so the claim must be refused AS a stolen session (the caller reacts by
			-- re-syncing, not by retrying), must mint nothing, must emit nothing, and must not strand the
			-- in-flight reservation — a stranded flag would lock the player out of the drop even after
			-- the rejoin that fixes everything else.
			local h = newServer()
			local player = h:join(1)
			h.data:markDead(player.UserId, Result.Codes.LockStolen)
			local pushed = #h.pushes

			local refused = h:claim(player)
			expect(refused):toBeErr(Result.Codes.LockStolen)
			expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
			expect(#h.pushes):toBe(pushed)
			expect(DailyDropService._claiming[player.UserId]):toBe(nil)

			-- The rejoin recovers — and proves the dead-session claim granted nothing, because this one
			-- is still the player's FIRST ever claim.
			local returning = h:join(1)
			local claimed = h:claim(returning)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.streak):toBe(1)
			expect((claimed :: any).value.reward):toBe(FIRST_REWARD)
			expect(h:snapshot(returning).credits):toBe(FIRST_REWARD)
			expect(#h.analytics:eventsOfType("currency_earned")):toBe(1)
		end
	)
end)

describe("daily: a degenerate SERVER clock refuses — it never opens the window", function()
	it("NaN / infinite / non-numeric ctx.clock:unix() is Err(Internal), not time 0", function()
		-- The slice pins the window as "evaluated ONLY against ctx.clock:unix()", which makes a
		-- degenerate clock a first-class input rather than an impossibility. The failure mode being
		-- guarded is specific: a regression that defaulted an unusable clock to 0 would compute
		-- elapsed against 0, read every record as claimable, and open the drop for EVERY player at
		-- once — the single largest mint this feature could produce.
		for _, bad in { 0 / 0, math.huge, -math.huge, "1700000000" :: any, true :: any } do
			local h = newServer()
			local player = h:join(1)
			local broken: any = {
				unix = function(): any
					return bad
				end,
				mono = function(): number
					return 0
				end,
			}

			local refused = h:claim(player, { clock = broken })
			expect(refused):toBeErr(Result.Codes.Internal)

			local after = h:snapshot(player)
			expect(after.credits):toBe(0)
			expect(after.lifetime):toBe(0)
			expect(after.lastClaimUnix):toBe(0)
			expect(after.earned):toBe(0)
			expect(#h.pushes):toBe(0)

			-- ...and the healthy clock still works: the bad clock burned nothing.
			expect(h:claim(player)):toBeOk()
			expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
		end
	end)
end)

describe(
	"daily: a blob whose `daily` record is missing or corrupt is REPAIRED, not fatal",
	function()
		it(
			"a MISSING daily field is rebuilt inside the transform and the claim grants once",
			function()
				-- A corrupt blob has exactly two bad outcomes and this pins both away: a throw inside a
				-- lock-held transform (which discards the whole write and surfaces as an opaque Internal),
				-- and a silent free claim on every request because the rebuilt record is never persisted.
				local h = newServer()
				local player = h:join(1)
				h.data:update(player, function(d: any): any
					d.daily = nil
					return d
				end)

				local claimed = h:claim(player)
				expect(claimed):toBeOk()
				expect((claimed :: any).value.streak):toBe(1)

				local after = h:snapshot(player)
				expect(after.streak):toBe(1)
				expect(after.lastClaimUnix):toBe(START_UNIX)
				expect(after.credits):toBe(FIRST_REWARD)

				-- THE REPAIR IS PERSISTED: the rebuilt record enforces the cooldown like any other, so a
				-- blob-corrupting exploit is not an unlimited-claim exploit.
				expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
				expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
				expect(#h.analytics:eventsOfType("currency_earned")):toBe(1)
			end
		)

		it("a NON-TABLE daily field is replaced, never indexed", function()
			for _, corrupt in { "wrecked" :: any, 7 :: any, true :: any } do
				local h = newServer()
				local player = h:join(1)
				h.data:update(player, function(d: any): any
					d.daily = corrupt
					return d
				end)

				expect(h:claim(player)):toBeOk()
				local blob = h:blob(player)
				expect(type(blob.daily)):toBe("table")
				expect(blob.daily.streak):toBe(1)
				expect(blob.daily.lastClaimUnix):toBe(START_UNIX)
				expect(blob.currencies.Credits):toBe(FIRST_REWARD)
				expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
			end
		end)
	end
)

-- ── 7. CONCURRENCY: two claims in the same frame grant EXACTLY once ─────────────────────────────

describe("daily: interleaved + spam-duplicated claims (the headline race)", function()
	-- Counts the outcomes of a batch of racing claims.
	local function tally(results: { any }): (number, { string })
		local granted = 0
		local codes: { string } = {}
		for _, outcome in results do
			if type(outcome) == "table" and outcome.ok == true then
				granted += 1
			else
				table.insert(codes, tostring((outcome :: any).code))
			end
		end
		return granted, codes
	end

	-- (countingData now lives at module scope — it grew a PEAK in-flight counter, which the case
	-- below needs and which every other race case can borrow.)

	it(
		"TWO claims in the same frame, single-flight NEUTRALISED: the lock-held transform alone grants once",
		function()
			-- This is the slice's stated mechanism under test, with the in-memory memo removed so the
			-- interleave genuinely reaches the data layer. A read-then-yield-then-write daily pays
			-- twice here; the transform-scoped one pays once.
			local h = newServer({ yieldOnUpdate = true })
			local player = h:join(1)
			local results: { any } = {}
			local counted = countingData(h.data)

			withoutSingleFlight(function()
				drain({
					coroutine.create(function()
						table.insert(results, h:claim(player, { data = counted }))
					end),
					coroutine.create(function()
						table.insert(results, h:claim(player, { data = counted }))
					end),
				})
			end)

			local granted, codes = tally(results)
			expect(#results):toBe(2)
			-- NOT VACUOUS: both claims genuinely entered ctx.data:update and interleaved inside the
			-- store's critical section. One update here would mean the memo short-circuited the race.
			expect(counted.updates):toBe(2)
			-- ...and `updates == 2` alone would NOT prove the interleave: two strictly sequential
			-- claims count 2 as well. PEAK is what discriminates them. It can only reach 2 if the
			-- second claim entered ctx.data:update while the first was STILL PARKED inside it, which
			-- is the only arrangement under which the "same lock-held transform" clause is load
			-- bearing. Without this line, a MockStore that stopped honouring `yieldOnUpdate` would
			-- turn every race case in this section into two sequential claims, silently, all green.
			expect(counted.peak):toBe(2)
			expect(granted):toBe(1)
			expect(codes[1]):toBe(Result.Codes.OnCooldown)

			local after = h:snapshot(player)
			expect(after.credits):toBe(FIRST_REWARD) -- EXACTLY one day's pay, never two
			expect(after.lifetime):toBe(FIRST_REWARD)
			expect(after.streak):toBe(1) -- not 2: the window check saw the first stamp
			expect(after.lastClaimUnix):toBe(START_UNIX)
			expect(after.earned):toBe(1) -- exactly one currency_earned
		end
	)

	it("TWO duplicates arriving over the REAL dispatch pipeline grant exactly once", function()
		-- Every other case in this section calls DailyDropService:claim directly. The shape an
		-- exploiter actually SENDS is two invocations in the same frame, which arrive through
		-- Net.dispatch -> validate -> the claimAction closure — so the wire path gets its own
		-- interleave, with the same peak-in-flight proof that it really interleaved.
		local h = newServer({ yieldOnUpdate = true })
		local player = h:join(1)
		local counted = countingData(h.data)
		local net = Mocks.net({
			clock = h.clock,
			data = counted,
			economy = h.economy,
			gate = false, -- the anti-spam bucket is a DIFFERENT mechanism, tested separately
		})
		net.register(DailyDropService:claimAction())

		local results: { any } = {}
		withoutSingleFlight(function()
			drain({
				coroutine.create(function()
					table.insert(results, net.invoke(Net.Actions.ClaimDaily, player, nil))
				end),
				coroutine.create(function()
					table.insert(results, net.invoke(Net.Actions.ClaimDaily, player, {}))
				end),
			})
		end)

		local granted, codes = tally(results)
		expect(#results):toBe(2)
		expect(counted.updates):toBe(2)
		expect(counted.peak):toBe(2) -- genuinely interleaved, on the wire path
		expect(granted):toBe(1)
		expect(codes[1]):toBe(Result.Codes.OnCooldown)

		local after = h:snapshot(player)
		expect(after.credits):toBe(FIRST_REWARD)
		expect(after.lifetime):toBe(FIRST_REWARD)
		expect(after.streak):toBe(1)
		expect(after.earned):toBe(1)
	end)

	it("FIVE spam-duplicated claims interleaved grant exactly once", function()
		local h = newServer({ yieldOnUpdate = true })
		local player = h:join(1)
		local results: { any } = {}
		withoutSingleFlight(function()
			local cos: { thread } = {}
			for _ = 1, 5 do
				table.insert(
					cos,
					coroutine.create(function()
						table.insert(results, h:claim(player))
					end)
				)
			end
			drain(cos)
		end)

		local granted = tally(results)
		expect(#results):toBe(5)
		expect(granted):toBe(1)
		local after = h:snapshot(player)
		expect(after.credits):toBe(FIRST_REWARD)
		expect(after.lifetime):toBe(FIRST_REWARD)
		expect(after.streak):toBe(1)
		expect(after.earned):toBe(1)
	end)

	it("the in-memory single-flight ALSO refuses a duplicate, with the same code", function()
		-- Belt-and-braces: with the memo live, the second claim never reaches the store at all. It
		-- must still be a game-cooldown refusal, not a rate-limit and not a silent success.
		local h = newServer({ yieldOnUpdate = true })
		local player = h:join(1)
		local results: { any } = {}
		drain({
			coroutine.create(function()
				table.insert(results, h:claim(player))
			end),
			coroutine.create(function()
				table.insert(results, h:claim(player))
			end),
		})
		local granted, codes = tally(results)
		expect(granted):toBe(1)
		expect(codes[1]):toBe(Result.Codes.OnCooldown)
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
	end)

	it("racing a LAPSED claim still resets the streak to 1, granted once", function()
		local h = newServer({ yieldOnUpdate = true })
		local player = h:join(1)
		-- ALWAYS in a coroutine against a yieldOnUpdate store: the write yields, and a yield on
		-- Lune's main thread exits the process 0 and silently swallows the whole run.
		local seeded: any = nil
		drain({
			coroutine.create(function()
				seeded = h:claim(player)
			end),
		})
		expect(seeded):toBeOk()
		h.clock:advance(LAPSES + 1)
		local paidOnce = h:snapshot(player).credits

		local results: { any } = {}
		withoutSingleFlight(function()
			drain({
				coroutine.create(function()
					table.insert(results, h:claim(player))
				end),
				coroutine.create(function()
					table.insert(results, h:claim(player))
				end),
			})
		end)
		local granted = tally(results)
		expect(granted):toBe(1)
		local after = h:snapshot(player)
		expect(after.streak):toBe(1)
		expect(after.credits):toBe(paidOnce + FIRST_REWARD)
	end)

	it("TWO DIFFERENT players racing both get paid (the guard is per player)", function()
		local h = newServer({ yieldOnUpdate = true })
		local a = h:join(1)
		local b = h:join(2)
		local results: { any } = {}
		drain({
			coroutine.create(function()
				table.insert(results, h:claim(a))
			end),
			coroutine.create(function()
				table.insert(results, h:claim(b))
			end),
		})
		local granted = tally(results)
		expect(granted):toBe(2)
		expect(h:snapshot(a).credits):toBe(FIRST_REWARD)
		expect(h:snapshot(b).credits):toBe(FIRST_REWARD)
	end)

	it("FALSIFIABILITY (the REAL path): a store that never RE-READS double-grants", function()
		-- THE counter-case that discriminates the mechanism actually under test. The hand-rolled one
		-- below proves the DRIVER can expose a stale read in a toy; it never touches
		-- DailyDropService, DataService or MockStore, so it would stay green with the service
		-- completely broken. This one drives the REAL DailyDropService, the REAL DataService and the
		-- REAL EconomyService — through a store whose update reads its snapshot, yields at the SAME
		-- point MockStore yields, and then runs the transform against that STALE read (no per-key
		-- FIFO, no re-read). The identical drive that grants ONCE above grants TWICE here, which is
		-- what makes the headline case's green mean something.
		local clock = Mocks.clock(START_UNIX)
		local analytics = AnalyticsService.new(clock)
		local economy = EconomyService.new(analytics)
		local backing: any = nil

		local naive: any = {}
		function naive.isLocked(): boolean
			return backing ~= nil
		end
		function naive.load(_self: any, _key: string, default: () -> any): any
			if backing == nil then
				backing = default()
			end
			local session: any = { key = "naive", data = backing }
			function session.set(self: any, value: any): ()
				self.data = value
				backing = value
			end
			function session.update(self: any, transform: any): any
				local snapshot = deepCopy(backing) -- read...
				coroutine.yield() -- ...yield, exactly where MockStore yields...
				local ok, newValue = pcall(transform, snapshot) -- ...and NEVER re-read
				if not ok then
					return Result.err(Result.Codes.Internal, tostring(newValue))
				end
				backing = newValue
				self.data = newValue
				return Result.ok(newValue)
			end
			function session.save(self: any): any
				return Result.ok(self.data)
			end
			function session.release(self: any): any
				return Result.ok(self.data)
			end
			function session.abandon(): () end
			return Result.ok(session)
		end

		local data = DataService.new(naive, clock, Config, Mocks.logWarn)
		DailyDropService:Start({
			clock = clock,
			data = data,
			net = { register = function() end },
			economy = economy,
		})
		local player = Mocks.player(77)
		expect(data:loadSession(player)):toBeOk()
		backing = (data:get(player) :: any).value -- keep the store's backing = the migrated blob

		local ctx = { player = player, clock = clock, data = data, economy = economy }
		local results: { any } = {}
		withoutSingleFlight(function()
			drain({
				coroutine.create(function()
					table.insert(results, DailyDropService:claim(ctx))
				end),
				coroutine.create(function()
					table.insert(results, DailyDropService:claim(ctx))
				end),
			})
		end)

		local granted = tally(results)
		expect(#results):toBe(2)
		expect(granted):toBe(2) -- PAID TWICE for one day, through the real service
		expect(#analytics:eventsOfType("currency_earned")):toBe(2)
		-- ...and the lost update on top: the second writer's stale snapshot clobbers the first, so
		-- the record shows ONE day's pay for TWO grants. Both halves of the defect, one drive.
		expect(backing.currencies.Credits):toBe(FIRST_REWARD)
		expect(backing.daily.streak):toBe(1)
	end)

	it(
		"FALSIFIABILITY: a decide-then-yield-then-stamp daily DOES double-grant at the same yield point",
		function()
			-- The counter-case that proves the interleave above is real, not trivially green. This
			-- naive daily reads the stamp, yields (as ctx.data:update does), and only then decides +
			-- writes — the exact defect the slice's "same lock-held transform" clause forbids.
			local blob = { credits = 0, lastClaimUnix = 0, streak = 0 }
			local function naiveClaim(now: number): boolean
				local stamp = blob.lastClaimUnix -- read...
				coroutine.yield() -- ...yield (no lock, no re-read)...
				if stamp ~= 0 and now - stamp < OPENS then
					return false
				end
				blob.credits += FIRST_REWARD -- ...then decide + write against the STALE read
				blob.streak += 1
				blob.lastClaimUnix = now
				return true
			end
			drain({
				coroutine.create(function()
					naiveClaim(START_UNIX)
				end),
				coroutine.create(function()
					naiveClaim(START_UNIX)
				end),
			})
			expect(blob.credits):toBe(FIRST_REWARD * 2) -- PAID TWICE
			expect(blob.streak):toBe(2)
			expect(blob.credits).never:toBe(FIRST_REWARD)
		end
	)
end)

-- ── 8. persistence: the record round-trips and the cooldown survives a rejoin ────────────────────

describe("daily: the persisted record round-trips through save -> leave -> rejoin", function()
	it("the streak and the stamp survive, and the cooldown is NOT reset by relogging", function()
		-- The most valuable exploit here is the cheapest one: claim, leave, rejoin, claim again.
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h.clock:advance(OPENS)
		expect(h:claim(player)):toBeOk() -- streak 2
		local before = h:snapshot(player)
		expect(before.streak):toBe(2)

		h:leave(player)
		local returning = h:join(1) -- a FRESH load from the store: the blob is the only memory
		local reloaded = h:snapshot(returning)
		expect(reloaded.streak):toBe(2)
		expect(reloaded.lastClaimUnix):toBe(before.lastClaimUnix)
		expect(reloaded.credits):toBe(before.credits)

		expect(h:claim(returning)):toBeErr(Result.Codes.OnCooldown) -- relogging is not a reset
		expect(h:snapshot(returning).credits):toBe(before.credits)
	end)

	it("relog-spam across ten rejoins mints nothing extra", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		for _ = 1, 10 do
			h:leave(player)
			local back = h:join(1)
			expect(h:claim(back)):toBeErr(Result.Codes.OnCooldown)
			player = back
		end
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(1)
	end)

	it("a rejoin INSIDE the window continues the streak across the round-trip", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h:leave(player)
		h.clock:advance(OPENS + 30 * 60)
		local returning = h:join(1)
		local claimed = h:claim(returning)
		expect(claimed):toBeOk()
		expect((claimed :: any).value.streak):toBe(2)
		expect((claimed :: any).value.continued):toBe(true)
	end)
end)

describe("daily: the v3->v4 persistence shape", function()
	it(
		"a pre-v4 blob migrates to daily = { streak = 0, lastClaimUnix = 0 } and is claimable",
		function()
			local legacy: any = { schemaVersion = 3, currencies = { Credits = 0 } }
			local migrated = Migrations.migrate(legacy)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(type(migrated.daily)):toBe("table")
			expect(migrated.daily.streak):toBe(0)
			expect(migrated.daily.lastClaimUnix):toBe(0) -- 0 means "never claimed"

			-- and a never-claimed record is immediately claimable at streak 1.
			local status = DailyDropService:windowFor(migrated.daily.lastClaimUnix, START_UNIX)
			expect(status):toBe(DailyDropService.Status.Never)
			expect(DailyDropService:streakAfter(migrated.daily.streak, status)):toBe(1)
		end
	)

	it("a migrated legacy player gets a real claim, once, through the whole stack", function()
		local clock = Mocks.clock(START_UNIX)
		-- A REAL pre-v4 record: the current seed, rolled back to v3 by removing the field v3->v4
		-- introduces. Hand-rolling a v3 literal would drift from what v3 actually stored.
		local legacy: any = Migrations.default(START_UNIX - 10 * 24 * HOUR)
		legacy.schemaVersion = 3
		legacy.daily = nil
		local store = Mocks.store({
			clock = clock,
			config = Config,
			seed = { [`{Config.schemaKeyPrefix}5`] = legacy },
		})
		local data = DataService.new(store, clock, Config, Mocks.logWarn)
		local analytics = AnalyticsService.new(clock)
		local economy = EconomyService.new(analytics)
		DailyDropService:Start({
			clock = clock,
			data = data,
			net = {
				register = function() end,
			},
			economy = economy,
		})
		local player = Mocks.player(5)
		expect(data:loadSession(player)):toBeOk()

		local claimed = DailyDropService:claim({
			player = player,
			clock = clock,
			data = data,
			economy = economy,
		})
		expect(claimed):toBeOk()
		expect((claimed :: any).value.streak):toBe(1)
		local blob = (data:get(player) :: any).value
		expect(blob.daily.lastClaimUnix):toBe(START_UNIX)
		expect(blob.currencies.Credits):toBe(FIRST_REWARD)
	end)

	it("a stamp AHEAD of the server clock can never grant early, and never bricks", function()
		-- A blob carrying a future lastClaimUnix (a mis-set clock, a foreign clock base) must not be
		-- a free claim, and must not make the drop unclaimable for the life of the record.
		local h = newServer()
		local player = h:join(1)
		h.data:update(player, function(d: any): any
			d.daily.lastClaimUnix = START_UNIX + 10 * 24 * HOUR
			d.daily.streak = 4
			return d
		end)

		expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown) -- no early mint
		expect(h:snapshot(player).credits):toBe(0)

		h.clock:advance(OPENS)
		local claimed = h:claim(player)
		expect(claimed):toBeOk() -- and the feature came back to life
		expect(h:snapshot(player).credits):toBe((claimed :: any).value.reward)
	end)

	it(
		"a small future skew opens the window 20h after the REAL claim, not after the heal",
		function()
			-- [ASSERTION FLIPPED — this case used to pin the defect it was written to describe. It read
			--  the healed stamp back as START_UNIX and then advanced EXACTLY `OPENS` from it, calling the
			--  result "one window later, not one window plus the skew". That is one window minus the skew
			--  measured from the player's ACTUAL last claim: the heal was silently paying the cooldown
			--  down. The slice's sentence is "the claim opens once 20h have elapsed since the LAST
			--  CLAIM", so 20h is counted from the stamp the last claim wrote — the correct answer here is
			--  OPENS after START_UNIX + skew, i.e. OPENS + skew from START_UNIX.]
			--
			-- A stamp a few minutes ahead of this server's clock is ordinary inter-server skew, not a
			-- broken record: it is self-correcting (elapsed is briefly negative, so the window reads
			-- CLOSED, and once `now` overtakes the stamp the 20h counts from the real claim), so it is
			-- left ALONE rather than healed. Nothing is granted early and nothing is bricked.
			local skew = 300
			expect(skew < DailyDropService.MAX_FUTURE_SKEW_SECONDS):toBe(true)
			local h = newServer()
			local player = h:join(1)
			local realClaimUnix = START_UNIX + skew
			h.data:update(player, function(d: any): any
				d.daily.lastClaimUnix = realClaimUnix
				d.daily.streak = 3
				return d
			end)

			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown) -- never early
			expect(h:snapshot(player).credits):toBe(0)
			-- ...and the refusal did NOT rewrite the player's stamp down to this server's clock. A heal
			-- here is a cooldown discount: every later window would be measured from `now` instead of
			-- from the claim the player actually made.
			expect(h:snapshot(player).lastClaimUnix):toBe(realClaimUnix)

			-- One window after the REAL claim — which is OPENS + skew from START_UNIX, not OPENS.
			h.clock:advance(OPENS - 1)
			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
			h.clock:advance(skew)
			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown) -- still one second short
			expect(h:snapshot(player).credits):toBe(0)
			h.clock:advance(1)
			expect(h.clock:unix()):toBe(realClaimUnix + OPENS)
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.streak):toBe(4) -- and the skew did not cost the streak either
		end
	)

	it("a repeated future stamp cannot ACCELERATE the drop cycle after cycle", function()
		-- The compounding shape the skew case bounds: claim on a server whose clock runs `skew`
		-- ahead, hop to a slower one, let it heal the stamp down to its own `now`, and the next
		-- window opens `skew` early — every single cycle. Three cycles of it here; each one must
		-- cost the player a FULL 20h measured from the stamp their claim actually wrote.
		local skew = 600
		local h = newServer()
		local player = h:join(1)

		for _ = 1, 3 do
			-- the fast server's stamp, as this (slower) server finds it in the blob
			local stampedAt = h.clock:unix() + skew
			h.data:update(player, function(d: any): any
				d.daily.lastClaimUnix = stampedAt
				return d
			end)
			local paid = h:snapshot(player).credits

			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown) -- the hop itself grants nothing
			h.clock:advance(OPENS - 1)
			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
			h.clock:advance(skew) -- 20h since THIS server's clock, but only 20h - skew since the claim
			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
			expect(h:snapshot(player).credits):toBe(paid) -- nothing was minted early
			h.clock:advance(1)
			expect(h.clock:unix()):toBe(stampedAt + OPENS)
			expect(h:claim(player)):toBeOk()
		end
	end)

	it(
		"an ABSURDLY future stamp is still healed AND persisted — the drop never bricks",
		function()
			-- The other half of the tolerance, and the reason the heal exists at all: a stamp so far
			-- ahead that waiting it out is indistinguishable from losing the feature (a foreign clock
			-- base, a millisecond timestamp) IS repaired, and the repair is WRITTEN BACK. A read-only
			-- clamp re-clamps to the moving `now` on every request, pinning elapsed at 0 forever.
			local h = newServer()
			local player = h:join(1)
			local absurd = START_UNIX + 10 * 24 * HOUR
			expect(absurd > START_UNIX + DailyDropService.MAX_FUTURE_SKEW_SECONDS):toBe(true)
			h.data:update(player, function(d: any): any
				d.daily.lastClaimUnix = absurd
				d.daily.streak = 3
				return d
			end)

			expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
			expect(h:snapshot(player).lastClaimUnix):toBe(START_UNIX) -- healed, and PERSISTED at now
			h.clock:advance(OPENS)
			local claimed = h:claim(player)
			expect(claimed):toBeOk() -- one window after the heal, never ten days
			expect((claimed :: any).value.streak):toBe(4)
		end
	)
end)

-- ── 9. the HUD badge's data path: daily rides the replicated view ───────────────────────────────

describe("daily: the badge is fed from the PlayerView after a committed claim", function()
	it("toView carries the daily record (streak + lastClaimUnix)", function()
		local data = Migrations.default(START_UNIX)
		data.daily.streak = 3
		data.daily.lastClaimUnix = START_UNIX
		local view: any = Types.toView(data :: any)
		expect(view.daily.streak):toBe(3)
		expect(view.daily.lastClaimUnix):toBe(START_UNIX)
	end)

	it("a granted claim pushes a refreshed view whose daily.streak is the NEW streak", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h.clock:advance(OPENS)
		expect(h:claim(player)):toBeOk()

		expect(#h.pushes > 0):toBe(true)
		local last = h.pushes[#h.pushes]
		expect(last.channel):toBe("data")
		expect(last.player):toBe(player)
		expect(last.payload.daily.streak):toBe(2)
		expect(last.payload.daily.lastClaimUnix):toBe(h.clock:unix())
		expect(last.payload.currencies.Credits):toBe(h:snapshot(player).credits)
	end)

	it("a REFUSED claim announces nothing", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local pushed = #h.pushes
		expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
		expect(#h.pushes):toBe(pushed)
	end)

	it("a THROWING view push never turns a committed grant into an error", function()
		-- The presentation layer is downstream of the money. An unguarded post-write FireClient is
		-- how a committed economy write once came back to the client as Err(Internal).
		local h = newServer({ fireClientThrows = true })
		local player = h:join(1)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expect((claimed :: any).value.reward):toBe(FIRST_REWARD)
		expect(h:snapshot(player).credits):toBe(FIRST_REWARD) -- the Credits are really committed
	end)
end)

-- ── 10. the wire surface ────────────────────────────────────────────────────────────────────────

describe("daily: the registered action", function()
	it("registers exactly daily.claim, with a rate policy that actually limits", function()
		local h = newServer()
		local action = h.registered[Net.Actions.ClaimDaily]
		expect(action ~= nil):toBe(true)
		expect(action.name):toBe(Net.Actions.ClaimDaily)
		expect(type(action.validate)):toBe("function")
		expect(type(action.handler)):toBe("function")
		expect(action.rate.maxPerWindow > 0):toBe(true)
		expect(action.rate.windowSeconds > 0):toBe(true)

		-- "EXACTLY daily.claim" is a claim about the COUNT, and nothing used to count. A service that
		-- also registered a second, unvalidated action (a debug grant, an alias) passed this case.
		local names: { string } = {}
		for name in h.registered do
			table.insert(names, name)
		end
		table.sort(names)
		expect(#names):toBe(1)
		expect(names[1]):toBe(Net.Actions.ClaimDaily)

		-- ...and "with a rate policy" has to bound the bucket from ABOVE or it means nothing:
		-- { maxPerWindow = 10000, windowSeconds = 0.001 } satisfies "> 0" on both and is no
		-- anti-spam bucket at all. The legal cadence of this action is ONE claim per 20h, so a
		-- sustained allowance above one request per second is pure spam surface, and a burst
		-- capacity in double figures lets a click-storm reach the transform.
		expect(action.rate.maxPerWindow <= 10):toBe(true)
		expect(action.rate.maxPerWindow / action.rate.windowSeconds <= 1):toBe(true)
	end)

	it("an unregistered sibling action name is UnknownAction (no accidental alias)", function()
		local h = newServer()
		local net = h:wire()
		local player = h:join(1)
		expect(net.invoke("daily.grant", player, nil)):toBeErr(Result.Codes.UnknownAction)
		expect(h:snapshot(player).credits):toBe(0)
	end)

	it("a finished claim STRANDS no reservation — and Stop clears the table besides", function()
		-- [TITLE + BODY REPAIRED. This case used to be titled "Stop clears the in-flight reservations"
		--  and asserted only that `_claiming` is empty AFTER Stop — which Stop does unconditionally
		--  (`self._claiming = {}`), so it was true no matter what claim leaked. The guarantee worth
		--  having is that claim releases its OWN reservation on every path, because a stranded flag
		--  locks that player out of the drop for the life of the server AND is invisible: the next
		--  claim is refused with OnCooldown, the very same code the window itself uses.]
		local h = newServer()
		local player = h:join(1)

		expect(h:claim(player)):toBeOk()
		expect(DailyDropService._claiming[player.UserId]):toBe(nil) -- granted: released
		expect(h:claim(player)):toBeErr(Result.Codes.OnCooldown)
		expect(DailyDropService._claiming[player.UserId]):toBe(nil) -- refused: released
		local exploding: any = {
			earn = function(): any
				error("boom")
			end,
		}
		expect(h:claim(player, { economy = exploding })):toBeErr()
		expect(DailyDropService._claiming[player.UserId]):toBe(nil) -- threw: released
		local ghost = Mocks.player(4242)
		expect(h:claim(ghost)):toBeErr(Result.Codes.NoData)
		expect(DailyDropService._claiming[ghost.UserId]):toBe(nil) -- no session: released
		expect(next(DailyDropService._claiming :: any)):toBe(nil)

		DailyDropService:Stop({})
		expect(next(DailyDropService._claiming :: any)):toBe(nil)
		-- and a fresh Start makes it claimable again (module state does not leak between servers).
		local h2 = newServer()
		expect(h2:claim(h2:join(1))):toBeOk()
	end)
end)
