--!strict
-- games/deep-reach/tests/unit/offline.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/offline.md, NOT from
--  OfflineService's control flow. The implementation was read ONLY to learn its observable interface
--  (method names, return shapes, the names of its two action factories). Every EXPECTATION below is
--  derived from the slice, and every economic number is DISCOVERED through the ctx.salvage seam
--  (rateFor / capacityFor) rather than copied out of any module — so a rebalance of the drone rate or
--  the smelter capacity moves the expectations with the game instead of going red.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   * "THE AWAY WINDOW, and it is yours exclusively: `[timestamps.lastSeenUnix, ctx.clock:unix()]`."
--   * "The computation, at session load, from server state only:
--      `min(ctx.salvage:rateFor(data) * awaySeconds, ctx.salvage:capacityFor(data))`. The cap IS the
--      smelter capacity, so upgrading the smelter visibly raises the offline grant and an enormous
--      away time cannot mint more than one smelter-full. Clamp awaySeconds at 0 for a negative/absurd
--      delta (a clock skew must never mint)."
--   * "THE CLAIM FLOW: `offline.claim` grants the computed amount through ctx.economy:earn
--      (increments stats.lifetimeCredits, emits currency_earned, source="offline") in ONE
--      DataService:update. ONE-SHOT PER SESSION — a second or spam-duplicated claim grants 0, and the
--      guard lives inside the same lock-held transform, not in a client flag."
--   * "NO CLIENT TIME ANYWHERE. The payload carries no timestamp, no duration and no amount; a forged
--      away time is one of the named exploits."
--   * "CLAIM-ON-JOIN WITHOUT RACING SESSION LOAD ... Compute server-side once the session's data is
--      loaded, hold the pending amount."
--   * AMENDMENT A5: "`offline.peek`: it returns { amount, capped } for the pending grant and is
--      SIDE-EFFECT FREE — it must not grant, must not clear the pending amount, and must not re-stamp
--      the away window. Peek-then-claim must grant exactly the peeked amount, exactly once;
--      peek-peek-claim must grant the same amount once."
--   * "NOT THIS SLICE: the rate or capacity formulas (Salvage core — you call its seam); the smelter
--      tick or storedCredits (Salvage core); the daily supply drop; the restock."
--   * "PERSISTENCE: none of your own — you read the EXISTING `timestamps.lastSeenUnix` ... and write
--      only currencies.Credits + stats.lifetimeCredits through ctx.economy."
--
-- WHY THE ECONOMY CASES ASSERT DELTAS ON A WHOLE-BLOB DIFF. An offline claim is a pure MINT: it
-- creates currency out of a clock reading. The written-never-read failure class (docs/LEARNINGS.md)
-- is exactly a test that asserts "a write happened" instead of "this much arrived and nothing else
-- moved". So the headline cases snapshot the ENTIRE blob before and after and compare the CHANGED
-- LEAF PATHS against the slice's allowlist of two — `currencies.Credits` and `stats.lifetimeCredits`.
-- A claim that also re-stamped timestamps.lastSeenUnix, burned smelter.storedCredits or advanced
-- smelter.lastTickUnix would pass a "credits went up" assertion and is red here.
--
-- WHY THERE IS NO MIGRATION ROUND-TRIP SECTION. The slice's PERSISTENCE line is explicit that this
-- feature adds NO persisted field of its own — the pending grant lives in server memory. There is
-- therefore no new field to round-trip. Section 12 asserts the NEGATIVE instead: a full claim
-- lifecycle introduces no new persisted key and does not move schemaVersion, so the absence of a
-- migration is a proven property rather than an assumption.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The dupe this feature is one mistake away from is: read
-- the pending amount, YIELD inside ctx.data:update, and only then zero it — two claims in the same
-- frame both read the same non-zero pending and the away window is paid twice. So the races are
-- driven the way economy_race.spec drives the economy: MockStore's `yieldOnUpdate` (a forced yield
-- INSIDE the update critical section) plus a round-robin coroutine driver. The service also carries
-- an in-memory single-flight reservation, which would short-circuit the interleave before it ever
-- reached the data layer and make the race vacuous — so the headline case NEUTRALISES it and proves
-- the guarantee holds without it. Section 9 opens with a FALSIFICATION counter-case: a naive
-- read-then-yield-then-earn claim, driven at the same yield point through the same instrumented data
-- layer, double-grants AND is observed with two updates in flight simultaneously. That is what makes
-- the green cases below evidence rather than decoration.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Migrations = require("../../src/shared/Migrations")
local Net = require("../../src/shared/Net")
local OfflineService = require("../../src/server/services/offline/OfflineService")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000

-- ── the economic constants, DISCOVERED through the seam this slice is told to call ──────────────
-- The slice fixes the RULE (min(rate * awaySeconds, capacity)) and names the two seam methods, but
-- it deliberately does NOT own the formulas. So the numbers every expectation below is expressed in
-- are probed off ctx.salvage against the production seed blob, exactly as OfflineService must read
-- them. A rebalance of DRONE_RATE or BASE_CAPACITY moves these and every derived expectation with
-- them; a change that broke the CAP RULE still goes red.
local PROBE_BLOB = Migrations.default(START_UNIX)
local BASE_RATE: number = SalvageService.seam:rateFor(PROBE_BLOB, START_UNIX)
local BASE_CAPACITY: number = SalvageService.seam:capacityFor(PROBE_BLOB)
-- The away time at which a default smelter fills exactly: the boundary the cap rule turns on.
local CAP_SECONDS: number = if BASE_RATE > 0 then BASE_CAPACITY / BASE_RATE else 0

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- Every amount in this spec is a product of a discovered rate and an integer second count, so exact
-- equality holds in binary — but a rebalance to a non-representable rate must not turn this spec into
-- a float-noise generator. On mismatch this defers to expect():toBe() so the failure renders both.
local function expectAmount(actual: any, expected: number): ()
	if type(actual) ~= "number" or math.abs(actual - expected) > 1e-9 then
		expect(actual):toBe(expected)
	end
end

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

-- Every changed LEAF PATH between two blob snapshots, sorted. This is the whole point of the
-- economy assertions: the slice grants this feature exactly two fields to move, so "what moved" is
-- the assertion, not "credits went up".
local function changedPaths(before: any, after: any): { string }
	local paths: { string } = {}
	local function walk(a: any, b: any, prefix: string): ()
		local keys: { [any]: boolean } = {}
		if type(a) == "table" then
			for key in a do
				keys[key] = true
			end
		end
		if type(b) == "table" then
			for key in b do
				keys[key] = true
			end
		end
		for key in keys do
			local path = if prefix == "" then tostring(key) else `{prefix}.{tostring(key)}`
			local left = if type(a) == "table" then a[key] else nil
			local right = if type(b) == "table" then b[key] else nil
			if type(left) == "table" or type(right) == "table" then
				walk(left, right, path)
			elseif left ~= right then
				table.insert(paths, path)
			end
		end
	end
	walk(before, after, "")
	table.sort(paths)
	return paths
end

-- A blob shaped exactly as the production seed writes it, stamped so the player LOGGED OUT
-- `awaySeconds` before START_UNIX. Migrations.default writes timestamps.lastSeenUnix = its argument,
-- which is precisely the base the slice says this feature reads.
local function blobAway(awaySeconds: number, mutate: ((any) -> ())?): any
	local blob = Migrations.default(START_UNIX - awaySeconds)
	if mutate ~= nil then
		mutate(blob)
	end
	return blob
end

-- A store seed: userId -> the persisted blob for that player, keyed the way DataService keys it.
local function seedAway(entries: { { userId: number, away: number, mutate: ((any) -> ())? } }): any
	local seed: any = {}
	for _, entry in entries do
		seed[Config.schemaKeyPrefix .. tostring(entry.userId)] = blobAway(entry.away, entry.mutate)
	end
	return seed
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
			error("offline race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`offline race coroutine errored: {tostring(err)}`)
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
-- pair genuinely reaches the data layer. The slice's stated guarantee is "a second or spam-duplicated
-- claim grants 0" — a per-server memo is belt-and-braces for that (and says nothing about the same
-- player on another server), so the guarantee must hold without it. Always restored.
local function withoutSingleFlight(body: () -> ()): ()
	local real = OfflineService._claiming
	local inert: any = setmetatable({}, {
		__newindex = function() end, -- every reservation is silently dropped
	})
	-- NON-VACUITY GUARD. If the drop ever stopped working (a field rename, a rawset, a metatable the
	-- service installs itself), the races below would silently be proving the belt-and-braces
	-- reservation instead of the guarantee the slice states, and would be green for the wrong reason.
	inert.probe = true
	if rawget(inert, "probe") ~= nil then
		error("offline spec: the single-flight neutralisation is not inert")
	end
	OfflineService._claiming = inert
	local ok, err = pcall(body)
	OfflineService._claiming = real
	if not ok then
		error(err, 0)
	end
