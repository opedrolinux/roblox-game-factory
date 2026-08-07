--!strict
-- games/deep-reach/tests/unit/salvage.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/salvage.md, NOT from
--  SalvageService's control flow. The implementation was read ONLY to learn its observable interface
--  (the seam method names, the action factories, the tick/collect entry points, the return shapes);
--  every EXPECTATION below is derived from the slice, and every economic number is DISCOVERED
--  through the public API (ctx.salvage:rateFor / :capacityFor) rather than copied out of the module.
--  A module that re-tunes DRONE_RATE, CONVEYOR_STEP or BASE_CAPACITY stays green here; a module that
--  stops applying one of them goes red.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   1. THE TICK — "One server-wide loop (a single task loop over live sessions, never one loop per
--      player) ... Per session per tick: `stored = math.min(capacityFor(data), stored + rateFor(data)
--      * (now - smelter.lastTickUnix))`, then stamp `smelter.lastTickUnix = now` — all inside ONE
--      DataService:update. It runs whether or not the player is standing there."
--   2. THE RATE, AS A DERIVED FUNCTION — "never a persisted field ... PURE over the persisted blob
--      and re-evaluated on every tick and every fetch." Its inputs are named exactly:
--      `upgrades.drones`, `upgrades.conveyor`, `upgrades.pearlDrones`, `data.resurfaces`,
--      `flags["gamepass.doubleCredits"]`, `now < data.boostExpiresUnix`, and the nil-safe `ctx.depth`
--      seam. "every one of those inputs must be absent-safe and default to a neutral value, AND
--      every one must genuinely reach the returned number ... A multiplier that is read but never
--      applied is the written-never-read defect this game was written to catch."
--   3. THE SMELTER — "capacity from `upgrades.smelter`; stored output clamped at capacity every tick
--      (a full smelter stops accruing, which is what makes the capacity upgrade matter)."
--   4. COLLECTING — "`salvage.collect` moves smelter.storedCredits into currencies.Credits through
--      ctx.economy:earn (which increments stats.lifetimeCredits and emits currency_earned,
--      source=\"smelt\"), zeroing stored in the SAME transform. Spam-duplicated collects must total
--      exactly the stored amount — the second call finds 0 and returns Err(Insufficient)."
--   5. HANDOFF WITH OFFLINE ACCRUAL — "the away window [timestamps.lastSeenUnix, now] belongs
--      exclusively to Offline accrual. At session load you MUST stamp `smelter.lastTickUnix = now`
--      BEFORE the first tick, so the online tick never re-counts it (and so a migrated lastTickUnix
--      of 0 cannot credit decades of accrual)."
--   6. THE OBSERVATION SURFACE — "`salvage.fetch` returns the DERIVED running rate, stored and
--      capacity."
--   7. THE WORLD — "Visuals are cosmetic: no client input and no client timing may influence the
--      rate (salvage-rate spoof)."
--   A2. "AUTO-COLLECT IS ONE GRANT PATH, NOT TWO ... so the lifetime-counter increment and the
--      currency_earned emit physically cannot be skipped on one of the two triggers."
--   NOT THIS SLICE: selling upgrades / setting prices, the depth tier table, the away-window
--      computation, granting the gamepass flags (only READ here).
--
-- WHY THE ECONOMY CASES ASSERT DELTAS, NEVER WRITES. The written-never-read pattern is this
-- factory's most expensive defect class, and its economic twin is the write-only assertion: a test
-- that checks "the smelter field moved" passes against a smelter that accrues into a number nothing
-- ever pays out, and against a collect that pays out without moving stats.lifetimeCredits. So every
-- case below snapshots currencies.Credits, stats.lifetimeCredits, smelter.storedCredits,
-- smelter.lastTickUnix and the currency_earned event count BEFORE and AFTER, and compares the DELTA.
-- The accrual-vs-earn distinction is asserted in BOTH directions: accruing must move NONE of the
-- three earn-side numbers (it is un-collected output sitting in a machine), and collecting must move
-- ALL of them by exactly the same amount.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The dupe this feature is one mistake away from is: read
-- smelter.storedCredits, YIELD in ctx.data:update, then earn that amount and zero it — two collects
-- in the same frame both read the same non-zero stored and the smelter pays twice for one fill.
-- Sequential calls cannot distinguish a correct implementation from that one, because nothing ever
-- interleaves. So the race cases drive the economy_race.spec idiom: a MockStore with `yieldOnUpdate`
-- (a forced yield INSIDE the update critical section) plus a round-robin coroutine driver, a
-- counting data proxy whose `peak` in-flight count proves the interleave is real, and a
-- FALSIFICATION counter-case (a naive read-then-yield-then-write collect, driven at the same yield
-- point) that DOES double-grant. The service also carries an in-memory single-flight reservation
-- that would short-circuit the interleave before it ever reached the data layer and make the race
-- vacuous — so the headline case NEUTRALISES it and proves the lock-held transform alone grants
-- exactly once, which is precisely the guarantee the slice states.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Net = require("../../src/shared/Net")
-- The ONE owner of PlayerRemoving (AMENDMENT A10b). The leave-path regression below drives the
-- PRODUCTION sequence rather than poking the data layer directly, because "salvage disarms on leave"
-- is only true if the module that owns the signal actually calls it.
local PlayerLifecycle = require("../../src/server/framework/PlayerLifecycle")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000
local DOUBLE_CREDITS_FLAG = "gamepass.doubleCredits"
local AUTO_COLLECT_FLAG = "gamepass.autoCollect"

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

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

-- Relative-tolerance float comparison. The rate is a PRODUCT of tuned steps (a +15% conveyor, a
-- +10% resurface), so exact binary equality is not available for the composed cases — but the
-- guarantee under test ("this input reaches the number") is about magnitude, not about the last bit.
local function close(actual: number, expected: number, epsilon: number?): boolean
	local tolerance = (epsilon or 1e-9) * math.max(1, math.abs(actual), math.abs(expected))
	return math.abs(actual - expected) <= tolerance
end

local function expectClose(actual: number, expected: number, why: string): ()
	if not close(actual, expected) then
		error(`{why}: got {actual}, want {expected}`, 0)
	end
end

local function expectFinite(value: any, why: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error(`{why}: expected a finite number, got {tostring(value)}`, 0)
	end
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
			error("salvage race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`salvage race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- A pass-through ctx.data that COUNTS the updates that actually reached the data layer AND tracks
-- the PEAK number in flight simultaneously.
--
-- `updates` alone cannot tell an interleave from two strictly sequential calls. So if Mocks.store
-- ever stopped forwarding `yieldOnUpdate` (option renamed, MockStore's forced yield deleted), every
-- race case below would silently degrade to two sequential collects and stay green. `peak` is the
-- guard: it can only reach 2 if the second request entered ctx.data:update while the first was
-- still parked inside it.
local function countingData(data: any): any
	local proxy: any = { updates = 0, gets = 0, inFlight = 0, peak = 0 }
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
	function proxy.get(self: any, player: any): any
		self.gets += 1
		return data:get(player)
	end
	return proxy
end

-- Run `body` with a service-owned in-memory reservation table neutralised, so an interleaved pair
-- genuinely reaches the data layer. The slice's stated mechanism is the lock-held transform; a
-- per-server memo is belt-and-braces for it (and says nothing about the same player on another
-- server), so the guarantee must hold WITHOUT it. The real table is ALWAYS restored, even on throw.
local function withoutMemo(field: string, body: () -> ()): ()
	local real = (SalvageService :: any)[field];
	(SalvageService :: any)[field] = setmetatable({}, {
		__newindex = function() end, -- every reservation is silently dropped
	}) :: any
	local ok, err = pcall(body);
	(SalvageService :: any)[field] = real
	if not ok then
		error(err, 0)
	end
end

-- Drive the ONE server-wide tick pass against an injected roster (the service's documented Tier-1
-- seam: there is no engine here, and the slice's "one loop over live sessions" is exactly what this
-- exercises). The real provider is ALWAYS restored.
local function withRoster(players: { any }, body: () -> ()): ()
	local real = SalvageService._players
	SalvageService._players = function(): { any }
		return players
	end
	local ok, err = pcall(body)
	SalvageService._players = real
	if not ok then
		error(err, 0)
	end
end

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, and SalvageService Started against a recording `net`. Start is the ONLY way the
-- ctx.salvage seam and the registered actions are obtained, which is deliberate — a spec that
-- reached into the module for its private seam table would not be testing what gameplay code gets.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	-- MockStore reads `yieldOnUpdate` off this LIVE table on every update, so the forced yield is
	-- armed only for the racing part of a case. That matters: the forced yield parks the CALLING
	-- coroutine, and a spec's setup writes (arm / seed) run on the main thread — parking that thread
	-- leaves nothing to resume it, and the whole run ends silently.
	local storeOptions: any = {
		clock = clock,
		config = Config,
		yieldOnUpdate = false,
		seed = opts.seed,
	}
	local store = Mocks.store(storeOptions)
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
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local startContext: any = {
		clock = clock,
		data = data,
		net = net,
		economy = economy,
		analytics = analytics,
		depth = opts.depth,
	}
	SalvageService:Start(startContext)

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		depth = opts.depth,
		seam = startContext.salvage,
		registered = registered,
		pushes = pushes,
		startContext = startContext,
		storeOptions = storeOptions,
	}

	-- Arm (or disarm) MockStore's forced yield inside the update critical section. Call it AFTER the
	-- setup writes and BEFORE the coroutine driver runs.
	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	-- The ActionContext a direct collect/fetch/tick call receives. `overrides` lets one case swap a
	-- single seam (a missing economy, a refusing economy, a counting data layer) without rebuilding
	-- the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			depth = if o.depth ~= nil then o.depth else self.depth,
		}
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

	-- Seed persisted state THROUGH the data layer (never by poking the live table), so every case
	-- starts from a blob the game could actually have written.
	function h.write(self: any, player: any, mutate: (any) -> ()): ()
		local written = self.data:update(player, function(d: any): any
			mutate(d)
			return d
		end)
		expect(written):toBeOk()
	end

	function h.arm(self: any, player: any, overrides: any?): any
		return SalvageService:armFor(self:ctx(player, overrides), player)
	end

	function h.tick(self: any, player: any, overrides: any?): any
		return SalvageService:tickPlayer(self:ctx(player, overrides), player)
	end

	function h.collect(self: any, player: any, overrides: any?): any
		return SalvageService:collect(self:ctx(player, overrides))
	end

	function h.fetch(self: any, player: any, overrides: any?): any
		return SalvageService:fetch(self:ctx(player, overrides))
	end

	-- The DERIVED numbers, read through the ctx.salvage seam exactly as a later feature would.
	function h.rate(self: any, player: any): number
		return self.seam:rateFor(self:blob(player), self.clock:unix(), self.depth)
	end

	function h.capacity(self: any, player: any): number
		return self.seam:capacityFor(self:blob(player))
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net, with the two salvage actions
	-- registered from the service's own action factories. `gate = true` opts INTO the spine Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local harness = Mocks.net({
			clock = self.clock,
			data = self.data,
			economy = self.economy,
			depth = self.depth,
			salvage = self.seam,
			gate = if w.gate == true then Mocks.gate(self.clock) else false,
		})
		harness.register(SalvageService:collectAction())
		harness.register(SalvageService:fetchAction())
		return harness
	end

	-- The five numbers every economy case compares before/after.
	function h.snap(self: any, player: any): any
		local blob = self:blob(player)
		return {
			credits = blob.currencies.Credits,
			pearls = blob.currencies.Pearls,
			lifetime = blob.stats.lifetimeCredits,
			stored = blob.smelter.storedCredits,
			lastTick = blob.smelter.lastTickUnix,
			earned = #self.analytics:eventsOfType("currency_earned"),
			spent = #self.analytics:eventsOfType("currency_spent"),
		}
	end

	return h
