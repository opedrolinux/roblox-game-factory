--!strict
-- games/collect-sim/src/server/services/monetization/MonetizationService.luau   [monetization]
-- Feature: real-money monetization. Three gamepasses gate effects via OWNERSHIP flags; dev-product
-- receipts are processed IDEMPOTENTLY (real money — never double-granted, never lost); a 2x Stardust
-- multiplier seam the consolidated Sell formula consumes; every successful purchase emits `purchase`
-- through ctx.analytics.
--
-- ================================ STATE OWNERSHIP =================================================
-- PERSISTED (all mutation through ctx.data:update — the single-writer, per-player FIFO-lock path):
--   * currencies.Stardust ............. credited by a Stardust-pack grant (an EARN path)
--   * stats.lifetimeStardust .......... incremented by the SAME amount on every earn (monotonic)
--   * receipts[receiptId] : boolean ... the idempotency LEDGER (a processed receipt id is recorded
--                                       here; a replay re-reads it INSIDE the lock and grants nothing)
--   * flags['gamepass.2xStardust' | 'gamepass.autoCollect' | 'gamepass.vipIsland'] : boolean
--                                       gamepass OWNERSHIP (granted out-of-band by the gamepass-grant
--                                       path / live-ops; this service only READS them for the seam)
-- IN-MEMORY SESSION STATE (closed over in Start; NOT persisted — the spec: "SESSION-ONLY"):
--   * _boostExpiry : { [userId] : number } .. the 30-min 2x boost's server-unix expiry per player.
--                                       Checked vs ctx.clock:unix(). Lost on server restart by design.
-- The service also captures `context.data` + `context.clock` in Start so the stardustMultiplier seam
-- (which is handed only a userId) can read the player's persisted flags + consult the server clock.
--
-- ============================== CONCURRENCY-SAFETY (real money) ===================================
-- ProcessReceipt is the economy red-team target. The idempotency check AND the grant are performed
-- INSIDE ONE ctx.data:update transform, on the lock-held re-read snapshot:
--   1. re-read receipts[receiptId] from the snapshot the lock handed us (post any earlier write);
--   2. if already present -> ALREADY PROCESSED: grant NOTHING, return d unchanged (the replay guard);
--   3. otherwise record receipts[receiptId] = true AND apply the grant (credit Stardust + accrue
--      lifetimeStardust for a pack) in the SAME synchronous transform, then return d.
-- Because the transform runs under the per-player FIFO lock on a FRESH re-read snapshot
-- (MockStore §4.1 / DataService.update), two interleaved or spam-duplicated deliveries of the SAME
-- receipt id serialise: the second re-reads the JUST-WRITTEN ledger flag and is shed as already-
-- processed. The ledger write and the grant commit ATOMICALLY together (one transform, no yield in
-- the body), so a receipt is NEVER double-granted and NEVER recorded-without-grant. There is NO
-- read-then-write across the yield: the decision reads only the snapshot it is handed.
--
-- The 30-min boost is session-only, but its idempotency is STILL persistent: the receipt id is
-- recorded in the SAME lock-held transform; the in-memory expiry is set ONLY when that transform
-- confirms the id was NEWLY recorded (commit-first), so a replay that re-reads the ledger sets no
-- second boost.
--
-- ============================== SERVER-DRIVEN (not a client action) ===============================
-- ProcessReceipt is the MarketplaceService receipt callback, NOT a Net.Action: it registers NO client
-- action. ProcessReceipt(receiptInfo) is Lune-clean and returns a Result (Tier-1 testable); the
-- runtime adapter receiptCallback() maps that Result to Enum.ProductPurchaseDecision (PurchaseGranted
-- on a granted/already-processed receipt, NotProcessedYet on ANY failure) and is wired to
-- MarketplaceService.ProcessReceipt in Start. The Enum is referenced Lune-safely (nil under Lune).
--
-- Lune-clean at the LOGIC level: ProcessReceipt / stardustMultiplier / the seam touch no Roblox
-- global, so a spec drives them directly. Only Start() references MarketplaceService (no spec calls it).
local Result = require("../../../shared/Result")
type Result<T> = Result.Result<T>

-- ----- SERVER-OWNED PRODUCT CATALOG (authoritative; the client supplies none of these numbers) -----
-- Dev products. `productId` is the stable Roblox developer-product id the receipt arrives keyed by;
-- `kind` selects the grant path; `amount` is the SERVER-owned Stardust granted by a pack (NEVER a
-- client number). The receipt's CurrencySpent / amount fields are real money and are never trusted as
-- a grant size — the grant is derived ENTIRELY from this catalog by productId.
type Product = { productId: number, kind: string, amount: number? }

