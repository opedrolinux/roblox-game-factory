--!strict
-- games/deep-reach/src/server/services/economy/EconomyService.luau   [contract pass — infra]
-- THE single Credits/Pearls mutation helper, on the ctx.economy seam. It exists because the
-- cross-cutting economy behaviour has NO owner among the features: the earn sites live in salvage,
-- offline, daily, monetization and resurface, and the spend sites live in structures and depth — so
-- if each builder wrote its own balance write, `stats.lifetimeCredits` would be incremented by some
-- of them and forgotten by the rest. This is the ENFORCEMENT POINT for the contract's rule:
-- "lifetime on all earns, never on spend/reset".
--
-- PURE TRANSFORMS, APPLIED INSIDE ONE ctx.data:update. earn/spend take the blob `data` handed to a
-- DataService transform and MUTATE IT IN PLACE, returning a Result. They never read a balance, yield,
-- and write a stale value back — because they never yield at all. The canonical call shape is:
--
--   local applied
--   local written = ctx.data:update(player, function(d)
--       applied = ctx.economy:spend(d, "Credits", cost, "structure.drones")
--       return d
--   end)
--   if not written.ok then return written end
--   if not applied.ok then return applied end
--
-- Everything — the balance guard, the debit, the lifetime increment and the analytics emit — happens
-- inside that ONE lock-held transform, so a spam-duplicated request cannot double-spend or mint.
--
-- LIFETIME RULE (contract.earnPaths): stats.lifetimeCredits counts CREDITS ONLY. earn BRANCHES on
-- currency, so the Pearls mint on resurface does not touch it; spend NEVER touches it; and a reset
-- (resurface zeroing currencies.Credits) leaves it alone because it never goes through here.
--
-- ANALYTICS: earn emits currency_earned and spend emits currency_spent through ctx.analytics, so a
-- feature builder physically cannot forget the event either. Nil-safe: an unwired seam is a no-op.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT service than this
-- ServerScriptService module — so the relative string cannot reach it there; require by instance.
-- Under Lune (script == nil) the filesystem path resolves.
local Result
if script == nil then
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Result = require((Shared :: any).Result)
end
type Result<T> = Result.Result<T>

local EconomyService = {}
EconomyService.__index = EconomyService
EconomyService.name = "EconomyService"

-- The ONE currency `stats.lifetimeCredits` tracks. Named here rather than at each call site so the
-- branch in earn cannot drift from the leaderboard's ranking key.
EconomyService.LIFETIME_CURRENCY = "Credits"

export type Grant = {
	currency: string,
	amount: number,
	balance: number, -- the post-credit balance
	lifetimeCredits: number, -- the post-increment lifetime total (unchanged for non-Credits)
}

export type Debit = {
	currency: string,
	amount: number,
	balance: number, -- the post-debit balance (never negative)
}

-- CONSTRUCTED in Context.build. `analytics` is the AnalyticsService seam (may be nil — every emit
-- here is nil-safe, so a Tier-1 spec can drive the pure economy math without an emitter).
function EconomyService.new(analytics: any?): any
	local self = setmetatable({}, EconomyService)
	self.name = "EconomyService"
	self._analytics = analytics
	return self
end

-- Guard shared by earn and spend. A non-number, NaN, infinite or non-positive amount is REFUSED
-- rather than clamped: a "negative earn" would be an unguarded debit that skips the balance check,
-- and a NaN written into a balance poisons every later comparison (NaN >= cost is false forever, so
-- the player can never spend again) and persists that way.
local function checkAmount(amount: any): Result<number>
	if type(amount) ~= "number" then
		return Result.err(Result.Codes.BadType, "amount must be a number")
	end
	if amount ~= amount then
		return Result.err(Result.Codes.OutOfRange, "amount must not be NaN")
	end
	if amount == math.huge or amount == -math.huge then
		return Result.err(Result.Codes.OutOfRange, "amount must be finite")
	end
	if amount <= 0 then
		return Result.err(Result.Codes.OutOfRange, "amount must be > 0")
	end
	return Result.ok(amount)
end

local function checkCurrency(currency: any): Result<string>
	if type(currency) ~= "string" or currency == "" then
		return Result.err(Result.Codes.BadType, "currency must be a non-empty string")
	end
	return Result.ok(currency)
end

-- Normalizes the blob's currency map so a missing `currencies` table is a recoverable state rather
-- than a crash inside a lock-held transform (an error thrown there discards the whole write).
local function currenciesOf(data: any): Result<{ [string]: number }>
	if type(data) ~= "table" then
		return Result.err(Result.Codes.Internal, "economy: data blob is not a table")
	end
	if type(data.currencies) ~= "table" then
		return Result.err(Result.Codes.Internal, "economy: data.currencies is missing")
	end
	return Result.ok(data.currencies)
end

-- Read a balance. An absent key reads as 0 — both currency keys ride the OPEN currencies map, so
-- "never seeded" and "spent to zero" are deliberately the same state.
function EconomyService.balanceOf(_self: any, data: any, currency: string): number
	if type(data) ~= "table" or type(data.currencies) ~= "table" then
		return 0
	end
	local value = data.currencies[currency]
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return value
end

