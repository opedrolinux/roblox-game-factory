--!strict
-- games/deep-reach/tests/integration/wholegame.spec.luau
-- [INDEPENDENT INTEGRATION GATE — authored from specs/deep-reach.md "## Core loop" and
--  "## Success criteria", NOT from any service's control flow. The per-feature gates each proved ONE
--  service in isolation; this file proves the features WORK TOGETHER by standing up the WHOLE game
--  and driving the SPEC's done-conditions end to end.]
--
-- ── WHAT "THE WHOLE GAME" MEANS HERE ────────────────────────────────────────────────────────────
-- `newGame()` below is src/server/init.server.luau rebuilt for Lune: the same context fields
-- Context.build constructs (clock, config, data, net, gate, analytics, economy), the same service
-- list in the SAME order, and the same pinned PlayerRemoving sequence (framework/PlayerLifecycle).
-- EVERY service is Started, so EVERY ctx seam is LIVE — `assertWired` fails the whole suite if any of
-- ctx.plot / ctx.salvage / ctx.depth / ctx.economy / ctx.analytics is nil, because a nil seam
-- silently turns an integration test back into a per-feature test that passes against a no-op.
--
-- Requests go through the REAL `Net.dispatch` (the same pure pipeline NetServer runs), over the REAL
-- spine `Gate`, against the REAL `DataService` over the REAL `MockStore` with its per-key FIFO lock.
-- Nothing here re-implements a handler, a price, a rate or a window.
--
-- ── WHY THE ASSERTIONS LOOK LIKE THIS ───────────────────────────────────────────────────────────
-- 26 of collect-sim's 66 confirmed defects were ONE shape: a purchase incremented a persisted field,
-- a test asserted the field moved, and NOTHING read it. So no case below is satisfied by a persisted
-- field changing. Every cross-feature seam is asserted as a DELTA ON THE CONSUMER'S OBSERVABLE
-- OUTPUT — the running income rate the tick and `salvage.fetch` compute, the capacity the offline cap
-- is bounded by, the pressure gate's verdict, the emitted analytics payload — measured through the
-- consumer, before and after the producer moves.
--
-- ── THE THREE THINGS ONLY THIS FILE CAN SEE ─────────────────────────────────────────────────────
--  1. THE RE-ENTRY LIFECYCLE. A per-feature gate cannot leave and rejoin: it holds one session for
--     the length of the test. Here a player EARNS, LEAVES through the pinned sequence (which stamps
--     timestamps.lastSeenUnix and releases the session), server time passes, and REJOINS — and the
--     away window must actually be paid. A lifecycle write on JOIN that clobbers the accrual base
--     before it is read would show up here as a ZERO grant and nowhere else.
--  2. THE SHARED BALANCE ACROSS FEATURES. Each feature's own gate raced itself. Credits are debited
--     by structures and depth and credited by salvage, offline, daily and monetization; only an
--     interleave that crosses those services can double-spend the one balance they share.
--  3. THE COMPOSED PACING. Three numeric tables (the salvage rate model, the shop price curve, the
--     tier ladder) multiply into "~90s to first Credits, 10-15 min to the first Depth unlock" and
--     nothing has ever checked the product. Per DECISION D2 the assertion here is a COARSE
--     ORDER-OF-MAGNITUDE BAND ONLY — it catches a composition that is 10x off. A GREEN BAND IS NOT
--     "THE PACING IS RIGHT": the exact numbers are a human tuning judgement at the playtest.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")

local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local DailyDropService = require("../../src/server/services/daily/DailyDropService")
local DataService = require("../../src/server/data/DataService")
local DepthService = require("../../src/server/services/depth/DepthService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local LeaderboardService = require("../../src/server/services/leaderboard/LeaderboardService")
local MonetizationService = require("../../src/server/services/monetization/MonetizationService")
local Net = require("../../src/shared/Net")
local OfflineService = require("../../src/server/services/offline/OfflineService")
local PlayerLifecycle = require("../../src/server/framework/PlayerLifecycle")
local PlotService = require("../../src/server/services/plot/PlotService")
local Result = require("../../src/shared/Result")
local ResurfaceService = require("../../src/server/services/resurface/ResurfaceService")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local StructuresShopService = require("../../src/server/services/structures/StructuresShopService")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000
local DAY_SECONDS = 86400
local HOUR_SECONDS = 3600

-- ── assertion helpers ───────────────────────────────────────────────────────────────────────────

local function expectTrue(condition: boolean, why: string): ()
	if not condition then
		error(why, 0)
	end
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function expectFinite(value: any, why: string): ()
	expectTrue(isFinite(value), `{why}: expected a finite number, got {tostring(value)}`)
end

-- Relative-tolerance comparison. Every observable this file asserts on is a PRODUCT of tuned steps
-- (rate = drones x conveyor x prestige x gamepass x boost x depth), so exact binary equality is not
-- available — but "this seam reached the number" is a question about magnitude.
local function expectClose(actual: any, expected: any, why: string): ()
	expectFinite(actual, why)
	expectFinite(expected, why)
	local tolerance = 1e-9 * math.max(1, math.abs(actual), math.abs(expected))
	if math.abs(actual - expected) > tolerance then
		error(`{why}: got {actual}, want {expected}`, 0)
	end
end

local function expectGreater(actual: any, floor: any, why: string): ()
	expectFinite(actual, why)
	expectTrue(actual > floor, `{why}: expected > {floor}, got {actual}`)
end

local function expectBetween(actual: any, low: number, high: number, why: string): ()
	expectFinite(actual, why)
	expectTrue(
		actual >= low and actual <= high,
		`{why}: expected within [{low}, {high}], got {actual}`
	)
end

-- Round-robin coroutine driver (the economy_race.spec idiom): resume every suspended coroutine
-- repeatedly until all are dead. Deterministic and deadlock-bounded.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 800 then
			error("integration race driver did not converge (possible deadlock)", 0)
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`integration race coroutine errored: {tostring(err)}`, 0)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- ── the server's config ─────────────────────────────────────────────────────────────────────────
-- The production Config with ONE change: `writeMinIntervalSeconds = 0`. The real 6s per-key throttle
-- floor is a DataStore budget rule, and DataService clears it by ADVANCING THE INJECTED CLOCK during
-- its retry backoff — which would silently move server time inside a test whose whole subject is what
-- happens over server time (the away window, the daily ladder, the restock day). Removing the floor
-- removes the interference; the retry policy itself is proven by data.spec / session_lock.spec.
local function testConfig(): any
	return {
		storeName = "DeepReachIntegration",
		schemaKeyPrefix = "player_",
		dataStore = {
			maxRetries = 4,
			retryBaseSeconds = 1.0,
			writeMinIntervalSeconds = 0,
			lockTtlSeconds = 30,
			heartbeatIntervalSeconds = 15,
			autosaveIntervalSeconds = 60,
			sessionLockedWaitSeconds = 40,
			globalWritesPerMinute = 60,
			globalWritesPerPlayerPerMinute = 10,
		},
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1.0 },
		flagsSeed = {},
	}
end

-- ── THE WHOLE-GAME HARNESS ──────────────────────────────────────────────────────────────────────

-- Every feature service in this game is a MODULE SINGLETON with module-level state (SalvageService
-- ._armed, DepthService._loopCompleted, MonetizationService.PASSES, ...). Each service's Start resets
-- its own state, and this list is the extra reset the singletons need so one case cannot inherit the
-- previous one's world: catalog ids a monetization case configured, and the injected roster seams.
local function resetSingletons(): ()
	MonetizationService._ownsPass = nil
	for _, entry in MonetizationService.PASSES do
		entry.gamePassId = 0
	end
	for _, entry in MonetizationService.PRODUCTS do
		entry.developerProductId = 0
	end
	SalvageService._players = nil
	OfflineService._players = nil
	LeaderboardService._players = nil
end

