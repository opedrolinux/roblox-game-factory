--!strict
-- games/collect-sim/tests/unit/monetization.spec.luau
-- [INDEPENDENT TEST GATE — authored from the monetization SPEC, NOT the implementation.]
--
-- Contract under test (verbatim spec guarantees):
--   * Gamepass OWNERSHIP recorded as flags['gamepass.2xStardust'|'gamepass.autoCollect'|'gamepass.vipIsland']
--     booleans; the three gamepasses GATE their effects. The observable seam is the 2x-Stardust
--     multiplier: stardustMultiplier(userId) -> 2 iff the player OWNS the 2x gamepass OR holds an
--     active 30-min boost, else 1.
--   * Dev-product receipts processed IDEMPOTENTLY: the handler records each processed receipt id in the
--     `receipts` ledger and returns NotProcessedYet on ANY failure, so a purchase is NEVER double-granted
--     or lost (real money). A replayed receipt id grants nothing twice.
--   * Stardust-pack grants ADD a SERVER-owned amount to currencies.Stardust atomically (one ctx.data:update
--     transform); EARN path -> increment stats.lifetimeStardust by the SAME amount AND emit currency_earned.
--   * 30-min 2x boost is SESSION-ONLY (in-memory expiry vs ctx.clock).
--   * Every successful purchase emits `purchase` THROUGH ctx.analytics.
--
-- This gate drives the REAL MonetizationService LOGIC (ProcessReceipt / stardustMultiplier /
-- receiptDecision / hasActiveBoost) over the REAL DataService + MockStore + Clock + AnalyticsService
-- (production code), so the economy guarantee is genuinely exercised, not re-implemented. Expectations
-- are derived from the spec; product ids/amounts are DISCOVERED through the service's behaviour rather
-- than copied out of the handler's control flow.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local MonetizationService = require("../../src/server/services/monetization/MonetizationService")
local DataService = require("../../src/server/data/DataService")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Migrations = require("../../src/shared/Migrations")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local TWO_X_GAMEPASS_FLAG = "gamepass.2xStardust"
local BOOST_SECONDS = 30 * 60 -- spec: a 30-min boost

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build a REAL DataService over a (optionally yielding/seeded) MockStore, with one player's session
-- loaded so ProcessReceipt / stardustMultiplier read a live, lock-protected snapshot.
local function setup(opts: any): (any, any, any, any)
	local o = opts or {}
	local clock = Mocks.clock(o.startUnix or 1000)
	local cfg = config()
	local storeOpts: any = { clock = clock, config = cfg }
	if o.yieldOnUpdate then
		storeOpts.yieldOnUpdate = true
	end
	if o.seed ~= nil then
		storeOpts.seed = o.seed
	end
	local store = Mocks.store(storeOpts)
	local data = DataService.new(store, clock, cfg, Mocks.logWarn)
	local player = Mocks.player(o.userId or 1)
	data:loadSession(player)
	local service = MonetizationService.new(data, clock)
	return service, data, player, clock
end

-- A seed blob for player_<userId> at the CURRENT schema version (so loadSession doesn't migrate it
-- in surprising ways) with optional flags pre-set. Mirrors the fresh-player default shape.
local function seedFor(userId: number, flags: { [string]: any }?): any
	local blob = Migrations.default(1000)
	blob.flags = flags or {}
	return { ["player_" .. tostring(userId)] = blob }
end

-- Round-robin coroutine driver (mirrors economy_race.spec): resume every suspended coroutine until
-- all are dead. Bounded against deadlock.
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

-- Discover a Stardust-pack product id + its server-owned grant amount through OBSERVED behaviour:
-- process a unique receipt and read the granted amount the service reports + the balance delta. This
-- keeps the gate from copying catalog literals out of the implementation.
local function grantOnce(service: any, userId: number, productId: number, purchaseId: string): any
	return service:ProcessReceipt({
		PlayerId = userId,
		ProductId = productId,
		PurchaseId = purchaseId,
	})
end

