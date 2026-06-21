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
--   * boostExpiresUnix : number ....... the 30-min 2x boost's server-unix expiry (0 = none). v5: the
--                                       boost is now PERSISTED (survives crash/rejoin) — STAMPED inside
--                                       the receipt transform, read vs ctx.clock:unix() for the 2x seam.
--   * flags['gamepass.2xStardust' | 'gamepass.autoCollect' | 'gamepass.vipIsland'] : boolean
--                                       gamepass OWNERSHIP. SET by this service's gamepass-grant path
--                                       (syncGamepassesFor on join via UserOwnsGamePassAsync +
--                                       onGamePassPurchased via PromptGamePassPurchaseFinished); READ by
--                                       the 2x / auto-collect / VIP seams. NEVER set from a client action.
-- The service captures `context.data` + `context.clock` in Start so the stardustMultiplier seam (handed
-- only a userId) can read the player's persisted boost + flags + consult the server clock.
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
-- The 30-min boost's expiry is now PERSISTED and STAMPED in the SAME lock-held transform as the ledger
-- write: on a NEWLY-recorded receipt the boost2x branch sets d.boostExpiresUnix atomically with the
-- ledger entry, so the grant and its idempotency commit together. A replay re-reads the ledger and
-- short-circuits BEFORE the boost stamp, so it can never arm a second window.
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
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox (a different service than this
-- ServerScriptService module), so the relative string can't reach it there — require by instance;
-- under Lune (script == nil) the filesystem path resolves.
local Result
if script == nil then
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Result = require((Shared :: any).Result)
end
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

-- ----- GAMEPASS OWNERSHIP CATALOG (gamePassId -> the persisted ownership flag it grants) -----
-- The runtime GRANT path: on join, UserOwnsGamePassAsync is checked for each pass and the owned ones'
-- flags are SET (server-authoritative — never from a client action); PromptGamePassPurchaseFinished
-- sets the flag on a fresh purchase. The flag GATES the effect (2x Sell / auto-collect / VIP island).
-- Placeholder gamePass ids (replaced with the real ids at publish; the LOGIC is keyed by these).
local GAMEPASSES: { { gamePassId: number, flag: string } } = {
	{ gamePassId = 1001, flag = "gamepass.2xStardust" },
	{ gamePassId = 1002, flag = "gamepass.autoCollect" },
	{ gamePassId = 1003, flag = "gamepass.vipIsland" },
}

-- The 30-min 2x boost duration, in seconds (30 * 60). Server-clock measured; persisted as an expiry.
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
	return self
end

-- Minimal Player surrogate so the data layer (which keys sessions by `.UserId`) can be addressed from
-- a bare userId — the seam + the receipt callback receive a userId, not a Player object. Reads only
-- .UserId (the documented constraint). Name is a stable, non-identifying placeholder.
local function playerRef(userId: number): any
	return { UserId = userId, Name = "User_" .. tostring(userId) }
end

-- Whether `userId` currently holds an active (non-expired) 30-min 2x boost. Reads the PERSISTED expiry
-- (v5) from the loaded session snapshot vs the SERVER clock (never client time): expiry strictly in the
-- FUTURE counts as active; an expiry exactly at or before now is lapsed. data:get is a pure snapshot read
-- (the already-loaded session), so a player whose session is not loaded reports no boost (graceful false).
function MonetizationService.hasActiveBoost(self: any, userId: number): boolean
	local got = self._data:get(playerRef(userId))
	if got.ok and got.value ~= nil then
		local expiry = got.value.boostExpiresUnix
		if type(expiry) == "number" then
			return self._clock:unix() < expiry
		end
	end
	return false
end

-- ================================ THE SELL SEAM (consumed by collection Sell) =====================
-- TWO shapes of the SAME rule (2x when the player has an active boost OR owns the 2x gamepass, else 1):
--   * stardustMultiplierFor(d, now): a PURE read over a snapshot `d` + a server `now`. This is the form
--     the consolidated Sell formula calls FROM INSIDE its lock-held transform (like ctx.islands /
--     ctx.restock), so the boost/gamepass are read off the SAME lock-held snapshot the sale commits on
--     — fully atomic, no read-check-write across a yield.
--   * stardustMultiplier(userId): the userId-only convenience form (a data:get snapshot read -> the pure
--     form). Defaults to the identity 1 whenever the player's data is unavailable, so an unloaded player
--     never errors the Sell formula — it just gets the un-multiplied base.
-- PURE form: reads only the snapshot + clock value handed in; no I/O, no self state beyond constants.
function MonetizationService.stardustMultiplierFor(_self: any, d: any, now: number): number
	if d ~= nil then
		-- Active PERSISTED boost is sufficient on its own (it grants 2x even without the gamepass).
		local expiry = d.boostExpiresUnix
		if type(expiry) == "number" and now < expiry then
			return STARDUST_MULTIPLIER_2X
		end
		-- Otherwise consult the PERSISTED gamepass ownership flag (exactly-true; a stray truthy is not it).
		local flags = d.flags
		if flags ~= nil and flags[GAMEPASS_2X_FLAG] == true then
			return STARDUST_MULTIPLIER_2X
		end
	end
	return 1
end