end

-- A blob shaped exactly as the production seed writes it, optionally mutated. Used for the PURE
-- rate/capacity cases, which need no server at all.
local function blobWith(mutate: ((any) -> ())?): any
	local blob = Mocks.playerData(START_UNIX)
	if mutate ~= nil then
		mutate(blob)
	end
	return blob
end

-- A depth seam stub: the nil-safe `ctx.depth` this slice CONSUMES (Depth tiers owns it and is built
-- later). `multiplier` is what its valueMultiplier returns.
local function depthSeam(multiplier: number): any
	local seam: any = { calls = 0 }
	function seam.valueMultiplier(self: any, _data: any, _nowUnix: number): number
		self.calls += 1
		return multiplier
	end
	return seam
end

-- An economy seam that REFUSES every earn, to prove a refused grant cannot burn the smelter.
local function refusingEconomy(): any
	local seam: any = { calls = 0 }
	function seam.earn(
		self: any,
		_data: any,
		_currency: string,
		_amount: number,
		_source: string
	): any
		self.calls += 1
		return Result.err(Result.Codes.Internal, "test: the economy refuses")
	end
	return seam
end

-- An economy that models the REAL EconomyService.earn's order on its non-atomic branch: it writes
-- the balance FIRST and only THEN discovers the reason it must refuse. `refusingEconomy` above
-- refuses BEFORE it mutates, so it can only prove the smelter is not burned — it can never see a
-- grant path that assumes `earn` is atomic-or-nothing. The slice's guarantee is stronger than "no
-- burn": a refused collect must leave the blob byte-identical, so the amount ends up in the smelter
-- OR in the balance, never in both.
local function partiallyApplyingEconomy(): any
	local seam: any = { calls = 0 }
	function seam.earn(self: any, data: any, currency: string, amount: number, _source: string): any
		self.calls += 1
		-- the partial apply: the balance is credited, and the refusal comes after it.
		data.currencies[currency] = (data.currencies[currency] or 0) + amount
		return Result.err(Result.Codes.Internal, "test: the economy refused AFTER crediting")
	end
	return seam
end

-- ── 1. wiring: the seam and the wire surface the slice specifies ────────────────────────────────

describe("salvage: the ctx.salvage seam and the two contract actions", function()
	it("Start installs ctx.salvage with rateFor and capacityFor", function()
		local h = newServer()
		expect(h.seam ~= nil):toBe(true)
		expect(type(h.seam.rateFor)):toBe("function")
		expect(type(h.seam.capacityFor)):toBe("function")
	end)

	it("Start registers exactly salvage.collect and salvage.fetch", function()
		local h = newServer()
		expect(h.registered[Net.Actions.CollectSmelter] ~= nil):toBe(true)
		expect(h.registered[Net.Actions.FetchSalvage] ~= nil):toBe(true)
		local count = 0
		for _ in h.registered do
			count += 1
		end
		expect(count):toBe(2)
	end)

	it("rateFor / capacityFor are PURE: reading them mutates nothing on the blob", function()
		local h = newServer()
		local blob = blobWith(function(d: any)
			d.upgrades.drones = 3
			d.upgrades.smelter = 2
			d.smelter.storedCredits = 40
			d.smelter.lastTickUnix = START_UNIX - 500
		end)
		local before = deepCopy(blob)
		h.seam:rateFor(blob, START_UNIX)
		h.seam:capacityFor(blob)
		h.seam:rateFor(blob, START_UNIX + 10_000)
		expect(blob):toEqual(before)
	end)

	it(
		"the rate is DERIVED, never a persisted field (no rate/capacity key is ever written)",
		function()
			local h = newServer()
			local player = h:join(1)
			h:arm(player)
			h.clock:advance(30)
			expect(h:tick(player)):toBeOk()
			expect(h:fetch(player)):toBeOk()
			local blob = h:blob(player)
			expect(blob.rate):toBe(nil)
			expect(blob.capacity):toBe(nil)
			expect(blob.multiplier):toBe(nil)
			expect(blob.salvage):toBe(nil)
			-- The persisted smelter record is exactly the two fields the slice names.
			local keys = 0
			for _ in blob.smelter do
				keys += 1
			end
			expect(keys):toBe(2)
			expect(type(blob.smelter.storedCredits)):toBe("number")
			expect(type(blob.smelter.lastTickUnix)):toBe("number")
		end
	)
end)

-- ── 2. THE DERIVED RATE: every named input must genuinely reach the number ──────────────────────
-- This is the written-never-read gate. Each case moves exactly ONE named input and demands the
-- returned number MOVE. A multiplier that is read and discarded is red here.