-- ============================================================================================
-- GAMEPASS GATING — the three gamepasses gate their effects via OWNERSHIP flags; the observable
-- seam is the 2x-Stardust multiplier.
-- ============================================================================================
describe("monetization: gamepass ownership gates the 2x-Stardust seam", function()
	it("no gamepass, no boost -> multiplier is the identity 1 (un-gated baseline)", function()
		local service, _data, player = setup({ seed = seedFor(1, {}) })
		expect(service:stardustMultiplier(player.UserId)):toBe(1)
	end)

	it("owning flags['gamepass.2xStardust'] gates the effect: multiplier becomes 2", function()
		local service, _data, player =
			setup({ seed = seedFor(1, { [TWO_X_GAMEPASS_FLAG] = true }) })
		expect(service:stardustMultiplier(player.UserId)):toBe(2)
	end)

	it(
		"UNRELATED gamepass flags (autoCollect / vipIsland) do NOT grant the 2x multiplier",
		function()
			-- The autoCollect / vipIsland gamepasses gate OTHER effects; owning them must NOT leak into
			-- the Stardust multiplier (a mint vector if they did).
			local service, _data, player = setup({
				seed = seedFor(1, {
					["gamepass.autoCollect"] = true,
					["gamepass.vipIsland"] = true,
				}),
			})
			expect(service:stardustMultiplier(player.UserId)):toBe(1)
		end
	)

	it("the flag must be exactly true: a truthy-but-not-true value does NOT gate 2x", function()
		-- Spec: ownership is a BOOLEAN flag. A stray string/number must not be treated as ownership.
		local service, _data, player = setup({ seed = seedFor(1, { [TWO_X_GAMEPASS_FLAG] = 1 }) })
		expect(service:stardustMultiplier(player.UserId)):toBe(1)
	end)

	it(
		"an unloaded player never errors the Sell formula -> identity 1 (graceful default)",
		function()
			local service = setup({ seed = seedFor(1, {}) })
			expect(service:stardustMultiplier(999999)):toBe(1)
		end
	)
end)

-- ============================================================================================
-- DEV-PRODUCT RECEIPTS — Stardust packs are an EARN path: server-owned amount added to
-- currencies.Stardust AND stats.lifetimeStardust by the SAME amount, atomically.
-- ============================================================================================
describe("monetization: Stardust-pack receipt is a server-owned EARN", function()
	it("a pack grant credits Stardust by a SERVER-owned amount (client supplies none)", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		local before = (data:get(player) :: any).value.currencies.Stardust
		local r = grantOnce(service, player.UserId, 101, "rcpt-S-1")
		expect(r):toBeOk()
		expect((r :: any).value.granted):toBe(true)
		local amount = (r :: any).value.amount
		expect(amount > 0):toBe(true) -- a pack grants a positive server-owned amount
		local after = (data:get(player) :: any).value.currencies.Stardust
		expect(after - before):toBe(amount) -- balance moved by EXACTLY the granted amount
	end)

	it("the grant amount is fixed by the catalog, NOT by any client/receipt number", function()
		-- Deliver a receipt carrying a huge attacker-controlled `amount`/`CurrencySpent`; the grant
		-- must equal the same server-owned size as a clean receipt for that product (never the input).
		local clean = setup({ seed = seedFor(1, {}) })
		local cleanRes = grantOnce(clean, 1, 102, "rcpt-clean")
		expect(cleanRes):toBeOk()
		local serverAmount = (cleanRes :: any).value.amount

		local service, data, player = setup({ userId = 2, seed = seedFor(2, {}) })
		local r = service:ProcessReceipt({
			PlayerId = player.UserId,
			ProductId = 102,
			PurchaseId = "rcpt-evil",
			amount = 999999999, -- attacker-supplied; must be ignored
			CurrencySpent = 999999999,
		})
		expect(r):toBeOk()
		expect((r :: any).value.amount):toBe(serverAmount)
		expect((data:get(player) :: any).value.currencies.Stardust):toBe(serverAmount)
	end)

	it("EARN path: lifetimeStardust increments by the SAME amount as the balance", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		local before = (data:get(player) :: any).value.stats.lifetimeStardust
		local r = grantOnce(service, player.UserId, 103, "rcpt-L-1")
		expect(r):toBeOk()
		local amount = (r :: any).value.amount
		local d = (data:get(player) :: any).value
		expect(d.stats.lifetimeStardust - before):toBe(amount) -- lifetime accrues the SAME amount
		expect(d.currencies.Stardust):toBe(amount)
	end)

	it("two DIFFERENT pack receipts both grant -> balance + lifetime are the exact sum", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		local a = grantOnce(service, player.UserId, 101, "rcpt-a")
		local b = grantOnce(service, player.UserId, 103, "rcpt-b")
		expect(a):toBeOk()
		expect(b):toBeOk()
		local sum = (a :: any).value.amount + (b :: any).value.amount
		local d = (data:get(player) :: any).value
		expect(d.currencies.Stardust):toBe(sum)
		expect(d.stats.lifetimeStardust):toBe(sum)
	end)
end)

