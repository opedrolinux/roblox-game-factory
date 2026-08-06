--!strict
-- games/deep-reach/tests/unit/structures.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/structures.md, NOT from
--  StructuresShopService's control flow. The implementation was read ONLY to learn its observable
--  interface (the action factories, the buy/fetch entry points, the reply shapes); every EXPECTATION
--  below is derived from the slice, and every economic number is DISCOVERED through the public API
--  (the shop view's server-derived `nextCost`, and ctx.salvage:rateFor / :capacityFor) rather than
--  copied out of the module. A build that re-tunes `base`, `growth` or `maxLevel` stays green here; a
--  build that stops charging the curve, stops moving the income rate, or double-spends goes red.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   1. THE CATALOG, SERVER-OWNED — "`drones` (count), `conveyor` (speed level), `smelter` (capacity
--      level), `hull` (pressure rating) — all priced in Credits — and `pearlDrones`, priced in Pearls.
--      Prices are a server-derived cost curve with a max level; the client NEVER sends a price, only a
--      catalog key."
--   2. THE PURCHASE — "`structures.buy`: validate type + range + rate + that the key is in the
--      catalog, then in ONE DataService:update read the level, derive the cost, debit through
--      ctx.economy:spend (Err(Insufficient) if short, never a negative balance, emits currency_spent)
--      and write `upgrades.<key> += 1`. Never read-then-write across a yield. Spam-duplicated and
--      interleaved buys must never double-spend or grant two levels for one debit."
--   3. THE READ SURFACE — "`structures.fetch`: the catalog with server-derived NEXT-LEVEL prices plus
--      this player's levels, so the shop UI holds no price constants of its own."
--   4. NO PURCHASABLE SHIPS INERT — "Each catalog entry must be proven by a DELTA ON A RUNNING
--      SERVER-DERIVED VALUE, not by a persisted field changing: `drones`, `conveyor` and `pearlDrones`
--      must each measurably raise the value `ctx.salvage:rateFor` returns; `smelter` must measurably
--      raise `ctx.salvage:capacityFor` (and therefore the offline cap); `hull` must measurably change
--      the outcome of the Depth pressure gate (it does not touch income — that is its whole point)."
--   5. CANONICAL KEYS — "upgrades.drones, upgrades.conveyor, upgrades.smelter, upgrades.hull,
--      upgrades.pearlDrones."
--   NOT THIS SLICE (so NOT asserted here): the income-rate function itself and the tick (Salvage), the
--      depth unlock cost/gate (Depth), minting Pearls or the prestige multiplier (Resurface), the
--      resurface wipe, gamepass/dev-product purchases (Monetization).
--   Plus games/deep-reach/CLAUDE.md §3 (validate type + range + ownership + rate on EVERY inbound
--   client request) and §4 (concurrency-safe economy: no double-spend, no dupes).
--
-- WHY EVERY EFFECT CASE MEASURES A RUNNING VALUE. 26 of collect-sim's 66 confirmed defects were one
-- shape: a purchase incremented a persisted field, the test asserted the field moved, and nothing ever
-- read it. So no case below is satisfied by `upgrades.<key>` changing. Each one takes a reading
-- THROUGH THE SEAM A LATER FEATURE WILL USE (`ctx.salvage:rateFor` / `:capacityFor`, and — for `hull`,
-- whose consumer is a later batch — a stand-in pressure gate that reads the canonical persisted key
-- exactly as DepthService will) before and after a REAL purchase, and compares the DELTA.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The double-spend this feature is one mistake away from:
-- read the level (and therefore the price) OUTSIDE the transform, yield in ctx.data:update, then debit
-- and write. Two buys in the same frame both price the same step, and the player pays twice for one
-- level (or gets two levels for one price step). Sequential calls cannot tell that implementation from
-- a correct one, because nothing ever interleaves. So the race cases drive the economy_race.spec
-- idiom: a MockStore with `yieldOnUpdate` (a forced yield INSIDE the update critical section) plus a
-- round-robin coroutine driver, a counting data proxy whose `peak` in-flight count proves the
-- interleave is real, and a FALSIFICATION counter-case (a naive price-outside-the-lock buy driven at
-- the same yield point) that DOES pay twice for one level.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")
local StructuresShopService = require("../../src/server/services/structures/StructuresShopService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000

-- THE CANONICAL KEYS, straight from the slice. Declared here (not read off the module) on purpose: a
-- catalog that silently dropped `hull` or renamed `pearlDrones` would still be self-consistent, and
-- every test that iterated the module's own order would stay green while the contract broke.
local CREDIT_KEYS = { "drones", "conveyor", "smelter", "hull" }
local PEARL_KEYS = { "pearlDrones" }
local ALL_KEYS = { "drones", "conveyor", "smelter", "hull", "pearlDrones" }

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

-- Relative-tolerance comparison: the rate is a PRODUCT of tuned steps, so exact binary equality is
-- not available for composed readings — but "this purchase reached the number" is about magnitude.
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

local function expectTrue(condition: boolean, why: string): ()
	if not condition then
		error(why, 0)
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
			error("structures race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`structures race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- A pass-through ctx.data that COUNTS the updates that reached the data layer AND tracks the PEAK
-- number in flight. `updates` alone cannot tell an interleave from two sequential calls, so if the
-- forced yield ever stopped being armed, every race case would silently degrade to two sequential
-- buys and stay green. `peak` can only reach 2 if the second request entered ctx.data:update while
-- the first was still parked inside it.
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

-- The PERSISTED level, read raw off the blob (never through the module's own reader), so a build that
-- writes the level somewhere else entirely cannot satisfy these assertions.
local function persistedLevel(blob: any, key: string): number
	if type(blob) ~= "table" or type(blob.upgrades) ~= "table" then
		return 0
	end
	local level = blob.upgrades[key]
	if type(level) ~= "number" then
		return 0
	end
	return level
end

-- THE STAND-IN DEPTH PRESSURE GATE. `hull` is the one entry whose real consumer (DepthService's
-- pressure gate) is a later batch, and the slice still requires it to move an OUTCOME rather than a
-- field. This is that outcome, modelled the only way it can be today: a gate that reads the CANONICAL
-- persisted key `upgrades.hull` (the contract's own name for it) and admits a dive only at or above
-- the trench's required rating. A shop that wrote its hull level under some other key — or not at all
-- — leaves this gate shut forever, which is exactly the defect the criterion is about.
local function pressureGateAdmits(blob: any, requiredHullLevel: number): boolean
	return persistedLevel(blob, "hull") >= requiredHullLevel
end

-- THE SAME STAND-IN, AS AN INSTALLED ctx SEAM. `hull` is the one catalog entry whose real consumer
-- (DepthService's pressure gate) is a later batch, so every case that BUYS hull has to say which
-- world it is in: one where something outside the shop reads `upgrades.hull`, or one where nothing
-- does. This is that seam — an EXTERNAL reader of the canonical key, exactly as DepthService will be
-- — and `newServer` installs it by default so the catalog/price/persistence cases below exercise a
-- hull that is genuinely for sale. The cases that are ABOUT the absent consumer opt out with
-- `{ noDepth = true }` (§8, §9), which is the only place the distinction is load-bearing.
local function depthConsumer(): any
	local seam: any = {}
	function seam.hullRatingOf(_self: any, blob: any): number
		return 1 + persistedLevel(blob, "hull")
	end
	return seam
end

local function entryOf(view: any, key: string): any
	if type(view) ~= "table" or type(view.entries) ~= "table" then
		return nil
	end
	for _, row in view.entries do
		if row.key == key then
			return row
		end
	end
	return nil
end

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, the real SalvageService Started (so ctx.salvage is the SAME derived rate function
-- the tick and salvage.fetch run on — the observable this slice is graded against), and the shop
-- Started against a recording `net`.
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
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local depth = depthConsumer()

	local startContext: any = {
		clock = clock,
		data = data,
		net = net,
		economy = economy,
		analytics = analytics,
		depth = depth,
	}
	SalvageService:Start(startContext) -- installs startContext.salvage
	StructuresShopService:Start(startContext)

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		economy = economy,
		analytics = analytics,
		seam = startContext.salvage,
		depth = depth,
		registered = registered,
		pushes = pushes,
		startContext = startContext,
		storeOptions = storeOptions,
	}

	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	-- The ActionContext a direct buy/fetch call receives. `overrides` swaps one seam without
	-- rebuilding the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			salvage = if o.noSalvage == true
				then nil
				else (if o.salvage ~= nil then o.salvage else self.seam),
			-- `hull`'s consumer, installed by default (see depthConsumer). `noDepth = true` is the
			-- pre-Depth world: nothing outside this shop reads `upgrades.hull` at all.
			depth = if o.noDepth == true
				then nil
				else (if o.depth ~= nil then o.depth else self.depth),
			analytics = self.analytics,
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

	function h.fund(self: any, player: any, credits: number, pearls: number?): ()
		self:write(player, function(d: any): ()
			d.currencies.Credits = credits
			d.currencies.Pearls = pearls or 0
		end)
	end

	function h.buy(self: any, player: any, key: string, overrides: any?): any
		return StructuresShopService:buy(self:ctx(player, overrides), key)
	end

	function h.fetch(self: any, player: any, overrides: any?): any
		return StructuresShopService:fetch(self:ctx(player, overrides))
	end

	function h.view(self: any, player: any): any
		local got = self:fetch(player)
		expect(got):toBeOk()
		return (got :: any).value
	end

	-- The SERVER-DERIVED price of the next level, read off the shop view exactly as the UI does.
	function h.priceOf(self: any, player: any, key: string): number
		local row = entryOf(self:view(player), key)
		expectTrue(row ~= nil, `the shop view has no row for the canonical key "{key}"`)
		return row.nextCost
	end

	-- The price the curve would charge at an ARBITRARY level, discovered through the same public read
	-- surface against a synthetic blob. Used by the race cases, which must know the price of the
	-- SECOND step before either purchase happens.
	function h.priceAtLevel(self: any, player: any, key: string, level: number): number
		local probe = deepCopy(self:blob(player))
		if type(probe.upgrades) ~= "table" then
			probe.upgrades = {}
		end
		probe.upgrades[key] = level
		local row = StructuresShopService:describeEntry(self:ctx(player), probe, key)
		expectTrue(row ~= nil, `the shop cannot describe "{key}" at level {level}`)
		return (row :: any).nextCost
	end

	-- The running, derived observables — read through the seams a later feature reads, never off a
	-- persisted field.
	function h.rate(self: any, player: any): number
		return self.seam:rateFor(self:blob(player), self.clock:unix(), nil)
	end

	function h.capacity(self: any, player: any): number
		return self.seam:capacityFor(self:blob(player))
	end

	-- Every number an economy case compares before and after.
	function h.snap(self: any, player: any): any
		local blob = self:blob(player)
		return {
			credits = blob.currencies.Credits,
			pearls = blob.currencies.Pearls,
			lifetime = blob.stats.lifetimeCredits,
			rate = self:rate(player),
			capacity = self:capacity(player),
			spent = #self.analytics:eventsOfType("currency_spent"),
			earned = #self.analytics:eventsOfType("currency_earned"),
			levels = {
				drones = persistedLevel(blob, "drones"),
				conveyor = persistedLevel(blob, "conveyor"),
				smelter = persistedLevel(blob, "smelter"),
				hull = persistedLevel(blob, "hull"),
				pearlDrones = persistedLevel(blob, "pearlDrones"),
			},
		}
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net, with the two shop actions registered
	-- from the service's own factories. `gate = true` opts INTO the spine rate Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local harness = Mocks.net({
			clock = self.clock,
			data = self.data,
			economy = self.economy,
			salvage = self.seam,
			analytics = self.analytics,
			gate = if w.gate == true then Mocks.gate(self.clock) else false,
		})
		harness.register(StructuresShopService:buyAction())
		harness.register(StructuresShopService:fetchAction())
		return harness
	end

	return h
end

-- ── 1. the wire surface + the catalog the slice names ───────────────────────────────────────────

describe("structures: the two contract actions and the server-owned catalog", function()
	it("Start registers structures.buy and structures.fetch with a rate policy", function()
		local h = newServer()
		for _, name in { Net.Actions.BuyStructure, Net.Actions.FetchStructures } do
			local action = h.registered[name]
			expectTrue(action ~= nil, `no action registered under the contract name "{name}"`)
			expectTrue(
				type(action.validate) == "function",
				`{name} has no validator (CLAUDE.md §3: validate type + range before acting)`
			)
			expectTrue(
				type(action.rate) == "table"
					and type(action.rate.maxPerWindow) == "number"
					and action.rate.maxPerWindow > 0
					and type(action.rate.windowSeconds) == "number"
					and action.rate.windowSeconds > 0,
				`{name} declares no usable RatePolicy — the Gate would not bound it`
			)
		end
	end)

	it("the catalog sells every canonical key, in the currency the slice names", function()
		local h = newServer()
		local player = h:join(1)
		local view = h:view(player)
		for _, key in CREDIT_KEYS do
			local row = entryOf(view, key)
			expectTrue(row ~= nil, `the catalog is missing the canonical entry "{key}"`)
			expect(row.currency):toBe("Credits")
			expect(row.level):toBe(0)
			expectTrue(
				type(row.maxLevel) == "number" and row.maxLevel > 0,
				`"{key}" declares no max level (the slice: "a server-derived cost curve with a max level")`
			)
		end
		for _, key in PEARL_KEYS do
			local row = entryOf(view, key)
			expectTrue(row ~= nil, `the catalog is missing the canonical entry "{key}"`)
			expect(row.currency):toBe("Pearls")
		end
	end)

	it("fetch before the session loads -> Err(NoData) (the JoinRetry surface)", function()
		local h = newServer()
		local player = Mocks.player(9) -- deliberately NOT loaded
		expect(h:fetch(player)):toBeErr(Result.Codes.NoData)
	end)

	it("fetch is side-effect free: repeated reads change no persisted byte", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 5000, 50)
		local before = deepCopy(h:blob(player))
		local first = h:view(player)
		h:fetch(player)
		h:fetch(player)
		local after = deepCopy(h:blob(player))
		expect(after):toEqual(before)
		-- and the prices did not drift with the number of refreshes
		expect(h:priceOf(player, "drones")):toBe(entryOf(first, "drones").nextCost)
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(0)
	end)
end)

-- ── 2. the server-derived price curve ───────────────────────────────────────────────────────────

describe(
	"structures: prices are server-derived, rise with the level, and are what is charged",
	function()
		it(
			"the advertised nextCost is EXACTLY what the purchase debits, for every entry",
			function()
				local h = newServer()
				local player = h:join(1)
				h:fund(player, 1_000_000, 1_000)
				for _, key in ALL_KEYS do
					local row = entryOf(h:view(player), key)
					local price = row.nextCost
					expectFinite(price, `"{key}" advertises a non-finite price`)
					expectTrue(price > 0, `"{key}" advertises a free purchase ({price})`)
					local before = h:snap(player)
					local bought = h:buy(player, key)
					expect(bought):toBeOk()
					local after = h:snap(player)
					if row.currency == "Credits" then
						expectClose(
							before.credits - after.credits,
							price,
							`"{key}" debited != advertised`
						)
						expect(after.pearls):toBe(before.pearls)
					else
						expectClose(
							before.pearls - after.pearls,
							price,
							`"{key}" debited != advertised`
						)
						expect(after.credits):toBe(before.credits)
					end
					expect(after.levels[key]):toBe(before.levels[key] + 1)
					-- the reply must not describe a different transaction than the one that happened
					expectClose(
						(bought :: any).value.cost,
						price,
						`"{key}": the buy reply's cost disagrees with the debit`
					)
				end
			end
		)

		it("the curve rises: each level costs strictly more than the one before", function()
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000, 1_000)
			for _, key in ALL_KEYS do
				local first = h:priceOf(player, key)
				expect(h:buy(player, key)):toBeOk()
				local second = h:priceOf(player, key)
				expectTrue(
					second > first,
					`"{key}": level 2 costs {second}, which is not more than level 1's {first} — the curve `
						.. "is flat, so the sink never bites"
				)
			end
		end)

		it("prices stay finite positive integers all the way to the max level", function()
			local h = newServer()
			local player = h:join(1)
			for _, key in ALL_KEYS do
				local maxLevel = entryOf(h:view(player), key).maxLevel
				local previous = -1
				for level = 0, maxLevel - 1 do
					local price = h:priceAtLevel(player, key, level)
					expectFinite(price, `"{key}" at level {level} has a non-finite price`)
					expectTrue(price > 0, `"{key}" at level {level} is free ({price})`)
					expectTrue(
						price == math.floor(price),
						`"{key}" at level {level} prices a fraction of a Credit ({price})`
					)
					expectTrue(price > previous, `"{key}" price did not rise at level {level}`)
					previous = price
				end
			end
		end)
	end
)

