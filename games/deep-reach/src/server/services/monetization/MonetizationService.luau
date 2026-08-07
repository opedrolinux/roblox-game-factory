--!strict
-- games/deep-reach/src/server/services/monetization/MonetizationService.luau   [feature: monetization]
--
-- THE authoritative owner of everything a player pays REAL MONEY for: the three gamepass grants, the
-- dev-product receipt handler, and the persisted 30-minute 2x boost. Replaces the contract-pass stub
-- in place and preserves the ONE decision that stub existed to pin: THIS SERVICE REGISTERS NO NET
-- ACTION AT ALL (contract.stubs.monetization declares `actions: []`).
--
-- ── WHY THERE IS NO ACTION, AND WHY THAT IS THE SECURITY POSTURE ────────────────────────────────
-- A client-settable gamepass flag IS a free gamepass. Every grant on this path is decided by an
-- authority OUTSIDE the client: `MarketplaceService:UserOwnsGamePassAsync` (Roblox's answer, asked by
-- the server), `PromptGamePassPurchaseFinished` (a server-side signal that fires after Roblox has
-- taken the money) and `ProcessReceipt` (a server callback Roblox invokes with a receipt IT minted).
-- Nothing here crosses the gateway, so there is no payload to validate and no rate policy to set —
-- the CLAUDE.md §3 validate-type+range+ownership+rate rule is satisfied by there being no inbound
-- client request at all, which is strictly stronger than validating one. The client's only role is to
-- ASK Roblox to show a purchase prompt (see MonetizationController), and that request goes to Roblox,
-- never to us.
--
-- ── WHAT THIS SLICE OWNS ────────────────────────────────────────────────────────────────────────
--  1. THE THREE GAMEPASS FLAGS, granted SERVER-SIDE ONLY into the persisted `flags` map:
--        flags["gamepass.doubleCredits"] · flags["gamepass.autoCollect"] · flags["gamepass.vipTrench"]
--     checked on join (UserOwnsGamePassAsync, pcall'd + retried) and on a fresh purchase
--     (PromptGamePassPurchaseFinished). A FAILED CHECK NEVER CLEARS A GRANTED FLAG — the only write
--     this service ever makes to a flag is false -> true. See `grantPass`.
--  2. THE DEV PRODUCTS, IDEMPOTENTLY: Credit packs S/M/L (granted through ctx.economy:earn, which is
--     what moves stats.lifetimeCredits and emits currency_earned) and the 30-min 2x boost
--     (`boostExpiresUnix = max(now, current expiry) + 1800`, so a stacked purchase EXTENDS rather
--     than being silently swallowed). The receipt id is stamped into the `receipts` ledger IN THE
--     SAME ctx.data:update as the grant.
--  3. THE REAL-MONEY GUARDS: `ctx.persistenceDegraded` (the in-memory fallback store — a successful
--     save there is NOT durability) and the durable-write confirmation below. Neither one
--     acknowledges a receipt it cannot prove survived.
--
-- NOT THIS SLICE, and deliberately so: the income rate (SalvageService READS
-- flags["gamepass.doubleCredits"] and `now < boostExpiresUnix` straight off the blob), the smelter
-- tick's auto-collect path (SalvageService reads flags["gamepass.autoCollect"] and runs its ONE shared
-- grant function — AMENDMENT A2: this file must NOT write a second collect path), and the exclusive
-- depth tier (DepthService reads flags["gamepass.vipTrench"] and returns Err(PrereqUnmet) without it).
-- Every one of those readers already exists; a flag granted here lands with ZERO edit to those files,
-- which is also why a flag granted under the WRONG KEY is a purchase that does nothing. The keys below
-- are string literals rather than a sibling require (a service never sibling-requires another
-- service), and each one names its reader.
--
-- ── THE CONCURRENCY / IDEMPOTENCY ARGUMENT (CLAUDE.md §4, §5) ────────────────────────────────────
-- The exploit this file is one mistake away from is the receipt replay: read `receipts[id]`, YIELD,
-- then grant and stamp. Two deliveries of the SAME receipt both observe "not processed" before either
-- writes, and Roblox pays once while the player is credited twice. THREE mechanisms close it:
--
--   (1) THE LEDGER CHECK, THE STAMP AND THE GRANT ARE ONE LOCK-HELD TRANSFORM. Nothing outside the
--       transform reads or writes `receipts`, `currencies` or `boostExpiresUnix` on this path.
--       DataService:update runs the transform under the per-player FIFO lock against a snapshot
--       RE-READ after any earlier update committed, and the transform is SYNCHRONOUS — it contains no
--       yield of any kind. So the second delivery's transform necessarily observes `receipts[id] ==
--       true` and grants NOTHING. This is the load-bearing guarantee; it holds even if (2) is deleted.
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION per receipt id, taken BEFORE the update can yield
--       (`self._processing`). Luau is single-threaded, so the reservation is visible to every
--       interleaved delivery the instant it is set. A duplicate that arrives while the first is parked
--       in the store is answered NotProcessedYet — never PurchaseGranted, because at that moment we
--       cannot yet prove the first one committed, and acknowledging an uncommitted grant is how real
--       money is lost. Roblox re-delivers, and the retry finds the durable ledger entry.
--   (3) THE STAMP IS ROLLED BACK ON A REFUSED GRANT, in the same transform, so a receipt whose grant
--       failed is not left marked processed (which would burn the purchase permanently). The earn-side
--       state is restored with it: EconomyService is atomic-or-nothing as of the current commit, but
--       this transaction is made atomic HERE rather than assumed atomic there.
--
-- ── AND THE OTHER HALF OF "NEVER LOST": DURABILITY BEFORE ACKNOWLEDGEMENT ────────────────────────
-- `ctx.data:update` commits to the SESSION, in memory; the durable write is `ctx.data:save`. Roblox
-- never re-delivers a receipt that was answered PurchaseGranted, so acknowledging before the write is
-- durable means a server crash in the next 60 seconds (the autosave cadence) destroys a purchase that
-- can never be recovered. So a fresh grant is followed by a forced save, and the acknowledgement is
-- CONDITIONAL on it. A replay whose grant is still un-durable on THIS server (`self._pendingDurable`)
-- is answered NotProcessedYet too, for exactly the same reason.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- The engine surfaces (MarketplaceService, ProcessReceipt, PromptGamePassPurchaseFinished) DO NOT
-- EXIST UNDER LUNE, so every decision in this file is Roblox-FREE and the engine is reached only
-- through guarded locals: `processReceipt` / `grantPass` / `syncPasses` / `onPromptFinished` /
-- `productForId` / `passForGamePassId` / `boostExpiryAt` all run under Lune with Mocks.player, a real
-- DataService over MockStore and no engine at all. Ownership is probed through the injectable
-- `self._ownsPass` test seam (nil in production, where it is MarketplaceService). Only `startRuntime`
-- and `_engineOwnsPass` touch `game` / `task` / `Enum`.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT Rojo service root
-- than this ServerScriptService module — so the relative string cannot reach it there; require by
-- instance. Under Lune (script == nil) the filesystem path resolves.
local Result, Types
if script == nil then
	Result = require("../../../shared/Result")
	Types = require("../../../shared/Types")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Result = require((Shared :: any).Result)
	Types = require((Shared :: any).Types)
end

local MonetizationService = {}
MonetizationService.name = "MonetizationService"

-- ── the two decisions Roblox understands ────────────────────────────────────────────────────────
-- Kept as STRINGS in the pure core and mapped to `Enum.ProductPurchaseDecision` only in the engine
-- wrapper: `Enum` is nil under Lune, so a core that returned the enum directly could not be tested at
-- all — and an untestable receipt handler is the definition of a feature with no gate.
MonetizationService.GRANTED = "PurchaseGranted"
MonetizationService.NOT_PROCESSED = "NotProcessedYet"

-- ── tunables (SERVER constants; no client number reaches any of them) ───────────────────────────

-- The 2x boost's length, verbatim from the spec ("a 30-min 2x boost").
local BOOST_SECONDS = 1800
MonetizationService.BOOST_SECONDS = BOOST_SECONDS

-- The currency the Credit packs grant, and the only currency this file names. Written ONLY through
-- ctx.economy:earn, which owns stats.lifetimeCredits and the currency_earned emit.
local EARN_CURRENCY = "Credits"

-- How many times an ownership probe is retried before this join gives up. UserOwnsGamePassAsync is a
-- web call: it can throw, it can time out, and a transient failure must cost the player nothing — so
-- it is retried within a bounded budget and, on exhaustion, NOTHING is written (never a clear).
local PASS_CHECK_ATTEMPTS = 3
local PASS_CHECK_STEP_SECONDS = 1
MonetizationService.PASS_CHECK_ATTEMPTS = PASS_CHECK_ATTEMPTS

-- The bounded wait for this player's session at join, same budget and shape as SalvageService's join
-- wait, for the same reason: DataService.loadSession YIELDS, and a grant issued before it resolves
-- reads Err(NoData) and grants nothing — a paid-for gamepass that does not apply until the next join.
MonetizationService.loadWaitAttempts = 200
MonetizationService.loadWaitStepSeconds = 0.25

-- ── THE THREE GAMEPASSES ────────────────────────────────────────────────────────────────────────
-- `flag` is the PERSISTED key each effect's reader looks at, quoted verbatim from that reader. Get one
-- of these strings wrong and the purchase is inert: it persists, it replicates, and no rule changes.
--   gamepass.doubleCredits -> SalvageService.multiplierAt (x2 on the running rate)
--   gamepass.autoCollect   -> SalvageService.tickPlayer   (the tick empties the smelter, ONE grant path)
--   gamepass.vipTrench     -> DepthService.descend        (the exclusive tier; Err(PrereqUnmet) without)
--
-- `gamePassId` is 0 = NOT CONFIGURED YET, and that is deliberate rather than a placeholder left
-- behind: a gamepass id only exists once a human has created the pass on a PUBLISHED place, which is
-- outside this factory's autonomy fence. An id of 0 means the ownership probe is SKIPPED entirely —
-- never asked, never granted, never cleared — so an unpublished game behaves as "nobody owns it"
-- rather than fabricating an asset id and asking Roblox about somebody else's product.
-- TODO(verify): fill these three ids from the published place's gamepasses (and the four product ids
-- below from its developer products) before the monetization surface can take money.
export type PassEntry = {
	key: string,
	flag: string,
	label: string,
	gamePassId: number,
}

MonetizationService.PASSES = {
	{
		key = "doubleCredits",
		flag = "gamepass.doubleCredits",
		label = "2x Credits",
		gamePassId = 0,
	},
	{
		key = "autoCollect",
		flag = "gamepass.autoCollect",
		label = "Auto-Collect",
		gamePassId = 0,
	},
	{
		key = "vipTrench",
		flag = "gamepass.vipTrench",
		label = "VIP Trench",
		gamePassId = 0,
	},
} :: { PassEntry }

-- ── THE DEV PRODUCTS ────────────────────────────────────────────────────────────────────────────
-- Held as an ARRAY of records rather than a `local CATALOG` map, because this is not a shop catalog:
-- there is no key the client may name, no price curve, and no in-game currency involved. The only
-- thing that selects an entry is a numeric ProductId that Roblox put on a receipt.
--
-- `amount` is the SERVER's number and the only source of it. No client value, and nothing off the
-- receipt, ever reaches the grant: `receiptInfo.CurrencySpent` is Robux the player paid, not Credits
-- they bought, and treating it as an amount would let the Robux price silently re-tune the economy.
export type ProductEntry = {
	key: string,
	kind: string, -- "credits" | "boost"
	label: string,
	amount: number, -- Credits granted (kind == "credits"); 0 otherwise
	seconds: number, -- boost seconds granted (kind == "boost"); 0 otherwise
	developerProductId: number, -- 0 = not configured (see the note on gamePassId above)
}

MonetizationService.PRODUCTS = {
	{
		key = "creditPackS",
		kind = "credits",
		label = "Small Credit Pack",
		amount = 5000,
		seconds = 0,
		developerProductId = 0,
	},
	{
		key = "creditPackM",
		kind = "credits",
		label = "Medium Credit Pack",
		amount = 30000,
		seconds = 0,
		developerProductId = 0,
	},
	{
		key = "creditPackL",
		kind = "credits",
		label = "Large Credit Pack",
		amount = 150000,
		seconds = 0,
		developerProductId = 0,
	},
	{
		key = "boost30",
		kind = "boost",
		label = "30-min 2x Boost",
		amount = 0,
		seconds = BOOST_SECONDS,
		developerProductId = 0,
	},
} :: { ProductEntry }

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

-- The ServerContext, captured at Start (the receipt callback and the prompt signal are handed no ctx).
MonetizationService._context = nil :: any
-- receipt id -> true while that receipt's update is parked inside ctx.data:update (mechanism (2)).
MonetizationService._processing = {} :: { [string]: boolean }
-- receipt id -> THE PENDING `purchase` PAYLOAD for a grant that COMMITTED to the session on this
-- server but whose durable write has not yet succeeded. A replay of one of these is answered
-- NotProcessedYet: the money is not safe yet, and Roblox re-delivering is the only thing that can
-- still rescue it. The payload is held rather than a bare `true` because THE ACKNOWLEDGEMENT, NOT THE
-- GRANTING CALL, IS THE EMIT POINT: a grant whose durable write fails is ultimately acknowledged by a
-- LATER delivery down the replay branch, and that delivery must emit the `purchase` the granting call
-- could not (it returned NotProcessedYet before reaching it). Without this, a receipt granted on the
-- durability path fires zero `purchase` events for its entire lifetime while ctx.economy:earn's
-- currency_earned has already fired — an analytics stream internally inconsistent about a payment.
MonetizationService._pendingDurable = {} :: { [string]: any }
-- TEST SEAM: `(userId: number, gamePassId: number) -> boolean`. nil in production, where ownership is
-- MarketplaceService:UserOwnsGamePassAsync. A spec has no engine and must still drive the grant path.
MonetizationService._ownsPass = nil :: ((number, number) -> boolean)?
MonetizationService._running = false
MonetizationService._connections = {} :: { any }

-- ── helpers (pure) ──────────────────────────────────────────────────────────────────────────────

local function isUsableNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6). Identity is
-- taken from the FIELD, which both a live Player and Mocks.player answer.
local function userIdOf(player: any): number?
	if player == nil then
		return nil
	end
	local userId = (player :: any).UserId
	if not isUsableNumber(userId) then
		return nil
	end
	return math.floor(userId)
end

local function sanitizeNow(value: any): number?
	if not isUsableNumber(value) then
		return nil
	end
	return math.floor(value)
end

-- The `flags` map, NORMALIZED IN PLACE. Call only inside a transform: repairing a garbage record
-- outside one would be an unlocked write on the single-writer path (CLAUDE.md §4).
local function flagsOf(data: any): { [string]: boolean }
	if type(data.flags) ~= "table" then
		data.flags = {}
	end
	return data.flags
end

-- The `receipts` idempotency ledger, NORMALIZED IN PLACE. Same rule as flagsOf. Note this table is
-- DELIBERATELY stripped from PlayerView (Types.luau:76): it is server bookkeeping, and replicating it
-- would hand the client the exact ids a replay attempt would need to guess.
local function receiptsOf(data: any): { [string]: boolean }
	if type(data.receipts) ~= "table" then
		data.receipts = {}
	end
	return data.receipts
end

-- The earn-side state of a snapshot, READ without touching it, so a refused grant can be rolled back
-- to exactly what this transform found. nil is a legitimate captured value (an absent key), and
-- restoring nil restores absence.
local function earnStateOf(data: any): (any, any)
	local balance: any = nil
	local lifetime: any = nil
	if type(data.currencies) == "table" then
		balance = data.currencies[EARN_CURRENCY]
	end
	if type(data.stats) == "table" then
		lifetime = data.stats.lifetimeCredits
	end
	return balance, lifetime
end

-- The UNDO of a refused earn. Only ever writes values captured off THIS snapshot moments earlier, and
-- only when they actually moved — it can restore a balance, never invent one.
local function restoreEarnState(data: any, balance: any, lifetime: any): ()
	if type(data.currencies) == "table" and data.currencies[EARN_CURRENCY] ~= balance then
		data.currencies[EARN_CURRENCY] = balance
	end
	if type(data.stats) == "table" and data.stats.lifetimeCredits ~= lifetime then
		data.stats.lifetimeCredits = lifetime
	end
end

-- ── catalog lookups (pure) ──────────────────────────────────────────────────────────────────────

function MonetizationService.passFor(_self: any, key: string): PassEntry?
	for _, entry in MonetizationService.PASSES do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

-- An UNCONFIGURED id (0) matches NOTHING. Without that guard every unrecognised gamepass id in the
-- universe would resolve to the first pass whose id we never filled in.
function MonetizationService.passForGamePassId(_self: any, gamePassId: any): PassEntry?
	if not isUsableNumber(gamePassId) then
		return nil
	end
	local id = math.floor(gamePassId)
	if id <= 0 then
		return nil
	end
	for _, entry in MonetizationService.PASSES do
		if entry.gamePassId == id then
			return entry
		end
	end
	return nil
end

function MonetizationService.productFor(_self: any, key: string): ProductEntry?
	for _, entry in MonetizationService.PRODUCTS do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

-- Same unconfigured-id rule as passForGamePassId, and here it is load-bearing for REAL MONEY: an
-- unknown ProductId must resolve to nil so the receipt is answered NotProcessedYet and Roblox
-- re-delivers it to a server that knows what it is — never granted as "probably the first pack".
function MonetizationService.productForId(_self: any, productId: any): ProductEntry?
	if not isUsableNumber(productId) then
		return nil
	end
	local id = math.floor(productId)
	if id <= 0 then
		return nil
	end
	for _, entry in MonetizationService.PRODUCTS do
		if entry.developerProductId == id then
			return entry
		end
	end
	return nil
end

-- Point a catalog entry at its real asset id. The ONLY writer of these ids other than a human editing
-- the table above; exists so a Tier-1 spec can drive the whole receipt path without a published place.
function MonetizationService.setProductId(self: any, key: string, id: number): boolean
	local entry = self:productFor(key)
	if entry == nil or not isUsableNumber(id) then
		return false
	end
	entry.developerProductId = math.floor(id)
	return true
end

function MonetizationService.setGamePassId(self: any, key: string, id: number): boolean
	local entry = self:passFor(key)
	if entry == nil or not isUsableNumber(id) then
		return false
	end
	entry.gamePassId = math.floor(id)
	return true
end

-- THE receipt's identity. `PurchaseId` is the id Roblox guarantees is unique per PURCHASE (ProductId
-- identifies the product and repeats on every sale of it — keying the ledger on that would grant a
-- Credit pack exactly once per player, forever). Coerced to a string because the ledger is
-- `{[string]: boolean}` and a DataStore round-trip does not promise to preserve a numeric key's type.
function MonetizationService.receiptKeyOf(_self: any, receiptInfo: any): string?
	if type(receiptInfo) ~= "table" then
		return nil
	end
	local purchaseId = receiptInfo.PurchaseId
	if type(purchaseId) == "number" then
		if not isUsableNumber(purchaseId) then
			return nil
		end
		return tostring(purchaseId)
	end
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return nil
	end
	return purchaseId
end

-- THE BOOST EXTENSION RULE, isolated so it is assertable on its own: extend from the LATER of now and
-- the current expiry. Extending from `now` alone would silently swallow the remainder of a boost the
-- player already paid for; extending from the expiry alone would back-date a long-expired one.
-- A garbage persisted expiry (nil / NaN / infinite / negative) reads as "none".
function MonetizationService.boostExpiryAt(
	_self: any,
	data: any,
	nowUnix: number,
	seconds: number
): number
	local current = 0
	if
		type(data) == "table"
		and isUsableNumber(data.boostExpiresUnix)
		and data.boostExpiresUnix > 0
	then
		current = data.boostExpiresUnix
	end
	return math.max(nowUnix, current) + seconds
end

-- ── analytics + view push (both nil-safe; neither may ever undo a committed grant) ───────────────

-- Nil-safe analytics emit (ctx.analytics:emit(event, payload)). NEVER emits currency_earned — that is
-- ctx.economy:earn's, and emitting it here too would double-count every Credit pack.
function MonetizationService.emit(_self: any, context: any, event: string, payload: any): boolean
	local analytics = if context ~= nil then context.analytics else nil
	if analytics == nil or type(analytics.emit) ~= "function" then
		return false
	end
	local ok = pcall(function()
		analytics:emit(event, payload)
	end)
	return ok
end

-- Push the refreshed client view after a committed grant. Guarded and pcall'd, its result discarded:
-- an unguarded post-write push is how a committed economy write once came back to the client as
-- Err(Internal) (docs/LEARNINGS.md), and here it would turn paid-for Credits into NotProcessedYet.
function MonetizationService.pushView(_self: any, context: any, player: any): boolean
	if context == nil or context.data == nil then
		return false
	end
	local net = context.net
	if net == nil or type(net.fireClient) ~= "function" then
		return false
	end
	local got = context.data:get(player)
	if type(got) ~= "table" or got.ok ~= true then
		return false
	end
	local ok = pcall(function()
		net:fireClient(player, "data", Types.toView(got.value))
	end)
	return ok
end

-- ── GAMEPASS GRANTS ─────────────────────────────────────────────────────────────────────────────

export type PassGrant = {
	key: string,
	flag: string,
	owned: boolean, -- true once the flag is set (whether or not THIS call set it)
	granted: boolean, -- true ONLY on a false -> true transition
}

-- Set one gamepass flag, idempotently, inside ONE lock-held transform.
--
-- THE ONLY WRITE THIS FUNCTION CAN MAKE IS false -> true. There is deliberately no "revoke" branch:
-- a `false` from a web call is indistinguishable at this layer from a call that failed in a way the
-- pcall did not surface, and the cost of the two mistakes is wildly asymmetric — wrongly keeping a
-- pass costs Roblox nothing, wrongly clearing one takes away something a player paid real money for.
--
-- `purchase` is emitted ONLY on the transition, and only AFTER the write commits, so a re-check that
-- finds the pass already granted (every join, forever) emits nothing.
function MonetizationService.grantPass(self: any, context: any, player: any, passKey: string): any
	if context == nil or context.data == nil then
		return Result.err(Result.Codes.Internal, "monetization: context is missing data")
	end
	local entry = self:passFor(passKey)
	if entry == nil then
		return Result.err(
			Result.Codes.BadType,
			`monetization: unknown gamepass key "{tostring(passKey)}"`
		)
	end
	local pass = entry :: PassEntry
	if userIdOf(player) == nil then
		return Result.err(Result.Codes.BadType, "monetization: player has no numeric UserId")
	end

	local transition = false
	local function transform(data: any): any
		if type(data) ~= "table" then
			return data
		end
		local flags = flagsOf(data)
		if flags[pass.flag] ~= true then
			flags[pass.flag] = true
			transition = true
		end
		return data
	end

	local ok, written = pcall(function(): any
		return context.data:update(player, transform)
	end)
	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "monetization: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded), LockStolen, or a transform that threw. The snapshot was
		-- discarded, so NOTHING was written — surfaced as-is rather than dressed up as a grant. The
		-- next join re-probes ownership and grants then; nothing is lost.
		return written
	end

	if transition then
		-- AFTER the commit, and only on the transition. A gamepass flag lost to a crash before the
		-- next autosave is re-granted by the very next join's ownership probe, which is why this path
		-- does not force a durable write the way a receipt does.
		self:emit(context, "purchase", {
			userId = userIdOf(player),
			kind = "gamepass",
			key = pass.key,
			flag = pass.flag,
			label = pass.label,
			gamePassId = pass.gamePassId,
		})
		self:pushView(context, player)
	end

	return Result.ok({
		key = pass.key,
		flag = pass.flag,
		owned = true,
		granted = transition,
	} :: PassGrant)
end

-- ONE ownership probe. Returns (probed, owned): `probed = false` means we could not get an answer at
-- all, which is NOT the same as "does not own it" and must never be written anywhere.
function MonetizationService.ownsPass(
	self: any,
	userId: number,
	gamePassId: number
): (boolean, boolean)
	local provider = self._ownsPass
	if type(provider) == "function" then
		local ok, owned = pcall(provider, userId, gamePassId)
		if not ok then
			return false, false
		end
		return true, owned == true
	end
	return self:_engineOwnsPass(userId, gamePassId)
end

-- ROBLOX-ONLY. `game` is a real global in Roblox and NIL under Lune, so it is reached through a
-- guarded local: under Lune this reports "could not probe", which writes nothing.
function MonetizationService._engineOwnsPass(
	_self: any,
	userId: number,
	gamePassId: number
): (boolean, boolean)
	local realGame: any = game
	if realGame == nil then
		return false, false
	end
	local ok, owned = pcall(function(): any
		return realGame:GetService("MarketplaceService"):UserOwnsGamePassAsync(userId, gamePassId)
	end)
	if not ok then
		return false, false
	end
	return true, owned == true
end

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable. A spec replaces it to drive the retry budget without sleeping.
function MonetizationService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- Probe with the bounded retry budget. A throw or a timeout is retried; an authoritative `false` is
-- NOT (it is an answer, and re-asking would only slow every join down for the majority who own
-- nothing). Returns (probed, owned) with the same meaning as ownsPass.
function MonetizationService.probeOwnership(
	self: any,
	userId: number,
	gamePassId: number
): (boolean, boolean)
	for attempt = 1, PASS_CHECK_ATTEMPTS do
		local probed, owned = self:ownsPass(userId, gamePassId)
		if probed then
			return true, owned
		end
		if attempt < PASS_CHECK_ATTEMPTS then
			self:_wait(PASS_CHECK_STEP_SECONDS)
		end
	end
	return false, false
end

export type PassSync = {
	checked: number, -- passes with a configured id that we actually asked about
	skipped: number, -- passes whose id is still 0 (unpublished): never asked, never written
	failed: number, -- probes that never got an answer: NOTHING was written for these
	owned: number,
	granted: number, -- false -> true transitions this pass made
}

-- THE JOIN CHECK: ask Roblox about each configured pass and grant what it says the player owns.
-- Roblox-free (the engine is behind ownsPass); a spec injects `_ownsPass` and drives this directly.
function MonetizationService.syncPasses(self: any, context: any, player: any): any
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "monetization: player has no numeric UserId")
	end
	local summary: PassSync = { checked = 0, skipped = 0, failed = 0, owned = 0, granted = 0 }

	for _, entry in MonetizationService.PASSES do
		if entry.gamePassId <= 0 then
			-- Unpublished: not an error and not a refusal, just nothing to ask. See the TODO(verify)
			-- on PASSES.
			summary.skipped += 1
		else
			summary.checked += 1
			local probed, owned = self:probeOwnership(userId, entry.gamePassId)
			if not probed then
				summary.failed += 1
			elseif owned then
				summary.owned += 1
				local granted = self:grantPass(context, player, entry.key)
				if granted.ok and granted.value.granted == true then
					summary.granted += 1
				end
			end
		end
	end

	return Result.ok(summary)
end

-- THE FRESH-PURCHASE PATH: MarketplaceService.PromptGamePassPurchaseFinished. `wasPurchased` is
-- Roblox's word, delivered to the SERVER — the client never says it. A `false` (the player closed the
-- prompt) writes nothing at all.
function MonetizationService.onPromptFinished(
	self: any,
	context: any,
	player: any,
	gamePassId: any,
	wasPurchased: any
): any
	if wasPurchased ~= true then
		return Result.err(
			Result.Codes.Rejected,
			"monetization: the purchase prompt was not completed"
		)
	end
	local entry = self:passForGamePassId(gamePassId)
	if entry == nil then
		-- A pass this game does not sell (or one whose id is still unconfigured). Nothing to grant,
		-- and inventing a grant from an id we do not recognise is how a free gamepass happens.
		return Result.err(
			Result.Codes.BadType,
			`monetization: unknown gamePassId {tostring(gamePassId)}`
		)
	end
	return self:grantPass(context, player, (entry :: PassEntry).key)
end

-- ── DEV PRODUCTS: THE RECEIPT HANDLER ───────────────────────────────────────────────────────────

export type ReceiptOutcome = {
	decision: string, -- MonetizationService.GRANTED | .NOT_PROCESSED
	granted: boolean, -- true only when THIS call applied the grant
	replay: boolean, -- true when the ledger already held this receipt id
	reason: string?, -- why it was not processed (diagnostics only; never shown to a client)
	key: string?,
	amount: number?, -- Credits granted (credit packs)
	balance: number?,
	lifetimeCredits: number?,
	boostExpiresUnix: number?,
	boostSecondsRemaining: number?,
	extended: boolean?, -- true when a live boost was EXTENDED rather than started fresh
}

local function notProcessed(reason: string): ReceiptOutcome
	return {
		decision = MonetizationService.NOT_PROCESSED,
		granted = false,
		replay = false,
		reason = reason,
	}
end

-- Force the durable write and report whether it landed. See the DURABILITY note in the header: this
-- is what makes a PurchaseGranted mean "this survived", and it is the difference between a crash
-- costing a player nothing and costing them a purchase Roblox will never re-deliver.
function MonetizationService.flush(_self: any, context: any, player: any): boolean
	local data = context.data
	if data == nil or type(data.save) ~= "function" then
		-- A data layer with no save (a reduced harness) cannot be asked to prove durability, and
		-- refusing every receipt there would be a false red rather than a safety property.
		return true
	end
	local ok, saved = pcall(function(): any
		return data:save(player)
	end)
	return ok and type(saved) == "table" and saved.ok == true
end

-- THE receipt handler, in full. Returns a ReceiptOutcome whose `.decision` the engine wrapper maps to
-- Enum.ProductPurchaseDecision. EVERY failure — a bad receipt, an unknown product, a degraded store, a
-- refused write, a failed durable save — returns NotProcessedYet, so Roblox re-delivers rather than
-- consuming the purchase (CLAUDE.md §5).
function MonetizationService.processReceipt(
	self: any,
	context: any,
	player: any,
	receiptInfo: any
): ReceiptOutcome
	if context == nil or context.data == nil or context.clock == nil then
		return notProcessed("context")
	end

	-- THE REAL-MONEY GUARD, FIRST, before anything can even look like progress. `persistenceDegraded`
	-- means this server fell back to the in-memory MockStore: a successful save() there is NOT
	-- durability, and acknowledging here would take the money and lose the grant with no way back —
	-- Roblox never re-delivers an acknowledged receipt. Refusing hands it to a healthy server instead.
	if context.persistenceDegraded == true then
		return notProcessed("persistence-degraded")
	end

	local key = self:receiptKeyOf(receiptInfo)
	if key == nil then
		return notProcessed("bad-receipt-id")
	end
	local receiptKey = key :: string

	local entry = self:productForId(receiptInfo.ProductId)
	if entry == nil then
		return notProcessed("unknown-product")
	end
	local product = entry :: ProductEntry

	local userId = userIdOf(player)
	if userId == nil then
		return notProcessed("no-player")
	end
	-- The receipt names its own buyer, and the check is UNCONDITIONAL. A receipt whose PlayerId is
	-- absent or unusable as an identity (a string, NaN, an infinity) names NOBODY, so there is nothing
	-- to check the caller's player against — and skipping the check there would credit whichever player
	-- the caller happened to resolve. Refuse rather than guess: an unattributable receipt is answered
	-- NotProcessedYet and Roblox re-delivers it with the buyer it minted it for.
	if not isUsableNumber(receiptInfo.PlayerId) then
		return notProcessed("no-buyer")
	end
	-- If the caller resolved a DIFFERENT player, granting would credit the wrong account.
	if math.floor(receiptInfo.PlayerId) ~= userId then
		return notProcessed("player-mismatch")
	end

	local now = sanitizeNow(context.clock:unix())
	if now == nil then
		return notProcessed("no-clock")
	end
	local nowUnix = now :: number

	local economy = context.economy
	if product.kind == "credits" and (economy == nil or type(economy.earn) ~= "function") then
		-- ctx.economy is the ENFORCEMENT POINT for "lifetime on all earns". Granting around it would
		-- leave stats.lifetimeCredits unmoved and currency_earned unemitted, so an absent seam is a
		-- refusal, never a fall-through to a direct write of data.currencies.
		return notProcessed("no-economy")
	end

	-- (2) RESERVE, synchronously, before anything below can yield.
	if self._processing[receiptKey] then
		return notProcessed("in-flight")
	end
	self._processing[receiptKey] = true

	local outcome: any = nil
	-- (1) THE ONE LOCK-HELD TRANSFORM: the ledger check, the stamp and the grant, with no yield
	-- anywhere between them.
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = { status = "error", reason = "bad-blob" }
			return data
		end
		local receipts = receiptsOf(data)
		if receipts[receiptKey] == true then
			-- ALREADY PROCESSED. Grant NOTHING and say so: the caller acknowledges (once durability
			-- is established), which is what makes a replay a no-op instead of a second payout.
			outcome = { status = "replay" }
			return data
		end

		-- Stamped in the SAME transform as the grant, so the two can never disagree.
		receipts[receiptKey] = true

		if product.kind == "credits" then
			local beforeBalance, beforeLifetime = earnStateOf(data)
			local granted =
				economy:earn(data, EARN_CURRENCY, product.amount, `product.{product.key}`)
			if not granted.ok then
				-- (3) ROLL THE STAMP BACK, and the earn-side state with it. A receipt left marked
				-- processed after a refused grant is a purchase burned forever: every re-delivery
				-- would take the replay branch and acknowledge a grant that never happened.
				receipts[receiptKey] = nil
				restoreEarnState(data, beforeBalance, beforeLifetime)
				outcome =
					{ status = "error", reason = "earn-refused", code = (granted :: any).code }
				return data
			end
			outcome = {
				status = "granted",
				amount = product.amount,
				balance = granted.value.balance,
				lifetimeCredits = granted.value.lifetimeCredits,
			}
			return data
		end

		-- THE BOOST. Persisted, so the expiry survives a crash/rejoin, and EXTENDED from the later of
		-- now and the current expiry so a stacked purchase is never silently swallowed. Nothing else
		-- in the game writes this field: SalvageService only reads `now < data.boostExpiresUnix`, and
		-- ResurfaceService leaves it untouched by AMENDMENT A6.
		local wasActive = isUsableNumber(data.boostExpiresUnix) and data.boostExpiresUnix > nowUnix
		local expires = self:boostExpiryAt(data, nowUnix, product.seconds)
		data.boostExpiresUnix = expires
		outcome = {
			status = "granted",
			boostExpiresUnix = expires,
			boostSecondsRemaining = expires - nowUnix,
			extended = wasActive,
		}
		return data
	end

	-- pcall'd ONLY so the reservation is released on every path: a reservation stranded `true` would
	-- refuse every future delivery of this receipt for the life of the server.
	-- (2b) THE RESERVATION IS HELD ACROSS THE DURABLE HALF, NOT JUST THE TRANSFORM.
	--
	-- It used to be released the instant `context.data:update` returned — one line above a `flush`
	-- that YIELDS for 0.1-10s (ctx.data:save -> saveSession, gated by the per-key
	-- writeMinIntervalSeconds floor and retried with backoff). Roblox does not serialise its
	-- ProcessReceipt re-invocations, so a re-delivery of the SAME PurchaseId landing in that window
	-- walked straight past the cleared reservation, took the replay branch, found `_pendingDurable`
	-- still set, flushed, cleared it and emitted `purchase` — and then the first call resumed and
	-- emitted `purchase` a second time. One payment, two revenue events, and an analytics stream
	-- internally inconsistent with the single currency_earned the one grant produced.
	--
	-- The transform itself was never the problem: mechanism (1) is lock-held and the grant, the
	-- ledger stamp and the balance all move exactly once either way. What was false was this file's
	-- own stated property — "a duplicate that arrives while the first is parked is answered
	-- NotProcessedYet" — which only held for the non-yielding half.
	--
	-- WRAPPED rather than released at each exit: there are nine return paths below, and the original
	-- early release exists precisely because releasing at every one of them is the fragile option. A
	-- stranded `true` would refuse every future delivery of this receipt for the life of the server,
	-- so the pcall guarantees the release happens even if something below throws.
	local okBody, result = pcall(function(): any
		local ok, written = pcall(function(): any
			return context.data:update(player, transform)
		end)

		if not ok then
			return notProcessed("update-threw")
		end
		if type(written) ~= "table" or written.ok == nil then
			return notProcessed("no-result")
		end
		if written.ok ~= true then
			-- NoData / LockStolen / a transform that threw. The snapshot was discarded, so nothing was
			-- stamped and nothing was granted — Roblox re-delivers.
			return notProcessed(`write-{tostring((written :: any).code)}`)
		end
		if outcome == nil then
			return notProcessed("no-outcome")
		end
		if outcome.status == "error" then
			return notProcessed(outcome.reason or "grant-refused")
		end

		if outcome.status == "replay" then
			-- Idempotent acknowledgement — but only once the grant this ledger entry refers to is durable.
			-- A replay of a grant still pending on THIS server is answered NotProcessedYet so Roblox keeps
			-- the receipt alive until the write lands.
			local pending = self._pendingDurable[receiptKey]
			if pending ~= nil then
				if not self:flush(context, player) then
					return notProcessed("awaiting-durability")
				end
				self._pendingDurable[receiptKey] = nil
				-- THIS server is the one that cleared the pending grant, so THIS call is that grant's
				-- FIRST SUCCESSFUL ACKNOWLEDGEMENT — and the acknowledgement is the emit point, not the
				-- flush inside the granting call. The granting call committed the grant, failed its durable
				-- write and returned NotProcessedYet BEFORE it could emit; if this branch stayed silent the
				-- purchase would fire no `purchase` event ever, on any delivery. The payload is the one
				-- captured at grant time (see _pendingDurable), so the numbers reported are the numbers the
				-- grant actually moved. pushView is here for the same reason: the HUD boost timer reads
				-- `boostExpiresUnix` off the replicated view and has no other driver.
				self:emit(context, "purchase", pending)
				self:pushView(context, player)
			end
			return {
				decision = MonetizationService.GRANTED,
				granted = false,
				replay = true,
				key = product.key,
			}
		end

		-- GRANTED. The write is in the session; make it durable before acknowledging. currency_earned was
		-- already emitted by ctx.economy:earn (emitting it here too would double-count every Credit pack);
		-- `purchase` is this feature's event, and it is emitted on the acknowledgement — either the one
		-- below, or, if this durable write fails, the replay branch above on the delivery that recovers it.
		local purchasePayload = {
			userId = userId,
			kind = "product",
			key = product.key,
			label = product.label,
			developerProductId = product.developerProductId,
			receiptId = receiptKey,
			amount = outcome.amount,
			balance = outcome.balance,
			lifetimeCredits = outcome.lifetimeCredits,
			boostExpiresUnix = outcome.boostExpiresUnix,
			boostSecondsRemaining = outcome.boostSecondsRemaining,
			extended = outcome.extended,
		}
		self._pendingDurable[receiptKey] = purchasePayload
		if not self:flush(context, player) then
			return notProcessed("save-failed")
		end
		self._pendingDurable[receiptKey] = nil

		-- AFTER the grant commits AND is durable.
		self:emit(context, "purchase", purchasePayload)
		self:pushView(context, player)

		return {
			decision = MonetizationService.GRANTED,
			granted = true,
			replay = false,
			key = product.key,
			amount = outcome.amount,
			balance = outcome.balance,
			lifetimeCredits = outcome.lifetimeCredits,
			boostExpiresUnix = outcome.boostExpiresUnix,
			boostSecondsRemaining = outcome.boostSecondsRemaining,
			extended = outcome.extended,
		}
	end)
	self._processing[receiptKey] = nil
	if not okBody then
		return notProcessed("handler-threw")
	end
	return result
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: install no seam (contract.stubs.monetization.seamProvided is null — in particular this must
-- NOT assign context.monetization, which is the pre-existing [B2] seam), register no action (see the
-- header), and wire the engine surfaces. Lune-callable: everything engine-shaped lives behind
-- startRuntime, so requiring and Starting this module under Lune never throws.
-- Which catalog entries are still on their placeholder id. An id of 0 matches NOTHING by design
-- (see passForGamePassId / productForId), which is the correct behaviour for an unpublished asset —
-- but it means the entry is INERT: syncPasses skips it, processReceipt answers unknown-product, and
-- the effect it was supposed to gate never turns on.
function MonetizationService.unconfiguredEntries(self: any): { string }
	local out: { string } = {}
	for _, pass in self.PASSES do
		if type(pass.gamePassId) ~= "number" or pass.gamePassId <= 0 then
			table.insert(out, `gamepass.{pass.key}`)
		end
	end
	for _, product in self.PRODUCTS do
		if type(product.developerProductId) ~= "number" or product.developerProductId <= 0 then
			table.insert(out, `product.{product.key}`)
		end
	end
	return out
end

-- THE BOOT AUDIT — the same posture StructuresShopService takes toward an entry whose effect nothing
-- reads. The integration red-team's finding was that EVERY id here is 0 in the shipped catalog, so
-- no gamepass is ever granted, no receipt is ever recognised, and `purchase` — one of the seven
-- events the analytics taxonomy mandates — has no reachable emit point at runtime at all. Worse, it
-- fails SILENTLY and in the shape of success: the passes simply never grant, so the 2x multiplier,
-- auto-collect and the VIP trench are all quietly off, and the Tier-1 suite is green because it
-- stamps real ids into the catalog before every case.
--
-- The ids cannot be invented — they come from a published place, which is a human step. So this does
-- the next best thing and refuses to let it be discovered in production: one loud line at boot,
-- naming exactly what is inert. Never an error: an unpublished place is the correct state during
-- development, and a server that refuses to boot over it would block every non-monetization test.
function MonetizationService.auditCatalog(self: any, warnFn: any): ()
	local unconfigured = self:unconfiguredEntries()
	if #unconfigured == 0 then
		return
	end
	local emit = if type(warnFn) == "function" then warnFn else warn
	emit(
		`[monetization] {#unconfigured} catalog entr{if #unconfigured == 1
			then "y is"
			else "ies are"} UNCONFIGURED (asset id 0) and therefore INERT: {table.concat(
			unconfigured,
			", "
		)}. `
			.. "No gamepass will be granted and no receipt will be recognised for these, so their effects "
			.. "(2x Credits, auto-collect, the VIP trench, Credit packs, the 30-min boost) are OFF and the "
			.. "`purchase` analytics event has no reachable emit point. Fill the ids from the published "
			.. "place — see the TODO(verify) above MonetizationService.PASSES."
	)
end

function MonetizationService.Start(self: any, context: any): ()
	self._context = context
	self._processing = {}
	self._pendingDurable = {}
	self:auditCatalog(context ~= nil and context.logWarn or nil)
	self:startRuntime(context)
end

-- Bounded wait for this player's session, then probe ownership. Same budget and shape as
-- SalvageService's join wait: loadSession YIELDS, and a grant issued before it resolves reads
-- Err(NoData) and grants nothing.
function MonetizationService.syncOnJoin(self: any, context: any, player: any): any
	for attempt = 1, self.loadWaitAttempts do
		local got = context.data:get(player)
		if type(got) == "table" and got.ok == true then
			return self:syncPasses(context, player)
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return Result.err(Result.Codes.NoData, "monetization: session never loaded for this player")
end

-- Map the pure core's decision string onto the enum Roblox actually wants. ROBLOX-ONLY (Enum is nil
-- under Lune). NotProcessedYet is the default on every path, including an unexpected one.
function MonetizationService.decisionEnum(_self: any, decision: string): any
	local enumGlobal: any = Enum
	if enumGlobal == nil then
		return decision
	end
	if decision == MonetizationService.GRANTED then
		return enumGlobal.ProductPurchaseDecision.PurchaseGranted
	end
	return enumGlobal.ProductPurchaseDecision.NotProcessedYet
end

-- ROBLOX-ONLY: the three engine surfaces. Every one of them can throw or yield, so each is entered
-- through a guarded local and the receipt callback is pcall'd end to end — an error escaping
-- ProcessReceipt is answered by Roblox as "not processed", but only if we get that far, and a throw
-- inside our own bookkeeping would otherwise strand the reservation.
function MonetizationService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return -- Lune: no engine to wire. Specs drive processReceipt / syncPasses / grantPass directly.
	end
	if self._running then
		return -- idempotent: a second Start must not install two receipt callbacks
	end
	self._running = true
	self._connections = {}

	local marketplace = realGame:GetService("MarketplaceService")
	local Players = realGame:GetService("Players")

	-- THE RECEIPT CALLBACK. Assigned, not connected: MarketplaceService.ProcessReceipt is a single
	-- function slot, and this is the one place in the game that sets it.
	marketplace.ProcessReceipt = function(receiptInfo: any): any
		local ok, outcome = pcall(function(): any
			local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
			if player == nil then
				-- The buyer left before we could grant. Roblox re-delivers on their next join, which
				-- is exactly what we want — granting to nobody would consume the purchase.
				return notProcessed("player-absent")
			end
			return self:processReceipt(context, player, receiptInfo)
		end)
		if not ok or type(outcome) ~= "table" then
			return self:decisionEnum(MonetizationService.NOT_PROCESSED)
		end
		return self:decisionEnum(outcome.decision)
	end

	-- THE FRESH GAMEPASS PURCHASE. Server-side signal; the client's prompt call is only what makes
	-- Roblox show the dialog.
	table.insert(
		self._connections,
		marketplace.PromptGamePassPurchaseFinished:Connect(
			function(player: any, gamePassId: any, wasPurchased: any)
				self:onPromptFinished(context, player, gamePassId, wasPurchased)
			end
		)
	)

	local function onAdded(player: any): ()
		self:syncOnJoin(context, player)
	end

	-- Players already present (a Studio Play session installs scripts after the local player joins).
	-- Spawned: syncOnJoin yields on both the session wait and the web call, and the bootstrap must not
	-- block on either.
	for _, player in Players:GetPlayers() do
		realTask.spawn(onAdded, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: any)
			realTask.spawn(onAdded, player)
		end)
	)
end

function MonetizationService.Stop(self: any, _context: any): ()
	self._running = false
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
	self._processing = {}
	self._context = nil
end

return MonetizationService