describe("salvage: every rate input named by the slice reaches the returned number", function()
	it("upgrades.drones raises the rate, strictly and monotonically", function()
		local h = newServer()
		local previous = -1
		for _, level in { 0, 1, 2, 5, 20 } do
			local rate = h.seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = level
				end),
				START_UNIX
			)
			expectFinite(rate, `rate at drones={level}`)
			if previous >= 0 and not (rate > previous) then
				error(`upgrades.drones={level} did not raise the rate ({rate} <= {previous})`, 0)
			end
			previous = rate
		end
	end)

	it("upgrades.pearlDrones raises the rate (the prestige hauler is applied)", function()
		local h = newServer()
		local without = h.seam:rateFor(blobWith(), START_UNIX)
		local with = h.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.pearlDrones = 1
			end),
			START_UNIX
		)
		expect(with > without):toBe(true)
	end)

	it("upgrades.conveyor raises the rate (throughput reaches the fleet)", function()
		local h = newServer()
		local base = h.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.drones = 4
			end),
			START_UNIX
		)
		local previous = base
		for _, level in { 1, 2, 3 } do
			local rate = h.seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = 4
					d.upgrades.conveyor = level
				end),
				START_UNIX
			)
			if not (rate > previous) then
				error(`upgrades.conveyor={level} did not raise the rate ({rate} <= {previous})`, 0)
			end
			previous = rate
		end
	end)

	it(
		"data.resurfaces raises the rate permanently (the prestige COUNT, not the currency)",
		function()
			local h = newServer()
			local none = h.seam:rateFor(blobWith(), START_UNIX)
			local once = h.seam:rateFor(
				blobWith(function(d: any)
					d.resurfaces = 1
				end),
				START_UNIX
			)
			local thrice = h.seam:rateFor(
				blobWith(function(d: any)
					d.resurfaces = 3
				end),
				START_UNIX
			)
			expect(once > none):toBe(true)
			expect(thrice > once):toBe(true)
			-- Spending Pearls must NOT shrink the multiplier: the count is the input, the balance is not.
			local spentDown = h.seam:rateFor(
				blobWith(function(d: any)
					d.resurfaces = 3
					d.currencies.Pearls = 0
				end),
				START_UNIX
			)
			expectClose(
				spentDown,
				thrice,
				"resurfaces multiplier must not depend on the Pearls balance"
			)
		end
	)

	it('flags["gamepass.doubleCredits"] doubles the rate EXACTLY (the slice says 2x)', function()
		local h = newServer()
		local plain = h.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.drones = 3
				d.upgrades.conveyor = 2
			end),
			START_UNIX
		)
		local doubled = h.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.drones = 3
				d.upgrades.conveyor = 2
				d.flags[DOUBLE_CREDITS_FLAG] = true
			end),
			START_UNIX
		)
		expectClose(doubled, plain * 2, "gamepass.doubleCredits must double the rate")
	end)

	it("now < boostExpiresUnix doubles the rate; at and past the expiry it does not", function()
		local h = newServer()
		local expiry = START_UNIX + 1800
		local function rateAt(now: number): number
			return h.seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = 2
					d.boostExpiresUnix = expiry
				end),
				now
			)
		end
		local plain = h.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.drones = 2
			end),
			START_UNIX
		)
		expectClose(rateAt(START_UNIX), plain * 2, "an active boost must double the rate")
		expectClose(rateAt(expiry - 1), plain * 2, "the last boosted second must still be doubled")
		-- `now < boostExpiresUnix` is a strict comparison: the expiry instant itself is unboosted.
		expectClose(rateAt(expiry), plain, "at the expiry instant the boost is over")
		expectClose(rateAt(expiry + 1), plain, "past the expiry the boost is over")
		expectClose(rateAt(expiry + 100_000), plain, "an old boost never comes back")
	end)

	it(
		"the two 2x multipliers COMPOSE (gamepass x boost = 4x), neither swallowing the other",
		function()
			local h = newServer()
			local plain = h.seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = 2
				end),
				START_UNIX
			)
			local both = h.seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = 2
					d.flags[DOUBLE_CREDITS_FLAG] = true
					d.boostExpiresUnix = START_UNIX + 60
				end),
				START_UNIX
			)
			expectClose(both, plain * 4, "the gamepass and the boost must compose")
		end
	)

	it("the nil-safe ctx.depth seam scales the rate, and its ABSENCE is neutral (1x)", function()
		local absent = newServer({ depth = nil })
		local neutral = absent.seam:rateFor(
			blobWith(function(d: any)
				d.upgrades.drones = 2
			end),
			START_UNIX
		)
		expectFinite(neutral, "an absent ctx.depth must still produce a rate")

		for _, multiplier in { 1, 2, 3.5, 10 } do
			local seam = depthSeam(multiplier)
			local scaled = newServer({ depth = seam }).seam:rateFor(
				blobWith(function(d: any)
					d.upgrades.drones = 2
				end),
				START_UNIX
			)
			expectClose(
				scaled,
				neutral * multiplier,
				`ctx.depth:valueMultiplier={multiplier} must scale the rate`
			)
			expect(seam.calls > 0):toBe(true)
		end
	end)

	it(
		"every rate input is ABSENT-SAFE: a blob missing all of them equals the neutral baseline",
		function()
			local h = newServer()
			local neutral = h.seam:rateFor(blobWith(), START_UNIX)
			-- A blob with NO upgrades map, NO flags map, NO resurfaces and NO boostExpiresUnix — the
			-- shape every one of those later features is responsible for, none of which exists yet.
			local bare: any = {
				currencies = { Credits = 0, Pearls = 0 },
				stats = { lifetimeCredits = 0, playtimeSeconds = 0, joinCount = 0 },
				smelter = { storedCredits = 0, lastTickUnix = 0 },
			}
			local bareRate = h.seam:rateFor(bare, START_UNIX)
			expectFinite(bareRate, "a bare blob must still produce a rate")
			expectClose(bareRate, neutral, "absent inputs must default to the neutral value")
			expectFinite(h.seam:capacityFor(bare), "a bare blob must still produce a capacity")
			expectClose(
				h.seam:capacityFor(bare),
				h.seam:capacityFor(blobWith()),
				"absent upgrades.smelter must default to the base capacity"
			)
		end
	)

	it(
		"rateFor is PURE over the blob: same blob + same now => the same number, every time",
		function()
			local h = newServer()
			local blob = blobWith(function(d: any)
				d.upgrades.drones = 3
				d.upgrades.conveyor = 1
				d.resurfaces = 2
			end)
			local first = h.seam:rateFor(blob, START_UNIX)
			for _ = 1, 5 do
				expectClose(
					h.seam:rateFor(blob, START_UNIX),
					first,
					"rateFor must be deterministic"
				)
			end
			-- No boost is active, so wall-clock time alone must not move the rate.
			expectClose(
				h.seam:rateFor(blob, START_UNIX + 86_400),
				first,
				"time alone must not change an unboosted rate"
			)
		end
	)

	it("capacityFor: upgrades.smelter raises the ceiling strictly and monotonically", function()
		local h = newServer()
		local previous = -1
		for _, level in { 0, 1, 2, 7 } do
			local capacity = h.seam:capacityFor(blobWith(function(d: any)
				d.upgrades.smelter = level
			end))
			expectFinite(capacity, `capacity at smelter={level}`)
			expect(capacity > 0):toBe(true)
			if previous >= 0 and not (capacity > previous) then
				error(
					`upgrades.smelter={level} did not raise capacity ({capacity} <= {previous})`,
					0
				)
			end
			previous = capacity
		end
	end)

	it("a poisoned blob can never produce a NaN / infinite / negative rate or capacity", function()
		local h = newServer()
		local poisons: { any } = { 0 / 0, math.huge, -math.huge, -50, 1e308, "9999", {}, true }
		for _, poison in poisons do
			for _, key in { "drones", "conveyor", "pearlDrones", "smelter" } do
				local blob = blobWith(function(d: any)
					d.upgrades[key] = poison
				end)
				local rate = h.seam:rateFor(blob, START_UNIX)
				local capacity = h.seam:capacityFor(blob)
				expectFinite(rate, `rate with upgrades.{key} = {tostring(poison)}`)
				expectFinite(capacity, `capacity with upgrades.{key} = {tostring(poison)}`)
				expect(rate >= 0):toBe(true)
				expect(capacity >= 0):toBe(true)
			end
		end
		-- resurfaces and boostExpiresUnix ride the same rule.
		for _, poison in poisons do
			local blob = blobWith(function(d: any)
				d.resurfaces = poison
				d.boostExpiresUnix = poison
			end)
			local rate = h.seam:rateFor(blob, START_UNIX)
			expectFinite(rate, `rate with resurfaces/boost = {tostring(poison)}`)
			expect(rate >= 0):toBe(true)
		end
	end)

	it("a depth seam that returns garbage cannot zero or poison the whole game's income", function()
		local neutral = newServer().seam:rateFor(blobWith(), START_UNIX)
		for _, bad in { 0 / 0, math.huge, -1, "3", nil } do
			local seam: any = {}
			function seam.valueMultiplier(_self: any, _data: any, _now: number): any
				return bad
			end
			local rate = newServer({ depth = seam }).seam:rateFor(blobWith(), START_UNIX)
			expectFinite(rate, `rate with a depth multiplier of {tostring(bad)}`)
			expectClose(rate, neutral, "a garbage depth multiplier must fall back to neutral")
		end
		-- A seam object with no valueMultiplier at all is the shape BEFORE Depth tiers lands.
		local rate = newServer({ depth = {} }).seam:rateFor(blobWith(), START_UNIX)
		expectClose(rate, neutral, "a depth seam without valueMultiplier must be neutral")
	end)
end)

-- ── 3. THE TICK: the accrual formula, and accrual is NOT an earn ────────────────────────────────

describe("salvage: the tick applies the slice's accrual formula", function()
	it(
		"one tick over T seconds credits exactly rateFor * T and stamps lastTickUnix = now",
		function()
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = 3
			end)
			expect(h:arm(player)):toBeOk()

			local rate = h:rate(player)
			expect(rate > 0):toBe(true)
			for _, span in { 1, 7, 30 } do
				local before = h:snap(player)
				h.clock:advance(span)
				local ticked = h:tick(player)
				expect(ticked):toBeOk()
				local after = h:snap(player)
				expectClose(
					after.stored - before.stored,
					rate * span,
					`a {span}s tick must credit rate*{span}`
				)
				expect(after.lastTick):toBe(h.clock:unix())
			end
		end
	)

	it("ACCRUAL IS NOT AN EARN: no currency, no lifetime counter, no currency_earned", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.drones = 5
		end)
		expect(h:arm(player)):toBeOk()
		local before = h:snap(player)
		for _ = 1, 20 do
			h.clock:advance(2)
			expect(h:tick(player)):toBeOk()
		end
		local after = h:snap(player)
		expect(after.stored > before.stored):toBe(true) -- the tick DID work
		expect(after.credits):toBe(before.credits)
		expect(after.lifetime):toBe(before.lifetime)
		expect(after.earned):toBe(before.earned)
	end)

	it("one tick is exactly ONE DataService:update", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local proxy = countingData(h.data)
		h.clock:advance(10)
		expect(h:tick(player, { data = proxy })):toBeOk()
		expect(proxy.updates):toBe(1)
	end)

	it(
		"a non-advancing clock credits nothing; a clock that moves BACKWARDS credits nothing",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			h.clock:advance(60)
			expect(h:tick(player)):toBeOk()
			local banked = h:snap(player)

			-- Same instant again: zero elapsed.
			expect(h:tick(player)):toBeOk()
			expectClose(
				h:snap(player).stored,
				banked.stored,
				"a zero-elapsed tick must credit nothing"
			)

			-- Backwards: a stamp in the future must not credit, and must never reduce stored.
			h.clock:advance(-45)
			expect(h:tick(player)):toBeOk()
			local rewound = h:snap(player)
			expectClose(rewound.stored, banked.stored, "a backwards clock must not credit")
			expect(rewound.stored >= banked.stored):toBe(true)
			expect(rewound.credits):toBe(banked.credits)
		end
	)

	it(
		"REGRESSION (F1): a backwards clock must not rewind the tick base and re-credit a paid span",
		function()
			-- THE DEFECT. `accrue` stamped `smelter.lastTickUnix = nowUnix` UNCONDITIONALLY, so a
			-- backwards wall-clock correction (Clock.real().unix is os.time(), which NTP can step
			-- back) moved the tick base INTO THE PAST — into a span this session had already been
			-- paid for. When the clock recovered, the next tick counted that span a SECOND time and
			-- minted output from a clock correction. The backwards-clock case above stops at the
			-- rewind, which is the one moment the defect is invisible: it only shows once time moves
			-- forward again, which is exactly what this case does.
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			local rate = h:rate(player)
			expect(rate > 0):toBe(true)

			h.clock:advance(60)
			expect(h:tick(player)):toBeOk() -- credits [T0, T0+60] and stamps T0+60
			local banked = h:snap(player)
			local paidThrough = banked.lastTick

			-- The clock steps BACK 45s, and a tick lands on the rewound clock. It credits nothing...
			h.clock:advance(-45)
			expect(h:tick(player)):toBeOk()
			expectClose(h:snap(player).stored, banked.stored, "a backwards clock must not credit")

			-- ...and the tick base must still be the last instant actually PAID FOR, so when the
			-- clock recovers and runs 30s past it, only those 30 seconds are new output.
			h.clock:advance(75)
			expect(h.clock:unix() - paidThrough):toBe(30)
			expect(h:tick(player)):toBeOk()
			expectClose(
				h:snap(player).stored - banked.stored,
				rate * 30,
				"only the span since the last CREDITED instant may be credited"
			)
		end
	)

	it(
		"REGRESSION (F4): a gap longer than an hour credits the WHOLE span, bounded only by capacity",
		function()
			-- THE CONTRACT, verbatim: `stored = math.min(capacityFor(data), stored + rateFor(data) *
			-- (now - smelter.lastTickUnix))`. The counted span is (now - lastTickUnix) and the ONLY
			-- ceiling on the result is capacity. The implementation additionally clamped the span to
			-- 3600s — invisible on a small tank (an hour already overfills it) and a silent income
			-- shortfall on a big one, where the hidden clamp rather than the capacity decided the
			-- number. This case sizes the tank so capacity CANNOT be what bounds the tick.
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.smelter = 20
			end)
			expect(h:arm(player)):toBeOk()
			local rate = h:rate(player)
			local capacity = h:capacity(player)
			local gap = 10_000
			expect(rate > 0):toBe(true)
			expect(rate * gap < capacity):toBe(true) -- the ceiling is NOT what bounds this tick
			local before = h:snap(player)

			h.clock:advance(gap)
			local ticked = h:tick(player)
			expect(ticked):toBeOk()
			expectClose(
				h:snap(player).stored - before.stored,
				rate * gap,
				"the counted span is (now - lastTickUnix), with no undeclared ceiling on it"
			)
			expectClose(
				(ticked :: any).value.credited,
				rate * gap,
				"and the tick reports what it actually credited"
			)
		end
	)

	it(
		"ONE server-wide pass ticks every live session once, and it runs with no player input",
		function()
			local h = newServer()
			local players = { h:join(1), h:join(2), h:join(3) }
			for _, player in players do
				expect(h:arm(player)):toBeOk()
			end
			local before: { any } = {}
			for index, player in players do
				before[index] = h:snap(player)
			end

			h.clock:advance(20)
			-- The roster carries a DUPLICATE entry: one pass must still credit that player once.
			local roster = { players[1], players[2], players[3], players[1] }
			local pass: any
			withRoster(roster, function()
				pass = SalvageService:tickAll(h.startContext)
			end)
			expect(pass.ticked):toBe(3)

			for index, player in players do
				local rate = h.seam:rateFor(h:blob(player), h.clock:unix(), h.depth)
				expectClose(
					h:snap(player).stored - before[index].stored,
					rate * 20,
					`player {index} must be credited exactly once by one pass`
				)
			end
		end
	)

	it(
		"a player who never acts still accrues — the loop is server-driven, not input-driven",
		function()
			local h = newServer()
			local player = h:join(9)
			expect(h:arm(player)):toBeOk()
			local before = h:snap(player)
			withRoster({ player }, function()
				for _ = 1, 5 do
					h.clock:advance(1)
					SalvageService:tickAll(h.startContext)
				end
			end)
			expect(h:snap(player).stored > before.stored):toBe(true)
		end
	)