-- ── 3. NO PURCHASABLE SHIPS INERT — every entry moves a RUNNING derived value ────────────────────

describe("structures: each purchase visibly changes the running income rate", function()
	local function buyAndMeasure(key: string, funds: number, pearls: number?): any
		local h = newServer()
		local player = h:join(1)
		h:fund(player, funds, pearls or 0)
		local before = h:snap(player)
		local bought = h:buy(player, key)
		expect(bought):toBeOk()
		return h, player, before, h:snap(player)
	end

	it("drones: buying one measurably RAISES ctx.salvage:rateFor", function()
		local _h, _player, before, after = buyAndMeasure("drones", 10_000)
		expectTrue(
			after.rate > before.rate,
			`drones is INERT: the derived rate stayed at {before.rate} after a paid purchase`
		)
	end)

	it("conveyor: buying one measurably RAISES ctx.salvage:rateFor", function()
		local _h, _player, before, after = buyAndMeasure("conveyor", 10_000)
		expectTrue(
			after.rate > before.rate,
			`conveyor is INERT: the derived rate stayed at {before.rate} after a paid purchase`
		)
	end)

	it("pearlDrones: a PEARL purchase measurably RAISES ctx.salvage:rateFor", function()
		local _h, _player, before, after = buyAndMeasure("pearlDrones", 0, 1_000)
		expectTrue(
			after.rate > before.rate,
			`pearlDrones is INERT: the derived rate stayed at {before.rate} after a paid purchase`
		)
		-- the Pearl sink spends Pearls, never Credits
		expectTrue(after.pearls < before.pearls, "pearlDrones did not spend Pearls")
		expect(after.credits):toBe(before.credits)
	end)

	it("smelter: buying one measurably RAISES ctx.salvage:capacityFor (the offline cap)", function()
		local _h, _player, before, after = buyAndMeasure("smelter", 10_000)
		expectTrue(
			after.capacity > before.capacity,
			`smelter is INERT: capacityFor stayed at {before.capacity} after a paid purchase`
		)
	end)

	it("hull: buying one FLIPS the depth pressure gate, and does NOT touch income", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 10_000)
		local before = h:snap(player)
		-- a trench that demands one plate of rating: shut at level 0
		expect(pressureGateAdmits(h:blob(player), 1)):toBe(false)
		expect(h:buy(player, "hull")):toBeOk()
		local after = h:snap(player)
		expectTrue(
			pressureGateAdmits(h:blob(player), 1),
			"hull is INERT: the pressure gate is still shut after a paid hull purchase"
		)
		-- "it does not touch income — that is its whole point"
		expectClose(after.rate, before.rate, "hull moved the income rate")
		expectClose(after.capacity, before.capacity, "hull moved the smelter capacity")
	end)

	it("the measurement is DISCRIMINATING: a near-miss upgrade key moves nothing", function()
		-- Proof that the delta cases above are not trivially green. The canonical keys are exact
		-- strings, and the whole written-never-read defect class is a purchase persisted under a key
		-- nothing reads. So: level 10 of `drone`/`conveyer`/`smelters`/`pearldrones` — one typo each —
		-- must move NEITHER observable, which is precisely the outcome those cases would report as red.
		local h = newServer()
		local player = h:join(1)
		local baseRate = h:rate(player)
		local baseCapacity = h:capacity(player)
		h:write(player, function(d: any): ()
			d.upgrades.drone = 10
			d.upgrades.conveyer = 10
			d.upgrades.smelters = 10
			d.upgrades.pearldrones = 10
		end)
		expectClose(
			h:rate(player),
			baseRate,
			"a near-miss key moved the rate (the test cannot bind)"
		)
		expectClose(h:capacity(player), baseCapacity, "a near-miss key moved the capacity")
		-- and the CANONICAL keys do move both, so the readings are live, not stuck
		h:write(player, function(d: any): ()
			d.upgrades.drones = 10
			d.upgrades.smelter = 10
		end)
		expectTrue(h:rate(player) > baseRate, "the canonical drones key does not reach the rate")
		expectTrue(
			h:capacity(player) > baseCapacity,
			"the canonical smelter key does not reach the capacity"
		)
	end)

	it("EVERY catalog entry moves at least one running observable (parametrized)", function()
		for _, key in ALL_KEYS do
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000, 1_000)
			local before = h:snap(player)
			local gateBefore = pressureGateAdmits(h:blob(player), before.levels.hull + 1)
			expect(h:buy(player, key)):toBeOk()
			local after = h:snap(player)
			local gateAfter = pressureGateAdmits(h:blob(player), before.levels.hull + 1)
			local moved = (after.rate ~= before.rate)
				or (after.capacity ~= before.capacity)
				or (gateAfter ~= gateBefore)
			expectTrue(
				moved,
				`"{key}" is INERT: a paid purchase moved neither the rate ({before.rate}), the `
					.. `capacity ({before.capacity}) nor the pressure gate. Players pay for nothing.`
			)
		end
	end)