-- ============================================================================================
-- IDEMPOTENCY — a replayed receipt id grants nothing twice; the ledger records the id.
-- ============================================================================================
describe("monetization: receipt idempotency (real money, never double-granted)", function()
	it(
		"replaying the SAME receipt id grants nothing the second time (sequential replay)",
		function()
			local service, data, player = setup({ seed = seedFor(1, {}) })
			local first = grantOnce(service, player.UserId, 101, "dup-1")
			expect(first):toBeOk()
			expect((first :: any).value.granted):toBe(true)
			local amount = (first :: any).value.amount
			local balanceAfterFirst = (data:get(player) :: any).value.currencies.Stardust

			local second = grantOnce(service, player.UserId, 101, "dup-1")
			expect(second):toBeOk() -- replay is reported as success (honored on original delivery)...
			expect((second :: any).value.granted):toBe(false) -- ...but grants NOTHING this time
			-- The balance and lifetime did not move on the replay.
			expect((data:get(player) :: any).value.currencies.Stardust):toBe(balanceAfterFirst)
			expect((data:get(player) :: any).value.stats.lifetimeStardust):toBe(amount)
		end
	)

	it("the processed receipt id is recorded in the persisted `receipts` ledger", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 102, "ledger-1")
		expect((data:get(player) :: any).value.receipts["ledger-1"]):toBe(true)
	end)

	it("a NEW receipt id for the same product DOES grant again (idempotency is per-id)", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		local r1 = grantOnce(service, player.UserId, 101, "id-A")
		local r2 = grantOnce(service, player.UserId, 101, "id-B")
		expect((r1 :: any).value.granted):toBe(true)
		expect((r2 :: any).value.granted):toBe(true)
		local amt = (r1 :: any).value.amount
		expect((data:get(player) :: any).value.currencies.Stardust):toBe(amt * 2)
	end)
end)

