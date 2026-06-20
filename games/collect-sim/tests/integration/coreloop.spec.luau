--!strict
-- games/collect-sim/tests/integration/coreloop.spec.luau   [INDEPENDENT INTEGRATION GATE — the WHOLE game]
-- The per-feature gates proved each service ALONE. This gate proves the FEATURES WORK TOGETHER by
-- standing up the WHOLE game in Tier-1 and testing the spec's "## Success criteria" END-TO-END.
--
-- HOW THE WHOLE GAME IS STOOD UP (a Lune-clean mirror of src/server/Context.build + init.server):
--   * a REAL DataService over a REAL MockStore (the per-key FIFO lock-queue — the same store
--     production runs in the spine), a REAL AnalyticsService (the single emitter), and a REAL
--     MonetizationService (its seam published in Start).
--   * EVERY feature service's Start(context) runs over ONE shared context object, exactly like the
--     bootstrap, so the SEAMS go LIVE: ctx.islands (IslandsService), ctx.restock (RestockService),
--     ctx.monetization (MonetizationService), ctx.analytics (AnalyticsService) are all non-nil — NOT
--     the nil/identity seams the focused per-feature tests run against. Each service registers its
--     actions onto ONE shared Net registry.
--   * requests are driven through the REAL Net.dispatch (the SAME pure pipeline NetServer + Mocks.net
--     use), with the ActionContext built FRESH per request from the LIVE shared context — so a seam
--     set during one service's Start is visible to every other service's handler, just like NetServer
--     projects the live ServerContext per request. This is what lets the island multiplier reach the
--     Sell formula, the 2x gamepass reach Sell, etc. — the composition the per-feature gates can't see.
--
-- The join/leave LIFECYCLE (loadSession on join; the PlayerRemoving path on leave — stamp
-- lastSeenUnix + session:release + drop the session) is replicated faithfully so the re-entry hooks
-- (offline accrual across an away window) can be tested END-TO-END — something no per-feature gate can
-- do, because the offline gate only loads ONCE and advances the clock; it never LEAVES and REJOINS.
--
-- HARD RULE (the integration gate's contract): if a success criterion does NOT hold end-to-end, the
-- test is left RED and reported — the implementation is NOT patched here.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")

local DataService = require("../../src/server/data/DataService")
local MockStore = require("../../src/server/data/MockStore")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local Migrations = require("../../src/shared/Migrations")

local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local CollectionService = require("../../src/server/services/collection/CollectionService")
local UpgradesShopService = require("../../src/server/services/shop/UpgradesShopService")
local DailyStreakService = require("../../src/server/services/daily/DailyStreakService")
local IslandsService = require("../../src/server/services/islands/IslandsService")
local LeaderboardService = require("../../src/server/services/leaderboard/LeaderboardService")
local MonetizationService = require("../../src/server/services/monetization/MonetizationService")
local OfflineService = require("../../src/server/services/offline/OfflineService")
local RestockService = require("../../src/server/services/restock/RestockService")
local RebirthService = require("../../src/server/services/rebirth/RebirthService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local A = Net.Actions

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Round-robin coroutine driver (the REQUIRED economy_race technique): resume every suspended
-- coroutine until all are dead. Deterministic, deadlock-guarded.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 1000 then
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

-- ============================ THE WHOLE-GAME HARNESS (Context.build + bootstrap mirror) ===========
-- Builds the full server context Lune-clean and runs EVERY service's Start over it so the seams go
-- live. Returns a `game` table with helpers to drive the real Net.dispatch + the join/leave lifecycle.
type Game = {
	data: any,
	clock: any,
	analytics: any,
	context: any,
	store: any,
	registry: any,
	invoke: (action: string, player: any, payload: any) -> any,
	invokeCo: (action: string, player: any, payload: any, sink: (any) -> ()) -> thread,
	-- join/leave are METHODS (called g:join(p) / g:leave(p)) so `self` is the Game table.
	join: (self: any, player: any) -> any,
	leave: (self: any, player: any) -> (),
}

local function buildGame(opts: any?): Game
	local o = opts or {}
	local clock = Mocks.clock(o.startUnix or 1000000)
	local cfg = config()
	local store = MockStore.new({
		clock = clock,
		config = cfg,
		yieldOnUpdate = o.yieldOnUpdate,
		seed = o.seed,
	})
	local data = DataService.new(store, clock, cfg, Mocks.logWarn)

	-- The SINGLE analytics emitter (the contract pass stands it up exactly once; every feature emits
	-- through the SAME object). Constructed here, placed on the context, so every handler's
	-- ActionContext projects this same emitter.
	local analytics = AnalyticsService.new(clock)

	local registry = Net.newRegistry()

	-- The shared server context. `net` is a thin adapter whose :register forwards to the one shared
	-- registry (services call context.net:register(...) in Start). The seam fields start nil and are
	-- POPULATED by the seam-providing services' Start — exactly like Context.build leaves them nil and
	-- the stub/feature Starts fill them.
	local context: any = {
		isServer = true,
		clock = clock,
		config = cfg,
		data = data,
		analytics = analytics,
		net = {
			register = function(_self: any, action: any): ()
				registry:register(action)
			end,
			-- DataService.Start (not run here) would use fireClient; unused in Tier-1.
			fireClient = function(_self: any, _player: any, _name: string, _payload: any): () end,
		},
		security = nil,
		flags = nil,
		monetization = nil,
		islands = nil,
		restock = nil,
	}

	-- BOOTSTRAP ORDER (mirrors init.server.luau service order, minus the Roblox-only net/data Start
	-- which only wire RemoteEvents/PlayerAdded — replaced here by the explicit join/leave helpers).
	-- AnalyticsService:Start is Roblox-only (Players), so we do NOT call it; the session_start/
	-- session_end lifecycle is emitted by the join/leave helpers below (the same emits Start wires).
	CollectionService:Start(context)
	UpgradesShopService:Start(context)
	DailyStreakService:Start(context)
	IslandsService:Start(context) -- publishes context.islands
	LeaderboardService:Start(context)
	MonetizationService:Start(context) -- publishes context.monetization
	OfflineService:Start(context)
	RestockService:Start(context) -- publishes context.restock
	RebirthService:Start(context)

	-- Build the ActionContext FRESH per request from the LIVE context (mirrors NetServer projecting
	-- the live ServerContext) so a seam set in any Start is visible to every handler.
	local function actionContext(player: any): any
		return {
			player = player,
			clock = context.clock,
			data = context.data,
			security = context.security,
			flags = context.flags,
			analytics = context.analytics,
			monetization = context.monetization,
			islands = context.islands,
			restock = context.restock,
		}
	end

	local function invoke(action: string, player: any, payload: any): any
		-- gate = nil: the integration gate isolates from rate-shedding (the per-feature gates already
		-- prove the rate limits); we test the COMPOSITION, not the buckets.
		return Net.dispatch(registry, nil, actionContext(player), action, payload)
	end

	-- A coroutine-wrapped invoke for the interleave/race tests: parks inside the yielding store's
	-- critical section, deposits its Result via `sink`.
	local function invokeCo(action: string, player: any, payload: any, sink: (any) -> ()): thread
		return coroutine.create(function()
			sink(invoke(action, player, payload))
		end)
	end

	-- ----- JOIN: the loadSession path (the same DataService.Start onAdded runs) + session_start -----
	-- Defined as a METHOD (self, player) so call sites use g:join(p); `self` is the Game table.
	local function join(_self: any, player: any): any
		local loaded = data:loadSession(player)
		expect(loaded):toBeOk()
		analytics:emit("session_start", { userId = player.UserId, name = player.Name })
		return (loaded :: any).value
	end

	-- ----- LEAVE: the EXACT PlayerRemoving path from DataService.Start: stamp lastSeenUnix on the
	-- server clock, release the store session, drop it from _sessions; + session_end. This is the
	-- lifecycle the per-feature gates cannot exercise (they never leave). -----
	local function leave(_self: any, player: any): ()
		local session = data._sessions[player.UserId]
		if session ~= nil then
			session.data.timestamps.lastSeenUnix = clock:unix()
			session:release()
			data._sessions[player.UserId] = nil
		end
		analytics:emit("session_end", { userId = player.UserId, name = player.Name })
	end

	return {
		data = data,
		clock = clock,
		analytics = analytics,
		context = context,
		store = store,
		registry = registry,
		invoke = invoke,
		invokeCo = invokeCo,
		join = join,
		leave = leave,
	}
end

-- ---- persisted-state readers (through the lock-queued data layer — the source of truth) ----
local function dataOf(g: Game, player: any): any
	local got = g.data:get(player)
	expect(got):toBeOk()
	return (got :: any).value
end
local function stardustOf(g: Game, player: any): number
	return (dataOf(g, player).currencies.Stardust or 0)
end
local function prismsOf(g: Game, player: any): number
	return (dataOf(g, player).currencies.Prisms or 0)
end
local function lifetimeOf(g: Game, player: any): number
	return (dataOf(g, player).stats.lifetimeStardust or 0)
end
local function rebirthsOf(g: Game, player: any): number
	return (dataOf(g, player).rebirths or 0)
end

-- Drive a balance to a target via the canonical write path (drained for the yielding store). Used to
-- set up a player at a known Stardust level without grinding thousands of Collect calls.
local function setStardust(g: Game, player: any, amount: number): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = g.data:update(player, function(d)
			d.currencies.Stardust = amount
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

-- Grant a gamepass/ownership flag through the canonical write path.
local function setFlag(g: Game, player: any, key: string, value: boolean): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = g.data:update(player, function(d)
			d.flags[key] = value
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

-- Count analytics events of a given type emitted for a userId (whole-session taxonomy assertions).
local function countEvents(g: Game, name: string, userId: number?): number
	local n = 0
	for _, e in g.analytics:eventsOfType(name) do
		if userId == nil or (e.payload ~= nil and e.payload.userId == userId) then
			n += 1
		end
	end
	return n
end

-- =====================================================================================================
-- CRITERION 1 + ANALYTICS: CORE LOOP completable end-to-end (collect -> sell -> buy -> unlock ->
-- rebirth) with a loop_completed at the rebirth, and the balance moving the RIGHT way at each step.
-- =====================================================================================================
describe(
	"CORE LOOP end-to-end: collect -> sell -> buy upgrade -> unlock island 2 -> rebirth",
	function()
		it(
			"traverses the whole loop, balance moves correctly at each step, loop_completed fires at rebirth",
			function()
				local g = buildGame()
				local p = Mocks.player(1, "Looper")
				g:join(p)
				expect(stardustOf(g, p)):toBe(0)

				-- 1) COLLECT: gather motes into the backpack (server adds one mote per Collect).
				for _ = 1, 50 do
					expect(g.invoke(A.Collect, p, {})):toBeOk()
				end
				-- collecting does NOT mint Stardust (it only fills the in-memory backpack).
				expect(stardustOf(g, p)):toBe(0)

				-- 2) SELL: convert the backpack to Stardust. Balance RISES; lifetime rises by the same amount.
				local sell = g.invoke(A.Sell, p, {})
				expect(sell):toBeOk()
				local earned = (sell :: any).value.earned
				expect(earned > 0):toBe(true)
				expect(stardustOf(g, p)):toBe(earned) -- balance moved UP by exactly the sale
				expect(lifetimeOf(g, p)):toBe(earned) -- an EARN -> lifetime up by the same amount

				-- Top up to a comfortable level so the upgrade + unlock + rebirth steps are affordable, exercising
				-- the REAL sinks below (not the grind). This is a server-path write, not a client grant.
				setStardust(g, p, 5000)

				-- 3) BUY UPGRADE: a Stardust SINK. Balance FALLS by exactly the server-derived cost; the upgrade
				-- level rises; lifetime is NOT touched (a spend is not an earn).
				local beforeBuy = stardustOf(g, p)
				local lifeBeforeBuy = lifetimeOf(g, p)
				local buy = g.invoke(A.BuyUpgrade, p, { upgradeId = "collect-speed" })
				expect(buy):toBeOk()
				local buyCost = (buy :: any).value.cost
				expect(buyCost > 0):toBe(true)
				expect(stardustOf(g, p)):toBe(beforeBuy - buyCost) -- balance moved DOWN by the cost
				expect((buy :: any).value.level):toBe(1)
				expect(lifetimeOf(g, p)):toBe(lifeBeforeBuy) -- a spend never raises lifetime

				-- 4) UNLOCK ISLAND 2: a Stardust SINK gated by order. Balance FALLS by the server-derived cost;
				-- the island.2 flag is set; lifetime untouched.
				local beforeUnlock = stardustOf(g, p)
				local lifeBeforeUnlock = lifetimeOf(g, p)
				local unlock = g.invoke(A.UnlockIsland, p, { islandId = 2 })
				expect(unlock):toBeOk()
				local unlockCost = (unlock :: any).value.cost
				expect(unlockCost > 0):toBe(true)
				expect(stardustOf(g, p)):toBe(beforeUnlock - unlockCost) -- balance moved DOWN
				expect(dataOf(g, p).flags["island.2"]):toBe(true) -- island 2 actually unlocked
				expect(lifetimeOf(g, p)):toBe(lifeBeforeUnlock)

				-- 5) REBIRTH: needs Stardust over the server threshold; ensure we are above it, then rebirth.
				-- Rebirth ZEROES Stardust, grants Prisms, bumps the rebirth count, and is the LOOP-COMPLETION
				-- point. lifetimeStardust must NOT reset (it is monotonic).
				setStardust(g, p, 5000)
				local lifeBeforeRebirth = lifetimeOf(g, p)
				expect(rebirthsOf(g, p)):toBe(0)
				expect(prismsOf(g, p)):toBe(0)
				local rb = g.invoke(A.Rebirth, p, {})
				expect(rb):toBeOk()
				expect((rb :: any).value.rebirths):toBe(1)
				expect((rb :: any).value.prismsEarned > 0):toBe(true)
				expect(rebirthsOf(g, p)):toBe(1) -- count bumped
				expect(prismsOf(g, p)):toBe((rb :: any).value.prismsEarned) -- Prisms granted
				expect(stardustOf(g, p)):toBe(0) -- prestige zeroed Stardust
				expect(dataOf(g, p).flags["island.2"]):toBe(nil) -- island flags cleared by rebirth
				expect(dataOf(g, p).upgrades["collect-speed"]):toBe(nil) -- upgrades reset by rebirth
				expect(lifetimeOf(g, p)):toBe(lifeBeforeRebirth) -- lifetime SURVIVES the rebirth (never reset)

				-- loop_completed fired EXACTLY at the rebirth, through the single ctx.analytics.
				expect(countEvents(g, "loop_completed", p.UserId)):toBe(1)
			end
		)
	end
)