end)

-- ── 4. economy integrity: no mint, no negative balance, no lifetime credit for spending ─────────

describe("structures: the economy cannot be minted, drained below zero, or bypassed", function()
	it("a short balance -> Err(Insufficient), and NOTHING moves", function()
		local h = newServer()
		local player = h:join(1)
		local price = h:priceOf(player, "drones")
		h:fund(player, price - 1)
		local before = h:snap(player)
		expect(h:buy(player, "drones")):toBeErr(Result.Codes.Insufficient)
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.levels.drones):toBe(0)
		expect(after.spent):toBe(before.spent)
		expectClose(after.rate, before.rate, "a refused purchase moved the income rate")
	end)

	it("spending to exactly zero never goes negative, and the next buy is refused", function()
		local h = newServer()
		local player = h:join(1)
		local price = h:priceOf(player, "drones")
		h:fund(player, price)
		expect(h:buy(player, "drones")):toBeOk()
		expect(h:snap(player).credits):toBe(0)
		expect(h:buy(player, "drones")):toBeErr(Result.Codes.Insufficient)
		local blob = h:blob(player)
		expectTrue(blob.currencies.Credits >= 0, "the balance went negative")
		expect(persistedLevel(blob, "drones")):toBe(1)
	end)

	it("a purchase never increases a balance and never touches stats.lifetimeCredits", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 100_000, 100)
		h:write(player, function(d: any): ()
			d.stats.lifetimeCredits = 4_242
		end)
		local before = h:snap(player)
		for _, key in ALL_KEYS do
			expect(h:buy(player, key)):toBeOk()
		end
		local after = h:snap(player)
		expectTrue(after.credits < before.credits, "the Credits balance did not fall")
		expectTrue(after.pearls < before.pearls, "the Pearls balance did not fall")
		expect(after.lifetime):toBe(4_242) -- lifetime counts EARNS only; a sink must never move it
		expect(after.earned):toBe(before.earned) -- and a purchase emits no currency_earned
	end)

	it("each successful purchase emits exactly one currency_spent, refusals emit none", function()
		local h = newServer()
		local player = h:join(1)
		local price = h:priceOf(player, "drones")
		h:fund(player, price)
		expect(h:buy(player, "drones")):toBeOk()
		local events = h.analytics:eventsOfType("currency_spent")
		expect(#events):toBe(1)
		expect(events[1].payload.currency):toBe("Credits")
		expectClose(events[1].payload.amount, price, "currency_spent reported the wrong amount")
		-- the refused follow-up must not emit
		expect(h:buy(player, "drones")):toBeErr(Result.Codes.Insufficient)
		expect(#h.analytics:eventsOfType("currency_spent")):toBe(1)
	end)

	it("without ctx.economy the shop REFUSES rather than writing a balance itself", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 100_000)
		local before = h:snap(player)
		local bought = h:buy(player, "drones", { noEconomy = true })
		expect(bought):toBeErr()
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.levels.drones):toBe(0)
	end)

	it("at the max level the entry is refused and nothing is debited", function()
		local h = newServer()
		local player = h:join(1)
		local maxLevel = entryOf(h:view(player), "drones").maxLevel
		h:fund(player, 10_000_000)
		h:write(player, function(d: any): ()
			d.upgrades.drones = maxLevel
		end)
		local before = h:snap(player)
		expect(h:buy(player, "drones")):toBeErr()
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.levels.drones):toBe(maxLevel)
		expect(after.spent):toBe(before.spent)
		expect(entryOf(h:view(player), "drones").maxed):toBe(true)
	end)

	it("a poisoned persisted level never produces a free, NaN or infinite purchase", function()
		for _, poison in { 0 / 0, -50, 1e308, math.huge } do
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			h:write(player, function(d: any): ()
				d.upgrades.drones = poison
			end)
			local before = h:snap(player)
			local bought = h:buy(player, "drones")
			local after = h:snap(player)
			expectFinite(after.credits, `a "{tostring(poison)}" level poisoned the balance`)
			expectTrue(
				after.credits <= before.credits,
				`a "{tostring(poison)}" level MINTED Credits ({before.credits} -> {after.credits})`
			)
			if (bought :: any).ok then
				expectTrue(
					after.credits < before.credits,
					`a "{tostring(poison)}" level bought a FREE level`
				)
				expectFinite(
					after.levels.drones,
					`a "{tostring(poison)}" level persisted a non-finite level`
				)
			end
		end
	end)

	it("a non-numeric persisted level is charged the base price, not skipped", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000)
		local base = h:priceOf(player, "drones")
		h:write(player, function(d: any): ()
			d.upgrades.drones = "9999" :: any
		end)
		local before = h:snap(player)
		local bought = h:buy(player, "drones")
		if (bought :: any).ok then
			expectClose(
				before.credits - h:snap(player).credits,
				base,
				"a string level was not priced as level 0"
			)
		else
			expect(h:snap(player).credits):toBe(before.credits)
		end
	end)