-- Placeholder Roblox developer-product ids (replaced with real ids at publish; the LOGIC is keyed by
-- these, so tests discover them through the catalog rather than copying literals out of the handler).
local PRODUCTS: { Product } = {
	{ productId = 101, kind = "stardustPack", amount = 1000 }, -- Stardust pack S
	{ productId = 102, kind = "stardustPack", amount = 6000 }, -- Stardust pack M (better value)
	{ productId = 103, kind = "stardustPack", amount = 20000 }, -- Stardust pack L (best value)
	{ productId = 201, kind = "boost2x", amount = nil }, -- 30-min 2x Stardust boost (session-only)
}

-- The 2x-Stardust GAMEPASS ownership flag (a persisted per-player boolean on flags). Owning it OR
-- holding an active 30-min boost makes the Sell multiplier 2.
local GAMEPASS_2X_FLAG = "gamepass.2xStardust"

-- The session-only 30-min 2x boost duration, in seconds (30 * 60). Server-clock measured.
local BOOST_DURATION_SECONDS = 30 * 60

-- The multiplier a 2x source applies to a Sell (gamepass OR active boost). 1 otherwise.
local STARDUST_MULTIPLIER_2X = 2

-- Find a catalog product by id. Returns the product or nil for an unknown/unsold id. Linear scan
-- over a tiny fixed server-owned list (never client-sized).
local function findProduct(productId: number): Product?
	for _, product in PRODUCTS do
		if product.productId == productId then
			return product
		end
	end
	return nil
end

local MonetizationService = { name = "MonetizationService" }

-- ================================ CONSTRUCTION (Tier-1 callable) =================================
-- new(data, clock): the unit a spec drives directly. `data` is the DataService-like (get/update);
-- `clock` is the server clock (unix). The in-memory boost map is owned here. No I/O, no Roblox global.
-- (Start() constructs the same object from `context` for the runtime.)
function MonetizationService.new(data: any, clock: any): any
	local self = setmetatable({}, { __index = MonetizationService })
	self.name = "MonetizationService"
	self._data = data
	self._clock = clock
	-- session-only 2x boost: userId -> server-unix expiry. Absent / past-expiry => no boost.
	self._boostExpiry = {} :: { [number]: number }
	return self
end

-- Minimal Player surrogate so the data layer (which keys sessions by `.UserId`) can be addressed from
-- a bare userId — the seam + the receipt callback receive a userId, not a Player object. Reads only
-- .UserId (the documented constraint). Name is a stable, non-identifying placeholder.
local function playerRef(userId: number): any
	return { UserId = userId, Name = "User_" .. tostring(userId) }
end

-- Whether `userId` currently holds an active (non-expired) 30-min 2x boost. Pure read of the in-memory
-- map vs the SERVER clock (never client time): expiry strictly in the FUTURE counts as active; an
-- expiry exactly at or before now is lapsed. No I/O.
function MonetizationService.hasActiveBoost(self: any, userId: number): boolean
	local expiry = self._boostExpiry[userId]
	if expiry == nil then
		return false
	end
	return self._clock:unix() < expiry
end

-- ================================ THE SELL SEAM (consumed by collection Sell) =====================
-- ctx.monetization:stardustMultiplier(userId) -> 2 when the player OWNS the 2x gamepass
-- (flags['gamepass.2xStardust']) OR has an active 30-min boost (in-memory expiry vs ctx.clock), else 1.
-- Pure-ish read: a data:get (no yield — returns the already-loaded session snapshot) + an in-memory
-- map lookup. Defaults to the identity 1 whenever the player's data is unavailable, so a player whose
-- session is not loaded never errors the Sell formula — it just gets the un-multiplied base.
function MonetizationService.stardustMultiplier(self: any, userId: number): number
	-- Active in-memory boost is sufficient on its own (it grants 2x even without the gamepass).
	if self:hasActiveBoost(userId) then
		return STARDUST_MULTIPLIER_2X
	end
	-- Otherwise consult the PERSISTED gamepass ownership flag. data:get is a pure snapshot read.
	local got = self._data:get(playerRef(userId))
	if got.ok and got.value ~= nil then
		local flags = got.value.flags
		if flags ~= nil and flags[GAMEPASS_2X_FLAG] == true then
			return STARDUST_MULTIPLIER_2X
		end
	end
	return 1
