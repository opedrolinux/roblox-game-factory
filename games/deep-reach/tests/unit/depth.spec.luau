--!strict
-- games/deep-reach/tests/unit/depth.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/depth.md, NOT from
--  DepthService's control flow. The implementation was read ONLY to learn its observable interface
--  (the two action factories, descend/fetch, the ctx.depth seam methods and the DepthInfo field
--  names). Every EXPECTATION below is derived from the slice, and every economic number — each
--  tier's Credits cost, its hull requirement, its value multiplier, its world Y, the restock
--  multiplier, the rate policies — is DISCOVERED THROUGH THE PUBLIC READ SURFACE (`depth.fetch`'s
--  reply and the seam) rather than copied out of the module. A build that re-tunes the tier curve
--  stays green here; a build that stops enforcing the pressure gate, lets a rung be skipped, stops
--  moving the running salvage rate, double-spends, or lets the restock be steered by a client goes
--  RED.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   1. THE LADDER — "5 trench tiers gated by Credits **and** hull rating; the dome visibly descends;
--      per-tier salvage value", plus "**VIP trench** (an exclusive depth tier)" gated on
--      `data.flags["gamepass.vipTrench"]`.
--   2. THE PRESSURE GATE — "each depth tier requires a minimum hull rating, so depth cannot be
--      bought purely with income — it needs the upgrade *and* the Credits. (This is the one rule
--      that stops a rich player skipping the middle game.)" And: "IT MUST NOT BE BYPASSABLE BY
--      RE-ORDERING PURCHASES. `depth.descend` validates ALL of the following against the SAME
--      lock-held snapshot in which it debits: (a) the previous tier is already unlocked — tiers are
--      strictly sequential, so no tier can be skipped by any purchase order; (b) `upgrades.hull >=
--      HULL_MIN[nextTier]` -> Err(PrereqUnmet) if not; (c) enough Credits -> Err(Insufficient) if
--      not; and for the VIP trench (d) flags["gamepass.vipTrench"] -> Err(PrereqUnmet) if absent."
--   3. THE SEAM SALVAGE CORE READS — "`ctx.depth:valueMultiplier(data, nowUnix) -> number` — the
--      per-tier salvage multiplier for `upgrades.depth`, MULTIPLIED by today's restock bonus when
--      the player's current tier is today's restock tier. ... landing this seam is what must produce
--      a measurable delta on the running rate."
--   4. THE RESTOCK ROTATION — "a day index derived from ctx.clock:unix() ONLY, deterministically
--      selecting one trench tier per server-day, resetting each day. No client input, no os.time, no
--      client-supplied day." AMENDMENT A7: "the wreck ... resets each day" must be provable by "the
--      wreck's presence/position CHANGING between two server-days — not by an integer flipping".
--   5. THE READ SURFACE — "`depth.fetch`: current tier, the next tier's Credits + hull requirement,
--      and today's restock tier (for the HUD badge)."
--   6. AMENDMENT A1 — "You PROVIDE `ctx.depth:tierYFor(data) -> number` (the world Y for the
--      player's persisted tier), which PlotService reads at claim time so a returning player's dome
--      is placed at their persisted tier rather than at Depth 1." Plus the art posture: "trench
--      tiers = stacked Part shells at descending Y."
--   7. EMITS — "debits via ctx.economy:spend (emits currency_spent), emits `progression`, and emits
--      `loop_completed` on the FIRST successful descend of a session."
--   NOT THIS SLICE (so NOT asserted here): selling hull rating (Structures writes upgrades.hull —
--      only READ here), the income tick / rate function itself (Salvage), granting the VIP flag
--      (Monetization), resetting the tier on prestige (Resurface).
--   Plus games/deep-reach/CLAUDE.md §3 (validate type + range + ownership + rate on EVERY inbound
--   client request) and §4 (concurrency-safe economy: no double-spend, no dupes).
--
-- WHY EVERY VALUE CASE MEASURES A RUNNING NUMBER. The written-never-read pattern behind 66 of
-- collect-sim's confirmed defects is: a purchase increments a persisted field, the test asserts the
-- field moved, and nothing ever reads it. So no case below is satisfied by `upgrades.depth`
-- changing. The per-tier value cases take a reading through `ctx.salvage:rateFor` — the SAME derived
-- rate the income tick runs on — before and after a REAL descend, and compare the DELTA.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The double-spend this feature is one mistake away from:
-- read the tier (and therefore the price and the hull minimum) OUTSIDE the transform, yield in
-- ctx.data:update, then debit and write. Two descends in the same frame both price tier 2 and the
-- player either pays twice for one rung or lands two rungs up for one price. SEQUENTIAL CALLS
-- CANNOT TELL THAT IMPLEMENTATION FROM A CORRECT ONE, because nothing ever interleaves. So the race
-- cases drive the economy_race.spec idiom: a MockStore with `yieldOnUpdate` (a forced yield INSIDE
-- the update critical section) plus a round-robin coroutine driver, an ENTER/EXIT log that proves a
-- duplicate genuinely ran to completion while the first request was still in flight, and a
-- FALSIFICATION counter-case (a naive price-outside-the-lock descend driven at the same yield point)
-- that DOES pay twice for one rung.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local DepthService = require("../../src/server/services/depth/DepthService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local StructuresShopService = require("../../src/server/services/structures/StructuresShopService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A fixed server instant. Chosen to sit strictly INSIDE a UTC day (not on a boundary) so the
-- day-rollover cases have to cross the boundary deliberately rather than by accident.
local START_UNIX = 1_700_000_000
-- The length of a server-day. This is not an implementation constant: "resets each day" and "one
-- trench tier per server-day" are the spec's words, and a day is 86400 seconds of server time.
local DAY_SECONDS = 86400

-- The canonical persisted keys, straight from the slice. Declared here rather than read off the
-- module on purpose: a build that persisted the tier under some other key would still be
-- self-consistent, and every test that read the key back off the module would stay green while the
-- contract (and Resurface, which writes `upgrades.depth` back to 1) broke.
local DEPTH_KEY = "depth"
local HULL_KEY = "hull"
local VIP_FLAG = "gamepass.vipTrench"
local CREDITS = "Credits"

-- ── small assertion helpers ─────────────────────────────────────────────────────────────────────

local function expectTrue(condition: boolean, why: string): ()
	if not condition then
		error(why, 0)
	end
end

local function expectFinite(value: any, why: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error(`{why}: expected a finite number, got {tostring(value)}`, 0)
	end
end

-- Relative-tolerance comparison: multipliers compose as products of tuned steps, so exact binary
-- equality is not available for composed readings — but "this descend reached that magnitude" is.
local function expectClose(actual: number, expected: number, why: string): ()
	local tolerance = 1e-9 * math.max(1, math.abs(actual), math.abs(expected))
	if math.abs(actual - expected) > tolerance then
		error(`{why}: got {actual}, want {expected}`, 0)
	end
end

-- The restock factor a player's CURRENT tier is carrying right now, so a multiplier assertion can be
-- written without knowing which server-day the harness happens to be standing on.
local function restockFactorFor(h: any, player: any, tier: number): number
	local info = h:info(player)
	return if info.restockTier == tier then info.restockMultiplier else 1
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

-- The PERSISTED tier, read raw off the blob (never through the module's own reader), so a build that
-- kept the tier somewhere else entirely cannot satisfy these assertions.
local function persistedTier(blob: any): any
	if type(blob) ~= "table" or type(blob.upgrades) ~= "table" then
		return nil
	end
	return blob.upgrades[DEPTH_KEY]
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
			error("depth race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`depth race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- ── the harness ─────────────────────────────────────────────────────────────────────────────────

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, the real SalvageService Started (so `ctx.salvage:rateFor` is the SAME derived
-- rate the income tick runs on — the observable the "per-tier salvage value" guarantee is graded
-- against), and DepthService Started against a recording `net`.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	-- MockStore reads `yieldOnUpdate` off this LIVE table on every update, so the forced yield is
	-- armed only for the racing part of a case: it parks the CALLING coroutine, and a spec's setup
	-- writes run on the main thread, which nothing would resume.
	local storeOptions: any = { clock = clock, config = Config, yieldOnUpdate = false }
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
	}
	SalvageService:Start(startContext) -- installs startContext.salvage
	StructuresShopService:Start(startContext) -- the shared-balance race partner
	DepthService:Start(startContext) -- installs startContext.depth, registers both actions

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		salvage = startContext.salvage,
		seam = startContext.depth,
		registered = registered,
		pushes = pushes,
		startContext = startContext,
		storeOptions = storeOptions,
	}

	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	-- The ActionContext a direct descend/fetch call receives. `overrides` swaps one seam without
	-- rebuilding the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.noData == true then nil else (if o.data ~= nil then o.data else self.data),
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			salvage = self.salvage,
			depth = self.seam,
			analytics = if o.noAnalytics == true
				then nil
				else (if o.analytics ~= nil then o.analytics else self.analytics),
		}
	end

	function h.join(self: any, userId: number): any
		local player = Mocks.player(userId)
		expect(self.data:loadSession(player)):toBeOk()
		return player
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

	function h.setTier(self: any, player: any, tier: number): ()
		self:write(player, function(d: any): ()
			d.upgrades[DEPTH_KEY] = tier
		end)
	end

	function h.setHull(self: any, player: any, level: number): ()
		self:write(player, function(d: any): ()
			d.upgrades[HULL_KEY] = level
		end)
	end

	function h.setFlag(self: any, player: any, key: string, value: boolean): ()
		self:write(player, function(d: any): ()
			d.flags[key] = value
		end)
	end

	function h.fund(self: any, player: any, credits: number): ()
		self:write(player, function(d: any): ()
			d.currencies[CREDITS] = credits
		end)
	end

	function h.credits(self: any, player: any): number
		return self:blob(player).currencies[CREDITS]
	end

	function h.descend(self: any, player: any, overrides: any?): any
		return DepthService:descend(self:ctx(player, overrides))
	end

	function h.fetch(self: any, player: any, overrides: any?): any
		return DepthService:fetch(self:ctx(player, overrides))
	end

	-- The whole server-derived read surface, exactly as the HUD receives it.
	function h.info(self: any, player: any, overrides: any?): any
		local got = self:fetch(player, overrides)
		expect(got):toBeOk()
		return (got :: any).value
	end

	-- THE RUNNING INCOME RATE — read through the seam the income tick and salvage.fetch read, with
	-- the depth seam passed explicitly so the reading cannot come from a stale captured context.
	function h.rate(self: any, player: any, atUnix: number?): number
		return self.salvage:rateFor(self:blob(player), atUnix or self.clock:unix(), self.seam)
	end

	function h.multiplier(self: any, player: any, atUnix: number?): number
		return self.seam:valueMultiplier(self:blob(player), atUnix or self.clock:unix())
	end

	function h.eventCount(self: any, name: string): number
		return #self.analytics:eventsOfType(name)
	end

	function h.lastEvent(self: any, name: string): any
		local events = self.analytics:eventsOfType(name)
		return events[#events]
	end

	-- The total Credits this server has seen debited, summed off the analytics ledger. Independent of
	-- any balance arithmetic the feature does, so a debit that never emitted (or emitted twice) is
	-- visible as a mismatch against the balance delta.
	function h.spentTotal(self: any): number
		local total = 0
		for _, event in self.analytics:eventsOfType("currency_spent") do
			if event.payload.currency == CREDITS then
				total += event.payload.amount
			end
		end
		return total
	end

	-- Every number an economy case compares before and after.
	function h.snap(self: any, player: any): any
		local blob = self:blob(player)
		return {
			credits = blob.currencies[CREDITS],
			pearls = blob.currencies.Pearls,
			lifetime = blob.stats.lifetimeCredits,
			tier = persistedTier(blob),
			rate = self:rate(player),
			spent = self:eventCount("currency_spent"),
			earned = self:eventCount("currency_earned"),
			progression = self:eventCount("progression"),
			loop = self:eventCount("loop_completed"),
		}
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net, with the two depth actions
	-- registered from the service's own factories. `gate = true` opts INTO the spine rate Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local harness = Mocks.net({
			clock = self.clock,
			data = self.data,
			economy = self.economy,
			salvage = self.salvage,
			depth = self.seam,
			analytics = self.analytics,
			gate = if w.gate == true then Mocks.gate(self.clock) else false,
		})
		harness.register(DepthService:descendAction())
		harness.register(DepthService:fetchAction())
		return harness
	end

	return h