end)

-- ── 4. THE SMELTER: the capacity ceiling ────────────────────────────────────────────────────────

describe("salvage: stored output is clamped at capacity on every tick", function()
	it("a long gap lands exactly AT capacity, never above it", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local capacity = h:capacity(player)
		expect(capacity > 0):toBe(true)
		h.clock:advance(3600)
		expect(h:tick(player)):toBeOk()
		expectClose(h:snap(player).stored, capacity, "a long gap must fill exactly to capacity")
		expect(h:snap(player).stored <= capacity):toBe(true)
	end)

	it("a FULL smelter stops accruing: the next ticks credit exactly 0", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(100_000)
		expect(h:tick(player)):toBeOk()
		local full = h:snap(player)
		expectClose(full.stored, h:capacity(player), "the smelter should be full")
		for _ = 1, 5 do
			h.clock:advance(600)
			local ticked = h:tick(player)
			expect(ticked):toBeOk()
			expectClose((ticked :: any).value.credited, 0, "a full smelter must credit 0")
			expectClose(h:snap(player).stored, full.stored, "a full smelter must not grow")
		end
	end)

	it("buying the capacity upgrade is what makes accrual resume (the upgrade matters)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(100_000)
		expect(h:tick(player)):toBeOk()
		local beforeUpgrade = h:snap(player).stored
		local baseCapacity = h:capacity(player)

		-- The Structures shop (NOT this slice) writes the level; salvage only reads it.
		h:write(player, function(d: any)
			d.upgrades.smelter = 2
		end)
		local raised = h:capacity(player)
		expect(raised > baseCapacity):toBe(true)

		h.clock:advance(30)
		expect(h:tick(player)):toBeOk()
		local after = h:snap(player).stored
		expect(after > beforeUpgrade):toBe(true)
		expect(after <= raised):toBe(true)
	end)

	it(
		"a SHRUNK capacity re-clamps on the next tick (stored never sits above the ceiling)",
		function()
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.smelter = 4
			end)
			expect(h:arm(player)):toBeOk()
			h.clock:advance(100_000)
			expect(h:tick(player)):toBeOk()
			expect(h:snap(player).stored > 0):toBe(true)

			-- A resurface wipes upgrades: the ceiling drops UNDER what is already banked.
			h:write(player, function(d: any)
				d.upgrades.smelter = 0
			end)
			local shrunk = h:capacity(player)
			expect(h:snap(player).stored > shrunk):toBe(true)
			h.clock:advance(1)
			expect(h:tick(player)):toBeOk()
			expect(h:snap(player).stored <= shrunk):toBe(true)
			expectClose(h:snap(player).stored, shrunk, "the re-clamp lands at the new ceiling")
		end
	)

	it("boundary: a partly-full smelter fills to exactly capacity, not past it", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local capacity = h:capacity(player)
		local rate = h:rate(player)
		h:write(player, function(d: any)
			d.smelter.storedCredits = capacity - rate * 2
		end)
		h.clock:advance(2)
		expect(h:tick(player)):toBeOk()
		expectClose(h:snap(player).stored, capacity, "it should land exactly on the ceiling")

		h.clock:advance(2)
		expect(h:tick(player)):toBeOk()
		expectClose(h:snap(player).stored, capacity, "and stay there")
	end)
end)

-- ── 5. THE HANDOFF WITH OFFLINE ACCRUAL (the away window is NOT ours) ───────────────────────────

describe("salvage: the away window belongs to Offline accrual, never to the online tick", function()
	it(
		"a MIGRATED blob (lastTickUnix = 0) credits NOTHING on its first tick, decades later",
		function()
			-- A pre-v5 record, exactly as the v4->v5 migration will find it: no smelter at all.
			local legacy: any = {
				schemaVersion = 4,
				currencies = { Credits = 10, Pearls = 0 },
				stats = { playtimeSeconds = 0, joinCount = 1, lifetimeCredits = 10 },
				timestamps = { firstJoinUnix = 1, lastSeenUnix = 1 },
				plot = { plotId = "", claimedAtUnix = 0 },
				daily = { streak = 0, lastClaimUnix = 0 },
				upgrades = { drones = 5 },
				flags = {},
				receipts = {},
			}
			local h = newServer({ startUnix = START_UNIX, seed = { player_1 = legacy } })
			local player = h:join(1)
			local blob = h:blob(player)
			expect(blob.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(blob.smelter.lastTickUnix):toBe(0) -- the migration's seed: "never ticked"

			local before = h:snap(player)
			local armed = h:tick(player) -- FIRST tick of the session
			expect(armed):toBeOk()
			local after = h:snap(player)
			expectClose(after.stored, before.stored, "a migrated stamp of 0 must credit NOTHING")
			expect(after.credits):toBe(before.credits)
			expect(after.lifetime):toBe(before.lifetime)
			-- ...and it must have re-stamped, so the NEXT tick counts only the online span.
			expect(after.lastTick):toBe(START_UNIX)

			local rate = h:rate(player)
			h.clock:advance(10)
			expect(h:tick(player)):toBeOk()
			expectClose(
				h:snap(player).stored - after.stored,
				rate * 10,
				"only the online span may be credited"
			)
		end
	)

	it("a REJOIN after a long absence credits nothing for the away window", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.drones = 4
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(60)
		expect(h:tick(player)):toBeOk()
		local atLeave = h:snap(player)
		expect(atLeave.stored > 0):toBe(true)

		-- Leave. One server-wide pass runs with this player off the roster (the real server does one
		-- every second), then a WEEK passes offline. Offline accrual — not this slice — owns it.
		h:leave(player)
		withRoster({}, function()
			SalvageService:tickAll(h.startContext)
		end)
		h.clock:advance(7 * 24 * 3600)

		local rejoined = h:join(1)
		local onJoin = h:snap(rejoined)
		expectClose(onJoin.stored, atLeave.stored, "the banked output survives the absence")
		expect(onJoin.lastTick):toBe(atLeave.lastTick) -- a week-old stamp, persisted

		expect(h:arm(rejoined)):toBeOk() -- session load stamps BEFORE the first accruing tick
		local afterArm = h:snap(rejoined)
		expectClose(afterArm.stored, atLeave.stored, "the away window must credit NOTHING online")
		expect(afterArm.credits):toBe(onJoin.credits)
		expect(afterArm.lastTick):toBe(h.clock:unix())

		local rate = h:rate(rejoined)
		h.clock:advance(5)
		expect(h:tick(rejoined)):toBeOk()
		expectClose(
			h:snap(rejoined).stored - afterArm.stored,
			rate * 5,
			"only the post-arm online span is credited"
		)
	end)

	it(
		"REGRESSION (F2/F3): a leave -> rejoin on the SAME server re-arms with NO tick pass in between",
		function()
			-- THE DEFECT. `_armed` was cleared ONLY by tickAll's prune loop, so a rejoin that beat the
			-- next ~1s pass inherited the PREVIOUS session's armed flag. `armFor` is idempotent on
			-- that key, so it returned Ok{armed=false} WITHOUT stamping, and the first accruing tick
			-- computed elapsed from the persisted, week-old lastTickUnix — paying the away window
			-- online, for a span OfflineService has already granted. The two rejoin cases above hand-
			-- run the missing prune (`withRoster({}, tickAll)`) and so cannot see it; this one leaves
			-- through the PRODUCTION path — PlayerLifecycle.onRemoving, the one owner of
			-- PlayerRemoving — and never runs a tick pass at all.
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = 4
			end)
			expect(h:arm(player)):toBeOk()
			h.clock:advance(60)
			expect(h:tick(player)):toBeOk()
			local atLeave = h:snap(player)
			expect(atLeave.stored > 0):toBe(true)

			-- The real leave sequence, with NO tickAll pass anywhere.
			PlayerLifecycle:onRemoving({ clock = h.clock, data = h.data, salvage = h.seam }, player)
			h.clock:advance(7 * 24 * 3600)

			local rejoined = h:join(1)
			expect(h:arm(rejoined)):toBeOk()
			local afterArm = h:snap(rejoined)
			-- The session was ARMED, not inherited: the stamp is NOW, not the week-old one.
			expect(afterArm.lastTick):toBe(h.clock:unix())
			expectClose(
				afterArm.stored,
				atLeave.stored,
				"the away window must credit NOTHING online"
			)
			expect(afterArm.credits):toBe(atLeave.credits)

			local rate = h:rate(rejoined)
			h.clock:advance(5)
			expect(h:tick(rejoined)):toBeOk()
			expectClose(
				h:snap(rejoined).stored - afterArm.stored,
				rate * 5,
				"only the post-arm online span is credited"
			)
		end
	)

	it("re-arming a LIVE session must not swallow the seconds since the last tick", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local rate = h:rate(player)
		local before = h:snap(player)

		h.clock:advance(30)
		expect(h:arm(player)):toBeOk() -- idempotent: an already-armed session is left alone
		h.clock:advance(0)
		expect(h:tick(player)):toBeOk()
		expectClose(
			h:snap(player).stored - before.stored,
			rate * 30,
			"a redundant arm must not re-stamp and lose 30s of income"
		)
	end)

	it(
		"a collect that arrives BEFORE arming does not convert the away window into Credits",
		function()
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = 6
				d.smelter.storedCredits = 40 -- banked in a PREVIOUS session
				d.smelter.lastTickUnix = START_UNIX - 30 * 24 * 3600 -- a month ago
			end)
			local before = h:snap(player)
			local collected = h:collect(player) -- an eager click on the loading screen
			expect(collected):toBeOk()
			local after = h:snap(player)
			expectClose(
				after.credits - before.credits,
				40,
				"only the previously banked output may be paid, never the away window"
			)
			expectClose(after.lifetime - before.lifetime, 40, "lifetime moves by the same amount")
			expect(after.stored):toBe(0)
		end
	)