end

-- ================================ PROCESS RECEIPT (idempotent, server-driven) =====================
-- ProcessReceipt(receiptInfo) -> Result. receiptInfo is the Roblox ReceiptInfo-shaped table the
-- MarketplaceService callback delivers: { PlayerId: number, ProductId: number, PurchaseId: string }
-- (other fields ignored — never trusted as a grant size). Returns:
--   Ok({ granted, productId, kind, amount, alreadyProcessed })  on a granted OR replayed receipt
--   Err(<code>)                                                  on ANY failure (-> NotProcessedYet)
-- Idempotency + the grant are ONE lock-held transform (see the header concurrency note).
function MonetizationService.ProcessReceipt(self: any, receiptInfo: any): Result<any>
	-- ----- untrusted-input validation (the receipt is server-delivered, but defend anyway) -----
	if typeof(receiptInfo) ~= "table" then
		return Result.err(Result.Codes.BadPayload, "receiptInfo must be a table")
	end
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local purchaseId = receiptInfo.PurchaseId
	if type(userId) ~= "number" or userId ~= userId then
		return Result.err(Result.Codes.BadPayload, "PlayerId must be a number")
	end
	if type(productId) ~= "number" or productId ~= productId then
		return Result.err(Result.Codes.BadPayload, "ProductId must be a number")
	end
	-- PurchaseId is the idempotency KEY (a stable per-receipt string). Without one we cannot
	-- de-dup a replay -> refuse (NotProcessedYet at runtime) rather than risk a double-grant.
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return Result.err(Result.Codes.BadPayload, "PurchaseId must be a non-empty string")
	end

	-- Unknown / unsold product id: refuse (so Roblox retries later rather than us granting nothing
	-- and consuming the receipt). NotProcessedYet at runtime.
	local product = findProduct(productId)
	if product == nil then
		return Result.err(Result.Codes.OutOfRange, "unknown product id")
	end

	local player = playerRef(userId)

	-- ----- ONE lock-held transform: idempotency check + ledger write + (pack) grant -----
	-- Outcomes captured into locals the transform closes over; the transform mutates `d` ONLY when
	-- the receipt is newly processed, and returns `d` unchanged otherwise (already-processed replay).
	local alreadyProcessed = false
	local grantedAmount = 0
	local outBalance = 0

	local updated = self._data:update(player, function(d)
		-- 1. re-read the ledger from the lock-held snapshot (post any earlier write).
		local receipts = d.receipts
		if receipts == nil then
			receipts = {}
			d.receipts = receipts
		end

		-- 2. REPLAY GUARD: this receipt id was already processed -> grant NOTHING, leave d unchanged.
		if receipts[purchaseId] == true then
			alreadyProcessed = true
			outBalance = (d.currencies ~= nil and d.currencies.Stardust or 0)
			return d
		end

		-- 3. NEWLY processed: record the receipt id AND apply the grant atomically in this one
		--    synchronous transform. Record the id FIRST so the ledger is set on every grant path
		--    (pack credits Stardust here; the boost's in-memory expiry is set by the caller AFTER a
		--    confirmed-new commit — its money-grant is the recorded ledger entry, no currency here).
		receipts[purchaseId] = true

		if product.kind == "stardustPack" then
			-- Server-owned grant size from the catalog (NEVER a client/receipt number). An EARN path:
			-- credit currencies.Stardust AND accrue the SAME amount into the monotonic lifetimeStardust.
			local amount = product.amount or 0
			grantedAmount = amount
			if d.currencies == nil then
				d.currencies = {}
			end
			d.currencies.Stardust = (d.currencies.Stardust or 0) + amount
			-- NIL-SAFE on d.stats: real PlayerData always has stats; a minimal test snapshot may not.
			if d.stats ~= nil then
				d.stats.lifetimeStardust = (d.stats.lifetimeStardust or 0) + amount
			end
			outBalance = d.currencies.Stardust
		else
			-- boost2x: no persisted currency grant in the transform; the ledger entry IS the money-grant
			-- record. outBalance reflects the (unchanged) balance for the return shape.
			outBalance = (d.currencies ~= nil and d.currencies.Stardust or 0)
		end

		return d
	end)

	if not updated.ok then
		-- The data write itself failed (NoData / transient). NEVER grant on a failed commit; surface
		-- the Err so the runtime returns NotProcessedYet and Roblox redelivers the receipt later.
		return updated
	end

	-- Replayed receipt: the ledger already had it; nothing was granted this time. Report success
	-- (the purchase WAS honored, on the original delivery) so the runtime returns PurchaseGranted and
	-- Roblox stops redelivering. No grant, no analytics (the original delivery already emitted).
	if alreadyProcessed then
		return Result.ok({
			granted = false,
			alreadyProcessed = true,
			productId = product.productId,
			kind = product.kind,
			amount = 0,
			balance = outBalance,
		})
	end

	-- ----- post-commit effects (only on a CONFIRMED-NEW, committed receipt) -----
	-- The boost's in-memory expiry is set ONLY now, after the ledger commit confirmed the id was newly
	-- recorded, so a replay (which short-circuits at the replay guard above) can never set a 2nd boost.
	if product.kind == "boost2x" then
		local now = self._clock:unix()
		self._boostExpiry[userId] = now + BOOST_DURATION_SECONDS
	end

	-- Every successful purchase emits `purchase` THROUGH ctx.analytics (nil-safe; a no-op in focused
	-- tests / the spine). A Stardust pack ALSO emits currency_earned (it is an earn path) — emitted
	-- here AFTER the committed grant, with the SERVER-owned amount.
	local analytics = self._analytics
	if analytics ~= nil then
		if product.kind == "stardustPack" then
			analytics:emit("currency_earned", {
				userId = userId,
				currency = "Stardust",
				amount = grantedAmount,
				source = "stardust_pack",
			})
		end
		analytics:emit("purchase", {
			userId = userId,
			productId = product.productId,
			kind = product.kind,
			amount = grantedAmount,
			receiptId = purchaseId,
		})
	end

	return Result.ok({
		granted = true,
		alreadyProcessed = false,
		productId = product.productId,
		kind = product.kind,
		amount = grantedAmount,
		balance = outBalance,
	})