-- Stand up the entire game. Mirrors src/server/Context.build + the service list in
-- src/server/init.server.luau, minus only the parts that dereference `game` (the Roblox event
-- wiring), which are replaced by the explicit lifecycle drivers below.
local function newGame(options: any?): any
	local opts: any = options or {}
	resetSingletons()

	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	local config = testConfig()
	-- MockStore reads `yieldOnUpdate` off this LIVE table on every update, so the forced yield inside
	-- the critical section is armed only for the racing part of a case.
	local storeOptions: any = { clock = clock, config = config, yieldOnUpdate = false }
	local store = Mocks.store(storeOptions)
	local data = DataService.new(store, clock, config, Mocks.logWarn)
	-- Constructed in the SAME order Context.build constructs them: analytics FIRST, because
	-- EconomyService emits currency_earned / currency_spent through it.
	local analytics = AnalyticsService.new(clock)
	local economy = EconomyService.new(analytics)
	local gate = Mocks.gate(clock)

	local registry = Net.newRegistry()
	local registeredNames: { string } = {}
	local pushes: { any } = {}

	local net: any = {}
	function net.register(_self: any, action: any): ()
		-- The REAL registry: a duplicate action name is a boot-time error there, exactly as on the wire.
		registry:register(action)
		table.insert(registeredNames, action.name)
	end
	function net.fireClient(_self: any, player: any, channel: string, payload: any): ()
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local context: any = {
		isServer = true,
		clock = clock,
		config = config,
		data = data,
		persistenceDegraded = false,
		net = net,
		gate = gate,
		security = nil,
		flags = nil,
		monetization = nil,
		analytics = analytics,
		economy = economy,
	}

	-- ── the bootstrap's service list, in ITS order ───────────────────────────────────────────────
	-- 1. PlayerLifecycle claims PlayerRemoving BEFORE data/analytics Start (A10b). Its Start is
	--    Roblox-only (it connects the signal), so the claim is made here and `leave` below runs the
	--    real `onRemoving` sequence — which is the pure function A10b extracted for exactly this.
	context.playerRemovingOwner = PlayerLifecycle
	-- 2. NetServer / 3. DataService Start are Roblox-only event wiring; `join`/`leave` drive it.
	-- 4. AnalyticsService:Start's Lune-safe half is the seam-identity invariant. Keep it: a seam that
	--    is declared but never assigned is a nil every emit falls through.
	analytics:assertInstalled(context)
	economy:Start(context)
	-- 5. The features, in build-batch order. Seam providers first (depth -> salvage -> plot).
	DepthService:Start(context)
	SalvageService:Start(context)
	PlotService:Start(context)
	DailyDropService:Start(context)
	StructuresShopService:Start(context)
	OfflineService:Start(context)
	ResurfaceService:Start(context)
	LeaderboardService:Start(context)
	MonetizationService:Start(context)

	if opts.plotCount ~= nil then
		PlotService:build(opts.plotCount)
	end

	local g: any = {
		clock = clock,
		config = config,
		store = store,
		storeOptions = storeOptions,
		data = data,
		analytics = analytics,
		economy = economy,
		gate = gate,
		net = net,
		registry = registry,
		registeredNames = registeredNames,
		pushes = pushes,
		context = context,
		online = {} :: { any },
	}

	-- The injected rosters. In production these are the engine's Players service; a Tier-1 harness
	-- has no engine and must still drive a full server's tick / prune / leaderboard passes.
	SalvageService._players = function(): { any }
		return g.online
	end
	OfflineService._players = function(): { any }
		return g.online
	end
	LeaderboardService._players = function(): { any }
		return g.online
	end

	-- EVERY SEAM MUST BE LIVE. A nil seam is not a smaller test — it is a test of a no-op, and every
	-- cross-feature assertion below would pass vacuously against it.
	function g.assertWired(self: any): ()
		local ctx = self.context
		expectTrue(
			ctx.analytics ~= nil,
			"ctx.analytics is nil: no event in the game would be emitted"
		)
		expectTrue(
			ctx.economy ~= nil,
			"ctx.economy is nil: no balance in the game would be written"
		)
		expectTrue(ctx.plot ~= nil, "ctx.plot is nil: PlotService never installed its seam")
		expectTrue(
			ctx.salvage ~= nil,
			"ctx.salvage is nil: SalvageService never installed its seam"
		)
		expectTrue(ctx.depth ~= nil, "ctx.depth is nil: DepthService never installed its seam")
		for _, pair in
			{
				{ "plot", "plotIdFor" },
				{ "plot", "rootFor" },
				{ "plot", "ownerOf" },
				{ "plot", "releaseFor" },
				{ "salvage", "rateFor" },
				{ "salvage", "capacityFor" },
				{ "salvage", "disarmFor" },
				{ "depth", "valueMultiplier" },
				{ "depth", "tierYFor" },
				{ "depth", "hullRatingOf" },
			}
		do
			local seam = ctx[pair[1]]
			expectTrue(
				seam ~= nil and type(seam[pair[2]]) == "function",
				`ctx.{pair[1]}:{pair[2]} is missing — its consumers would silently read nothing`
			)
		end
	end

	-- The ActionContext NetServer.actionContext builds, field for field.
	function g.actionCtx(self: any, player: any): any
		local ctx = self.context
		return {
			player = player,
			clock = ctx.clock,
			data = ctx.data,
			security = ctx.security,
			flags = ctx.flags,
			analytics = ctx.analytics,
			monetization = ctx.monetization,
			economy = ctx.economy,
			plot = ctx.plot,
			salvage = ctx.salvage,
			depth = ctx.depth,
		}
	end

	-- THE inbound pipeline: the same pure Net.dispatch NetServer runs, over the same spine Gate.
	function g.invoke(self: any, actionName: string, player: any, payload: any?): any
		return Net.dispatch(self.registry, self.gate, self:actionCtx(player), actionName, payload)
	end

	-- The same pipeline WITHOUT the anti-spam token bucket (Net.dispatch is nil-tolerant on `gate`).
	-- Used ONLY by the pacing simulator, which fires hundreds of legitimate, seconds-apart actions in
	-- a tight loop: the bucket would refuse them for a reason that has nothing to do with pacing, and
	-- padding the clock to appease it would corrupt the number being measured. Every CORRECTNESS case
	-- in this file goes through the gated `invoke`.
	function g.invokeUngated(self: any, actionName: string, player: any, payload: any?): any
		return Net.dispatch(self.registry, nil, self:actionCtx(player), actionName, payload)
	end

	function g.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	function g.blob(self: any, player: any): any
		local got = self.data:get(player)
		expect(got):toBeOk()
		return (got :: any).value
	end

	function g.credits(self: any, player: any): number
		return self:blob(player).currencies.Credits or 0
	end

	function g.pearls(self: any, player: any): number
		return self:blob(player).currencies.Pearls or 0
	end

	function g.lifetime(self: any, player: any): number
		return self:blob(player).stats.lifetimeCredits
	end

	-- The DERIVED running income rate, read through the SAME ctx.salvage seam the tick, the shop, the
	-- offline window and the prestige preview all read. Never a persisted field.
	function g.rateSeam(self: any, player: any): number
		return self.context.salvage:rateFor(self:blob(player))
	end

	function g.capacitySeam(self: any, player: any): number
		return self.context.salvage:capacityFor(self:blob(player))
	end

	-- TEST SETUP ONLY: a direct balance write, deliberately NOT through ctx.economy. It exists to
	-- compress hours of legitimate salvage into one statement for cases whose subject is something
	-- else. Because it bypasses the economy seam it moves NEITHER stats.lifetimeCredits NOR any
	-- analytics event — which is exactly what makes it safe to use in the cases that assert those.
	function g.fund(self: any, player: any, currency: string, amount: number): ()
		local written = self.data:update(player, function(blob: any): any
			blob.currencies[currency] = (blob.currencies[currency] or 0) + amount
			return blob
		end)
		expect(written):toBeOk()
	end

	-- TEST SETUP ONLY: set a persisted flag the way MonetizationService would, when the case's
	-- subject is the READER rather than the grant. The grant path itself is driven for real below.
	function g.setFlag(self: any, player: any, flag: string, value: boolean): ()
		local written = self.data:update(player, function(blob: any): any
			blob.flags[flag] = value
			return blob
		end)
		expect(written):toBeOk()
	end

	-- The bootstrap's join hooks, in the order the service list connects them. Every one of these is
	-- a REAL production entry point; only the `task.spawn(...)` around them is Roblox's.
	function g.runJoinHooks(self: any, player: any): ()
		self.analytics:onPlayerAdded(self.data, player)
		SalvageService:armOnJoin(self.context, player)
		self.lastClaim = PlotService:claimOnJoin(self.context, player)
		OfflineService:prepareOnJoin(self.context, player)
		MonetizationService:syncOnJoin(self.context, player)
	end

	-- Install a session WITHOUT running any join hook. This is the state a request issued "the instant
	-- the player joins" actually races.
	function g.joinRaw(self: any, userId: number, name: string?): any
		local player = Mocks.player(userId, name)
		self.data:beginJoin(player)
		local loaded = self.data:loadSession(player)
		expect(loaded):toBeOk()
		expectTrue(
			self.data:finishJoin(player, loaded),
			"finishJoin reported the player left mid-load"
		)
		table.insert(self.online, player)
		-- DataService.Start pushes the client-safe view once, on load.
		self.net:fireClient(player, "data", Types.toView((loaded :: any).value.data))
		return player
	end

	function g.join(self: any, userId: number, name: string?): any
		local player = self:joinRaw(userId, name)
		self:runJoinHooks(player)
		return player
	end

	-- THE pinned leave sequence (A10b): analytics session_end -> plot release -> salvage disarm ->
	-- data session release. The real function, not a re-creation of it.
	function g.leave(self: any, player: any): ()
		PlayerLifecycle:onRemoving(self.context, player)
		for index, present in self.online do
			if present == player then
				table.remove(self.online, index)
				break
			end
		end
	end

	function g.eventsOf(self: any, name: string): { any }
		return self.analytics:eventsOfType(name)
	end

	function g.countEvents(self: any, name: string): number
		return #self.analytics:eventsOfType(name)
	end

	function g.lastEvent(self: any, name: string): any
		local list = self.analytics:eventsOfType(name)
		return list[#list]
	end

	function g.lastPush(self: any): any
		return self.pushes[#self.pushes]
	end

	-- A REAL dev-product purchase through the REAL receipt handler. Used to fund the long-run cases,
	-- so even the funding is a production earn path (it moves stats.lifetimeCredits through
	-- ctx.economy and emits currency_earned + purchase, exactly as a live sale would).
	function g.buyCreditPack(self: any, player: any, productKey: string, receiptId: string): any
		local entry = MonetizationService:productFor(productKey)
		expectTrue(entry ~= nil, `no dev product named "{productKey}"`)
		if (entry :: any).developerProductId <= 0 then
			MonetizationService:setProductId(productKey, 900000 + #self.registeredNames)
		end
		local outcome = MonetizationService:processReceipt(self.context, player, {
			PurchaseId = receiptId,
			ProductId = (MonetizationService:productFor(productKey) :: any).developerProductId,
			PlayerId = player.UserId,
			CurrencySpent = 99,
		})
		return outcome
	end

	return g
end

-- ── the catalog / ladder facts this file reads off the SERVER (never re-declares) ────────────────

local function catalogCost(key: string, level: number): number
	local entry = StructuresShopService.CATALOG[key]
	expectTrue(entry ~= nil, `no catalog entry "{key}"`)
	return StructuresShopService:nextCostOf(entry, level)
end

local function tierCost(index: number): number
	return DepthService.TIERS[index].cost
end

-- Buy one level of `key` through the REAL wire, advancing a beat first so the spine's anti-spam
-- bucket (a legitimate defence against a click flood, not against a scripted setup) refills.
local function buy(g: any, player: any, key: string): any
	g.clock:advance(1)
	return g:invoke(Net.Actions.BuyStructure, player, { key = key })
end

local function descend(g: any, player: any): any
	g.clock:advance(5)
	return g:invoke(Net.Actions.Descend, player, nil)
end

-- Raise this player to `targetTier` the way a player does: buy the hull plates the pressure gate
-- demands, fund the Credits, and DESCEND through every rung. There is no shortcut — the ladder is
-- strictly sequential by construction, which is itself asserted below.
local function climbTo(g: any, player: any, targetTier: number): ()
	-- Resumable: starts from whatever rung the player is actually standing on, so a case that already
	-- descended by hand can hand the rest of the ladder over without skipping (or re-trying) a rung.
	for tier = DepthService:tierOf(g:blob(player)) + 1, targetTier do
		local required = DepthService.TIERS[tier].hullMin
		while g.context.depth:hullRatingOf(g:blob(player)) < required do
			local level = StructuresShopService:levelOf(g:blob(player), "hull")
			g:fund(player, "Credits", catalogCost("hull", level))
			expect(buy(g, player, "hull")):toBeOk()
		end
		g:fund(player, "Credits", tierCost(tier))
		local moved = descend(g, player)
		expect(moved):toBeOk()
		expect((moved :: any).value.tier):toBe(tier)
	end
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] the whole game stands up with every seam live", function()
	it("every ctx seam a service reads is installed and carries its methods", function()
		local g = newGame()
		g:assertWired()
	end)

	it("every action the Net contract names is registered exactly once on ONE registry", function()
		local g = newGame()
		local seen: { [string]: number } = {}
		for _, name in g.registeredNames do
			seen[name] = (seen[name] or 0) + 1
		end
		for key, name in Net.Actions do
			expectTrue(
				seen[name] == 1,
				`Net.Actions.{key} ("{name}") is registered {tostring(seen[name])} times — the whole `
					.. "game booted without it"
			)
			expectTrue(
				g.registry:get(name) ~= nil,
				`Net.Actions.{key} ("{name}") is not resolvable on the registry Net.dispatch reads`
			)
		end
	end)

	it("an unknown action is refused by the real pipeline (no silent handler)", function()
		local g = newGame()
		local player = g:join(1)
		expect(g:invoke("definitely.not.an.action", player, nil)):toBeErr(
			Result.Codes.UnknownAction
		)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] CORE LOOP, end to end, in one session", function()
	-- The spec's "## Core loop", step for step:
	--   1. Join -> a free dome plot is claimed for you at Depth 1 and its pad lights up.
	--   2. Buy a salvage drone -> it hauls wreck fragments to your smelter.
	--   3. The smelter converts fragments -> Credits, continuously.
	--   4. Spend Credits on more drones / conveyor / smelter -> income rises.
	--   5. Buy the Depth unlock -> the dome descends -> repeat -> resurface for Pearls.
	-- EVERY step asserts that the state MOVED THE RIGHT WAY, so a step that silently no-ops fails.
	it("claim -> salvage -> buy -> descend -> resurface, and loop_completed fires", function()
		local g = newGame()
		g:assertWired()
		local player = g:join(1)

		-- ── 1. JOIN: a dome is claimed, and it is claimed AT DEPTH 1 ──────────────────────────────
		expect(g.lastClaim):toBeOk()
		local claimed = (g.lastClaim :: any).value
		expectTrue(claimed.held, "the join hook reported no dome held")
		expectTrue(claimed.plotId ~= "", "the join hook claimed an empty plot id")
		expect(g:blob(player).plot.plotId):toBe(claimed.plotId)
		expect(g.context.plot:plotIdFor(player)):toBe(claimed.plotId)
		expect(g.context.plot:ownerOf(claimed.plotId)):toBe(player.UserId)
		-- AMENDMENT A1: the dome is placed at the Y of the PERSISTED tier, read through ctx.depth.
		expect(claimed.y):toBe(g.context.depth:tierYFor(g:blob(player)))
		expect(claimed.y):toBe(DepthService.TIERS[1].y)

		-- ── 2/3. THE SMELTER YIELDS CREDITS. The starter drone is the seed of the loop. ───────────
		local opening = g:invoke(Net.Actions.FetchSalvage, player, nil)
		expect(opening):toBeOk()
		local baseRate = (opening :: any).value.rate
		expectGreater(
			baseRate,
			0,
			"a fresh dome has no income at all — the loop has no entry point"
		)

		g.clock:advance(120)
		local creditsBefore = g:credits(player)
		local lifetimeBefore = g:lifetime(player)
		local collected = g:invoke(Net.Actions.CollectSmelter, player, nil)
		expect(collected):toBeOk()
		local smelted = (collected :: any).value.collected
		expectClose(smelted, baseRate * 120, "the smelter did not convert 120s of drone output")
		expectClose(
			g:credits(player),
			creditsBefore + smelted,
			"the smelt did not reach the balance"
		)
		expectClose(
			g:lifetime(player),
			lifetimeBefore + smelted,
			"the smelt did not reach stats.lifetimeCredits"
		)

		-- ── 4. A PURCHASE RAISES THE RUNNING RATE (a DELTA, never a persisted field) ──────────────
		g:fund(player, "Credits", catalogCost("drones", 0))
		local rateBeforeDrone = g:rateSeam(player)
		local spentBefore = g:credits(player)
		local bought = buy(g, player, "drones")
		expect(bought):toBeOk()
		local buyInfo = (bought :: any).value
		expectClose(
			g:credits(player),
			spentBefore - buyInfo.cost,
			"the purchase did not debit exactly the server-derived cost"
		)
		expectGreater(
			g:rateSeam(player),
			rateBeforeDrone,
			"buying a drone did not move the running income rate — the purchasable is INERT"
		)
		expectGreater(
			buyInfo.effectDelta,
			0,
			"the buy reply reported no delta on its own observable"
		)

		-- ── 5. THE DEPTH UNLOCK. Pressure gate first: Credits alone must not be enough. ───────────
		g:fund(player, "Credits", tierCost(2) * 4)
		local refused = descend(g, player)
		expect(refused):toBeErr(Result.Codes.PrereqUnmet)

		local hullBefore = g.context.depth:hullRatingOf(g:blob(player))
		g:fund(player, "Credits", catalogCost("hull", 0))
		expect(buy(g, player, "hull")):toBeOk()
		expectGreater(
			g.context.depth:hullRatingOf(g:blob(player)),
			hullBefore,
			"buying hull plating did not move the pressure rating the gate reads"
		)

		local rateAtTier1 = g:rateSeam(player)
		local descended = descend(g, player)
		expect(descended):toBeOk()
		local descendInfo = (descended :: any).value
		expect(descendInfo.tier):toBe(2)
		expect(g:blob(player).upgrades.depth):toBe(2)
		expectGreater(
			descendInfo.valueMultiplier,
			descendInfo.previousValueMultiplier,
			"descending did not raise the salvage value multiplier"
		)
		expectGreater(
			g:rateSeam(player),
			rateAtTier1,
			"the depth tier's value multiplier never reached the running income rate"
		)
		expectTrue(descendInfo.y < descendInfo.previousY, "the dome did not descend in the world")

		-- loop_completed: the terminal step of the core loop, ONCE per session.
		expect(g:countEvents("loop_completed")):toBe(1)
		local loop = g:lastEvent("loop_completed")
		expect(loop.payload.userId):toBe(player.UserId)
		expect(loop.payload.tier):toBe(2)
		expect(g:countEvents("progression")):toBe(1)

		-- ── the rest of the ladder, then RESURFACE FOR PEARLS ─────────────────────────────────────
		climbTo(g, player, 5)
		expect(g:blob(player).upgrades.depth):toBe(5)
		-- Still exactly one loop_completed for this session, however many rungs were climbed.
		expect(g:countEvents("loop_completed")):toBe(1)

		-- A real lifetime aggregate, so the Pearl formula has something to work with.
		expect(g:buyCreditPack(player, "creditPackL", "loop-fund-1").decision):toBe(
			MonetizationService.GRANTED
		)

		local lifetimeAtPrestige = g:lifetime(player)
		local pearlsBefore = g:pearls(player)
		g.clock:advance(11)
		local surfaced = g:invoke(Net.Actions.Resurface, player, nil)
		expect(surfaced):toBeOk()
		local prestige = (surfaced :: any).value
		expectGreater(prestige.pearls, 0, "the resurface minted no Pearls")
		expectClose(
			g:pearls(player),
			pearlsBefore + prestige.pearls,
			"the minted Pearls never reached the balance"
		)
		expect(g:blob(player).resurfaces):toBe(1)
		expect(g:blob(player).upgrades.depth):toBe(1)
		expect(g:credits(player)):toBe(0)
		expect(g:blob(player).upgrades.drones):toBe(0)
		-- The leaderboard's ranking key SURVIVES the reset.
		expect(g:lifetime(player)):toBe(lifetimeAtPrestige)
		expect(g:countEvents("progression")):toBe(5) -- 4 descends + this resurface

		-- ── the session closes cleanly ────────────────────────────────────────────────────────────
		g:leave(player)
		local ended = g:lastEvent("session_end")
		expectTrue(ended ~= nil, "no session_end was emitted for a completed session")
		expect(ended.payload.stale):toBe(false)
		expect(ended.payload.userId):toBe(player.UserId)
	end)

	it("the permanent prestige multiplier reaches the running rate after resurfacing", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 2_000_000)
		climbTo(g, player, 5)

		local rateBefore = g.context.salvage:rateFor({
			currencies = {},
			stats = { lifetimeCredits = 0 },
			upgrades = {},
			flags = {},
			smelter = { storedCredits = 0, lastTickUnix = 0 },
			resurfaces = g:blob(player).resurfaces,
			boostExpiresUnix = 0,
		})
		g.clock:advance(11)
		expect(g:invoke(Net.Actions.Resurface, player, nil)):toBeOk()
		local rateAfter = g.context.salvage:rateFor({
			currencies = {},
			stats = { lifetimeCredits = 0 },
			upgrades = {},
			flags = {},
			smelter = { storedCredits = 0, lastTickUnix = 0 },
			resurfaces = g:blob(player).resurfaces,
			boostExpiresUnix = 0,
		})
		expectGreater(
			rateAfter,
			rateBefore,
			"data.resurfaces is written by the prestige and never read by the rate — an INERT prestige"
		)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] every cross-feature seam reaches its consumer", function()
	-- Each case names a PRODUCER, a CONSUMER, and the consumer's OBSERVABLE. The assertion is always
	-- a delta on the consumer's output, never that the producer's persisted field changed.

	it("ctx.depth:valueMultiplier -> salvage's running rate (per tier)", function()
		local g = newGame()
		local player = g:join(1)
		local before = g:rateSeam(player)
		g:fund(player, "Credits", 2_000_000)
		climbTo(g, player, 3)
		local after = g:rateSeam(player)
		expectClose(
			after / before,
			DepthService.TIERS[3].valueMultiplier / DepthService.TIERS[1].valueMultiplier,
			"the tier value multiplier did not reach the rate with the ladder's own factor"
		)
	end)

	it("ctx.depth:hullRatingOf -> the structures shop can SELL `hull` at all", function()
		local g = newGame()
		local player = g:join(1)
		local shop = g:invoke(Net.Actions.FetchStructures, player, nil)
		expect(shop):toBeOk()
		local hullRow: any = nil
		for _, row in (shop :: any).value.entries do
			if row.key == "hull" then
				hullRow = row
			end
		end
		expectTrue(hullRow ~= nil, "the shop does not list `hull` at all")
		expectTrue(
			hullRow.effect.measured,
			"`hull`'s declared consumer (ctx.depth) answered nothing — the entry is UNPROVEN and the "
				.. "shop refuses every sale of it"
		)
		expectGreater(hullRow.effect.delta, 0, "buying `hull` moves nothing its consumer can see")
		g:fund(player, "Credits", hullRow.nextCost)
		expect(buy(g, player, "hull")):toBeOk()
	end)

	it("ctx.depth:tierYFor -> the dome PlotService places (and plot.fetch reports)", function()
		local g = newGame()
		local player = g:join(1)
		local atSurface = g:invoke(Net.Actions.FetchPlot, player, nil)
		expect(atSurface):toBeOk()
		expect((atSurface :: any).value.y):toBe(DepthService.TIERS[1].y)

		g:fund(player, "Credits", 2_000_000)
		climbTo(g, player, 2)
		local deeper = g:invoke(Net.Actions.FetchPlot, player, nil)
		expect(deeper):toBeOk()
		expect((deeper :: any).value.y):toBe(DepthService.TIERS[2].y)
		expectTrue(
			(deeper :: any).value.y < (atSurface :: any).value.y,
			"the persisted tier never reached the dome's world placement"
		)
	end)

	it("ctx.salvage:rateFor / :capacityFor -> the structures shop's reported readings", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 100_000)

		local capacityBefore = g:capacitySeam(player)
		local bought = buy(g, player, "smelter")
		expect(bought):toBeOk()
		expectGreater(
			g:capacitySeam(player),
			capacityBefore,
			"buying the smelter tank did not move ctx.salvage:capacityFor"
		)
		expect((bought :: any).value.observable):toBe("capacity")
		expectGreater(
			(bought :: any).value.effectDelta,
			0,
			"the buy reply reported no capacity delta"
		)

		local rateBefore = g:rateSeam(player)
		local conveyor = buy(g, player, "conveyor")
		expect(conveyor):toBeOk()
		expectGreater(
			g:rateSeam(player),
			rateBefore,
			"buying the conveyor did not move ctx.salvage:rateFor"
		)
	end)

	it("ctx.salvage:capacityFor -> the CAP on the offline away-window grant", function()
		-- Two identical away windows, one with a bigger tank. The offline grant must rise with the
		-- capacity — that is the whole design reason the cap is the smelter's and not a constant.
		local function awayGrantWithSmelterLevels(levels: number): number
			local g = newGame()
			local player = g:join(1)
			if levels > 0 then
				g:fund(player, "Credits", 1_000_000)
				for _ = 1, levels do
					expect(buy(g, player, "smelter")):toBeOk()
				end
			end
			g:leave(player)
			g.clock:advance(30 * DAY_SECONDS) -- far past any plausible fill time: the cap decides
			local back = g:join(1)
			local peeked = g:invoke(Net.Actions.FetchOffline, back, nil)
			expect(peeked):toBeOk()
			expectTrue(
				(peeked :: any).value.capped,
				"a 30-day away window was not capped — the cap is not being applied at all"
			)
			return (peeked :: any).value.amount
		end
		local small = awayGrantWithSmelterLevels(0)
		local large = awayGrantWithSmelterLevels(3)
		expectGreater(
			large,
			small,
			"upgrading the smelter did not raise the offline grant — ctx.salvage:capacityFor never "
				.. "reached OfflineService"
		)
	end)

	it("flags['gamepass.doubleCredits'] -> x2 on the running rate (server-granted only)", function()
		local g = newGame()
		local player = g:join(1)
		local before = g:rateSeam(player)
		-- GRANTED SERVER-SIDE, through the real ownership probe, never from a client action.
		MonetizationService:setGamePassId("doubleCredits", 4242)
		MonetizationService._ownsPass = function(_userId: number, gamePassId: number): boolean
			return gamePassId == 4242
		end
		local synced = MonetizationService:syncPasses(g.context, player)
		expect(synced):toBeOk()
		expect((synced :: any).value.granted):toBe(1)
		expect(g:blob(player).flags["gamepass.doubleCredits"]):toBe(true)
		expectClose(
			g:rateSeam(player),
			before * 2,
			"the 2x Credits gamepass never reached the rate"
		)
		local purchase = g:lastEvent("purchase")
		expectTrue(purchase ~= nil, "granting a gamepass emitted no `purchase` event")
		expect(purchase.payload.kind):toBe("gamepass")
		expect(purchase.payload.flag):toBe("gamepass.doubleCredits")
	end)

	it("flags['gamepass.autoCollect'] -> the tick empties the smelter into the balance", function()
		local g = newGame()
		local player = g:join(1)
		g.clock:advance(60)
		g:setFlag(player, "gamepass.autoCollect", true)

		local creditsBefore = g:credits(player)
		local lifetimeBefore = g:lifetime(player)
		g.clock:advance(60)
		local ticked = SalvageService:tickPlayer(g.context, player)
		expect(ticked):toBeOk()
		expectGreater(
			(ticked :: any).value.collected,
			0,
			"the auto-collect gamepass did not make the tick empty the smelter"
		)
		expectGreater(g:credits(player), creditsBefore, "auto-collect banked nothing")
		expectGreater(
			g:lifetime(player),
			lifetimeBefore,
			"auto-collect skipped the lifetime counter — it is not going through the ONE grant path"
		)
		expect(g:blob(player).smelter.storedCredits):toBe(0)
	end)

	it("flags['gamepass.vipTrench'] -> the exclusive tier is gated, then reachable", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 10_000_000)
		climbTo(g, player, 5)
		-- Hull rated for the VIP trench, Credits in hand, flag ABSENT.
		while g.context.depth:hullRatingOf(g:blob(player)) < DepthService.TIERS[6].hullMin do
			expect(buy(g, player, "hull")):toBeOk()
		end
		expect(descend(g, player)):toBeErr(Result.Codes.PrereqUnmet)
		expect(g:blob(player).upgrades.depth):toBe(5)

		g:setFlag(player, "gamepass.vipTrench", true)
		local entered = descend(g, player)
		expect(entered):toBeOk()
		expect((entered :: any).value.tier):toBe(6)
	end)

	it("boostExpiresUnix (a dev product) -> x2 on the rate, and it SURVIVES A REJOIN", function()
		local g = newGame()
		local player = g:join(1)
		local plain = g:rateSeam(player)

		MonetizationService:setProductId("boost30", 77001)
		local outcome = MonetizationService:processReceipt(g.context, player, {
			PurchaseId = "boost-1",
			ProductId = 77001,
			PlayerId = player.UserId,
		})
		expect(outcome.decision):toBe(MonetizationService.GRANTED)
		expectClose(g:rateSeam(player), plain * 2, "the paid 2x boost never reached the rate")

		-- Leave, come back well inside the 30 minutes: the EXPIRY IS PERSISTED, so the boost is still
		-- running. (This is the half a per-feature gate cannot see: it never releases the session.)
		g:leave(player)
		g.clock:advance(600)
		local back = g:join(1)
		expectClose(
			g:rateSeam(back),
			plain * 2,
			"the persisted boost expiry did not survive the rejoin"
		)

		g.clock:advance(MonetizationService.BOOST_SECONDS)
		expectClose(g:rateSeam(back), plain, "an expired boost is still multiplying the rate")
	end)

	it("ctx.plot:releaseFor -> the pinned leave sequence actually frees the dome", function()
		local g = newGame({ plotCount = 2 })
		local one = g:join(1)
		local two = g:join(2)
		expect(g.context.plot:plotIdFor(one)).never:toBe(nil)
		expect(g.context.plot:plotIdFor(two)).never:toBe(nil)
		expect(g.context.plot:plotIdFor(one)).never:toBe(g.context.plot:plotIdFor(two))

		local held = g.context.plot:plotIdFor(one)
		g:leave(one)
		expect(g.context.plot:ownerOf(held)):toBe(nil)
		expect(g.context.plot:plotIdFor(one)):toBe(nil)
	end)

	it("stats.lifetimeCredits -> the leaderboard's ranking, ACROSS a prestige", function()
		-- The reset hazard ResurfaceService's own header names: the wipe zeroes currencies.Credits, so
		-- a board that ranked on the SPENDABLE balance would rank the player who just prestiged LAST.
		-- Only a test that earns through one feature and resets through another can see it.
		local g = newGame()
		local rich = g:join(1)
		local poor = g:join(2)
		expect(g:buyCreditPack(rich, "creditPackL", "board-1").decision):toBe(
			MonetizationService.GRANTED
		)
		expect(g:buyCreditPack(poor, "creditPackS", "board-2").decision):toBe(
			MonetizationService.GRANTED
		)

		local board = g:invoke(Net.Actions.FetchLeaderboard, rich, nil)
		expect(board):toBeOk()
		expect((board :: any).value.playerCount):toBe(2)
		expect((board :: any).value.entries[1].userId):toBe(rich.UserId)
		expect((board :: any).value.you.rank):toBe(1)
		expect((board :: any).value.you.lifetimeCredits):toBe(g:lifetime(rich))

		g:fund(rich, "Credits", 2_000_000)
		climbTo(g, rich, 5)
		g.clock:advance(11)
		expect(g:invoke(Net.Actions.Resurface, rich, nil)):toBeOk()
		expect(g:credits(rich)):toBe(0) -- the spendable balance is gone...

		g.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
		local after = g:invoke(Net.Actions.FetchLeaderboard, rich, nil)
		expect(after):toBeOk()
		expect((after :: any).value.you.rank):toBe(1)
		expectGreater(
			(after :: any).value.entries[1].lifetimeCredits,
			(after :: any).value.entries[2].lifetimeCredits,
			"the prestiged player was demoted — the board is ranking on the spendable balance, not on "
				.. "the monotonic lifetime aggregate"
		)
	end)

	it(
		"gamepass -> salvage's rate -> the OFFLINE away-window grant (a three-feature chain)",
		function()
			-- The away window is `ctx.salvage:rateFor(blob) * elapsed`, and that rate composes the
			-- gamepass. A short window keeps the smelter cap out of it, so what is being measured is the
			-- RATE reaching OfflineService and nothing else.
			local function awayGrant(withDoubleCredits: boolean): number
				local g = newGame()
				local player = g:join(1)
				if withDoubleCredits then
					g:setFlag(player, "gamepass.doubleCredits", true)
				end
				g:leave(player)
				g.clock:advance(120)
				local back = g:join(1)
				local peeked = g:invoke(Net.Actions.FetchOffline, back, nil)
				expect(peeked):toBeOk()
				expectTrue(
					not (peeked :: any).value.capped,
					"the window hit the smelter cap — this case measures the RATE, not the ceiling"
				)
				return (peeked :: any).value.amount
			end
			local plain = awayGrant(false)
			local doubled = awayGrant(true)
			expectGreater(plain, 0, "the plain away window paid nothing")
			expectClose(
				doubled,
				plain * 2,
				"the 2x Credits gamepass never reached the offline away-window grant"
			)
		end
	)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe(
	"[integration] the lifetime aggregate rises on EVERY earn, never on a spend or a reset",
	function()
		-- stats.lifetimeCredits is the leaderboard's ranking key and the Pearl formula's input. The
		-- contract is "lifetime on all earns, never on spend/reset", and it is only observable ACROSS
		-- features: five services earn through the one seam and two spend through it.
		it(
			"smelt, offline, daily and a Credit pack each move it by EXACTLY the amount granted",
			function()
				local g = newGame()
				local player = g:join(1)

				-- smelt
				g.clock:advance(100)
				local before = g:lifetime(player)
				local collected = g:invoke(Net.Actions.CollectSmelter, player, nil)
				expect(collected):toBeOk()
				expectClose(
					g:lifetime(player) - before,
					(collected :: any).value.collected,
					"the smelt earn did not move lifetime by exactly what it granted"
				)

				-- daily
				before = g:lifetime(player)
				local daily = g:invoke(Net.Actions.ClaimDaily, player, nil)
				expect(daily):toBeOk()
				expectClose(
					g:lifetime(player) - before,
					(daily :: any).value.reward,
					"the daily drop did not move lifetime by exactly its reward"
				)

				-- a Credit pack (real money, real receipt)
				before = g:lifetime(player)
				local pack = g:buyCreditPack(player, "creditPackS", "lifetime-1")
				expect(pack.decision):toBe(MonetizationService.GRANTED)
				expectClose(
					g:lifetime(player) - before,
					pack.amount,
					"the Credit pack did not move lifetime by exactly what it granted"
				)

				-- offline (leave, time passes, rejoin, claim)
				g:leave(player)
				g.clock:advance(4 * HOUR_SECONDS)
				local back = g:join(1)
				before = g:lifetime(back)
				local away = g:invoke(Net.Actions.ClaimOffline, back, nil)
				expect(away):toBeOk()
				expectGreater((away :: any).value.amount, 0, "the away window paid nothing")
				expectClose(
					g:lifetime(back) - before,
					(away :: any).value.amount,
					"the offline claim did not move lifetime by exactly what it granted"
				)
			end
		)

		it("a duplicate collect / claim does not move it twice", function()
			local g = newGame()
			local player = g:join(1)
			g.clock:advance(100)
			expect(g:invoke(Net.Actions.CollectSmelter, player, nil)):toBeOk()
			local afterFirst = g:lifetime(player)
			expect(g:invoke(Net.Actions.CollectSmelter, player, nil)):toBeErr(
				Result.Codes.Insufficient
			)
			expect(g:lifetime(player)):toBe(afterFirst)

			expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeOk()
			local afterDaily = g:lifetime(player)
			expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeErr(Result.Codes.OnCooldown)
			expect(g:lifetime(player)):toBe(afterDaily)
		end)

		it("spends (structures, depth) and the resurface RESET leave it untouched", function()
			local g = newGame()
			local player = g:join(1)
			g:fund(player, "Credits", 2_000_000)
			expect(g:buyCreditPack(player, "creditPackM", "lifetime-2").decision):toBe(
				MonetizationService.GRANTED
			)

			local afterEarning = g:lifetime(player)
			expectGreater(afterEarning, 0, "the fixture never earned anything to begin with")

			expect(buy(g, player, "drones")):toBeOk()
			expect(g:lifetime(player)):toBe(afterEarning)

			climbTo(g, player, 5)
			expect(g:lifetime(player)):toBe(afterEarning)

			g.clock:advance(11)
			local surfaced = g:invoke(Net.Actions.Resurface, player, nil)
			expect(surfaced):toBeOk()
			expect(g:lifetime(player)):toBe(afterEarning)
			-- ...and the Pearls mint is NOT a Credits earn, so it must not move the counter either.
			expectGreater(g:pearls(player), 0, "the resurface minted no Pearls")
			expect(g:lifetime(player)):toBe(afterEarning)
		end)
	end
)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] the shared Credits balance under a CROSS-FEATURE race", function()
	-- The per-feature gates each raced ONE service against itself. Credits are credited by salvage,
	-- offline, daily and monetization and debited by structures and depth; only an interleave that
	-- crosses those services can double-spend the one balance they share.
	it("interleaved buy + descend + collect + daily + offline reconcile EXACTLY", function()
		local g = newGame()
		local player = g:join(1)
		-- Set the stage: an away window owed, a smelter with output in it, a daily drop available,
		-- hull rated for tier 2, and enough Credits that several of the debits can succeed.
		g:leave(player)
		g.clock:advance(6 * HOUR_SECONDS)
		local back = g:join(1)
		g:fund(back, "Credits", 100_000)
		expect(buy(g, back, "hull")):toBeOk()
		g.clock:advance(200) -- fills the smelter

		local startCredits = g:credits(back)
		local startLifetime = g:lifetime(back)
		local startDrones = StructuresShopService:levelOf(g:blob(back), "drones")

		local results: { [string]: any } = {}
		g:setYield(true)
		local cos = {
			coroutine.create(function()
				results.buyA = g:invokeUngated(Net.Actions.BuyStructure, back, { key = "drones" })
			end),
			coroutine.create(function()
				results.buyB = g:invokeUngated(Net.Actions.BuyStructure, back, { key = "drones" })
			end),
			coroutine.create(function()
				results.descend = g:invokeUngated(Net.Actions.Descend, back, nil)
			end),
			coroutine.create(function()
				results.collect = g:invokeUngated(Net.Actions.CollectSmelter, back, nil)
			end),
			coroutine.create(function()
				results.daily = g:invokeUngated(Net.Actions.ClaimDaily, back, nil)
			end),
			coroutine.create(function()
				results.offline = g:invokeUngated(Net.Actions.ClaimOffline, back, nil)
			end),
		}
		drain(cos)
		g:setYield(false)

		local credited = 0
		local debited = 0
		local buys = 0
		for name, res in results do
			expectTrue(type(res) == "table" and res.ok ~= nil, `{name} returned no Result at all`)
			if res.ok then
				if name == "buyA" or name == "buyB" then
					buys += 1
					debited += res.value.cost
				elseif name == "descend" then
					debited += res.value.cost
				elseif name == "collect" then
					credited += res.value.collected
				elseif name == "daily" then
					credited += res.value.reward
				elseif name == "offline" then
					credited += res.value.amount
				end
			end
		end

		expectGreater(credited, 0, "not one earn path succeeded — the race proved nothing")
		expectGreater(debited, 0, "not one spend path succeeded — the race proved nothing")
		expectClose(
			g:credits(back),
			startCredits + credited - debited,
			"the shared Credits balance does not reconcile against what the replies claimed — a "
				.. "cross-feature double-spend or a lost credit"
		)
		expectTrue(g:credits(back) >= 0, "the shared balance went negative")
		expectClose(
			g:lifetime(back) - startLifetime,
			credited,
			"the lifetime aggregate does not match the sum of the successful earns"
		)
		expect(StructuresShopService:levelOf(g:blob(back), "drones")):toBe(startDrones + buys)
		-- Every purchase priced its OWN step: n buys cost the sum of n CONSECUTIVE prices, never n
		-- copies of the same one.
		if buys == 2 then
			local a: any = results.buyA
			local b: any = results.buyB
			expectTrue(
				a.value.cost ~= b.value.cost,
				"two interleaved buys were charged the SAME price — the level was read outside the lock"
			)
		end
	end)

	it("spam-duplicated resurfaces mint exactly ONE batch of Pearls", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 2_000_000)
		climbTo(g, player, 5)
		expect(g:buyCreditPack(player, "creditPackL", "race-fund").decision):toBe(
			MonetizationService.GRANTED
		)

		local pearlsBefore = g:pearls(player)
		local resurfacesBefore = g:blob(player).resurfaces
		local results: { any } = {}

		g:setYield(true)
		local cos = {}
		for index = 1, 3 do
			table.insert(
				cos,
				coroutine.create(function()
					results[index] = g:invokeUngated(Net.Actions.Resurface, player, nil)
				end)
			)
		end
		table.insert(
			cos,
			coroutine.create(function()
				results[4] = g:invokeUngated(Net.Actions.BuyStructure, player, { key = "drones" })
			end)
		)
		drain(cos)
		g:setYield(false)

		local minted = 0
		local succeeded = 0
		for index = 1, 3 do
			local res: any = results[index]
			expectTrue(type(res) == "table" and res.ok ~= nil, "a resurface returned no Result")
			if res.ok then
				succeeded += 1
				minted += res.value.pearls
			else
				expect(res):toBeErr(Result.Codes.PrereqUnmet)
			end
		end
		expect(succeeded):toBe(1)
		expect(g:blob(player).resurfaces):toBe(resurfacesBefore + 1)
		expectClose(
			g:pearls(player),
			pearlsBefore + minted,
			"Pearls were duped: the balance does not match the ONE successful mint"
		)
		expectTrue(g:credits(player) >= 0, "the wipe left a negative Credits balance")
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe(
	"[integration] the RE-ENTRY lifecycle: earn -> leave -> time passes -> rejoin -> claim",
	function()
		-- No per-feature gate can reach this: each holds ONE session for the length of the test. The
		-- leave stamps timestamps.lastSeenUnix and releases the session; the rejoin loads it again. If a
		-- lifecycle write on JOIN clobbers that base before OfflineService reads it, the player receives
		-- ZERO and their whole away window is gone permanently and silently.
		it("a fresh player is owed NOTHING (no free smelter on a first join)", function()
			local g = newGame()
			local player = g:join(1)
			local peeked = g:invoke(Net.Actions.FetchOffline, player, nil)
			expect(peeked):toBeOk()
			expect((peeked :: any).value.amount):toBe(0)
			expect(g:invoke(Net.Actions.ClaimOffline, player, nil)):toBeErr(
				Result.Codes.Insufficient
			)
		end)

		it("the away window is PAID on the rejoin, at the rate x the real elapsed time", function()
			local g = newGame()
			local player = g:join(1)
			-- earn something first, so the session that leaves is a session that was played
			g.clock:advance(120)
			expect(g:invoke(Net.Actions.CollectSmelter, player, nil)):toBeOk()
			local leftAt = g.clock:unix()

			g:leave(player)
			expect(g.data:get(player)):toBeErr(Result.Codes.NoData)

			local away = 3 * HOUR_SECONDS
			g.clock:advance(away)
			local back = g:join(1)

			-- the leave really did stamp the base the away window is measured from
			expect(g.data:joinBaseFor(back)):toBe(leftAt)

			local peeked = g:invoke(Net.Actions.FetchOffline, back, nil)
			expect(peeked):toBeOk()
			local pending = (peeked :: any).value
			expect(pending.awaySeconds):toBe(away)
			local expected = math.min(g:rateSeam(back) * away, g:capacitySeam(back))
			expectClose(
				pending.amount,
				expected,
				"the away window's amount is not rate x elapsed, capped by the smelter"
			)
			expectGreater(
				pending.amount,
				0,
				"THE AWAY WINDOW PAID ZERO: a join-time lifecycle write clobbered the accrual base"
			)

			local creditsBefore = g:credits(back)
			local claimed = g:invoke(Net.Actions.ClaimOffline, back, nil)
			expect(claimed):toBeOk()
			expectClose(
				(claimed :: any).value.amount,
				pending.amount,
				"the claim paid a different amount"
			)
			expectClose(
				g:credits(back),
				creditsBefore + pending.amount,
				"the away window never reached the balance"
			)
			-- ONE-SHOT: the second claim of the same session pays nothing.
			expect(g:invoke(Net.Actions.ClaimOffline, back, nil)):toBeErr(Result.Codes.Insufficient)
		end)

		it(
			"an AUTOSAVE landing between the join and the claim does not erase the window",
			function()
				-- DataService.autosaveTick REWRITES timestamps.lastSeenUnix to now on every flush. A window
				-- read off the live blob after a flush reads "you were not away" and the earnings are gone
				-- with nothing left anywhere to recover them from. The base must be the LOAD-TIME snapshot.
				local g = newGame()
				local player = g:join(1)
				g:leave(player)
				g.clock:advance(2 * HOUR_SECONDS)

				local back = g:joinRaw(1) -- no join hooks yet: nothing has snapshotted anything
				local flushed = g.data:autosaveTick()
				expect(flushed.flushed):toBe(1)
				expect(g:blob(back).timestamps.lastSeenUnix):toBe(g.clock:unix()) -- the base on the blob is GONE

				local claimed = g:invoke(Net.Actions.ClaimOffline, back, nil)
				expect(claimed):toBeOk()
				expectGreater(
					(claimed :: any).value.amount,
					0,
					"an autosave between the join and the claim erased the away window"
				)
				expect((claimed :: any).value.awaySeconds):toBe(2 * HOUR_SECONDS)
			end
		)

		it("a claim issued BEFORE the session loads is refused, and loses nothing", function()
			local g = newGame()
			local player = g:join(1)
			g:leave(player)
			g.clock:advance(2 * HOUR_SECONDS)

			-- The instant the player joins: PlayerAdded has fired, loadSession has NOT resolved.
			local racer = Mocks.player(1)
			g.data:beginJoin(racer)
			local tooEarly = g:invoke(Net.Actions.ClaimOffline, racer, nil)
			expect(tooEarly):toBeErr(Result.Codes.NoData)

			-- ...and once it does resolve, the whole window is still owed. A claim served against
			-- half-loaded data would have consumed (or zeroed) it here.
			local loaded = g.data:loadSession(racer)
			expect(loaded):toBeOk()
			expectTrue(g.data:finishJoin(racer, loaded), "finishJoin reported a departure")
			table.insert(g.online, racer)

			local claimed = g:invoke(Net.Actions.ClaimOffline, racer, nil)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.awaySeconds):toBe(2 * HOUR_SECONDS)
			expectGreater(
				(claimed :: any).value.amount,
				0,
				"the window was consumed by the refused claim"
			)
		end)

		it("the online tick does NOT re-pay a window the offline claim already paid", function()
			-- The handoff: [lastSeenUnix, now] belongs to OfflineService, and SalvageService ARMS the
			-- session at join so its first accruing tick starts from now. Getting this wrong pays the
			-- same seconds twice, and only a leave/rejoin can show it.
			local g = newGame()
			local player = g:join(1)
			g:leave(player)
			g.clock:advance(2 * HOUR_SECONDS)
			local back = g:join(1)

			expect(g:blob(back).smelter.lastTickUnix):toBe(g.clock:unix())
			local claimed = g:invoke(Net.Actions.ClaimOffline, back, nil)
			expect(claimed):toBeOk()

			-- One second of ONLINE time may now accrue — and only one second's worth.
			g.clock:advance(1)
			local ticked = SalvageService:tickPlayer(g.context, back)
			expect(ticked):toBeOk()
			expectClose(
				(ticked :: any).value.credited,
				g:rateSeam(back) * 1,
				"the first online tick after a rejoin credited more than the seconds actually elapsed — "
					.. "the away window is being paid twice"
			)
		end)

		it(
			"a leave -> rejoin inside one tick pass re-ARMS (the disarm is in the pinned order)",
			function()
				local g = newGame()
				local player = g:join(1)
				g.clock:advance(60)
				g:leave(player)
				g.clock:advance(90 * 60)
				local back = g:join(1)
				-- Armed at the rejoin instant: an inherited `armed` flag would leave lastTickUnix at the
				-- pre-absence value and the very next tick would credit the whole away window online.
				expect(g:blob(back).smelter.lastTickUnix):toBe(g.clock:unix())
				local ticked = SalvageService:tickPlayer(g.context, back)
				expect(ticked):toBeOk()
				expect((ticked :: any).value.credited):toBe(0)
			end
		)
	end
)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] plot ownership is exclusive, released, and re-claimable", function()
	it("one player gets exactly one dome; a second claim is refused", function()
		local g = newGame()
		local player = g:join(1)
		local held = g.context.plot:plotIdFor(player)
		expectTrue(held ~= nil, "the join hook claimed nothing")
		expect(g:invoke(Net.Actions.ClaimPlot, player, nil)):toBeErr(Result.Codes.AlreadyClaimed)
		expect(g.context.plot:plotIdFor(player)):toBe(held)
	end)

	it(
		"a full server refuses with Unavailable, and the leave -> claim race hands it over",
		function()
			local g = newGame({ plotCount = 1 })
			local one = g:join(1)
			expect(g.context.plot:plotIdFor(one)):toBe("dome_1")

			local two = g:join(2)
			expect(g.lastClaim):toBeErr(Result.Codes.Unavailable)
			expect(g.context.plot:plotIdFor(two)):toBe(nil)
			expect(g:invoke(Net.Actions.ClaimPlot, two, nil)):toBeErr(Result.Codes.Unavailable)

			-- THE RACE: the holder leaves and the waiter claims in the same frame.
			g:leave(one)
			local taken = g:invoke(Net.Actions.ClaimPlot, two, nil)
			expect(taken):toBeOk()
			expect((taken :: any).value.plotId):toBe("dome_1")
			expect(g.context.plot:ownerOf("dome_1")):toBe(two.UserId)
			expect(g:blob(two).plot.plotId):toBe("dome_1")
		end
	)

	it("a rejoining player takes their OWN dome back when it is free", function()
		local g = newGame({ plotCount = 4 })
		local one = g:join(1)
		local two = g:join(2)
		local held = g.context.plot:plotIdFor(one)
		g:leave(one)
		local back = g:join(1)
		expect(g.context.plot:plotIdFor(back)):toBe(held)
		expect(g.context.plot:plotIdFor(two)).never:toBe(held)
	end)

	it("a client-named plot is REFUSED, not ignored (the plot-claim-hijack)", function()
		local g = newGame({ plotCount = 4 })
		local one = g:join(1)
		local two = Mocks.player(2)
		g.data:beginJoin(two)
		local loaded = g.data:loadSession(two)
		expect(loaded):toBeOk()
		g.data:finishJoin(two, loaded)
		expect(g:invoke(Net.Actions.ClaimPlot, two, { plotId = g.context.plot:plotIdFor(one) })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(g.context.plot:ownerOf(g.context.plot:plotIdFor(one))):toBe(one.UserId)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] the pressure gate holds and cannot be re-ordered around", function()
	it("Credits alone below the hull minimum is PrereqUnmet, not Insufficient", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", tierCost(2) * 100)
		expect(descend(g, player)):toBeErr(Result.Codes.PrereqUnmet)
		expect(g:blob(player).upgrades.depth):toBe(nil)
	end)

	it(
		"hull first, Credits short -> Insufficient (the two refusals stay distinguishable)",
		function()
			local g = newGame()
			local player = g:join(1)
			g:fund(player, "Credits", catalogCost("hull", 0))
			expect(buy(g, player, "hull")):toBeOk()
			expect(descend(g, player)):toBeErr(Result.Codes.Insufficient)
			expect(g:blob(player).upgrades.depth):toBe(nil)
		end
	)

	it("a deep hull does not skip a rung: the ladder is strictly sequential", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 5_000_000)
		-- Buy the hull for tier 5 FIRST, then try to descend: the target is derived from the
		-- snapshot's own tier, so no purchase order can reach tier 3 from tier 1.
		while g.context.depth:hullRatingOf(g:blob(player)) < DepthService.TIERS[5].hullMin do
			expect(buy(g, player, "hull")):toBeOk()
		end
		local first = descend(g, player)
		expect(first):toBeOk()
		expect((first :: any).value.tier):toBe(2)
		local second = descend(g, player)
		expect(second):toBeOk()
		expect((second :: any).value.tier):toBe(3)
	end)

	it("a payload naming a tier is REFUSED, not ignored (the depth-gate bypass)", function()
		local g = newGame()
		local player = g:join(1)
		g:fund(player, "Credits", 5_000_000)
		expect(g:invoke(Net.Actions.Descend, player, { tier = 5 })):toBeErr(Result.Codes.BadPayload)
		expect(g:blob(player).upgrades.depth):toBe(nil)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe(
	"[integration] no purchasable ships inert: every catalog entry moves its consumer",
	function()
		it("each catalog key moves the observable its declared CONSUMER reports", function()
			local g = newGame()
			local player = g:join(1)
			g:fund(player, "Credits", 5_000_000)
			g:fund(player, "Pearls", 5_000)

			for _, key in StructuresShopService.CATALOG_ORDER do
				local effect = StructuresShopService.EFFECTS[key]
				expectTrue(effect ~= nil, `catalog entry "{key}" declares no effect`)
				local seam = g.context[effect.consumer]
				expectTrue(
					seam ~= nil,
					`"{key}" names ctx.{effect.consumer} as its consumer and that seam is not installed`
				)
				local before = effect.measure(g:actionCtx(player), g:blob(player))
				expectTrue(
					before ~= nil,
					`"{key}"'s consumer could not measure "{effect.observable}"`
				)

				local bought = buy(g, player, key)
				expect(bought):toBeOk()
				local after = effect.measure(g:actionCtx(player), g:blob(player))
				expectTrue(after ~= nil, `"{key}"'s consumer stopped answering after the purchase`)
				expectGreater(
					after,
					before,
					`buying "{key}" did not move "{effect.observable}" as read through ctx.`
						.. `{effect.consumer} — the purchasable is INERT and the Credits are destroyed`
				)
				expectClose(
					(bought :: any).value.effectDelta,
					(after :: any) - (before :: any),
					`the buy reply's reported delta for "{key}" does not match the consumer's reading`
				)
			end
		end)

		it(
			"the boot-time inert audit reports every entry PROVEN on a fully wired server",
			function()
				local g = newGame()
				local report = StructuresShopService:auditEffects(g:actionCtx(Mocks.player(1)), nil)
				expect(#report):toBe(#StructuresShopService.CATALOG_ORDER)
				for _, row in report do
					expectTrue(
						row.measured,
						`the boot audit could not measure "{row.key}" — ctx.{row.consumer} is not installed`
					)
					expectTrue(row.moved, `the boot audit reports "{row.key}" INERT`)
					expectTrue(not row.unproven, `the boot audit reports "{row.key}" UNPROVEN`)
				end
			end
		)
	end
)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] the analytics taxonomy, end to end over ONE session", function()
	it("every event the spec mandates fires through the ONE emitter, with real payloads", function()
		local g = newGame()
		local player = g:join(1)

		-- session_start, on the loaded blob
		expect(g:countEvents("session_start")):toBe(1)
		local started = g:lastEvent("session_start")
		expect(started.payload.userId):toBe(player.UserId)
		expect(started.payload.joinCount):toBe(1)
		expect(started.at):toBe(g.clock:unix())

		-- currency_earned (smelt)
		g.clock:advance(200)
		expect(g:invoke(Net.Actions.CollectSmelter, player, nil)):toBeOk()
		local smelt = g:lastEvent("currency_earned")
		expect(smelt.payload.source):toBe("smelt")
		expect(smelt.payload.currency):toBe("Credits")
		expectGreater(smelt.payload.amount, 0, "currency_earned carried no amount")
		expect(smelt.payload.balance):toBe(g:credits(player))
		expect(smelt.payload.lifetimeCredits):toBe(g:lifetime(player))

		-- currency_earned (daily)
		expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeOk()
		expect(g:lastEvent("currency_earned").payload.source):toBe("daily")

		-- currency_spent (structure)
		g:fund(player, "Credits", 5_000_000)
		expect(buy(g, player, "drones")):toBeOk()
		local spent = g:lastEvent("currency_spent")
		expect(spent.payload.sink):toBe("structure.drones")
		expect(spent.payload.currency):toBe("Credits")
		expect(spent.payload.balance):toBe(g:credits(player))

		-- purchase (dev product) + currency_earned (product)
		local pack = g:buyCreditPack(player, "creditPackM", "taxonomy-1")
		expect(pack.decision):toBe(MonetizationService.GRANTED)
		local purchase = g:lastEvent("purchase")
		expect(purchase.payload.kind):toBe("product")
		expect(purchase.payload.key):toBe("creditPackM")
		expect(purchase.payload.receiptId):toBe("taxonomy-1")
		expect(g:lastEvent("currency_earned").payload.source):toBe("product.creditPackM")

		-- progression (depth) + loop_completed + currency_spent (depth)
		expect(buy(g, player, "hull")):toBeOk()
		local descended = descend(g, player)
		expect(descended):toBeOk()
		expect(g:lastEvent("currency_spent").payload.sink):toBe("depth.2")
		local progression = g:lastEvent("progression")
		expect(progression.payload.kind):toBe("depth")
		expect(progression.payload.tier):toBe(2)
		expect(g:countEvents("loop_completed")):toBe(1)
		expect(g:lastEvent("loop_completed").payload.step):toBe(Net.Actions.Descend)

		-- progression (resurface) + currency_earned (Pearls)
		climbTo(g, player, 5)
		g.clock:advance(11)
		expect(g:invoke(Net.Actions.Resurface, player, nil)):toBeOk()
		local prestige = g:lastEvent("progression")
		expect(prestige.payload.kind):toBe("resurface")
		expect(prestige.payload.resurfaces):toBe(1)
		local pearlEarn = g:lastEvent("currency_earned")
		expect(pearlEarn.payload.currency):toBe("Pearls")
		expect(pearlEarn.payload.source):toBe("resurface")

		-- session_end, on the STILL-LOADED blob (the A10b pinned order)
		g:leave(player)
		expect(g:countEvents("session_end")):toBe(1)
		local ended = g:lastEvent("session_end")
		expect(ended.payload.stale):toBe(false)
		expect(ended.payload.lifetimeCredits):toBe(pearlEarn.payload.lifetimeCredits)
		expectGreater(ended.payload.sessionSeconds, 0, "session_end reported a zero-length session")

		-- THE WHOLE TAXONOMY, and nothing off it.
		for _, name in AnalyticsService.TAXONOMY do
			expectGreater(g:countEvents(name), 0, `the mandated event "{name}" never fired`)
		end
		for _, record in g.analytics:events() do
			expectTrue(
				g.analytics:isKnownEvent(record.event),
				`an off-taxonomy event "{record.event}" was emitted`
			)
		end
		expect(g.analytics:droppedCount()):toBe(0)
	end)

	it("session_end after a leave is NEVER the stale join-time reconstruction", function()
		local g = newGame()
		local player = g:join(1)
		g.clock:advance(300)
		expect(g:invoke(Net.Actions.CollectSmelter, player, nil)):toBeOk()
		local earned = g:credits(player)
		g:leave(player)
		local ended = g:lastEvent("session_end")
		expect(ended.payload.stale):toBe(false)
		expect(ended.payload.credits):toBe(earned)
		expectGreater(
			ended.payload.credits,
			0,
			"session_end described the JOIN-time snapshot: the pinned leave order was bypassed"
		)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe(
	"[integration] re-entry hooks on server time: the daily ladder (A12) and the restock",
	function()
		-- AMENDMENT A12: the window is 20h OPEN / 44h LAPSE, not the spec's literal "20-22h". Graded
		-- against A12 AND against the escalating ladder actually being CLIMBABLE.
		it("[A12] a real 24h cadence CLIMBS the ladder to the cap", function()
			local g = newGame()
			local player = g:join(1)
			local rewards: { number } = {}
			for day = 1, 8 do
				local claimed = g:invoke(Net.Actions.ClaimDaily, player, nil)
				expect(claimed):toBeOk()
				local info = (claimed :: any).value
				expect(info.streak):toBe(day)
				table.insert(rewards, info.reward)
				-- the HUD badge reads the streak off the replicated view
				local push = g:lastPush()
				expect(push.channel):toBe("data")
				expect(push.payload.daily.streak):toBe(day)
				if day < 8 then
					g.clock:advance(24 * HOUR_SECONDS)
				end
			end
			for index = 2, DailyDropService.REWARD_CAP_STREAK do
				expectGreater(
					rewards[index],
					rewards[index - 1],
					"the daily reward did not escalate on a real 24h cadence — the ladder is unreachable"
				)
			end
			expect(rewards[DailyDropService.REWARD_CAP_STREAK]):toBe(
				DailyDropService.MAX_REWARD_CREDITS
			)
			expect(rewards[8]):toBe(DailyDropService.MAX_REWARD_CREDITS) -- capped, not unbounded
		end)

		it("[A12] the drop is closed inside 20h and LAPSES the streak past 44h", function()
			local g = newGame()
			local player = g:join(1)
			expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeOk()

			g.clock:advance(19 * HOUR_SECONDS)
			expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeErr(Result.Codes.OnCooldown)

			g.clock:advance(5 * HOUR_SECONDS) -- 24h total: inside the window
			local second = g:invoke(Net.Actions.ClaimDaily, player, nil)
			expect(second):toBeOk()
			expect((second :: any).value.streak):toBe(2)

			g.clock:advance(48 * HOUR_SECONDS) -- a whole day missed
			local lapsed = g:invoke(Net.Actions.ClaimDaily, player, nil)
			expect(lapsed):toBeOk()
			expect((lapsed :: any).value.streak):toBe(1)
			expect((lapsed :: any).value.status):toBe(DailyDropService.Status.Lapsed)
		end)

		it(
			"the daily streak SURVIVES a leave and rejoin (it is persisted, not session state)",
			function()
				local g = newGame()
				local player = g:join(1)
				expect(g:invoke(Net.Actions.ClaimDaily, player, nil)):toBeOk()
				g:leave(player)
				g.clock:advance(24 * HOUR_SECONDS)
				local back = g:join(1)
				local claimed = g:invoke(Net.Actions.ClaimDaily, back, nil)
				expect(claimed):toBeOk()
				expect((claimed :: any).value.streak):toBe(2)
			end
		)

		it(
			"the rich wreck RESETS on the server day, and its bonus reaches the running rate",
			function()
				-- The restock is a per-tier salvage-VALUE multiplier, so "it reset" is provable as the rate a
				-- player standing in the rotating tier reads, not as an integer flipping.
				local baseDay = DepthService:dayIndexAt(START_UNIX)
				local cold: number? = nil
				local hot: number? = nil
				for day = baseDay, baseDay + 12 do
					if cold == nil and DepthService:restockTierAt(day * DAY_SECONDS) ~= 1 then
						cold = day
					end
					if
						cold ~= nil
						and day > (cold :: number)
						and hot == nil
						and DepthService:restockTierAt(day * DAY_SECONDS) == 1
					then
						hot = day
					end
				end
				expectTrue(
					cold ~= nil and hot ~= nil,
					"the restock rotation never visits tier 1 in 12 days"
				)

				local g = newGame({ startUnix = (cold :: number) * DAY_SECONDS + HOUR_SECONDS })
				local player = g:join(1)
				local coldRate = g:rateSeam(player)
				local coldWreck = DepthService:wreckPlacementAt(g.clock:unix())
				expect(coldWreck.tier).never:toBe(1)

				g.clock:advance(((hot :: number) - (cold :: number)) * DAY_SECONDS)
				local hotRate = g:rateSeam(player)
				local hotWreck = DepthService:wreckPlacementAt(g.clock:unix())
				expect(hotWreck.tier):toBe(1)
				expectTrue(
					hotWreck.dayIndex ~= coldWreck.dayIndex
						and (hotWreck.tier ~= coldWreck.tier or hotWreck.x ~= coldWreck.x),
					"the rich wreck did not move on the day rollover"
				)
				expectClose(
					hotRate,
					coldRate * DepthService.RESTOCK_MULTIPLIER,
					"the restocked tier's bonus never reached the running income rate"
				)
			end
		)
	end
)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe("[integration] monetization is wired server-side and idempotent", function()
	it("a receipt grants ONCE; every replay is an idempotent acknowledgement", function()
		local g = newGame()
		local player = g:join(1)
		MonetizationService:setProductId("creditPackS", 55001)
		local receipt = {
			PurchaseId = "dupe-1",
			ProductId = 55001,
			PlayerId = player.UserId,
		}
		local first = MonetizationService:processReceipt(g.context, player, receipt)
		expect(first.decision):toBe(MonetizationService.GRANTED)
		expect(first.granted):toBe(true)
		local afterFirst = g:credits(player)
		local lifetimeAfterFirst = g:lifetime(player)

		for _ = 1, 3 do
			local replay = MonetizationService:processReceipt(g.context, player, receipt)
			expect(replay.decision):toBe(MonetizationService.GRANTED)
			expect(replay.granted):toBe(false)
			expect(replay.replay):toBe(true)
		end
		expect(g:credits(player)):toBe(afterFirst)
		expect(g:lifetime(player)):toBe(lifetimeAfterFirst)
		expect(g:countEvents("purchase")):toBe(1)
		-- the ledger is server bookkeeping and must never replicate to the client
		expect((Types.toView(g:blob(player)) :: any).receipts):toBe(nil)
	end)

	it("a receipt that names a different buyer is refused (NotProcessedYet)", function()
		local g = newGame()
		local player = g:join(1)
		local other = g:join(2)
		MonetizationService:setProductId("creditPackS", 55002)
		local outcome = MonetizationService:processReceipt(g.context, player, {
			PurchaseId = "mismatch-1",
			ProductId = 55002,
			PlayerId = other.UserId,
		})
		expect(outcome.decision):toBe(MonetizationService.NOT_PROCESSED)
		expect(g:credits(player)):toBe(0)
	end)

	it("a degraded (non-durable) server never acknowledges a receipt", function()
		local g = newGame()
		local player = g:join(1)
		MonetizationService:setProductId("creditPackS", 55003)
		g.context.persistenceDegraded = true
		local outcome = MonetizationService:processReceipt(g.context, player, {
			PurchaseId = "degraded-1",
			ProductId = 55003,
			PlayerId = player.UserId,
		})
		expect(outcome.decision):toBe(MonetizationService.NOT_PROCESSED)
		expect(g:credits(player)):toBe(0)
		g.context.persistenceDegraded = false
	end)

	it("a gamepass flag is never re-granted, and a failed probe never CLEARS one", function()
		local g = newGame()
		local player = g:join(1)
		MonetizationService:setGamePassId("autoCollect", 4343)
		MonetizationService._ownsPass = function(): boolean
			return true
		end
		expect(MonetizationService:syncPasses(g.context, player)):toBeOk()
		expect(g:blob(player).flags["gamepass.autoCollect"]):toBe(true)
		expect(g:countEvents("purchase")):toBe(1)

		-- a second sync (every join, forever) grants nothing and emits nothing
		expect(MonetizationService:syncPasses(g.context, player)):toBeOk()
		expect(g:countEvents("purchase")):toBe(1)

		-- a probe that cannot get an answer must NOT take away something paid for
		MonetizationService._ownsPass = function(): boolean
			error("web call failed")
		end
		expect(MonetizationService:syncPasses(g.context, player)):toBeOk()
		expect(g:blob(player).flags["gamepass.autoCollect"]):toBe(true)
	end)

	it("the gamepass survives a leave and rejoin, and still gates its effect", function()
		local g = newGame()
		local player = g:join(1)
		local plain = g:rateSeam(player)
		MonetizationService:setGamePassId("doubleCredits", 4444)
		MonetizationService._ownsPass = function(): boolean
			return true
		end
		expect(MonetizationService:syncPasses(g.context, player)):toBeOk()
		g:leave(player)
		g.clock:advance(60)
		-- the rejoin's own probe must not be what keeps it: turn the probe OFF entirely.
		MonetizationService._ownsPass = nil
		MonetizationService:setGamePassId("doubleCredits", 0)
		local back = g:join(1)
		expect(g:blob(back).flags["gamepass.doubleCredits"]):toBe(true)
		expectClose(
			g:rateSeam(back),
			plain * 2,
			"the persisted gamepass flag stopped gating the rate"
		)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
describe(
	"[integration] PACING (amendment A8 / decision D2) — a COARSE order-of-magnitude band",
	function()
		-- READ THIS BEFORE TRUSTING A GREEN HERE.
		-- The spec's targets are "~90s to first Credits" and "10-15 min to the first Depth unlock". Three
		-- numeric tables built in three separate batches multiply into those numbers — SalvageService's
		-- rate model, StructuresShopService's price curve, and DepthService's tier ladder — and NOTHING
		-- has ever checked the composed result. Per DECISION D2 the assertion is a COARSE BAND, roughly
		-- an order of magnitude either side of the target, whose ONLY job is to catch a composition that
		-- is 10x off. IT IS NOT A TUNED ASSERTION AND A GREEN HERE IS NOT "THE PACING IS RIGHT" — the
		-- exact numbers are a human tuning judgement made at the playtest.
		local FIRST_CREDITS_TARGET = 90
		local FIRST_DEPTH_TARGET = 15 * 60
		local BAND_FACTOR = 10

		it("a fresh dome affords its first purchase inside a coarse band around ~90s", function()
			local g = newGame()
			local player = g:join(1)
			local goal = catalogCost("drones", 0)
			local startedAt = g.clock:unix()
			local guard = 0
			while g:credits(player) < goal and guard < 200 do
				guard += 1
				g.clock:advance(10)
				local collected = g:invokeUngated(Net.Actions.CollectSmelter, player, nil)
				expectTrue(
					type(collected) == "table" and collected.ok ~= nil,
					"the collect returned no Result"
				)
			end
			expectTrue(
				g:credits(player) >= goal,
				"a fresh dome never affords its first drone at all"
			)
			local elapsed = g.clock:unix() - startedAt
			expectBetween(
				elapsed,
				FIRST_CREDITS_TARGET / BAND_FACTOR,
				FIRST_CREDITS_TARGET * BAND_FACTOR,
				"TIME TO FIRST PURCHASE is an order of magnitude off the spec's ~90s (coarse band only; "
					.. "this is not a tuning assertion)"
			)
		end)

		it("a reinvesting player reaches Depth 2 inside a coarse band around 10-15 min", function()
			-- THE COMPOSED NUMBER: the whole economy driven by a plain, plausible player who collects when
			-- the smelter is worth collecting, reinvests in whichever of drones/conveyor is cheapest WHILE
			-- IT IS CHEAP RELATIVE TO THE GOAL, then saves for the hull plate and the tier-2 unlock.
			local g = newGame()
			local player = g:join(1)
			local hullCost = catalogCost("hull", 0)
			local goal = hullCost + tierCost(2)
			-- "cheap relative to the goal": an upgrade worth buying on the way rather than saving past.
			local REINVEST_CEILING = goal / 4

			local startedAt = g.clock:unix()
			local guard = 0
			local descendedAt: number? = nil
			while guard < 600 do
				guard += 1
				local blob = g:blob(player)
				local credits = blob.currencies.Credits or 0

				if StructuresShopService:levelOf(blob, "hull") >= 1 and credits >= tierCost(2) then
					local moved = g:invokeUngated(Net.Actions.Descend, player, nil)
					expect(moved):toBeOk()
					expect((moved :: any).value.tier):toBe(2)
					descendedAt = g.clock:unix()
					break
				end
				if StructuresShopService:levelOf(blob, "hull") == 0 and credits >= goal then
					expect(g:invokeUngated(Net.Actions.BuyStructure, player, { key = "hull" })):toBeOk()
					continue
				end

				local bestKey: string? = nil
				local bestCost = math.huge
				for _, key in { "drones", "conveyor" } do
					local cost = catalogCost(key, StructuresShopService:levelOf(blob, key))
					if cost <= REINVEST_CEILING and cost < bestCost then
						bestKey, bestCost = key, cost
					end
				end
				if bestKey ~= nil and credits >= bestCost then
					expect(g:invokeUngated(Net.Actions.BuyStructure, player, { key = bestKey })):toBeOk()
					continue
				end

				-- Otherwise: work. Advance only as far as the smelter can hold, then empty it.
				local need = (if bestKey ~= nil then bestCost else goal) - credits
				local rate = g:rateSeam(player)
				local headroom = g:capacitySeam(player) - blob.smelter.storedCredits
				local step = math.max(1, math.ceil(math.min(headroom, math.max(need, 1)) / rate))
				g.clock:advance(step)
				local collected = g:invokeUngated(Net.Actions.CollectSmelter, player, nil)
				expectTrue(
					type(collected) == "table" and collected.ok ~= nil,
					"the collect returned no Result"
				)
			end

			expectTrue(descendedAt ~= nil, "a reinvesting player never reaches Depth 2 at all")
			local elapsed = (descendedAt :: number) - startedAt
			expectBetween(
				elapsed,
				FIRST_DEPTH_TARGET / BAND_FACTOR,
				FIRST_DEPTH_TARGET * BAND_FACTOR,
				"TIME TO THE FIRST DEPTH UNLOCK is an order of magnitude off the spec's 10-15 min (coarse "
					.. "band only; this is not a tuning assertion, and a green here does not mean the "
					.. "pacing is right)"
			)
		end)
	end
)

describe("[integration] the BindToClose window — a stopped service is off the wire", function()
	-- The adversarial review's HIGH finding, reproduced end to end.
	--
	-- Bootstrap.stop tears down in reverse order, so OfflineService.Stop runs while the gateway is
	-- still dispatching and DataService.Stop (which persists) has not run yet. OfflineService.Stop
	-- clears `_pending` — the ONLY one-shot guard the away window has — and `ensurePending` then
	-- recomputes the window from `joinBaseFor`, which DataService pins at load and never advances.
	-- So a claim arriving inside that window re-pays the whole session, and DataService.Stop makes it
	-- durable. It also inflates stats.lifetimeCredits, which is the leaderboard's ranking key.
	it("offline.claim during teardown is refused, and the guard is load-bearing", function()
		-- OfflineService is a MODULE SINGLETON and this is the only test in the suite that calls its
		-- Stop, so it is the only one that can leave the module in a torn-down state for whatever runs
		-- next. Snapshot every field Start/Stop own and put them back, rather than trying to name the
		-- one that leaks: an earlier attempt restored `_players` alone, left two unrelated offline
		-- specs failing, and cost a real detour in which the FIX was the prime suspect and was
		-- innocent. Removing this describe block alone turned the suite green again, which is what
		-- settled it.
		local savedPending = OfflineService._pending
		local savedClaiming = OfflineService._claiming
		local savedContext = OfflineService._context
		local savedPlayers = OfflineService._players

		-- ── PART 1: the ORIGINAL defect, with the wire left open. This half must keep failing if the
		-- fix is ever removed by a different route than deleting the quiesce call — it is what proves
		-- the guard below is doing real work rather than passing vacuously.
		local exposed = newGame()
		local victim = exposed:join(1)
		exposed:leave(victim)
		exposed.clock:advance(4 * HOUR_SECONDS)
		local back = exposed:join(1)
		local firstClaim = exposed:invoke(Net.Actions.ClaimOffline, back, nil)
		expect(firstClaim):toBeOk()
		local paidOnce = exposed:credits(back)
		expectGreater(paidOnce, 0, "the away window paid nothing, so this test proves nothing")

		-- Teardown reaches OfflineService while the wire is still open (the pre-fix world).
		-- NOTE: OfflineService is a MODULE SINGLETON, so Stop mutates state every later spec shares.
		-- Both halves of this test re-Start it before returning; leaving it stopped made two unrelated
		-- offline specs fail, and the first suspect was the fix rather than the test.
		OfflineService:Stop(exposed.context)
		local replay = exposed:invoke(Net.Actions.ClaimOffline, back, nil)
		expectTrue(
			replay.ok == true,
			"EXPECTED THE DEFECT: with the gateway still open, clearing _pending must let the away "
				.. "window be claimed a SECOND time. If this now refuses, the exploit is being stopped "
				.. "somewhere else and the assertion below is no longer evidence for the quiesce."
		)
		expectGreater(
			exposed:credits(back),
			paidOnce,
			"the replayed claim paid nothing — the double-pay this test guards against cannot be "
				.. "reproduced, so the guard below is unfalsified"
		)

		-- ── PART 2: the same teardown, with Bootstrap's quiesce pass in front of it.
		local guarded = newGame()
		local player = guarded:join(2)
		guarded:leave(player)
		guarded.clock:advance(4 * HOUR_SECONDS)
		local rejoined = guarded:join(2)
		expect(guarded:invoke(Net.Actions.ClaimOffline, rejoined, nil)):toBeOk()
		local settled = guarded:credits(rejoined)

		-- What Bootstrap.stop now does, in its order: quiesce EVERY service first, then Stop.
		guarded.registry:quiesce()
		OfflineService:Stop(guarded.context)

		local refused = guarded:invoke(Net.Actions.ClaimOffline, rejoined, nil)
		expect(refused):toBeErr(Result.Codes.Unavailable)
		expect(guarded:credits(rejoined)):toBe(settled)

		-- Put the singleton back exactly as it was found (see the snapshot at the top). NOT by calling
		-- Start again — that re-registers the actions and throws "already registered".
		OfflineService._pending = savedPending
		OfflineService._claiming = savedClaiming
		OfflineService._context = savedContext
		OfflineService._players = savedPlayers
		-- And empty the ROSTERS. This is the only test in the file that finishes with players still
		-- online, and the injected `_players` seams stay bound to this game after it ends — so a later
		-- spec's tick/prune pass walks a foreign roster that happens to share userId 1.
		SalvageService._players = nil
		LeaderboardService._players = nil
	end)

	it("quiesce closes the WHOLE wire, not just the action that motivated it", function()
		-- The fix is at the seam precisely so it does not have to be reasoned about per service. Every
		-- other action a stopped service owns is in the same danger; this pins that they all close.
		local g = newGame()
		local player = g:join(3)
		expect(g:invoke(Net.Actions.FetchSalvage, player, nil)):toBeOk()
		g.registry:quiesce()
		for _, action in
			{
				Net.Actions.FetchSalvage,
				Net.Actions.CollectSmelter,
				Net.Actions.ClaimPlot,
				Net.Actions.BuyStructure,
				Net.Actions.ClaimDaily,
				Net.Actions.Descend,
			}
		do
			expect(g:invoke(action, player, nil)):toBeErr(Result.Codes.Unavailable)
		end

		-- Same hygiene as the test above, and it is not optional: leaving a player ONLINE in the
		-- injected rosters is what made two unrelated offline specs fail, because the seams stay bound
		-- to this game after the test ends and a later spec's tick then walks a foreign roster that
		-- happens to share a userId. Bisecting the two tests in this block is what found it.
		g:leave(player)
		SalvageService._players = nil
		OfflineService._players = nil
		LeaderboardService._players = nil
	end)
end)