end)

-- ── 6. COLLECTING ───────────────────────────────────────────────────────────────────────────────

describe("salvage.collect: the ONE grant path", function()
	it(
		"moves exactly stored into Credits, zeroes stored, and moves lifetime by the same",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			h:write(player, function(d: any)
				d.smelter.storedCredits = 123.5
			end)
			local before = h:snap(player)
			local collected = h:collect(player)
			expect(collected):toBeOk()
			local after = h:snap(player)

			expectClose(
				after.credits - before.credits,
				123.5,
				"Credits must move by exactly stored"
			)
			expectClose(
				after.lifetime - before.lifetime,
				123.5,
				"lifetime must move by exactly stored"
			)
			expect(after.stored):toBe(0)
			expectClose(
				(collected :: any).value.collected,
				123.5,
				"the reply reports what it moved"
			)
			expect((collected :: any).value.stored):toBe(0)
			expectClose(
				(collected :: any).value.balance,
				after.credits,
				"the reply reports the balance"
			)
			expectClose(
				(collected :: any).value.lifetimeCredits,
				after.lifetime,
				"the reply reports lifetime"
			)
		end
	)

	it('emits exactly ONE currency_earned per collect: Credits, source "smelt"', function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 80
		end)
		local before = #h.analytics:eventsOfType("currency_earned")
		expect(h:collect(player)):toBeOk()
		local events = h.analytics:eventsOfType("currency_earned")
		expect(#events - before):toBe(1)
		local last = events[#events]
		expect(last.payload.currency):toBe("Credits")
		expect(last.payload.source):toBe("smelt")
		expectClose(last.payload.amount, 80, "the event describes the amount collected")
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(0) -- a collect is never a spend
	end)

	it("an EMPTY smelter is Err(Insufficient) and moves absolutely nothing", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local before = deepCopy(h:blob(player))
		local snapBefore = h:snap(player)
		local collected = h:collect(player)
		expect(collected):toBeErr(Result.Codes.Insufficient)
		local after = h:snap(player)
		expect(after.credits):toBe(snapBefore.credits)
		expect(after.lifetime):toBe(snapBefore.lifetime)
		expect(after.earned):toBe(snapBefore.earned)
		expect(h:blob(player).currencies):toEqual(before.currencies)
		expect(h:blob(player).stats):toEqual(before.stats)
	end)

	it(
		"the empty-smelter refusal is Insufficient — NOT OutOfRange, Rejected or RateLimited",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			local collected = h:collect(player)
			expect((collected :: any).code):toBe(Result.Codes.Insufficient)
			expect((collected :: any).code).never:toBe(Result.Codes.OutOfRange)
			expect((collected :: any).code).never:toBe(Result.Codes.Rejected)
			expect((collected :: any).code).never:toBe(Result.Codes.RateLimited)
			expect((collected :: any).code).never:toBe(Result.Codes.BadPayload)
		end
	)

	it("a collect before the session is loaded is Err(NoData) and mints nothing", function()
		local h = newServer()
		local player = Mocks.player(77) -- never loadSession'd
		local collected = h:collect(player)
		expect(collected):toBeErr(Result.Codes.NoData)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
	end)

	it(
		"without ctx.economy the grant is REFUSED — no direct write around the enforcement point",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			h:write(player, function(d: any)
				d.smelter.storedCredits = 200
			end)
			local before = deepCopy(h:blob(player))
			local collected = h:collect(player, { noEconomy = true })
			expect(collected):toBeErr()
			local after = h:blob(player)
			expect(after.currencies):toEqual(before.currencies)
			expect(after.stats):toEqual(before.stats)
			expectClose(
				after.smelter.storedCredits,
				200,
				"a refused grant must not burn the smelter"
			)
			expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
		end
	)

	it("an economy that REFUSES leaves the stored output intact (no burn, no mint)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 175
		end)
		local before = h:snap(player)
		local economy = refusingEconomy()
		local collected = h:collect(player, { economy = economy })
		expect(collected):toBeErr()
		expect(economy.calls):toBe(1)
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.lifetime):toBe(before.lifetime)
		expectClose(after.stored, 175, "the captured amount is restored")
		expect(after.stored <= h:capacity(player)):toBe(true) -- and never above the ceiling
	end)

	-- REGRESSION (independent gate finding #1). The case above proves the smelter is not BURNED by a
	-- refusal; it cannot prove the balance is not MINTED by one, because its stub refuses before it
	-- mutates. The real EconomyService.earn writes `currencies[currency] = before + amount` and only
	-- THEN checks `data.stats`, so on a blob whose `stats` table is absent it credits the balance and
	-- returns Err(Internal). grantStored's restore then puts the SAME amount back in the smelter and
	-- the transform still returns `data`, so the snapshot commits with the amount in BOTH places —
	-- repeatable once per collect, and invisible to stats.lifetimeCredits. The slice's guarantee is
	-- atomic-or-nothing: a refused collect leaves the blob byte-identical.
	it(
		"a refused earn that ALREADY CREDITED the balance mints nothing (atomic-or-nothing)",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			h:write(player, function(d: any)
				d.smelter.storedCredits = 250
				-- a corrupt record: the exact input that makes the REAL economy refuse AFTER it has
				-- already written the balance.
				d.stats = nil
			end)
			local before = deepCopy(h:blob(player))

			local collected = h:collect(player) -- the REAL EconomyService, not a stub
			expect(collected):toBeErr()

			local after = h:blob(player)
			expect(after.currencies.Credits):toBe(before.currencies.Credits)
			expectClose(
				after.smelter.storedCredits,
				250,
				"the captured amount is restored to the smelter"
			)
			expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
		end
	)

	-- The same guarantee stated against the CONTRACT rather than against one blob shape: whatever
	-- makes an earn refuse, the amount may never end up in the smelter AND in the balance.
	it("a partially-applying earn cannot leave the amount in BOTH places", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 175
		end)
		local before = h:snap(player)

		local economy = partiallyApplyingEconomy()
		expect(h:collect(player, { economy = economy })):toBeErr()
		expect(economy.calls):toBe(1)

		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.lifetime):toBe(before.lifetime)
		expect(after.earned):toBe(before.earned)
		expectClose(after.stored, 175, "the captured amount is restored, and ONLY there")
	end)

	it("a restore after a refused grant can never breach the capacity ceiling", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.smelter = 6
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(1_000_000)
		expect(h:tick(player)):toBeOk()
		local capacity = h:capacity(player)
		expectClose(h:snap(player).stored, capacity, "the smelter should be full")

		expect(h:collect(player, { economy = refusingEconomy() })):toBeErr()
		expect(h:snap(player).stored <= capacity):toBe(true)
	end)

	it(
		"CONSERVATION: over a session, total Credits earned equals total accrued (no mint)",
		function()
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = 2
				d.upgrades.conveyor = 1
			end)
			expect(h:arm(player)):toBeOk()
			local rate = h:rate(player)
			local capacity = h:capacity(player)
			local before = h:snap(player)

			local elapsed = 0
			for _ = 1, 6 do
				h.clock:advance(20)
				elapsed += 20
				expect(h:tick(player)):toBeOk()
				expect(h:collect(player)):toBeOk()
			end
			local after = h:snap(player)
			expect(after.stored):toBe(0)
			expect(rate * elapsed < capacity):toBe(true) -- the cap never bit, so the sum is exact
			expectClose(
				after.credits - before.credits,
				rate * elapsed,
				"total collected must equal total accrued"
			)
			expectClose(
				after.lifetime - before.lifetime,
				rate * elapsed,
				"lifetime tracks it exactly"
			)
		end
	)

	it("one collect is exactly ONE DataService:update", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 25
		end)
		local proxy = countingData(h.data)
		expect(h:collect(player, { data = proxy })):toBeOk()
		expect(proxy.updates):toBe(1)
	end)