end

-- ================================ RUNTIME RECEIPT ADAPTER ========================================
-- Maps a ProcessReceipt Result to Enum.ProductPurchaseDecision, Lune-safely (Enum is a Roblox global,
-- NIL under Lune). PurchaseGranted on a granted OR already-processed receipt (the money was honored
-- exactly once); NotProcessedYet on ANY failure, so Roblox redelivers and the purchase is never lost.
-- The string fallbacks under Lune let a spec assert the DECISION without a real Roblox Enum.
function MonetizationService.receiptDecision(self: any, receiptInfo: any): any
	local result = self:ProcessReceipt(receiptInfo)
	local enum: any = Enum :: any
	if result.ok then
		if enum ~= nil and enum.ProductPurchaseDecision ~= nil then
			return enum.ProductPurchaseDecision.PurchaseGranted
		end
		return "PurchaseGranted" -- Lune fallback (no Roblox Enum)
	end
	if enum ~= nil and enum.ProductPurchaseDecision ~= nil then
		return enum.ProductPurchaseDecision.NotProcessedYet
	end
	return "NotProcessedYet" -- Lune fallback
end

-- ================================ START (publish seam + wire callback) ===========================
-- Constructs the runtime service from context, publishes the ctx.monetization seam (so every
-- handler's ActionContext — and the consolidated Sell formula — reads stardustMultiplier from now on),
-- and wires the receipt callback to MarketplaceService. Registers NO client Net.Action.
function MonetizationService:Start(context: any): ()
	-- Build the stateful unit from the injected deps (so the seam can read flags + the clock).
	local service = MonetizationService.new(context.data, context.clock)
	service._analytics = context.analytics -- nil-safe at the emit sites

	-- Publish the seam: ctx.monetization:stardustMultiplier(userId). Same object identity every
	-- ActionContext projects, so the in-memory boost map is shared across all requests.
	context.monetization = service
	self._runtime = service

	-- ROBLOX-ONLY runtime wiring: the receipt callback. Guarded so this Start stays import-safe under
	-- Lune (MarketplaceService is a Roblox-only service). The callback returns an Enum at runtime.
	local realGame: any = game
	if realGame ~= nil and type(realGame.GetService) == "function" then
		local marketplace = realGame:GetService("MarketplaceService")
		marketplace.ProcessReceipt = function(receiptInfo: any): any
			return service:receiptDecision(receiptInfo)
		end
	end
end

return MonetizationService