end

-- ── the ladder, DISCOVERED through depth.fetch ──────────────────────────────────────────────────
-- Nothing below copies a cost, a hull minimum, a multiplier or a Y out of the module. Each tier's
-- requirements are read off the HUD reply while the player stands one rung above the bottom of them
-- — which is also, deliberately, the exact surface the requirement panel renders, so a build whose
-- advertised numbers disagreed with what the gate enforces fails the §7 cases below.

-- The hull LEVEL that first certifies `rating`, probed through the read surface.
local function hullLevelForRating(h: any, probe: any, rating: number): number
	for level = 0, 128 do
		h:setHull(probe, level)
		if h:info(probe).hullRating >= rating then
			return level
		end
	end
	error(`no hull level within 0..128 reaches rating {rating}`, 0)
end

local ladderCache: any = nil
local function ladder(): any
	if ladderCache ~= nil then
		return ladderCache
	end
	local h = newServer()
	local probe = h:join(90001)
	local base = h:info(probe)
	local maxTier = base.maxTier
	expectTrue(
		type(maxTier) == "number" and maxTier >= 2,
		`depth.fetch reports maxTier={tostring(maxTier)}; the slice describes a ladder of five tiers `
			.. `plus the VIP trench`
	)

	local rows: { any } = {}
	for k = 1, maxTier do
		h:setTier(probe, k)
		local info = h:info(probe)
		rows[k] = {
			label = info.label,
			y = info.y,
			mult = info.tierValueMultiplier,
			atMax = info.atMaxTier,
			nextCost = info.nextCost,
			nextHull = info.nextHullRequired,
			nextVip = info.nextRequiresVip,
		}
	end

	local tiers: { any } = {}
	for k = 1, maxTier do
		local previous = rows[k - 1]
		tiers[k] = {
			index = k,
			label = rows[k].label,
			y = rows[k].y,
			mult = rows[k].mult,
			cost = if previous ~= nil then previous.nextCost else 0,
			hullRequired = if previous ~= nil then previous.nextHull else 0,
			requiresVip = if previous ~= nil then previous.nextVip else false,
			hullLevel = 0,
		}
	end

	h:setTier(probe, 1)
	for k = 2, maxTier do
		tiers[k].hullLevel = hullLevelForRating(h, probe, tiers[k].hullRequired)
	end
	h:setHull(probe, 0)

	ladderCache = {
		maxTier = maxTier,
		tiers = tiers,
		restockMultiplier = base.restockMultiplier,
		-- The VIP trench is the flag-gated rung; every rung below it is a plain trench tier.
		vipTier = (function(): number?
			for k = 2, maxTier do
				if tiers[k].requiresVip == true then
					return k
				end
			end
			return nil
		end)(),
	}
	return ladderCache
end

-- The exact Credits a player must part with to walk from tier `from` to tier `to`.
local function costBetween(from: number, to: number): number
	local total = 0
	for k = from + 1, to do
		total += ladder().tiers[k].cost
	end
	return total
end

-- Stand a player at `tier` with exactly the Credits and hull the ladder says the NEXT rung demands
-- (and the VIP flag when that rung needs one). The canonical "everything is met" starting state.
local function armFor(h: any, player: any, tier: number, extraCredits: number?): any
	local next = ladder().tiers[tier + 1]
	h:setTier(player, tier)
	h:setHull(player, next.hullLevel)
	h:fund(player, next.cost + (extraCredits or 0))
	if next.requiresVip == true then
		h:setFlag(player, VIP_FLAG, true)
	end
	return next
end

-- ── 1. the wire surface + the seam the rest of the game reads ───────────────────────────────────

describe("depth: the two contract actions and the ctx.depth seam", function()
	it("Start registers exactly the two action names the contract pinned", function()
		local h = newServer()
		expectTrue(
			h.registered[Net.Actions.Descend] ~= nil,
			`the depth service registered no "{Net.Actions.Descend}" action`
		)
		expectTrue(
			h.registered[Net.Actions.FetchDepth] ~= nil,
			`the depth service registered no "{Net.Actions.FetchDepth}" action`
		)
		-- Both declare a rate policy: CLAUDE.md §3 requires rate on EVERY inbound client request.
		for _, name in { Net.Actions.Descend, Net.Actions.FetchDepth } do
			local policy = h.registered[name].rate
			expectTrue(type(policy) == "table", `action "{name}" declares no rate policy`)
			expectTrue(
				type(policy.maxPerWindow) == "number" and policy.maxPerWindow > 0,
				`action "{name}" declares a degenerate maxPerWindow`
			)
			expectTrue(
				type(policy.windowSeconds) == "number" and policy.windowSeconds > 0,
				`action "{name}" declares a degenerate windowSeconds`
			)
		end
	end)

	it(
		"Start installs ctx.depth carrying valueMultiplier and tierYFor (the seam two other features already read)",
		function()
			local h = newServer()
			expectTrue(h.seam ~= nil, "Start did not install context.depth")
			expectTrue(
				type(h.seam.valueMultiplier) == "function",
				"ctx.depth:valueMultiplier is missing — Salvage core reads it for the per-tier value"
			)
			expectTrue(
				type(h.seam.tierYFor) == "function",
				"ctx.depth:tierYFor is missing — PlotService reads it (AMENDMENT A1) to place a returning "
					.. "player's dome at their persisted tier"
			)
		end
	)

	it("the ladder is five trench tiers plus one flag-gated VIP trench", function()
		local l = ladder()
		expect(l.maxTier):toBe(6)
		expectTrue(l.vipTier ~= nil, "no rung on the ladder is gated on a gamepass flag")
		expect(l.vipTier):toBe(l.maxTier)
		-- Every rung BELOW the VIP trench is a plain trench tier: the pass buys ACCESS to the bottom
		-- rung, never a skipped one.
		for k = 2, l.maxTier - 1 do
			expect(l.tiers[k].requiresVip):toBe(false)
		end
	end)
end)

-- ── 2. per-tier salvage value: a DELTA ON THE RUNNING RATE, never a persisted field ─────────────