end)

-- ── 7. AUTO-COLLECT: one grant path, not two (ORCHESTRATOR AMENDMENT A2) ────────────────────────

describe("salvage: auto-collect is the SAME grant path as salvage.collect", function()
	it(
		"with the flag ABSENT (today's state) the tick grants nothing — the smelter just fills",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			local before = h:snap(player)
			for _ = 1, 5 do
				h.clock:advance(10)
				expect(h:tick(player)):toBeOk()
			end
			local after = h:snap(player)
			expect(after.credits):toBe(before.credits)
			expect(after.lifetime):toBe(before.lifetime)
			expect(after.earned):toBe(before.earned)
			expect(after.stored > before.stored):toBe(true)
		end
	)

	it(
		"with the flag SET the tick grants automatically, moving lifetime and emitting the event",
		function()
			local h = newServer()
			local player = h:join(1)
			-- Monetization (NOT this slice) grants the flag; salvage only READS it.
			h:write(player, function(d: any)
				d.flags[AUTO_COLLECT_FLAG] = true
				d.upgrades.drones = 3
			end)
			expect(h:arm(player)):toBeOk()
			local rate = h:rate(player)
			local before = h:snap(player)

			h.clock:advance(10)
			local ticked = h:tick(player)
			expect(ticked):toBeOk()
			local after = h:snap(player)

			expectClose(
				(ticked :: any).value.collected,
				rate * 10,
				"the tick reports what it granted"
			)
			expectClose(
				after.credits - before.credits,
				rate * 10,
				"auto-collect credits the balance"
			)
			expectClose(after.lifetime - before.lifetime, rate * 10, "...and the lifetime counter")
			expect(after.earned - before.earned):toBe(1)
			expect(after.stored):toBe(0)
			local events = h.analytics:eventsOfType("currency_earned")
			expect(events[#events].payload.source):toBe("smelt") -- the SAME source, not a second path
			expect(events[#events].payload.currency):toBe("Credits")
		end
	)

	it("A2: the auto trigger moves lifetime by EXACTLY what the manual trigger moves", function()
		local amount = 90
		local function lifetimeDeltaVia(auto: boolean): (number, number, number)
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.flags[AUTO_COLLECT_FLAG] = auto
			end)
			expect(h:arm(player)):toBeOk()
			h:write(player, function(d: any)
				d.smelter.storedCredits = amount
			end)
			local before = h:snap(player)
			if auto then
				expect(h:tick(player)):toBeOk() -- zero elapsed: nothing accrues, the flag grants
			else
				expect(h:collect(player)):toBeOk()
			end
			local after = h:snap(player)
			return after.lifetime - before.lifetime,
				after.credits - before.credits,
				after.earned - before.earned
		end

		local autoLifetime, autoCredits, autoEvents = lifetimeDeltaVia(true)
		local manualLifetime, manualCredits, manualEvents = lifetimeDeltaVia(false)
		expectClose(autoLifetime, amount, "auto-collect must increment lifetimeCredits")
		expectClose(autoLifetime, manualLifetime, "both triggers move lifetime identically")
		expectClose(autoCredits, manualCredits, "both triggers move the balance identically")
		expect(autoEvents):toBe(manualEvents)
		expect(autoEvents):toBe(1)
	end)

	it("auto-collect on an EMPTY smelter is a silent no-op, not an error and not a mint", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.flags[AUTO_COLLECT_FLAG] = true
		end)
		expect(h:arm(player)):toBeOk()
		local before = h:snap(player)
		local ticked = h:tick(player) -- zero elapsed => nothing stored => nothing to grant
		expect(ticked):toBeOk()
		expect((ticked :: any).value.collected):toBe(0)
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.lifetime):toBe(before.lifetime)
		expect(after.earned):toBe(before.earned)
	end)

	-- REGRESSION (independent gate finding #1, on the OTHER trigger). Both cases that pin
	-- atomic-or-nothing against a partially-applying earn drive `salvage.collect`; the auto-collect
	-- tick reaches the SAME grantStored, so a rollback that lived only on the manual path would mint
	-- here once per TICK (1/s) instead of once per collect — a strictly worse leak, and one no manual
	-- case can see. AMENDMENT A2 says the two triggers are one grant path; this asserts the refusal
	-- semantics travel with it, not just the success semantics.
	it("a partially-applying earn on the AUTO trigger mints nothing either", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.flags[AUTO_COLLECT_FLAG] = true
		end)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 175
		end)
		local before = h:snap(player)

		local economy = partiallyApplyingEconomy()
		-- zero elapsed: nothing accrues, so the ONLY thing this tick does is attempt the auto-grant.
		local ticked = h:tick(player, { economy = economy })
		expect(ticked):toBeOk() -- a refused auto-collect is a silent no-op, not a tick failure
		expect(economy.calls):toBe(1)
		expect((ticked :: any).value.collected):toBe(0)

		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.lifetime):toBe(before.lifetime)
		expect(after.earned):toBe(before.earned)
		expectClose(after.stored, 175, "the captured amount is restored, and ONLY there")
	end)

	it("an auto-collecting tick is still exactly ONE DataService:update", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.flags[AUTO_COLLECT_FLAG] = true
		end)
		expect(h:arm(player)):toBeOk()
		local proxy = countingData(h.data)
		h.clock:advance(30)
		expect(h:tick(player, { data = proxy })):toBeOk()
		expect(proxy.updates):toBe(1)
		expect(h:snap(player).credits > 0):toBe(true)
	end)
end)

-- ── 8. THE OBSERVATION SURFACE ──────────────────────────────────────────────────────────────────

describe("salvage.fetch: the derived rate, stored and capacity", function()
	it("reports the seam's rate, the blob's stored and the seam's capacity", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.drones = 3
			d.upgrades.smelter = 2
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(15)
		expect(h:tick(player)):toBeOk()

		local fetched = h:fetch(player)
		expect(fetched):toBeOk()
		local info = (fetched :: any).value
		expectClose(info.rate, h:rate(player), "fetch reports the DERIVED rate")
		expectClose(info.capacity, h:capacity(player), "fetch reports the capacity")
		expectClose(info.stored, h:snap(player).stored, "fetch reports the stored output")
	end)

	it("fetch is SIDE-EFFECT FREE: refreshing the HUD can never accrue or grant", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(30)
		expect(h:tick(player)):toBeOk()
		local before = deepCopy(h:blob(player))

		for _ = 1, 25 do
			h.clock:advance(5) -- time passes between refreshes: an accruing fetch would show here
			expect(h:fetch(player)):toBeOk()
		end
		expect(h:blob(player)):toEqual(before)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
	end)

	it(
		"fetch RE-DERIVES: a changed upgrade level moves the reported rate with no other action",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			local first = (h:fetch(player) :: any).value.rate
			h:write(player, function(d: any)
				d.upgrades.drones = 10
			end)
			local second = (h:fetch(player) :: any).value.rate
			expect(second > first):toBe(true)
			expectClose(second, h:rate(player), "the fetch and the seam agree")
		end
	)

	-- REGRESSION (independent gate finding #2). The side-effect-free case above reads a WELL-FORMED
	-- blob, so an in-place repair inside describe() is invisible to it. DataService.get returns
	-- `session.data` — the LIVE in-memory blob, not a copy — and salvage.fetch is a client-callable
	-- read action (10/s) running outside any ctx.data:update. So a describe() that normalizes a
	-- garbage smelter record IN PLACE is an unlocked write on the one path the slice designates as
	-- the pure observation surface (and one that any concurrent transform, which works on a deepCopy
	-- snapshot and commits it wholesale, silently discards anyway). The REPLY must be sanitized; the
	-- RECORD must be left to the single-writer path.
	it("fetch NEVER writes to the live session blob, even to repair a garbage record", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.smelter.storedCredits = -5
			d.smelter.lastTickUnix = -1
		end)
		local before = deepCopy(h:blob(player))

		local fetched = h:fetch(player)
		expect(fetched):toBeOk()
		expect((fetched :: any).value.stored):toBe(0) -- the READING is normalized...
		expect(h:blob(player)):toEqual(before) -- ...the RECORD is untouched
	end)

	it("fetch before the session is loaded is Err(NoData)", function()
		local h = newServer()
		expect(h:fetch(Mocks.player(404))):toBeErr(Result.Codes.NoData)
	end)
end)

-- ── 9. NEGATIVE / ABUSE: type, range, ownership, rate, and the salvage-rate spoof ───────────────