end)

-- ── 5. negative / abuse: malformed payloads, forged prices, rate, ownership ──────────────────────

describe("structures: malformed and forged payloads are refused, and change nothing", function()
	it("malformed payloads are refused and persist nothing", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000)
		local harness = h:wire()
		local before = h:snap(player)
		local payloads: { any } = {
			nil,
			"drones",
			42,
			true,
			{},
			{ key = 123 },
			{ key = "" },
			{ key = {} },
			{ key = "drones2" },
			{ key = "DRONES" },
			{ key = string.rep("x", 5_000) },
			{ key = "Credits" }, -- a currency is not a purchasable
			{ key = "resurfaces" }, -- neither is an arbitrary blob field
		}
		for index = 1, 13 do
			local result = harness.invoke(Net.Actions.BuyStructure, player, payloads[index])
			expect(result):toBeErr()
		end
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits)
		expect(after.spent):toBe(before.spent)
		-- and no phantom upgrade key was created by any of them
		local blob = h:blob(player)
		for key in blob.upgrades do
			expectTrue(
				table.find(ALL_KEYS, key) ~= nil,
				`a refused payload created the upgrade key "{key}"`
			)
		end
	end)

	it(
		"a key outside the catalog -> Err(BadPayload) (CLAUDE.md: malformed -> BadPayload)",
		function()
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			local harness = h:wire()
			expect(harness.invoke(Net.Actions.BuyStructure, player, { key = "battleship" })):toBeErr(
				Result.Codes.BadPayload
			)
		end
	)

	it("a client-supplied PRICE never buys anything cheaper than the server's curve", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000)
		local harness = h:wire()
		local price = h:priceOf(player, "drones")
		local before = h:snap(player)
		local result = harness.invoke(
			Net.Actions.BuyStructure,
			player,
			{ key = "drones", cost = 1, price = 1, nextCost = 1, discount = 0.99, free = true }
		)
		local after = h:snap(player)
		if (result :: any).ok then
			expectClose(
				before.credits - after.credits,
				price,
				"a client-supplied price was honoured — the till is open"
			)
		else
			expect(after.credits):toBe(before.credits)
			expect(after.levels.drones):toBe(0)
		end
	end)

	it(
		"a client-supplied LEVEL never skips the curve (no level-24 purchase for the level-1 price)",
		function()
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			local harness = h:wire()
			local price = h:priceOf(player, "drones")
			local before = h:snap(player)
			local result = harness.invoke(
				Net.Actions.BuyStructure,
				player,
				{ key = "drones", level = 24, levels = 24 }
			)
			local after = h:snap(player)
			if (result :: any).ok then
				expect(after.levels.drones):toBe(1)
				expectClose(
					before.credits - after.credits,
					price,
					"a client-supplied level moved the price"
				)
			else
				expect(after.levels.drones):toBe(0)
				expect(after.credits):toBe(before.credits)
			end
		end
	)

	it("a client-supplied CURRENCY never pays for a Pearl item with Credits", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000, 10)
		local harness = h:wire()
		local before = h:snap(player)
		local result = harness.invoke(
			Net.Actions.BuyStructure,
			player,
			{ key = "pearlDrones", currency = "Credits" }
		)
		local after = h:snap(player)
		expect(after.credits):toBe(before.credits) -- Credits are NEVER the pearlDrones sink
		if (result :: any).ok then
			expectTrue(after.pearls < before.pearls, "a Pearl purchase spent no Pearls")
		else
			expect(after.pearls):toBe(before.pearls)
		end
	end)

	it("the Gate bounds the buy action, and a rate-limited call debits nothing", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 10_000_000)
		local harness = h:wire({ gate = true })
		local policy = h.registered[Net.Actions.BuyStructure].rate
		local allowed = 0
		local limited = 0
		local creditsBeforeLimit = 0
		-- burst well past the declared window budget
		for _ = 1, policy.maxPerWindow + 3 do
			local before = h:snap(player).credits
			local result = harness.invoke(Net.Actions.BuyStructure, player, { key = "drones" })
			if (result :: any).ok then
				allowed += 1
			elseif (result :: any).code == Result.Codes.RateLimited then
				limited += 1
				creditsBeforeLimit = before
				-- a refused-by-rate call must not have reached the economy
				expect(h:snap(player).credits):toBe(creditsBeforeLimit)
			end
		end
		expectTrue(limited > 0, "the buy action was never rate-limited inside one window")
		expectTrue(allowed <= policy.maxPerWindow, "more buys landed than the policy allows")
		-- the bucket refills on the SERVER clock
		h.clock:advance(policy.windowSeconds * 4)
		expect(harness.invoke(Net.Actions.BuyStructure, player, { key = "drones" })):toBeOk()
	end)

	it("the payer is the ACTING player: a forged userId never touches another blob", function()
		local h = newServer()
		local attacker = h:join(1)
		local victim = h:join(2)
		h:fund(attacker, 1_000_000)
		h:fund(victim, 1_000_000)
		local harness = h:wire()
		local victimBefore = h:snap(victim)
		local attackerBefore = h:snap(attacker)
		local result = harness.invoke(
			Net.Actions.BuyStructure,
			attacker,
			{ key = "drones", userId = victim.UserId, target = victim.UserId }
		)
		local victimAfter = h:snap(victim)
		expect(victimAfter.credits):toBe(victimBefore.credits)
		expect(victimAfter.levels.drones):toBe(0)
		if (result :: any).ok then
			expectTrue(
				h:snap(attacker).credits < attackerBefore.credits,
				"the purchase was granted but nobody paid for it"
			)
			expect(h:snap(attacker).levels.drones):toBe(1)
		end
	end)