describe("depth: descending multiplies salvage value (measured on the running rate)", function()
	it("tier 1 is the identity — a fresh blob's multiplier is exactly 1", function()
		local h = newServer()
		local player = h:join(1)
		-- Deliberately at a time when tier 1 is NOT today's restock tier, so this reads the ladder's
		-- own identity rather than a bonus.
		local l = ladder()
		local at = START_UNIX
		for _ = 1, l.maxTier + 2 do
			if h:info(player, { clock = h.clock }).restockTier ~= 1 then
				break
			end
			at += DAY_SECONDS
			h.clock:advance(DAY_SECONDS)
		end
		expectTrue(
			h:info(player).restockTier ~= 1,
			"could not find a day whose restock tier is not 1"
		)
		expectClose(h:multiplier(player), 1, "a fresh blob's depth multiplier")
		expect(persistedTier(h:blob(player))):toBe(nil)
	end)

	it("the multiplier is strictly increasing down the ladder (deeper is richer)", function()
		local h = newServer()
		local player = h:join(1)
		local l = ladder()
		for k = 2, l.maxTier do
			expectTrue(
				l.tiers[k].mult > l.tiers[k - 1].mult,
				`tier {k} ({l.tiers[k].label}) multiplies salvage by {l.tiers[k].mult}, which is not `
					.. `richer than tier {k - 1}'s {l.tiers[k - 1].mult} — descending must pay`
			)
		end
		-- And the seam agrees with what the HUD advertised, for every rung.
		for k = 1, l.maxTier do
			h:setTier(player, k)
			local info = h:info(player)
			expectClose(info.tierValueMultiplier, l.tiers[k].mult, `tier {k} multiplier via fetch`)
		end
	end)

	it(
		"A REAL DESCEND MOVES THE RUNNING INCOME RATE by exactly the tier's multiplier ratio",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			armFor(h, player, 1)
			local multiplierBefore = h:multiplier(player)
			local rateBefore = h:rate(player)
			expectTrue(
				rateBefore > 0,
				"the base salvage rate is 0, so no multiplier delta is observable"
			)

			local result = h:descend(player)
			expect(result):toBeOk()

			local multiplierAfter = h:multiplier(player)
			local rateAfter = h:rate(player)
			expectTrue(
				rateAfter > rateBefore,
				`descending to {l.tiers[2].label} did not raise the running income rate `
					.. `({rateBefore} -> {rateAfter}) — the tier shipped inert`
			)
			-- The delta is not an arbitrary bump: the running rate moved by EXACTLY the ratio of the
			-- depth multipliers, so nothing else in the rate function drifted under the descend.
			expectClose(
				rateAfter / rateBefore,
				multiplierAfter / multiplierBefore,
				"the running-rate ratio across a descend"
			)
		end
	)

	it(
		"EVERY rung of the ladder measurably raises the running rate over the rung above it",
		function()
			local h = newServer()
			local l = ladder()
			local player = h:join(1)
			-- One tier carries today's rich wreck, so the raw rates are not comparable across rungs:
			-- the restocked tier is doubled. Divide that day-fact back out and what is left is the
			-- LADDER, which is what "descending multiplies salvage value" is a claim about.
			local at = h.clock:unix()
			local restockTier = h:info(player).restockTier
			local bonus = h:info(player).restockMultiplier
			local previous: number? = nil
			for k = 1, l.maxTier do
				h:setTier(player, k)
				local raw = h:rate(player, at)
				expectFinite(raw, `the running rate at tier {k}`)
				local rate = raw / (if k == restockTier then bonus else 1)
				if previous ~= nil then
					expectTrue(
						rate > previous :: number,
						`tier {k} ({l.tiers[k].label}) does not out-earn tier {k - 1}: {previous} -> {rate}`
					)
				end
				previous = rate
			end
		end
	)

	it(
		"the multiplier is never 0, negative or NaN for ANY persisted value (Salvage multiplies the whole economy by it)",
		function()
			local h = newServer()
			local player = h:join(1)
			local at = h.clock:unix()
			for _, garbage in { 0, -1, -999, 1e308, math.huge, -math.huge, 0 / 0, "6", true, {} } do
				h:write(player, function(d: any): ()
					d.upgrades[DEPTH_KEY] = garbage
				end)
				local m = h:multiplier(player, at)
				expectFinite(m, `the multiplier for a persisted depth of {tostring(garbage)}`)
				expectTrue(
					m > 0,
					`a persisted depth of {tostring(garbage)} produced a multiplier of {m} — that zeroes `
						.. `(or reverses) the whole game's income`
				)
				local y = h.seam:tierYFor(h:blob(player))
				expectFinite(y, `tierYFor for a persisted depth of {tostring(garbage)}`)
			end
		end
	)

	-- [REGRESSION — dropped gate findings F2/F4] A persisted `upgrades.depth` is DATA, not a fact:
	-- a rolled-back record, a botched migration or a future writer can put an out-of-range integer
	-- there. The read path (the seam Salvage multiplies by, the Y PlotService places at, the HUD
	-- reply) never re-checks `requiresFlag` — that clause lives only inside the descend transform —
	-- so whatever tier an out-of-range value resolves to is handed out with NO flag check at all.
	-- The direction of that resolution is therefore a monetization boundary: degrading DOWN gives a
	-- corrupted record the free rung it started on, degrading UP hands it the paywalled trench's
	-- income multiplier and world position for free. The two garbage classes must also agree: a
	-- build where `math.huge` reads as tier 1 and `1e308` reads as the VIP trench is deciding the
	-- paywall on the difference between two unusable numbers.
	it(
		"an out-of-range persisted depth degrades DOWN — never UP into the flag-gated VIP trench",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			expectTrue(l.vipTier ~= nil, "no rung on the ladder is gated on a gamepass flag")
			local vip = l.vipTier :: number
			local at = h.clock:unix()

			-- The reference reading: an infinity is not a tier, and every build already degrades it.
			-- Every other unusable value has to land in the same place.
			h:write(player, function(d: any): ()
				d.upgrades[DEPTH_KEY] = math.huge
			end)
			local reference = h:info(player).tier
			expectTrue(
				l.tiers[reference].requiresVip ~= true,
				`an infinite persisted depth already resolves to the flag-gated tier {reference}`
			)

			for _, garbage in { l.maxTier + 1, 7, 999, 2 ^ 40, 1e308 } do
				h:write(player, function(d: any): ()
					d.upgrades[DEPTH_KEY] = garbage
					d.flags[VIP_FLAG] = nil
				end)
				local info = h:info(player)
				expect(info.vipUnlocked):toBe(false)
				expectTrue(
					l.tiers[info.tier].requiresVip ~= true,
					`a persisted depth of {tostring(garbage)} resolved to tier {info.tier} `
						.. `({info.label}), which is gated on "{VIP_FLAG}" — and this blob carries no such `
						.. `flag. An out-of-range record must never self-upgrade into the paywall`
				)
				expect(info.tier):toBe(reference)
				expectTrue(
					h:multiplier(player, at) < l.tiers[vip].mult,
					`a persisted depth of {tostring(garbage)} pays the paywalled trench's salvage `
						.. `multiplier ({h:multiplier(player, at)}) with the flag absent`
				)
				expectTrue(
					h.seam:tierYFor(h:blob(player)) > l.tiers[vip].y,
					`a persisted depth of {tostring(garbage)} places the dome at the paywalled trench's `
						.. `world Y with the flag absent`
				)
			end
		end
	)
end)

-- ── 3. THE PRESSURE GATE ────────────────────────────────────────────────────────────────────────