end

-- Temporarily shorten the join hook's bounded wait so a spec can drive the never-loads path without
-- spinning 200 times. Always restored.
local function withLoadWait(attempts: number, body: () -> ()): ()
	local real = OfflineService.loadWaitAttempts
	OfflineService.loadWaitAttempts = attempts
	local ok, err = pcall(body)
	OfflineService.loadWaitAttempts = real
	if not ok then
		error(err, 0)
	end
end

-- Temporarily inject a roster provider (the service's documented Tier-1 seam for the memory prune).
local function withRoster(players: { any }, body: () -> ()): ()
	local real = OfflineService._players
	OfflineService._players = function(): { any }
		return players
	end
	local ok, err = pcall(body)
	OfflineService._players = real
	if not ok then
		error(err, 0)
	end
end

-- A pass-through ctx.data that COUNTS updates AND tracks the PEAK number in flight simultaneously.
-- `updates` alone cannot tell an interleave from two sequential calls; `peak` can only reach 2 if a
-- second claim entered ctx.data:update while the first was still parked inside it. Section 9's
-- falsification case asserts peak == 2, which is what proves the forced yield is genuinely armed.
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

-- A ctx.data whose first `failures` updates are refused by the store, so the restore path is
-- exercised. `get` is untouched (the session really is loaded).
local function failingData(data: any, failures: number, code: string): any
	local proxy: any = { remaining = failures, updates = 0 }
	function proxy.update(self: any, player: any, transform: any): any
		self.updates += 1
		if self.remaining > 0 then
			self.remaining -= 1
			return Result.err(code, "offline spec: the store refused this write")
		end
		return data:update(player, transform)
	end
	function proxy.get(_self: any, player: any): any
		return data:get(player)
	end
	return proxy
end

-- A ctx.salvage stand-in. The REAL seam is used everywhere it matters; this exists only for the
-- poisoned-reading cases, where the point is that a broken upstream cannot mint.
local function salvageSeam(rate: any, capacity: any): any
	local seam: any = {}
	function seam.rateFor(_self: any, _data: any, _nowUnix: number?, _depth: any?): any
		return rate
	end
	function seam.capacityFor(_self: any, _data: any): any
		return capacity
	end
	return seam
end

-- An economy that CREDITS the balance and THEN refuses. The nastiest shape a seam can have, and the
-- one the salvage gate actually caught: every caller reads `if not granted.ok then` as "nothing
-- happened". A claim that trusted that would commit the credit AND keep the window claimable — one
-- free smelter-full per refused claim, with stats.lifetimeCredits never moving so nothing downstream
-- could see it.
local function creditThenRefuseEconomy(): any
	local seam: any = { calls = 0 }
	function seam.earn(self: any, data: any, currency: string, amount: number, _source: string): any
		self.calls += 1
		if type(data) == "table" and type(data.currencies) == "table" then
			data.currencies[currency] = (data.currencies[currency] or 0) + amount
		end
		return Result.err(
			Result.Codes.Internal,
			"offline spec: the economy refused after crediting"
		)
	end
	return seam
end

-- An economy that refuses cleanly, mutating nothing.
local function refusingEconomy(code: string): any
	local seam: any = { calls = 0 }
	function seam.earn(
		self: any,
		_data: any,
		_currency: string,
		_amount: number,
		_source: string
	): any
		self.calls += 1
		return Result.err(code, "offline spec: refused")
	end
	return seam
end

-- ── the world ───────────────────────────────────────────────────────────────────────────────────

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, the REAL SalvageService seam installed on ctx.salvage (so the cap under test is
-- the actual smelter capacity, not a stub's opinion of it), and OfflineService Started against a
-- recording `net`. Start is the only way the actions and the view-push context are obtained.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	-- MockStore reads `yieldOnUpdate` off this LIVE table on every update, so the forced yield is
	-- armed only for the racing part of a case: it parks the CALLING coroutine, and a spec's setup
	-- writes run on the main thread, which nothing would resume.
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
		if opts.fireClientThrows then
			error("offline spec: the wire is down")
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
	SalvageService:Start(startContext) -- installs the REAL ctx.salvage seam
	OfflineService:Start(startContext)

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		seam = startContext.salvage,
		registered = registered,
		pushes = pushes,
		startContext = startContext,
		storeOptions = storeOptions,
	}

	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	-- The ActionContext a direct peek/claim call receives. `overrides` swaps one seam without
	-- rebuilding the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = if o.playerOverridden == true then o.player else player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			salvage = if o.noSalvage == true
				then nil
				else (if o.salvage ~= nil then o.salvage else self.seam),
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

	function h.peek(self: any, player: any, overrides: any?): any
		return OfflineService:peek(self:ctx(player, overrides))
	end

	function h.claim(self: any, player: any, overrides: any?): any
		return OfflineService:claim(self:ctx(player, overrides))
	end

	function h.prepare(self: any, player: any): any
		return OfflineService:prepareOnJoin(self.startContext, player)
	end

	-- The two numbers the slice's rule is written in, read through the seam it names.
	function h.rate(self: any, player: any): number
		return self.seam:rateFor(self:blob(player), self.clock:unix())
	end

	function h.capacity(self: any, player: any): number
		return self.seam:capacityFor(self:blob(player))
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net, with the two offline actions
	-- registered from the service's own factories. `gate = true` opts INTO the spine rate Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local harness = Mocks.net({
			clock = self.clock,
			data = self.data,
			economy = self.economy,
			salvage = self.seam,
			gate = if w.gate == true then Mocks.gate(self.clock) else false,
		})
		harness.register(OfflineService:claimAction())
		harness.register(OfflineService:peekAction())
		return harness
	end

	-- The numbers every economy case compares before/after.
	function h.snap(self: any, player: any): any
		local blob = self:blob(player)
		return {
			credits = blob.currencies.Credits,
			lifetime = blob.stats.lifetimeCredits,
			lastSeen = blob.timestamps.lastSeenUnix,
			stored = blob.smelter.storedCredits,
			lastTick = blob.smelter.lastTickUnix,
			earned = #self.analytics:eventsOfType("currency_earned"),
			spent = #self.analytics:eventsOfType("currency_spent"),
			pushes = #self.pushes,
		}
	end

	return h
end

-- ── 0. the discovery probe is not vacuous ───────────────────────────────────────────────────────
-- Every expectation in this file is expressed in BASE_RATE / BASE_CAPACITY. If either probed as 0,
-- most cases below would assert "0 == 0" and pass against a service that grants nothing at all.

describe("offline: the discovered economic constants are usable (anti-vacuity)", function()
	it("the seam reports a POSITIVE drone rate for a seed blob", function()
		expect(type(BASE_RATE)):toBe("number")
		expect(BASE_RATE > 0):toBe(true)
	end)

	it("the seam reports a POSITIVE smelter capacity for a seed blob", function()
		expect(type(BASE_CAPACITY)):toBe("number")
		expect(BASE_CAPACITY > 0):toBe(true)
	end)

	it("a seed blob's persisted away-base is the stamp Migrations.default wrote", function()
		-- The slice's base is `timestamps.lastSeenUnix`, and this spec seeds it through the
		-- production default. If that ever stopped being the field, every away window here would be 0.
		expect(blobAway(600).timestamps.lastSeenUnix):toBe(START_UNIX - 600)
	end)
end)

-- ── 1. the away window: [timestamps.lastSeenUnix, ctx.clock:unix()], on server time only ─────────

describe("offline: the away window is [lastSeenUnix, ctx.clock:unix()] on SERVER time", function()
	it("a 200s absence accrues rate * 200, below the cap", function()
		local away = 200
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local peeked = h:peek(player)
		expect(peeked):toBeOk()
		local info = (peeked :: any).value
		expect(info.awaySeconds):toBe(away)
		expectAmount(info.amount, BASE_RATE * away)
		expect(info.capped):toBe(false)
	end)

	it("the window is measured against the SERVER clock, not wall time", function()
		-- Identically-stamped blobs, two servers whose clocks differ: the grant follows the clock the
		-- service was handed. This is the injectable-clock rule (CLAUDE.md §7) made observable.
		-- (Distinct userIds: OfflineService's pending map is per-SERVER-process state keyed by
		-- userId, and this spec runs both "servers" inside one process.)
		local a = newServer({ seed = seedAway({ { userId = 1, away = 100 } }) })
		local b = newServer({
			seed = seedAway({ { userId = 2, away = 100 } }),
			startUnix = START_UNIX + 300,
		})
		local playerA = a:join(1)
		local playerB = b:join(2)
		expectAmount((a:peek(playerA) :: any).value.amount, BASE_RATE * 100)
		expectAmount((b:peek(playerB) :: any).value.amount, BASE_RATE * 400)
	end)

	it("awaySecondsFor is the pure span, and it is exclusively this feature's", function()
		expect(OfflineService:awaySecondsFor(1000, 1600)):toBe(600)
		expect(OfflineService:awaySecondsFor(1000, 1001)):toBe(1)
	end)

	it("a fresh player (base == now) is owed NOTHING", function()
		local h = newServer() -- no seed: default() stamps lastSeenUnix = the load instant
		local player = h:join(1)
		local peeked = h:peek(player)
		expect(peeked):toBeOk()
		expect((peeked :: any).value.awaySeconds):toBe(0)
		expect((peeked :: any).value.amount):toBe(0)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
	end)

	it(
		"the window does NOT include the smelter's own tick base (that field is Salvage's)",
		function()
			-- smelter.lastTickUnix is stamped by Salvage core at session load precisely so its online tick
			-- never re-counts this window. Moving it must not move the offline grant by one credit.
			local away = 300
			local h = newServer({
				seed = seedAway({
					{
						userId = 1,
						away = away,
						mutate = function(blob: any): ()
							blob.smelter.lastTickUnix = START_UNIX - 5
						end,
					},
				}),
			})
			local player = h:join(1)
			expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * away)
		end
	)