describe("salvage: the wire refuses everything a client could try to influence", function()
	it(
		"a payload naming a rate / amount / stored / time is Err(BadPayload) on BOTH actions",
		function()
			local h = newServer()
			local player = h:join(1)
			local wire = h:wire()
			local spoofs: { any } = {
				{ amount = 1e9 },
				{ rate = 1e9 },
				{ stored = 1e9 },
				{ storedCredits = 1e9 },
				{ capacity = 1e9 },
				{ multiplier = 1e6 },
				{ credits = 1e9 },
				{ nowUnix = START_UNIX + 1e9 },
				{ lastTickUnix = 0 },
				{ elapsed = 1e9 },
				{ drones = 9999 },
				{ userId = 2 },
			}
			for _, payload in spoofs do
				expect(wire.invoke(Net.Actions.CollectSmelter, player, payload)):toBeErr(
					Result.Codes.BadPayload
				)
				expect(wire.invoke(Net.Actions.FetchSalvage, player, payload)):toBeErr(
					Result.Codes.BadPayload
				)
			end
		end
	)

	it(
		"a non-table payload is Err(BadType); nil and an empty table are the contract shape",
		function()
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			local wire = h:wire()
			for _, bad in { "give me credits", 42, true } do
				expect(wire.invoke(Net.Actions.FetchSalvage, player, bad)):toBeErr(
					Result.Codes.BadType
				)
				expect(wire.invoke(Net.Actions.CollectSmelter, player, bad)):toBeErr(
					Result.Codes.BadType
				)
			end
			expect(wire.invoke(Net.Actions.FetchSalvage, player, nil)):toBeOk()
			expect(wire.invoke(Net.Actions.FetchSalvage, player, {})):toBeOk()
		end
	)

	it("THE RATE SPOOF: no client number ever reaches the balance", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h:write(player, function(d: any)
			d.smelter.storedCredits = 30
		end)
		local wire = h:wire()
		local before = h:snap(player)

		-- (a) a payload that names a number is refused outright...
		expect(wire.invoke(Net.Actions.CollectSmelter, player, { amount = 1e9 })):toBeErr()
		local afterSpoof = h:snap(player)
		expect(afterSpoof.credits):toBe(before.credits)
		expect(afterSpoof.stored):toBe(before.stored)

		-- (b) ...and a payload the validator does NOT recognise cannot influence the number either:
		-- the amount paid is the SERVER-derived stored output, not anything the client sent.
		local collected = wire.invoke(Net.Actions.CollectSmelter, player, { wobble = 1e9 })
		expect(collected):toBeOk()
		local after = h:snap(player)
		expectClose(after.credits - before.credits, 30, "only the server-derived amount is paid")
		expectClose((collected :: any).value.collected, 30, "the reply reports the server's number")
	end)

	it("a spoofed fetch payload can never change the reported rate", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local wire = h:wire()
		local honest = (wire.invoke(Net.Actions.FetchSalvage, player, nil) :: any).value
		local sneaky = (wire.invoke(Net.Actions.FetchSalvage, player, { wobble = 1e9 }) :: any).value
		expectClose(sneaky.rate, honest.rate, "a client key must not move the reported rate")
		expectClose(sneaky.capacity, honest.capacity, "...nor the capacity")
	end)

	it("the spine Gate rate-limits a collect burst (policy discovered from the action)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local policy = SalvageService:collectAction().rate
		expect(type(policy.maxPerWindow)):toBe("number")
		expect(policy.maxPerWindow > 0):toBe(true)
		local wire = h:wire({ gate = true })

		for index = 1, policy.maxPerWindow do
			local result = wire.invoke(Net.Actions.CollectSmelter, player, nil)
			if (result :: any).code == Result.Codes.RateLimited then
				error(`request {index} of {policy.maxPerWindow} was rate-limited too early`, 0)
			end
		end
		expect(wire.invoke(Net.Actions.CollectSmelter, player, nil)):toBeErr(
			Result.Codes.RateLimited
		)
	end)

	it("a RateLimited collect never reaches the economy (nothing is granted)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		local policy = SalvageService:collectAction().rate
		local wire = h:wire({ gate = true })
		for _ = 1, policy.maxPerWindow do
			wire.invoke(Net.Actions.CollectSmelter, player, nil)
		end
		h:write(player, function(d: any)
			d.smelter.storedCredits = 500
		end)
		local before = h:snap(player)
		expect(wire.invoke(Net.Actions.CollectSmelter, player, nil)):toBeErr(
			Result.Codes.RateLimited
		)
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expectClose(after.stored, 500, "a rate-limited collect must not empty the smelter")
		expect(after.earned):toBe(before.earned)
	end)

	it("the fetch action carries its own rate policy and is limited too", function()
		local h = newServer()
		local player = h:join(1)
		local policy = SalvageService:fetchAction().rate
		expect(policy.maxPerWindow > 0):toBe(true)
		local wire = h:wire({ gate = true })
		for _ = 1, policy.maxPerWindow do
			wire.invoke(Net.Actions.FetchSalvage, player, nil)
		end
		expect(wire.invoke(Net.Actions.FetchSalvage, player, nil)):toBeErr(Result.Codes.RateLimited)
	end)

	it("OWNERSHIP: a collect touches only the acting player's smelter", function()
		local h = newServer()
		local alice = h:join(1)
		local bob = h:join(2)
		expect(h:arm(alice)):toBeOk()
		expect(h:arm(bob)):toBeOk()
		h:write(alice, function(d: any)
			d.smelter.storedCredits = 60
		end)
		h:write(bob, function(d: any)
			d.smelter.storedCredits = 500
		end)
		local bobBefore = deepCopy(h:blob(bob))
		local aliceBefore = h:snap(alice)

		local wire = h:wire()
		expect(wire.invoke(Net.Actions.CollectSmelter, alice, nil)):toBeOk()

		expect(h:blob(bob)):toEqual(bobBefore) -- byte-identical
		expectClose(h:snap(alice).credits - aliceBefore.credits, 60, "Alice is paid her own output")
	end)

	it("a poisoned storedCredits (NaN / infinite / negative) can never mint currency", function()
		for _, poison in { 0 / 0, math.huge, -math.huge, -5000, "1e9" } do
			local h = newServer()
			local player = h:join(1)
			expect(h:arm(player)):toBeOk()
			h:write(player, function(d: any)
				d.smelter.storedCredits = poison
			end)
			local before = h:snap(player)
			h:collect(player) -- ok or Err; either way it must not mint
			local after = h:snap(player)
			expectFinite(after.credits, `Credits after collecting {tostring(poison)}`)
			expectFinite(after.lifetime, `lifetime after collecting {tostring(poison)}`)
			expect(after.credits >= 0):toBe(true)
			expect(after.lifetime >= before.lifetime):toBe(true)
			expect(after.credits < 1e12):toBe(true)
		end
	end)

	it("a poisoned blob can never persist a NaN or infinite stored value through a tick", function()
		for _, poison in { 0 / 0, math.huge, -math.huge, 1e308 } do
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = poison
				d.smelter.storedCredits = poison
			end)
			expect(h:arm(player)):toBeOk()
			h.clock:advance(60)
			expect(h:tick(player)):toBeOk()
			local stored = h:snap(player).stored
			expectFinite(stored, `stored after ticking with {tostring(poison)}`)
			expect(stored >= 0):toBe(true)
			expect(stored <= h:capacity(player)):toBe(true)
		end
	end)
end)

-- ── 10. CONCURRENCY: the smelter pays for one fill exactly once ─────────────────────────────────