end)

-- ── 6. concurrency: interleaved and spam-duplicated buys ────────────────────────────────────────

describe(
	"structures: interleaved / spam-duplicated buys never double-spend or dupe a level",
	function()
		-- Two REAL buys through the service, forced to interleave inside ctx.data:update.
		local function raceBuys(h: any, player: any, keys: { string }, proxy: any): { any }
			local results: { any } = {}
			local cos: { thread } = {}
			for index, key in keys do
				table.insert(
					cos,
					coroutine.create(function()
						results[index] = h:buy(player, key, { data = proxy })
					end)
				)
			end
			h:setYield(true)
			drain(cos)
			h:setYield(false)
			return results
		end

		it("two interleaved buys pay TWO CONSECUTIVE STEPS and grant exactly two levels", function()
			local h = newServer()
			local player = h:join(1)
			local step1 = h:priceAtLevel(player, "drones", 0)
			local step2 = h:priceAtLevel(player, "drones", 1)
			h:fund(player, step1 + step2) -- exactly enough for both steps, and not a Credit more
			local before = h:snap(player)
			local proxy = countingData(h.data)
			local results = raceBuys(h, player, { "drones", "drones" }, proxy)
			expect(results[1]):toBeOk()
			expect(results[2]):toBeOk()
			expect(proxy.peak):toBe(2) -- the interleave was REAL, not two sequential calls
			local after = h:snap(player)
			expect(after.levels.drones):toBe(2)
			expect(after.credits):toBe(0)
			expectClose(
				before.credits - after.credits,
				step1 + step2,
				"two interleaved buys did not pay two consecutive steps"
			)
			expect(after.spent):toBe(before.spent + 2)
			expectTrue(after.rate > before.rate, "two granted levels did not raise the rate")
		end)

		it("spam-duplicated buys with funds for ONE step grant exactly one level", function()
			local h = newServer()
			local player = h:join(1)
			local step1 = h:priceAtLevel(player, "drones", 0)
			h:fund(player, step1) -- enough for the first step only
			local before = h:snap(player)
			local proxy = countingData(h.data)
			local results = raceBuys(h, player, { "drones", "drones", "drones", "drones" }, proxy)
			local granted = 0
			for _, result in results do
				if (result :: any).ok then
					granted += 1
				else
					expect(result):toBeErr(Result.Codes.Insufficient)
				end
			end
			expect(proxy.peak > 1):toBe(true)
			expect(granted):toBe(1)
			local after = h:snap(player)
			expect(after.levels.drones):toBe(1)
			expect(after.credits):toBe(0)
			expectTrue(after.credits >= 0, "a spam burst drove the balance negative")
			expect(after.spent):toBe(before.spent + 1)
		end)

		it(
			"interleaved buys across DIFFERENT entries settle on the exact shared balance",
			function()
				local h = newServer()
				local player = h:join(1)
				local drone = h:priceAtLevel(player, "drones", 0)
				local conveyor = h:priceAtLevel(player, "conveyor", 0)
				local smelter = h:priceAtLevel(player, "smelter", 0)
				h:fund(player, drone + conveyor + smelter)
				local before = h:snap(player)
				local proxy = countingData(h.data)
				local results = raceBuys(h, player, { "drones", "conveyor", "smelter" }, proxy)
				for _, result in results do
					expect(result):toBeOk()
				end
				expect(proxy.peak > 1):toBe(true)
				local after = h:snap(player)
				expect(after.credits):toBe(0)
				expect(after.levels.drones):toBe(1)
				expect(after.levels.conveyor):toBe(1)
				expect(after.levels.smelter):toBe(1)
				expectClose(
					before.credits - after.credits,
					drone + conveyor + smelter,
					"three interleaved buys did not total the three prices"
				)
				expectTrue(
					after.rate > before.rate,
					"the interleaved purchases did not raise the rate"
				)
			end
		)

		it("a buy interleaved with an EARN on the same balance loses neither", function()
			local h = newServer()
			local player = h:join(1)
			local price = h:priceAtLevel(player, "drones", 0)
			h:fund(player, price)
			local before = h:snap(player)
			local proxy = countingData(h.data)
			local grant = 777
			local cos: { thread } = {
				coroutine.create(function()
					h:buy(player, "drones", { data = proxy })
				end),
				coroutine.create(function()
					proxy:update(player, function(d: any): any
						h.economy:earn(d, "Credits", grant, "test.interleave")
						return d
					end)
				end),
			}
			h:setYield(true)
			drain(cos)
			h:setYield(false)
			expect(proxy.peak):toBe(2)
			local after = h:snap(player)
			expect(after.credits):toBe(before.credits + grant - price)
			expect(after.levels.drones):toBe(1)
			expect(after.lifetime):toBe(before.lifetime + grant) -- the earn's lifetime credit survived
		end)

		it(
			"FALSIFIABILITY: a naive price-outside-the-lock buy DOES pay twice for one level",
			function()
				-- The counter-case that proves the interleave point above is real. This is the classic
				-- mistake the slice forbids ("Never read-then-write across a yield"): read the level (and
				-- therefore the price) BEFORE ctx.data:update, then debit and write inside it. Driven at the
				-- SAME yield point, with the SAME funds as the headline case, it pays two level-1 prices and
				-- grants ONE level. If this naive version somehow behaved correctly, the headline case would
				-- not be distinguishing anything.
				local h = newServer()
				local player = h:join(1)
				local step1 = h:priceAtLevel(player, "drones", 0)
				local step2 = h:priceAtLevel(player, "drones", 1)
				h:fund(player, step1 + step2)

				local function naiveBuy(): ()
					-- priced OUTSIDE the lock, off a snapshot that a concurrent buy is about to invalidate
					local staleLevel = persistedLevel(h:blob(player), "drones")
					local staleCost = h:priceAtLevel(player, "drones", staleLevel)
					h.data:update(player, function(d: any): any
						if type(d.upgrades) ~= "table" then
							d.upgrades = {}
						end
						local previous = d.upgrades.drones
						d.upgrades.drones = staleLevel + 1
						local debit = h.economy:spend(d, "Credits", staleCost, "test.naive")
						if not debit.ok then
							d.upgrades.drones = previous
						end
						return d
					end)
				end

				local cos: { thread } = {
					coroutine.create(naiveBuy),
					coroutine.create(naiveBuy),
				}
				h:setYield(true)
				drain(cos)
				h:setYield(false)

				local after = h:snap(player)
				-- both priced level 0, both wrote level 1: two debits, ONE level.
				expect(after.levels.drones):toBe(1)
				expect(after.credits):toBe(step1 + step2 - step1 * 2)
				expect(after.spent):toBe(2)
			end
		)
	end
)

-- ── 7. persistence: the purchase survives a save/release/reload round trip ───────────────────────