end)

-- ── 2. the cap IS the smelter capacity ──────────────────────────────────────────────────────────

describe("offline: the grant is capped by the SMELTER CAPACITY", function()
	it("an away time past the fill point grants exactly one smelter-full, capped=true", function()
		local away = math.floor(CAP_SECONDS) + 1000
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expectAmount(info.amount, BASE_CAPACITY)
		expect(info.capped):toBe(true)
		expect(info.uncapped > info.amount):toBe(true)
	end)

	it("an ENORMOUS away time still cannot mint more than one smelter-full", function()
		-- The named exploit, reached without any client input at all: a blob stamped at the unix
		-- epoch. Uncapped this is ~27 years of drone output.
		local h = newServer({
			seed = seedAway({ { userId = 1, away = START_UNIX - 1 } }),
		})
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expectAmount(info.amount, BASE_CAPACITY)
		expect(info.capped):toBe(true)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		local after = h:snap(player)
		expectAmount(after.credits - before.credits, BASE_CAPACITY)
	end)

	it(
		"UPGRADING the smelter visibly raises the offline grant (the design reason for the cap)",
		function()
			local away = math.floor(CAP_SECONDS) + 1000
			local base = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
			local upgraded = newServer({
				seed = seedAway({
					{
						userId = 2,
						away = away,
						mutate = function(blob: any): ()
							blob.upgrades[SalvageService.UPGRADE_KEYS.smelter] = 2
						end,
					},
				}),
			})
			local basePlayer = base:join(1)
			local upgradedPlayer = upgraded:join(2)

			local baseCapacity = base:capacity(basePlayer)
			local upgradedCapacity = upgraded:capacity(upgradedPlayer)
			-- Vacuity guard: if the upgrade did not move the capacity, this case proves nothing.
			expect(upgradedCapacity > baseCapacity):toBe(true)

			local baseAmount = (base:peek(basePlayer) :: any).value.amount
			local upgradedAmount = (upgraded:peek(upgradedPlayer) :: any).value.amount
			expectAmount(baseAmount, baseCapacity)
			expectAmount(upgradedAmount, upgradedCapacity)
			expect(upgradedAmount > baseAmount):toBe(true)
		end
	)

	it(
		"a FASTER fleet fills the same window faster, and is still capped by the same ceiling",
		function()
			local away = 400
			local slow = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
			local fast = newServer({
				seed = seedAway({
					{
						userId = 2,
						away = away,
						mutate = function(blob: any): ()
							blob.upgrades[SalvageService.UPGRADE_KEYS.drones] = 20
						end,
					},
				}),
			})
			local slowPlayer = slow:join(1)
			local fastPlayer = fast:join(2)
			expect(fast:rate(fastPlayer) > slow:rate(slowPlayer)):toBe(true)
			local slowAmount = (slow:peek(slowPlayer) :: any).value.amount
			local fastAmount = (fast:peek(fastPlayer) :: any).value.amount
			expect(fastAmount > slowAmount):toBe(true)
			expectAmount(fastAmount, fast:capacity(fastPlayer))
		end
	)

	it("accrualFor is exactly min(rate * awaySeconds, capacity)", function()
		local under = OfflineService:accrualFor(2, 10, 100)
		expectAmount(under.amount, 20)
		expect(under.capped):toBe(false)
		local over = OfflineService:accrualFor(2, 1000, 100)
		expectAmount(over.amount, 100)
		expect(over.capped):toBe(true)
	end)
end)

-- ── 3. boundaries ───────────────────────────────────────────────────────────────────────────────

describe("offline: boundary values around the cap and the zero", function()
	it(
		"exactly at the fill point: amount == capacity and NOTHING was lost (capped=false)",
		function()
			local away = math.floor(CAP_SECONDS)
			local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
			local player = h:join(1)
			local info = (h:peek(player) :: any).value
			expectAmount(info.amount, BASE_CAPACITY)
			expectAmount(info.uncapped, BASE_CAPACITY)
			expect(info.capped):toBe(false)
		end
	)

	it("one second past the fill point: amount == capacity and capped=true", function()
		local away = math.floor(CAP_SECONDS) + 1
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expectAmount(info.amount, BASE_CAPACITY)
		expect(info.capped):toBe(true)
	end)

	it("one second short of the fill point: strictly below capacity, capped=false", function()
		local away = math.floor(CAP_SECONDS) - 1
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expectAmount(info.amount, BASE_RATE * away)
		expect(info.amount < BASE_CAPACITY):toBe(true)
		expect(info.capped):toBe(false)
	end)

	it("the smallest payable window is ONE second", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 1 } }) })
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expectAmount(info.amount, BASE_RATE * 1)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE)
	end)

	it("a ZERO-second window grants nothing and is refused with Insufficient", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 0 } }) })
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expect(h:snap(player).credits):toBe(before.credits)
		expect(h:snap(player).lifetime):toBe(before.lifetime)
	end)
end)

-- ── 4. a clock skew must never mint ─────────────────────────────────────────────────────────────

describe("offline: a negative or absurd delta clamps to 0 (a clock skew never mints)", function()
	it("a base stamped in the FUTURE grants nothing", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = -100000 } }) })
		local player = h:join(1)
		local info = (h:peek(player) :: any).value
		expect(info.awaySeconds):toBe(0)
		expect(info.amount):toBe(0)
		local before = h:snap(player)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expect(h:snap(player).credits):toBe(before.credits)
	end)

	it("awaySecondsFor clamps a backwards clock to 0, never to a negative span", function()
		expect(OfflineService:awaySecondsFor(2000, 1000)):toBe(0)
		expect(OfflineService:awaySecondsFor(2000, 2000)):toBe(0)
	end)

	it("a MISSING base (0) grants nothing — never a free smelter from the epoch", function()
		local h = newServer({
			seed = seedAway({
				{
					userId = 1,
					away = 500,
					mutate = function(blob: any): ()
						blob.timestamps.lastSeenUnix = 0
					end,
				},
			}),
		})
		local player = h:join(1)
		expect((h:peek(player) :: any).value.amount):toBe(0)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
	end)

	it("a NEGATIVE base grants nothing", function()
		local h = newServer({
			seed = seedAway({
				{
					userId = 1,
					away = 500,
					mutate = function(blob: any): ()
						blob.timestamps.lastSeenUnix = -9999
					end,
				},
			}),
		})
		local player = h:join(1)
		expect((h:peek(player) :: any).value.amount):toBe(0)
	end)

	it("a GARBAGE base (a string) grants nothing rather than throwing", function()
		local h = newServer({
			seed = seedAway({
				{
					userId = 1,
					away = 500,
					mutate = function(blob: any): ()
						blob.timestamps.lastSeenUnix = "yesterday" :: any
					end,
				},
			}),
		})
		local player = h:join(1)
		local peeked = h:peek(player)
		expect(peeked):toBeOk()
		expect((peeked :: any).value.amount):toBe(0)
	end)

	it("a NaN / infinite base grants nothing", function()
		expect(OfflineService:awaySecondsFor(0 / 0, START_UNIX)):toBe(0)
		expect(OfflineService:awaySecondsFor(math.huge, START_UNIX)):toBe(0)
		expect(OfflineService:awaySecondsFor(-math.huge, START_UNIX)):toBe(0)
	end)
end)

-- ── 5. the claim: exactly the computed amount, through ctx.economy, in ONE update ────────────────

