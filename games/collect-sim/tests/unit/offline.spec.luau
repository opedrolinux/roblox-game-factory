--!strict
-- games/collect-sim/tests/unit/offline.spec.luau   [INDEPENDENT TEST GATE — authored from the offline spec slice]
-- Adversarial Tier-1 gate for the "Offline earnings" feature. Authored from the SPEC's behavioral
-- guarantees, NOT from the implementation's branch logic (maker != checker). The spec slice:
--   * Passive collectors accrue CAPPED Stardust while away, claimed on join.
--   * The accrual base is the EXISTING server-written timestamps.lastSeenUnix (the data layer stamps it
--     on save/release/join); elapsed = ctx.clock:unix() - lastSeenUnix — SERVER-derived, NEVER client.
--   * Accrued Stardust = a server-owned per-second rate * elapsed, scaled by the player's CURRENT
--     highest-unlocked-island mote value (ctx.islands:multiplierFor(d)), CAPPED at a server-owned ceiling
--     (so a long absence OR a forged clock cannot mint unbounded Stardust).
--   * IDEMPOTENT claim-on-join: claiming advances lastSeenUnix to now INSIDE the transform so a re-claim
--     accrues from ZERO — claiming twice in one session grants nothing the second time.
--   * Crediting offline Stardust is an EARN path: increment stats.lifetimeStardust by the same amount and
--     emit currency_earned THROUGH ctx.analytics.
--   * Success: capped Stardust claimed on join, on SERVER time; offline-time forgery yields nothing extra.
--
-- We drive the action the SAME way production does: call Start({ net = harness.registry }) so the
-- ClaimOffline action registers onto a Mocks.net harness, then invoke through the REAL Net.dispatch with a
-- real DataService over a MockStore as ctx.data. Stardust, lifetimeStardust and lastSeenUnix are read back
-- through DataService:get — the persisted, lock-queued state — so a mint, a phantom grant, a double-grant
-- or a missed advance is OBSERVABLE.
--
-- The server-owned RATE and CAP constants are DISCOVERED through the API (probe claims), never copied from
-- the implementation: we infer rate from a small elapsed and CAP from where the grant plateaus.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local OfflineService = require("../../src/server/services/offline/OfflineService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local CLAIM = Net.Actions.ClaimOffline -- "offline.claim"

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Round-robin coroutine driver: resume every suspended coroutine until all are dead. Used both to seed
-- through a yielding store and to interleave race invocations. Deterministic, deadlock-guarded.
-- (Identical technique to economy_race.spec / islands.spec — the REQUIRED concurrency mechanism.)
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

-- Build the offline action wired onto a fresh Mocks.net harness over a DataService with one loaded
-- player. `opts.yieldOnUpdate` flows to the mock store; `opts.gate` defaults to false so behavior is
-- isolated from the rate gate; `opts.analytics` is optionally injected to observe emitted events.
-- IMPORTANT: loadSession STAMPS timestamps.lastSeenUnix = clock:unix() at load time, so a fresh player's
-- accrual base equals the start time — to simulate offline time we ADVANCE the clock (server time) or set
-- lastSeenUnix into the past via the canonical write path. The clock is returned so a test controls time.
local function setup(opts: any?): (any, any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(o.startUnix or 1000)
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
	if o.analytics ~= nil then
		harnessOpts.analytics = o.analytics
	end
	local harness = Mocks.net(harnessOpts)
	OfflineService:Start({ net = harness.registry })
	return harness, data, player, clock
end

-- Read the persisted Stardust balance through the lock-queued data layer.
local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Read the persisted lifetimeStardust earn counter.
local function lifetimeOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.stats.lifetimeStardust or 0
end

-- Read the persisted accrual base (the server-written lastSeenUnix).
local function lastSeenOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.timestamps.lastSeenUnix
end

-- Force lastSeenUnix into the past through the canonical write path (drained for yielding stores). This
-- models "the data layer wrote lastSeenUnix at save/release, then the player was away `seconds`".
local function setLastSeen(data: any, player: any, unix: number): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = data:update(player, function(d)
			d.timestamps.lastSeenUnix = unix
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

-- Probe the server-owned RATE/CAP through the API (never the implementation). A claim after `elapsed`
-- seconds of (server) absence, at the identity island multiplier, grants rate*elapsed clamped to CAP.
-- We probe with a SMALL elapsed (un-capped) to read rate, and a HUGE elapsed to read CAP.
local function probeGrant(elapsed: number): number
	-- fresh, isolated player so the probe never pollutes a test's state.
	local harness, _data, player, clock = setup({ userId = 999000 + (elapsed % 1000) })
	clock:advance(elapsed) -- server time moves forward; lastSeenUnix was stamped at load
	local r = harness.invoke(CLAIM, player, {})
	expect(r):toBeOk()
	return (r :: any).value.granted
end

-- Discover the per-second rate from a small (un-capped) window and the CAP from a huge one.
local RATE = probeGrant(60) / 60 -- grant over 60s / 60 == per-second rate (un-capped at 60s)
local CAP = probeGrant(10 ^ 9) -- a 31-year "absence" plateaus at the cap (mult 1)

describe("Offline — server-time accrual since lastSeenUnix (claim-on-join)", function()
	it(
		"a probe with a known elapsed grants rate*elapsed (server-derived from lastSeenUnix)",
		function()
			-- Sanity on the discovered rate: a small window grants a positive, integral amount = rate*elapsed.
			expect(RATE > 0):toBe(true)
			expect(CAP > 0):toBe(true)
			local elapsed = 120
			local expectedRaw = RATE * elapsed
			expect(expectedRaw <= CAP):toBe(true) -- 120s is well under the cap, so it is NOT clamped
			local harness, _data, player, clock = setup()
			clock:advance(elapsed)
			local r = harness.invoke(CLAIM, player, {})
			expect(r):toBeOk()
			local v = (r :: any).value
			expect(v.claimed):toBe(true)
			expect(v.granted):toBe(math.floor(expectedRaw))
			expect(v.elapsed):toBe(elapsed) -- the reported window is the SERVER-derived elapsed
		end
	)

	it("the grant is CREDITED to the persisted Stardust balance, exactly once", function()
		local harness, data, player, clock = setup()
		expect(balanceOf(data, player)):toBe(0)
		clock:advance(300)
		local r = harness.invoke(CLAIM, player, {})
		expect(r):toBeOk()
		local granted = (r :: any).value.granted
		expect(granted):toBe(math.floor(RATE * 300))
		-- persisted balance rose by EXACTLY the grant; the returned balance matches the persisted one.
		expect(balanceOf(data, player)):toBe(granted)
		expect((r :: any).value.balance):toBe(balanceOf(data, player))
	end)

	it(
		"elapsed is read from the PERSISTED base, not from any client field in the payload",
		function()
			-- A real absence of 500s exists in the data (lastSeenUnix set 500s in the past). The client smuggles
			-- a fat elapsed/now/amount — they must ALL be ignored; only the server's lastSeenUnix delta counts.
			local harness, data, player, clock = setup()
			local now = clock:unix()
			setLastSeen(data, player, now - 500) -- the persisted truth: away 500s
			local r = harness.invoke(CLAIM, player, {
				elapsed = 10 ^ 9,
				now = now + 10 ^ 9,
				amount = 10 ^ 9,
				seconds = 10 ^ 9,
				granted = 10 ^ 9,
			})
			expect(r):toBeOk()
			local v = (r :: any).value
			expect(v.elapsed):toBe(500) -- the SERVER window, not the smuggled 1e9
			expect(v.granted):toBe(math.floor(RATE * 500)) -- accrued from the persisted base only
			expect(balanceOf(data, player)):toBe(math.floor(RATE * 500))
		end
	)

	it("a fresh join (lastSeenUnix == now, zero elapsed) grants NOTHING", function()
		-- loadSession stamps lastSeenUnix = now; with no clock advance there is zero offline time.
		local harness, data, player = setup()
		expect(lastSeenOf(data, player)):toBe(1000) -- stamped at load
		local r = harness.invoke(CLAIM, player, {})
		expect(r):toBeOk()
		expect((r :: any).value.granted):toBe(0)
		expect((r :: any).value.elapsed):toBe(0)
		expect(balanceOf(data, player)):toBe(0)
	end)
end)

describe(
	"Offline — CAPPED so a long absence / forged clock cannot mint unbounded Stardust",
	function()
		it("a huge elapsed is CLAMPED to the server-owned cap (not rate*elapsed)", function()
			local harness, data, player, clock = setup()
			clock:advance(10 ^ 7) -- ~116 days; rate*elapsed would be astronomically more than CAP
			local r = harness.invoke(CLAIM, player, {})
			expect(r):toBeOk()
			local granted = (r :: any).value.granted
			expect(granted):toBe(CAP) -- clamped to the ceiling, NOT rate*1e7
			expect(granted < RATE * 10 ^ 7):toBe(true) -- the clamp actually bit
			expect(balanceOf(data, player)):toBe(CAP)
		end)

		it(
			"FORGERY YIELDS NOTHING EXTRA: two absurd-but-different elapsed windows grant the SAME capped amount",
			function()
				-- The forgery defence: a longer absence (or a forged client clock implying one) cannot mint more
				-- than the cap. Two wildly different over-cap windows must grant the identical capped amount.
				local a = probeGrant(10 ^ 8)
				local b = probeGrant(10 ^ 12) -- 100x larger "absence"
				expect(a):toBe(CAP)
				expect(b):toBe(CAP)
				expect(a):toBe(b) -- the forged-larger window mints NOTHING beyond the cap
			end
		)

		it(
			"the cap is the ceiling: claiming after a window just over the cap-equivalent equals CAP",
			function()
				-- elapsed chosen so rate*elapsed is just above CAP -> the grant equals CAP exactly (the boundary).
				local capElapsed = CAP / RATE -- rate*capElapsed == CAP
				local harness, _data, player, clock = setup()
				clock:advance(capElapsed + 5000) -- a bit past the cap window
				local r = harness.invoke(CLAIM, player, {})
				expect(r):toBeOk()
				expect((r :: any).value.granted):toBe(CAP)
			end
		)
	end
)

describe(
	"Offline — IDEMPOTENT claim-on-join (advances lastSeenUnix INSIDE the transform)",
	function()
		it(
			"claiming TWICE in one session grants nothing the second time (re-claim accrues from zero)",
			function()
				local harness, data, player, clock = setup()
				clock:advance(400)
				local first = harness.invoke(CLAIM, player, {})
				expect(first):toBeOk()
				local granted1 = (first :: any).value.granted
				expect(granted1):toBe(math.floor(RATE * 400))
				expect(balanceOf(data, player)):toBe(granted1)

				-- the base was advanced to `now` inside the first claim -> a second immediate claim sees 0 elapsed.
				local second = harness.invoke(CLAIM, player, {})
				expect(second):toBeOk()
				expect((second :: any).value.granted):toBe(0)
				expect((second :: any).value.elapsed):toBe(0)
				-- balance UNCHANGED after the second claim — no double-grant.
				expect(balanceOf(data, player)):toBe(granted1)
			end
		)

		it("the claim ADVANCES the persisted lastSeenUnix to the server `now`", function()
			local harness, data, player, clock = setup()
			clock:advance(250)
			local now = clock:unix()
			local r = harness.invoke(CLAIM, player, {})
			expect(r):toBeOk()
			expect((r :: any).value.granted > 0):toBe(true)
			-- after the claim the base is `now`, so the NEXT window starts from here.
			expect(lastSeenOf(data, player)):toBe(now)
		end)

		it(
			"after a re-claim resets the base, a LATER absence accrues fresh (base genuinely moved)",
			function()
				local harness, data, player, clock = setup()
				clock:advance(200)
				expect((harness.invoke(CLAIM, player, {}) :: any).value.granted):toBe(
					math.floor(RATE * 200)
				)
				local afterFirst = balanceOf(data, player)

				-- a re-claim immediately grants 0 (base == now)...
				expect((harness.invoke(CLAIM, player, {}) :: any).value.granted):toBe(0)
				expect(balanceOf(data, player)):toBe(afterFirst)

				-- ...but advancing time again accrues ONLY the NEW window (not 200+150), proving the base moved.
				clock:advance(150)
				local third = harness.invoke(CLAIM, player, {})
				expect((third :: any).value.granted):toBe(math.floor(RATE * 150))
				expect(balanceOf(data, player)):toBe(afterFirst + math.floor(RATE * 150))
			end
		)

		it("a zero-grant re-claim does NOT touch lifetimeStardust (not an earn event)", function()
			local harness, data, player, clock = setup()
			clock:advance(300)
			expect(harness.invoke(CLAIM, player, {})):toBeOk()
			local lifeAfterFirst = lifetimeOf(data, player)
			expect(lifeAfterFirst):toBe(math.floor(RATE * 300))
			-- the no-op re-claim grants 0 -> lifetime must not move.
			expect(harness.invoke(CLAIM, player, {})):toBeOk()
			expect(lifetimeOf(data, player)):toBe(lifeAfterFirst)
		end)
	end
)

describe(
	"Offline — EARN path: lifetimeStardust accrues + currency_earned emitted through analytics",
	function()
		it(
			"a grant increments stats.lifetimeStardust by the SAME amount as the balance gain",
			function()
				local harness, data, player, clock = setup()
				local life0 = lifetimeOf(data, player)
				clock:advance(360)
				local r = harness.invoke(CLAIM, player, {})
				expect(r):toBeOk()
				local granted = (r :: any).value.granted
				expect(granted > 0):toBe(true)
				-- lifetime rose by EXACTLY the grant (monotonic earn counter), same as the balance gain.
				expect(lifetimeOf(data, player) - life0):toBe(granted)
				expect(balanceOf(data, player)):toBe(granted)
			end
		)

		it(
			"a successful claim emits currency_earned (Stardust, amount == granted, source offline)",
			function()
				local events: { any } = {}
				local analytics = {
					emit = function(_self: any, name: string, payload: any)
						table.insert(events, { name = name, payload = payload })
					end,
				}
				local harness, _data, player, clock = setup({ analytics = analytics })
				clock:advance(500)
				local r = harness.invoke(CLAIM, player, {})
				expect(r):toBeOk()
				local granted = (r :: any).value.granted
				expect(granted > 0):toBe(true)

				local sawEarned = false
				for _, e in events do
					if e.name == "currency_earned" then
						sawEarned = true
						expect(e.payload.currency):toBe("Stardust")
						expect(e.payload.amount):toBe(granted) -- reports the granted amount, not a forged one
						expect(e.payload.userId):toBe(player.UserId)
						expect(e.payload.source):toBe("offline")
					end
				end
				expect(sawEarned):toBe(true)
			end
		)

		it(
			"a zero-grant claim emits NOTHING through analytics (a no-op re-claim is not an earn event)",
			function()
				local count = 0
				local analytics = {
					emit = function(_self: any, _name: string, _payload: any)
						count += 1
					end,
				}
				-- fresh join -> zero elapsed -> zero grant -> no event.
				local harness, _data, player = setup({ analytics = analytics })
				local r = harness.invoke(CLAIM, player, {})
				expect(r):toBeOk()
				expect((r :: any).value.granted):toBe(0)
				expect(count):toBe(0)
			end
		)
	end
)

describe("Offline — scaled by the player's CURRENT highest unlocked island mote value", function()
	-- Mocks.net does NOT forward ctx.islands, so the offline service sees the identity seam (mult 1) there.
	-- To exercise the SCALING guarantee we drive the REAL Net.dispatch directly with a ctx that publishes
	-- an islands seam — the same function production uses, just with the seam wired (production wires it
	-- via the shared ServerContext). This proves the grant is rate*elapsed*islandMultiplier, capped.
	local function dispatchWithIslands(
		registry: any,
		clock: any,
		data: any,
		player: any,
		islandMultiplier: number,
		payload: any
	): any
		local islands = {
			multiplierFor = function(_self: any, _d: any): number
				return islandMultiplier
			end,
		}
		local ctx = {
			player = player,
			clock = clock,
			data = data,
			islands = islands,
		}
		return Net.dispatch(registry, nil, ctx, CLAIM, payload)
	end

	it("an island multiplier of M scales the (capped) base accrual: grant == base*M", function()
		local harness, data, player, clock = setup()
		clock:advance(100) -- un-capped base window
		local base = RATE * 100
		expect(base <= CAP):toBe(true)
		local M = 4
		local r = dispatchWithIslands(harness.registry, clock, data, player, M, {})
		expect(r):toBeOk()
		-- the multiplier scales the (capped) base: floor(base * M).
		expect((r :: any).value.granted):toBe(math.floor(base * M))
		expect(balanceOf(data, player)):toBe(math.floor(base * M))
	end)

	it(
		"the cap binds the BASE, so even with a multiplier a huge absence is bounded by CAP*M",
		function()
			-- A forged/huge elapsed with a fat multiplier still cannot exceed CAP*M (the cap clamps the BASE
			-- before the multiply) — the multiplier scales an already-bounded amount.
			local harness, data, player, clock = setup()
			clock:advance(10 ^ 9) -- enormous absence
			local M = 8
			local r = dispatchWithIslands(harness.registry, clock, data, player, M, {})
			expect(r):toBeOk()
			expect((r :: any).value.granted):toBe(CAP * M) -- floor(CAP*M); CAP and M are integers here
			expect(balanceOf(data, player)):toBe(CAP * M)
			-- NOT the unbounded rate*1e9*M.
			expect((r :: any).value.granted < RATE * 10 ^ 9 * M):toBe(true)
		end
	)
end)

describe("Offline — malformed / abusive payloads (BadPayload, no state change)", function()
	it("a non-table payload -> Err(BadPayload); the handler never runs, no state change", function()
		local harness, data, player, clock = setup()
		clock:advance(1000) -- there IS offline time to be (wrongly) granted if validation were skipped
		local before = balanceOf(data, player)
		expect(harness.invoke(CLAIM, player, 5)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(CLAIM, player, "claim")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(CLAIM, player, true)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(CLAIM, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- nothing was granted: a rejected payload mutates no state.
		expect(balanceOf(data, player)):toBe(before)
		expect(lastSeenOf(data, player)):toBe(1000) -- base NOT advanced by a rejected claim
	end)

	it(
		"a table payload carrying extra fields is accepted; the extras are simply ignored",
		function()
			local harness, _data, player, clock = setup()
			clock:advance(150)
			local r =
				harness.invoke(CLAIM, player, { junk = "x", elapsed = 999999, nested = { a = 1 } })
			expect(r):toBeOk()
			expect((r :: any).value.granted):toBe(math.floor(RATE * 150)) -- server window, extras ignored
		end
	)
end)

describe("Offline — rate limit (defence in depth, not the idempotency guarantee)", function()
	it(
		"spamming ClaimOffline past the action's rate window -> Err(RateLimited); refills after window",
		function()
			-- A REAL gate + injected clock enforces the action's own RatePolicy. After the first claim advances
			-- the base, the rest grant 0 (idempotent) until the gate sheds with RateLimited.
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, data, player = setup({ gate = gate })
			setLastSeen(data, player, clock:unix() - 300) -- there is real offline time for the FIRST claim
			local hitRateLimit = false
			for _ = 1, 50 do
				local r = harness.invoke(CLAIM, player, {})
				if not r.ok and r.code == Result.Codes.RateLimited then
					hitRateLimit = true
					break
				end
				expect(r):toBeOk() -- before shedding: claims succeed (first grants, rest grant 0)
			end
			expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
		end
	)
end)

describe(
	"Offline — concurrency-safe & idempotent EARN (interleaved / spam-duplicated never double-grant)",
	function()
		-- The economy_race technique (REQUIRED): drive interleaved invocations as coroutines against a yielding
		-- store so the second ClaimOffline arrives WHILE the first is parked inside the lock-held update. A
		-- double-grant (claiming the SAME offline window twice) would FAIL these assertions.

		it(
			"TWO interleaved claims of the same offline window grant it EXACTLY once (no double-grant)",
			function()
				-- Probe the grant a single claim would yield for a 600s window (clean, isolated).
				local ph, _pd, pp, pc = setup({ userId = 5151 })
				pc:advance(600)
				local single = (ph.invoke(CLAIM, pp, {}) :: any).value.granted
				expect(single > 0):toBe(true)

				local harness, data, player, clock = setup({ yieldOnUpdate = true })
				clock:advance(600) -- the SAME 600s offline window, now contested by two interleaved claims
				local before = balanceOf(data, player)
				expect(before):toBe(0)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.a = harness.invoke(CLAIM, player, {})
					end),
					coroutine.create(function()
						results.b = harness.invoke(CLAIM, player, {})
					end),
				}
				drain(cos)

				-- BOTH calls succeed (claim is not a rejection on the loser — it grants 0), but the window is paid
				-- out EXACTLY once: one claim grants `single`, the other grants 0.
				expect(results.a):toBeOk()
				expect(results.b):toBeOk()
				local grants =
					{ (results.a :: any).value.granted, (results.b :: any).value.granted }
				table.sort(grants)
				expect(grants[1]):toBe(0) -- the loser accrued from the just-advanced base -> nothing
				expect(grants[2]):toBe(single) -- the winner granted the window EXACTLY once
				-- persisted balance rose by EXACTLY one window's grant — never two.
				expect(balanceOf(data, player)):toBe(single)
				expect(lifetimeOf(data, player)):toBe(single) -- lifetime credited exactly once too
			end
		)

		it(
			"FOUR spam-duplicated interleaved claims pay the window EXACTLY once (anti double-spend mint)",
			function()
				local ph, _pd, pp, pc = setup({ userId = 6262 })
				pc:advance(800)
				local single = (ph.invoke(CLAIM, pp, {}) :: any).value.granted
				expect(single > 0):toBe(true)

				local harness, data, player, clock = setup({ yieldOnUpdate = true })
				clock:advance(800)

				local results: { any } = {}
				local cos = {}
				for i = 1, 4 do
					local idx = i
					table.insert(
						cos,
						coroutine.create(function()
							results[idx] = harness.invoke(CLAIM, player, {})
						end)
					)
				end
				drain(cos)

				-- sum of all four grants == exactly ONE window; exactly one claim is the non-zero winner.
				local total = 0
				local nonZero = 0
				for i = 1, 4 do
					expect(results[i]):toBeOk()
					local g = (results[i] :: any).value.granted
					total += g
					if g > 0 then
						nonZero += 1
						expect(g):toBe(single)
					end
				end
				expect(nonZero):toBe(1) -- exactly one of four spam claims paid out
				expect(total):toBe(single) -- the window was minted EXACTLY once across all four
				expect(balanceOf(data, player)):toBe(single) -- persisted: one window, never four
				expect(lifetimeOf(data, player)):toBe(single)
			end
		)
	end
)

describe(
	"Offline — the accrual base advances MONOTONICALLY (a late, earlier-now claim cannot pull it back)",
	function()
		-- REGRESSION (economy red-team / gate): the idempotency proof assumes BOTH interleaved claims
		-- share the SAME `now`. The existing race tests pin one clock value for both racers, so they never
		-- exercise the case where two genuinely concurrent claims capture DIFFERENT server times. When the
		-- LATER-now claim runs its transform FIRST (advancing lastSeenUnix forward) and the EARLIER-now
		-- claim runs SECOND, an UNCONDITIONAL `d.timestamps.lastSeenUnix = now` write pulls the base
		-- BACKWARD by the inter-request delta. The next claim then re-accrues from that earlier base —
		-- re-minting a window already paid out. The invariant: after ANY claim the persisted base must be
		-- >= every `now` already observed by a completed claim (it may only move forward).
		--
		-- We give the two racers SEPARATE clocks over the SAME DataService/store (yielding) so they capture
		-- different `now` values. `drain` resumes A first, so A acquires the lock first, parks at
		-- yieldOnUpdate, and its transform runs FIRST; releasing hands the lock to B, whose transform runs
		-- SECOND. So A is the LATER-now racer and B the EARLIER-now racer.
		local function raceSetup(nowA: number, nowB: number): (any, any, any)
			local cfg = config()
			-- Shared backing store with the in-critical-section yield so the second claim is FORCED to park.
			local sharedClock = Mocks.clock(1000)
			local store = Mocks.store({ clock = sharedClock, config = cfg, yieldOnUpdate = true })
			local data = DataService.new(store, sharedClock, cfg, Mocks.logWarn)
			local player = Mocks.player(7777)
			data:loadSession(player) -- stamps lastSeenUnix = 1000 (the base both racers accrue from)

			-- Two harnesses sharing the SAME data, each with its OWN clock so the racers capture DIFFERENT
			-- server `now` values (gate off to isolate from rate shedding).
			local clockA = Mocks.clock(nowA)
			local clockB = Mocks.clock(nowB)
			local harnessA = Mocks.net({ clock = clockA, data = data, gate = false })
			local harnessB = Mocks.net({ clock = clockB, data = data, gate = false })
			OfflineService:Start({ net = harnessA.registry })
			OfflineService:Start({ net = harnessB.registry })
			return data, player, { a = harnessA, b = harnessB }
		end

		it(
			"a later-now claim first then an earlier-now claim second keeps lastSeenUnix MONOTONIC (no re-mint)",
			function()
				-- A captures the LATER now (1700); B the EARLIER now (1690). Real base was stamped at 1000.
				local nowA = 1700
				local nowB = 1690
				local data, player, h = raceSetup(nowA, nowB)
				expect(lastSeenOf(data, player)):toBe(1000)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						-- A resumes first -> acquires the lock first -> its transform runs FIRST (later now).
						results.a = h.a.invoke(CLAIM, player, {})
					end),
					coroutine.create(function()
						-- B parks behind A -> its transform runs SECOND (earlier now).
						results.b = h.b.invoke(CLAIM, player, {})
					end),
				}
				drain(cos)

				expect(results.a):toBeOk()
				expect(results.b):toBeOk()

				-- THE INVARIANT (RED on the buggy impl): after both claims the persisted base must be
				-- monotonic — it may NEVER be pulled below the largest `now` a completed claim observed.
				-- The buggy impl writes lastSeenUnix = nowB (1690), moving the base BACKWARD past nowA.
				expect(lastSeenOf(data, player) >= nowA):toBe(true)

				-- The concrete consequence the backward move enables — a no-double-mint check. The whole
				-- 1000..1700 window was already paid out by A; a follow-up claim at a strictly later time
				-- must accrue ONLY the new window, never re-grant the d=10s the backward move re-opened.
				local paidOut = balanceOf(data, player)
				local newWindow = 100
				local clockC = Mocks.clock(nowA + newWindow) -- 1800: a fresh claim at a strictly later time
				local harnessC = Mocks.net({ clock = clockC, data = data, gate = false })
				OfflineService:Start({ net = harnessC.registry })
				local third = harnessC.invoke(CLAIM, player, {})
				expect(third):toBeOk()
				-- The new window is exactly nowA..nowA+newWindow == 100s (base must be nowA, not nowB).
				-- On the buggy impl the base is nowB=1690, so elapsed = 1800-1690 = 110 -> re-mints the 10s.
				expect((third :: any).value.granted):toBe(math.floor(RATE * newWindow))
				expect(balanceOf(data, player)):toBe(paidOut + math.floor(RATE * newWindow))
			end
		)
	end
)
