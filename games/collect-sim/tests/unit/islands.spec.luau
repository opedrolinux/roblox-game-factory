--!strict
-- games/collect-sim/tests/unit/islands.spec.luau   [INDEPENDENT TEST GATE — authored from the islands spec slice]
-- Adversarial Tier-1 gate for the "Islands & unlocks" feature. Authored from the SPEC's behavioral
-- guarantees, NOT from the implementation's branch logic (maker != checker). The spec slice:
--   * 4-6 islands gated by Stardust, each rarer/RICHER than the last; the starting island is ALWAYS
--     unlocked; unlocking the next island is a Stardust SINK with a SERVER-OWNED cost.
--   * unlock state is a per-player boolean per island under flags['island.<id>']; islands unlock IN
--     ORDER (an island's prerequisite must already be unlocked).
--   * a VIP island requires flags['gamepass.vipIsland'] ownership to unlock/access.
--   * on a successful unlock: deduct the SERVER cost + set the flag in ONE ctx.data:update transform,
--     emit progression + currency_spent THROUGH ctx.analytics.
--   * the client supplies ONLY which island id to unlock — never a price, never a multiplier, never an
--     island it has not earned. No open exploit (server owns the catalog/prices/multipliers).
--   * per-island mote value is the islandMultiplier the consolidated Sell formula reads from the
--     player's HIGHEST unlocked island (ctx.islands:multiplierFor(d)).
--   * economy concurrency-safe: interleaved unlock+sell+buy never double-spends Stardust.
--
-- We drive the actions the SAME way production does: call Start({ net = harness.registry }) so the
-- UnlockIsland/FetchIslands actions register onto a Mocks.net harness, then invoke through the REAL
-- Net.dispatch, with a real DataService over a MockStore as ctx.data. Stardust + the island flags are
-- read back through DataService:get — the persisted, lock-queued state — so a mint, a phantom grant,
-- or a double-spend is OBSERVABLE.
--
-- Constants are DISCOVERED through the API (FetchIslands), never copied from the implementation: the
-- catalog count, each island's cost / multiplier / vip flag / order all come from the read action.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local IslandsService = require("../../src/server/services/islands/IslandsService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local UNLOCK = Net.Actions.UnlockIsland -- "islands.unlock"
local FETCH = Net.Actions.FetchIslands -- "islands.fetch"
local VIP_FLAG = "gamepass.vipIsland" -- the spec's named ownership flag
local STARTING_ID = 1 -- the spec: the starting island is always unlocked (catalog order 1)

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build islands wired onto a fresh Mocks.net harness over a DataService with one loaded player.
-- `opts` flows to the mock store (yieldOnUpdate) and the harness (gate). gate defaults to false so
-- behavior is isolated from the rate gate. We also publish the islands seam onto the harness so a
-- focused multiplier test can call it; analytics is optionally injected to observe emitted events.
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
	-- Start registers both actions AND sets context.islands = seam. We pass a context object so we can
	-- also read the published seam back for the multiplier tests.
	local startCtx: any = { net = harness.registry }
	IslandsService:Start(startCtx)
	harness.islands = startCtx.islands
	return harness, data, player, clock
end

-- Read the persisted Stardust balance through the lock-queued data layer.
local function balanceOf(data: any, player: any): number
	local got = data:get(player)
	expect(got):toBeOk()
	return (got :: any).value.currencies.Stardust or 0
end

-- Read a persisted flag (nil -> false) through the data layer.
local function flagOf(data: any, player: any, key: string): boolean
	local got = data:get(player)
	expect(got):toBeOk()
	local flags = (got :: any).value.flags or {}
	return flags[key] == true
end

-- The FetchIslands projection (id, order, cost, multiplier, vip, unlocked), ordered by `order`.
-- This is the ONLY source of catalog constants in this spec — never the implementation table.
local function fetchIslands(harness: any, player: any): { any }
	local r = harness.invoke(FETCH, player, {})
	expect(r):toBeOk()
	local list = (r :: any).value.islands
	table.sort(list, function(a, b)
		return a.order < b.order
	end)
	return list
end

-- Round-robin coroutine driver: resume every suspended coroutine until all are dead. Used both to
-- seed through a yielding store and to interleave race invocations. Deterministic, deadlock-guarded.
-- (Identical technique to economy_race.spec / shop.spec — the REQUIRED concurrency mechanism.)
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

-- Set the player's Stardust through the canonical write path, drained so it works under yieldOnUpdate.
local function setStardust(data: any, player: any, amount: number): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = data:update(player, function(d)
			d.currencies.Stardust = amount
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

-- Set a flag (e.g. an island flag or the VIP grant) through the canonical write path, drained.
local function setFlag(data: any, player: any, key: string, value: boolean): ()
	local r: any = nil
	local co = coroutine.create(function()
		r = data:update(player, function(d)
			if d.flags == nil then
				d.flags = {}
			end
			d.flags[key] = value
			return d
		end)
	end)
	drain({ co })
	expect(r):toBeOk()
end

-- Unlock the islands in catalog order up to (and including) `targetOrder`, on a NON-yielding setup,
-- granting enough Stardust each step. Returns the harness/data/player so a test can then act at the
-- frontier. Grants the VIP flag along the way if a vip island lies on the path.
local function unlockUpTo(harness: any, data: any, player: any, targetOrder: number): ()
	local list = fetchIslands(harness, player)
	for _, island in list do
		if island.order > 1 and island.order <= targetOrder then
			if island.vip then
				setFlag(data, player, VIP_FLAG, true)
			end
			setStardust(data, player, island.cost) -- exactly enough for this step
			local r = harness.invoke(UNLOCK, player, { islandId = island.id })
			expect(r):toBeOk()
		end
	end
end

describe(
	"Islands — server-owned catalog shape (4-6 islands, rising, starting always unlocked)",
	function()
		it(
			"FetchIslands reports 4-6 islands, the starting island unlocked, the rest locked",
			function()
				local harness, _data, player = setup()
				local list = fetchIslands(harness, player)
				-- the spec: 4-6 islands.
				expect(#list >= 4):toBe(true)
				expect(#list <= 6):toBe(true)
				-- order 1 is the starting island: id 1, cost 0, unlocked for a fresh player.
				expect(list[1].order):toBe(1)
				expect(list[1].id):toBe(STARTING_ID)
				expect(list[1].cost):toBe(0)
				expect(list[1].unlocked):toBe(true)
				-- every NON-starting island is locked for a fresh player.
				for i = 2, #list do
					expect(list[i].unlocked):toBe(false)
				end
			end
		)

		it(
			"each island is rarer/RICHER than the last: cost AND multiplier strictly rise with order",
			function()
				local harness, _data, player = setup()
				local list = fetchIslands(harness, player)
				for i = 2, #list do
					-- strictly rising cost (it is a SINK that gets steeper) and strictly rising multiplier.
					expect(list[i].cost > list[i - 1].cost):toBe(true)
					expect(list[i].multiplier > list[i - 1].multiplier):toBe(true)
				end
				-- the starting island's multiplier is the floor (1): a fresh player's Sell multiplier.
				expect(list[1].multiplier):toBe(1)
			end
		)

		it(
			"the catalog projection never leaks a writable price path: FetchIslands does not mutate state",
			function()
				local harness, data, player = setup()
				setStardust(data, player, 12345)
				fetchIslands(harness, player)
				fetchIslands(harness, player)
				-- a read action changed nothing: balance and flags are untouched.
				expect(balanceOf(data, player)):toBe(12345)
				expect(flagOf(data, player, "island.2")):toBe(false)
			end
		)
	end
)

describe(
	"Islands — successful unlock (deduct exactly, set the flag, both persisted, in ONE write)",
	function()
		it(
			"unlocking island 2 deducts EXACTLY its server cost and sets flags['island.2'], both persisted",
			function()
				local harness, data, player = setup()
				local list = fetchIslands(harness, player)
				local island2 = list[2]
				setStardust(data, player, island2.cost + 1000) -- afford it with change to spare
				local before = balanceOf(data, player)
				expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(false)

				local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
				expect(r):toBeOk()
				local v = (r :: any).value
				-- return shape carries the server cost + the island's multiplier (client-derived nowhere).
				expect(v.islandId):toBe(island2.id)
				expect(v.cost):toBe(island2.cost)
				expect(v.multiplier):toBe(island2.multiplier)

				-- PERSISTED: balance fell by EXACTLY the cost, the unlock flag is set.
				expect(before - balanceOf(data, player)):toBe(island2.cost)
				expect(v.balance):toBe(balanceOf(data, player)) -- returned balance == persisted balance
				expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(true)
			end
		)

		it(
			"the core loop traverses up the chain: unlock 2 then 3 then 4 in order, each persisted",
			function()
				local harness, data, player = setup()
				local list = fetchIslands(harness, player)
				local highest = math.min(#list, 4) -- traverse at least through island 4 (skip vip if it is on path)
				for order = 2, highest do
					local island = list[order]
					if island.vip then
						break -- vip path is tested separately; stop the plain traversal before it
					end
					setStardust(data, player, island.cost)
					local r = harness.invoke(UNLOCK, player, { islandId = island.id })
					expect(r):toBeOk()
					expect(flagOf(data, player, "island." .. tostring(island.id))):toBe(true)
				end
				-- after traversal, FetchIslands reflects every unlocked island as unlocked = true.
				local after = fetchIslands(harness, player)
				for order = 2, highest do
					if after[order].vip then
						break
					end
					expect(after[order].unlocked):toBe(true)
				end
			end
		)

		it(
			"exactly-equal balance CAN afford (boundary: reject only when balance < cost)",
			function()
				local harness, data, player = setup()
				local island2 = fetchIslands(harness, player)[2]
				setStardust(data, player, island2.cost) -- exactly the cost
				local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
				expect(r):toBeOk()
				expect(balanceOf(data, player)):toBe(0) -- spent it all, exact
				expect((r :: any).value.balance):toBe(0)
				expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(true)
			end
		)
	end
)

describe(
	"Islands — progression + currency_spent emitted THROUGH ctx.analytics on success",
	function()
		it(
			"a successful unlock emits progression and currency_spent; the spend is NOT a mint",
			function()
				local events: { any } = {}
				local analytics = {
					emit = function(_self: any, name: string, payload: any)
						table.insert(events, { name = name, payload = payload })
					end,
				}
				local harness, data, player = setup({ analytics = analytics })
				local island2 = fetchIslands(harness, player)[2]
				setStardust(data, player, island2.cost)
				local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
				expect(r):toBeOk()

				-- both events fired.
				local sawProgression = false
				local spentAmount: number? = nil
				for _, e in events do
					if e.name == "progression" then
						sawProgression = true
						expect(e.payload.userId):toBe(player.UserId)
					elseif e.name == "currency_spent" then
						expect(e.payload.currency):toBe("Stardust")
						spentAmount = e.payload.amount
					end
				end
				expect(sawProgression):toBe(true)
				-- currency_spent reports EXACTLY the server cost (a sink, not a negative earn / mint).
				expect(spentAmount):toBe(island2.cost)
			end
		)

		it("a FAILED unlock (out of order) emits NOTHING through analytics", function()
			local count = 0
			local analytics = {
				emit = function(_self: any, _name: string, _payload: any)
					count += 1
				end,
			}
			local harness, data, player = setup({ analytics = analytics })
			local island3 = fetchIslands(harness, player)[3]
			setStardust(data, player, 1000000)
			-- island 3 with island 2 still locked -> rejected -> no progression/spend events.
			local r = harness.invoke(UNLOCK, player, { islandId = island3.id })
			expect(r):toBeErr()
			expect(count):toBe(0)
		end)
	end
)

describe("Islands — must unlock IN ORDER (prerequisite gate)", function()
	it(
		"unlocking island 3 while island 2 is locked -> Err(OutOfRange); no deduction, no flag",
		function()
			local harness, data, player = setup()
			local island3 = fetchIslands(harness, player)[3]
			setStardust(data, player, 1000000) -- can easily afford, but has NOT earned the predecessor
			local before = balanceOf(data, player)

			local r = harness.invoke(UNLOCK, player, { islandId = island3.id })
			expect(r):toBeErr(Result.Codes.OutOfRange)
			-- nothing spent, nothing unlocked.
			expect(balanceOf(data, player)):toBe(before)
			expect(flagOf(data, player, "island." .. tostring(island3.id))):toBe(false)
		end
	)

	it(
		"once island 2 is unlocked, island 3 becomes reachable (the gate is the IMMEDIATE predecessor)",
		function()
			local harness, data, player = setup()
			local list = fetchIslands(harness, player)
			local island2, island3 = list[2], list[3]
			-- island 3 must be NON-vip for this plain ordering test; if vip, this game has it at order 3 and
			-- the order test still holds via the 'before unlock 2' branch above. Guard so we only assert the
			-- positive path when island 3 is reachable without a vip grant.
			if island3.vip then
				return
			end
			unlockUpTo(harness, data, player, 2)
			expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(true)

			setStardust(data, player, island3.cost)
			local r = harness.invoke(UNLOCK, player, { islandId = island3.id })
			expect(r):toBeOk()
			expect(flagOf(data, player, "island." .. tostring(island3.id))):toBe(true)
		end
	)

	it(
		"the starting island can never be 'unlocked' by spending -> Err(OutOfRange), no deduction",
		function()
			local harness, data, player = setup()
			setStardust(data, player, 1000000)
			local before = balanceOf(data, player)
			local r = harness.invoke(UNLOCK, player, { islandId = STARTING_ID })
			expect(r):toBeErr(Result.Codes.OutOfRange)
			expect(balanceOf(data, player)):toBe(before) -- nothing spent on the free island
		end
	)

	it(
		"re-unlocking an ALREADY unlocked island is an idempotent no-op rejection (no second deduction)",
		function()
			local harness, data, player = setup()
			local island2 = fetchIslands(harness, player)[2]
			setStardust(data, player, island2.cost * 2 + 100) -- enough to (wrongly) pay twice
			expect(harness.invoke(UNLOCK, player, { islandId = island2.id })):toBeOk()
			local afterFirst = balanceOf(data, player)

			-- a SECOND unlock of the same island must NOT deduct again.
			local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
			expect(r):toBeErr(Result.Codes.OutOfRange)
			expect(balanceOf(data, player)):toBe(afterFirst) -- balance unchanged: no double sink
			expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(true) -- still unlocked
		end
	)
end)

describe("Islands — affordability (cannot afford -> Insufficient, no change)", function()
	it("balance one below the cost -> Err(Insufficient); balance AND flag unchanged", function()
		local harness, data, player = setup()
		local island2 = fetchIslands(harness, player)[2]
		setStardust(data, player, island2.cost - 1) -- one short
		local before = balanceOf(data, player)
		local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
		expect(r):toBeErr(Result.Codes.Insufficient)
		expect(balanceOf(data, player)):toBe(before)
		expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(false)
	end)

	it("a fresh (zero-balance) player can never unlock a paid island for free", function()
		local harness, data, player = setup()
		local island2 = fetchIslands(harness, player)[2]
		expect(balanceOf(data, player)):toBe(0)
		expect(island2.cost > 0):toBe(true) -- the next island is a real sink
		local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
		expect(r):toBeErr(Result.Codes.Insufficient)
		expect(balanceOf(data, player)):toBe(0)
		expect(flagOf(data, player, "island." .. tostring(island2.id))):toBe(false)
	end)
end)

describe("Islands — VIP island requires the gamepass.vipIsland ownership flag", function()
	-- Locate a vip island (the spec marks one vip in the server catalog). If none, the game has none
	-- and these cases pass vacuously (still authored to the spec's conditional guarantee).
	local function findVip(harness: any, player: any): any?
		for _, island in fetchIslands(harness, player) do
			if island.vip then
				return island
			end
		end
		return nil
	end

	it(
		"unlocking the VIP island WITHOUT gamepass.vipIsland -> Err(NotOwner); no deduction, no flag",
		function()
			local harness, data, player = setup()
			local vip = findVip(harness, player)
			if vip == nil then
				return
			end
			-- earn every predecessor so ONLY the vip gate stands between us and the unlock.
			unlockUpTo(harness, data, player, vip.order - 1)
			setStardust(data, player, vip.cost + 100) -- can afford; just lacks the gamepass
			expect(flagOf(data, player, VIP_FLAG)):toBe(false)
			local before = balanceOf(data, player)

			local r = harness.invoke(UNLOCK, player, { islandId = vip.id })
			expect(r):toBeErr(Result.Codes.NotOwner)
			expect(balanceOf(data, player)):toBe(before) -- not charged
			expect(flagOf(data, player, "island." .. tostring(vip.id))):toBe(false) -- not unlocked
		end
	)

	it(
		"WITH gamepass.vipIsland (and predecessors earned + funds), the VIP island unlocks",
		function()
			local harness, data, player = setup()
			local vip = findVip(harness, player)
			if vip == nil then
				return
			end
			unlockUpTo(harness, data, player, vip.order - 1)
			setFlag(data, player, VIP_FLAG, true) -- grant the gamepass ownership flag
			setStardust(data, player, vip.cost)
			local before = balanceOf(data, player)
			local r = harness.invoke(UNLOCK, player, { islandId = vip.id })
			expect(r):toBeOk()
			expect(before - balanceOf(data, player)):toBe(vip.cost)
			expect(flagOf(data, player, "island." .. tostring(vip.id))):toBe(true)
		end
	)
end)

describe(
	"Islands — malformed / abusive payloads (BadPayload / OutOfRange, no state change)",
	function()
		it("non-table payload -> Err(BadPayload); handler never runs, no state change", function()
			local harness, data, player = setup()
			setStardust(data, player, 1000000)
			local before = balanceOf(data, player)
			expect(harness.invoke(UNLOCK, player, 2)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(UNLOCK, player, "2")):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(UNLOCK, player, true)):toBeErr(Result.Codes.BadPayload)
			expect(harness.invoke(UNLOCK, player, nil)):toBeErr(Result.Codes.BadPayload)
			expect(balanceOf(data, player)):toBe(before)
		end)

		it("missing / non-number / non-integer islandId -> Err(BadPayload)", function()
			local harness, data, player = setup()
			setStardust(data, player, 1000000)
			expect(harness.invoke(UNLOCK, player, {})):toBeErr(Result.Codes.BadPayload) -- no islandId
			expect(harness.invoke(UNLOCK, player, { islandId = "2" })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(harness.invoke(UNLOCK, player, { islandId = true })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(harness.invoke(UNLOCK, player, { islandId = {} })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(harness.invoke(UNLOCK, player, { islandId = 2.5 })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(harness.invoke(UNLOCK, player, { islandId = 0 / 0 })):toBeErr(
				Result.Codes.BadPayload
			) -- NaN
			expect(harness.invoke(UNLOCK, player, { islandId = math.huge })):toBeErr(
				Result.Codes.BadPayload
			)
		end)

		it(
			"an unknown island id (outside the catalog) -> Err(OutOfRange); no state change",
			function()
				local harness, data, player = setup()
				setStardust(data, player, 1000000)
				local before = balanceOf(data, player)
				expect(harness.invoke(UNLOCK, player, { islandId = 9999 })):toBeErr(
					Result.Codes.OutOfRange
				)
				expect(harness.invoke(UNLOCK, player, { islandId = -3 })):toBeErr(
					Result.Codes.OutOfRange
				)
				expect(balanceOf(data, player)):toBe(before)
			end
		)

		it(
			"NO open exploit: a client-supplied price/multiplier/balance is ignored; cost is server-derived",
			function()
				-- The client smuggles cost/multiplier/balance fields. They must NEVER be honored: the cost is
				-- the catalog cost, identical to a clean unlock with no extra fields.
				local cleanHarness, cleanData, cleanPlayer = setup({ userId = 7777 })
				local cleanIsland2 = fetchIslands(cleanHarness, cleanPlayer)[2]
				setStardust(cleanData, cleanPlayer, cleanIsland2.cost)
				local clean =
					cleanHarness.invoke(UNLOCK, cleanPlayer, { islandId = cleanIsland2.id })
				expect(clean):toBeOk()
				local serverCost = (clean :: any).value.cost
				local serverMult = (clean :: any).value.multiplier

				local harness, data, player = setup()
				local island2 = fetchIslands(harness, player)[2]
				setStardust(data, player, island2.cost)
				local before = balanceOf(data, player)
				local r = harness.invoke(UNLOCK, player, {
					islandId = island2.id,
					cost = 0, -- "free", please
					price = 1,
					multiplier = 9999, -- a fat multiplier, please
					balance = 999999999,
				})
				expect(r):toBeOk()
				local v = (r :: any).value
				expect(v.cost):toBe(serverCost) -- the client's cost=0 was ignored
				expect(v.multiplier):toBe(serverMult) -- the client's multiplier=9999 was ignored
				expect(before - balanceOf(data, player)):toBe(serverCost) -- deducted the REAL cost, not 0
			end
		)
	end
)

describe(
	"Islands — the Sell multiplier seam reads the HIGHEST unlocked island (pure over snapshot)",
	function()
		-- The seam ctx.islands:multiplierFor(d) -> the player's highest-unlocked-island multiplier; nil
		-- snapshot -> identity 1 (so the pre-feature Sell is preserved exactly).
		it("nil snapshot -> identity default 1 (no I/O, no yield)", function()
			local harness = setup()
			expect(harness.islands:multiplierFor(nil)):toBe(1)
		end)

		it("a fresh player (only the starting island) -> multiplier 1", function()
			local harness, data, player = setup()
			local d = (data:get(player) :: any).value
			expect(harness.islands:multiplierFor(d)):toBe(1)
		end)

		it(
			"after unlocking islands, the seam returns the HIGHEST unlocked island's multiplier",
			function()
				local harness, data, player = setup()
				local list = fetchIslands(harness, player)
				-- climb to the highest NON-vip island so the test needs no gamepass; assert the seam tracks the
				-- top of the climb at each step.
				local top = 1
				for order = 2, #list do
					if list[order].vip then
						break
					end
					top = order
				end
				expect(top >= 2):toBe(true) -- there is at least one paid non-vip island to climb to

				for order = 2, top do
					setStardust(data, player, list[order].cost)
					expect(harness.invoke(UNLOCK, player, { islandId = list[order].id })):toBeOk()
					local d = (data:get(player) :: any).value
					-- the seam now reads THIS island (the new highest), not a lower one.
					expect(harness.islands:multiplierFor(d)):toBe(list[order].multiplier)
				end
			end
		)
	end
)

describe(
	"Islands — the read-only catalog seam (the world generator's source; server-owned)",
	function()
		-- ctx.islands:catalog() -> a FRESH { id, order, cost, multiplier, vip } projection in catalog order.
		-- WorldService reads it to build one greybox platform per island. We assert it AGREES with the
		-- client-facing FetchIslands projection (the SAME server-owned catalog), never copying the
		-- implementation table — so the world geometry can never silently diverge from server authority.
		it(
			"catalog() agrees with FetchIslands on count, ids, order, cost, multiplier, vip",
			function()
				local harness, _data, player = setup()
				local fetched = fetchIslands(harness, player) -- sorted by order
				local cat = harness.islands:catalog()
				table.sort(cat, function(a, b)
					return a.order < b.order
				end)
				expect(#cat):toBe(#fetched)
				for i = 1, #fetched do
					expect(cat[i].id):toBe(fetched[i].id)
					expect(cat[i].order):toBe(fetched[i].order)
					expect(cat[i].cost):toBe(fetched[i].cost)
					expect(cat[i].multiplier):toBe(fetched[i].multiplier)
					expect(cat[i].vip):toBe(fetched[i].vip)
				end
				-- the seam carries NO per-player field (it has no player): `unlocked` is FetchIslands-only.
				expect(cat[1].unlocked):toBe(nil)
			end
		)

		it(
			"catalog() is a PURE read: hands back a fresh table each call and mutates no state",
			function()
				local harness, data, player = setup()
				setStardust(data, player, 4242)
				local first = harness.islands:catalog()
				-- mutating the returned projection must not corrupt the server-owned catalog: a later call is clean.
				first[1].cost = -999
				first[1].id = 88888
				local second = harness.islands:catalog()
				expect(second[1].cost ~= -999):toBe(true)
				expect(second[1].id ~= 88888):toBe(true)
				-- and reading the catalog touched no player state.
				expect(balanceOf(data, player)):toBe(4242)
				expect(flagOf(data, player, "island.2")):toBe(false)
			end
		)
	end
)

describe(
	"Islands — concurrency-safe sink (interleaved + spam-duplicated never double-spend)",
	function()
		-- The economy_race technique (REQUIRED): drive interleaved invocations as coroutines against a
		-- yielding store so the second UnlockIsland arrives WHILE the first is parked inside the lock-held
		-- update. A double-spend would FAIL these assertions.

		it(
			"DOUBLE-UNLOCK: two interleaved unlocks of the SAME island -> exactly one deduction, one flag",
			function()
				-- Discover island 2's cost on a clean probe.
				local ph, _pd, pp = setup({ userId = 4242 })
				local probe2 = fetchIslands(ph, pp)[2]
				local cost = probe2.cost
				local islandId = probe2.id

				local harness, data, player = setup({ yieldOnUpdate = true })
				-- enough for EXACTLY ONE unlock (not two).
				setStardust(data, player, cost)
				local before = balanceOf(data, player)
				expect(before):toBe(cost)

				local results: { any } = {}
				local cos = {
					coroutine.create(function()
						results.a = harness.invoke(UNLOCK, player, { islandId = islandId })
					end),
					coroutine.create(function()
						results.b = harness.invoke(UNLOCK, player, { islandId = islandId })
					end),
				}
				drain(cos)

				-- exactly ONE Ok; the loser is rejected (already unlocked OR cannot afford) — never two grants.
				local oks = 0
				for _, key in { "a", "b" } do
					local r = results[key]
					if r.ok then
						oks += 1
						expect((r :: any).value.cost):toBe(cost)
					else
						expect(r):toBeErr() -- a clean rejection, NOT a second deduction
					end
				end
				expect(oks):toBe(1) -- never two unlocks for the money of one
				expect(flagOf(data, player, "island." .. tostring(islandId))):toBe(true) -- unlocked exactly once
				expect(before - balanceOf(data, player)):toBe(cost) -- EXACTLY one deduction
				expect(balanceOf(data, player) >= 0):toBe(true) -- balance NEVER went negative
			end
		)

		it(
			"SPAM-DUPLICATED: four interleaved identical unlocks with money for ONE -> exactly one grant",
			function()
				local ph, _pd, pp = setup({ userId = 9090 })
				local probe2 = fetchIslands(ph, pp)[2]
				local cost = probe2.cost
				local islandId = probe2.id

				local harness, data, player = setup({ yieldOnUpdate = true })
				setStardust(data, player, cost) -- money for exactly one
				local before = balanceOf(data, player)

				local results: { any } = {}
				local cos = {}
				for i = 1, 4 do
					local idx = i
					table.insert(
						cos,
						coroutine.create(function()
							results[idx] = harness.invoke(UNLOCK, player, { islandId = islandId })
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
						expect(r):toBeErr() -- losers shed cleanly (already-unlocked or insufficient)
					end
				end
				expect(oks):toBe(1) -- exactly one of four spam clicks unlocked the island
				expect(flagOf(data, player, "island." .. tostring(islandId))):toBe(true)
				expect(before - balanceOf(data, player)):toBe(cost) -- exactly ONE deduction
				expect(balanceOf(data, player) >= 0):toBe(true)
			end
		)

		it(
			"INTERLEAVED unlock + sell-shaped spend: a concurrent spend can never let the unlock overspend",
			function()
				-- Model an interleaved competing Stardust spend (a sell/buy that DEDUCTS, the worst case for a
				-- sink: the balance shrinks underneath the unlock). With money for the unlock OR the competing
				-- spend but not both, exactly one wins; the unlock can never deduct against a stale balance.
				local ph, _pd, pp = setup({ userId = 3131 })
				local island2 = fetchIslands(ph, pp)[2]
				local cost = island2.cost
				local islandId = island2.id

				local harness, data, player = setup({ yieldOnUpdate = true })
				setStardust(data, player, cost) -- exactly the island cost; a competing spend of `cost` drains it
				local before = balanceOf(data, player)

				local results: { any } = {}
				local cos = {
					-- the unlock
					coroutine.create(function()
						results.unlock = harness.invoke(UNLOCK, player, { islandId = islandId })
					end),
					-- a competing direct Stardust spend of the SAME amount, through the canonical write path:
					-- it only deducts when the balance can cover it (mirrors a guarded sell/buy).
					coroutine.create(function()
						results.spend = data:update(player, function(d)
							if (d.currencies.Stardust or 0) >= cost then
								d.currencies.Stardust -= cost
								results.spendApplied = true
							end
							return d
						end)
					end),
				}
				drain(cos)

				local finalBalance = balanceOf(data, player)
				-- INVARIANT: total Stardust removed is at most the starting balance (no double-spend / no mint).
				expect(finalBalance >= 0):toBe(true)
				local unlocked = results.unlock.ok == true
				local spent = results.spendApplied == true
				-- the two competing `cost`-sized spends cannot BOTH succeed against a balance of exactly `cost`.
				expect(unlocked and spent):toBe(false)
				-- whichever won removed exactly `cost`; conservation holds either way.
				if unlocked then
					expect(flagOf(data, player, "island." .. tostring(islandId))):toBe(true)
					expect(before - finalBalance):toBe(cost)
				else
					-- the unlock lost: it must NOT have set the flag (no grant without payment).
					expect(flagOf(data, player, "island." .. tostring(islandId))):toBe(false)
					expect(before - finalBalance):toBe(spent and cost or 0)
				end
			end
		)
	end
)

describe("Islands — rate limit (defence in depth, not the concurrency guarantee)", function()
	it(
		"spamming UnlockIsland past the action's rate window -> Err(RateLimited); refills after window",
		function()
			-- A REAL gate + injected clock enforces the action's own RatePolicy. The player has no money, so
			-- each allowed call is an Insufficient (mints nothing) until the gate sheds.
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local harness, data, player = setup({ gate = gate })
			local island2 = fetchIslands(harness, player)[2]
			expect(balanceOf(data, player)):toBe(0)

			local hitRateLimit = false
			local allowed = 0
			for _ = 1, 50 do
				local r = harness.invoke(UNLOCK, player, { islandId = island2.id })
				if not r.ok and r.code == Result.Codes.RateLimited then
					hitRateLimit = true
					break
				end
				expect(r):toBeErr(Result.Codes.Insufficient) -- before shedding: unaffordable, never Ok
				allowed += 1
			end
			expect(hitRateLimit):toBe(true) -- the bucket DID shed once exhausted
			expect(allowed > 0):toBe(true)

			clock:advance(60) -- refill
			expect(harness.invoke(UNLOCK, player, { islandId = island2.id })):toBeErr(
				Result.Codes.Insufficient
			) -- through the gate again (still no money)
		end
	)
end)