-- =====================================================================================================
-- CRITERION: MULTIPLIERS ACTUALLY REACH SELL (the composition the per-feature gates can't see).
-- =====================================================================================================
describe("Multipliers compose into the consolidated Sell formula", function()
	-- Helper: collect `n` motes then sell, returning the earned amount.
	local function collectAndSell(g: Game, p: any, n: number): number
		for _ = 1, n do
			expect(g.invoke(A.Collect, p, {})):toBeOk()
		end
		local r = g.invoke(A.Sell, p, {})
		expect(r):toBeOk()
		return (r :: any).value.earned
	end

	it(
		"unlocking a richer island makes a SUBSEQUENT sell pay MORE (island mult reaches Sell)",
		function()
			-- ISOLATE the island multiplier from the restock vein: pick a server day whose rich vein
			-- lands on an island the player NEVER unlocks here (island 3), so the restock factor stays 1
			-- in BOTH the base and the richer sell. vein = ISLAND_IDS[(day % 5) + 1]; day == floor(now/86400).
			-- day % 5 == 2 -> vein island 3. We only unlock island 2, so the restock bonus never applies and
			-- the ONLY differing factor between the two sells is the island-2 multiplier (2).
			local SECONDS_PER_DAY = 86400
			local g = buildGame({ startUnix = 12 * SECONDS_PER_DAY + 100 }) -- day 12 -> 12%5==2 -> vein island 3
			local p = Mocks.player(10, "Climber")
			g:join(p)

			-- Baseline sell on the starting island (multiplier 1; not the vein island -> restock 1).
			local base = collectAndSell(g, p, 50)
			expect(base > 0):toBe(true)

			-- Unlock island 2 (multiplier 2 per the catalog), affording it first.
			setStardust(g, p, 5000)
			expect(g.invoke(A.UnlockIsland, p, { islandId = 2 })):toBeOk()

			-- A subsequent identical sell pays MORE — the island multiplier reached the Sell formula via
			-- ctx.islands:multiplierFor(d). With island-2 multiplier 2 (and restock still 1, since the
			-- vein is island 3 which the player has NOT unlocked) the same 50 motes pay EXACTLY 2x the base.
			local richer = collectAndSell(g, p, 50)
			expect(richer):toBe(base * 2)
		end
	)

	it(
		"the 2x-Stardust gamepass flag DOUBLES a subsequent sell (monetization seam reaches Sell)",
		function()
			local g = buildGame()
			local p = Mocks.player(11, "Whale")
			g:join(p)

			local base = collectAndSell(g, p, 50)
			expect(base > 0):toBe(true)

			-- Grant the 2x gamepass ownership flag; the monetization seam now returns 2 for this user.
			setFlag(g, p, "gamepass.2xStardust", true)

			local doubled = collectAndSell(g, p, 50)
			expect(doubled):toBe(base * 2)
		end
	)

	it(
		"on TODAY's restock vein the bonus applies to a sell on that island (restock seam reaches Sell)",
		function()
			-- The restock vein is derived from the server day number over island ids {1..5}; the starting
			-- island (id 1) is universally unlocked. Find a server time whose vein lands on the starting
			-- island so EVERY player is eligible, and contrast it with a non-starting-vein day's base sell.
			-- richVeinIslandId(now) = ISLAND_IDS[(day % 5) + 1]; day == floor(now/86400). day%5==0 -> island 1.
			local SECONDS_PER_DAY = 86400
			-- A day number that is a multiple of 5 lands the vein on island id 1 (the starting island).
			local veinDay = 5
			local nonVeinDay = 6 -- day%5==1 -> island id 2 (which a fresh player has NOT unlocked)

			-- Base sell on a NON-vein day (vein is island 2, player only has island 1 -> no bonus).
			local gBase = buildGame({ startUnix = nonVeinDay * SECONDS_PER_DAY + 100 })
			local pb = Mocks.player(12, "VeinBase")
			gBase:join(pb)
			local base = collectAndSell(gBase, pb, 50)
			expect(base > 0):toBe(true)

			-- Sell on a VEIN day where the vein is the starting island (universally eligible) -> bonus applies.
			local gVein = buildGame({ startUnix = veinDay * SECONDS_PER_DAY + 100 })
			local pv = Mocks.player(13, "VeinHot")
			gVein:join(pv)
			local hot = collectAndSell(gVein, pv, 50)

			-- The rich-vein multiplier is server-owned (> 1). The hot-day sell must EXCEED the base-day sell
			-- (same island multiplier 1, same rebirths 0, same 50 motes) — proving the restock seam reached Sell.
			expect(hot > base):toBe(true)
			-- And it is an integer multiple of the base (the only differing factor is the restock multiplier).
			expect(hot % base):toBe(0)
			expect((hot / base) >= 2):toBe(true) -- a real bonus, not a rounding artifact
		end
	)
end)

-- =====================================================================================================
-- CRITERION: LIFETIME on ALL earns, NEVER on spend/reset (and rebirth does not RESET it).
-- =====================================================================================================
describe("lifetimeStardust rises on every EARN, never on a spend or a reset", function()
	it(
		"sell, daily claim, offline claim, and a monetization pack each RAISE lifetime by the grant",
		function()
			local g = buildGame()
			local p = Mocks.player(20, "Earner")
			g:join(p)
			expect(lifetimeOf(g, p)):toBe(0)

			-- EARN 1: sell.
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local sell = g.invoke(A.Sell, p, {})
			expect(sell):toBeOk()
			local l1 = lifetimeOf(g, p)
			expect(l1):toBe((sell :: any).value.earned)

			-- EARN 2: daily claim (server-clock gated; first-ever claim always grants).
			local daily = g.invoke(A.Daily, p, {})
			expect(daily):toBeOk()
			local dailyReward = (daily :: any).value.reward
			expect(dailyReward > 0):toBe(true)
			local l2 = lifetimeOf(g, p)
			expect(l2):toBe(l1 + dailyReward)

			-- EARN 3: offline claim across an away window. Leave -> time passes -> rejoin -> claim. Use the
			-- REAL lifecycle so the accrual base is the server-written lastSeenUnix (this is also the re-entry
			-- criterion's path). If this grants 0, the offline EARN cannot raise lifetime — caught here too.
			g:leave(p)
			g.clock:advance(600) -- 10 minutes away
			g:join(p)
			local offline = g.invoke(A.ClaimOffline, p, {})
			expect(offline):toBeOk()
			local offlineGrant = (offline :: any).value.granted
			local l3 = lifetimeOf(g, p)
			-- GAP 4 (load-bearing offline grant): the offline EARN must actually PAY for a 600s away
			-- window. If offline grants 0, the "lifetime rises on the offline earn" claim below is
			-- vacuously true (l3 == l2 + 0), so a regression to "offline never pays" slips through.
			-- Require it strictly positive so this test FAILS if the offline path mints nothing.
			expect(offlineGrant > 0):toBe(true)
			expect(l3):toBe(l2 + offlineGrant) -- lifetime rose by EXACTLY the (now-required-positive) offline grant

			-- EARN 4: a monetization Stardust-pack grant (idempotent ProcessReceipt path) RAISES lifetime.
			local mon = g.context.monetization
			local receipt = { PlayerId = p.UserId, ProductId = 101, PurchaseId = "pack-earn-1" } -- product 101 = pack S
			local pr = mon:ProcessReceipt(receipt)
			expect(pr):toBeOk()
			local packAmount = (pr :: any).value.amount
			expect(packAmount > 0):toBe(true)
			expect(lifetimeOf(g, p)):toBe(l3 + packAmount)
		end
	)

	it(
		"a shop buy, an island unlock, and a rebirth do NOT raise lifetime (and rebirth does not RESET it)",
		function()
			local g = buildGame()
			local p = Mocks.player(21, "Spender")
			g:join(p)
			setStardust(g, p, 50000) -- plenty for a buy + unlock + rebirth

			-- accrue a real lifetime via an honest earn so we can prove a spend/reset never moves it.
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			expect(g.invoke(A.Sell, p, {})):toBeOk()
			local lifeAfterEarn = lifetimeOf(g, p)
			expect(lifeAfterEarn > 0):toBe(true)

			-- SPEND: shop buy -> lifetime unchanged.
			expect(g.invoke(A.BuyUpgrade, p, { upgradeId = "backpack" })):toBeOk()
			expect(lifetimeOf(g, p)):toBe(lifeAfterEarn)

			-- SPEND: island unlock -> lifetime unchanged.
			expect(g.invoke(A.UnlockIsland, p, { islandId = 2 })):toBeOk()
			expect(lifetimeOf(g, p)):toBe(lifeAfterEarn)

			-- RESET: rebirth -> lifetime SURVIVES (monotonic across prestige). Ensure above threshold first.
			setStardust(g, p, 5000)
			local lifeBeforeRebirth = lifetimeOf(g, p)
			expect(lifeBeforeRebirth):toBe(lifeAfterEarn) -- the setStardust write is not an earn either
			expect(g.invoke(A.Rebirth, p, {})):toBeOk()
			expect(lifetimeOf(g, p)):toBe(lifeBeforeRebirth) -- NOT reset by rebirth
		end
	)
end)

-- =====================================================================================================
-- CRITERION 2: ECONOMY concurrency-safe — interleaved/spam-duplicated sell + buy + unlock + rebirth
-- against the ONE shared currencies.Stardust never double-spends Stardust or dupes Prisms.
-- =====================================================================================================
describe(
	"Shared-balance race: interleaved sell/buy/unlock/rebirth never double-spend or dupe",
	function()
		it("spam-duplicated SELL of one backpack pays out EXACTLY once (no double mint)", function()
			local g = buildGame({ yieldOnUpdate = true })
			local p = Mocks.player(30, "Spammer")
			-- load through the yielding store via a drained coroutine (loadSession can park on the lock).
			local lr: any = nil
			drain({ coroutine.create(function()
				lr = g.data:loadSession(p)
			end) })
			expect(lr):toBeOk()
			g.analytics:emit("session_start", { userId = p.UserId, name = p.Name })

			-- Fill the backpack to 50 (each Collect is synchronous on the in-memory backpack — no store yield).
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end

			-- Probe what ONE sell of a full backpack pays (clean, isolated, identity multipliers).
			local gp = buildGame()
			local pp = Mocks.player(3030)
			gp:join(pp)
			for _ = 1, 50 do
				expect(gp.invoke(A.Collect, pp, {})):toBeOk()
			end
			local single = (gp.invoke(A.Sell, pp, {}) :: any).value.earned
			expect(single > 0):toBe(true)

			-- Four interleaved sells of the SAME backpack against the yielding store. The Collection Sell
			-- empties the in-memory backpack BEFORE the yielding update, so exactly ONE pays out.
			local results: { any } = {}
			local cos = {}
			for i = 1, 4 do
				local idx = i
				table.insert(
					cos,
					g.invokeCo(A.Sell, p, {}, function(r)
						results[idx] = r
					end)
				)
			end
			drain(cos)

			local total = 0
			local nonZero = 0
			for i = 1, 4 do
				expect(results[i]):toBeOk()
				local e = (results[i] :: any).value.earned
				total += e
				if e > 0 then
					nonZero += 1
				end
			end
			expect(nonZero):toBe(1) -- exactly one of four spam-sells paid out
			expect(total):toBe(single) -- the backpack was minted EXACTLY once
			expect(stardustOf(g, p)):toBe(single) -- persisted: one window, never four
			expect(lifetimeOf(g, p)):toBe(single)
		end)

		it(
			"interleaved BUY + UNLOCK against one balance never overspends (no negative, no free grant)",
			function()
				-- A balance that affords EITHER the upgrade (cost base*1 = 25 for collect-speed) OR the island-2
				-- unlock (cost 500), but the operations interleave on the SAME Stardust. The total deducted must
				-- equal the sum of whatever actually succeeded; the balance can never go negative.
				local g = buildGame({ yieldOnUpdate = true })
				local p = Mocks.player(31, "Racer")
				local lr: any = nil
				drain({ coroutine.create(function()
					lr = g.data:loadSession(p)
				end) })
				expect(lr):toBeOk()
				setStardust(g, p, 525) -- exactly affords ONE buy (25) + ONE unlock (500)

				local results: { any } = {}
				local cos = {
					g.invokeCo(A.BuyUpgrade, p, { upgradeId = "collect-speed" }, function(r)
						results.buy = r
					end),
					g.invokeCo(A.UnlockIsland, p, { islandId = 2 }, function(r)
						results.unlock = r
					end),
				}
				drain(cos)
				expect(results.buy):toBeOk()
				expect(results.unlock):toBeOk()
				-- Both succeeded against the lock-serialized balance: 525 - 25 - 500 == 0. Never negative, never
				-- a free grant (each deduction matched its effect).
				expect(stardustOf(g, p)):toBe(0)
				expect(dataOf(g, p).flags["island.2"]):toBe(true)
				expect(dataOf(g, p).upgrades["collect-speed"]):toBe(1)
			end
		)

		it(
			"spam-duplicated REBIRTH grants Prisms EXACTLY once and bumps the count once (no dupe)",
			function()
				local g = buildGame({ yieldOnUpdate = true })
				local p = Mocks.player(32, "Prestige")
				local lr: any = nil
				drain({ coroutine.create(function()
					lr = g.data:loadSession(p)
				end) })
				expect(lr):toBeOk()
				setStardust(g, p, 3000) -- above the rebirth threshold; enough for exactly ONE rebirth

				local results: { any } = {}
				local cos = {}
				for i = 1, 4 do
					local idx = i
					table.insert(
						cos,
						g.invokeCo(A.Rebirth, p, {}, function(r)
							results[idx] = r
						end)
					)
				end
				drain(cos)

				local okCount = 0
				local totalPrismsEarned = 0
				for i = 1, 4 do
					local r = results[i]
					if r.ok then
						okCount += 1
						totalPrismsEarned += (r :: any).value.prismsEarned
					else
						-- the losers re-read the just-zeroed Stardust (below threshold) -> Insufficient.
						expect(r):toBeErr(Result.Codes.Insufficient)
					end
				end
				expect(okCount):toBe(1) -- exactly one rebirth committed
				expect(rebirthsOf(g, p)):toBe(1) -- count bumped exactly once, never duped
				expect(prismsOf(g, p)):toBe(totalPrismsEarned) -- Prisms granted exactly once (the single winner)
				expect(stardustOf(g, p)):toBe(0) -- zeroed once
			end
		)
	end
)

-- =====================================================================================================
-- CRITERION 4: RE-ENTRY LIFECYCLE (the per-feature gates CANNOT test this). A player EARNS, LEAVES
-- (stamps lastSeenUnix), time passes on the server clock, REJOINS (loadSession), then claims offline.
-- They MUST receive the offline grant for the elapsed-away window. If they get ZERO, that is an
-- integration bug (a lifecycle timestamp issue) — left RED and reported.
-- =====================================================================================================
describe(
	"Re-entry lifecycle: leave -> server time passes -> rejoin -> claim offline pays the away window",
	function()
		it(
			"an away window of 600s, claimed after rejoin, grants the offline accrual for THAT window",
			function()
				-- First, establish the per-second offline rate via the SAME real game path (probe), so the
				-- expectation is derived from behavior, not a copied constant. A single load + advance + claim
				-- gives rate*elapsed (the per-feature path) — we use it only to compute the expected grant.
				local gp = buildGame()
				local pp = Mocks.player(4040)
				gp:join(pp)
				gp.clock:advance(600)
				local probe = (gp.invoke(A.ClaimOffline, pp, {}) :: any).value.granted
				expect(probe > 0):toBe(true) -- a 600s window genuinely accrues something on the offline path

				-- Now the REAL re-entry lifecycle: join, leave (stamps lastSeenUnix), 600s passes, rejoin, claim.
				local g = buildGame()
				local p = Mocks.player(40, "Returner")
				g:join(p)
				-- earn a bit while present so leaving has meaning (not required, but realistic).
				for _ = 1, 10 do
					expect(g.invoke(A.Collect, p, {})):toBeOk()
				end
				expect(g.invoke(A.Sell, p, {})):toBeOk()
				local balanceAtLeave = stardustOf(g, p)

				g:leave(p) -- PlayerRemoving: stamps lastSeenUnix = now, releases the session
				g.clock:advance(600) -- the player is AWAY for 600 server seconds
				g:join(p) -- rejoin: loadSession re-loads the persisted blob

				local claim = g.invoke(A.ClaimOffline, p, {})
				expect(claim):toBeOk()
				local granted = (claim :: any).value.granted

				-- THE INTEGRATION INVARIANT: the away window (leave -> rejoin) is 600s, so the claim MUST grant
				-- the same accrual a 600s offline window pays. A grant of ZERO means the accrual base was
				-- destroyed by the lifecycle (loadSession re-stamps lastSeenUnix = now on every join, wiping the
				-- leave-time base) — an INTEGRATION BUG, left RED.
				-- GAP 4 (load-bearing offline grant): make the must-pay requirement DIRECT. The re-entry
				-- claim has to pay a strictly POSITIVE amount for the 600s away window; a regression to
				-- "offline never pays" (granted == 0) fails HERE, not just via the granted == probe identity.
				expect(granted > 0):toBe(true)
				expect(granted):toBe(probe)
				expect(stardustOf(g, p)):toBe(balanceAtLeave + granted)
			end
		)
	end
)

-- =====================================================================================================
-- CRITERION 5: ANALYTICS taxonomy end-to-end — over a full session the 7 events fire through the
-- single ctx.analytics: session_start/session_end (lifecycle), loop_completed, currency_earned,
-- currency_spent, progression, purchase.
-- =====================================================================================================
describe(
	"Analytics taxonomy end-to-end: all 7 events fire through the single ctx.analytics",
	function()
		it(
			"a full session emits session_start/_end, loop_completed, currency_earned/_spent, progression, purchase",
			function()
				local g = buildGame()
				local p = Mocks.player(50, "Telemetry")
				g:join(p) -- session_start

				-- currency_earned (sell).
				for _ = 1, 50 do
					expect(g.invoke(A.Collect, p, {})):toBeOk()
				end
				expect(g.invoke(A.Sell, p, {})):toBeOk()

				setStardust(g, p, 50000)

				-- currency_spent (shop buy).
				expect(g.invoke(A.BuyUpgrade, p, { upgradeId = "magnet" })):toBeOk()

				-- progression + currency_spent (island unlock).
				expect(g.invoke(A.UnlockIsland, p, { islandId = 2 })):toBeOk()

				-- purchase (+ currency_earned) via a Stardust pack receipt.
				local mon = g.context.monetization
				expect(mon:ProcessReceipt({
					PlayerId = p.UserId,
					ProductId = 101,
					PurchaseId = "telemetry-pack-1",
				})):toBeOk()

				-- loop_completed + progression (rebirth) — the loop-completion point.
				setStardust(g, p, 5000)
				expect(g.invoke(A.Rebirth, p, {})):toBeOk()

				g:leave(p) -- session_end

				-- Assert EVERY one of the 7 taxonomy events fired at least once this session.
				for _, name in
					{
						"session_start",
						"session_end",
						"loop_completed",
						"currency_earned",
						"currency_spent",
						"progression",
						"purchase",
					}
				do
					expect(#g.analytics:eventsOfType(name) > 0):toBe(true)
				end

				-- Spot-check the source/sink tags so the events are the REAL ones, not a stray emit:
				--   * a currency_earned tagged source "sell" exists (the sale).
				local sawSellEarn = false
				for _, e in g.analytics:eventsOfType("currency_earned") do
					if e.payload ~= nil and e.payload.source == "sell" then
						sawSellEarn = true
					end
				end
				expect(sawSellEarn):toBe(true)
				--   * a progression event tagged kind "rebirth" exists (the prestige), AND one "island_unlock".
				local sawRebirth, sawIsland = false, false
				for _, e in g.analytics:eventsOfType("progression") do
					if e.payload ~= nil and e.payload.kind == "rebirth" then
						sawRebirth = true
					end
					if e.payload ~= nil and e.payload.kind == "island_unlock" then
						sawIsland = true
					end
				end
				expect(sawRebirth):toBe(true)
				expect(sawIsland):toBe(true)
			end
		)
	end
)

-- =====================================================================================================
-- CRITERION 3: MONETIZATION wired + idempotent (the gamepass gates compose with Sell, and the pack
-- dev-product grants via an idempotent ProcessReceipt — a replay grants nothing the second time).
-- =====================================================================================================
describe("Monetization wired + idempotent through the live monetization seam", function()
	it(
		"a Stardust-pack receipt grants ONCE; a replayed receipt id grants nothing the second time",
		function()
			local g = buildGame()
			local p = Mocks.player(60, "Buyer")
			g:join(p)
			local mon = g.context.monetization

			local before = stardustOf(g, p)
			local r1 =
				mon:ProcessReceipt({ PlayerId = p.UserId, ProductId = 101, PurchaseId = "dup-1" })
			expect(r1):toBeOk()
			local amount = (r1 :: any).value.amount
			expect(amount > 0):toBe(true)
			expect((r1 :: any).value.granted):toBe(true)
			expect(stardustOf(g, p)):toBe(before + amount)

			-- REPLAY the SAME PurchaseId: idempotent -> grants nothing, balance unchanged.
			local r2 =
				mon:ProcessReceipt({ PlayerId = p.UserId, ProductId = 101, PurchaseId = "dup-1" })
			expect(r2):toBeOk()
			expect((r2 :: any).value.alreadyProcessed):toBe(true)
			expect((r2 :: any).value.granted):toBe(false)
			expect(stardustOf(g, p)):toBe(before + amount) -- NOT double-granted
		end
	)

	it(
		"the 2x boost dev-product activates the boost so a subsequent sell pays double, idempotently",
		function()
			local g = buildGame()
			local p = Mocks.player(61, "Booster")
			g:join(p)
			local mon = g.context.monetization

			-- baseline sell with no boost.
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local base = (g.invoke(A.Sell, p, {}) :: any).value.earned
			expect(base > 0):toBe(true)

			-- buy the 30-min 2x boost (product 201). The seam now reports 2x for this user (server-clock).
			expect(
				mon:ProcessReceipt({ PlayerId = p.UserId, ProductId = 201, PurchaseId = "boost-1" })
			):toBeOk()

			-- a subsequent sell pays double (the boost multiplier reached Sell via the monetization seam).
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local boosted = (g.invoke(A.Sell, p, {}) :: any).value.earned
			expect(boosted):toBe(base * 2)

			-- a replayed boost receipt id does not stack a second boost (idempotent ledger).
			local replay =
				mon:ProcessReceipt({ PlayerId = p.UserId, ProductId = 201, PurchaseId = "boost-1" })
			expect(replay):toBeOk()
			expect((replay :: any).value.alreadyProcessed):toBe(true)
		end
	)

	it("the VIP-island gamepass flag gates unlocking the VIP island", function()
		local g = buildGame()
		local p = Mocks.player(62, "VIP")
		g:join(p)
		-- afford + unlock islands 2..4 in order so the VIP island (id 5) is order-reachable.
		setStardust(g, p, 1000000)
		for _, id in { 2, 3, 4 } do
			expect(g.invoke(A.UnlockIsland, p, { islandId = id })):toBeOk()
		end

		-- WITHOUT the VIP flag: unlocking island 5 is refused as NotOwner.
		expect(g.invoke(A.UnlockIsland, p, { islandId = 5 })):toBeErr(Result.Codes.NotOwner)

		-- WITH the VIP gamepass flag: the unlock now succeeds.
		setFlag(g, p, "gamepass.vipIsland", true)
		expect(g.invoke(A.UnlockIsland, p, { islandId = 5 })):toBeOk()
		expect(dataOf(g, p).flags["island.5"]):toBe(true)
	end)
end)

-- A small migration/round-trip sanity at the WHOLE-game level: a seeded LEGACY (v1) blob loaded through
-- the real DataService migrates to the current schema and is immediately playable (sell works), proving
-- the migration + the live seams compose on a returning player's data.
describe("A legacy (v1) seeded player migrates and is immediately playable end-to-end", function()
	it(
		"a v1 blob loads, migrates to current schema, and a sell works with lifetime accrual",
		function()
			local legacy = {
				schemaVersion = 1,
				currencies = { Stardust = 100 },
				stats = { playtimeSeconds = 0, joinCount = 0 },
				timestamps = { firstJoinUnix = 1, lastSeenUnix = 1 },
				upgrades = {},
				flags = {},
				receipts = {},
			}
			local g = buildGame({ seed = { player_70 = legacy } })
			local p = Mocks.player(70, "Veteran")
			g:join(p)
			local d = dataOf(g, p)
			-- migrated to current schema; lifetimeStardust backfilled from the legacy balance (floor).
			expect(d.schemaVersion):toBe(Migrations.migrate({ schemaVersion = 1 }).schemaVersion)
			expect(d.stats.lifetimeStardust):toBe(100)
			expect(d.currencies.Stardust):toBe(100)

			-- immediately playable: collect + sell raises the balance and lifetime.
			for _ = 1, 50 do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local sell = g.invoke(A.Sell, p, {})
			expect(sell):toBeOk()
			local earned = (sell :: any).value.earned
			expect(d.stats.lifetimeStardust):toBe(100) -- snapshot pre-sell (d is a copy)
			expect(stardustOf(g, p)):toBe(100 + earned)
			expect(lifetimeOf(g, p)):toBe(100 + earned)
		end
	)
end)

-- =====================================================================================================
-- GAP 1 -- DAILY 20-22h CLAIM WINDOW, END-TO-END on the SERVER clock. The existing lifetime test claims
-- daily ONCE; nothing drives the COOLDOWN window through the whole-game harness. Here a player claims,
-- a too-soon re-claim is rejected OnCooldown, advancing INTO the 20-22h window grants AGAIN and the
-- streak INCREMENTS. Driven entirely through g.invoke(A.Daily, ...) on the server clock g.clock.
-- FALSIFIABLE: a broken cooldown (claim allowed immediately, or never re-allowed) makes this RED.
-- =====================================================================================================
describe(
	"Daily streak: the 20-22h claim window is enforced END-TO-END on the server clock",
	function()
		it(
			"claim grants; a too-soon re-claim is OnCooldown; advancing into the window grants again + streak++",
			function()
				-- Start at a day boundary so clock math is clean; the vein isolation is irrelevant here (no Sell).
				local g = buildGame()
				local p = Mocks.player(80, "Streaker")
				g:join(p)

				-- FIRST claim ever: always grants, streak starts at 1, reward is server-derived (> 0).
				local first = g.invoke(A.Daily, p, {})
				expect(first):toBeOk()
				expect((first :: any).value.streak):toBe(1)
				local firstReward = (first :: any).value.reward
				expect(firstReward > 0):toBe(true)
				-- The grant is an EARN: the balance moved up by exactly the reward.
				expect(stardustOf(g, p)):toBe(firstReward)

				-- TOO SOON: advance LESS than the 20h floor of the window (19h). A second claim is rejected as
				-- OnCooldown end-to-end; balance + streak are untouched (no grant, no streak bump).
				g.clock:advance(19 * 3600) -- 19h < the 20h window floor
				local tooSoon = g.invoke(A.Daily, p, {})
				expect(tooSoon):toBeErr(Result.Codes.OnCooldown)
				expect(stardustOf(g, p)):toBe(firstReward) -- nothing granted on the cooldown rejection
				-- The streak did NOT advance on a rejected claim (re-read the persisted streak).
				expect(dataOf(g, p).daily.streak):toBe(1)

				-- INTO THE WINDOW: advance the remainder so the TOTAL elapsed since the first claim is inside the
				-- 20-22h window (21h total here), and below the 48h streak-reset ceiling. The claim now GRANTS
				-- again and the streak INCREMENTS to 2 (not reset to 1) -- proving both the cooldown OPENED and the
				-- streak counter advanced, end-to-end on the server clock.
				g.clock:advance(2 * 3600) -- +2h -> 21h total elapsed: inside [20h, 22h], under 48h reset
				local second = g.invoke(A.Daily, p, {})
				expect(second):toBeOk()
				expect((second :: any).value.streak):toBe(2) -- streak INCREMENTED, not reset
				local secondReward = (second :: any).value.reward
				expect(secondReward > 0):toBe(true)
				-- A higher streak pays MORE (reward scales with the streak): the window re-open is a real EARN.
				expect(secondReward > firstReward):toBe(true)
				expect(stardustOf(g, p)):toBe(firstReward + secondReward) -- balance rose by the second grant
				expect(dataOf(g, p).daily.streak):toBe(2) -- persisted streak advanced
			end
		)
	end
)

-- =====================================================================================================
-- GAP 2 -- RESTOCK DAY-BOUNDARY RESET, END-TO-END. The rich vein is day-derived (day = floor(now/86400));
-- crossing a SERVER day boundary moves the vein to a DIFFERENT island, i.e. the restock RESETS each day.
-- Proven two ways end-to-end through the whole-game harness: (a) the FetchRestock vein island id CHANGES
-- across the boundary, and (b) the Sell bonus that landed on the player's island on a vein day is GONE
-- on the next day (the vein moved off them). Isolated from the island multiplier (player keeps island 1).
-- FALSIFIABLE: a vein that did NOT reset at the day boundary keeps the same island / keeps paying the
-- bonus, making this RED.
-- =====================================================================================================
describe("Restock: the daily rich vein RESETS at the server day boundary, end-to-end", function()
	local SECONDS_PER_DAY = 86400

	-- Helper: collect n motes then sell, returning earned (mirrors the multiplier-suite helper).
	local function collectAndSell(g: Game, p: any, n: number): number
		for _ = 1, n do
			expect(g.invoke(A.Collect, p, {})):toBeOk()
		end
		local r = g.invoke(A.Sell, p, {})
		expect(r):toBeOk()
		return (r :: any).value.earned
	end

	it(
		"crossing midnight moves the vein to a different island (FetchRestock id changes + Sell bonus leaves)",
		function()
			-- Day 5 -> 5%5==0 -> vein index 1 -> island id 1 (the universally-unlocked starting island), so a
			-- fresh player IS eligible and the vein bonus reaches their Sell. Start late in day 5 so a single
			-- clock advance crosses into day 6, where 6%5==1 -> vein index 2 -> island id 2 (the player has NOT
			-- unlocked it), so the bonus must DISAPPEAR -- the restock reset moved the vein off the player.
			local g = buildGame({ startUnix = 5 * SECONDS_PER_DAY + (SECONDS_PER_DAY - 100) }) -- 100s before midnight, day 5
			local p = Mocks.player(81, "Veiner")
			g:join(p)

			-- BEFORE the boundary: FetchRestock reports the day-5 vein on island 1, and this fresh player is
			-- eligible (starting island). A vein-day sell on the starting island pays the rich-vein bonus.
			local beforeFetch = g.invoke(A.FetchRestock, p, {})
			expect(beforeFetch):toBeOk()
			local veinBefore = (beforeFetch :: any).value.islandId
			expect((beforeFetch :: any).value.eligible):toBe(true) -- starting island is today's vein -> eligible
			local hot = collectAndSell(g, p, 50)
			expect(hot > 0):toBe(true)

			-- CROSS THE DAY BOUNDARY on the server clock (200s forward: 100s to midnight + 100s into day 6).
			g.clock:advance(200)

			-- AFTER the boundary: the vein RESET to a DIFFERENT island (day-6 vein is island 2). The
			-- FetchRestock id changed, and this player (still only island 1) is no longer eligible.
			local afterFetch = g.invoke(A.FetchRestock, p, {})
			expect(afterFetch):toBeOk()
			local veinAfter = (afterFetch :: any).value.islandId
			expect(veinAfter ~= veinBefore):toBe(true) -- the rich vein MOVED at the day boundary (reset)
			expect((afterFetch :: any).value.eligible):toBe(false) -- vein is island 2, which the player lacks

			-- And the Sell bonus is GONE: the same 50 motes now pay the plain base (no vein, no island-2, no
			-- rebirth). The day-5 hot sell strictly EXCEEDED this day-6 cold sell -> the restock truly reset.
			local cold = collectAndSell(g, p, 50)
			expect(cold > 0):toBe(true)
			expect(hot > cold):toBe(true) -- the vein bonus that applied on day 5 is gone on day 6
			-- The cold sell is the un-multiplied base; the hot sell was an integer multiple of it (the vein).
			expect(hot % cold):toBe(0)
			expect(hot / cold):toBe(3) -- RICH_VEIN_MULTIPLIER reached Sell only on the vein day
		end
	)
end)

-- =====================================================================================================
-- GAP 3 -- currency_spent specifically from a SHOP UPGRADE. The existing analytics test only asserts a
-- currency_spent fired AT ALL, which an island-unlock spend alone satisfies. Here we require a
-- currency_spent tagged to the UPGRADE purchase (payload.upgradeId names the bought upgrade, and it
-- carries NO island sink), so the assertion is NOT satisfiable by island-unlock's currency_spent (which
-- is tagged sink="island_unlock" + islandId, with no upgradeId). FALSIFIABLE: a shop buy that stopped
-- emitting currency_spent (or tagged it like an island unlock) makes this RED even with island-unlock
-- spends present.
-- =====================================================================================================
describe(
	"Analytics: currency_spent is emitted for a SHOP UPGRADE (distinct from island-unlock)",
	function()
		it(
			"a shop BuyUpgrade emits a currency_spent tagged to the upgrade; an island unlock does NOT satisfy it",
			function()
				local g = buildGame()
				local p = Mocks.player(82, "Shopper")
				g:join(p)
				setStardust(g, p, 50000) -- afford the upgrade AND an island unlock

				-- Do an ISLAND UNLOCK FIRST, so an island-tagged currency_spent already exists. If the gap test
				-- merely asserted ">= 1 currency_spent", this unlock alone would (wrongly) satisfy it.
				expect(g.invoke(A.UnlockIsland, p, { islandId = 2 })):toBeOk()

				-- Now buy a SHOP UPGRADE. The buy's currency_spent must carry the upgradeId of the bought kind.
				local buy = g.invoke(A.BuyUpgrade, p, { upgradeId = "magnet" })
				expect(buy):toBeOk()
				local spentCost = (buy :: any).value.cost
				expect(spentCost > 0):toBe(true)

				-- Scan currency_spent for one tagged to the UPGRADE: payload.upgradeId == "magnet". An island
				-- unlock's currency_spent has NO upgradeId (it carries sink="island_unlock" + islandId), so this
				-- match is satisfiable ONLY by the shop buy's emission -- exactly the coverage the gap demands.
				local sawUpgradeSpend = false
				for _, e in g.analytics:eventsOfType("currency_spent") do
					if e.payload ~= nil and e.payload.upgradeId == "magnet" then
						sawUpgradeSpend = true
						-- It is the upgrade's spend, NOT an island unlock's: the upgrade tag is present and the
						-- island sink tag is absent on this same event.
						expect(e.payload.sink):toBe(nil)
						expect(e.payload.amount):toBe(spentCost) -- the server-derived cost, the real spend
					end
				end
				expect(sawUpgradeSpend):toBe(true)

				-- Sanity that we did NOT just match the island unlock: the island-unlock currency_spent exists and
				-- is tagged differently (sink="island_unlock", no upgradeId), so the gap-3 match is genuinely
				-- upgrade-specific and could not have been satisfied by the unlock spend alone.
				local sawIslandSpend = false
				for _, e in g.analytics:eventsOfType("currency_spent") do
					if e.payload ~= nil and e.payload.sink == "island_unlock" then
						sawIslandSpend = true
						expect(e.payload.upgradeId):toBe(nil) -- the island spend carries NO upgradeId
					end
				end
				expect(sawIslandSpend):toBe(true)
			end
		)
	end
)

-- =====================================================================================================
-- V5 TEST A -- the persisted 2x BOOST SURVIVES a rejoin, end-to-end. Buy the 30-min 2x boost
-- (ProcessReceipt 201 via the live monetization seam), LEAVE (g:leave releases -> saves the persisted
-- blob, incl. boostExpiresUnix), advance the server clock a LITTLE (< 30 min), REJOIN (g:join ->
-- loadSession re-loads the persisted blob), and prove the boost is STILL active: an identical sell pays
-- 2x the pre-boost baseline. FALSIFIABLE: a session-only (in-memory) boost would be LOST on the rejoin
-- and the post-rejoin sell would pay 1x, making the toBe(base * 2) RED.
-- =====================================================================================================
describe(
	"V5: the persisted 2x boost SURVIVES a leave -> rejoin lifecycle (reaches Sell after rejoin)",
	function()
		local SECONDS_PER_DAY = 86400

		local function collectAndSell(g: Game, p: any, n: number): number
			for _ = 1, n do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local r = g.invoke(A.Sell, p, {})
			expect(r):toBeOk()
			return (r :: any).value.earned
		end

		it(
			"buy boost -> leave -> advance < 30min -> rejoin -> a sell still pays 2x the baseline",
			function()
				-- ISOLATE the restock vein: day 12 -> 12%5==2 -> vein island 3 (never unlocked here), so restock
				-- stays 1 in BOTH sells; the player keeps only island 1 (island mult 1) and never rebirths. The ONLY
				-- factor that can differ between the baseline and the post-rejoin sell is the persisted 2x boost.
				local g = buildGame({ startUnix = 12 * SECONDS_PER_DAY + 100 })
				local p = Mocks.player(83, "Returner2x")
				g:join(p)

				-- Baseline sell with NO boost (island 1, vein island 3 -> restock 1, rebirths 0).
				local base = collectAndSell(g, p, 50)
				expect(base > 0):toBe(true)

				-- Buy the 30-min 2x boost through the LIVE monetization seam (server-driven receipt, not a client
				-- action). This STAMPS the persisted boostExpiresUnix inside the lock-held receipt transform.
				local mon = g.context.monetization
				local pr = mon:ProcessReceipt({
					PlayerId = p.UserId,
					ProductId = 201,
					PurchaseId = "v5a-boost",
				})
				expect(pr):toBeOk()
				expect((pr :: any).value.granted):toBe(true)
				expect(mon:hasActiveBoost(p.UserId)):toBe(true) -- armed before we leave

				-- LEAVE: the PlayerRemoving path releases the session, SAVING the persisted blob (incl.
				-- boostExpiresUnix) to the store's backing -- the crash/leave half of the round-trip.
				g:leave(p)

				-- Advance the server clock a LITTLE: well under the 30-min (1800s) window so the boost is still live.
				g.clock:advance(600) -- 10 minutes away, < 30-min boost

				-- REJOIN: loadSession re-loads the persisted blob over the SAME backing store. A session-only boost
				-- would be GONE here; a PERSISTED boostExpiresUnix comes back and is still in the future.
				g:join(p)
				expect(mon:hasActiveBoost(p.UserId)):toBe(true) -- the persisted boost survived the rejoin

				-- A subsequent identical sell pays 2x the baseline: the RESTORED persisted boost reached the Sell
				-- formula via ctx.monetization:stardustMultiplierFor read off the lock-held snapshot. (Same island,
				-- same vein-island-3 restock, same rebirths -> the boost is the only differing factor: exactly 2x.)
				local boosted = collectAndSell(g, p, 50)
				expect(boosted):toBe(base * 2)
			end
		)
	end
)

-- =====================================================================================================
-- V5 TEST B -- the server-side gamepass GRANT path composes into Sell, end-to-end. Use the REAL grant
-- path (ctx.monetization:syncGamepassesFor with an injected ownership predicate that OWNS the 2x pass
-- 1001) to set the persisted gamepass.2xStardust flag, then prove a subsequent sell pays 2x. This is
-- the GRANT path (server-verified ownership -> persisted flag -> Sell formula), NOT a hand-set flag.
-- FALSIFIABLE: if the grant path failed to reach the persisted flag or the Sell formula, the sell would
-- stay 1x and the toBe(base * 2) goes RED.
-- =====================================================================================================
describe(
	"V5: the server-side gamepass GRANT path reaches the Sell formula (2x), end-to-end",
	function()
		local SECONDS_PER_DAY = 86400
		local TWO_X_GAMEPASS_ID = 1001 -- catalog: 1001 -> 'gamepass.2xStardust'

		local function collectAndSell(g: Game, p: any, n: number): number
			for _ = 1, n do
				expect(g.invoke(A.Collect, p, {})):toBeOk()
			end
			local r = g.invoke(A.Sell, p, {})
			expect(r):toBeOk()
			return (r :: any).value.earned
		end

		it(
			"syncGamepassesFor(owns 1001) persists the flag through the grant path, so a sell pays 2x",
			function()
				-- ISOLATE restock: day 12 -> vein island 3 (never unlocked) -> restock 1 in both sells. Island 1
				-- only (mult 1), rebirths 0: the gamepass-granted 2x flag is the only factor that can differ.
				local g = buildGame({ startUnix = 12 * SECONDS_PER_DAY + 100 })
				local p = Mocks.player(84, "GrantedWhale")
				g:join(p)
				local mon = g.context.monetization

				-- Baseline sell BEFORE any grant (the 2x flag is not set yet).
				local base = collectAndSell(g, p, 50)
				expect(base > 0):toBe(true)
				expect(mon:stardustMultiplier(p.UserId)):toBe(1) -- no flag granted yet

				-- The REAL server-side GRANT path: an injected ownership predicate that OWNS the 2x gamepass (1001),
				-- standing in for UserOwnsGamePassAsync. syncGamepassesFor writes the persisted gamepass.2xStardust
				-- flag through the lock path -- a flag NEVER set from a client action.
				local function ownsTwoX(_userId: number, gamePassId: number): boolean
					return gamePassId == TWO_X_GAMEPASS_ID
				end
				mon:syncGamepassesFor(p.UserId, ownsTwoX)

				-- The grant reached the PERSISTED store (read back through the lock-queued data layer)...
				expect(dataOf(g, p).flags["gamepass.2xStardust"]):toBe(true)
				-- ...and lifted the seam to 2.
				expect(mon:stardustMultiplier(p.UserId)):toBe(2)

				-- A subsequent identical sell pays 2x: the GRANT-PATH flag reached the consolidated Sell formula via
				-- ctx.monetization:stardustMultiplierFor read off the lock-held snapshot. Only the granted 2x flag
				-- differs from the baseline (same island, same vein-island-3 restock, same rebirths) -> exactly 2x.
				local granted = collectAndSell(g, p, 50)
				expect(granted):toBe(base * 2)
			end
		)
	end
)