describe(
	"depth: the pressure gate holds (hull AND Credits, in the same guarded transform)",
	function()
		it(
			"Credits alone below the hull minimum -> Err(PrereqUnmet), and NOTHING is debited",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				local target = l.tiers[2]
				h:setTier(player, 1)
				h:setHull(player, math.max(0, target.hullLevel - 1))
				h:fund(player, target.cost * 1000) -- rich, and it must not help
				local before = h:snap(player)

				local result = h:descend(player)
				expect(result):toBeErr(Result.Codes.PrereqUnmet)

				local after = h:snap(player)
				expect(after.credits):toBe(before.credits)
				expect(after.tier):toBe(before.tier)
				expect(after.spent):toBe(before.spent)
				expect(after.progression):toBe(before.progression)
				expectClose(
					after.rate,
					before.rate,
					"a refused descend must not move the income rate"
				)
			end
		)

		it("a hull-too-low refusal is NOT the same code as a cannot-afford refusal", function()
			local h = newServer()
			local l = ladder()
			local target = l.tiers[2]

			local poorHull = h:join(1)
			h:setTier(poorHull, 1)
			h:setHull(poorHull, math.max(0, target.hullLevel - 1))
			h:fund(poorHull, target.cost)
			expect(h:descend(poorHull)):toBeErr(Result.Codes.PrereqUnmet)

			local poorPurse = h:join(2)
			h:setTier(poorPurse, 1)
			h:setHull(poorPurse, target.hullLevel)
			h:fund(poorPurse, math.max(0, target.cost - 1))
			expect(h:descend(poorPurse)):toBeErr(Result.Codes.Insufficient)
		end)

		it(
			"hull met and Credits met -> the rung is granted and EXACTLY the advertised cost is debited",
			function()
				local h = newServer()
				local player = h:join(1)
				local target = armFor(h, player, 1, 77)
				local before = h:snap(player)

				local result = h:descend(player)
				expect(result):toBeOk()
				local info = (result :: any).value
				expect(info.tier):toBe(2)
				expect(info.previousTier):toBe(1)
				expect(info.cost):toBe(target.cost)

				local after = h:snap(player)
				expect(after.credits):toBe(before.credits - target.cost)
				expect(after.tier):toBe(2)
				-- A SPEND never touches the lifetime total (the contract's earn/spend rule).
				expect(after.lifetime):toBe(before.lifetime)
				expect(after.earned):toBe(before.earned)
				expect(after.spent):toBe(before.spent + 1)
			end
		)

		it(
			"THE BOUNDARY: one hull level short refuses, exactly the required level admits, for EVERY rung",
			function()
				local l = ladder()
				for k = 2, l.maxTier do
					local target = l.tiers[k]
					local h = newServer()

					local short = h:join(1)
					h:setTier(short, k - 1)
					h:setHull(short, math.max(0, target.hullLevel - 1))
					h:fund(short, target.cost * 10)
					if target.requiresVip == true then
						h:setFlag(short, VIP_FLAG, true)
					end
					if target.hullLevel > 0 then
						expect(h:descend(short)):toBeErr(Result.Codes.PrereqUnmet)
					end

					local exact = h:join(2)
					h:setTier(exact, k - 1)
					h:setHull(exact, target.hullLevel)
					h:fund(exact, target.cost)
					if target.requiresVip == true then
						h:setFlag(exact, VIP_FLAG, true)
					end
					local result = h:descend(exact)
					expect(result):toBeOk()
					expect((result :: any).value.tier):toBe(k)
					expect(h:credits(exact)):toBe(0)
				end
			end
		)

		it(
			"THE BOUNDARY: one Credit short refuses, exactly the price admits, for EVERY rung",
			function()
				local l = ladder()
				for k = 2, l.maxTier do
					local target = l.tiers[k]
					local h = newServer()

					local short = h:join(1)
					h:setTier(short, k - 1)
					h:setHull(short, target.hullLevel)
					h:fund(short, math.max(0, target.cost - 1))
					if target.requiresVip == true then
						h:setFlag(short, VIP_FLAG, true)
					end
					expect(h:descend(short)):toBeErr(Result.Codes.Insufficient)
					expect(h:credits(short)):toBe(math.max(0, target.cost - 1))
					expect(persistedTier(h:blob(short))):toBe(k - 1)
				end
			end
		)

		it(
			"THE HEADLINE: a rich player with no hull cannot buy their way past the middle game",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				h:setTier(player, 1)
				h:setHull(player, 0)
				h:setFlag(player, VIP_FLAG, true) -- even the pass must not help
				local purse = 10 ^ 12
				h:fund(player, purse)

				-- Spam the whole ladder's worth of descends. Money alone must stall at the first rung whose
				-- hull minimum outruns a level-0 hull.
				for _ = 1, l.maxTier * 3 do
					h:descend(player)
				end

				local reached = h:info(player).tier
				local rating = h:info(player).hullRating
				-- The highest rung a bare hull certifies, computed from the LADDER's own advertised minimums.
				local admissible = 1
				for k = 2, l.maxTier do
					if l.tiers[k].hullRequired <= rating then
						admissible = k
					else
						break
					end
				end
				expect(reached):toBe(admissible)
				expectTrue(
					reached < l.maxTier,
					"a level-0 hull reached the deepest trench with Credits alone — the pressure gate is not "
						.. "gating anything"
				)
				-- And the money that DID move bought exactly the rungs that were reached.
				expect(h:credits(player)):toBe(purse - costBetween(1, reached))
				expect(h:spentTotal()):toBe(costBetween(1, reached))
			end
		)

		it(
			"THE ORDERING: hull-then-Credits and Credits-then-hull converge on the identical outcome",
			function()
				local h = newServer()
				local l = ladder()
				local target = l.tiers[2]

				local hullFirst = h:join(1)
				h:setTier(hullFirst, 1)
				h:setHull(hullFirst, target.hullLevel)
				expect(h:descend(hullFirst)):toBeErr(Result.Codes.Insufficient) -- the money is not there yet
				h:fund(hullFirst, target.cost)
				local a = h:descend(hullFirst)

				local creditsFirst = h:join(2)
				h:setTier(creditsFirst, 1)
				h:fund(creditsFirst, target.cost)
				expect(h:descend(creditsFirst)):toBeErr(Result.Codes.PrereqUnmet) -- the hull is not there yet
				h:setHull(creditsFirst, target.hullLevel)
				local b = h:descend(creditsFirst)

				expect(a):toBeOk()
				expect(b):toBeOk()
				expect((a :: any).value.tier):toBe((b :: any).value.tier)
				expect(h:credits(hullFirst)):toBe(h:credits(creditsFirst))
				expect(persistedTier(h:blob(hullFirst))):toBe(persistedTier(h:blob(creditsFirst)))
			end
		)

		it(
			"STRICTLY SEQUENTIAL: no purchase order lands a player more than one rung per descend",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				-- Everything anyone could ever need, all at once, in the "wrong" order (flag, then hull, then
				-- an unlimited purse) — the shape a rich player would actually try.
				h:setTier(player, 1)
				h:setFlag(player, VIP_FLAG, true)
				h:setHull(player, l.tiers[l.maxTier].hullLevel)
				h:fund(player, 10 ^ 12)

				local expected = 1
				for _ = 1, l.maxTier - 1 do
					local result = h:descend(player)
					expect(result):toBeOk()
					expected += 1
					expect((result :: any).value.tier):toBe(expected)
					expect((result :: any).value.previousTier):toBe(expected - 1)
					expect(h:info(player).tier):toBe(expected)
				end
				expect(h:info(player).tier):toBe(l.maxTier)
				-- And every rung was paid for: the deepest trench costs the SUM of the ladder, never one price.
				expect(h:spentTotal()):toBe(costBetween(1, l.maxTier))
				expect(h:credits(player)):toBe(10 ^ 12 - costBetween(1, l.maxTier))
			end
		)

		it("at the deepest trench a further descend is refused and debits nothing", function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			h:setTier(player, l.maxTier)
			h:setHull(player, l.tiers[l.maxTier].hullLevel + 10)
			h:setFlag(player, VIP_FLAG, true)
			h:fund(player, 10 ^ 12)
			local before = h:snap(player)

			expect(h:descend(player)):toBeErr(Result.Codes.PrereqUnmet)

			local after = h:snap(player)
			expect(after.credits):toBe(before.credits)
			expect(after.tier):toBe(l.maxTier)
			expect(after.spent):toBe(before.spent)
			expect(h:info(player).atMaxTier):toBe(true)
		end)
	end
)

-- ── 4. the VIP trench ───────────────────────────────────────────────────────────────────────────

describe(
	"depth: the VIP trench is gated on the gamepass flag, and the pass never skips a rung",
	function()
		it(
			"without the flag the VIP rung is Err(PrereqUnmet) even with the hull AND the Credits",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				local vip = l.tiers[l.vipTier]
				h:setTier(player, l.vipTier - 1)
				h:setHull(player, vip.hullLevel)
				h:fund(player, vip.cost * 10)
				local before = h:snap(player)

				expect(h:descend(player)):toBeErr(Result.Codes.PrereqUnmet)

				local after = h:snap(player)
				expect(after.credits):toBe(before.credits)
				expect(after.tier):toBe(l.vipTier - 1)
				expect(after.spent):toBe(before.spent)
			end
		)

		it("the SERVER-set flag opens it — and only it", function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			local vip = l.tiers[l.vipTier]
			h:setTier(player, l.vipTier - 1)
			h:setHull(player, vip.hullLevel)
			h:fund(player, vip.cost)
			h:setFlag(player, VIP_FLAG, true)

			local result = h:descend(player)
			expect(result):toBeOk()
			expect((result :: any).value.tier):toBe(l.vipTier)
			expect(h:credits(player)):toBe(0)
		end)

		it("owning the pass does NOT let a shallow player jump to the VIP trench", function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			h:setTier(player, 1)
			h:setFlag(player, VIP_FLAG, true)
			h:setHull(player, l.tiers[l.maxTier].hullLevel)
			h:fund(player, 10 ^ 12)

			local result = h:descend(player)
			expect(result):toBeOk()
			expect((result :: any).value.tier):toBe(2) -- the next rung, not the exclusive one
			expect((result :: any).value.cost):toBe(l.tiers[2].cost)
		end)

		it(
			"a client-set-looking truthy value is not a flag: only `true` opens the trench",
			function()
				local h = newServer()
				local l = ladder()
				local vip = l.tiers[l.vipTier]
				for _, value in { 1, "true", "yes", {} } do
					local player = h:join(math.random(1000, 999999))
					h:setTier(player, l.vipTier - 1)
					h:setHull(player, vip.hullLevel)
					h:fund(player, vip.cost)
					h:write(player, function(d: any): ()
						d.flags[VIP_FLAG] = value
					end)
					expect(h:descend(player)):toBeErr(Result.Codes.PrereqUnmet)
					expect(h:credits(player)):toBe(vip.cost)
				end
			end
		)
	end
)

-- ── 5. negative / abuse: the payload carries nothing the server derives ─────────────────────────

describe("depth: malformed and forged payloads are refused, not ignored", function()
	it("a payload naming the tier, the price, the hull or the day -> Err(BadPayload)", function()
		local h = newServer()
		local player = h:join(1)
		local l = ladder()
		armFor(h, player, 1)
		local wire = h:wire()
		local before = h:snap(player)

		local forgeries: { any } = {
			{ tier = l.maxTier },
			{ targetTier = l.maxTier },
			{ nextTier = 6 },
			{ depth = 6 },
			{ cost = 0 },
			{ price = 0 },
			{ credits = 10 ^ 12 },
			{ amount = 0 },
			{ hull = 99 },
			{ hullRating = 99 },
			{ multiplier = 1000 },
			{ restockTier = 1 },
			{ day = 0 },
			{ dayIndex = 0 },
			{ nowUnix = 0 },
			{ timestamp = 0 },
			{ userId = 2 },
			{ flags = { [VIP_FLAG] = true } },
			{ force = true },
		}
		for _, payload in forgeries do
			expect(wire.invoke(Net.Actions.Descend, player, payload)):toBeErr(
				Result.Codes.BadPayload
			)
			expect(wire.invoke(Net.Actions.FetchDepth, player, payload)):toBeErr(
				Result.Codes.BadPayload
			)
		end

		-- Nothing moved: the forgeries were refused, not silently ignored while the descend ran.
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.tier):toBe(before.tier)
		expect(after.spent):toBe(before.spent)
	end)

	it("a non-table payload -> Err(BadType); nil and an empty table are accepted", function()
		local h = newServer()
		local player = h:join(1)
		armFor(h, player, 1)
		local wire = h:wire()

		for _, payload in { "descend", 6, true, 0 / 0 } do
			expect(wire.invoke(Net.Actions.FetchDepth, player, payload)):toBeErr(
				Result.Codes.BadType
			)
		end
		expect(wire.invoke(Net.Actions.FetchDepth, player, nil)):toBeOk()
		expect(wire.invoke(Net.Actions.FetchDepth, player, {})):toBeOk()
		expect(wire.invoke(Net.Actions.Descend, player, nil)):toBeOk()
	end)

	it("an unknown action name never reaches the depth handlers", function()
		local h = newServer()
		local player = h:join(1)
		local wire = h:wire()
		expect(wire.invoke("depth.descend.admin", player, nil)):toBeErr(Result.Codes.UnknownAction)
		expect(wire.invoke("depth.setTier", player, { tier = 6 })):toBeErr(
			Result.Codes.UnknownAction
		)
	end)

	it("descend is rate-limited by the spine Gate, and fetch's bucket is its own", function()
		local h = newServer()
		local player = h:join(1)
		armFor(h, player, 1)
		local wire = h:wire({ gate = true })
		local policy = h.registered[Net.Actions.Descend].rate
		local budget = policy.burst or policy.maxPerWindow

		-- The clock never advances, so the token bucket never refills: request budget+1 must be the
		-- one the Gate refuses.
		for index = 1, budget do
			local result = wire.invoke(Net.Actions.Descend, player, nil)
			expectTrue(
				result.ok == true or result.code ~= Result.Codes.RateLimited,
				`descend #{index} of a budget of {budget} was rate-limited early`
			)
		end
		expect(wire.invoke(Net.Actions.Descend, player, nil)):toBeErr(Result.Codes.RateLimited)
		-- A different action has a different bucket: the HUD must still be able to read the trench.
		expect(wire.invoke(Net.Actions.FetchDepth, player, nil)):toBeOk()
	end)

	it(
		"the payload has no owner field to forge: a second player's userId cannot steer a descend",
		function()
			local h = newServer()
			local victim = h:join(1)
			local attacker = h:join(2)
			armFor(h, victim, 1)
			h:setTier(attacker, 1)
			h:fund(attacker, 0)
			local wire = h:wire({ gate = true })

			expect(wire.invoke(Net.Actions.Descend, attacker, { userId = victim.UserId })):toBeErr(
				Result.Codes.BadPayload
			)
			-- The attacker's own descend fails on their own empty purse, and the victim is untouched.
			local own = wire.invoke(Net.Actions.Descend, attacker, nil)
			expectTrue(own.ok == false, "a broke attacker descended")
			expect(persistedTier(h:blob(victim))):toBe(1)
			expect(h:credits(victim)):toBe(ladder().tiers[2].cost)
		end
	)
end)