describe("structures: purchased levels persist under the canonical upgrade keys", function()
	it("a bought level survives save -> release -> reload, and the rate with it", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000, 1_000)
		for _, key in ALL_KEYS do
			expect(h:buy(player, key)):toBeOk()
		end
		local rateBefore = h:rate(player)
		local capacityBefore = h:capacity(player)
		expect(h.data:save(player)):toBeOk()
		h.data:onPlayerRemoving(player)

		local rejoined = h:join(1)
		local blob = h:blob(rejoined)
		for _, key in ALL_KEYS do
			expect(persistedLevel(blob, key)):toBe(1)
		end
		expectClose(h:rate(rejoined), rateBefore, "the reloaded blob's rate lost the purchases")
		expectClose(
			h:capacity(rejoined),
			capacityBefore,
			"the reloaded blob's capacity lost the smelter"
		)
		-- and the shop reads the persisted levels back, so the UI never re-sells level 1
		local view = h:view(rejoined)
		for _, key in ALL_KEYS do
			expect(entryOf(view, key).level):toBe(1)
		end
	end)
end)

-- ── 8. REGRESSION — the inert guard must not certify an entry against ITSELF ─────────────────────
--
-- THE DEFECT THESE CASES PIN (found by the economy red-team, missed by the builder and three critics).
-- The slice's headline criterion is "NO PURCHASABLE SHIPS INERT ... proven by a DELTA ON A RUNNING
-- SERVER-DERIVED VALUE, not by a persisted field changing". The shop builds exactly one RUNTIME guard
-- for that class — `auditEffects`, which re-reads every entry's declared observable one level higher —
-- and for `hull` that guard COULD NOT FAIL, by construction: `hull`'s declared observable was
-- `hullRatingOf`, a pure function of the very `upgrades.hull` key the shop itself writes, defined in
-- the shop itself. `drones`/`conveyor`/`smelter`/`pearlDrones` bind to `ctx.salvage`, a genuinely
-- EXTERNAL reader; `hull` bound to itself. So the audit asserted `1 ~= 2` and reported `moved = true`
-- forever no matter what the rest of the game did, and the file could honestly print no INERT warning
-- at boot while selling a 400-Credit, irreversible, geometrically escalating upgrade whose consumer
-- (the Depth pressure gate) does not exist yet — `grep -rn 'upgrades.hull' src` hits nothing outside
-- the shop, and DepthService's descend handler is still `Err(Internal, "stub")`.
--
-- The two invariants below, and why each is the DELTA and not a restatement:
--   (a) SELF-CERTIFICATION IS IMPOSSIBLE. Every entry's observable must be read through a seam that
--       lives OUTSIDE this service, so an entry whose consumer is not installed reports UNPROVEN
--       (`measured = false`) instead of proving itself. Run against a context with NO seams at all,
--       a self-certifying entry is the ONLY kind that can still report a measured, moving effect.
--   (b) A PROVABLY INERT ENTRY IS REFUSED, not merely printed about at boot. A purchase whose declared
--       observable the server can watch NOT move is a purchase the running game cannot see: it must
--       cost the player nothing, because there is no refund and no downgrade anywhere in this game.
--
-- Case (b) is staged with the written-never-read defect itself: a `ctx.salvage` seam that has stopped
-- reading `upgrades.conveyor`. That is the exact shape of 26 of collect-sim's 66 confirmed defects.

describe("structures: the inert guard cannot certify an entry against itself", function()
	local function auditByKey(ctx: any): { [string]: any }
		local rows: { [string]: any } = {}
		for _, row in StructuresShopService:auditEffects(ctx, nil) do
			rows[row.key] = row
		end
		return rows
	end

	it("with NO consumer seam installed, no entry may report a measured effect", function()
		local h = newServer()
		-- deliberately seamless: no salvage, no depth. Nothing outside the shop can be asked anything.
		local bare: any = { player = Mocks.player(1), clock = h.clock, data = h.data }
		for _, key in ALL_KEYS do
			local row = auditByKey(bare)[key]
			expectTrue(row ~= nil, `the boot audit does not cover the canonical entry "{key}"`)
			expectTrue(
				row.measured ~= true,
				`"{key}" CERTIFIED ITS OWN EFFECT with no consumer seam installed ({row.current} -> `
					.. `{row.next}): its observable is a pure function of the very upgrade key the shop `
					.. "writes, so the boot audit can never report it inert and the shop can sell it "
					.. "forever with nothing in the game reading it"
			)
		end
	end)

	it(
		"the audit still PROVES an entry through its real consumer seam (a is not vacuous)",
		function()
			local h = newServer()
			local player = h:join(1)
			local rows = auditByKey(h:ctx(player)) -- ctx.salvage installed
			for _, key in { "drones", "conveyor", "smelter", "pearlDrones" } do
				local row = rows[key]
				expectTrue(
					row.measured == true and row.moved == true,
					`"{key}" is no longer proven through ctx.salvage ({row.current} -> {row.next}, `
						.. `measured={tostring(row.measured)}) — the audit has gone blind, not honest`
				)
			end
		end
	)

	it(
		"hull is UNPROVEN while its Depth consumer is absent, and PROVEN once one reads the key",
		function()
			local h = newServer()
			local player = h:join(1)
			-- Today: no DepthService pressure gate exists, so nothing in the game reads `upgrades.hull`.
			local withoutDepth = auditByKey(h:ctx(player, { noDepth = true }))["hull"]
			expectTrue(
				withoutDepth.measured ~= true,
				`hull reported a measured effect ({withoutDepth.current} -> {withoutDepth.next}) with no `
					.. "consumer of upgrades.hull installed anywhere — that reading came from the shop itself"
			)
			-- And with the consumer installed, the same audit proves it — so the check above is a binding
			-- statement about WHO answered, not a blanket "hull can never be proven".
			local ctx = h:ctx(player)
			ctx.depth = depthConsumer()
			local withConsumer = auditByKey(ctx)["hull"]
			expectTrue(
				withConsumer.measured == true and withConsumer.moved == true,
				"hull is not proven even through a consumer that reads the canonical upgrades.hull key "
					.. `({withConsumer.current} -> {withConsumer.next})`
			)
		end
	)

	it("an entry the server can PROVE is inert is refused, and destroys no Credits", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000)
		-- THE WRITTEN-NEVER-READ DEFECT, STAGED: a salvage seam that still answers, but has stopped
		-- reading `upgrades.conveyor`. Buying a conveyor now moves nothing the running game can see.
		local deaf: any = {}
		function deaf.rateFor(_self: any, blob: any, _nowUnix: number?, _depth: any?): number
			return 1 + persistedLevel(blob, "drones") -- conveyor is not read at all
		end
		function deaf.capacityFor(_self: any, blob: any): number
			return 100 + persistedLevel(blob, "smelter")
		end

		local before = h:snap(player)
		local bought = h:buy(player, "conveyor", { salvage = deaf })
		local after = h:snap(player)
		expect(bought):toBeErr(Result.Codes.PrereqUnmet)
		expect(after.credits):toBe(before.credits) -- not one Credit destroyed
		expect(after.levels.conveyor):toBe(0)
		expect(after.spent):toBe(before.spent)

		-- The control: the SAME seam still reads `upgrades.drones`, so drones still sells. A shop that
		-- refused everything would satisfy the assertion above and be useless.
		expect(h:buy(player, "drones", { salvage = deaf })):toBeOk()
		expectTrue(
			h:snap(player).credits < before.credits,
			"the control purchase debited nothing — the refusal is indiscriminate"
		)
	end)
end)

