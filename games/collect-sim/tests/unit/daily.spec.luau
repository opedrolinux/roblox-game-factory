--!strict
-- games/collect-sim/tests/unit/daily.spec.luau   [INDEPENDENT TEST GATE — authored from the daily-streak spec slice]
-- Adversarial Tier-1 gate for the "Daily streak" feature (the once-per-day SERVER-CLOCK-gated reward).
-- Authored from the SPEC's behavioral guarantees, NOT the implementation's branch logic (maker !=
-- checker). The economy red-team target here is the TIME-GATE analog of a double-spend: a spam /
-- interleaved daily.claim in one window must grant EXACTLY ONCE.
--
-- The SPEC pins these EXACT server-owned windows (we encode them as the contract; the reward BASE is
-- DISCOVERED through the API — the first claim returns it — so we never copy the implementation curve):
--   COOLDOWN     = 72000s  (20h): claim allowed only when now - lastClaimUnix >= COOLDOWN.
--   STREAK_RESET = 172800s (48h): MORE than this elapsed -> streak resets to 1; otherwise increments.
--
-- We drive the action the SAME way production does: Start({ net = harness.registry }) registers the
-- Daily action onto a Mocks.net harness, then we invoke through the REAL Net.dispatch, with a real
-- DataService over a MockStore as ctx.data. Time comes ONLY from the injected fake clock (clock:advance).
-- Stardust / streak / lastClaimUnix are read back through DataService:get (the persisted, lock-queued
-- state) so a double-grant, a phantom streak bump, or a payload-smuggled time would be observable.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local DailyStreakService = require("../../src/server/services/daily/DailyStreakService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local DAILY = Net.Actions.Daily -- "daily.claim"

-- The SPEC's pinned server-owned windows (the wire contract behavior is graded against THESE).
local COOLDOWN = 72000 -- 20h
local STREAK_RESET = 172800 -- 48h

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build the daily service wired onto a fresh Mocks.net harness over a DataService with one loaded
-- player. Returns (harness, data, player, clock). `opts` flows to the mock store (yieldOnUpdate) and
-- the harness (gate). gate defaults to false so behavior is isolated from the rate gate; the
-- concurrency tests do NOT rely on the rate gate (it is defence in depth, not the guarantee).
local START_UNIX = 1_000_000 -- a fixed, large server "now" so windows never go negative
local function setup(opts: any?): (any, any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(o.startUnix or START_UNIX)
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
	DailyStreakService:Start({ net = harness.registry })
	return harness, data, player, clock
end

-- Read the persisted Stardust balance through the lock-queued data layer.
local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Read the persisted streak.
local function streakOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.daily.streak or 0
end

-- Read the persisted lastClaimUnix.
local function lastClaimOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.daily.lastClaimUnix or 0
end

-- Round-robin coroutine driver: resume every suspended coroutine until all are dead. Deterministic,
-- deadlock-guarded. (Identical technique to economy_race.spec / shop.spec — the ONLY way to genuinely
-- interleave two requests against the per-player FIFO lock; sequential calls do NOT prove this.)
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

-- Discover the BASE reward (streak-1 reward) through the API on a clean serial player, so expectations
-- are parametrized by the observed server-derived value, never a copied constant.
local function discoverBase(): number
	local h, _d, p = setup({ userId = 90001 })
	local r = h.invoke(DAILY, p, {})
	expect(r):toBeOk()
	local v = (r :: any).value
	expect(v.streak):toBe(1)
	return v.reward
end

describe("Daily streak — first claim (streak 1, base reward, server-now persisted)", function()
	it(
		"first-ever claim -> streak 1, grants the base reward, persists lastClaimUnix == server now",
		function()
			local harness, data, player, clock = setup()
			-- A fresh player starts at zero on all three.
			expect(balanceOf(data, player)):toBe(0)
			expect(streakOf(data, player)):toBe(0)
			expect(lastClaimOf(data, player)):toBe(0)

			local now = clock:unix()
			local r = harness.invoke(DAILY, player, {})
			expect(r):toBeOk()
			local v = (r :: any).value

			-- Return shape: { claimed = true, streak, reward, balance = NEW Stardust }.
			expect(v.claimed):toBe(true)
			expect(v.streak):toBe(1)
			expect(type(v.reward)):toBe("number")
			expect(v.reward > 0):toBe(true) -- the base grant is positive

			-- All three persisted: streak 1, lastClaimUnix == the SERVER now, balance == reward (from 0).
			expect(streakOf(data, player)):toBe(1)
			expect(lastClaimOf(data, player)):toBe(now) -- the server clock value, not the payload
			expect(balanceOf(data, player)):toBe(v.reward)
			expect(v.balance):toBe(v.reward) -- returned balance == new persisted balance
			expect(balanceOf(data, player)):toBe(v.balance)
		end
	)

	it(
		"the reward is server-DERIVED and scales with the streak (base, 2*base at streak 2)",
		function()
			local harness, _data, player, clock = setup()
			local first = harness.invoke(DAILY, player, {})
			expect(first):toBeOk()
			local base = (first :: any).value.reward

			-- Advance into the increment window (>= COOLDOWN, <= STREAK_RESET) and claim again.
			clock:advance(COOLDOWN)
			local second = harness.invoke(DAILY, player, {})
			expect(second):toBeOk()
			local v = (second :: any).value
			expect(v.streak):toBe(2)
			-- The reward escalates with the streak: strictly more than the base (until/unless a cap binds).
			-- For streak 2 the spec's relational base*streak gives 2*base; assert the relation, not a constant.
			expect(v.reward >= base):toBe(true)
			expect(v.reward):toBe(base * 2)
		end
	)
end)

describe("Daily streak — within cooldown (OnCooldown, nothing changes)", function()
	it(
		"a second claim 1h later -> Err(OnCooldown); Stardust, streak, lastClaimUnix ALL unchanged",
		function()
			local harness, data, player, clock = setup()
			local first = harness.invoke(DAILY, player, {})
			expect(first):toBeOk()
			local claimedAt = lastClaimOf(data, player)
			local bal = balanceOf(data, player)
			local streak = streakOf(data, player)
			expect(streak):toBe(1)

			clock:advance(3600) -- +1h, well within the 20h cooldown
			local r = harness.invoke(DAILY, player, {})
			expect(r):toBeErr(Result.Codes.OnCooldown)

			-- NO grant, NO streak change, NO timestamp change.
			expect(balanceOf(data, player)):toBe(bal)
			expect(streakOf(data, player)):toBe(streak)
			expect(lastClaimOf(data, player)):toBe(claimedAt)
		end
	)

	it("repeated sub-cooldown spam never mints and never advances the streak", function()
		local harness, data, player, clock = setup()
		expect(harness.invoke(DAILY, player, {})):toBeOk()
		local bal = balanceOf(data, player)

		-- Hammer it many times at increasing-but-still-sub-cooldown offsets: every one is OnCooldown.
		for _, dt in { 1, 60, 3600, 36000, COOLDOWN - 1 } do
			clock:advance(dt)
			-- Re-anchor: total elapsed must stay < COOLDOWN. We reset the clock window per iteration by
			-- only ever advancing to just-under cooldown from the SAME claim, so check the cumulative.
			if clock:unix() - lastClaimOf(data, player) < COOLDOWN then
				expect(harness.invoke(DAILY, player, {})):toBeErr(Result.Codes.OnCooldown)
				expect(balanceOf(data, player)):toBe(bal)
				expect(streakOf(data, player)):toBe(1)
			end
		end
	end)

	it(
		"BOUNDARY: claiming at exactly COOLDOWN-1 is still OnCooldown (the gate is >=, strict below)",
		function()
			local harness, data, player, clock = setup()
			expect(harness.invoke(DAILY, player, {})):toBeOk()
			local bal = balanceOf(data, player)

			clock:advance(COOLDOWN - 1) -- one second short of the window opening
			local r = harness.invoke(DAILY, player, {})
			expect(r):toBeErr(Result.Codes.OnCooldown)
			expect(balanceOf(data, player)):toBe(bal)
			expect(streakOf(data, player)):toBe(1)
		end
	)
end)

describe(
	"Daily streak — claim after cooldown, within reset (streak increments, reward escalates)",
	function()
		it(
			"a claim 21h after the last -> streak increments to 2, reward escalates, timestamp updated",
			function()
				local harness, data, player, clock = setup()
				local first = harness.invoke(DAILY, player, {})
				expect(first):toBeOk()
				local base = (first :: any).value.reward
				local bal1 = balanceOf(data, player)

				clock:advance(21 * 3600) -- 21h: past the 20h cooldown, well within the 48h reset
				local now = clock:unix()
				local r = harness.invoke(DAILY, player, {})
				expect(r):toBeOk()
				local v = (r :: any).value
				expect(v.streak):toBe(2)
				expect(v.reward):toBe(base * 2) -- escalated with the streak
				-- Balance accrued the second reward; timestamp moved to the new server now.
				expect(balanceOf(data, player)):toBe(bal1 + v.reward)
				expect(lastClaimOf(data, player)):toBe(now)
				expect(streakOf(data, player)):toBe(2)
			end
		)

		it(
			"BOUNDARY: a claim at EXACTLY COOLDOWN elapsed is allowed (>=) and increments the streak",
			function()
				local harness, data, player, clock = setup()
				expect(harness.invoke(DAILY, player, {})):toBeOk()
				expect(streakOf(data, player)):toBe(1)

				clock:advance(COOLDOWN) -- now - last == COOLDOWN exactly -> the window is OPEN (>=)
				local r = harness.invoke(DAILY, player, {})
				expect(r):toBeOk()
				expect((r :: any).value.streak):toBe(2) -- incremented, not rejected, not reset
				expect(streakOf(data, player)):toBe(2)
			end
		)

		it(
			"a multi-day run accumulates the streak (1->2->3->4), each at the cooldown boundary",
			function()
				local harness, data, player, clock = setup()
				local base = (harness.invoke(DAILY, player, {}) :: any).value
				expect(base.streak):toBe(1)
				local baseReward = base.reward
				local expectedBalance = base.reward

				for streak = 2, 4 do
					clock:advance(COOLDOWN) -- exactly at the window, within reset -> increments
					local r = harness.invoke(DAILY, player, {})
					expect(r):toBeOk()
					local v = (r :: any).value
					expect(v.streak):toBe(streak)
					expect(streakOf(data, player)):toBe(streak)
					-- reward is relational base*streak (subject to the implementation's cap if any)
					expect(v.reward >= baseReward):toBe(true)
					expectedBalance += v.reward
					expect(balanceOf(data, player)):toBe(expectedBalance)
				end
			end
		)
	end
)

describe("Daily streak — claim after the reset window (streak RESETS to 1)", function()
	it("a claim 50h after the last (MORE than 48h) -> streak resets to 1", function()
		local harness, data, player, clock = setup()
		-- Build the streak up to 3 first so a reset to 1 is unmistakable (not a no-op increment).
		expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(1)
		clock:advance(COOLDOWN)
		expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(2)
		clock:advance(COOLDOWN)
		expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(3)
		local base = discoverBase()

		clock:advance(50 * 3600) -- 50h since the streak-3 claim: MORE than the 48h reset window
		local now = clock:unix()
		local r = harness.invoke(DAILY, player, {})
		expect(r):toBeOk()
		local v = (r :: any).value
		expect(v.streak):toBe(1) -- lapsed: reset, NOT 4
		expect(v.reward):toBe(base) -- reward is the streak-1 base again
		expect(streakOf(data, player)):toBe(1)
		expect(lastClaimOf(data, player)):toBe(now)
	end)

	it(
		"BOUNDARY: at EXACTLY STREAK_RESET elapsed the streak INCREMENTS (reset is 'MORE than', strict)",
		function()
			-- The spec: reset only when MORE than STREAK_RESET elapsed. So now - last == STREAK_RESET is NOT
			-- a lapse -> it increments. (STREAK_RESET > COOLDOWN, so the cooldown gate is also satisfied.)
			local harness, data, player, clock = setup()
			expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(1)

			clock:advance(STREAK_RESET) -- exactly 48h: the boundary is NOT "more than"
			local r = harness.invoke(DAILY, player, {})
			expect(r):toBeOk()
			expect((r :: any).value.streak):toBe(2) -- increment, NOT reset to 1
			expect(streakOf(data, player)):toBe(2)
		end
	)

	it(
		"BOUNDARY: at STREAK_RESET + 1 the streak DOES reset (just past the lapse threshold)",
		function()
			local harness, data, player, clock = setup()
			expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(1)
			clock:advance(COOLDOWN)
			expect((harness.invoke(DAILY, player, {}) :: any).value.streak):toBe(2)

			clock:advance(STREAK_RESET + 1) -- one second MORE than the reset window -> lapsed
			local r = harness.invoke(DAILY, player, {})
			expect(r):toBeOk()
			expect((r :: any).value.streak):toBe(1) -- reset, NOT 3
			expect(streakOf(data, player)):toBe(1)
		end
	)
end)

describe(
	"Daily streak — server time is authoritative (payload-smuggled fields ignored)",
	function()
		it("malformed payload (non-table) -> Err(BadPayload); no grant, no state change", function()
			local harness, data, player = setup()
			expect(balanceOf(data, player)):toBe(0)
			expect(harness.invoke(DAILY, player, 7)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(DAILY, player, "claim")):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(DAILY, player, true)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(DAILY, player, nil)):toBeErr(Result.Codes.BadPayload)
			-- Nothing minted, nothing stamped, streak still zero.
			expect(balanceOf(data, player)):toBe(0)
			expect(streakOf(data, player)):toBe(0)
			expect(lastClaimOf(data, player)):toBe(0)
		end)

		it(
			"a client-smuggled now/time field in the payload is IGNORED — the server clock decides",
			function()
				local harness, data, player, clock = setup()
				expect(harness.invoke(DAILY, player, {})):toBeOk()
				local claimedAt = lastClaimOf(data, player)
				local bal = balanceOf(data, player)

				clock:advance(3600) -- still inside cooldown on the SERVER clock
				-- The client lies: claims a huge `now`/`time` to pretend the window has passed. Must be ignored.
				local r = harness.invoke(DAILY, player, {
					now = clock:unix() + STREAK_RESET * 10,
					time = clock:unix() + STREAK_RESET * 10,
					unix = clock:unix() + STREAK_RESET * 10,
					lastClaimUnix = 0, -- "I never claimed", please
				})
				expect(r):toBeErr(Result.Codes.OnCooldown) -- the SERVER clock still says cooldown
				expect(balanceOf(data, player)):toBe(bal)
				expect(lastClaimOf(data, player)):toBe(claimedAt) -- the server-stamped time stands
			end
		)

		it(
			"a client-smuggled reward/amount/balance field is IGNORED — the grant is server-derived",
			function()
				local harness, data, player, clock = setup()
				local base = discoverBase()

				clock:advance(0) -- first claim for THIS player at start
				local r = harness.invoke(DAILY, player, {
					reward = 999_999_999, -- please grant me a billion
					amount = 999_999_999,
					balance = 999_999_999,
					streak = 50, -- and jump me to streak 50
				})
				expect(r):toBeOk()
				local v = (r :: any).value
				expect(v.streak):toBe(1) -- the client's streak=50 was ignored
				expect(v.reward):toBe(base) -- the client's reward was ignored; server base granted
				expect(balanceOf(data, player)):toBe(base) -- exactly the server reward, not a billion
				expect(v.balance):toBe(base)
			end
		)
	end
)

describe(
	"Daily streak — concurrency: spam/interleaved claim grants EXACTLY once (time-gate double-spend)",
	function()
		-- The economy_race technique: drive interleaved invocations as coroutines against a yielding store
		-- so the second claim arrives WHILE the first is parked inside the lock-held data:update. The first
		-- writes lastClaimUnix = now; the second RE-READS it (now - now = 0 < COOLDOWN) and is shed as
		-- OnCooldown. Never double-grants Stardust, never double-increments the streak. Sequential calls
		-- would NOT prove this — the yield + drain genuinely interleaves them under the FIFO lock.

		it(
			"TWO interleaved first-claims -> exactly ONE grant, ONE streak bump, the other OnCooldown",
			function()
				local harness, data, player = setup({ yieldOnUpdate = true })
				expect(balanceOf(data, player)):toBe(0)
				expect(streakOf(data, player)):toBe(0)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.a = harness.invoke(DAILY, player, {})
					end),
					coroutine.create(function()
						results.b = harness.invoke(DAILY, player, {})
					end),
				}
				drain(cos)

				-- Exactly ONE Ok, exactly one OnCooldown (the loser re-read the just-written timestamp).
				local oks = 0
				local okValue: any = nil
				for _, key in { "a", "b" } do
					local r = results[key]
					if r.ok then
						oks += 1
						okValue = r.value
					else
						expect(r):toBeErr(Result.Codes.OnCooldown) -- NOT a second grant, NOT Internal
					end
				end
				expect(oks):toBe(1) -- NEVER two grants in one window

				-- Persisted state reflects exactly ONE claim: streak 1 (not 2), balance == the single reward.
				expect(streakOf(data, player)):toBe(1)
				expect(okValue.streak):toBe(1)
				expect(balanceOf(data, player)):toBe(okValue.reward) -- exactly one grant, no double-mint
			end
		)

		it(
			"FOUR spam-duplicated claims in one window -> exactly ONE grant (the rest shed OnCooldown)",
			function()
				local harness, data, player = setup({ yieldOnUpdate = true })

				local results: { any } = {}
				local cos = {}
				for i = 1, 4 do
					local idx = i
					table.insert(
						cos,
						coroutine.create(function()
							results[idx] = harness.invoke(DAILY, player, {})
						end)
					)
				end
				drain(cos)

				local oks = 0
				local okValue: any = nil
				for i = 1, 4 do
					local r = results[i]
					if r.ok then
						oks += 1
						okValue = r.value
					else
						expect(r):toBeErr(Result.Codes.OnCooldown) -- spam losers shed cleanly, no mint
					end
				end
				expect(oks):toBe(1) -- exactly one of four spam clicks claimed
				expect(streakOf(data, player)):toBe(1) -- streak bumped exactly once
				expect(balanceOf(data, player)):toBe(okValue.reward) -- exactly one reward minted
			end
		)

		it(
			"interleaved claims in a LATER window still grant exactly once (streak bumps by exactly 1)",
			function()
				-- Establish streak 1 serially, advance one full day, then fire two interleaved claims. The window
				-- is open, so ONE succeeds (streak -> 2) and the other re-reads now and is shed: streak is 2, not
				-- 3, and only one reward is added on top of the first.
				local harness, data, player, clock = setup({ yieldOnUpdate = true })

				-- Seed the first claim through a drained coroutine (the store yields on update).
				local seed: any = nil
				drain({
					coroutine.create(function()
						seed = harness.invoke(DAILY, player, {})
					end),
				})
				expect(seed):toBeOk()
				expect(streakOf(data, player)):toBe(1)
				local balAfterFirst = balanceOf(data, player)

				clock:advance(COOLDOWN) -- a full window later: the next claim is allowed
				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.a = harness.invoke(DAILY, player, {})
					end),
					coroutine.create(function()
						results.b = harness.invoke(DAILY, player, {})
					end),
				}
				drain(cos)

				local oks = 0
				local okValue: any = nil
				for _, key in { "a", "b" } do
					local r = results[key]
					if r.ok then
						oks += 1
						okValue = r.value
					else
						expect(r):toBeErr(Result.Codes.OnCooldown)
					end
				end
				expect(oks):toBe(1) -- exactly one grant in the second window
				expect(okValue.streak):toBe(2) -- incremented by exactly 1, never 3
				expect(streakOf(data, player)):toBe(2)
				expect(balanceOf(data, player)):toBe(balAfterFirst + okValue.reward) -- exactly one extra grant
			end
		)
	end
)

describe("Daily streak — rate limit (defence in depth, not the concurrency guarantee)", function()
	it("spamming daily.claim past the action's rate window -> Err(RateLimited)", function()
		-- A REAL gate + injected clock enforces the action's own RatePolicy. After the first claim the
		-- rest are OnCooldown (cheap, mints nothing); past the bucket they shed as RateLimited.
		local clock = Mocks.clock(START_UNIX)
		local gate = Mocks.gate(clock)
		local harness, data, player = setup({ gate = gate, startUnix = START_UNIX })

		expect(harness.invoke(DAILY, player, {})):toBeOk() -- first claim grants
		local bal = balanceOf(data, player)

		local hitRateLimit = false
		for _ = 1, 50 do
			local r = harness.invoke(DAILY, player, {})
			if not r.ok and r.code == Result.Codes.RateLimited then
				hitRateLimit = true
				break
			end
			-- before the gate sheds, a same-window re-claim is OnCooldown (never a second Ok grant)
			expect(r):toBeErr(Result.Codes.OnCooldown)
		end
		expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
		expect(balanceOf(data, player)):toBe(bal) -- not a single extra Stardust was minted by the spam
	end)
end)
