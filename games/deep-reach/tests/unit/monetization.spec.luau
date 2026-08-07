--!strict
-- games/deep-reach/tests/unit/monetization.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/monetization.md, NOT
--  from MonetizationService's control flow. The implementation was read ONLY to learn its observable
--  interface (the entry points, the return shapes, the injectable `_ownsPass` seam, the id setters);
--  every EXPECTATION below is derived from the slice, and every economic number is DISCOVERED
--  through the public API (`:productFor`, `:passFor`, `.BOOST_SECONDS`, DepthService:tierAt,
--  ctx.salvage:rateFor) rather than copied out of the module. A build that re-tunes a Credit pack's
--  amount or the VIP trench's price stays green here; a build that stops applying one of them, or
--  that grants a receipt twice, goes red.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   1. "GAMEPASS OWNERSHIP, GRANTED SERVER-SIDE ONLY ... recorded as persisted `flags['gamepass.*']`
--      booleans that gate each effect (never set from a client action)." / "There is deliberately NO
--      Net action for this — a client-settable gamepass flag is a free gamepass." / "Emit `purchase`
--      on a false->true transition." / "Both API calls can throw/yield: pcall them, retry within
--      budget, and never let a failed check clear an already-granted flag."
--   2. "THE EFFECTS ARE READ BY OTHER FEATURES, and your gate must prove each one actually lands:
--      `doubleCredits` and the boost multiply the value `ctx.salvage:rateFor` returns; `autoCollect`
--      makes Salvage core's tick empty the smelter with no manual collect; `vipTrench` is what lets
--      Depth tiers enter the exclusive tier (Err(PrereqUnmet) without it). Assert each as a DELTA on
--      the running rate / on the gate outcome — a flag written and never read is the exact defect
--      class this game is graded against."
--   3. "DEV PRODUCTS via `MarketplaceService.ProcessReceipt`, IDEMPOTENTLY ... The receipt id is
--      recorded in the `receipts` ledger and the grant is applied in the SAME DataService:update — an
--      already-present receipt id grants nothing and returns PurchaseGranted; ANY failure returns
--      `Enum.ProductPurchaseDecision.NotProcessedYet`. Replaying the same receipt must never
--      double-grant. Emit `purchase` after the grant commits."
--      Credit packs "grant Credits through ctx.economy:earn, which increments stats.lifetimeCredits
--      and emits currency_earned"; the boost sets "`boostExpiresUnix = ctx.clock:unix() + 1800`,
--      EXTENDING from the later of now and the current expiry so a stacked purchase is never
--      silently swallowed".
--   4. "REAL MONEY GUARD: if `ctx.persistenceDegraded` is true ... Do not acknowledge a receipt as
--      processed; return NotProcessedYet so Roblox re-delivers it to a healthy server."
--   5. "THE BOOST IS PERSISTED: `boostExpiresUnix` survives a crash/rejoin."
--   A2. AUTO-COLLECT: "you GRANT the flag and your gate ASSERTS the effect lands. SalvageService
--      already implements the auto-collect grant as ONE shared path."
--   A6. "`boostExpiresUnix` ... SURVIVES a resurface untouched ... a boost bought, then a resurface
--      performed, must leave the remaining boost time intact AND still multiplying the running rate."
--   PERSISTENCE: "`boostExpiresUnix: number` at schema v6->v7".
--
-- WHY EVERY ECONOMIC CASE ASSERTS A DELTA. This game is graded against the written-never-read
-- pattern, whose economic twin is the write-only assertion: a test that checks "the flag is true" or
-- "boostExpiresUnix moved" passes against a purchase that changes no rule in the game. So the three
-- gamepasses and the boost are asserted through their READERS — the number ctx.salvage:rateFor
-- returns, the smelter the tick empties, the code DepthService:descend refuses with — and every
-- receipt case snapshots currencies.Credits, stats.lifetimeCredits, the `receipts` ledger size and
-- the currency_earned / purchase event counts BEFORE and AFTER, then compares the difference.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The exploit this feature is one mistake away from is the
-- receipt replay: read `receipts[id]`, YIELD, then grant and stamp — two deliveries of the SAME
-- receipt both observe "not processed" before either writes, and Roblox pays once while the player is
-- credited twice. Sequential calls cannot distinguish a correct implementation from that one,
-- because nothing ever interleaves. So the race cases drive the economy_race.spec idiom: a MockStore
-- with `yieldOnUpdate` (a forced yield INSIDE the update critical section) plus a round-robin
-- coroutine driver, a counting data proxy whose `peak` in-flight count proves the interleave is real,
-- and a FALSIFICATION counter-case (a naive read-ledger-then-yield-then-grant handler driven at the
-- same yield point) that DOES double-grant. The service also carries an in-memory single-flight
-- reservation that would short-circuit the interleave before it ever reached the data layer and make
-- the race vacuous — so the headline case NEUTRALISES it and proves the lock-held transform alone
-- grants exactly once, which is precisely the guarantee the slice states.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local DepthService = require("../../src/server/services/depth/DepthService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Migrations = require("../../src/shared/Migrations")
local MonetizationService = require("../../src/server/services/monetization/MonetizationService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000

-- The persisted flag keys, quoted from the slice ("`flags[\"gamepass.doubleCredits\"]`, …") rather
-- than read off the module: a build that renames one of these ships three inert purchases, and the
-- readers (SalvageService, DepthService) would go on reading the old key in silence.
local DOUBLE_CREDITS_FLAG = "gamepass.doubleCredits"
local AUTO_COLLECT_FLAG = "gamepass.autoCollect"
local VIP_TRENCH_FLAG = "gamepass.vipTrench"

-- Asset ids a published place would carry. The catalog ships with 0 = NOT CONFIGURED (a real id only
-- exists once a human has created the pass/product on a published place), so every server below
-- stamps these through the documented setters before driving the paths that need an id.
local PASS_IDS: { [string]: number } = {
	doubleCredits = 71001,
	autoCollect = 71002,
	vipTrench = 71003,
}
local PRODUCT_IDS: { [string]: number } = {
	creditPackS = 81001,
	creditPackM = 81002,
	creditPackL = 81003,
	boost30 = 81004,
}

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

local function countKeys(map: any): number
	if type(map) ~= "table" then
		return 0
	end
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

-- Relative-tolerance float comparison: the running rate is a PRODUCT of tuned steps, so exact binary
-- equality is not available for the composed cases — but the guarantee under test ("this multiplier
-- reaches the number") is about magnitude, not about the last bit.
local function expectClose(actual: number, expected: number, why: string): ()
	local tolerance = 1e-9 * math.max(1, math.abs(actual), math.abs(expected))
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		error(`{why}: got {tostring(actual)}, want {tostring(expected)}`, 0)
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
			error("monetization race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`monetization race coroutine errored: {tostring(err)}`, 0)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- A pass-through ctx.data that COUNTS what actually reached the data layer AND tracks the PEAK
-- number of updates in flight simultaneously. `updates` alone cannot tell an interleave from two
-- strictly sequential calls, so if MockStore's forced yield were ever lost every race case below
-- would silently degrade to two sequential deliveries and stay green. `peak` is the guard: it can
-- only reach 2 if the second delivery entered ctx.data:update while the first was still parked.
local function countingData(data: any): any
	local proxy: any = { updates = 0, saves = 0, gets = 0, inFlight = 0, peak = 0 }
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
	function proxy.save(self: any, player: any): any
		self.saves += 1
		return data:save(player)
	end
	function proxy.get(self: any, player: any): any
		self.gets += 1
		return data:get(player)
	end
	return proxy
end

-- Run `body` with a service-owned in-memory reservation table neutralised, so an interleaved pair
-- genuinely reaches the data layer. The slice's stated mechanism is the ledger check + stamp + grant
-- inside ONE DataService:update; a per-server memo is belt-and-braces for it (and says nothing about
-- the same receipt re-delivered to another server), so the guarantee must hold WITHOUT it. The real
-- table is ALWAYS restored, even on throw.
local function withoutMemo(field: string, body: () -> ()): ()
	local real = (MonetizationService :: any)[field];
	(MonetizationService :: any)[field] = setmetatable({}, {
		__newindex = function() end, -- every reservation is silently dropped
	}) :: any
	local ok, err = pcall(body);
	(MonetizationService :: any)[field] = real
	if not ok then
		error(err, 0)
	end
end

-- Point the shared catalogs at "published" ids. PASSES / PRODUCTS are MODULE state (one table for
-- the whole process), so every server re-stamps them and the id-0 cases restore afterwards.
local function stampIds(): ()
	for key, id in PASS_IDS do
		expect(MonetizationService:setGamePassId(key, id)):toBe(true)
	end
	for key, id in PRODUCT_IDS do
		expect(MonetizationService:setProductId(key, id)):toBe(true)
	end
end

-- Run `body` with one catalog entry back in its UNCONFIGURED (id 0) state; always restored.
local function withUnconfiguredPass(key: string, body: () -> ()): ()
	expect(MonetizationService:setGamePassId(key, 0)):toBe(true)
	local ok, err = pcall(body)
	expect(MonetizationService:setGamePassId(key, PASS_IDS[key])):toBe(true)
	if not ok then
		error(err, 0)
	end
end

local function withUnconfiguredProduct(key: string, body: () -> ()): ()
	expect(MonetizationService:setProductId(key, 0)):toBe(true)
	local ok, err = pcall(body)
	expect(MonetizationService:setProductId(key, PRODUCT_IDS[key])):toBe(true)
	if not ok then
		error(err, 0)
	end
end

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, and MonetizationService Started against a recording `net` that forwards every
-- registration into a REAL Net registry — so "this feature registers no action" is asserted against
-- the same pipeline the live wire uses, not against a counter.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	-- MockStore reads these off this LIVE table on every call, so a case can arm the forced yield (or
	-- a failing durable write) at exactly the moment it needs it. That matters: the forced yield parks
	-- the CALLING coroutine, and a spec's setup writes run on the main thread — parking that thread
	-- leaves nothing to resume it and the whole run ends silently.
	local storeOptions: any = {
		clock = clock,
		config = Config,
		yieldOnUpdate = false,
		failSave = opts.failSave == true,
		seed = opts.seed,
	}
	local store = Mocks.store(storeOptions)
	local data = DataService.new(store, clock, Config, Mocks.logWarn)
	local analytics = AnalyticsService.new(clock)
	local economy = EconomyService.new(analytics)

	local wire = Mocks.net({ clock = clock, data = data, gate = false, economy = economy })
	local registered: { string } = {}
	local pushes: { any } = {}
	local net: any = {}
	function net.register(_self: any, action: any): ()
		table.insert(registered, action.name)
		wire.register(action)
	end
	function net.fireClient(_self: any, player: any, channel: string, payload: any): ()
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local context: any = {
		clock = clock,
		data = data,
		net = net,
		economy = economy,
		analytics = analytics,
		persistenceDegraded = opts.persistenceDegraded,
	}

	stampIds()
	MonetizationService._ownsPass = opts.ownsPass
	MonetizationService:Start(context)

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		net = net,
		wire = wire,
		registered = registered,
		pushes = pushes,
		context = context,
		storeOptions = storeOptions,
	}

	-- The ServerContext a direct call receives. `overrides` lets one case swap a single seam (a
	-- missing economy, a refusing economy, a counting data layer, a degraded store) without
	-- rebuilding the world.
	function h.ctx(self: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			net = if o.noNet == true then nil else self.net,
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			analytics = self.analytics,
			depth = self.context.depth,
			salvage = self.context.salvage,
			persistenceDegraded = o.persistenceDegraded,
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

	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	function h.grant(self: any, player: any, passKey: string, overrides: any?): any
		return MonetizationService:grantPass(self:ctx(overrides), player, passKey)
	end

	function h.sync(self: any, player: any, overrides: any?): any
		return MonetizationService:syncPasses(self:ctx(overrides), player)
	end

	function h.prompt(self: any, player: any, gamePassId: any, wasPurchased: any): any
		return MonetizationService:onPromptFinished(self:ctx(), player, gamePassId, wasPurchased)
	end

	function h.process(self: any, player: any, receiptInfo: any, overrides: any?): any
		return MonetizationService:processReceipt(self:ctx(overrides), player, receiptInfo)
	end

	-- The earn-side + ledger + analytics state, as ONE snapshot, so every case can assert a DELTA.
	-- Nil-safe on `stats` because one case deliberately drives a blob whose stats table is missing.
	function h.snap(self: any, player: any): any
		local blob = self:blob(player)
		local lifetime = 0
		if type(blob.stats) == "table" and type(blob.stats.lifetimeCredits) == "number" then
			lifetime = blob.stats.lifetimeCredits
		end
		return {
			balance = self.economy:balanceOf(blob, "Credits"),
			lifetime = lifetime,
			boost = blob.boostExpiresUnix,
			receipts = countKeys(blob.receipts),
			purchases = #self.analytics:eventsOfType("purchase"),
			earns = #self.analytics:eventsOfType("currency_earned"),
			flags = countKeys(blob.flags),
		}
	end

	-- The DERIVED running rate, read through the ctx.salvage seam exactly as Salvage core does.
	function h.rate(self: any, player: any, atUnix: number?): number
		local blob = self:blob(player)
		return self.context.salvage:rateFor(blob, atUnix or self.clock:unix(), self.context.depth)
	end

	function h.startSalvage(self: any): ()
		SalvageService:Start(self.context)
	end

	function h.startDepth(self: any): ()
		DepthService:Start(self.context)
	end

	return h
end

-- A receipt as Roblox delivers one. `PurchaseId` is the per-PURCHASE identity; `CurrencySpent` is
-- Robux the player paid and is deliberately present-but-irrelevant (a build that treated it as an
-- amount would let the Robux price silently re-tune the economy).
local function receiptFor(player: any, productKey: string, purchaseId: any, extra: any?): any
	local info: any = {
		PurchaseId = purchaseId,
		ProductId = PRODUCT_IDS[productKey],
		PlayerId = player.UserId,
		CurrencySpent = 99,
		CurrencyType = "Robux",
		PlaceIdWherePurchased = 1234,
	}
	if extra ~= nil then
		for key, value in extra do
			info[key] = value
		end
	end
	return info
end

local function productAmount(key: string): number
	local entry = MonetizationService:productFor(key)
	if entry == nil then
		error(`the catalog has no product "{key}" — the spec names Credit packs S/M/L`, 0)
	end
	return (entry :: any).amount
end

local function boostSeconds(): number
	local entry = MonetizationService:productFor("boost30")
	if entry == nil then
		error("the catalog has no 30-min boost product", 0)
	end
	return (entry :: any).seconds
end

local GRANTED = MonetizationService.GRANTED
local NOT_PROCESSED = MonetizationService.NOT_PROCESSED

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 1. THE WIRE SURFACE — there is NO client action, because a client-settable flag is a free pass
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe(
	"monetization: the wire surface (a client-settable gamepass flag is a free gamepass)",
	function()
		it(
			"Start registers NO action at all — nothing this feature does crosses the gateway",
			function()
				local h = newServer()
				expect(#h.registered):toBe(0)
				expect(#h.wire.registry:names()):toBe(0)
			end
		)

		it("no plausible monetization action name is dispatchable -> Err(UnknownAction)", function()
			local h = newServer()
			local player = h:join(1)
			for _, name in
				{
					"monetization.grant",
					"monetization.buy",
					"monetization.receipt",
					"monetization.setflag",
					"gamepass.grant",
					"gamepass.claim",
					"boost.buy",
					"product.redeem",
				}
			do
				expect(h.wire.invoke(name, player, {})):toBeErr(Result.Codes.UnknownAction)
			end
		end)

		it("the shared action registry declares no monetization/gamepass/receipt action", function()
			for key, name in Net.Actions do
				local lowered = string.lower(tostring(name))
				for _, banned in { "monet", "gamepass", "receipt", "product", "boost", "purchase" } do
					if string.find(lowered, banned, 1, true) ~= nil then
						error(
							`Net.Actions.{tostring(key)} = "{tostring(name)}" exposes monetization on the `
								.. `client wire; the slice states there is deliberately NO Net action`,
							0
						)
					end
				end
			end
		end)

		it(
			"`purchase` is a declared analytics event (the taxonomy this feature emits into)",
			function()
				local h = newServer()
				expect(h.analytics:isKnownEvent("purchase")):toBe(true)
			end
		)
	end
)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 2. GAMEPASS OWNERSHIP — granted server-side only, false -> true only, never cleared
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("monetization: gamepass ownership is granted SERVER-SIDE into persisted flags", function()
	it("a granted pass writes exactly its own persisted flag key, and no other", function()
		local h = newServer()
		local player = h:join(1)
		expect(countKeys(h:blob(player).flags)):toBe(0)

		local granted = h:grant(player, "doubleCredits")
		expect(granted):toBeOk()
		expect((granted :: any).value.granted):toBe(true)
		expect((granted :: any).value.owned):toBe(true)

		local flags = h:blob(player).flags
		expect(flags[DOUBLE_CREDITS_FLAG]):toBe(true)
		expect(flags[AUTO_COLLECT_FLAG]):toBe(nil)
		expect(flags[VIP_TRENCH_FLAG]):toBe(nil)
		expect(countKeys(flags)):toBe(1)
	end)

	it("each of the three passes writes the flag key its READER looks at", function()
		local h = newServer()
		local player = h:join(1)
		for key, flag in
			{
				doubleCredits = DOUBLE_CREDITS_FLAG,
				autoCollect = AUTO_COLLECT_FLAG,
				vipTrench = VIP_TRENCH_FLAG,
			}
		do
			expect(h:grant(player, key)):toBeOk()
			expect(h:blob(player).flags[flag]):toBe(true)
		end
		expect(countKeys(h:blob(player).flags)):toBe(3)
	end)

	it("`purchase` is emitted ONCE, on the false->true transition only", function()
		local h = newServer()
		local player = h:join(1)
		expect(#h.analytics:eventsOfType("purchase")):toBe(0)

		expect(h:grant(player, "vipTrench")):toBeOk()
		local emitted = h.analytics:eventsOfType("purchase")
		expect(#emitted):toBe(1)
		expect(emitted[1].payload.kind):toBe("gamepass")
		expect(emitted[1].payload.flag):toBe(VIP_TRENCH_FLAG)
		expect(emitted[1].payload.userId):toBe(1)

		-- Re-granting (every join, forever) is idempotent and SILENT.
		local again = h:grant(player, "vipTrench")
		expect(again):toBeOk()
		expect((again :: any).value.granted):toBe(false)
		expect((again :: any).value.owned):toBe(true)
		expect(#h.analytics:eventsOfType("purchase")):toBe(1)
	end)

	it(
		"an unknown pass key grants nothing -> Err(BadType) (no free flag from a bad name)",
		function()
			local h = newServer()
			local player = h:join(1)
			for _, key in { "", "gamepass.vipTrench", "vip", "doublecredits", "__index" } do
				expect(h:grant(player, key)):toBeErr(Result.Codes.BadType)
			end
			expect(countKeys(h:blob(player).flags)):toBe(0)
			expect(#h.analytics:eventsOfType("purchase")):toBe(0)
		end
	)

	it("a player with no numeric UserId grants nothing -> Err(BadType)", function()
		local h = newServer()
		h:join(1)
		expect(h:grant({ Name = "spoof" }, "doubleCredits")):toBeErr(Result.Codes.BadType)
		expect(h:grant({ UserId = "1", Name = "spoof" }, "doubleCredits")):toBeErr(
			Result.Codes.BadType
		)
		expect(h:grant({ UserId = 0 / 0, Name = "spoof" }, "doubleCredits")):toBeErr(
			Result.Codes.BadType
		)
	end)

	it(
		"granting before the session loads writes nothing and surfaces the data layer's Err",
		function()
			local h = newServer()
			local player = Mocks.player(9) -- never loadSession'd
			local granted = h:grant(player, "autoCollect")
			expect(granted):toBeErr(Result.Codes.NoData)
			expect(#h.analytics:eventsOfType("purchase")):toBe(0)
		end
	)

	it("a granted flag SURVIVES a save/release/rejoin round trip (it is persisted)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:grant(player, "doubleCredits")):toBeOk()
		h:leave(player)

		local rejoined = h:join(1)
		expect(h:blob(rejoined).flags[DOUBLE_CREDITS_FLAG]):toBe(true)
	end)
end)

describe("monetization: the ownership PROBE never costs a player a pass they paid for", function()
	it("syncPasses grants exactly the passes Roblox says are owned", function()
		local asked: { number } = {}
		local h = newServer({
			ownsPass = function(_userId: number, gamePassId: number): boolean
				table.insert(asked, gamePassId)
				return gamePassId == PASS_IDS.autoCollect
			end,
		})
		local player = h:join(1)
		local summary = h:sync(player)
		expect(summary):toBeOk()
		expect((summary :: any).value.checked):toBe(3)
		expect((summary :: any).value.skipped):toBe(0)
		expect((summary :: any).value.owned):toBe(1)
		expect((summary :: any).value.granted):toBe(1)
		expect(#asked):toBe(3)

		local flags = h:blob(player).flags
		expect(flags[AUTO_COLLECT_FLAG]):toBe(true)
		expect(countKeys(flags)):toBe(1)
	end)

	it("an authoritative `false` NEVER clears a flag that is already granted", function()
		local h = newServer({
			ownsPass = function(): boolean
				return false -- Roblox now says: owns nothing
			end,
		})
		local player = h:join(1)
		expect(h:grant(player, "vipTrench")):toBeOk()

		local summary = h:sync(player)
		expect(summary):toBeOk()
		expect((summary :: any).value.owned):toBe(0)
		-- The only write this path may make is false -> true. Wrongly clearing takes away something a
		-- player paid real money for.
		expect(h:blob(player).flags[VIP_TRENCH_FLAG]):toBe(true)
	end)

	it("a THROWING probe writes nothing at all and never clears a granted flag", function()
		local calls = 0
		local h = newServer({
			ownsPass = function(): boolean
				calls += 1
				error("UserOwnsGamePassAsync: HTTP 503")
			end,
		})
		local player = h:join(1)
		expect(h:grant(player, "doubleCredits")):toBeOk()

		local summary = h:sync(player)
		expect(summary):toBeOk()
		expect((summary :: any).value.failed):toBe(3) -- all three configured probes gave no answer
		expect((summary :: any).value.owned):toBe(0)
		expect((summary :: any).value.granted):toBe(0)
		-- Retried within a bounded budget: three passes, each retried, and the budget is finite.
		expect(calls > 3):toBe(true)
		expect(calls <= 3 * MonetizationService.PASS_CHECK_ATTEMPTS):toBe(true)

		local flags = h:blob(player).flags
		expect(flags[DOUBLE_CREDITS_FLAG]):toBe(true)
		expect(countKeys(flags)):toBe(1)
	end)

	it("a probe that throws then succeeds still grants (the retry is within budget)", function()
		local calls = 0
		local h = newServer({
			ownsPass = function(_userId: number, gamePassId: number): boolean
				calls += 1
				if calls == 1 then
					error("UserOwnsGamePassAsync: timeout")
				end
				return gamePassId == PASS_IDS.doubleCredits
			end,
		})
		local player = h:join(1)
		local summary = h:sync(player)
		expect(summary):toBeOk()
		expect((summary :: any).value.failed):toBe(0)
		expect(h:blob(player).flags[DOUBLE_CREDITS_FLAG]):toBe(true)
	end)

	it("an UNCONFIGURED pass (id 0) is never asked about and never granted", function()
		local asked: { number } = {}
		local h = newServer({
			ownsPass = function(_userId: number, gamePassId: number): boolean
				table.insert(asked, gamePassId)
				return true -- would grant everything it is asked about
			end,
		})
		local player = h:join(1)
		withUnconfiguredPass("vipTrench", function()
			local summary = h:sync(player)
			expect(summary):toBeOk()
			expect((summary :: any).value.skipped):toBe(1)
			expect((summary :: any).value.checked):toBe(2)
		end)
		for _, id in asked do
			expect(id ~= 0):toBe(true)
		end
		-- The paywalled trench is NOT granted by an unpublished catalog entry.
		expect(h:blob(player).flags[VIP_TRENCH_FLAG]):toBe(nil)
		expect(h:blob(player).flags[DOUBLE_CREDITS_FLAG]):toBe(true)
	end)
end)

describe("monetization: PromptGamePassPurchaseFinished (the fresh-purchase path)", function()
	it("wasPurchased == true on a known id grants exactly that pass", function()
		local h = newServer()
		local player = h:join(1)
		local granted = h:prompt(player, PASS_IDS.autoCollect, true)
		expect(granted):toBeOk()
		expect((granted :: any).value.flag):toBe(AUTO_COLLECT_FLAG)
		expect(h:blob(player).flags[AUTO_COLLECT_FLAG]):toBe(true)
		expect(countKeys(h:blob(player).flags)):toBe(1)
	end)

	it("a prompt the player did NOT complete writes nothing -> Err(Rejected)", function()
		local h = newServer()
		local player = h:join(1)
		for _, spoof in { false, nil, 1, "true", {}, 0 } do
			expect(h:prompt(player, PASS_IDS.vipTrench, spoof)):toBeErr(Result.Codes.Rejected)
		end
		expect(countKeys(h:blob(player).flags)):toBe(0)
		expect(#h.analytics:eventsOfType("purchase")):toBe(0)
	end)

	it("an unknown / malformed gamePassId grants nothing -> Err(BadType)", function()
		local h = newServer()
		local player = h:join(1)
		for _, id in { 999999, 0, -1, 0 / 0, math.huge, "71001", {}, nil } do
			expect(h:prompt(player, id, true)):toBeErr(Result.Codes.BadType)
		end
		expect(countKeys(h:blob(player).flags)):toBe(0)
	end)

	it("an UNCONFIGURED (id 0) pass cannot be claimed by prompting id 0", function()
		local h = newServer()
		local player = h:join(1)
		withUnconfiguredProduct("boost30", function()
			-- unrelated product left unconfigured on purpose; the pass under test is below
		end)
		withUnconfiguredPass("doubleCredits", function()
			expect(h:prompt(player, 0, true)):toBeErr(Result.Codes.BadType)
			expect(h:prompt(player, PASS_IDS.doubleCredits, true)):toBeErr(Result.Codes.BadType)
		end)
		expect(countKeys(h:blob(player).flags)):toBe(0)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 3. THE EFFECTS LAND — each pass asserted as a DELTA on its READER, never as a field that moved
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("monetization: the 2x Credits pass moves the RUNNING RATE (not just a flag)", function()
	it("granting doubleCredits exactly doubles ctx.salvage:rateFor", function()
		local h = newServer()
		h:startSalvage()
		local player = h:join(1)

		local before = h:rate(player)
		expect(before > 0):toBe(true) -- non-vacuous: there is a rate to double

		expect(h:grant(player, "doubleCredits")):toBeOk()
		expectClose(h:rate(player), before * 2, "doubleCredits must double the running rate")
	end)

	it("the 30-min boost doubles the rate, and STOPS doubling it at the expiry", function()
		local h = newServer()
		h:startSalvage()
		local player = h:join(1)

		local before = h:rate(player)
		local now = h.clock:unix()
		local outcome = h:process(player, receiptFor(player, "boost30", "boost-1"))
		expect(outcome.decision):toBe(GRANTED)

		local expiry = h:blob(player).boostExpiresUnix
		expect(expiry):toBe(now + boostSeconds())
		expectClose(h:rate(player, now), before * 2, "an active boost must double the running rate")
		expectClose(
			h:rate(player, expiry - 1),
			before * 2,
			"the boost must still apply one second before it expires"
		)
		-- The slice pins the reader as `now < data.boostExpiresUnix`: AT the expiry it is over.
		expectClose(
			h:rate(player, expiry),
			before,
			"the boost must not apply at the expiry instant"
		)
		expectClose(h:rate(player, expiry + 60), before, "an expired boost must not apply")
	end)

	it("the pass and the boost STACK (both multipliers reach the number)", function()
		local h = newServer()
		h:startSalvage()
		local player = h:join(1)

		local before = h:rate(player)
		local now = h.clock:unix()
		expect(h:grant(player, "doubleCredits")):toBeOk()
		expect(h:process(player, receiptFor(player, "boost30", "boost-2")).decision):toBe(GRANTED)

		expectClose(h:rate(player, now), before * 4, "2x pass AND 2x boost must compose to 4x")
	end)
end)

describe(
	"monetization: the Auto-Collect pass makes the TICK empty the smelter (AMENDMENT A2)",
	function()
		it(
			"without the flag the tick accrues and NEVER pays out; with it, the tick pays out",
			function()
				local h = newServer()
				h:startSalvage()
				local player = h:join(1)

				-- The first tick ARMS the session (the away window belongs to offline accrual); accrual starts
				-- after it.
				expect(SalvageService:tickPlayer(h.context, player)):toBeOk()
				h.clock:advance(120)

				local beforeNoFlag = h:snap(player)
				local ticked = SalvageService:tickPlayer(h.context, player)
				expect(ticked):toBeOk()
				local afterNoFlag = h:snap(player)
				-- No pass: the smelter fills and the player's earn-side numbers do NOT move.
				expect(h:blob(player).smelter.storedCredits > 0):toBe(true)
				expect(afterNoFlag.balance - beforeNoFlag.balance):toBe(0)
				expect(afterNoFlag.lifetime - beforeNoFlag.lifetime):toBe(0)
				expect(afterNoFlag.earns - beforeNoFlag.earns):toBe(0)

				-- Now BUY the pass — server-side — and tick again with no manual collect anywhere.
				expect(h:grant(player, "autoCollect")):toBeOk()
				h.clock:advance(120)
				local beforeFlag = h:snap(player)
				local stored = h:blob(player).smelter.storedCredits
				expect(stored > 0):toBe(true)

				expect(SalvageService:tickPlayer(h.context, player)):toBeOk()
				local afterFlag = h:snap(player)
				local paid = afterFlag.balance - beforeFlag.balance

				expect(h:blob(player).smelter.storedCredits):toBe(0) -- the smelter was emptied by the tick
				expect(paid >= stored):toBe(true) -- at least the stored amount, plus this tick's accrual
				-- A2: ONE shared grant path, so the lifetime counter and the currency_earned emit cannot be
				-- skipped on the auto trigger.
				expect(afterFlag.lifetime - beforeFlag.lifetime):toBe(paid)
				expect(afterFlag.earns - beforeFlag.earns):toBe(1)
			end
		)
	end
)

describe("monetization: the VIP-trench pass is what opens the exclusive tier", function()
	it(
		"descending into the exclusive tier is Err(PrereqUnmet) without the flag, Ok with it",
		function()
			local h = newServer()
			h:startDepth()
			h:startSalvage()
			local player = h:join(1)

			-- Find the exclusive tier the way a player reaches it: the deepest rung, one below it.
			local exclusive = DepthService:tierAt(DepthService.MAX_TIER)
			expect(exclusive.requiresFlag):toBe(VIP_TRENCH_FLAG)
			h:write(player, function(d: any): ()
				d.upgrades.depth = DepthService.MAX_TIER - 1
				d.upgrades.hull = exclusive.hullMin - DepthService.BASE_HULL_RATING
				d.currencies.Credits = exclusive.cost
			end)

			local ctx = h:ctx()
			ctx.player = player
			local refused = DepthService:descend(ctx)
			expect(refused):toBeErr(Result.Codes.PrereqUnmet)
			expect(h:blob(player).upgrades.depth):toBe(DepthService.MAX_TIER - 1)
			expect(h.economy:balanceOf(h:blob(player), "Credits")):toBe(exclusive.cost)

			local multiplierBefore = h.context.depth:valueMultiplier(h:blob(player), h.clock:unix())

			expect(h:grant(player, "vipTrench")):toBeOk()
			local allowed = DepthService:descend(ctx)
			expect(allowed):toBeOk()
			expect((allowed :: any).value.tier):toBe(DepthService.MAX_TIER)
			expect(h:blob(player).upgrades.depth):toBe(DepthService.MAX_TIER)
			-- The pass buys ACCESS, not a free rung: the Credits were still spent.
			expect(h.economy:balanceOf(h:blob(player), "Credits")):toBe(0)
			-- …and the tier the pass unlocked is genuinely worth more.
			expect(
				h.context.depth:valueMultiplier(h:blob(player), h.clock:unix()) > multiplierBefore
			):toBe(true)
		end
	)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 4. DEV-PRODUCT RECEIPTS — idempotent, atomic with the ledger stamp, NotProcessedYet on any failure
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("monetization: Credit packs grant through ctx.economy:earn", function()
	it(
		"a Credit pack moves balance, lifetimeCredits and currency_earned by the SAME amount",
		function()
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackM")
			expect(amount > 0):toBe(true)

			local before = h:snap(player)
			local outcome = h:process(player, receiptFor(player, "creditPackM", "pack-1"))
			local after = h:snap(player)

			expect(outcome.decision):toBe(GRANTED)
			expect(outcome.granted):toBe(true)
			expect(outcome.replay):toBe(false)
			expect(after.balance - before.balance):toBe(amount)
			expect(after.lifetime - before.lifetime):toBe(amount)
			expect(after.earns - before.earns):toBe(1)
			expect(after.purchases - before.purchases):toBe(1)
			expect(after.receipts - before.receipts):toBe(1)

			local earned = h.analytics:eventsOfType("currency_earned")
			expect(earned[#earned].payload.currency):toBe("Credits")
			expect(earned[#earned].payload.amount):toBe(amount)
		end
	)

	it("each pack grants ITS OWN server-side amount (never a number off the receipt)", function()
		local h = newServer()
		local player = h:join(1)
		local index = 0
		for _, key in { "creditPackS", "creditPackM", "creditPackL" } do
			index += 1
			local before = h:snap(player)
			-- A hostile receipt carrying every "amount"-shaped field an implementation might read.
			local outcome = h:process(
				player,
				receiptFor(player, key, `spoof-{index}`, {
					CurrencySpent = 1_000_000_000,
					Amount = 1_000_000_000,
					amount = 1_000_000_000,
					Credits = 1_000_000_000,
				})
			)
			local after = h:snap(player)
			expect(outcome.decision):toBe(GRANTED)
			expect(after.balance - before.balance):toBe(productAmount(key))
		end
	end)

	it("the receipt id is stamped into the persisted `receipts` ledger", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:process(player, receiptFor(player, "creditPackS", "ledger-1")).decision):toBe(
			GRANTED
		)
		expect(h:blob(player).receipts["ledger-1"]):toBe(true)
	end)

	it("the `receipts` ledger is NEVER replicated to the client", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:process(player, receiptFor(player, "creditPackS", "secret-1")).decision):toBe(
			GRANTED
		)
		local view: any = Types.toView(h:blob(player))
		expect(view.receipts):toBe(nil)
		-- …but the boost expiry the HUD counts down IS replicated.
		expect(type(view.boostExpiresUnix)):toBe("number")
	end)
end)

describe("monetization: ProcessReceipt is IDEMPOTENT (replaying never double-grants)", function()
	it("a replayed receipt id grants NOTHING and still answers PurchaseGranted", function()
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackL")

		local before = h:snap(player)
		expect(h:process(player, receiptFor(player, "creditPackL", "dup-1")).decision):toBe(GRANTED)
		local afterFirst = h:snap(player)

		-- Roblox re-delivers the SAME receipt four more times.
		for _ = 1, 4 do
			local replay = h:process(player, receiptFor(player, "creditPackL", "dup-1"))
			expect(replay.decision):toBe(GRANTED) -- acknowledged, so Roblox stops re-delivering
			expect(replay.granted):toBe(false)
			expect(replay.replay):toBe(true)
		end
		local afterReplays = h:snap(player)

		expect(afterFirst.balance - before.balance):toBe(amount)
		expect(afterReplays.balance - afterFirst.balance):toBe(0)
		expect(afterReplays.lifetime - afterFirst.lifetime):toBe(0)
		expect(afterReplays.earns - afterFirst.earns):toBe(0)
		expect(afterReplays.purchases - afterFirst.purchases):toBe(0)
		expect(afterReplays.receipts):toBe(afterFirst.receipts)
	end)

	it(
		"the ledger is keyed on the PURCHASE, not the product: a new PurchaseId grants again",
		function()
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackS")
			local before = h:snap(player)
			expect(h:process(player, receiptFor(player, "creditPackS", "buy-a")).decision):toBe(
				GRANTED
			)
			expect(h:process(player, receiptFor(player, "creditPackS", "buy-b")).decision):toBe(
				GRANTED
			)
			local after = h:snap(player)
			expect(after.balance - before.balance):toBe(amount * 2)
			expect(after.receipts - before.receipts):toBe(2)
		end
	)

	it("the SAME PurchaseId delivered as a number and as a string is ONE receipt", function()
		-- A DataStore round trip does not promise to preserve a numeric key's type, so a ledger that
		-- keyed on the raw value would re-grant every purchase once per representation.
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackM")
		local before = h:snap(player)
		expect(h:process(player, receiptFor(player, "creditPackM", 4242)).decision):toBe(GRANTED)
		local replay = h:process(player, receiptFor(player, "creditPackM", "4242"))
		expect(replay.granted):toBe(false)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(amount)
		expect(after.receipts - before.receipts):toBe(1)
	end)

	it("a replay survives a rejoin — the ledger is PERSISTED, not per-session memory", function()
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackS")
		expect(h:process(player, receiptFor(player, "creditPackS", "durable-1")).decision):toBe(
			GRANTED
		)
		local afterFirst = h:snap(player)
		h:leave(player)

		local rejoined = h:join(1)
		local replay = h:process(rejoined, receiptFor(rejoined, "creditPackS", "durable-1"))
		expect(replay.decision):toBe(GRANTED)
		expect(replay.granted):toBe(false)
		local after = h:snap(rejoined)
		expect(after.balance):toBe(afterFirst.balance)
		expect(after.balance):toBe(amount)
	end)
end)

describe("monetization: ANY failure returns NotProcessedYet and grants nothing", function()
	it("an unknown ProductId is refused (never granted as 'probably the first pack')", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		for _, productId in { 424242, 0, -1, 0 / 0, math.huge, "81001", {}, nil } do
			local outcome = h:process(player, {
				PurchaseId = `unknown-{tostring(productId)}`,
				ProductId = productId,
				PlayerId = player.UserId,
			})
			expect(outcome.decision):toBe(NOT_PROCESSED)
			expect(outcome.granted):toBe(false)
		end
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
	end)

	it("an UNCONFIGURED product (id 0) cannot be bought by sending ProductId 0", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		withUnconfiguredProduct("creditPackL", function()
			local outcome = h:process(player, {
				PurchaseId = "unconfigured-1",
				ProductId = 0,
				PlayerId = player.UserId,
			})
			expect(outcome.decision):toBe(NOT_PROCESSED)
		end)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
	end)

	it("a malformed receipt payload is refused -> NotProcessedYet, nothing written", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		local malformed: { any } = {
			nil,
			"receipt",
			42,
			{},
			{ ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 }, -- no PurchaseId
			{ PurchaseId = "", ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 },
			{ PurchaseId = 0 / 0, ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 },
			{ PurchaseId = math.huge, ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 },
			{ PurchaseId = {}, ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 },
			{ PurchaseId = true, ProductId = PRODUCT_IDS.creditPackS, PlayerId = 1 },
		}
		for index = 1, 10 do
			local outcome = h:process(player, malformed[index])
			expect(outcome.decision):toBe(NOT_PROCESSED)
			expect(outcome.granted):toBe(false)
		end
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
		expect(after.purchases - before.purchases):toBe(0)
	end)

	it("a receipt whose PlayerId names a DIFFERENT player credits nobody", function()
		local h = newServer()
		local buyer = h:join(1)
		local other = h:join(2)
		local before = h:snap(other)
		local outcome = h:process(other, receiptFor(buyer, "creditPackL", "mismatch-1"))
		expect(outcome.decision):toBe(NOT_PROCESSED)
		local after = h:snap(other)
		expect(after.balance - before.balance):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
	end)

	it("a receipt for a session that never loaded grants nothing -> NotProcessedYet", function()
		local h = newServer()
		local ghost = Mocks.player(77)
		local outcome = h:process(ghost, receiptFor(ghost, "creditPackS", "ghost-1"))
		expect(outcome.decision):toBe(NOT_PROCESSED)
		expect(outcome.granted):toBe(false)
	end)

	it("with NO ctx.economy seam a Credit pack is refused, never written around it", function()
		-- ctx.economy is the enforcement point for stats.lifetimeCredits + currency_earned; granting
		-- around it would mint Credits no leaderboard or analytic could ever see.
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		local outcome = h:process(
			player,
			receiptFor(player, "creditPackL", "no-economy-1"),
			{ noEconomy = true }
		)
		expect(outcome.decision):toBe(NOT_PROCESSED)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
		expect(after.lifetime - before.lifetime):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
	end)

	it(
		"a REFUSED earn rolls the ledger stamp AND the balance back, and the retry grants once",
		function()
			-- The worst shape available here: a receipt marked processed whose grant failed is a
			-- purchase burned forever, because every re-delivery would take the replay branch and
			-- acknowledge a grant that never happened.
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackM")
			local receipt = receiptFor(player, "creditPackM", "refused-1")

			-- Make the earn seam refuse without touching MonetizationService: a blob with no `stats`
			-- table is exactly the state EconomyService:earn refuses on.
			local savedStats = h:blob(player).stats
			h:write(player, function(d: any): ()
				d.stats = nil
			end)

			local balanceBefore = h.economy:balanceOf(h:blob(player), "Credits")
			local outcome = h:process(player, receipt)
			expect(outcome.decision):toBe(NOT_PROCESSED)
			expect(outcome.granted):toBe(false)
			expect(h.economy:balanceOf(h:blob(player), "Credits")):toBe(balanceBefore)
			expect(countKeys(h:blob(player).receipts)):toBe(0) -- NOT left marked processed
			expect(#h.analytics:eventsOfType("purchase")):toBe(0)

			-- Roblox re-delivers to a healthy state: the purchase is recovered, exactly once.
			h:write(player, function(d: any): ()
				d.stats = savedStats
			end)
			local before = h:snap(player)
			expect(h:process(player, receipt).decision):toBe(GRANTED)
			expect(h:process(player, receipt).granted):toBe(false)
			local after = h:snap(player)
			expect(after.balance - before.balance):toBe(amount)
			expect(after.lifetime - before.lifetime):toBe(amount)
			expect(after.receipts - before.receipts):toBe(1)
		end
	)
end)

describe("monetization: THE REAL-MONEY GUARDS (degraded persistence + durability)", function()
	it("ctx.persistenceDegraded refuses a perfectly valid receipt -> NotProcessedYet", function()
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		local outcome = h:process(
			player,
			receiptFor(player, "creditPackL", "degraded-1"),
			{ persistenceDegraded = true }
		)
		expect(outcome.decision):toBe(NOT_PROCESSED)
		expect(outcome.granted):toBe(false)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
		expect(after.purchases - before.purchases):toBe(0)
	end)

	it("the boost is refused under degraded persistence too (no free half-grant)", function()
		local h = newServer()
		local player = h:join(1)
		local outcome = h:process(
			player,
			receiptFor(player, "boost30", "degraded-2"),
			{ persistenceDegraded = true }
		)
		expect(outcome.decision):toBe(NOT_PROCESSED)
		expect(h:blob(player).boostExpiresUnix):toBe(0)
	end)

	it("the SAME receipt then grants exactly once on a healthy server", function()
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackS")
		local receipt = receiptFor(player, "creditPackS", "degraded-3")
		expect(h:process(player, receipt, { persistenceDegraded = true }).decision):toBe(
			NOT_PROCESSED
		)

		local before = h:snap(player)
		expect(h:process(player, receipt).decision):toBe(GRANTED)
		expect(h:process(player, receipt).granted):toBe(false)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(amount)
		expect(after.receipts - before.receipts):toBe(1)
	end)

	it(
		"a grant whose DURABLE write fails is not acknowledged, and re-delivery grants once",
		function()
			-- Roblox never re-delivers a receipt answered PurchaseGranted, so acknowledging before the
			-- write is durable means a crash destroys a purchase that can never be recovered.
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackM")
			local receipt = receiptFor(player, "creditPackM", "durability-1")

			local before = h:snap(player)
			h.storeOptions.failSave = true
			local refused = h:process(player, receipt)
			expect(refused.decision):toBe(NOT_PROCESSED)
			expect(refused.granted):toBe(false)

			-- The store recovers and Roblox re-delivers.
			h.storeOptions.failSave = false
			local recovered = h:process(player, receipt)
			expect(recovered.decision):toBe(GRANTED)

			-- …and once more for good measure. Across all three deliveries the player is credited ONCE.
			expect(h:process(player, receipt).granted):toBe(false)
			local after = h:snap(player)
			expect(after.balance - before.balance):toBe(amount)
			expect(after.lifetime - before.lifetime):toBe(amount)
			expect(after.receipts - before.receipts):toBe(1)
		end
	)

	it(
		"a purchase RECOVERED through the durability path still emits exactly one `purchase`",
		function()
			-- [REGRESSION — the durability path swallowed the analytics event.] The slice says "Emit
			-- `purchase` after the grant commits", and the success criterion lists `purchase` among the
			-- core events. The failure this asserts against is invisible to a balance/ledger delta: the
			-- fresh-grant call commits the grant to the session, the durable write fails, and it returns
			-- NotProcessedYet BEFORE the emit; the re-delivery then takes the replay branch, which
			-- acknowledges and emits nothing. Net: a real-money purchase that WAS granted and WAS
			-- acknowledged fires zero `purchase` events for its entire lifetime, while `currency_earned`
			-- (emitted from inside the transform) fired with nothing behind it — an analytics stream that
			-- is internally inconsistent about a payment.
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackM")
			local receipt = receiptFor(player, "creditPackM", "durability-emit-1")

			local before = h:snap(player)
			h.storeOptions.failSave = true
			expect(h:process(player, receipt).decision):toBe(NOT_PROCESSED)
			-- The grant is already in the session at this point, so currency_earned has ALREADY fired.
			expect(h:snap(player).earns - before.earns):toBe(1)

			h.storeOptions.failSave = false
			expect(h:process(player, receipt).decision):toBe(GRANTED)
			-- A further re-delivery is a plain replay and must add nothing.
			expect(h:process(player, receipt).granted):toBe(false)

			local after = h:snap(player)
			expect(after.balance - before.balance):toBe(amount)
			expect(after.receipts - before.receipts):toBe(1)
			expect(after.earns - before.earns):toBe(1)
			-- THE ASSERTION THE SUITE WAS MISSING: exactly one `purchase`, never zero and never two.
			expect(after.purchases - before.purchases):toBe(1)

			local emitted = h.analytics:eventsOfType("purchase")
			local last = emitted[#emitted]
			expect(last.payload.key):toBe("creditPackM")
			expect(last.payload.receiptId):toBe("durability-emit-1")
			expect(last.payload.amount):toBe(amount)
		end
	)

	it("a BOOST recovered through the durability path emits AND pushes the client view", function()
		-- Same defect, second consequence: the HUD boost-remaining timer is driven from
		-- `view.boostExpiresUnix` on the replicated PlayerView and nothing else, so a boost granted on
		-- this path is live and rate-multiplying while the HUD shows nothing until some unrelated
		-- feature happens to push a view.
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)
		local pushedBefore = #h.pushes
		local receipt = receiptFor(player, "boost30", "durability-emit-2")

		h.storeOptions.failSave = true
		expect(h:process(player, receipt).decision):toBe(NOT_PROCESSED)
		local expiry = h:blob(player).boostExpiresUnix
		expect(expiry > h.clock:unix()):toBe(true) -- the boost IS live: it committed to the session

		h.storeOptions.failSave = false
		expect(h:process(player, receipt).decision):toBe(GRANTED)

		local after = h:snap(player)
		expect(after.purchases - before.purchases):toBe(1)
		expect(after.boost):toBe(expiry) -- acknowledged, never re-granted (no second 1800s)
		expect(#h.pushes - pushedBefore > 0):toBe(true)
		local lastPush = h.pushes[#h.pushes]
		expect(lastPush.channel):toBe("data")
		expect(lastPush.payload.boostExpiresUnix):toBe(expiry)
	end)

	it("a receipt with an ABSENT or non-numeric PlayerId credits nobody", function()
		-- [REGRESSION — the ownership check was conditional on the field being usable.] The receipt
		-- names its own buyer; a receipt that names NOBODY cannot be checked against the player the
		-- caller resolved, so it must be refused rather than credited to whoever was passed in. The
		-- suite already covered the MISMATCH case, which is what made this guard read as complete.
		local h = newServer()
		local player = h:join(1)
		local before = h:snap(player)

		-- No PlayerId at all.
		local anonymous: any = {
			PurchaseId = "anon-0",
			ProductId = PRODUCT_IDS.creditPackL,
			CurrencySpent = 99,
			CurrencyType = "Robux",
		}
		expect(h:process(player, anonymous).decision):toBe(NOT_PROCESSED)

		-- Present but unusable as an identity: a string id, NaN, either infinity, a non-number.
		local unusable: { any } = { "1", 0 / 0, math.huge, -math.huge, true, {} }
		for index, bad in unusable do
			local receipt: any = receiptFor(player, "creditPackL", `anon-{index}`)
			receipt.PlayerId = bad
			local outcome = h:process(player, receipt)
			expect(outcome.decision):toBe(NOT_PROCESSED)
			expect(outcome.granted):toBe(false)
		end

		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(0)
		expect(after.lifetime - before.lifetime):toBe(0)
		expect(after.receipts - before.receipts):toBe(0)
		expect(after.purchases - before.purchases):toBe(0)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 5. THE PERSISTED 30-MIN BOOST — extension rule, boundaries, rejoin, resurface (A6)
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("monetization: the 30-minute 2x boost (persisted, extended, never swallowed)", function()
	it("a fresh boost expires exactly 1800 server-seconds from now", function()
		local h = newServer()
		local player = h:join(1)
		local now = h.clock:unix()
		local outcome = h:process(player, receiptFor(player, "boost30", "fresh-1"))
		expect(outcome.decision):toBe(GRANTED)
		expect(boostSeconds()):toBe(1800)
		expect(h:blob(player).boostExpiresUnix):toBe(now + 1800)
		expect(outcome.boostSecondsRemaining):toBe(1800)
		expect(outcome.extended):toBe(false)
		-- A boost grants no Credits and touches no earn-side number.
		expect(h.economy:balanceOf(h:blob(player), "Credits")):toBe(0)
		expect(#h.analytics:eventsOfType("currency_earned")):toBe(0)
		expect(#h.analytics:eventsOfType("purchase")):toBe(1)
	end)

	it("a STACKED purchase EXTENDS from the current expiry (never silently swallowed)", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:process(player, receiptFor(player, "boost30", "stack-1")).decision):toBe(GRANTED)
		local firstExpiry = h:blob(player).boostExpiresUnix

		h.clock:advance(300) -- 5 minutes in, 25 still on the clock
		local now = h.clock:unix()
		expect(firstExpiry > now):toBe(true) -- the boost under test is genuinely still live
		local outcome = h:process(player, receiptFor(player, "boost30", "stack-2"))
		expect(outcome.decision):toBe(GRANTED)
		expect(outcome.extended):toBe(true)

		-- Extend-from-now would land at now + 1800 and swallow the 1500s already paid for.
		expect(h:blob(player).boostExpiresUnix):toBe(firstExpiry + boostSeconds())
		expect(h:blob(player).boostExpiresUnix ~= now + boostSeconds()):toBe(true)
	end)

	it("a LONG-EXPIRED boost is not back-dated: it restarts from now", function()
		local h = newServer()
		local player = h:join(1)
		expect(h:process(player, receiptFor(player, "boost30", "expired-1")).decision):toBe(GRANTED)
		h.clock:advance(boostSeconds() * 10)
		local now = h.clock:unix()
		local outcome = h:process(player, receiptFor(player, "boost30", "expired-2"))
		expect(outcome.extended):toBe(false)
		expect(h:blob(player).boostExpiresUnix):toBe(now + boostSeconds())
	end)

	it("a GARBAGE persisted expiry reads as 'no boost' (never NaN, never eternal)", function()
		local h = newServer()
		local player = h:join(1)
		local seconds = boostSeconds()
		local index = 0
		for _, garbage in { 0 / 0, math.huge, -math.huge, -1, 0, "soon", {}, true } do
			index += 1
			h:write(player, function(d: any): ()
				d.boostExpiresUnix = garbage
				d.receipts = {}
			end)
			local now = h.clock:unix()
			local outcome = h:process(player, receiptFor(player, "boost30", `garbage-{index}`))
			expect(outcome.decision):toBe(GRANTED)
			expect(h:blob(player).boostExpiresUnix):toBe(now + seconds)
			h.clock:advance(1)
		end
	end)

	it(
		"boostExpiryAt is pure and monotonic over the two inputs (the extension rule alone)",
		function()
			local seconds = boostSeconds()
			expect(MonetizationService:boostExpiryAt({ boostExpiresUnix = 0 }, 100, seconds)):toBe(
				100 + seconds
			)
			expect(MonetizationService:boostExpiryAt({ boostExpiresUnix = 500 }, 100, seconds)):toBe(
				500 + seconds
			)
			expect(MonetizationService:boostExpiryAt({ boostExpiresUnix = 50 }, 100, seconds)):toBe(
				100 + seconds
			)
			expect(MonetizationService:boostExpiryAt({}, 100, seconds)):toBe(100 + seconds)
		end
	)

	it("the boost SURVIVES a crash/rejoin and still multiplies the running rate", function()
		local h = newServer()
		h:startSalvage()
		local player = h:join(1)
		local baseRate = h:rate(player)
		local now = h.clock:unix()
		expect(h:process(player, receiptFor(player, "boost30", "rejoin-1")).decision):toBe(GRANTED)
		local expiry = h:blob(player).boostExpiresUnix

		h:leave(player)
		h.clock:advance(600) -- ten minutes away

		local rejoined = h:join(1)
		expect(h:blob(rejoined).boostExpiresUnix):toBe(expiry)
		expect(expiry - h.clock:unix()):toBe(boostSeconds() - 600 - (h.clock:unix() - now - 600))
		expectClose(
			h:rate(rejoined, h.clock:unix()),
			baseRate * 2,
			"the persisted boost must still double the rate after a rejoin"
		)
	end)

	it(
		"AMENDMENT A6: a resurface-shaped wipe leaves the boost intact AND still multiplying",
		function()
			-- ResurfaceService is still the contract-pass STUB, so this drives the wipe the spec
			-- describes ("wipe structures + depth + Credits, mint Pearls, ++resurfaces") straight
			-- through the data layer. What it pins is the invariant A6 depends on and that this slice
			-- genuinely owns: `boostExpiresUnix` is a top-level persisted field, co-located with
			-- nothing a prestige resets — so a prestige cannot take away boost time bought with real
			-- money, and the rate still carries it afterwards.
			local h = newServer()
			h:startSalvage()
			local player = h:join(1)
			h:write(player, function(d: any): ()
				d.upgrades.drones = 4
				d.currencies.Credits = 9000
			end)

			local now = h.clock:unix()
			expect(h:process(player, receiptFor(player, "boost30", "resurface-1")).decision):toBe(
				GRANTED
			)
			local expiry = h:blob(player).boostExpiresUnix
			expect(expiry):toBe(now + boostSeconds())

			h.clock:advance(600)
			h:write(player, function(d: any): ()
				d.upgrades = {}
				d.currencies.Credits = 0
				d.currencies.Pearls = (d.currencies.Pearls or 0) + 3
				d.resurfaces = (d.resurfaces or 0) + 1
			end)

			expect(h:blob(player).boostExpiresUnix):toBe(expiry) -- untouched
			expect(expiry - h.clock:unix()):toBe(boostSeconds() - 600) -- remaining time intact

			-- …and it is still MULTIPLYING: the same blob read after the expiry is worth half as much.
			local boosted = h:rate(player, h.clock:unix())
			local unboosted = h:rate(player, expiry)
			expect(boosted > 0):toBe(true)
			expectClose(
				boosted,
				unboosted * 2,
				"the boost must still double the post-resurface rate"
			)
		end
	)
end)

describe("monetization: the v6->v7 boostExpiresUnix migration round-trips", function()
	it("a legacy blob migrates to a numeric, inert boost and can then be boosted", function()
		local legacy = Migrations.default(START_UNIX)
		legacy.schemaVersion = 6
		legacy.boostExpiresUnix = nil
		local h = newServer({ seed = { player_5 = legacy } })
		h:startSalvage()

		local player = h:join(5)
		local blob = h:blob(player)
		expect(blob.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(blob.boostExpiresUnix):toBe(0)

		local baseRate = h:rate(player)
		local now = h.clock:unix()
		expect(h:process(player, receiptFor(player, "boost30", "migrated-1")).decision):toBe(
			GRANTED
		)
		expect(h:blob(player).boostExpiresUnix):toBe(now + boostSeconds())
		expectClose(h:rate(player, now), baseRate * 2, "a migrated blob must still take the boost")

		-- …and the migrated + boosted value round-trips through a save/rejoin.
		h:leave(player)
		local rejoined = h:join(5)
		expect(h:blob(rejoined).boostExpiresUnix):toBe(now + boostSeconds())
		expect(h:blob(rejoined).schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
	end)

	it(
		"a GARBAGE persisted expiry on a legacy blob migrates to 0, not to an eternal boost",
		function()
			local legacy = Migrations.default(START_UNIX)
			legacy.schemaVersion = 6
			legacy.boostExpiresUnix = "forever"
			local h = newServer({ seed = { player_6 = legacy } })
			h:startSalvage()

			local player = h:join(6)
			expect(h:blob(player).boostExpiresUnix):toBe(0)
			local base = h:rate(player)
			-- No boost is active, so the rate is the same one second later and one hour later.
			expectClose(
				h:rate(player, h.clock:unix() + 3600),
				base,
				"a migrated garbage expiry is inert"
			)
		end
	)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 6. CONCURRENCY — interleaved + spam-duplicated deliveries against the per-player FIFO lock
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("monetization: interleaved receipt deliveries (the replay double-grant)", function()
	it(
		"TWO interleaved deliveries of the SAME receipt grant EXACTLY ONCE (lock-held transform alone)",
		function()
			local h = newServer()
			local player = h:join(1)
			local amount = productAmount("creditPackL")
			local receipt = receiptFor(player, "creditPackL", "race-1")
			local proxy = countingData(h.data)
			local before = h:snap(player)

			-- The in-memory single-flight reservation is NEUTRALISED: it would short-circuit the
			-- second delivery before it ever reached the data layer and make this test vacuous. The
			-- guarantee the slice states is the ledger check + stamp + grant inside ONE update, and it
			-- must hold on its own.
			withoutMemo("_processing", function()
				local outcomes: { any } = {}
				h:setYield(true)
				local cos = {
					coroutine.create(function()
						outcomes[1] = h:process(player, receipt, { data = proxy })
					end),
					coroutine.create(function()
						outcomes[2] = h:process(player, receipt, { data = proxy })
					end),
				}
				drain(cos)
				h:setYield(false)

				-- The interleave is REAL: the second delivery entered ctx.data:update while the first
				-- was still parked inside it.
				expect(proxy.peak):toBe(2)
				expect(proxy.updates):toBe(2)
				expect(outcomes[1].granted ~= outcomes[2].granted):toBe(true)
				expect(outcomes[1].granted == true or outcomes[2].granted == true):toBe(true)
			end)

			local after = h:snap(player)
			expect(after.balance - before.balance):toBe(amount)
			expect(after.lifetime - before.lifetime):toBe(amount)
			expect(after.earns - before.earns):toBe(1)
			expect(after.purchases - before.purchases):toBe(1)
			expect(after.receipts - before.receipts):toBe(1)
		end
	)

	it("FALSIFIABILITY: a naive read-ledger -> yield -> grant handler DOES double-grant", function()
		-- The counter-case that proves the case above is meaningful rather than trivially green: the
		-- same two interleaved deliveries against a handler that checks the ledger before its yield
		-- credit the player twice for one purchase.
		local backing: any = { receipts = {}, Credits = 0 }
		local function naiveGrant(receiptId: string, amount: number): boolean
			if backing.receipts[receiptId] == true then
				return false
			end
			coroutine.yield() -- no lock held: the duplicate reads the SAME "not processed" state
			backing.receipts[receiptId] = true
			backing.Credits += amount
			return true
		end
		local cos = {
			coroutine.create(function()
				naiveGrant("race-x", 1000)
			end),
			coroutine.create(function()
				naiveGrant("race-x", 1000)
			end),
		}
		drain(cos)
		expect(backing.Credits):toBe(2000)
		expect(backing.Credits).never:toBe(1000)
	end)

	it("a duplicate arriving while the first is STILL IN FLIGHT is never acknowledged", function()
		-- Acknowledging a grant that has not committed is how real money is lost: Roblox never
		-- re-delivers an acknowledged receipt.
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackM")
		local receipt = receiptFor(player, "creditPackM", "inflight-1")
		local before = h:snap(player)

		local outcomes: { any } = {}
		local observedInFlight = false
		local first: thread
		h:setYield(true)
		first = coroutine.create(function()
			outcomes[1] = h:process(player, receipt)
		end)
		local second = coroutine.create(function()
			observedInFlight = coroutine.status(first) == "suspended"
			outcomes[2] = h:process(player, receipt)
		end)
		drain({ first, second })
		h:setYield(false)

		expect(observedInFlight):toBe(true) -- the duplicate genuinely arrived mid-flight
		expect(outcomes[1].decision):toBe(GRANTED)
		expect(outcomes[2].granted):toBe(false)
		expect(outcomes[2].decision):toBe(NOT_PROCESSED)

		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(amount)
		expect(after.receipts - before.receipts):toBe(1)

		-- Roblox re-delivers the refused one; it finds the durable ledger entry and grants nothing.
		local replay = h:process(player, receipt)
		expect(replay.decision):toBe(GRANTED)
		expect(replay.granted):toBe(false)
		expect(h:snap(player).balance - before.balance):toBe(amount)
	end)

	it("interleaved DIFFERENT receipts both land — the sum is exact (no lost update)", function()
		local h = newServer()
		local player = h:join(1)
		local small = productAmount("creditPackS")
		local large = productAmount("creditPackL")
		local proxy = countingData(h.data)
		local before = h:snap(player)

		h:setYield(true)
		local cos = {
			coroutine.create(function()
				h:process(player, receiptFor(player, "creditPackS", "sum-a"), { data = proxy })
			end),
			coroutine.create(function()
				h:process(player, receiptFor(player, "creditPackL", "sum-b"), { data = proxy })
			end),
		}
		drain(cos)
		h:setYield(false)

		expect(proxy.peak):toBe(2)
		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(small + large)
		expect(after.lifetime - before.lifetime):toBe(small + large)
		expect(after.receipts - before.receipts):toBe(2)
		expect(after.earns - before.earns):toBe(2)
	end)

	it("interleaved DIFFERENT boost receipts stack to the exact total (neither is lost)", function()
		local h = newServer()
		local player = h:join(1)
		local seconds = boostSeconds()
		local now = h.clock:unix()
		local proxy = countingData(h.data)

		h:setYield(true)
		local cos = {
			coroutine.create(function()
				h:process(player, receiptFor(player, "boost30", "stackrace-a"), { data = proxy })
			end),
			coroutine.create(function()
				h:process(player, receiptFor(player, "boost30", "stackrace-b"), { data = proxy })
			end),
		}
		drain(cos)
		h:setYield(false)

		expect(proxy.peak):toBe(2)
		-- A stale-snapshot second transform would land at now + 1800 and swallow a paid-for boost.
		expect(h:blob(player).boostExpiresUnix):toBe(now + seconds * 2)
		expect(countKeys(h:blob(player).receipts)):toBe(2)
	end)

	it("FOUR spam-duplicated deliveries of one receipt still credit exactly one grant", function()
		local h = newServer()
		local player = h:join(1)
		local amount = productAmount("creditPackS")
		local receipt = receiptFor(player, "creditPackS", "spam-1")
		local proxy = countingData(h.data)
		local before = h:snap(player)

		withoutMemo("_processing", function()
			h:setYield(true)
			local cos = {}
			for _ = 1, 4 do
				table.insert(
					cos,
					coroutine.create(function()
						h:process(player, receipt, { data = proxy })
					end)
				)
			end
			drain(cos)
			h:setYield(false)
			expect(proxy.peak > 1):toBe(true)
		end)

		local after = h:snap(player)
		expect(after.balance - before.balance):toBe(amount)
		expect(after.lifetime - before.lifetime):toBe(amount)
		expect(after.earns - before.earns):toBe(1)
		expect(after.purchases - before.purchases):toBe(1)
		expect(after.receipts - before.receipts):toBe(1)
	end)

	it("interleaved grants of the SAME gamepass emit `purchase` exactly once", function()
		local h = newServer()
		local player = h:join(1)
		local proxy = countingData(h.data)

		h:setYield(true)
		local cos = {
			coroutine.create(function()
				h:grant(player, "vipTrench", { data = proxy })
			end),
			coroutine.create(function()
				h:grant(player, "vipTrench", { data = proxy })
			end),
		}
		drain(cos)
		h:setYield(false)

		expect(proxy.peak):toBe(2)
		expect(h:blob(player).flags[VIP_TRENCH_FLAG]):toBe(true)
		expect(countKeys(h:blob(player).flags)):toBe(1)
		expect(#h.analytics:eventsOfType("purchase")):toBe(1)
	end)
end)

-- ── the receipt reservation must span the DURABLE half, not just the transform ───────────────────
--
-- The whole-game adversarial review's confirmed finding, found independently by two lenses. The
-- reservation was released the instant ctx.data:update returned — one line above a `flush` that
-- YIELDS (ctx.data:save -> saveSession, gated by the per-key write floor and retried with backoff,
-- so 0.1-10s every time). Roblox does not serialise ProcessReceipt re-invocations, so a re-delivery
-- of the SAME PurchaseId landing in that window passed the cleared reservation, took the replay
-- branch, found _pendingDurable still set, flushed, cleared it and emitted `purchase` — and then the
-- first call resumed and emitted `purchase` AGAIN. One real payment, two revenue events.
--
-- The grant itself was never at risk (the lock-held transform is mechanism 1 and it holds), which is
-- why this is low severity — but the file's own stated property, "a duplicate that arrives while the
-- first is parked is answered NotProcessedYet", was false for the yielding half.
--
-- WHY THE HARNESS NEEDS A CUSTOM data LAYER: MockStore's yield hook covers `update` only, so no
-- existing fixture can park a caller inside `save`. This wraps the real data layer and parks the
-- FIRST save, which is precisely the window the exploit uses. Nothing else is stubbed — the
-- transform, the ledger, the economy seam and the emitter are all the real ones.
describe("monetization: a re-delivery during the durable write cannot double-emit", function()
	it(
		"the SAME receipt re-delivered while the first save is parked is refused in-flight",
		function()
			local h = newServer()
			local player = h:join(1)
			stampIds()

			-- Read the grant size off the CATALOG, never restated: the assertion tracks the product.
			local PACK_M_AMOUNT = 0
			for _, entry in MonetizationService.PRODUCTS do
				if entry.key == "creditPackM" then
					PACK_M_AMOUNT = entry.amount
				end
			end
			expect(PACK_M_AMOUNT > 0):toBe(true)

			local parked = 0
			local slowData = setmetatable({}, {
				__index = function(_t: any, key: string): any
					local inner: any = h.data
					local value = inner[key]
					if key == "save" then
						return function(_self: any, p: any): any
							-- Park the FIRST save exactly where the real one yields; later saves pass.
							parked += 1
							if parked == 1 then
								coroutine.yield()
							end
							return inner:save(p)
						end
					end
					if type(value) == "function" then
						return function(_self: any, ...): any
							return value(inner, ...)
						end
					end
					return value
				end,
			})

			local ctx = h:ctx({ data = slowData })
			local receipt = receiptFor(player, "creditPackM", "dupe-during-flush")
			local first: any = nil
			local second: any = nil

			local co1 = coroutine.create(function()
				first = MonetizationService:processReceipt(ctx, player, receipt)
			end)
			local co2 = coroutine.create(function()
				second = MonetizationService:processReceipt(ctx, player, receipt)
			end)

			local before = h:snap(player)
			-- co1 runs until it parks INSIDE the durable write, with the grant already committed to the
			-- session; co2 then arrives with the same PurchaseId while co1 is still parked.
			coroutine.resume(co1)
			expect(parked):toBe(1)
			drain({ co2, co1 })
			local after = h:snap(player)

			-- The reservation held: the duplicate never reached the replay branch at all.
			expect(second).never:toBe(nil)
			expect((second :: any).decision):toBe(NOT_PROCESSED)
			-- The real delivery still succeeds once it resumes.
			expect((first :: any).decision):toBe(GRANTED)
			-- ONE payment, ONE revenue event — the invariant the exploit broke.
			expect(after.purchases - before.purchases):toBe(1)
			-- ...and the grant itself moved exactly once, as it did even with the bug.
			expect(after.balance - before.balance):toBe(PACK_M_AMOUNT)
			expect(after.lifetime - before.lifetime):toBe(PACK_M_AMOUNT)
		end
	)
end)

-- ── the boot audit refuses to let an inert catalog ship silently ─────────────────────────────────
--
-- The integration red-team's MEDIUM finding: every asset id in the shipped catalog is 0, so
-- syncPasses skips every pass, processReceipt answers unknown-product for every receipt, and the
-- three gamepass effects plus both dev products are OFF — with `purchase`, one of the seven events
-- the taxonomy mandates, having no reachable emit point in the built game at all. It fails in the
-- shape of success: nothing errors, the passes simply never grant.
--
-- The ids come from a published place, so filling them is a human step and NOT something this suite
-- can assert. What it CAN assert is that the condition is loud. These cases are the reason the
-- warning cannot be quietly deleted later.
describe(
	"monetization: an unconfigured catalog is announced at boot, not discovered live",
	function()
		it("unconfiguredEntries names every entry still on a placeholder id", function()
			withUnconfiguredProduct("creditPackM", function()
				local names = MonetizationService:unconfiguredEntries()
				local found = false
				for _, name in names do
					if name == "product.creditPackM" then
						found = true
					end
				end
				expect(found):toBe(true)
			end)
		end)

		it("a fully configured catalog is SILENT (the warning means something)", function()
			stampIds()
			expect(#MonetizationService:unconfiguredEntries()):toBe(0)
			local warned = 0
			MonetizationService:auditCatalog(function()
				warned += 1
			end)
			-- A warning that fires unconditionally is noise, and noise is how a real one gets ignored.
			expect(warned):toBe(0)
		end)

		it("an unconfigured entry WARNS, and the message names what is inert", function()
			withUnconfiguredPass("vipTrench", function()
				local messages: { string } = {}
				MonetizationService:auditCatalog(function(message: string)
					table.insert(messages, message)
				end)
				expect(#messages):toBe(1)
				-- The name must be IN the message: a warning that says "something is wrong" without
				-- saying what costs more time than it saves.
				expect(string.find(messages[1], "gamepass.vipTrench", 1, true)).never:toBe(nil)
			end)
		end)
	end
)