-- ── 6. economy safety: no mint, no negative balance, no free rung ───────────────────────────────

describe("depth: the economy cannot be minted, overflowed or side-stepped", function()
	it(
		"with ctx.economy absent the descend REFUSES and grants no rung (never a free descend)",
		function()
			local h = newServer()
			local player = h:join(1)
			armFor(h, player, 1)
			local before = h:snap(player)

			local result = h:descend(player, { noEconomy = true })
			expectTrue(result.ok == false, "a descend with no economy seam succeeded")

			local after = h:snap(player)
			expect(after.tier):toBe(before.tier)
			expect(after.credits):toBe(before.credits)
			expect(after.spent):toBe(before.spent)
			expectClose(after.rate, before.rate, "a refused descend must not move the income rate")
		end
	)

	it("a balance can never go negative, and a refused descend leaves it byte-identical", function()
		local h = newServer()
		local l = ladder()
		for k = 2, l.maxTier do
			local player = h:join(k)
			h:setTier(player, k - 1)
			h:setHull(player, l.tiers[k].hullLevel)
			h:setFlag(player, VIP_FLAG, true)
			for _, purse in { 0, 1, l.tiers[k].cost - 1 } do
				if purse >= 0 then
					h:fund(player, purse)
					expect(h:descend(player)):toBeErr(Result.Codes.Insufficient)
					expect(h:credits(player)):toBe(purse)
					expectTrue(h:credits(player) >= 0, "the balance went negative")
				end
			end
		end
	end)

	it(
		"descend NEVER earns: currency_earned and stats.lifetimeCredits are untouched by the whole ladder",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			h:setTier(player, 1)
			h:setFlag(player, VIP_FLAG, true)
			h:setHull(player, l.tiers[l.maxTier].hullLevel)
			h:fund(player, 10 ^ 12)
			local before = h:snap(player)

			for _ = 1, l.maxTier + 2 do
				h:descend(player)
			end

			local after = h:snap(player)
			expect(after.earned):toBe(before.earned)
			expect(after.lifetime):toBe(before.lifetime)
			expect(after.pearls):toBe(before.pearls)
			-- Every Credit that left the balance is accounted for on the ledger, exactly once.
			expect(before.credits - after.credits):toBe(h:spentTotal())
		end
	)

	it(
		"every currency_spent from a descend is sunk to a depth rung, priced at the ladder",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			armFor(h, player, 1)
			expect(h:descend(player)):toBeOk()
			local event = h:lastEvent("currency_spent")
			expectTrue(event ~= nil, "a successful descend emitted no currency_spent")
			expect(event.payload.currency):toBe(CREDITS)
			expect(event.payload.amount):toBe(l.tiers[2].cost)
			expect(event.payload.balance):toBe(h:credits(player))
			expectTrue(
				string.find(tostring(event.payload.sink), "depth") ~= nil,
				`currency_spent from a descend is sunk to "{tostring(event.payload.sink)}", which does not `
					.. `name depth — the spend cannot be attributed`
			)
		end
	)

	it(
		"before the session is loaded, descend and fetch refuse rather than fabricating a tier",
		function()
			local h = newServer()
			local stranger = Mocks.player(4242) -- never loadSession'd
			expect(h:fetch(stranger)):toBeErr(Result.Codes.NoData)
			expect(h:descend(stranger)):toBeErr(Result.Codes.NoData)
		end
	)
end)

-- ── 7. the read surface, and that it tells the truth the gate enforces ──────────────────────────

describe("depth.fetch: the HUD's numbers are the numbers the gate believes", function()
	it(
		"fetch reports the current tier, the next rung's Credits + hull, and today's restock tier",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			h:setTier(player, 2)
			local info = h:info(player)
			expect(info.tier):toBe(2)
			expect(info.nextTier):toBe(3)
			expect(info.nextCost):toBe(l.tiers[3].cost)
			expect(info.nextHullRequired):toBe(l.tiers[3].hullRequired)
			expectTrue(
				type(info.restockTier) == "number"
					and info.restockTier >= 1
					and info.restockTier <= l.maxTier,
				`fetch reported a restock tier of {tostring(info.restockTier)}`
			)
			expect(info.maxTier):toBe(l.maxTier)
		end
	)

	it(
		"`canDescend` is the gate's verdict: it agrees with what descend actually does, every time",
		function()
			local h = newServer()
			local l = ladder()
			local target = l.tiers[2]
			-- A grid over the two gate inputs, straddling both thresholds.
			local hullLevels = { 0, math.max(0, target.hullLevel - 1), target.hullLevel }
			local purses = { 0, math.max(0, target.cost - 1), target.cost }
			local seed = 0
			for _, hullLevel in hullLevels do
				for _, purse in purses do
					seed += 1
					local player = h:join(7000 + seed)
					h:setTier(player, 1)
					h:setHull(player, hullLevel)
					h:fund(player, purse)
					local advertised = h:info(player).canDescend
					local result = h:descend(player)
					expect(result.ok):toBe(advertised)
				end
			end
		end
	)

	it(
		"fetch is SIDE-EFFECT FREE: reading it ten times changes no tier, no balance and emits nothing",
		function()
			local h = newServer()
			local player = h:join(1)
			armFor(h, player, 1)
			local before = h:snap(player)
			local blobBefore = deepCopy(h:blob(player))
			for _ = 1, 10 do
				expect(h:fetch(player)):toBeOk()
			end
			local after = h:snap(player)
			expect(after.credits):toBe(before.credits)
			expect(after.tier):toBe(before.tier)
			expect(after.spent):toBe(before.spent)
			expect(after.progression):toBe(before.progression)
			expect(after.loop):toBe(before.loop)
			expect(h:blob(player)):toEqual(blobBefore)
		end
	)

	it(
		"the requirement panel's own numbers drive a successful descend to a zero balance",
		function()
			local h = newServer()
			local l = ladder()
			for k = 2, l.maxTier do
				local player = h:join(8000 + k)
				h:setTier(player, k - 1)
				local info = h:info(player)
				-- Fund and hull EXACTLY what the panel asked for, discovered from the panel alone.
				h:fund(player, info.nextCost)
				h:setHull(player, hullLevelForRating(h, player, info.nextHullRequired))
				if info.nextRequiresVip then
					h:setFlag(player, VIP_FLAG, true)
				end
				-- setHull/fund order does not matter, but re-fund in case the probe path wrote nothing.
				h:fund(player, info.nextCost)
				local result = h:descend(player)
				expect(result):toBeOk()
				expect(h:credits(player)):toBe(0)
				expect(h:info(player).tier):toBe(k)
			end
		end
	)
end)