function MonetizationService.stardustMultiplier(self: any, userId: number): number
	local got = self._data:get(playerRef(userId))
	if got.ok and got.value ~= nil then
		return self:stardustMultiplierFor(got.value, self._clock:unix())
	end
	return 1
end

-- ================================ GAMEPASS GRANT PATH (server-authoritative) ======================
-- Owning a gamepass is recorded as a PERSISTED flags[...] boolean. These flags are SET here ONLY — from
-- a server-verified ownership check (UserOwnsGamePassAsync) on join, or the PromptGamePassPurchaseFinished
-- signal on a fresh purchase — and NEVER from a client Net action (no registered action writes flags).

-- Grant a gamepass OWNERSHIP flag through the single-writer lock-held data path. Idempotent: re-setting an
-- already-true flag is a no-op write. Returns the data:update Result (Err if the session is unloaded).
function MonetizationService.grantGamepassFlag(self: any, userId: number, flag: string): Result<any>
	return self._data:update(playerRef(userId), function(d)
		if d.flags == nil then
			d.flags = {}
		end
		d.flags[flag] = true
		return d
	end)
end

-- Sync ALL gamepass ownership flags for a player from the authoritative ownership source. `ownsGamePass`
-- is an INJECTED predicate (userId, gamePassId) -> boolean wrapping MarketplaceService:UserOwnsGamePassAsync
-- at runtime (so this is Tier-1 testable with a fake). Each owned pass sets its flag (idempotent); a pcall
-- guards the ownership lookup so one failure (network/throw) never aborts the rest or errors the join.
function MonetizationService.syncGamepassesFor(
	self: any,
	userId: number,
	ownsGamePass: (number, number) -> boolean
): ()
	for _, gp in GAMEPASSES do
		local ok, owns = pcall(ownsGamePass, userId, gp.gamePassId)
		if ok and owns == true then
			self:grantGamepassFlag(userId, gp.flag)
		end
	end
end

-- Map a freshly-purchased gamePassId to its flag and grant it (the PromptGamePassPurchaseFinished path).
-- Unknown / unsold ids are ignored. Returns true iff a known pass was granted.
function MonetizationService.onGamePassPurchased(
	self: any,
	userId: number,
	gamePassId: number
): boolean
	for _, gp in GAMEPASSES do
		if gp.gamePassId == gamePassId then
			self:grantGamepassFlag(userId, gp.flag)
			return true
		end
	end
	return false
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
	-- Server time captured ONCE for the boost expiry stamp (an input scalar, like the Sell `now`); the
	-- transform closes over it so the persisted expiry is set on the SERVER clock, never client time.
	local now = self._clock:unix()

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
			-- boost2x: no currency is minted, but the boost EXPIRY is now PERSISTED (v5) — STAMP it in
			-- THIS same lock-held transform, atomically with the ledger entry. math.max never shortens an
			-- already-active boost. The ledger entry + this stamp commit together; a replay short-circuits
			-- at the guard above and never reaches here, so no second window is ever armed.
			d.boostExpiresUnix = math.max(d.boostExpiresUnix or 0, now + BOOST_DURATION_SECONDS)
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

	-- (The boost's persisted expiry was STAMPED inside the committed transform above — no post-commit
	-- side effect is needed now; a replay short-circuited at the ledger guard and armed no second window.)

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
	-- ActionContext projects, so every request reads the player's persisted boost/flags through it.
	context.monetization = service
	self._runtime = service

	-- ROBLOX-ONLY runtime wiring. Guarded so this Start stays import-safe under Lune (MarketplaceService
	-- / Players are Roblox-only). UNTESTABLE in Tier-1 (no real MarketplaceService, no real gamepass ids)
	-- — the GRANT/SYNC LOGIC lives in the Tier-1-tested methods above; only the wiring is here.
	local realGame: any = game
	if realGame ~= nil and type(realGame.GetService) == "function" then
		local marketplace = realGame:GetService("MarketplaceService")
		-- (a) the receipt callback (dev products): maps a ProcessReceipt Result to the purchase Enum.
		marketplace.ProcessReceipt = function(receiptInfo: any): any
			return service:receiptDecision(receiptInfo)
		end

		-- (b) the GAMEPASS GRANT path. On join, check ownership of each catalogued pass and SET its flag;
		-- on a fresh purchase, set the bought pass's flag. The ownership lookup yields + may throw, so it
		-- runs off the join thread (task.spawn) and syncGamepassesFor pcall-guards each lookup — a network
		-- failure never blocks the join. NEVER sets a flag from client input (server-verified ownership only).
		local Players = realGame:GetService("Players")
		local function ownsGamePass(userId: number, gamePassId: number): boolean
			return marketplace:UserOwnsGamePassAsync(userId, gamePassId)
		end
		local function syncFor(player: any): ()
			service:syncGamepassesFor(player.UserId, ownsGamePass)
		end
		for _, player in Players:GetPlayers() do
			task.spawn(syncFor, player) -- service may start after players are already present
		end
		Players.PlayerAdded:Connect(function(player: any)
			task.spawn(syncFor, player)
		end)
		marketplace.PromptGamePassPurchaseFinished:Connect(
			function(player: any, gamePassId: number, wasPurchased: boolean)
				if wasPurchased then
					service:onGamePassPurchased(player.UserId, gamePassId)
				end
			end
		)
	end
end

return MonetizationService