-- ============================================================================================
-- FAILURE -> NotProcessedYet — bad payloads + unknown product + failed write never grant,
-- and the runtime decision is NotProcessedYet so Roblox redelivers (purchase never lost).
-- ============================================================================================
describe(
	"monetization: any failure -> Err -> NotProcessedYet (never granted, never lost)",
	function()
		it("non-table receiptInfo -> Err(BadPayload)", function()
			local service = setup({ seed = seedFor(1, {}) })
			expect(service:ProcessReceipt(42)):toBeErr(Result.Codes.BadPayload)
			expect(service:ProcessReceipt("nope")):toBeErr(Result.Codes.BadPayload)
			expect(service:ProcessReceipt(nil)):toBeErr(Result.Codes.BadPayload)
		end)

		it("missing / wrong-typed PlayerId or ProductId -> Err(BadPayload)", function()
			local service = setup({ seed = seedFor(1, {}) })
			expect(service:ProcessReceipt({ ProductId = 101, PurchaseId = "x" })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(service:ProcessReceipt({ PlayerId = "1", ProductId = 101, PurchaseId = "x" })):toBeErr(
				Result.Codes.BadPayload
			)
			expect(service:ProcessReceipt({ PlayerId = 1, ProductId = "101", PurchaseId = "x" })):toBeErr(
				Result.Codes.BadPayload
			)
		end)

		it(
			"missing / empty PurchaseId -> Err(BadPayload) (no idempotency key = refuse, never grant)",
			function()
				local service, data, player = setup({ seed = seedFor(1, {}) })
				expect(service:ProcessReceipt({ PlayerId = player.UserId, ProductId = 101 })):toBeErr(
					Result.Codes.BadPayload
				)
				expect(service:ProcessReceipt({
					PlayerId = player.UserId,
					ProductId = 101,
					PurchaseId = "",
				})):toBeErr(Result.Codes.BadPayload)
				-- Nothing was granted on either refusal.
				expect((data:get(player) :: any).value.currencies.Stardust):toBe(0)
			end
		)

		it("unknown / unsold product id -> Err(OutOfRange), nothing granted", function()
			local service, data, player = setup({ seed = seedFor(1, {}) })
			local r = grantOnce(service, player.UserId, 99999, "unknown-1")
			expect(r):toBeErr(Result.Codes.OutOfRange)
			expect((data:get(player) :: any).value.currencies.Stardust):toBe(0)
			-- A refused unknown id is NOT recorded in the ledger (so a later valid id is unaffected).
			expect((data:get(player) :: any).value.receipts["unknown-1"]).never:toBe(true)
		end)

		it(
			"a failed data commit -> Err, NEVER a grant (NotProcessedYet so Roblox redelivers)",
			function()
				-- failSave makes session.save/release fail, but update commits to the in-memory backing;
				-- to force the COMMIT path to fail we use a store that has no loaded session: ProcessReceipt
				-- on a NoData player must surface the Err and grant nothing.
				local service, _data, _player = setup({ seed = seedFor(1, {}) })
				-- userId 7 is never loaded -> data:update returns NoData -> ProcessReceipt surfaces it.
				local r = grantOnce(service, 7, 101, "nodata-1")
				expect(r):toBeErr(Result.Codes.NoData)
				expect((r :: any).value):toBe(nil)
			end
		)

		it(
			"receiptDecision maps Ok -> PurchaseGranted and Err -> NotProcessedYet (Lune string fallback)",
			function()
				local service, _data, player = setup({ seed = seedFor(1, {}) })
				-- Granted receipt -> PurchaseGranted.
				expect(service:receiptDecision({
					PlayerId = player.UserId,
					ProductId = 101,
					PurchaseId = "dec-1",
				})):toBe("PurchaseGranted")
				-- A replay is still PurchaseGranted (honored once; Roblox should stop redelivering).
				expect(service:receiptDecision({
					PlayerId = player.UserId,
					ProductId = 101,
					PurchaseId = "dec-1",
				})):toBe("PurchaseGranted")
				-- Any failure -> NotProcessedYet (Roblox redelivers; purchase never lost).
				expect(service:receiptDecision({
					PlayerId = player.UserId,
					ProductId = 99999,
					PurchaseId = "dec-bad",
				})):toBe("NotProcessedYet")
				expect(service:receiptDecision(nil)):toBe("NotProcessedYet")
			end
		)
	end
)

-- ============================================================================================
-- 30-MIN 2x BOOST — session-only, in-memory expiry vs the SERVER clock.
-- ============================================================================================
describe("monetization: 30-min 2x boost is session-only and clock-gated", function()
	it("buying the boost arms a 2x multiplier with no gamepass owned", function()
		local service, _data, player, clock = setup({ seed = seedFor(1, {}) })
		expect(service:stardustMultiplier(player.UserId)):toBe(1) -- baseline
		local r = grantOnce(service, player.UserId, 201, "boost-1")
		expect(r):toBeOk()
		expect((r :: any).value.granted):toBe(true)
		expect(service:hasActiveBoost(player.UserId)):toBe(true)
		expect(service:stardustMultiplier(player.UserId)):toBe(2)
		-- clock has not advanced; boost is live for the full window.
		clock:advance(BOOST_SECONDS - 1)
		expect(service:stardustMultiplier(player.UserId)):toBe(2)
	end)

	it("the boost expires after 30 minutes on the SERVER clock (back to 1)", function()
		local service, _data, player, clock = setup({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 201, "boost-exp")
		expect(service:hasActiveBoost(player.UserId)):toBe(true)
		clock:advance(BOOST_SECONDS) -- exactly at expiry -> lapsed (strict future required)
		expect(service:hasActiveBoost(player.UserId)):toBe(false)
		expect(service:stardustMultiplier(player.UserId)):toBe(1)
	end)

	it("the boost grant does NOT mint Stardust (it is a multiplier, not currency)", function()
		local service, data, player = setup({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 201, "boost-nomint")
		expect((data:get(player) :: any).value.currencies.Stardust):toBe(0)
		expect((data:get(player) :: any).value.stats.lifetimeStardust):toBe(0)
	end)

	it("replaying a boost receipt does NOT re-arm a second boost window", function()
		local service, _data, player, clock = setup({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 201, "boost-replay")
		clock:advance(BOOST_SECONDS - 10) -- near expiry
		-- Replay the SAME id: must short-circuit at the ledger and NOT extend the window.
		local replay = grantOnce(service, player.UserId, 201, "boost-replay")
		expect((replay :: any).value.granted):toBe(false)
		clock:advance(20) -- past the ORIGINAL expiry (10 + 20 > 0 window remainder)
		expect(service:hasActiveBoost(player.UserId)):toBe(false) -- no second window armed
	end)
end)

-- ============================================================================================
-- ANALYTICS — every successful purchase emits `purchase`; a pack ALSO emits currency_earned
-- with the SERVER-owned amount.
-- ============================================================================================
describe("monetization: analytics emission through the ctx.analytics seam", function()
	local function withAnalytics(opts: any): (any, any, any, any)
		local service, data, player, clock = setup(opts)
		local analytics = AnalyticsService.new(clock)
		service._analytics = analytics
		return service, data, player, analytics
	end

	it("a Stardust-pack purchase emits `purchase` AND `currency_earned` (server amount)", function()
		local service, _data, player, analytics = withAnalytics({ seed = seedFor(1, {}) })
		local r = grantOnce(service, player.UserId, 101, "an-pack")
		local amount = (r :: any).value.amount

		local purchases = analytics:eventsOfType("purchase")
		expect(#purchases):toBe(1)
		expect(purchases[1].payload.productId):toBe(101)
		expect(purchases[1].payload.receiptId):toBe("an-pack")

		local earned = analytics:eventsOfType("currency_earned")
		expect(#earned):toBe(1)
		expect(earned[1].payload.amount):toBe(amount) -- the SERVER-owned grant, not a client number
		expect(earned[1].payload.currency):toBe("Stardust")
	end)

	it("a boost purchase emits `purchase` but NOT currency_earned (no currency minted)", function()
		local service, _data, player, analytics = withAnalytics({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 201, "an-boost")
		expect(#analytics:eventsOfType("purchase")):toBe(1)
		expect(#analytics:eventsOfType("currency_earned")):toBe(0)
	end)

	it("a REPLAYED receipt emits NOTHING (the original delivery already emitted)", function()
		local service, _data, player, analytics = withAnalytics({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 101, "an-replay")
		local afterFirst = #analytics:events()
		grantOnce(service, player.UserId, 101, "an-replay") -- replay
		expect(#analytics:events()):toBe(afterFirst) -- no second emit on the replay
	end)

	it("a FAILED receipt (unknown product) emits nothing", function()
		local service, _data, player, analytics = withAnalytics({ seed = seedFor(1, {}) })
		grantOnce(service, player.UserId, 99999, "an-fail")
		expect(#analytics:events()):toBe(0)
	end)
end)

-- ============================================================================================
-- CONCURRENCY / RACES — the economy red-team target. Interleaved + spam-DUPLICATED deliveries of
-- the SAME receipt id must serialise against the per-player FIFO lock: granted EXACTLY ONCE, never
-- double-spent. Uses the yielding store + coroutine driver so the deliveries genuinely interleave
-- inside the critical section (sequential calls would NOT prove this).
-- ============================================================================================
describe("monetization: concurrency-safe receipts (falsifiable double-spend defense)", function()
	it("TWO interleaved deliveries of the SAME receipt id grant the pack EXACTLY ONCE", function()
		-- yieldOnUpdate forces a yield inside the lock critical section, so the second delivery arriving
		-- during the first's transform is FORCED to park in the FIFO and re-read the JUST-WRITTEN ledger
		-- -> it must be shed as already-processed. A naive read->yield->write (no re-read) would grant
		-- twice; this assertion (single grant) rejects that, so a GREEN test distinguishes the mechanism.
		local service, data, player = setup({ yieldOnUpdate = true, seed = seedFor(1, {}) })
		local results: { any } = {}
		local cos = {
			coroutine.create(function()
				results.a = grantOnce(service, player.UserId, 101, "race-same")
			end),
			coroutine.create(function()
				results.b = grantOnce(service, player.UserId, 101, "race-same")
			end),
		}
		drain(cos)

		expect(results.a):toBeOk()
		expect(results.b):toBeOk()
		-- Exactly one of the two interleaved deliveries actually granted.
		local grantedCount = 0
		if (results.a :: any).value.granted then
			grantedCount += 1
		end
		if (results.b :: any).value.granted then
			grantedCount += 1
		end
		expect(grantedCount):toBe(1)

		-- The economy invariant: the pack was credited ONCE (single amount), never doubled.
		local d = (data:get(player) :: any).value
		local single = (results.a :: any).value.amount > 0 and (results.a :: any).value.amount
			or (results.b :: any).value.amount
		expect(d.currencies.Stardust):toBe(single)
		expect(d.stats.lifetimeStardust):toBe(single)
		expect(d.receipts["race-same"]):toBe(true)
	end)

	it("FOUR spam-duplicated deliveries of one receipt id still grant EXACTLY ONCE", function()
		-- The spam-click class against real money: the SAME receipt fired 4x interleaved. The ledger
		-- re-read under the FIFO lock sheds every replay -> one grant, one ledger entry.
		local service, data, player = setup({ yieldOnUpdate = true, seed = seedFor(1, {}) })
		local results: { any } = {}
		local cos = {}
		for i = 1, 4 do
			local idx = i
			table.insert(
				cos,
				coroutine.create(function()
					results[idx] = grantOnce(service, player.UserId, 102, "spam-receipt")
				end)
			)
		end
		drain(cos)

		local grantedCount = 0
		local grantedAmount = 0
		for i = 1, 4 do
			expect(results[i]):toBeOk()
			if (results[i] :: any).value.granted then
				grantedCount += 1
				grantedAmount = (results[i] :: any).value.amount
			end
		end
		expect(grantedCount):toBe(1) -- never 4, never 2

		local d = (data:get(player) :: any).value
		expect(d.currencies.Stardust):toBe(grantedAmount) -- single credit, not 4x
		expect(d.stats.lifetimeStardust):toBe(grantedAmount)
	end)

	it("interleaved deliveries of DIFFERENT receipt ids each grant once -> exact sum", function()
		-- Distinct ids are independent purchases; both must commit (no lost update from interleaving).
		local service, data, player = setup({ yieldOnUpdate = true, seed = seedFor(1, {}) })
		local results: { any } = {}
		local cos = {
			coroutine.create(function()
				results.a = grantOnce(service, player.UserId, 101, "diff-A")
			end),
			coroutine.create(function()
				results.b = grantOnce(service, player.UserId, 101, "diff-B")
			end),
		}
		drain(cos)
		expect((results.a :: any).value.granted):toBe(true)
		expect((results.b :: any).value.granted):toBe(true)
		local sum = (results.a :: any).value.amount + (results.b :: any).value.amount
		local d = (data:get(player) :: any).value
		expect(d.currencies.Stardust):toBe(sum) -- no lost update under interleave
		expect(d.stats.lifetimeStardust):toBe(sum)
	end)
end)