-- ── 8. AMENDMENT A1 + the art posture: stacked shells at descending Y ───────────────────────────

describe(
	"depth: tierYFor is the world Y of the PERSISTED tier (stacked shells, descending)",
	function()
		it("Y strictly descends with every rung", function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			local previous: number? = nil
			for k = 1, l.maxTier do
				h:setTier(player, k)
				local y = h.seam:tierYFor(h:blob(player))
				expectFinite(y, `tierYFor at tier {k}`)
				expect(y):toBe(h:info(player).y)
				if previous ~= nil then
					expectTrue(
						y < previous :: number,
						`tier {k} sits at Y={y}, which is not BELOW tier {k - 1}'s Y={previous} — the trench `
							.. `shells are not stacked at descending Y`
					)
				end
				previous = y
			end
		end)

		it(
			"a REJOINING player's Y follows their persisted tier through a save/reload round trip",
			function()
				local h = newServer()
				local player = h:join(1)
				armFor(h, player, 1)
				expect(h:descend(player)):toBeOk()
				local yAfterDescend = h.seam:tierYFor(h:blob(player))

				-- Persist, drop the session, and come back exactly as a rejoin does.
				expect(h.data:save(player)):toBeOk()
				h.data:onPlayerRemoving(player)
				local rejoined = h:join(1)
				local blob = h:blob(rejoined)
				expect(persistedTier(blob)):toBe(2)
				expect(h.seam:tierYFor(blob)):toBe(yAfterDescend)
				expect(h:info(rejoined).tier):toBe(2)
				-- And the running rate came back with them: the tier is not a cosmetic that reset on rejoin.
				expectClose(
					h:multiplier(rejoined),
					ladder().tiers[2].mult * restockFactorFor(h, rejoined, 2),
					"the rejoined multiplier"
				)
			end
		)

		it("a successful descend reports the Y it moved to, and the Y it came from", function()
			local h = newServer()
			local player = h:join(1)
			armFor(h, player, 1)
			local yBefore = h.seam:tierYFor(h:blob(player))
			local result = h:descend(player)
			expect(result):toBeOk()
			local info = (result :: any).value
			expect(info.previousY):toBe(yBefore)
			expect(info.y):toBe(h.seam:tierYFor(h:blob(player)))
			expectTrue(info.y < info.previousY, "the descend did not move the dome downward")
		end)
	end
)

-- ── 9. THE DAILY RESTOCK: server clock only, resets each day ────────────────────────────────────

describe("depth: the daily restock rotation is a pure function of SERVER time", function()
	it(
		"today's restock tier is deterministic in the clock alone — two servers agree, two players agree",
		function()
			local a = newServer({ startUnix = START_UNIX })
			local b = newServer({ startUnix = START_UNIX })
			local pa = a:join(1)
			local pb1 = b:join(1)
			local pb2 = b:join(2)
			b:setTier(pb2, 3)
			b:setHull(pb2, 9)
			expect(a:info(pa).restockTier):toBe(b:info(pb1).restockTier)
			-- It does not depend on the player's blob at all.
			expect(b:info(pb1).restockTier):toBe(b:info(pb2).restockTier)
		end
	)

	it("it resets each day: the day index advances exactly at the 86400s boundary", function()
		local base = START_UNIX - (START_UNIX % DAY_SECONDS) -- a true UTC midnight
		local h = newServer({ startUnix = base })
		local player = h:join(1)
		local dayAtMidnight = h:info(player).restockDayIndex

		h.clock:advance(DAY_SECONDS - 1)
		expect(h:info(player).restockDayIndex):toBe(dayAtMidnight)

		h.clock:advance(1)
		expect(h:info(player).restockDayIndex):toBe(dayAtMidnight + 1)
	end)

	it(
		"the wreck RESETS: its tier or its position CHANGES between two consecutive server-days",
		function()
			-- AMENDMENT A7: "the rich wreck resets" must be provable by the wreck's presence/position
			-- changing between two server-days — not by an integer flipping.
			local midnight = START_UNIX - (START_UNIX % DAY_SECONDS)
			local yesterday = DepthService:wreckPlacementAt(midnight)
			local today = DepthService:wreckPlacementAt(midnight + DAY_SECONDS)
			expectFinite(yesterday.x, "the wreck's X")
			expectFinite(yesterday.z, "the wreck's Z")
			expect(today.dayIndex):toBe(yesterday.dayIndex + 1)
			local moved = today.tier ~= yesterday.tier
				or math.abs(today.x - yesterday.x) > 1e-9
				or math.abs(today.z - yesterday.z) > 1e-9
				or math.abs(today.y - yesterday.y) > 1e-9
			expectTrue(
				moved,
				"the rich wreck sits in exactly the same tier at exactly the same position on two "
					.. "consecutive server-days — nothing about it 'resets'"
			)
			-- Within one day it never moves: a wreck that drifted every read is not a landmark.
			local later = DepthService:wreckPlacementAt(midnight + DAY_SECONDS - 1)
			expect(later.tier):toBe(yesterday.tier)
			expect(later.x):toBe(yesterday.x)
			expect(later.z):toBe(yesterday.z)
		end
	)

	it("the wreck's tier is the SAME tier the HUD badge advertises", function()
		local h = newServer({ startUnix = START_UNIX })
		local player = h:join(1)
		for day = 0, 9 do
			local at = START_UNIX + day * DAY_SECONDS
			local badge = h:info(player, { clock = Mocks.clock(at) }).restockTier
			expect(DepthService:wreckPlacementAt(at).tier):toBe(badge)
		end
	end)

	it(
		"the wreck only ever spawns in a TRENCH tier — never in the paywalled VIP trench",
		function()
			local l = ladder()
			local seen: { [number]: boolean } = {}
			for day = -30, 200 do
				local tier = DepthService:restockTierAt(START_UNIX + day * DAY_SECONDS)
				expectTrue(
					tier >= 1 and tier <= l.maxTier - 1 and tier == math.floor(tier),
					`the restock landed on tier {tier}; the daily re-entry hook must sit in one of the `
						.. `{l.maxTier - 1} trench tiers, never behind the paywall`
				)
				seen[tier] = true
			end
			-- And it is genuinely reachable wherever a player is standing: every trench tier gets a turn.
			for k = 1, l.maxTier - 1 do
				expectTrue(
					seen[k] == true,
					`over 230 server-days the rich wreck never once spawned in tier {k} — a re-entry hook `
						.. `that cannot reach a tier is not a re-entry reason for the players standing there`
				)
			end
		end
	)

	it(
		"consecutive days do not repeat the same tier (the reset is visible to a returning player)",
		function()
			local previous: number? = nil
			for day = 0, 40 do
				local tier = DepthService:restockTierAt(START_UNIX + day * DAY_SECONDS)
				if previous ~= nil then
					expectTrue(
						tier ~= previous :: number,
						`the restock stayed on tier {tier} for two consecutive days — a player who logs in `
							.. `daily sees no reset`
					)
				end
				previous = tier
			end
		end
	)
end)