describe("offline: the claim grants the computed amount through ctx.economy", function()
	it("Credits AND stats.lifetimeCredits both move by exactly the pending amount", function()
		local away = 300
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local expected = math.min(BASE_RATE * away, BASE_CAPACITY)
		local before = h:snap(player)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expectAmount((claimed :: any).value.amount, expected)
		local after = h:snap(player)
		expectAmount(after.credits - before.credits, expected)
		expectAmount(after.lifetime - before.lifetime, expected)
	end)

	it(
		"the claim moves ONLY currencies.Credits and stats.lifetimeCredits — nothing else",
		function()
			-- The slice's PERSISTENCE line, asserted as a whole-blob diff. A claim that re-stamped
			-- lastSeenUnix, burned storedCredits or advanced lastTickUnix passes "credits went up" and
			-- fails here.
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local before = deepCopy(h:blob(player))
			expect(h:claim(player)):toBeOk()
			local after = deepCopy(h:blob(player))
			expect(changedPaths(before, after)):toEqual({
				"currencies.Credits",
				"stats.lifetimeCredits",
			})
		end
	)

	it(
		"the claim does NOT re-stamp timestamps.lastSeenUnix (the data layer owns that field)",
		function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local before = h:snap(player)
			expect(h:claim(player)):toBeOk()
			expect(h:snap(player).lastSeen):toBe(before.lastSeen)
		end
	)

	it("the claim does NOT touch smelter.storedCredits or smelter.lastTickUnix", function()
		local h = newServer({
			seed = seedAway({
				{
					userId = 1,
					away = 300,
					mutate = function(blob: any): ()
						blob.smelter.storedCredits = 42
					end,
				},
			}),
		})
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		local after = h:snap(player)
		expect(after.stored):toBe(42)
		expect(after.lastTick):toBe(before.lastTick)
	end)

	it("exactly ONE DataService:update reaches the data layer per granted claim", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local counter = countingData(h.data)
		expect(h:claim(player, { data = counter })):toBeOk()
		expect(counter.updates):toBe(1)
	end)

	it("a REFUSED claim reaches the data layer ZERO times", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 0 } }) })
		local player = h:join(1)
		local counter = countingData(h.data)
		expect(h:claim(player, { data = counter })):toBeErr(Result.Codes.Insufficient)
		expect(counter.updates):toBe(0)
	end)

	it("the granted amount equals the peeked amount, exactly", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 411 } }) })
		local player = h:join(1)
		local peeked = (h:peek(player) :: any).value.amount
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expectAmount((claimed :: any).value.amount, peeked)
	end)

	it("the claim reports the post-grant balance and lifetime the economy computed", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		local blob = h:blob(player)
		expectAmount((claimed :: any).value.balance, blob.currencies.Credits)
		expectAmount((claimed :: any).value.lifetimeCredits, blob.stats.lifetimeCredits)
	end)
end)

-- ── 6. analytics: currency_earned, source="offline" ─────────────────────────────────────────────

describe("offline: the earn is observable as currency_earned with source=offline", function()
	it("a granted claim emits exactly one currency_earned carrying the granted amount", function()
		local away = 300
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local expected = math.min(BASE_RATE * away, BASE_CAPACITY)
		local before = #h.analytics:eventsOfType("currency_earned")
		expect(h:claim(player)):toBeOk()
		local events = h.analytics:eventsOfType("currency_earned")
		expect(#events - before):toBe(1)
		local payload = events[#events].payload
		expect(payload.source):toBe("offline")
		expect(payload.currency):toBe("Credits")
		expectAmount(payload.amount, expected)
	end)

	it("an offline claim is never a currency_spent", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(0)
	end)

	it("a REFUSED claim emits no currency event at all", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 0 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(0)
	end)

	it("a SECOND claim emits nothing (one window, one event)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(1)
	end)
end)

-- ── 7. ONE-SHOT PER SESSION ─────────────────────────────────────────────────────────────────────

describe("offline: the away window pays exactly ONCE per session", function()
	it("a second claim grants 0 and is refused with Insufficient", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		local afterFirst = h:snap(player)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		local afterSecond = h:snap(player)
		expect(afterSecond.credits):toBe(afterFirst.credits)
		expect(afterSecond.lifetime):toBe(afterFirst.lifetime)
		expectAmount(afterFirst.credits - before.credits, math.min(BASE_RATE * 300, BASE_CAPACITY))
	end)

	it("TEN sequential claims pay exactly one window in total", function()
		local away = 300
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local before = h:snap(player)
		local granted = 0
		for _ = 1, 10 do
			local result = h:claim(player)
			if result.ok then
				granted += 1
			else
				expect(result):toBeErr(Result.Codes.Insufficient)
			end
		end
		expect(granted):toBe(1)
		expectAmount(
			h:snap(player).credits - before.credits,
			math.min(BASE_RATE * away, BASE_CAPACITY)
		)
	end)

	it("WAITING after a claim does not re-open the window (no re-mint by the clock)", function()
		-- The window is a snapshot of one session's absence. Advancing the server clock inside the
		-- SAME session must not accrue a second window: online output is the smelter's job.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local afterClaim = h:snap(player)
		h.clock:advance(100000)
		expect((h:peek(player) :: any).value.amount):toBe(0)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expect(h:snap(player).credits):toBe(afterClaim.credits)
	end)

	it(
		"the one-shot refusal is Insufficient, NOT RateLimited (they are different failures)",
		function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			expect(h:claim(player)):toBeOk()
			local second = h:claim(player)
			expect(second):toBeErr(Result.Codes.Insufficient)
			expect((second :: any).code == Result.Codes.RateLimited):toBe(false)
		end
	)

	it("a REJOIN opens a NEW window (the leave stamped a new base)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 200 } }) })
		local player = h:join(1)
		local firstExpected = math.min(BASE_RATE * 200, BASE_CAPACITY)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, firstExpected)

		h:leave(player) -- the data layer stamps lastSeenUnix = now on release
		h.clock:advance(400)
		local rejoined = h:join(1)
		local info = (h:peek(rejoined) :: any).value
		expect(info.awaySeconds):toBe(400)
		local secondExpected = math.min(BASE_RATE * 400, BASE_CAPACITY)
		expectAmount(info.amount, secondExpected)
		local beforeSecond = h:snap(rejoined)
		expect(h:claim(rejoined)):toBeOk()
		expectAmount(h:snap(rejoined).credits - beforeSecond.credits, secondExpected)
	end)

	it("a rejoin does NOT re-pay the previous session's window", function()
		-- The pointed version of the case above: if the leave->rejoin cycle re-used the OLD base, the
		-- second grant would be the FULL elapsed span since the original logout, not just the gap.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 200 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		h:leave(player)
		h.clock:advance(10)
		local rejoined = h:join(1)
		local info = (h:peek(rejoined) :: any).value
		expect(info.awaySeconds):toBe(10)
		expectAmount(info.amount, BASE_RATE * 10)
	end)
end)

-- ── 8. peek is SIDE-EFFECT FREE (AMENDMENT A5) ──────────────────────────────────────────────────

describe("offline: offline.peek is strictly side-effect free", function()
	it("a peek changes NOTHING in the persisted blob", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local before = deepCopy(h:blob(player))
		expect(h:peek(player)):toBeOk()
		expect(h:peek(player)):toBeOk()
		expect(changedPaths(before, deepCopy(h:blob(player)))):toEqual({})
	end)

	it("a peek reaches ctx.data:update ZERO times", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local counter = countingData(h.data)
		expect(h:peek(player, { data = counter })):toBeOk()
		expect(h:peek(player, { data = counter })):toBeOk()
		expect(counter.updates):toBe(0)
	end)

	it("a peek pushes no client view and emits no currency event", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:peek(player)):toBeOk()
		local after = h:snap(player)
		expect(after.pushes):toBe(before.pushes)
		expect(after.earned):toBe(before.earned)
	end)

	it("PEEK-THEN-CLAIM grants exactly the peeked amount, exactly once", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 411 } }) })
		local player = h:join(1)
		local peeked = (h:peek(player) :: any).value
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, peeked.amount)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expectAmount(h:snap(player).credits - before.credits, peeked.amount)
	end)

	it("PEEK-PEEK-CLAIM grants the SAME amount once (peeking never compounds)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 411 } }) })
		local player = h:join(1)
		local first = (h:peek(player) :: any).value.amount
		local second = (h:peek(player) :: any).value.amount
		local third = (h:peek(player) :: any).value.amount
		expectAmount(second, first)
		expectAmount(third, first)
		local before = h:snap(player)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expectAmount((claimed :: any).value.amount, first)
		expectAmount(h:snap(player).credits - before.credits, first)
	end)

	it(
		"a peek does not re-stamp the away window: the amount is stable as the clock runs",
		function()
			-- If peeking re-based the window, a player who left the popup open would watch their pending
			-- grant shrink to nothing. If it re-COMPUTED it, they would watch it grow for free.
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local first = (h:peek(player) :: any).value
			h.clock:advance(5000)
			local later = (h:peek(player) :: any).value
			expectAmount(later.amount, first.amount)
			expect(later.awaySeconds):toBe(first.awaySeconds)
			expect(later.lastSeenUnix):toBe(first.lastSeenUnix)
			local before = h:snap(player)
			expect(h:claim(player)):toBeOk()
			expectAmount(h:snap(player).credits - before.credits, first.amount)
		end
	)

	it("a peek AFTER a claim reports 0 and claimed=true (the popup can tell)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect((h:peek(player) :: any).value.claimed):toBe(false)
		expect(h:claim(player)):toBeOk()
		local after = (h:peek(player) :: any).value
		expect(after.amount):toBe(0)
		expect(after.claimed):toBe(true)
	end)

	it("peek reports whether the ceiling BIT, so the popup can teach the upgrade", function()
		local under = newServer({ seed = seedAway({ { userId = 1, away = 100 } }) })
		local over = newServer({
			seed = seedAway({ { userId = 2, away = math.floor(CAP_SECONDS) + 500 } }),
		})
		expect((under:peek(under:join(1)) :: any).value.capped):toBe(false)
		local overInfo = (over:peek(over:join(2)) :: any).value
		expect(overInfo.capped):toBe(true)
		expect(overInfo.uncapped > overInfo.capacity):toBe(true)
	end)
