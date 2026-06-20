--!strict
-- games/collect-sim/tests/unit/rebirth.spec.luau   [INDEPENDENT TEST GATE — authored from the rebirth spec slice]
-- Adversarial Tier-1 gate for the "Rebirth / prestige" loop-completion feature. Authored from the
-- SPEC's behavioral GUARANTEES, NOT from the implementation's branch logic (maker != checker). The
-- spec slice this gate holds the feature to:
--   * Rebirth requires a SERVER-OWNED Stardust threshold. Below it -> Insufficient, nothing changes.
--   * On success, ATOMICALLY in ONE ctx.data:update transform: zero currencies.Stardust; RESET
--     upgrades to {}; CLEAR every island flag (flags['island.*']) — keep the always-unlocked starting
--     island (no flag); INCREMENT the persisted `rebirths` count by 1; GRANT currencies.Prisms += a
--     SERVER-DERIVED amount (the client supplies NO number).
--   * PRESERVE across the rebirth: the rebirths count (increments, never resets), currencies.Prisms
--     (accumulates over rebirths), stats.lifetimeStardust (the lifetime earn aggregate — NEVER reset by
--     a rebirth: the reset is a spend/zero, not an earn), and gamepass flags (flags['gamepass.*']).
--   * The permanent multiplier is DERIVED at read (1 + rebirths*step) and NEVER persisted; the handler
--     returns it for the HUD but stores only the count.
--   * On a SUCCESSFUL rebirth emit BOTH loop_completed AND progression THROUGH ctx.analytics (rebirth
--     is the loop-completion point). A FAILED rebirth emits nothing.
--   * Concurrency: interleaved / spam-duplicated rebirths must NEVER dupe Prisms, double-increment the
--     count, or double-reset — the whole reset-and-grant is ONE transform under the per-player FIFO
--     lock on the re-read snapshot.
--   * The client sends an EMPTY intent; a non-table payload -> BadPayload.
--
-- We drive the action the SAME way production does: Start({ net = harness.registry }) registers the
-- Rebirth action onto a Mocks.net harness; we invoke through the REAL Net.dispatch with a real
-- DataService over a MockStore as ctx.data. Every operand (Stardust, upgrades, island/gamepass flags,
-- rebirths, Prisms, lifetimeStardust) is read back through DataService:get — the persisted, lock-queued
-- state — so a mint, a phantom grant, a missed reset, or a double-spend is OBSERVABLE.
--
-- The server-owned threshold is DISCOVERED through the action's own behavior (binary search on the
-- Insufficient<->Ok boundary), never copied from the implementation table.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local RebirthService = require("../../src/server/services/rebirth/RebirthService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local REBIRTH = Net.Actions.Rebirth -- "rebirth.do"

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

-- Build the Rebirth action wired onto a fresh Mocks.net harness over a DataService with one loaded
-- player. `opts.yieldOnUpdate` forces the store to yield inside the critical section (concurrency
-- tests); `opts.gate` controls the rate gate (defaults false to isolate behavior); `opts.analytics`
-- injects an emitter to observe events; `opts.userId` keys a distinct player.
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
	if o.analytics ~= nil then
		harnessOpts.analytics = o.analytics
	end
	local harness = Mocks.net(harnessOpts)
	RebirthService:Start({ net = harness.registry })
	return harness, data, player, clock
end

-- Read the whole persisted snapshot through the lock-queued data layer.
local function snapshot(data: any, player: any): any
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value
end

local function stardustOf(data: any, player: any): number
	return snapshot(data, player).currencies.Stardust or 0
end

local function prismsOf(data: any, player: any): number
	return snapshot(data, player).currencies.Prisms or 0
end

local function rebirthsOf(data: any, player: any): number
	return snapshot(data, player).rebirths or 0
end

local function lifetimeOf(data: any, player: any): number
	local s = snapshot(data, player).stats or {}
	return s.lifetimeStardust or 0
end

-- Apply an arbitrary mutation to the player's PERSISTED data through the canonical write path,
-- drained so it works even under yieldOnUpdate. (We never poke the backing table directly.)
local function mutate(data: any, player: any, fn: (any) -> ()): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = data:update(player, function(d)
			fn(d)
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

local function setStardust(data: any, player: any, amount: number): ()
	mutate(data, player, function(d)
		d.currencies.Stardust = amount
	end)
end

-- ----- discover the server-owned threshold via the action's OWN boundary (never the impl table) -----
-- Binary search the smallest balance at which Rebirth flips Insufficient -> Ok. Each probe uses a
-- FRESH player (a successful rebirth zeros Stardust, so we must not reuse one). Returns the threshold.
local function discoverThreshold(): number
	local lo = 0 -- known to FAIL (a fresh player has 0)
	local hi = 1 -- grow until it SUCCEEDS, giving an upper bound
	local function rebirthsAt(balance: number): boolean
		-- a unique userId per probe so each starts clean.
		local uid = 100000 + balance % 1000000 + math.random(1, 1000000)
		local harness, data, player = setup({ userId = uid })
		setStardust(data, player, balance)
		local r = harness.invoke(REBIRTH, player, {})
		return r.ok == true
	end
	while not rebirthsAt(hi) do
		lo = hi
		hi *= 2
		if hi > 1e12 then
			error("threshold discovery did not converge (no balance ever rebirthed)")
		end
	end
	-- invariant: lo FAILS, hi SUCCEEDS. Narrow to the exact integer boundary.
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if rebirthsAt(mid) then
			hi = mid
		else
			lo = mid
		end
	end
	return hi -- the smallest balance that SUCCEEDS == the threshold
end

local THRESHOLD = discoverThreshold()

describe("Rebirth — server-owned threshold gate (Insufficient below, Ok at/above)", function()
	it(
		"a fresh (zero-balance) player cannot rebirth -> Err(Insufficient), nothing changes",
		function()
			local harness, data, player = setup()
			expect(stardustOf(data, player)):toBe(0)
			local r = harness.invoke(REBIRTH, player, {})
			expect(r):toBeErr(Result.Codes.Insufficient)
			-- no mint, no count bump, no Prisms grant.
			expect(rebirthsOf(data, player)):toBe(0)
			expect(prismsOf(data, player)):toBe(0)
			expect(stardustOf(data, player)):toBe(0)
		end
	)

	it(
		"balance ONE BELOW the threshold -> Err(Insufficient); no reset, no grant, no bump",
		function()
			local harness, data, player = setup()
			setStardust(data, player, THRESHOLD - 1)
			-- seed some progression so we can prove NOTHING was reset on a rejection.
			mutate(data, player, function(d)
				d.upgrades = { collect = 3 }
				d.flags = { ["island.2"] = true }
			end)
			local before = stardustOf(data, player)

			local r = harness.invoke(REBIRTH, player, {})
			expect(r):toBeErr(Result.Codes.Insufficient)

			-- everything is exactly as before: no spend, no reset, no grant.
			expect(stardustOf(data, player)):toBe(before)
			expect(rebirthsOf(data, player)):toBe(0)
			expect(prismsOf(data, player)):toBe(0)
			local d = snapshot(data, player)
			expect(d.upgrades.collect):toBe(3) -- upgrades untouched
			expect(d.flags["island.2"]):toBe(true) -- island flag untouched
		end
	)

	it(
		"balance EXACTLY at the threshold CAN rebirth (boundary: reject only when balance < threshold)",
		function()
			local harness, data, player = setup()
			setStardust(data, player, THRESHOLD)
			local r = harness.invoke(REBIRTH, player, {})
			expect(r):toBeOk()
			expect(rebirthsOf(data, player)):toBe(1)
			expect(stardustOf(data, player)):toBe(0) -- the prestige spend zeroed it
			expect(prismsOf(data, player) > 0):toBe(true) -- a real grant
		end
	)
end)

describe(
	"Rebirth — the full prestige reset (one atomic transform), all operands persisted",
	function()
		it(
			"on success: Stardust zeroed, upgrades -> {}, island flags cleared, rebirths+1, Prisms granted",
			function()
				local harness, data, player = setup()
				setStardust(data, player, THRESHOLD)
				mutate(data, player, function(d)
					d.upgrades = { collect = 5, backpack = 2, magnet = 1 }
					d.flags = {
						["island.2"] = true,
						["island.3"] = true,
						["gamepass.vipIsland"] = true, -- a purchase: MUST persist
					}
				end)

				local r = harness.invoke(REBIRTH, player, {})
				expect(r):toBeOk()
				local v = (r :: any).value
				expect(v.rebirths):toBe(1)
				expect(v.prismsEarned > 0):toBe(true)

				local d = snapshot(data, player)
				-- 1. Stardust zeroed.
				expect(d.currencies.Stardust):toBe(0)
				-- 2. upgrades cleared to an EMPTY table (no bought levels survive).
				expect(next(d.upgrades)):toBe(nil)
				-- 3. island flags cleared...
				expect(d.flags["island.2"]):toBe(nil)
				expect(d.flags["island.3"]):toBe(nil)
				-- 4. rebirths incremented.
				expect(d.rebirths):toBe(1)
				-- 5. Prisms granted (persisted == returned).
				expect(d.currencies.Prisms):toBe(v.prismsEarned)
				expect(d.currencies.Prisms):toBe(v.prisms)
			end
		)

		it("gamepass.* flags PERSIST through a rebirth (purchases are never wiped)", function()
			local harness, data, player = setup()
			setStardust(data, player, THRESHOLD)
			mutate(data, player, function(d)
				d.flags = {
					["island.2"] = true, -- will be cleared
					["gamepass.vipIsland"] = true, -- must survive
					["gamepass.x2cash"] = true, -- must survive
				}
			end)
			expect(harness.invoke(REBIRTH, player, {})):toBeOk()
			local d = snapshot(data, player)
			expect(d.flags["island.2"]):toBe(nil) -- island flag gone
			expect(d.flags["gamepass.vipIsland"]):toBe(true) -- purchase persists
			expect(d.flags["gamepass.x2cash"]):toBe(true) -- purchase persists
		end)

		it(
			"stats.lifetimeStardust is NEVER reset by a rebirth (the reset is a spend, not an earn)",
			function()
				local harness, data, player = setup()
				setStardust(data, player, THRESHOLD)
				mutate(data, player, function(d)
					d.stats.lifetimeStardust = 999999 -- a big lifetime aggregate
				end)
				expect(lifetimeOf(data, player)):toBe(999999)

				expect(harness.invoke(REBIRTH, player, {})):toBeOk()
				-- the rebirth zeroed CURRENT Stardust but the LIFETIME aggregate is monotonic — unchanged.
				expect(lifetimeOf(data, player)):toBe(999999)
				expect(stardustOf(data, player)):toBe(0)
			end
		)

		it(
			"a non-island, non-gamepass flag is NOT cleared (only flags['island.*'] reset)",
			function()
				-- The spec resets ONLY the island flags; any other flag (here a non-island marker) must survive
				-- just like gamepass flags. This guards an over-broad reset that clears the whole flags map.
				local harness, data, player = setup()
				setStardust(data, player, THRESHOLD)
				mutate(data, player, function(d)
					d.flags = {
						["island.2"] = true,
						["tutorial.done"] = true, -- neither island nor gamepass: must survive
					}
				end)
				expect(harness.invoke(REBIRTH, player, {})):toBeOk()
				local d = snapshot(data, player)
				expect(d.flags["island.2"]):toBe(nil)
				expect(d.flags["tutorial.done"]):toBe(true)
			end
		)
	end
)

describe(
	"Rebirth — accumulation across multiple rebirths (count increments, Prisms accumulate)",
	function()
		it(
			"rebirths increments by exactly 1 each time (1 -> 2 -> 3); count is never reset",
			function()
				local harness, data, player = setup()
				for expected = 1, 3 do
					setStardust(data, player, THRESHOLD) -- re-earn the threshold each run
					local r = harness.invoke(REBIRTH, player, {})
					expect(r):toBeOk()
					expect((r :: any).value.rebirths):toBe(expected)
					expect(rebirthsOf(data, player)):toBe(expected)
				end
			end
		)

		it(
			"Prisms ACCUMULATE across rebirths (never reset, never duped) — monotonic non-decreasing",
			function()
				local harness, data, player = setup()
				local running = 0
				for _ = 1, 4 do
					setStardust(data, player, THRESHOLD)
					local r = harness.invoke(REBIRTH, player, {})
					expect(r):toBeOk()
					local earned = (r :: any).value.prismsEarned
					running += earned
					-- the persisted Prisms equals the exact running sum of every grant (no reset, no dupe).
					expect(prismsOf(data, player)):toBe(running)
					expect((r :: any).value.prisms):toBe(running)
				end
				expect(running > 0):toBe(true)
			end
		)

		it(
			"a bigger run (more Stardust over the threshold) grants AT LEAST as many Prisms (server-scaled)",
			function()
				-- Two clean players: one rebirths at exactly the threshold, one far above it. The deeper run's
				-- grant is server-derived from the held Stardust and must be >= the minimal run's grant. This is
				-- an INEQUALITY (spec: "a server-derived amount"), not the impl's exact formula.
				local hMin, dMin, pMin = setup({ userId = 11 })
				setStardust(dMin, pMin, THRESHOLD)
				local rMin = hMin.invoke(REBIRTH, pMin, {})
				expect(rMin):toBeOk()

				local hBig, dBig, pBig = setup({ userId = 12 })
				setStardust(dBig, pBig, THRESHOLD * 10)
				local rBig = hBig.invoke(REBIRTH, pBig, {})
				expect(rBig):toBeOk()

				expect((rBig :: any).value.prismsEarned >= (rMin :: any).value.prismsEarned):toBe(
					true
				)
			end
		)
	end
)

describe("Rebirth — derived multiplier (returned for the HUD, NEVER persisted)", function()
	it("the returned multiplier strictly RISES with the rebirth count (1 -> higher)", function()
		local harness, data, player = setup()
		setStardust(data, player, THRESHOLD)
		local r1 = harness.invoke(REBIRTH, player, {})
		expect(r1):toBeOk()
		local m1 = (r1 :: any).value.multiplier
		expect(m1 > 1):toBe(true) -- one rebirth already lifts the multiplier above the base 1

		setStardust(data, player, THRESHOLD)
		local r2 = harness.invoke(REBIRTH, player, {})
		expect(r2):toBeOk()
		local m2 = (r2 :: any).value.multiplier
		expect(m2 > m1):toBe(true) -- a second rebirth lifts it further
	end)

	it("no 'multiplier' field is persisted; only the rebirths COUNT lives in the data", function()
		local harness, data, player = setup()
		setStardust(data, player, THRESHOLD)
		expect(harness.invoke(REBIRTH, player, {})):toBeOk()
		local d = snapshot(data, player)
		-- the count is persisted; a literal multiplier is not.
		expect(d.rebirths):toBe(1)
		expect(d.multiplier):toBe(nil)
		expect((d.currencies :: any).multiplier):toBe(nil)
	end)
end)

describe(
	"Rebirth — analytics: loop_completed AND progression on success; nothing on failure",
	function()
		it(
			"a successful rebirth emits BOTH loop_completed AND progression THROUGH ctx.analytics",
			function()
				local events: { any } = {}
				local analytics = {
					emit = function(_self: any, name: string, payload: any)
						table.insert(events, { name = name, payload = payload })
					end,
				}
				local harness, data, player = setup({ analytics = analytics })
				setStardust(data, player, THRESHOLD)
				local r = harness.invoke(REBIRTH, player, {})
				expect(r):toBeOk()

				local sawLoop, sawProgression = false, false
				for _, e in events do
					if e.name == "loop_completed" then
						sawLoop = true
						expect(e.payload.userId):toBe(player.UserId)
					elseif e.name == "progression" then
						sawProgression = true
						expect(e.payload.userId):toBe(player.UserId)
					end
				end
				expect(sawLoop):toBe(true) -- rebirth is the loop-completion point
				expect(sawProgression):toBe(true) -- the permanent rebirth advanced
			end
		)

		it("a FAILED rebirth (below threshold) emits NOTHING through analytics", function()
			local count = 0
			local analytics = {
				emit = function(_self: any, _name: string, _payload: any)
					count += 1
				end,
			}
			local harness, data, player = setup({ analytics = analytics })
			setStardust(data, player, THRESHOLD - 1) -- one short: rejected
			local r = harness.invoke(REBIRTH, player, {})
			expect(r):toBeErr(Result.Codes.Insufficient)
			expect(count):toBe(0)
		end)

		it(
			"analytics is nil-safe: a rebirth with NO analytics injected still succeeds (no crash)",
			function()
				local harness, data, player = setup() -- no analytics
				setStardust(data, player, THRESHOLD)
				local r = harness.invoke(REBIRTH, player, {})
				expect(r):toBeOk() -- the emit path is a no-op when analytics is absent
				expect(rebirthsOf(data, player)):toBe(1)
			end
		)
	end
)

describe("Rebirth — malformed / abusive payloads (client supplies an EMPTY intent)", function()
	it("a non-table payload -> Err(BadPayload); the handler never runs, no state change", function()
		local harness, data, player = setup()
		setStardust(data, player, THRESHOLD)
		local before = stardustOf(data, player)
		expect(harness.invoke(REBIRTH, player, 1)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(REBIRTH, player, "go")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(REBIRTH, player, true)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(REBIRTH, player, nil)):toBeErr(Result.Codes.BadPayload)
		-- none of those ran the reset.
		expect(stardustOf(data, player)):toBe(before)
		expect(rebirthsOf(data, player)):toBe(0)
		expect(prismsOf(data, player)):toBe(0)
	end)

	it(
		"a client-smuggled Prisms / rebirths / multiplier number is IGNORED (server-derived only)",
		function()
			-- The client packs fat numbers into the intent. The server trusts ZERO client numbers: the grant
			-- is identical to a clean empty-intent rebirth, the count increments by exactly 1, and the
			-- multiplier is the derived value — none of the smuggled fields are honored.
			local clean, cd, cp = setup({ userId = 555 })
			setStardust(cd, cp, THRESHOLD)
			local cr = clean.invoke(REBIRTH, cp, {})
			expect(cr):toBeOk()
			local cleanEarned = (cr :: any).value.prismsEarned

			local harness, data, player = setup({ userId = 556 })
			setStardust(data, player, THRESHOLD)
			local r = harness.invoke(REBIRTH, player, {
				prisms = 999999999,
				prismsEarned = 999999999,
				rebirths = 999999,
				Prisms = 999999999,
				multiplier = 999999,
				Stardust = 999999999,
			})
			expect(r):toBeOk()
			local v = (r :: any).value
			expect(v.prismsEarned):toBe(cleanEarned) -- smuggled Prisms ignored
			expect(v.rebirths):toBe(1) -- exactly +1 from 0, not the smuggled 999999
			expect(prismsOf(data, player)):toBe(cleanEarned) -- persisted grant == clean grant
			expect(rebirthsOf(data, player)):toBe(1)
		end
	)
end)

describe(
	"Rebirth — concurrency-safe (interleaved + spam-duplicated never dupe Prisms / double-reset)",
	function()
		-- The economy_race technique (REQUIRED): drive interleaved invocations as coroutines against a
		-- yielding store so a second Rebirth arrives WHILE the first is parked inside the lock-held update.
		-- A duped Prisms grant, a double-increment, or a double-reset would FAIL these assertions. Sequential
		-- calls would NOT prove this — the store yields INSIDE the critical section to force the interleave.

		it(
			"TWO interleaved rebirths with money for ONE -> exactly one grant, count +1, Prisms not duped",
			function()
				-- Discover the clean single-rebirth grant on a probe (so we can assert NO duplication).
				local ph, pd, pp = setup({ userId = 4242 })
				setStardust(pd, pp, THRESHOLD)
				local probe = ph.invoke(REBIRTH, pp, {})
				expect(probe):toBeOk()
				local oneGrant = (probe :: any).value.prismsEarned

				local harness, data, player = setup({ userId = 4243, yieldOnUpdate = true })
				setStardust(data, player, THRESHOLD) -- enough for EXACTLY ONE rebirth
				expect(prismsOf(data, player)):toBe(0)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.a = harness.invoke(REBIRTH, player, {})
					end),
					coroutine.create(function()
						results.b = harness.invoke(REBIRTH, player, {})
					end),
				}
				drain(cos)

				-- exactly ONE Ok; the loser re-read the just-zeroed Stardust (below threshold) -> Insufficient.
				local oks = 0
				for _, key in { "a", "b" } do
					local r = results[key]
					if r.ok then
						oks += 1
					else
						expect(r):toBeErr(Result.Codes.Insufficient) -- the spam-duplicate guard fired
					end
				end
				expect(oks):toBe(1) -- never two rebirths for one threshold's worth of Stardust

				-- count incremented EXACTLY once; Prisms granted EXACTLY once (no dupe).
				expect(rebirthsOf(data, player)):toBe(1)
				expect(prismsOf(data, player)):toBe(oneGrant)
				expect(stardustOf(data, player)):toBe(0) -- reset happened exactly once
			end
		)

		it(
			"FOUR spam-duplicated interleaved rebirths (money for ONE) -> exactly one grant, count = 1",
			function()
				local ph, pd, pp = setup({ userId = 9090 })
				setStardust(pd, pp, THRESHOLD)
				local probe = ph.invoke(REBIRTH, pp, {})
				expect(probe):toBeOk()
				local oneGrant = (probe :: any).value.prismsEarned

				local harness, data, player = setup({ userId = 9091, yieldOnUpdate = true })
				setStardust(data, player, THRESHOLD)

				local results: { any } = {}
				local cos = {}
				for i = 1, 4 do
					local idx = i
					table.insert(
						cos,
						coroutine.create(function()
							results[idx] = harness.invoke(REBIRTH, player, {})
						end)
					)
				end
				drain(cos)

				local oks = 0
				for i = 1, 4 do
					local r = results[i]
					if r.ok then
						oks += 1
					else
						expect(r):toBeErr(Result.Codes.Insufficient)
					end
				end
				expect(oks):toBe(1) -- exactly one of four spam clicks rebirthed
				expect(rebirthsOf(data, player)):toBe(1) -- count never double-incremented
				expect(prismsOf(data, player)):toBe(oneGrant) -- Prisms never duped
				expect(stardustOf(data, player)):toBe(0) -- reset ran exactly once
			end
		)

		it(
			"interleaved rebirth + a competing Stardust spend: never double-spends the threshold balance",
			function()
				-- A competing direct Stardust spend of the SAME threshold amount races the rebirth. With money for
				-- ONE of them, exactly one wins; the rebirth can never grant Prisms against a stale (already-spent)
				-- balance. Conservation: total Stardust removed never exceeds the starting balance.
				local harness, data, player = setup({ userId = 3131, yieldOnUpdate = true })
				setStardust(data, player, THRESHOLD) -- exactly the threshold; a competing spend of THRESHOLD drains it
				local before = stardustOf(data, player)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.rebirth = harness.invoke(REBIRTH, player, {})
					end),
					coroutine.create(function()
						results.spend = data:update(player, function(d)
							if (d.currencies.Stardust or 0) >= THRESHOLD then
								d.currencies.Stardust -= THRESHOLD
								results.spendApplied = true
							end
							return d
						end)
					end),
				}
				drain(cos)

				local final = stardustOf(data, player)
				expect(final >= 0):toBe(true) -- balance NEVER went negative (no double-spend / no mint)
				local rebirthed = results.rebirth.ok == true
				local spent = results.spendApplied == true
				-- the two competing THRESHOLD-sized spends cannot BOTH succeed against a balance of exactly THRESHOLD.
				expect(rebirthed and spent):toBe(false)
				if rebirthed then
					expect(rebirthsOf(data, player)):toBe(1)
					expect(prismsOf(data, player) > 0):toBe(true)
					expect(before - final):toBe(THRESHOLD) -- the rebirth zeroed exactly the threshold
				else
					-- the rebirth lost: NO grant, NO count bump (no prestige without paying the threshold).
					expect(rebirthsOf(data, player)):toBe(0)
					expect(prismsOf(data, player)):toBe(0)
				end
			end
		)
	end
)

describe("Rebirth — rate limit (defence in depth, NOT the concurrency guarantee)", function()
	it(
		"spamming Rebirth past the action's rate window -> Err(RateLimited); refills after the window",
		function()
			-- A REAL gate + injected clock enforces the action's own RatePolicy. The player has no money, so
			-- each allowed call is an Insufficient (mints nothing, never Ok) until the gate sheds.
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, data, player = setup({ gate = gate })
			expect(stardustOf(data, player)):toBe(0)

			local hitRateLimit = false
			local allowed = 0
			for _ = 1, 50 do
				local r = harness.invoke(REBIRTH, player, {})
				if not r.ok and r.code == Result.Codes.RateLimited then
					hitRateLimit = true
					break
				end
				expect(r):toBeErr(Result.Codes.Insufficient) -- before shedding: unaffordable, never Ok
				allowed += 1
			end
			expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
			expect(allowed > 0):toBe(true)

			clock:advance(60) -- refill the window
			expect(harness.invoke(REBIRTH, player, {})):toBeErr(Result.Codes.Insufficient) -- gate refilled, still no money
		end
	)
end)