-- CREDIT `amount` of `currency` to this blob. Increments stats.lifetimeCredits for Credits ONLY, and
-- emits currency_earned. `source` is the earn path ("smelt" / "offline" / "daily" /
-- "product.creditpack" / "resurface") and is carried on the event, never used for math.
--
-- Mutates `data` in place; call it INSIDE a ctx.data:update transform.
function EconomyService.earn(
	self: any,
	data: any,
	currency: string,
	amount: number,
	source: string
): Result<Grant>
	local currencyChecked = checkCurrency(currency)
	if not currencyChecked.ok then
		return currencyChecked :: any
	end
	local amountChecked = checkAmount(amount)
	if not amountChecked.ok then
		return amountChecked :: any
	end
	local currencies = currenciesOf(data)
	if not currencies.ok then
		return currencies :: any
	end
	local map = (currencies :: any).value

	-- EVERY REFUSAL IS DECIDED BEFORE THE FIRST MUTATION. This check used to sit BELOW the balance
	-- write, which made `earn` non-atomic on exactly one branch: it credited currencies[currency] and
	-- THEN returned Err(Internal) for missing stats. That is the worst possible shape for a seam whose
	-- entire job is to be the one safe way to move a balance — every caller reasonably reads
	-- `if not granted.ok then <undo my side> end` as "nothing happened", and on this branch something
	-- had. The salvage gate caught it as a mint: collect zeroed the smelter, earn credited the balance
	-- and refused, salvage restored the smelter, and the transform committed with the amount in BOTH
	-- places — with stats.lifetimeCredits never moving, so no downstream reader could see it.
	--
	-- Fixed HERE rather than in the caller, because the caller was not wrong. Five features earn
	-- through this seam (salvage, daily, offline, monetization, resurface) and each would have had to
	-- independently discover that a documented atomic-or-nothing helper is not one. Retiring the class
	-- at the seam is the whole reason the contract pass stood this service up.
	if currency == EconomyService.LIFETIME_CURRENCY and type(data.stats) ~= "table" then
		return Result.err(Result.Codes.Internal, "economy: data.stats is missing")
	end

	local before = self:balanceOf(data, currency)
	local balance = before + amount
	map[currency] = balance

	-- THE lifetime rule, in one branch. Pearls (and any future currency) never touch it.
	local lifetimeCredits: number
	if currency == EconomyService.LIFETIME_CURRENCY then
		local current = data.stats.lifetimeCredits
		if type(current) ~= "number" or current ~= current then
			current = 0
		end
		lifetimeCredits = current + amount
		data.stats.lifetimeCredits = lifetimeCredits
	else
		local existing = if type(data.stats) == "table" then data.stats.lifetimeCredits else nil
		lifetimeCredits = if type(existing) == "number" then existing else 0
	end

	local grant: Grant = {
		currency = currency,
		amount = amount,
		balance = balance,
		lifetimeCredits = lifetimeCredits,
	}

	-- Emitted LAST, after the mutation is applied to the snapshot, so an event never describes a
	-- change that was refused. (The residual edge is a LATER statement in the same transform
	-- throwing: the store discards the half-applied snapshot but the emit already stands. Keep the
	-- economy call the last mutation in a transform and that edge cannot arise.)
	self:_emit("currency_earned", {
		currency = currency,
		amount = amount,
		balance = balance,
		lifetimeCredits = lifetimeCredits,
		source = source,
	})

	return Result.ok(grant)
end

-- DEBIT `amount` of `currency` from this blob. Err(Insufficient) when the balance does not cover it
-- — checked BEFORE any write, so a refused spend leaves the blob byte-identical and a balance can
-- never go negative. NEVER touches stats.lifetimeCredits (contract.earnPaths: spend paths must not).
-- `sink` is the spend site ("structure.<key>" / "depth.<tier>"), carried on the event only.
--
-- Mutates `data` in place; call it INSIDE a ctx.data:update transform.
function EconomyService.spend(
	self: any,
	data: any,
	currency: string,
	amount: number,
	sink: string
): Result<Debit>
	local currencyChecked = checkCurrency(currency)
	if not currencyChecked.ok then
		return currencyChecked :: any
	end
	local amountChecked = checkAmount(amount)
	if not amountChecked.ok then
		return amountChecked :: any
	end
	local currencies = currenciesOf(data)
	if not currencies.ok then
		return currencies :: any
	end
	local map = (currencies :: any).value

	local before = self:balanceOf(data, currency)
	if before < amount then
		return Result.err(
			Result.Codes.Insufficient,
			`{currency}: have {before}, need {amount} for {sink}`
		)
	end

	local balance = before - amount
	map[currency] = balance

	local debit: Debit = { currency = currency, amount = amount, balance = balance }

	self:_emit("currency_spent", {
		currency = currency,
		amount = amount,
		balance = balance,
		sink = sink,
	})

	return Result.ok(debit)
end

-- Nil-safe analytics emit. An unwired seam is a no-op, and a throwing emitter must never discard a
-- committed economy write, so the call is pcall-guarded.
function EconomyService._emit(self: any, event: string, payload: any): ()
	local analytics = self._analytics
	if analytics == nil then
		return
	end
	pcall(function()
		analytics:emit(event, payload)
	end)
end

-- Boot-time wiring invariant, same reasoning as AnalyticsService: a seam declared but never assigned
-- is a nil every handler silently falls through. Pure (no Roblox global) so Tier-1 proves the check.
function EconomyService.assertInstalled(self: any, context: any): ()
	if context == nil or context.economy ~= self then
		error(
			"EconomyService:Start — context.economy is not this service. Every ctx.economy:earn/spend "
				.. "in the game would fall through a nil seam, so balances would be written by nobody "
				.. "and stats.lifetimeCredits would never move. Assign it in Context.build."
		)
	end
end

-- Start: this service connects no events and registers no action — it is a pure helper reached
-- through ctx.economy. Start exists so the bootstrap ASSERTS the seam is installed at boot rather
-- than discovering it from a leaderboard stuck at zero. Lune-callable (no Roblox global).
function EconomyService.Start(self: any, context: any): ()
	self:assertInstalled(context)
end

return EconomyService