-- ── 9. REGRESSION — AN ENTRY NOBODY READS IS NEVER SOLD, ONLY REPORTED ──────────────────────────
--
-- THE DEFECT THESE CASES PIN (economy red-team; the builder and three critics missed it, and §8 only
-- made it VISIBLE). §8 established that an entry's observable must be read through an external seam,
-- so `hull` now reports UNPROVEN at boot instead of certifying itself. But UNPROVEN was treated as
-- "not a defect this transform can see" and the purchase went through anyway: `structures.buy` on
-- `hull` still debited 400 Credits via ctx.economy:spend and wrote `upgrades.hull = 1` while NOTHING
-- in the game read that key (DepthService is still the contract-pass stub whose descend handler is
-- `Err(Internal, "stub")`; `grep -rn 'upgrades.hull' src` hits nothing outside the shop). There is no
-- refund and no downgrade anywhere in this game, so those Credits were destroyed permanently — and
-- the curve escalates: 400, 720, 1,296, ... ~79,400 at level 9, an unbounded sink for zero effect.
--
-- THE INVARIANT: an entry may be DEBITED only when somebody outside this shop can be seen reading
-- what it writes. "The consumer answers and does not move" (§8's staged deaf seam) and "no consumer
-- answers at all" are different diagnoses but the SAME consequence for the player — Credits spent on
-- a number the running game cannot observe — so they must produce the same refusal. Reporting it in
-- the boot log is not a fix: the boot log does not hold the player's Credits.
--
-- WHY THIS IS THE DELTA, NOT A RESTATEMENT OF §8: §8 asserts what the AUDIT REPORTS. These assert
-- what the TILL DOES. A build that reports `hull` unproven at boot and sells it anyway is green on
-- every case in §8 and red on every case here.
describe("structures: an entry with no installed consumer is refused, never debited", function()
	it("hull, in today's pre-Depth world: Err(PrereqUnmet) and not one Credit moves", function()
		local h = newServer()
		local player = h:join(1)
		h:fund(player, 1_000_000)
		local price = h:priceOf(player, "hull")
		expectTrue(price > 0, "hull is not priced at all — this case would prove nothing")

		local before = h:snap(player)
		-- No ctx.depth: exactly the shipped game, where DepthService is a stub and nothing anywhere
		-- reads `upgrades.hull`.
		local bought = h:buy(player, "hull", { noDepth = true })
		local after = h:snap(player)
		expect(bought):toBeErr(Result.Codes.PrereqUnmet)
		expect(after.credits):toBe(before.credits) -- the whole point: nothing was destroyed
		expect(after.levels.hull):toBe(0)
		expect(after.spent):toBe(before.spent) -- and no currency_spent was emitted for it
		expectTrue(
			not pressureGateAdmits(h:blob(player), 1),
			"a refused hull purchase still moved the pressure gate"
		)

		-- THE CONTROL, so the refusal is about the missing reader and not about `hull`: install the
		-- consumer and the IDENTICAL purchase is granted, at the identical advertised price.
		expect(h:buy(player, "hull")):toBeOk()
		expect(h:snap(player).credits):toBe(before.credits - price)
		expect(h:snap(player).levels.hull):toBe(1)
	end)

	it("the rule is general: EVERY entry is refused when its consumer is absent", function()
		-- Parametrized so a future catalog entry cannot be added with a consumer nobody installs and
		-- quietly become the next hull. Each key opts out of exactly the seam ITS effect declares.
		for _, key in ALL_KEYS do
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000, 1_000)
			local overrides: any = if key == "hull"
				then { noDepth = true }
				else { noSalvage = true }
			local before = h:snap(player)
			local bought = h:buy(player, key, overrides)
			local after = h:snap(player)
			expect(bought):toBeErr(Result.Codes.PrereqUnmet)
			expect(after.credits):toBe(before.credits)
			expect(after.pearls):toBe(before.pearls)
			expect(after.levels[key]):toBe(before.levels[key])
			expect(after.spent):toBe(before.spent)
		end
	end)

	it(
		"the refusal is not a blanket 'no': with every consumer installed the catalog sells",
		function()
			-- The counterweight. A shop that refused everything would satisfy both cases above and be
			-- useless, so: the same server, the same funds, every seam present -> every entry is granted.
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000, 1_000)
			local before = h:snap(player)
			for _, key in ALL_KEYS do
				expect(h:buy(player, key)):toBeOk()
			end
			local after = h:snap(player)
			expectTrue(after.credits < before.credits, "no Credits were spent at all")
			expectTrue(after.pearls < before.pearls, "no Pearls were spent at all")
			expect(after.spent):toBe(before.spent + #ALL_KEYS)
		end
	)
end)