describe("depth: the restock multiplies value ONLY for the player standing in it", function()
	it("the seam multiplies by the restock bonus at the restock tier, and not elsewhere", function()
		local h = newServer({ startUnix = START_UNIX })
		local player = h:join(1)
		local l = ladder()
		local at = h.clock:unix()
		local restockTier = h:info(player).restockTier
		local bonus = h:info(player).restockMultiplier
		expectTrue(
			bonus > 1,
			`the restock multiplier is {bonus}; a "rich wreck" must be worth more`
		)

		for k = 1, l.maxTier do
			h:setTier(player, k)
			local expected = l.tiers[k].mult * (if k == restockTier then bonus else 1)
			expectClose(h:multiplier(player, at), expected, `the multiplier at tier {k}`)
			expect(h:info(player).restockActive):toBe(k == restockTier)
		end
	end)

	it("A DELTA ON THE RUNNING RATE: the same blob out-earns itself on its restock day", function()
		local h = newServer({ startUnix = START_UNIX })
		local player = h:join(1)
		-- Stand still, at one tier, and move only the SERVER CLOCK.
		local tier = 3
		h:setTier(player, tier)
		local onDay: number? = nil
		local offDay: number? = nil
		for day = 0, 30 do
			local at = START_UNIX + day * DAY_SECONDS
			if DepthService:restockTierAt(at) == tier then
				onDay = at
			else
				offDay = at
			end
			if onDay ~= nil and offDay ~= nil then
				break
			end
		end
		expectTrue(
			onDay ~= nil and offDay ~= nil,
			"could not find a restock-on and a restock-off day"
		)
		local hot = h:rate(player, onDay :: number)
		local cold = h:rate(player, offDay :: number)
		expectTrue(
			hot > cold,
			`the rich wreck did not raise the running income rate at its own tier ({cold} -> {hot})`
		)
		expectClose(
			hot / cold,
			ladder().restockMultiplier,
			"the restock's effect on the running rate"
		)
	end)

	it("no client can steer the restock: the day comes from ctx.clock and nowhere else", function()
		local h = newServer({ startUnix = START_UNIX })
		local player = h:join(1)
		local wire = h:wire()
		local honest = (wire.invoke(Net.Actions.FetchDepth, player, nil) :: any).value

		-- Every shape a client could use to claim a day is refused outright.
		for _, forgery in
			{
				{ day = 1 },
				{ dayIndex = 999 },
				{ nowUnix = 0 },
				{ time = 0 },
				{ serverTime = 0 },
				{ clientTime = 0 },
			}
		do
			expect(wire.invoke(Net.Actions.FetchDepth, player, forgery)):toBeErr(
				Result.Codes.BadPayload
			)
		end
		-- The badge only moves when the SERVER clock moves.
		expect((wire.invoke(Net.Actions.FetchDepth, player, nil) :: any).value.restockDayIndex):toBe(
			honest.restockDayIndex
		)
		h.clock:advance(DAY_SECONDS)
		expect((wire.invoke(Net.Actions.FetchDepth, player, nil) :: any).value.restockDayIndex):toBe(
			honest.restockDayIndex + 1
		)
	end)

	-- [REGRESSION — dropped gate finding BH1] The rotation deliberately never lands the rich wreck
	-- behind the paywall (pinned by "the wreck only ever spawns in a TRENCH tier" above). That is a
	-- fair design decision — the daily hook must be reachable by the players who can stand there —
	-- but it has a price: the VIP trench is the ONE rung with no compensating hot day of its own, so
	-- its flat multiplier has to beat the RESTOCKED reading of every rung below it. Otherwise a free
	-- tier-5 player out-earns a player who paid Credits AND real money one day in five, and depth is
	-- one-way: nothing in the game walks `upgrades.depth` back up, so the last descend is a permanent
	-- pay cut on those days. Measured on the RUNNING rate, the number Salvage actually multiplies by.
	it(
		"the paywalled trench out-earns EVERY restocked tier below it (it can never be restocked itself)",
		function()
			local h = newServer({ startUnix = START_UNIX })
			local player = h:join(1)
			local l = ladder()
			expectTrue(l.vipTier ~= nil, "no rung on the ladder is gated on a gamepass flag")
			local vip = l.vipTier :: number

			for k = 1, vip - 1 do
				local hot: number? = nil
				for day = 0, 60 do
					local candidate = START_UNIX + day * DAY_SECONDS
					if DepthService:restockTierAt(candidate) == k then
						hot = candidate
						break
					end
				end
				expectTrue(hot ~= nil, `no server-day within 60 puts the rich wreck in tier {k}`)
				local at = hot :: number
				expectTrue(
					DepthService:restockTierAt(at) ~= vip,
					"the paywalled trench carries the wreck on this day, so it is not the excluded rung"
				)

				h:setTier(player, k)
				local restocked = h:rate(player, at)
				h:setTier(player, vip)
				local paywalled = h:rate(player, at)
				expectTrue(
					paywalled > restocked,
					`on the day the rich wreck lands in tier {k} ({l.tiers[k].label}) a player standing `
						.. `there earns {restocked}, while the paywalled {l.tiers[vip].label} — which costs `
						.. `{l.tiers[vip].cost} Credits plus the gamepass, and which the wreck can NEVER `
						.. `visit — earns only {paywalled}. The last rung of the ladder is a pay cut, and `
						.. `nothing walks a player back up it`
				)
			end
		end
	)

	it("a garbage clock reading never poisons the multiplier", function()
		local h = newServer()
		local player = h:join(1)
		h:setTier(player, 2)
		for _, bad in { 0 / 0, math.huge, -math.huge, "now", nil, {} } do
			local m = h.seam:valueMultiplier(h:blob(player), bad)
			expectFinite(m, `the multiplier for a clock reading of {tostring(bad)}`)
			expectTrue(m > 0, `a clock reading of {tostring(bad)} produced a multiplier of {m}`)
		end
	end)
end)

-- ── 10. analytics ───────────────────────────────────────────────────────────────────────────────

describe("depth: the three emit points", function()
	it(
		"progression fires on a successful descend, carrying the NEW tier — and never on a refusal",
		function()
			local h = newServer()
			local player = h:join(1)
			armFor(h, player, 1)
			local before = h:eventCount("progression")

			expect(h:descend(player)):toBeOk()
			expect(h:eventCount("progression")):toBe(before + 1)
			local event = h:lastEvent("progression")
			expect(event.payload.tier):toBe(2)
			expect(event.payload.previousTier):toBe(1)

			-- Now hulled for the NEXT rung but broke, so the refusal is the Credits clause: it must be
			-- silent on the progression channel.
			h:setHull(player, ladder().tiers[3].hullLevel)
			expect(h:credits(player)):toBe(0)
			expect(h:descend(player)):toBeErr(Result.Codes.Insufficient)
			expect(h:eventCount("progression")):toBe(before + 1)
		end
	)

	it(
		"loop_completed fires on the FIRST successful descend of a session and NEVER again",
		function()
			local h = newServer()
			local player = h:join(1)
			local l = ladder()
			h:setTier(player, 1)
			h:setFlag(player, VIP_FLAG, true)
			h:setHull(player, l.tiers[l.maxTier].hullLevel)
			h:fund(player, 10 ^ 12)
			expect(h:eventCount("loop_completed")):toBe(0)

			for _ = 1, l.maxTier - 1 do
				expect(h:descend(player)):toBeOk()
			end
			expect(h:eventCount("loop_completed")):toBe(1)
			expect(h:lastEvent("loop_completed").payload.tier):toBe(2)
		end
	)

	-- [REGRESSION — dropped gate findings F1/F3] "the FIRST successful descend of a SESSION" is a
	-- claim about SESSIONS, and a rejoin to the same server starts a new one. The suppression set is
	-- per-SERVER memory, so a session boundary it does not observe is a funnel event that silently
	-- never fires: the player descends, leaves, comes back, completes the core loop again, and the
	-- analytics say nobody did. Both halves are asserted here — the SECOND session emits again, and
	-- the second session still emits only ONCE — so the invariant cannot be satisfied by simply
	-- emitting on every descend.
	it(
		"loop_completed fires again for the SAME player's SECOND session (leave -> rejoin)",
		function()
			local h = newServer()
			local player = h:join(1)
			armFor(h, player, 1)
			expect(h:descend(player)):toBeOk()
			expect(h:eventCount("loop_completed")):toBe(1)
			expect(h:lastEvent("loop_completed").payload.tier):toBe(2)

			-- Leave and come back exactly as a rejoin does: persist, release the session, load it again.
			expect(h.data:save(player)):toBeOk()
			h.data:onPlayerRemoving(player)
			local rejoined = h:join(1)
			expect(persistedTier(h:blob(rejoined))):toBe(2)

			-- A NEW session completes the core loop again: it must be counted again.
			armFor(h, rejoined, 2)
			expect(h:descend(rejoined)):toBeOk()
			expect(h:eventCount("loop_completed")):toBe(2)
			expect(h:lastEvent("loop_completed").payload.tier):toBe(3)

			-- ...and only ONCE for that session, however many rungs it walks.
			armFor(h, rejoined, 3)
			expect(h:descend(rejoined)):toBeOk()
			expect(h:eventCount("loop_completed")):toBe(2)
		end
	)

	it("a REFUSED descend never emits loop_completed (the loop did not complete)", function()
		local h = newServer()
		local player = h:join(1)
		h:setTier(player, 1)
		h:fund(player, 0)
		for _ = 1, 5 do
			expectTrue(h:descend(player).ok == false, "a broke player descended")
		end
		expect(h:eventCount("loop_completed")):toBe(0)
		expect(h:eventCount("progression")):toBe(0)
	end)

	it("a THROWING analytics seam never turns a committed descend into an error", function()
		-- The exact shape that once turned a committed economy write into Err(Internal): an unguarded
		-- post-write side effect. The descend has already committed by the time an event is emitted, so
		-- an emitter that explodes must be swallowed, not surfaced.
		local h = newServer()
		local player = h:join(1)
		armFor(h, player, 1)
		local exploding: any = {}
		function exploding.emit(_self: any, _event: string, _payload: any): ()
			error("analytics is on fire")
		end
		expect(h:descend(player, { analytics = exploding })):toBeOk()
		expect(persistedTier(h:blob(player))):toBe(2)
		expect(h:credits(player)):toBe(0)
	end)

	it("an UNWIRED analytics seam is a no-op, never a refusal", function()
		local h = newServer()
		local player = h:join(1)
		armFor(h, player, 1)
		expect(h:descend(player, { noAnalytics = true })):toBeOk()
		expect(persistedTier(h:blob(player))):toBe(2)
	end)
end)