describe(
	"salvage: interleaved and spam-duplicated collects total EXACTLY the stored amount",
	function()
		-- Build a server with one armed player holding `stored`, then ARM the forced yield inside
		-- the update critical section — so only the racing calls below are parked, never the setup.
		local function raceServer(stored: number): (any, any)
			local h = newServer()
			local player = h:join(1)
			-- A ceiling comfortably above `stored`: a seeded amount ABOVE capacity is a state the
			-- tick's clamp forbids, and re-clamping it would confuse "the smelter paid once" with
			-- "the smelter was capped".
			h:write(player, function(d: any)
				d.upgrades.smelter = 20
			end)
			expect(h:arm(player)):toBeOk()
			expect(h:capacity(player) > stored):toBe(true)
			h:write(player, function(d: any)
				d.smelter.storedCredits = stored
			end)
			h:setYield(true)
			return h, player
		end

		it("TWO interleaved collects grant ONCE; the loser is Err(Insufficient)", function()
			local h, player = raceServer(140)
			local before = h:snap(player)
			local results: { any } = {}
			local cos = {}
			for index = 1, 2 do
				table.insert(
					cos,
					coroutine.create(function()
						results[index] = h:collect(player)
					end)
				)
			end
			drain(cos)

			local ok, errs = 0, 0
			for _, result in results do
				if (result :: any).ok then
					ok += 1
				else
					errs += 1
					expect(result):toBeErr(Result.Codes.Insufficient)
				end
			end
			expect(ok):toBe(1)
			expect(errs):toBe(1)

			local after = h:snap(player)
			expectClose(after.credits - before.credits, 140, "the smelter pays for one fill, once")
			expectClose(after.lifetime - before.lifetime, 140, "lifetime moves once, by the same")
			expect(after.earned - before.earned):toBe(1)
			expect(after.stored):toBe(0)
		end)

		it(
			"WITHOUT the in-memory reservation, the lock-held transform ALONE still grants once",
			function()
				local h, player = raceServer(140)
				local before = h:snap(player)
				local proxy = countingData(h.data)
				local results: { any } = {}

				withoutMemo("_collecting", function()
					local cos = {}
					for index = 1, 2 do
						table.insert(
							cos,
							coroutine.create(function()
								results[index] = h:collect(player, { data = proxy })
							end)
						)
					end
					drain(cos)
				end)

				-- The interleave is REAL: both requests were inside ctx.data:update simultaneously.
				expect(proxy.updates):toBe(2)
				expect(proxy.peak):toBe(2)

				local granted = 0
				for _, result in results do
					if (result :: any).ok then
						granted += 1
					else
						expect(result):toBeErr(Result.Codes.Insufficient)
					end
				end
				expect(granted):toBe(1)

				local after = h:snap(player)
				expectClose(after.credits - before.credits, 140, "no double-grant across the yield")
				expectClose(after.lifetime - before.lifetime, 140, "no double lifetime increment")
				expect(after.earned - before.earned):toBe(1)
				expect(after.stored):toBe(0)
			end
		)

		it("SIX spam-duplicated collects total exactly the stored amount, once", function()
			local h, player = raceServer(333)
			local before = h:snap(player)
			local results: { any } = {}

			withoutMemo("_collecting", function()
				local cos = {}
				for index = 1, 6 do
					table.insert(
						cos,
						coroutine.create(function()
							results[index] = h:collect(player)
						end)
					)
				end
				drain(cos)
			end)

			local granted = 0
			for _, result in results do
				if (result :: any).ok then
					granted += 1
				end
			end
			expect(granted):toBe(1)
			local after = h:snap(player)
			expectClose(after.credits - before.credits, 333, "six clicks pay for one fill")
			expectClose(after.lifetime - before.lifetime, 333, "...and one lifetime increment")
			expect(after.earned - before.earned):toBe(1)
			expect(after.stored):toBe(0)
		end)

		it(
			"FALSIFIABILITY: a naive read-then-yield-then-grant collect DOES double-pay at this yield",
			function()
				-- The counter-case that proves the races above are meaningful rather than trivially
				-- green: the SAME interleave, against a collect that captures `stored` BEFORE the yield,
				-- pays twice for one fill. If this landed on 140, the cases above would distinguish
				-- nothing.
				local blob: any = { credits = 0, stored = 140 }
				local function naiveCollect(): ()
					local amount = blob.stored -- captured BEFORE the yield: the stale read
					coroutine.yield()
					if amount > 0 then
						blob.credits += amount
						blob.stored = 0
					end
				end
				drain({
					coroutine.create(naiveCollect),
					coroutine.create(naiveCollect),
				})
				expect(blob.credits):toBe(280) -- paid TWICE for one fill
				expect(blob.credits).never:toBe(140)
			end
		)

		it("TWO interleaved TICKS credit the elapsed span ONCE, not twice", function()
			local h = newServer()
			local player = h:join(1)
			h:write(player, function(d: any)
				d.upgrades.drones = 3
				d.upgrades.smelter = 8 -- a ceiling far above anything this case can accrue
			end)
			expect(h:arm(player)):toBeOk()
			local rate = h:rate(player)
			local before = h:snap(player)
			h.clock:advance(40)
			h:setYield(true)

			withoutMemo("_ticking", function()
				drain({
					coroutine.create(function()
						h:tick(player)
					end),
					coroutine.create(function()
						h:tick(player)
					end),
				})
			end)

			local after = h:snap(player)
			expectClose(
				after.stored - before.stored,
				rate * 40,
				"the span is credited exactly once"
			)
			expect(after.stored - before.stored < rate * 80):toBe(true)
		end)

		it(
			"an interleaved TICK and COLLECT conserve: nothing is created and nothing is lost",
			function()
				local h = newServer()
				local player = h:join(1)
				h:write(player, function(d: any)
					d.upgrades.drones = 2
					d.upgrades.smelter = 8
				end)
				expect(h:arm(player)):toBeOk()
				local rate = h:rate(player)
				local before = h:snap(player)
				h.clock:advance(50)
				h:setYield(true)

				drain({
					coroutine.create(function()
						h:tick(player)
					end),
					coroutine.create(function()
						h:collect(player)
					end),
				})

				local after = h:snap(player)
				local produced = (after.credits - before.credits) + (after.stored - before.stored)
				expectClose(
					produced,
					rate * 50,
					"credits + stored must equal exactly what was produced"
				)
				expectClose(
					after.lifetime - before.lifetime,
					after.credits - before.credits,
					"lifetime tracks exactly what was paid out"
				)
			end
		)

		it(
			"interleaved collects by TWO players pay each their own output, never each other's",
			function()
				local h = newServer()
				local alice = h:join(1)
				local bob = h:join(2)
				expect(h:arm(alice)):toBeOk()
				expect(h:arm(bob)):toBeOk()
				h:write(alice, function(d: any)
					d.smelter.storedCredits = 70
				end)
				h:write(bob, function(d: any)
					d.smelter.storedCredits = 210
				end)
				local aliceBefore = h:snap(alice)
				local bobBefore = h:snap(bob)
				h:setYield(true)

				drain({
					coroutine.create(function()
						h:collect(alice)
					end),
					coroutine.create(function()
						h:collect(bob)
					end),
					coroutine.create(function()
						h:collect(alice)
					end),
					coroutine.create(function()
						h:collect(bob)
					end),
				})

				expectClose(
					h:snap(alice).credits - aliceBefore.credits,
					70,
					"Alice gets exactly hers"
				)
				expectClose(h:snap(bob).credits - bobBefore.credits, 210, "Bob gets exactly his")
				expect(h:snap(alice).stored):toBe(0)
				expect(h:snap(bob).stored):toBe(0)
			end
		)
	end
)

-- ── 11. BOUNDARIES + THE PERSISTED SHAPE ────────────────────────────────────────────────────────

describe("salvage: boundaries and the persisted smelter record", function()
	it("a rate of exactly 0 accrues nothing and is not an error", function()
		local h = newServer({ depth = depthSeam(0) })
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		expectClose(h:rate(player), 0, "a 0x depth multiplier zeroes the rate")
		h.clock:advance(3600)
		local ticked = h:tick(player)
		expect(ticked):toBeOk()
		expect((ticked :: any).value.credited):toBe(0)
		expect(h:snap(player).stored):toBe(0)
		expect(h:collect(player)):toBeErr(Result.Codes.Insufficient)
	end)

	it("the smelter's stored output and tick stamp survive a save -> reload round-trip", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.drones = 4
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(45)
		expect(h:tick(player)):toBeOk()
		local banked = h:snap(player)
		expect(banked.stored > 0):toBe(true)

		expect(h.data:save(player)):toBeOk()
		h:leave(player)
		withRoster({}, function()
			SalvageService:tickAll(h.startContext)
		end)

		local rejoined = h:join(1)
		local reloaded = h:snap(rejoined)
		expectClose(reloaded.stored, banked.stored, "stored output is persisted")
		expect(reloaded.lastTick):toBe(banked.lastTick)
		-- ...and the reloaded session re-arms, so the gap credits nothing.
		h.clock:advance(9999)
		expect(h:arm(rejoined)):toBeOk()
		expectClose(h:snap(rejoined).stored, banked.stored, "the reload must not credit the gap")
		expect(h:snap(rejoined).lastTick):toBe(h.clock:unix())
	end)

	it("collecting the full capacity works and leaves exactly zero", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.smelter = 3
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(1_000_000)
		expect(h:tick(player)):toBeOk()
		local capacity = h:capacity(player)
		local before = h:snap(player)
		expectClose(before.stored, capacity, "the smelter is full")

		local collected = h:collect(player)
		expect(collected):toBeOk()
		expectClose(h:snap(player).credits - before.credits, capacity, "a full tank pays capacity")
		expect(h:snap(player).stored):toBe(0)
		expect(h:collect(player)):toBeErr(Result.Codes.Insufficient) -- and it is empty now
	end)

	it("the tick reply and the fetch reply agree on rate, stored and capacity", function()
		local h = newServer()
		local player = h:join(1)
		h:write(player, function(d: any)
			d.upgrades.drones = 2
			d.upgrades.conveyor = 3
			d.upgrades.smelter = 1
		end)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(25)
		local ticked = h:tick(player)
		expect(ticked):toBeOk()
		local fetched = h:fetch(player)
		expect(fetched):toBeOk()
		expectClose((ticked :: any).value.rate, (fetched :: any).value.rate, "the rates agree")
		expectClose(
			(ticked :: any).value.stored,
			(fetched :: any).value.stored,
			"the stored values agree"
		)
		expectClose(
			(ticked :: any).value.capacity,
			(fetched :: any).value.capacity,
			"the capacities agree"
		)
	end)

	it("a player with no dome and no upgrades still ticks and collects without error", function()
		-- The fresh-player path: nothing bought, no plot claimed, nothing else built yet.
		local h = newServer()
		local player = h:join(1)
		expect(h:arm(player)):toBeOk()
		h.clock:advance(120)
		expect(h:tick(player)):toBeOk()
		local collected = h:collect(player)
		if (collected :: any).ok then
			expect(h:snap(player).stored):toBe(0)
			expect(h:snap(player).credits > 0):toBe(true)
		else
			-- A zero-rate fresh player is a legitimate design; it must refuse cleanly, never throw.
			expect(collected):toBeErr(Result.Codes.Insufficient)
			expect(h:snap(player).credits):toBe(0)
		end
	end)
end)

-- ── presentation must never be able to fail a transaction that already committed ────────────────
--
-- The integration red-team's finding, and a repeat of a defect this factory SHIPPED once: an
-- unguarded post-write FireClient turned a committed Sell into Err(Internal) in the previous game,
-- invisible to 352 green Lune tests. Here the shape was `context.data:get(player)` sitting OUTSIDE
-- the pcall in pushView. An Err from `get` was handled — but a data layer that THROWS (a released
-- session, an erroring metatable, a future refactor) propagated straight out of pushView and into
-- the caller's return path. Every caller is a POST-WRITE presentation step, so the player would see
-- an error for a grant their balance had already received.
--
-- Seven services carried the identical block. This case pins the contract for salvage, the one whose
-- analogue actually shipped the bug.
describe("salvage: a throwing data layer cannot turn a committed write into a failure", function()
	it("pushView SWALLOWS a get() that throws, and reports false", function()
		local h = newServer()
		local player = h:join(1)

		-- A data layer whose `get` raises rather than returning Err — the case the old code let
		-- escape. Everything else delegates to the real one.
		local throwingData = setmetatable({}, {
			__index = function(_t: any, key: string): any
				local inner: any = h.data
				if key == "get" then
					return function(): any
						error("data layer exploded", 0)
					end
				end
				local value = inner[key]
				if type(value) == "function" then
					return function(_self: any, ...): any
						return value(inner, ...)
					end
				end
				return value
			end,
		})

		local ctx = h:ctx(player, { data = throwingData })
		ctx.net = {
			fireClient = function(): ()
				error("pushView reached the wire despite a throwing get", 0)
			end,
		}

		-- The whole assertion: it RETURNS, it does not propagate. A raised error here is the defect.
		local ok, pushed = pcall(function(): boolean
			return SalvageService:pushView(ctx, player)
		end)
		expect(ok):toBe(true)
		expect(pushed):toBe(false)
	end)
end)