-- ── 10. REGRESSION (F1) — THE POST-WRITE PUSH CAN NEVER FAIL A COMMITTED PURCHASE ───────────────
--
-- THE DEFECT THESE CASES PIN. `buy`'s post-write step reads
-- `if outcome.ok then self:pushView(self._context, player); pcall(function() self:syncWorld(...) end) end`
-- — syncWorld is pcall'd, pushView is a BARE call, while the comment above it claims both are
-- "guarded and pcall'd". And inside `pushView` the pcall wraps only `net:fireClient`; the
-- `context.data:get(player)` that feeds it sits OUTSIDE. Both readings run AFTER the transform has
-- committed the level and after ctx.economy:spend has debited and emitted currency_spent, so a throw
-- on either escapes `buy`, and Net.dispatch turns any throw out of a handler into
-- Err(Result.Codes.Internal) (src/shared/Net.luau:249-252). The player is told their PAID, PERSISTED
-- purchase failed — the exact defect the salvage merge produced (docs/LEARNINGS.md: an unguarded
-- post-write FireClient turning a committed economy write into Err(Internal)), which 352 green Lune
-- tests called fine because nothing exercised the push path at all.
--
-- The escape route is live today, not hypothetical: it is benign ONLY because the ONE implementation
-- currently behind `context.data` (DataService.get) happens to be a pure table read. The transaction
-- is protected by its callee rather than by the file that owns it, and `context.data` is a SEAM — the
-- server context is assembled by the bootstrap and can hold any object that answers `get`.
--
-- WHY THE MUTATION IS THE DEFECT AND NOT A CRUDER COUSIN: the second case replaces exactly ONE thing
-- — the `get` on the SERVER context the push reads through (`self._context.data`) — and leaves the
-- buy's own `ctx.data` (the transform, the debit, the commit) completely untouched. So the purchase is
-- genuinely committed and genuinely paid for before the throw, and the only question the case asks is
-- whether the reply describes that committed purchase or an Internal error.
describe(
	"structures: the post-write push cannot undo, and cannot fail, a committed purchase",
	function()
		-- A ctx.data stand-in whose `get` THROWS and whose `update` is the real thing. This is the seam
		-- `pushView` reads through, and the one place the finding says is unguarded.
		local function throwingGet(real: any): any
			local seam: any = {}
			function seam.get(_self: any, _player: any): any
				error("structures spec: the data seam threw inside the post-write push", 0)
			end
			function seam.update(_self: any, player: any, transform: any): any
				return real:update(player, transform)
			end
			return seam
		end

		it(
			"a committed buy pushes exactly one refreshed view; a refused buy pushes none",
			function()
				local h = newServer()
				local player = h:join(1)
				h:fund(player, 1_000_000)
				local mark = #h.pushes
				expect(h:buy(player, "drones")):toBeOk()
				local pushed = 0
				for index = mark + 1, #h.pushes do
					local push = h.pushes[index]
					if push.channel == "data" and push.player == player then
						pushed += 1
					end
				end
				expect(pushed):toBe(1)

				-- A REFUSAL pushes nothing: there is no new state to describe, and a push after a refusal
				-- would tell the HUD a purchase happened.
				mark = #h.pushes
				expect(h:buy(player, "hull", { noDepth = true })):toBeErr(Result.Codes.PrereqUnmet)
				expect(#h.pushes):toBe(mark)
			end
		)

		it("a THROWING push seam still returns Ok(BuyInfo) — never Err(Internal)", function()
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			local price = h:priceOf(player, "drones")
			local before = h:snap(player)

			-- Poison ONLY the server context the post-write push reads through. The buy's own ctx.data is
			-- untouched, so the transform, the debit and the commit all succeed exactly as before.
			h.startContext.data = throwingGet(h.data)
			local harness = h:wire()
			local result = harness.invoke(Net.Actions.BuyStructure, player, { key = "drones" })
			h.startContext.data = h.data

			local after = h:snap(player)
			-- The purchase IS committed and IS paid for, whatever the reply says:
			expect(after.levels.drones):toBe(1)
			expectClose(
				before.credits - after.credits,
				price,
				"the poisoned push seam changed what the purchase debited"
			)
			expect(after.spent):toBe(before.spent + 1)
			-- ... so the reply must describe THAT purchase, not an Internal error.
			expect(result):toBeOk()
			expect((result :: any).value.key):toBe("drones")
			expect((result :: any).value.level):toBe(1)
			expectClose(
				(result :: any).value.cost,
				price,
				"the buy reply's cost disagrees with the debit that actually happened"
			)
		end)

		it("pushView itself absorbs a throwing seam and REPORTS the failure as false", function()
			-- Bound at the unit, not only at `buy`: `pushView`'s own contract is "every caller ignores
			-- the return value — a presentation failure must never turn a granted purchase into an
			-- error", which is only true if the failure never leaves this function. The `data:get` that
			-- feeds the push sat OUTSIDE its pcall, so the seam it reads through could throw straight
			-- past that contract. This case pins the guard to the function that promises it, so a
			-- caller-side pcall cannot stand in for it.
			local h = newServer()
			local player = h:join(1)
			local context: any = { net = h.startContext.net, data = throwingGet(h.data) }
			local ok, pushed = pcall(function(): any
				return StructuresShopService:pushView(context, player)
			end)
			expectTrue(ok, `pushView THREW instead of reporting a failed push: {tostring(pushed)}`)
			expect(pushed):toBe(false)
			-- and the control: with an honest seam it really does push, so `false` above means
			-- "the push failed", not "this function never pushes".
			expect(StructuresShopService:pushView(h.startContext, player)):toBe(true)
		end)

		it("a throwing push seam does not throw out of a DIRECT buy either", function()
			-- The same escape, one layer lower: without Net.dispatch's pcall in front of it, the throw is
			-- not an Err at all — it is an exception crossing the service boundary, which any caller that
			-- is not a dispatch (the kiosk path, a later feature, a bootstrap hook) would take unguarded.
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			h.startContext.data = throwingGet(h.data)
			local ok, result = pcall(function(): any
				return h:buy(player, "drones")
			end)
			h.startContext.data = h.data
			expectTrue(
				ok,
				`buy THREW out of its post-write push instead of returning a Result: {tostring(
					result
				)}`
			)
			expect(result):toBeOk()
			expect(h:snap(player).levels.drones):toBe(1)
		end)
	end
)

-- ── 11. REGRESSION (F3) — ONE AUTHORITY ON WHAT A LEVEL MEANS, AND A POISONED BYTE IS REPAIRED ──
--
-- THE DEFECT THESE CASES PIN. A persisted level is clamped in two places that disagree: this shop
-- clamps to the catalog's own `maxLevel` (25 for drones), while SalvageService clamps to a private
-- MAX_UPGRADE_LEVEL of 10000 (and DepthService keeps a third copy of that 10000 for `hull`). With
-- `upgrades.drones = 1e308` on a hacked, legacy or mis-migrated blob:
--   * the shop reports level 25 / maxed / nextCost 0 and refuses `buy` with PrereqUnmet,
--   * `ctx.salvage:rateFor` goes on paying a fleet of STARTER_DRONES + 10000,
--   * and the shop ROW is inverted: `describeEntry` probes the "next" reading at
--     `math.min(level + 1, maxLevel)` = 25, so the row advertises a rate LOWER than the one the tick
--     is actually paying — a NEGATIVE delta on an upgrade.
-- The two authorities describe different fleets, and nothing ever repairs the byte: `1e308` is a
-- usable number (only NaN and ±inf are rejected), so `levelOf` floors and clamps it, the buy transform
-- takes its `level >= maxLevel` branch and returns BEFORE the only write in the file. The poison
-- therefore survives every purchase attempt forever and bricks that entry as permanently maxed.
--
-- WHY THIS IS THE DELTA, NOT A RESTATEMENT OF §4's POISON CASE: that case asserts the BALANCE is
-- finite and was not minted and no free level was granted — all of which stay true here. These cases
-- assert the two things it never looks at: that the shop and the income engine AGREE about what the
-- player owns, and that the poisoned byte is REPAIRED rather than left on the blob.
--
-- The repair is a legal single-writer write: it happens inside the ONE lock-held ctx.data:update
-- transform `buy` already runs (CLAUDE.md §4), on the snapshot the per-player FIFO lock just handed
-- over — never on a read path, which is why `fetch` still cannot fix it and why the assertions below
-- take the repair through a real buy attempt.
describe(
	"structures: the shop's clamp is THE authority, and it repairs the byte it clamps",
	function()
		-- The rate engine's own reading of a blob whose drones level is exactly `level` — i.e. what the
		-- tick WOULD pay if the persisted byte said what the shop says it says.
		local function rateAtLevel(h: any, blob: any, level: number): number
			local probe = deepCopy(blob)
			if type(probe.upgrades) ~= "table" then
				probe.upgrades = {}
			end
			probe.upgrades.drones = level
			return h.seam:rateFor(probe, h.clock:unix(), nil)
		end

		it("a shop row never advertises a NEGATIVE effect delta on a poisoned blob", function()
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			h:write(player, function(d: any): ()
				d.upgrades.drones = 1e308
			end)
			local row = entryOf(h:view(player), "drones")
			expectTrue(row ~= nil, "the shop view has no row for drones")
			expectFinite(row.effect.current, "the drones row reports a non-finite current reading")
			expectFinite(row.effect.next, "the drones row reports a non-finite next reading")
			expectTrue(
				row.effect.delta >= 0,
				`the drones row advertises a NEGATIVE delta ({row.effect.current} -> {row.effect.next}): `
					.. "the shop is probing one level higher than IT thinks the player owns, while the rate "
					.. "engine is paying a different, larger fleet — two authorities, one row"
			)
		end)

		it(
			"one buy attempt REPAIRS a poisoned level, and the two authorities then agree",
			function()
				local h = newServer()
				local player = h:join(1)
				h:fund(player, 1_000_000)
				local maxLevel = entryOf(h:view(player), "drones").maxLevel
				h:write(player, function(d: any): ()
					d.upgrades.drones = 1e308
				end)
				local creditsBefore = h:snap(player).credits

				h:buy(player, "drones") -- refused at the cap; the point is what it leaves behind

				-- (c) the persisted byte is finite and within the shop's own cap
				local persisted = persistedLevel(h:blob(player), "drones")
				expectFinite(persisted, "a poisoned level survived a buy attempt un-repaired")
				expectTrue(
					persisted <= maxLevel,
					`the persisted drones level is {persisted}, above the shop's own max of {maxLevel} — the `
						.. "clamp applies to the READING only, so the poison stays on the blob forever and "
						.. "bricks the entry as permanently maxed"
				)
				-- and the refusal is still a refusal: nothing was debited for the repair
				expect(h:snap(player).credits):toBe(creditsBefore)

				-- (a) the shop and the income engine now describe the SAME fleet
				local shopLevel = entryOf(h:view(player), "drones").level
				expectClose(
					h:rate(player),
					rateAtLevel(h, h:blob(player), shopLevel),
					`the shop reports drones level {shopLevel} while ctx.salvage:rateFor prices a different `
						.. "fleet off the same blob"
				)
			end
		)

		it("the repair is not a blanket rewrite: honest levels are left exactly alone", function()
			-- The counterweight. A build that wrote the clamped level back on EVERY buy would satisfy the
			-- case above and quietly seed `upgrades` keys nobody bought, so: a clean blob's bytes, and the
			-- keys present on it, must come through a buy untouched apart from the one level purchased.
			local h = newServer()
			local player = h:join(1)
			h:fund(player, 1_000_000)
			h:write(player, function(d: any): ()
				d.upgrades.drones = 3
			end)
			expect(h:buy(player, "drones")):toBeOk()
			local blob = h:blob(player)
			expect(persistedLevel(blob, "drones")):toBe(4)
			for _, key in { "conveyor", "smelter", "hull", "pearlDrones" } do
				expectTrue(
					blob.upgrades[key] == nil,
					`buying drones seeded the unrelated upgrade key "{key}" ({tostring(
						blob.upgrades[key]
					)})`
				)
			end
		end)
	end
)