-- ── 11. CONCURRENCY: interleaved and spam-duplicated descends ───────────────────────────────────

describe(
	"depth: concurrency-safe — interleaved descends never double-spend or skip a rung",
	function()
		-- The invariant every correct implementation satisfies, whatever it does with a duplicate:
		-- the player ends at SOME tier T, and the Credits that left their balance are EXACTLY the
		-- ladder's price of walking from the starting tier to T. Never more (a double-spend), never
		-- less (two rungs for one debit).
		local function assertLadderInvariant(
			h: any,
			player: any,
			fromTier: number,
			startCredits: number
		): number
			local blob = h:blob(player)
			local reached = h:info(player).tier
			local paid = costBetween(fromTier, reached)
			expect(blob.currencies[CREDITS]):toBe(startCredits - paid)
			expect(h:spentTotal()):toBe(paid)
			expectTrue(
				blob.currencies[CREDITS] >= 0,
				"the balance went negative under interleaving"
			)
			return reached
		end

		it(
			"a spam-duplicated descend under a FORCED yield: one rung, one debit, and the duplicate genuinely interleaved",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				h:setTier(player, 1)
				h:setHull(player, l.tiers[2].hullLevel)
				local purse = l.tiers[2].cost * 4
				h:fund(player, purse)

				local log: { string } = {}
				h:setYield(true)
				local cos: { thread } = {}
				for index = 1, 4 do
					table.insert(
						cos,
						coroutine.create(function()
							table.insert(log, `enter{index}`)
							h:descend(player)
							table.insert(log, `exit{index}`)
						end)
					)
				end
				drain(cos)
				h:setYield(false)

				-- THE INTERLEAVE PROOF: a later request ran to COMPLETION while request #1 was still parked
				-- inside the data layer. Without this, four sequential calls would look identical.
				local exitFirst = table.find(log, "exit1")
				expectTrue(exitFirst ~= nil, "request #1 never finished")
				local nestedCompletion = false
				for index = 2, 4 do
					local other = table.find(log, `exit{index}`)
					if other ~= nil and other < (exitFirst :: number) then
						nestedCompletion = true
					end
				end
				expectTrue(
					nestedCompletion,
					"no duplicate completed while the first descend was in flight — the forced yield did not "
						.. "arm, so this case degenerates to four sequential descends and proves nothing"
				)

				-- Only the hull for tier 2 was bought, so tier 3 is out of reach whatever the interleaving did.
				local reached = assertLadderInvariant(h, player, 1, purse)
				expect(reached):toBe(2)
				expect(h:eventCount("currency_spent")):toBe(1)
				expect(h:eventCount("progression")):toBe(1)
				expect(h:eventCount("loop_completed")):toBe(1)
			end
		)

		it(
			"interleaved descends with the hull and purse for TWO rungs still pay the full ladder price",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				h:setTier(player, 1)
				h:setHull(player, l.tiers[3].hullLevel)
				local purse = costBetween(1, 3)
				h:fund(player, purse)

				h:setYield(true)
				local cos: { thread } = {}
				for _ = 1, 3 do
					table.insert(
						cos,
						coroutine.create(function()
							h:descend(player)
						end)
					)
				end
				drain(cos)
				h:setYield(false)

				local reached = assertLadderInvariant(h, player, 1, purse)
				expectTrue(reached >= 2, "no descend landed at all under interleaving")
				expectTrue(
					reached <= 3,
					`interleaved descends landed at tier {reached} with only two rungs' hull and Credits`
				)
			end
		)

		it(
			"the in-flight reservation is RELEASED: a player is never locked out of the trench after a race",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				h:setTier(player, 1)
				h:setHull(player, l.tiers[3].hullLevel)
				h:fund(player, costBetween(1, 3))

				h:setYield(true)
				local cos: { thread } = {}
				for _ = 1, 3 do
					table.insert(
						cos,
						coroutine.create(function()
							h:descend(player)
						end)
					)
				end
				drain(cos)
				h:setYield(false)

				-- Sequentially, from wherever the race left us, the ladder still works.
				local reached = h:info(player).tier
				if reached < 3 then
					expect(h:descend(player)):toBeOk()
					expect(h:info(player).tier):toBe(reached + 1)
				end
				expect(h:credits(player)):toBe(0)
			end
		)

		it(
			"SHARED BALANCE: an interleaved structures buy + descend can never overdraw the purse",
			function()
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				h:setTier(player, 1)
				h:setHull(player, l.tiers[2].hullLevel)
				-- Enough for the descend OR the hull plate, but NOT for both.
				local shopView = (StructuresShopService:fetch(h:ctx(player)) :: any).value
				local hullPrice = 0
				for _, row in shopView.entries do
					if row.key == HULL_KEY then
						hullPrice = row.nextCost
					end
				end
				expectTrue(hullPrice > 0, "the shop advertises no price for a hull plate")
				local purse = math.max(l.tiers[2].cost, hullPrice)
				expectTrue(
					purse < l.tiers[2].cost + hullPrice,
					"the two prices are not tight enough to force a contention"
				)
				h:fund(player, purse)

				h:setYield(true)
				drain({
					coroutine.create(function()
						h:descend(player)
					end),
					coroutine.create(function()
						StructuresShopService:buy(h:ctx(player), HULL_KEY)
					end),
				})
				h:setYield(false)

				local balance = h:credits(player)
				expectTrue(balance >= 0, `the shared balance went negative ({balance})`)
				expect(purse - balance):toBe(h:spentTotal())
			end
		)

		it(
			"FALSIFIABILITY: a naive price-outside-the-lock descend DOES pay twice for one rung",
			function()
				-- The counter-case that proves the race cases above are meaningful rather than trivially green.
				-- This is the exact mistake the slice forbids ("validates ALL of the following against the SAME
				-- lock-held snapshot in which it debits"): read the tier and its price OUTSIDE the transform,
				-- yield inside ctx.data:update, then write and debit.
				local h = newServer()
				local player = h:join(1)
				local l = ladder()
				local cost = l.tiers[2].cost
				h:setTier(player, 1)
				h:setHull(player, l.tiers[2].hullLevel)
				h:fund(player, cost * 4)

				local function naiveDescend(): ()
					local blob = h:blob(player) -- READ OUTSIDE THE LOCK
					local current = blob.upgrades[DEPTH_KEY] or 1
					local target = current + 1
					local price = l.tiers[target].cost
					h.data:update(player, function(d: any): any
						d.upgrades[DEPTH_KEY] = target
						h.economy:spend(d, CREDITS, price, "naive.depth")
						return d
					end)
				end

				h:setYield(true)
				drain({
					coroutine.create(naiveDescend),
					coroutine.create(naiveDescend),
				})
				h:setYield(false)

				expect(persistedTier(h:blob(player))):toBe(2) -- ONE rung...
				expect(h:credits(player)):toBe(cost * 4 - cost * 2) -- ...paid for TWICE.
				expectTrue(
					h:spentTotal() == cost * 2,
					`the naive descend did not double-spend ({h:spentTotal()} vs {cost * 2}), so the race cases `
						.. `above are not distinguishing a correct implementation from a broken one`
				)
			end
		)
	end
)

-- ── 12. persistence: the tier rides the open upgrades map, and survives a round trip ────────────

describe("depth: `upgrades.depth` is the authoritative, persisted fact", function()
	it("a descend writes the canonical key and it survives save -> reload", function()
		local h = newServer()
		local player = h:join(1)
		armFor(h, player, 1)
		expect(h:descend(player)):toBeOk()
		expect(persistedTier(h:blob(player))):toBe(2)

		expect(h.data:save(player)):toBeOk()
		h.data:onPlayerRemoving(player)

		local rejoined = h:join(1)
		local blob = h:blob(rejoined)
		expect(persistedTier(blob)):toBe(2)
		expect(blob.currencies[CREDITS]):toBe(0)
		-- The whole blob still carries the fields the round trip must not lose.
		expect(type(blob.upgrades)):toBe("table")
		expect(type(blob.flags)):toBe("table")
		expect(blob.schemaVersion):toBe(h:blob(rejoined).schemaVersion)
	end)

	it("a fresh blob carries NO depth key, and still reads as the first trench tier", function()
		local h = newServer()
		local player = h:join(1)
		expect(persistedTier(h:blob(player))):toBe(nil)
		expect(h:info(player).tier):toBe(1)
		expectClose(
			h:multiplier(player) / restockFactorFor(h, player, 1),
			ladder().tiers[1].mult,
			"the fresh-player multiplier"
		)
	end)

	it("a refused descend leaves the depth key exactly as it found it, INCLUDING absent", function()
		local h = newServer()
		local player = h:join(1)
		local l = ladder()
		-- Hulled for the next rung so the refusal is the CREDITS clause, and the depth key was never
		-- written in the first place: a rolled-back tier must restore ABSENCE, not a 1.
		h:setHull(player, l.tiers[2].hullLevel)
		h:fund(player, 0)
		expect(h:descend(player)):toBeErr(Result.Codes.Insufficient)
		expect(persistedTier(h:blob(player))):toBe(nil)

		-- And a hull refusal at a real tier leaves the stored integer untouched.
		h:setTier(player, 2)
		h:setHull(player, 0)
		h:fund(player, l.tiers[3].cost * 10)
		expect(h:descend(player)):toBeErr(Result.Codes.PrereqUnmet)
		expect(persistedTier(h:blob(player))):toBe(2)
	end)
end)