end)

-- ── 9. CONCURRENCY: interleaved + spam-duplicated claims ────────────────────────────────────────

describe("offline: interleaved and spam-duplicated claims (falsifiable)", function()
	-- 9.0 THE FALSIFICATION. Everything below it is only evidence if the driver genuinely interleaves
	-- two claims INSIDE the update critical section. This counter-case is the naive claim the slice
	-- warns against — read the pending amount, yield in the update, zero it afterwards — driven at the
	-- SAME yield point through the SAME instrumented data layer. It double-grants, and two updates are
	-- observed in flight at once.
	it("FALSIFIABILITY: a naive read-then-yield-then-zero claim DOES double-grant here", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local amount = (h:peek(player) :: any).value.amount
		expect(amount > 0):toBe(true)

		local record: any = { amount = amount }
		local counter = countingData(h.data)
		local economy = h.economy

		local function naiveClaim(): any
			local captured = record.amount -- read BEFORE the yield: the defect
			if captured <= 0 then
				return Result.err(Result.Codes.Insufficient, "naive: nothing pending")
			end
			local applied: any = nil
			local written = counter:update(player, function(d: any): any
				applied = economy:earn(d, "Credits", captured, "offline")
				return d
			end)
			record.amount = 0 -- zeroed AFTER the yield: far too late
			if not written.ok then
				return written
			end
			return applied
		end

		local before = h:snap(player)
		h:setYield(true)
		drain({
			coroutine.create(function()
				naiveClaim()
			end),
			coroutine.create(function()
				naiveClaim()
			end),
		})
		h:setYield(false)

		expect(counter.updates):toBe(2)
		-- The load-bearing proof that the interleave is REAL: both claims were inside ctx.data:update
		-- simultaneously. Without the forced yield this would be 1 and every case below would be
		-- silently testing two sequential calls.
		expect(counter.peak):toBe(2)
		expectAmount(h:snap(player).credits - before.credits, amount * 2)
	end)

	it("TWO interleaved claims pay the window EXACTLY ONCE (single-flight neutralised)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local amount = (h:peek(player) :: any).value.amount
		expect(amount > 0):toBe(true)
		local before = h:snap(player)
		local results: { any } = {}

		withoutSingleFlight(function()
			h:setYield(true)
			drain({
				coroutine.create(function()
					table.insert(results, h:claim(player))
				end),
				coroutine.create(function()
					table.insert(results, h:claim(player))
				end),
			})
			h:setYield(false)
		end)

		expect(#results):toBe(2)
		local granted = 0
		for _, result in results do
			if result.ok then
				granted += 1
				expectAmount(result.value.amount, amount)
			else
				expect(result):toBeErr(Result.Codes.Insufficient)
			end
		end
		expect(granted):toBe(1)
		expectAmount(h:snap(player).credits - before.credits, amount)
		expectAmount(h:snap(player).lifetime - before.lifetime, amount)
		expect(h:snap(player).earned - before.earned):toBe(1)
	end)

	it("FOUR spam-duplicated claims pay the window EXACTLY ONCE", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local amount = (h:peek(player) :: any).value.amount
		local before = h:snap(player)
		local results: { any } = {}

		withoutSingleFlight(function()
			h:setYield(true)
			local cos: { thread } = {}
			for _ = 1, 4 do
				table.insert(
					cos,
					coroutine.create(function()
						table.insert(results, h:claim(player))
					end)
				)
			end
			drain(cos)
			h:setYield(false)
		end)

		local granted = 0
		for _, result in results do
			if result.ok then
				granted += 1
			end
		end
		expect(granted):toBe(1)
		expectAmount(h:snap(player).credits - before.credits, amount)
		expect(h:snap(player).earned - before.earned):toBe(1)
	end)

	it("the in-memory single-flight, left INSTALLED, also pays exactly once", function()
		-- Belt-and-braces path: the same burst with the service's own reservation in place.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local amount = (h:peek(player) :: any).value.amount
		local before = h:snap(player)
		local results: { any } = {}

		h:setYield(true)
		local cos: { thread } = {}
		for _ = 1, 3 do
			table.insert(
				cos,
				coroutine.create(function()
					table.insert(results, h:claim(player))
				end)
			)
		end
		drain(cos)
		h:setYield(false)

		local granted = 0
		for _, result in results do
			if result.ok then
				granted += 1
			end
		end
		expect(granted):toBe(1)
		expectAmount(h:snap(player).credits - before.credits, amount)
	end)

	it("a PEEK interleaved into a live claim cannot resurrect the pending amount", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local amount = (h:peek(player) :: any).value.amount
		local before = h:snap(player)
		local peeked: any = nil
		local claimResult: any = nil

		h:setYield(true)
		drain({
			coroutine.create(function()
				claimResult = h:claim(player)
			end),
			coroutine.create(function()
				peeked = h:peek(player)
			end),
		})
		h:setYield(false)

		expect(claimResult):toBeOk()
		expect(peeked):toBeOk()
		-- The peek landed while the claim was parked in the store: the window is already spoken for.
		expect((peeked :: any).value.amount):toBe(0)
		expectAmount(h:snap(player).credits - before.credits, amount)
		-- And a claim AFTER the burst still finds nothing.
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expectAmount(h:snap(player).credits - before.credits, amount)
	end)

	it("two DIFFERENT players' interleaved claims each pay their own window", function()
		local h = newServer({
			seed = seedAway({
				{ userId = 1, away = 100 },
				{ userId = 2, away = 200 },
			}),
		})
		local a = h:join(1)
		local b = h:join(2)
		local amountA = (h:peek(a) :: any).value.amount
		local amountB = (h:peek(b) :: any).value.amount
		expect(amountB > amountA):toBe(true)
		local beforeA = h:snap(a)
		local beforeB = h:snap(b)

		h:setYield(true)
		drain({
			coroutine.create(function()
				expect(h:claim(a)):toBeOk()
			end),
			coroutine.create(function()
				expect(h:claim(b)):toBeOk()
			end),
		})
		h:setYield(false)

		expectAmount(h:snap(a).credits - beforeA.credits, amountA)
		expectAmount(h:snap(b).credits - beforeB.credits, amountB)
	end)
end)

-- ── 10. no client time / no client number anywhere ──────────────────────────────────────────────

describe("offline: the payload carries no time, no duration and no amount", function()
	local FORGERIES: { { name: string, payload: any, code: string } } = {
		{ name = "awaySeconds", payload = { awaySeconds = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "seconds", payload = { seconds = 999999 }, code = Result.Codes.BadPayload },
		{ name = "elapsed", payload = { elapsed = 999999 }, code = Result.Codes.BadPayload },
		{ name = "duration", payload = { duration = 999999 }, code = Result.Codes.BadPayload },
		{ name = "lastSeenUnix", payload = { lastSeenUnix = 1 }, code = Result.Codes.BadPayload },
		{ name = "nowUnix", payload = { nowUnix = 2e9 }, code = Result.Codes.BadPayload },
		{ name = "timestamp", payload = { timestamp = 1 }, code = Result.Codes.BadPayload },
		{ name = "clientTime", payload = { clientTime = 1 }, code = Result.Codes.BadPayload },
		{ name = "amount", payload = { amount = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "credits", payload = { credits = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "rate", payload = { rate = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "capacity", payload = { capacity = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "multiplier", payload = { multiplier = 1e9 }, code = Result.Codes.BadPayload },
		{ name = "userId", payload = { userId = 2 }, code = Result.Codes.BadPayload },
		{ name = "a string", payload = "give me credits", code = Result.Codes.BadType },
		{ name = "a number", payload = 99999, code = Result.Codes.BadType },
		{ name = "a boolean", payload = true, code = Result.Codes.BadType },
	}

	for _, forgery in FORGERIES do
		it(`offline.claim REFUSES a payload naming {forgery.name} — and mints nothing`, function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local wire = h:wire()
			local before = h:snap(player)
			local result = wire.invoke(Net.Actions.ClaimOffline, player, forgery.payload)
			expect(result):toBeErr(forgery.code)
			local after = h:snap(player)
			expect(after.credits):toBe(before.credits)
			expect(after.lifetime):toBe(before.lifetime)
			-- and the window is STILL owed — a refused forgery must not burn the grant either
			expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
		end)

		it(`offline.peek REFUSES a payload naming {forgery.name}`, function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local wire = h:wire()
			expect(wire.invoke(Net.Actions.FetchOffline, player, forgery.payload)):toBeErr(
				forgery.code
			)
		end)
	end

	it("a nil payload is the well-formed call and grants the SERVER-derived amount", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire()
		local before = h:snap(player)
		local result = wire.invoke(Net.Actions.ClaimOffline, player, nil)
		expect(result):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("an EMPTY table is accepted and grants the same server-derived amount", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire()
		local before = h:snap(player)
		expect(wire.invoke(Net.Actions.ClaimOffline, player, {})):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("an unrecognised key cannot influence the grant by one credit", function()
		-- Whether the validator refuses or ignores a key it has no opinion about, the invariant the
		-- slice states is the same: every number on this path came from the blob or ctx.clock.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire()
		local before = h:snap(player)
		local result = wire.invoke(Net.Actions.ClaimOffline, player, { bonus = 1e9, x = "y" })
		local delta = h:snap(player).credits - before.credits
		if result.ok then
			expectAmount(delta, BASE_RATE * 300)
		else
			expect(delta):toBe(0)
		end
	end)

	it("offline.peek reports the SERVER window regardless of a forged-looking payload", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire()
		local honest = wire.invoke(Net.Actions.FetchOffline, player, nil)
		expect(honest):toBeOk()
		expectAmount((honest :: any).value.amount, BASE_RATE * 300)
		expect((honest :: any).value.nowUnix):toBe(h.clock:unix())
	end)
end)

-- ── 11. ownership, identity and rate limits ─────────────────────────────────────────────────────

describe("offline: the grant is derived from ctx.player alone", function()
	it("one player's claim cannot touch another player's blob or window", function()
		local h = newServer({
			seed = seedAway({
				{ userId = 1, away = 100 },
				{ userId = 2, away = 5000 },
			}),
		})
		local a = h:join(1)
		local b = h:join(2)
		local victimBefore = deepCopy(h:blob(b))
		local wire = h:wire()
		expect(wire.invoke(Net.Actions.ClaimOffline, a, nil)):toBeOk()
		-- B's blob is byte-identical, and B's window is still fully owed.
		expect(changedPaths(victimBefore, deepCopy(h:blob(b)))):toEqual({})
		expectAmount((h:peek(b) :: any).value.amount, BASE_CAPACITY)
	end)

	it("a payload naming another userId is refused, and that player is untouched", function()
		local h = newServer({
			seed = seedAway({
				{ userId = 1, away = 100 },
				{ userId = 2, away = 5000 },
			}),
		})
		local a = h:join(1)
		local b = h:join(2)
		local victimBefore = deepCopy(h:blob(b))
		local wire = h:wire()
		expect(wire.invoke(Net.Actions.ClaimOffline, a, { userId = 2 })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(changedPaths(victimBefore, deepCopy(h:blob(b)))):toEqual({})
	end)

	it("a player with a NON-NUMERIC UserId is refused with BadType", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		h:join(1)
		local impostor: any = { UserId = "1", Name = "impostor" }
		expect(h:claim(impostor, { playerOverridden = true, player = impostor })):toBeErr(
			Result.Codes.BadType
		)
		expect(h:peek(impostor, { playerOverridden = true, player = impostor })):toBeErr(
			Result.Codes.BadType
		)
	end)

	it("a NIL player is refused, never granted", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		h:join(1)
		expect(h:claim(nil, { playerOverridden = true, player = nil })):toBeErr(
			Result.Codes.BadType
		)
	end)

	it("claiming before the session is loaded returns NoData, and mints nothing", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = Mocks.player(1) -- never loadSession'd
		expect(h:claim(player)):toBeErr(Result.Codes.NoData)
		expect(h:peek(player)):toBeErr(Result.Codes.NoData)
	end)
end)

describe("offline: the spine rate Gate bounds the JoinRetry re-issue burst", function()
	it("offline.claim is rate limited past its declared allowance", function()
		local policy = (OfflineService:claimAction() :: any).rate
		expect(type(policy.maxPerWindow)):toBe("number")
		expect(policy.maxPerWindow >= 1):toBe(true)
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire({ gate = true })
		for index = 1, policy.maxPerWindow do
			local result = wire.invoke(Net.Actions.ClaimOffline, player, nil)
			if index == 1 then
				expect(result):toBeOk()
			else
				expect(result):toBeErr(Result.Codes.Insufficient)
			end
		end
		-- One past the allowance: the GATE refuses, with a code the one-shot guard never returns.
		expect(wire.invoke(Net.Actions.ClaimOffline, player, nil)):toBeErr(Result.Codes.RateLimited)
	end)

	it("offline.peek is rate limited past its own, more generous allowance", function()
		local policy = (OfflineService:peekAction() :: any).rate
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire({ gate = true })
		for _ = 1, policy.maxPerWindow do
			expect(wire.invoke(Net.Actions.FetchOffline, player, nil)):toBeOk()
		end
		expect(wire.invoke(Net.Actions.FetchOffline, player, nil)):toBeErr(Result.Codes.RateLimited)
		-- The bucket refills on the SERVER monotonic clock.
		h.clock:advance(policy.windowSeconds)
		expect(wire.invoke(Net.Actions.FetchOffline, player, nil)):toBeOk()
	end)

	it("a rate-limited claim mints nothing and leaves the window owed", function()
		local policy = (OfflineService:peekAction() :: any).rate
		expect(policy.windowSeconds > 0):toBe(true)
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local wire = h:wire({ gate = true })
		local claimPolicy = (OfflineService:claimAction() :: any).rate
		local before = h:snap(player)
		local blocked = 0
		for _ = 1, claimPolicy.maxPerWindow + 5 do
			local result = wire.invoke(Net.Actions.ClaimOffline, player, nil)
			if not result.ok and (result :: any).code == Result.Codes.RateLimited then
				blocked += 1
			end
		end
		expect(blocked > 0):toBe(true)
		-- Exactly one window was paid across the whole burst.
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("the two offline actions are registered under the contract's names", function()
		local h = newServer()
		expect(h.registered[Net.Actions.ClaimOffline] ~= nil):toBe(true)
		expect(h.registered[Net.Actions.FetchOffline] ~= nil):toBe(true)
		expect(Net.Actions.ClaimOffline):toBe("offline.claim")
		expect(Net.Actions.FetchOffline):toBe("offline.peek")
	end)
end)

-- ── 12. no persisted field of its own (the negative migration case) ─────────────────────────────

describe("offline: this feature persists nothing of its own", function()
	it(
		"a full claim lifecycle adds no new persisted key and does not move schemaVersion",
		function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local beforeKeys: { string } = {}
			for key in h:blob(player) do
				table.insert(beforeKeys, tostring(key))
			end
			table.sort(beforeKeys)
			local version = h:blob(player).schemaVersion

			expect(h:peek(player)):toBeOk()
			expect(h:claim(player)):toBeOk()
			expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)

			local afterKeys: { string } = {}
			for key in h:blob(player) do
				table.insert(afterKeys, tostring(key))
			end
			table.sort(afterKeys)
			expect(afterKeys):toEqual(beforeKeys)
			expect(h:blob(player).schemaVersion):toBe(version)
			expect(h:blob(player).schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		end
	)

	it("the granted Credits survive a save/release/reload round trip", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local granted = h:blob(player).currencies.Credits
		h:leave(player) -- durable release, which also stamps the new lastSeenUnix
		local rejoined = h:join(1)
		expectAmount(h:blob(rejoined).currencies.Credits, granted)
		expectAmount(h:blob(rejoined).stats.lifetimeCredits, granted)
	end)

	it("a re-loaded blob still projects through toView without a new field", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		local view = Types.toView(h:blob(player))
		expectAmount(view.currencies.Credits, h:blob(player).currencies.Credits)
		expect((view :: any).offline):toBe(nil)
		expect((view :: any).pending):toBe(nil)
	end)
end)

-- ── 13. broken seams REFUSE — they never fall through to an uncapped or unrecorded grant ────────

describe("offline: a broken seam refuses loudly rather than minting", function()
	it("NO ctx.salvage: the claim is refused with Internal, and nothing is credited", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:claim(player, { noSalvage = true })):toBeErr(Result.Codes.Internal)
		expect(h:peek(player, { noSalvage = true })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
		-- and the window is untouched: a broken boot must not consume the grant
		expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
	end)

	it("a ctx.salvage with NO capacityFor is refused (an uncapped grant IS the exploit)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 999999 } }) })
		local player = h:join(1)
		local half: any = {}
		function half.rateFor(_self: any, _data: any): number
			return BASE_RATE
		end
		local before = h:snap(player)
		expect(h:claim(player, { salvage = half })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
	end)

	it("a THROWING ctx.salvage is refused, never granted", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local angry: any = {}
		function angry.rateFor(_self: any, _data: any): number
			error("salvage exploded")
		end
		function angry.capacityFor(_self: any, _data: any): number
			return BASE_CAPACITY
		end
		local before = h:snap(player)
		expect(h:claim(player, { salvage = angry })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
	end)

	it(
		"NO ctx.economy: refused with Internal — never a direct write of data.currencies",
		function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local before = deepCopy(h:blob(player))
			expect(h:claim(player, { noEconomy = true })):toBeErr(Result.Codes.Internal)
			-- Nothing moved at all: in particular Credits did not move without lifetimeCredits.
			expect(changedPaths(before, deepCopy(h:blob(player)))):toEqual({})
		end
	)

	it("a REFUSING economy leaves the blob untouched and the window still owed", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local seam = refusingEconomy(Result.Codes.OutOfRange)
		local before = deepCopy(h:blob(player))
		expect(h:claim(player, { economy = seam })):toBeErr(Result.Codes.OutOfRange)
		expect(seam.calls):toBe(1)
		expect(changedPaths(before, deepCopy(h:blob(player)))):toEqual({})
		-- The grant is not lost to a transient refusal.
		expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
	end)

	it(
		"an economy that CREDITS THEN REFUSES cannot leave the credit behind (the mint shape)",
		function()
			-- The exact defect the salvage gate caught, re-aimed at this path: a refused claim that still
			-- committed the balance would mint one window per refusal, with stats.lifetimeCredits unmoved
			-- so nothing downstream could ever see it.
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			local seam = creditThenRefuseEconomy()
			local before = deepCopy(h:blob(player))
			expect(h:claim(player, { economy = seam })):toBeErr(Result.Codes.Internal)
			expect(seam.calls):toBe(1)
			expect(changedPaths(before, deepCopy(h:blob(player)))):toEqual({})
		end
	)

	it("repeated credit-then-refuse claims never accumulate a balance", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local seam = creditThenRefuseEconomy()
		local before = h:snap(player)
		for _ = 1, 5 do
			expect(h:claim(player, { economy = seam })):toBeErr(Result.Codes.Internal)
		end
		expect(h:snap(player).credits):toBe(before.credits)
		expect(h:snap(player).lifetime):toBe(before.lifetime)
		-- and one honest claim afterwards still pays exactly ONE window
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)
end)

-- ── 14. a poisoned upstream reading cannot mint ─────────────────────────────────────────────────

describe("offline: poisoned rate/capacity readings are bounded, never minted", function()
	it("an INFINITE rate pays AT MOST one smelter-full, and never an infinity", function()
		-- The slice bounds this path from above ("an enormous away time cannot mint more than one
		-- smelter-full"); it does not dictate which safe value a poisoned reading collapses to. So the
		-- assertion is the BOUND, on both the reported amount and the credited delta.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local poisoned = salvageSeam(math.huge, BASE_CAPACITY)
		local info = (h:peek(player, { salvage = poisoned }) :: any).value
		expect(info.amount == info.amount):toBe(true) -- not NaN
		expect(info.amount ~= math.huge):toBe(true)
		expect(info.amount >= 0):toBe(true)
		expect(info.amount <= BASE_CAPACITY):toBe(true)
		local before = h:snap(player)
		local claimed = h:claim(player, { salvage = poisoned })
		if not claimed.ok then
			expect(claimed):toBeErr(Result.Codes.Insufficient)
		end
		local delta = h:snap(player).credits - before.credits
		expect(delta == delta):toBe(true)
		expect(delta >= 0):toBe(true)
		expect(delta <= BASE_CAPACITY):toBe(true)
	end)

	it("a NaN rate mints nothing, and never writes NaN into a balance", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local poisoned = salvageSeam(0 / 0, BASE_CAPACITY)
		expect((h:peek(player, { salvage = poisoned }) :: any).value.amount):toBe(0)
		expect(h:claim(player, { salvage = poisoned })):toBeErr(Result.Codes.Insufficient)
		local credits = h:blob(player).currencies.Credits
		expect(credits == credits):toBe(true) -- not NaN
		expect(credits):toBe(0)
	end)

	it("a NEGATIVE rate mints nothing (never a debit dressed as an earn)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local poisoned = salvageSeam(-50, BASE_CAPACITY)
		expect((h:peek(player, { salvage = poisoned }) :: any).value.amount):toBe(0)
		local before = h:snap(player)
		expect(h:claim(player, { salvage = poisoned })):toBeErr(Result.Codes.Insufficient)
		expect(h:snap(player).credits):toBe(before.credits)
	end)

	it("a NaN or negative CAPACITY collapses the grant to 0 rather than to unbounded", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect((h:peek(player, { salvage = salvageSeam(BASE_RATE, 0 / 0) }) :: any).value.amount):toBe(
			0
		)
		expect((h:peek(player, { salvage = salvageSeam(BASE_RATE, -100) }) :: any).value.amount):toBe(
			0
		)
	end)

	it("accrualFor never returns a NaN or negative amount for poisoned inputs", function()
		local cases: { { any } } = {
			{ 0 / 0, 100, 250 },
			{ math.huge, 100, 250 },
			{ -5, 100, 250 },
			{ 2, 0 / 0, 250 },
			{ 2, -100, 250 },
			{ 2, math.huge, 250 },
			{ 2, 100, 0 / 0 },
			{ 2, 100, -250 },
		}
		for _, case in cases do
			local accrual = OfflineService:accrualFor(case[1], case[2], case[3])
			expect(accrual.amount == accrual.amount):toBe(true) -- not NaN
			expect(accrual.amount >= 0):toBe(true)
			expect(accrual.amount ~= math.huge):toBe(true)
			expect(accrual.amount <= math.max(accrual.capacity, 0)):toBe(true)
		end
	end)

	it("a BROKEN CLOCK is refused rather than treated as an away time", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local broken: any = {}
		function broken.unix(_self: any): any
			return 0 / 0
		end
		function broken.mono(_self: any): number
			return 0
		end
		local before = h:snap(player)
		expect(h:claim(player, { clock = broken })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
	end)
end)

-- ── 15. the restore path is bounded by the cap ──────────────────────────────────────────────────

describe("offline: a failed claim restores the window without ever exceeding the cap", function()
	it("a store failure leaves the window claimable, and the retry pays it ONCE", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local expected = math.min(BASE_RATE * 300, BASE_CAPACITY)
		local flaky = failingData(h.data, 1, Result.Codes.Internal)
		local before = h:snap(player)
		expect(h:claim(player, { data = flaky })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
		-- Still owed, unchanged.
		expectAmount((h:peek(player) :: any).value.amount, expected)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, expected)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expectAmount(h:snap(player).credits - before.credits, expected)
	end)

	it("FIVE consecutive store failures still pay exactly ONE window in total", function()
		local away = math.floor(CAP_SECONDS) + 1000 -- a CAPPED window: the restore must re-clamp
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local flaky = failingData(h.data, 5, Result.Codes.Internal)
		local before = h:snap(player)
		for _ = 1, 5 do
			expect(h:claim(player, { data = flaky })):toBeErr(Result.Codes.Internal)
			-- After every failure the restored pending is bounded by the smelter capacity.
			expect((h:peek(player) :: any).value.amount <= BASE_CAPACITY):toBe(true)
		end
		expect(h:claim(player, { data = flaky })):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_CAPACITY)
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expectAmount(h:snap(player).credits - before.credits, BASE_CAPACITY)
	end)

	it("a LockStolen update surfaces the code and does not consume the window", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local dead = failingData(h.data, 1, Result.Codes.LockStolen)
		expect(h:claim(player, { data = dead })):toBeErr(Result.Codes.LockStolen)
		expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
	end)

	it("a THROWING data layer is caught, and the window is left owed", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local exploding: any = {}
		function exploding.update(_self: any, _player: any, _transform: any): any
			error("the store exploded")
		end
		function exploding.get(_self: any, target: any): any
			return h.data:get(target)
		end
		local before = h:snap(player)
		expect(h:claim(player, { data = exploding })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
		expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)
end)

-- ── 16. CLAIM ON JOIN WITHOUT RACING SESSION LOAD ───────────────────────────────────────────────
-- The single highest-risk wire in this game, and the defect that lost a previous game's earnings
-- PERMANENTLY: the away window lives in `timestamps.lastSeenUnix`, which the data layer's autosave
-- REWRITES to now on every flush. If nothing snapshotted the window before that, the earnings are
-- gone and no offline rung can see it.

describe("offline: the away window survives the autosave that erases its base", function()
	it(
		"HEADLINE: window computed at join, autosave re-stamps the base, the claim still pays",
		function()
			local away = 600
			local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
			local player = h:join(1)
			local expected = math.min(BASE_RATE * away, BASE_CAPACITY)

			-- The join hook closes the window the instant the session is loaded.
			local prepared = h:prepare(player)
			expect(prepared):toBeOk()
			expectAmount((h:peek(player) :: any).value.amount, expected)

			-- Now the autosave fires and destroys the persisted base.
			local flush = h.data:autosaveTick()
			expect(flush.flushed):toBe(1)
			expect(h:blob(player).timestamps.lastSeenUnix):toBe(h.clock:unix())

			-- FALSIFICATION OF THE PREMISE: recomputing from the post-autosave blob now reads ~0, so this
			-- case genuinely distinguishes "paid the snapshot" from "recomputed at claim time".
			local recomputed =
				OfflineService:computePending(h.startContext, h:blob(player), h.clock:unix())
			expect(recomputed):toBeOk()
			expect((recomputed :: any).value.amount):toBe(0)

			local before = h:snap(player)
			local claimed = h:claim(player)
			expect(claimed):toBeOk()
			expectAmount((claimed :: any).value.amount, expected)
			expectAmount(h:snap(player).credits - before.credits, expected)
		end
	)

	it("a peek at join also closes the window against a later autosave", function()
		local away = 600
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		local expected = math.min(BASE_RATE * away, BASE_CAPACITY)
		expectAmount((h:peek(player) :: any).value.amount, expected)
		h.data:autosaveTick()
		expectAmount((h:peek(player) :: any).value.amount, expected)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, expected)
	end)

	it("TWO autosaves between the join hook and the claim still pay the full window", function()
		local away = 600
		local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
		local player = h:join(1)
		expect(h:prepare(player)):toBeOk()
		h.data:autosaveTick()
		h.clock:advance(120)
		h.data:autosaveTick()
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(
			h:snap(player).credits - before.credits,
			math.min(BASE_RATE * away, BASE_CAPACITY)
		)
	end)

	it("the join hook waits for the session and refuses NoData rather than computing 0", function()
		-- A window computed before loadSession resolves reads Err(NoData) and remembers NOTHING — so
		-- the untouched window is still there for the client's JoinRetry re-issue. The alternative
		-- (remembering a 0) is the permanent-loss defect through the server door.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 600 } }) })
		local player = Mocks.player(1) -- not loaded yet
		withLoadWait(2, function()
			expect(h:prepare(player)):toBeErr(Result.Codes.NoData)
		end)
		-- Now the session loads: the window is intact and pays in full.
		expect(h.data:loadSession(player)):toBeOk()
		local expected = math.min(BASE_RATE * 600, BASE_CAPACITY)
		expectAmount((h:peek(player) :: any).value.amount, expected)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, expected)
	end)

	it(
		"the join hook computes the window exactly once — a second call does not re-open it",
		function()
			local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
			local player = h:join(1)
			expect(h:prepare(player)):toBeOk()
			expect(h:claim(player)):toBeOk()
			local afterClaim = h:snap(player)
			-- The hook running again (a duplicate PlayerAdded, a re-issued join) must not re-mint.
			expect(h:prepare(player)):toBeOk()
			expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
			expect(h:snap(player).credits):toBe(afterClaim.credits)
		end
	)

	it(
		"the window is priced at SESSION-LOAD state — upgrades bought afterwards do not re-price it",
		function()
			-- "The computation, AT SESSION LOAD, from server state only." Once the join hook has closed
			-- the window, buying a bigger fleet must not retroactively raise what the absence earned;
			-- otherwise the cheapest way to farm an away window is to bank upgrades and claim last.
			local away = 100
			local h = newServer({ seed = seedAway({ { userId = 1, away = away } }) })
			local player = h:join(1)
			expect(h:prepare(player)):toBeOk()
			local atLoad = (h:peek(player) :: any).value.amount
			expectAmount(atLoad, BASE_RATE * away)

			-- Now the fleet and the smelter both get much bigger, mid-session.
			expect(h.data:update(player, function(d: any): any
				d.upgrades[SalvageService.UPGRADE_KEYS.drones] = 40
				d.upgrades[SalvageService.UPGRADE_KEYS.smelter] = 10
				return d
			end)):toBeOk()
			expect(h:rate(player) > BASE_RATE):toBe(true) -- vacuity guard: the upgrade really did land

			expectAmount((h:peek(player) :: any).value.amount, atLoad)
			local before = h:snap(player)
			expect(h:claim(player)):toBeOk()
			expectAmount(h:snap(player).credits - before.credits, atLoad)
		end
	)

	it("a claim refused for NoData does not strand the in-flight reservation", function()
		-- The reservation is per-server memory. A path that returned without releasing it would lock
		-- this player out of their own away window for the LIFE of the server — the earnings are gone
		-- and nothing logs it.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = Mocks.player(1)
		for _ = 1, 3 do
			expect(h:claim(player)):toBeErr(Result.Codes.NoData)
		end
		expect(h.data:loadSession(player)):toBeOk()
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("a data layer that reports success WITHOUT running the transform loses no window", function()
		-- The silent-liar store: update returns Ok but the transform never ran, so nothing was
		-- credited. Reporting success here would consume the window and pay nothing.
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local liar: any = {}
		function liar.update(_self: any, _player: any, _transform: any): any
			return Result.ok({})
		end
		function liar.get(_self: any, target: any): any
			return h.data:get(target)
		end
		local before = h:snap(player)
		expect(h:claim(player, { data = liar })):toBeErr(Result.Codes.Internal)
		expect(h:snap(player).credits):toBe(before.credits)
		expectAmount((h:peek(player) :: any).value.amount, BASE_RATE * 300)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("an eager claim BEFORE the join hook is not double-paid when the hook completes", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk() -- the client got there first
		expect(h:prepare(player)):toBeOk() -- the hook lands afterwards
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)
end)

-- ── 17. the post-claim view push never undoes a committed grant ─────────────────────────────────

describe("offline: the presentation push is derived, and can never fail the claim", function()
	it("a granted claim pushes the refreshed client view", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:claim(player)):toBeOk()
		expect(#h.pushes >= 1):toBe(true)
		local push = h.pushes[#h.pushes]
		expect(push.channel):toBe("data")
		expectAmount(push.payload.currencies.Credits, h:blob(player).currencies.Credits)
	end)

	it("a THROWING fireClient does not turn a committed grant into Err(Internal)", function()
		-- The exact defect docs/LEARNINGS.md records from collect-sim: an unguarded post-write push
		-- turned a committed Sell into an error, and 352 Lune tests called it fine.
		local h = newServer({
			seed = seedAway({ { userId = 1, away = 300 } }),
			fireClientThrows = true,
		})
		local player = h:join(1)
		local before = h:snap(player)
		local claimed = h:claim(player)
		expect(claimed):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
		-- and the window is still one-shot
		expect(h:claim(player)):toBeErr(Result.Codes.Insufficient)
	end)
end)

-- ── 18. the memory prune must never destroy a live player's owed window ─────────────────────────

describe("offline: pruning per-server memory cannot lose an owed window", function()
	it("a prune with a live roster keeps the present player's window claimable", function()
		local h = newServer({
			seed = seedAway({
				{ userId = 1, away = 300 },
				{ userId = 2, away = 300 },
			}),
		})
		local a = h:join(1)
		local b = h:join(2)
		expect(h:peek(a)):toBeOk()
		expect(h:peek(b)):toBeOk()
		withRoster({ a }, function()
			OfflineService:prune()
		end)
		local before = h:snap(a)
		expect(h:claim(a)):toBeOk()
		expectAmount(h:snap(a).credits - before.credits, BASE_RATE * 300)
	end)

	it("an EMPTY roster prunes nothing (unreadable != nobody is here)", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:peek(player)):toBeOk()
		withRoster({}, function()
			expect(OfflineService:prune()):toBe(0)
		end)
		local before = h:snap(player)
		expect(h:claim(player)):toBeOk()
		expectAmount(h:snap(player).credits - before.credits, BASE_RATE * 300)
	end)

	it("a pruned-away player who rejoins is paid their NEW window, not the old one", function()
		local h = newServer({ seed = seedAway({ { userId = 1, away = 300 } }) })
		local player = h:join(1)
		expect(h:peek(player)):toBeOk()
		h:leave(player)
		withRoster({ Mocks.player(99) }, function()
			OfflineService:prune()
		end)
		h.clock:advance(50)
		local rejoined = h:join(1)
		expectAmount((h:peek(rejoined) :: any).value.amount, BASE_RATE * 50)
	end)
end)
