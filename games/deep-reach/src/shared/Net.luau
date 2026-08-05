--!strict
-- core/src/shared/Net.luau
-- The single wire surface: action registry + the ONE pure inbound pipeline (Net.dispatch)
-- that BOTH NetServer (real wire) and Mocks.net (tests) call, so they can never diverge.
-- Lune-clean: its one cross-module require (Result) goes through the D1 `script == nil`
-- require-shim. See docs/CORE-DESIGN.md §3.3.

local Result
if script == nil then
	-- Lune: string path relative to THIS file (cwd-agnostic).
	Result = require("./Result")
else
	-- Roblox runtime: instance require (the dead branch under Lune).
	Result = require((script :: any).Parent.Result)
end

type Result<T> = Result.Result<T>

-- How often a player may invoke an action. Enforced by the spine rate Gate (§3.6) AND the
-- full B2 token bucket; declared on every action now so enforcement needs no Net change.
export type RatePolicy = {
	maxPerWindow: number, -- e.g. 5
	windowSeconds: number, -- e.g. 1.0 (measured on the SERVER MONOTONIC clock — ctx.clock:mono())
	burst: number?, -- optional token-bucket burst; defaults to maxPerWindow
}

-- A validator turns an UNTRUSTED payload into a typed, range-checked value, or an Err.
-- It runs on the server BEFORE the handler. Pure + injectable => Tier-1 testable.
export type Validator<T> = (rawPayload: any) -> Result<T>

-- Structural aliases so this shared module needs no require into server-only code.
-- The concrete server types (Clock, DataService, ...) in §2.3 satisfy these.
export type ClockLike = {
	unix: (self: any) -> number,
	mono: (self: any) -> number,
}
export type DataServiceLike = {
	get: (self: any, player: any) -> Result<any>,
	update: (self: any, player: any, transform: (any) -> any) -> Result<any>,
	save: (self: any, player: any) -> Result<any>,
}
export type PlayerLike = {
	UserId: number,
	Name: string,
}
export type GateLike = {
	check: (self: any, userId: number, actionName: string, policy: RatePolicy) -> Result<true>,
	assertOwner: (self: any, actingUserId: number, ownerUserId: number) -> Result<true>,
}

-- ActionContext is a TYPED, NARROW projection of ServerContext (concern 15): NetServer
-- builds it by closing over the real ServerContext, so the deps are the SAME objects.
-- Deferred seams appear here as the SAME optional fields ServerContext has, so a B2
-- handler reads ctx.monetization / ctx.flags with ZERO Net change.
export type ActionContext = {
	player: PlayerLike, -- read ONLY .UserId / .Name (Lune-mock compatible, §7.3)
	clock: ClockLike, -- server clock (§5); handlers read time HERE, never from payload
	data: DataServiceLike, -- the per-player data layer (§4.4)
	-- deferred seams: nil in the spine, same identity as ServerContext's fields once B2 lands.
	security: any?, -- [B2]
	flags: any?, -- [B2]
	analytics: any?, -- [B2]
	monetization: any?, -- [B2]
	-- [contract pass] Deep Reach seams. NIL in the spine; populated by a stub/feature service at
	-- Start. Declared here because ActionContext is --!strict — a handler reading ctx.economy or
	-- ctx.depth without the field declared is a type error at build, and src/shared/ is read-only
	-- to feature work, so no builder can add them mid-fan-out. Read them nil-safely.
	economy: any?, -- EconomyService: earn/spend + lifetimeCredits + currency_* analytics
	plot: any?, -- PlotService: plotIdFor / rootFor / ownerOf
	salvage: any?, -- SalvageService: rateFor / capacityFor
	depth: any?, -- DepthService: valueMultiplier / tierYFor
}

export type Handler<TIn, TOut> = (ctx: ActionContext, payload: TIn) -> Result<TOut>

-- One registered action. `name` is the wire identifier (stable string).
export type Action<TIn, TOut> = {
	name: string,
	validate: Validator<TIn>,
	rate: RatePolicy,
	handler: Handler<TIn, TOut>,
	-- ownerOf: an optional predicate that extracts the owner UserId a payload claims; the
	-- gateway asserts the acting player matches (Err NotOwner) when present. [B2] expands this.
	ownerOf: ((payload: any) -> number?)?,
	-- [B2] requiresProduct hook lives here as an optional field later.
}

export type Registry = {
	register: <TIn, TOut>(self: Registry, action: Action<TIn, TOut>) -> (),
	get: (self: Registry, name: string) -> Action<any, any>?,
	names: (self: Registry) -> { string },
}

local Net = {}

-- Stable action-name constants the spine + B2 features share (avoids typos across files).
-- AMENDMENT A10a: the scaffold's `Sample = "sample.ping"` key is GONE, together with
-- services/sample, controllers/sample and tests/unit/sample.spec. SampleAction wrote
-- `currencies.Stardust` — the FOUNDATION game's currency — directly from a client-callable action,
-- so leaving it alive through fan-out would mint a currency Deep Reach does not have into live
-- blobs, straight past the ctx.economy single-writer path. Removing the key here (rather than
-- later) also keeps it inside this one guarded shared-contract edit.
Net.Actions = {
	-- [plot] The payload carries NO plot id — the SERVER picks. A client-named plot IS the
	-- plot-claim-hijack exploit. Second claim -> Err(AlreadyClaimed); server full -> Err(Unavailable).
	ClaimPlot = "plot.claim",
	-- [plot] Which dome this player holds (id + world position), for the HUD/highlight.
	-- JoinRetry-guarded on the client (it reads state that only exists after loadSession's yield).
	FetchPlot = "plot.fetch",

	-- [salvage] Empty the smelter: smelter.storedCredits -> currencies.Credits via ctx.economy:earn.
	-- Spam-duplicate safe (the second call finds 0 stored).
	CollectSmelter = "salvage.collect",
	-- [salvage] The DERIVED running income rate + stored + capacity. This is the observation
	-- surface the "purchased structures change the income rate" criterion asserts a delta on.
	FetchSalvage = "salvage.fetch",

	-- [structures] Server-validated purchase of ONE catalog entry; cost is server-derived, never
	-- sent by the client.
	BuyStructure = "structures.buy",
	-- [structures] The catalog with server-derived next-level prices + this player's levels, so
	-- the shop UI never holds its own price constants. Iterates the CATALOG, never the raw blob.
	FetchStructures = "structures.fetch",

	-- [depth] Unlock + descend to the next trench tier. The pressure gate (prior tier + hull
	-- minimum + Credits) is evaluated in the SAME lock-held transform that debits.
	Descend = "depth.descend",
	-- [depth] Current tier, the next tier's Credits + hull requirement, and TODAY's restock tier.
	FetchDepth = "depth.fetch",

	-- [offline] Claim the away-window accrual computed on the SERVER from timestamps.lastSeenUnix.
	-- One-shot per session; no client-supplied time anywhere in the payload.
	ClaimOffline = "offline.claim",
	-- [offline, AMENDMENT A5] Read the PENDING away-accrual grant (amount + whether it was capped)
	-- WITHOUT claiming it, so the claim-on-join popup can show it. The pending amount lives in
	-- server memory, not in PlayerData, so it is not in PlayerView and had no read surface at all.
	-- Peeking MUST be SIDE-EFFECT FREE: never grants, never clears the pending amount, never
	-- re-stamps the away window. JoinRetry-guarded on the client.
	FetchOffline = "offline.peek",

	-- [daily] Claim the supply drop; SERVER-clock gated on the rolling 20-22h window off
	-- daily.lastClaimUnix. Err(OnCooldown) before it opens.
	ClaimDaily = "daily.claim",

	-- [resurface] Prestige: wipe structures + depth + Credits, mint Pearls, ++resurfaces.
	-- Err(PrereqUnmet) below the minimum depth. Duplicate-safe (no Pearl dupe).
	Resurface = "resurface.do",
	-- [resurface] Preview the Pearls that would be minted, the resulting permanent multiplier,
	-- and whether the minimum depth is met — so the confirm UI is server-truthed.
	FetchResurface = "resurface.fetch",

	-- [leaderboard] The current top-N snapshot by stats.lifetimeCredits.
	FetchLeaderboard = "leaderboard.fetch",

	-- NOTE: monetization adds NO action. Gamepass prompts are client-initiated MarketplaceService
	-- calls, and product grants are server-driven through ProcessReceipt — never a client action.
}

-- Creates a fresh, empty registry (one per server; tests create throwaway ones).
function Net.newRegistry(): Registry
	local actions: { [string]: Action<any, any> } = {}

	local registry = {}

	function registry.register<TIn, TOut>(_self: Registry, action: Action<TIn, TOut>): ()
		if type(action.name) ~= "string" or action.name == "" then
			error("Net.register: action.name must be a non-empty string")
		end
		if actions[action.name] ~= nil then
			-- No silent override — a duplicate registration is a boot-time error.
			error(`Net.register: action "{action.name}" already registered`)
		end
		actions[action.name] = (action :: any) :: Action<any, any>
	end

	function registry.get(_self: Registry, name: string): Action<any, any>?
		return actions[name]
	end

	function registry.names(_self: Registry): { string }
		local out = {}
		for name in actions do
			table.insert(out, name)
		end
		table.sort(out)
		return out
	end

	return (registry :: any) :: Registry
end

-- THE single pure inbound pipeline (concern 19). Called by BOTH NetServer (real wire) and
-- Mocks.net.invoke (tests) so they can never diverge. Runs steps 2-7 of the inbound flow:
-- lookup -> [panic] -> [rate via gate] -> [ownership] -> validate -> pcall(handler).
-- Lune-clean & synchronous-by-contract for the validate/handler portion.
function Net.dispatch(
	registry: Registry,
	gate: GateLike?, -- the §3.6 rate/ownership gate; nil-tolerant for tests that skip rate
	ctx: ActionContext,
	actionName: string,
	rawPayload: any
): Result<any>
	-- 2. actionName must be a string and a registered action.
	if type(actionName) ~= "string" then
		return Result.err(Result.Codes.UnknownAction, "actionName must be a string")
	end
	local action = registry:get(actionName)
	if action == nil then
		return Result.err(Result.Codes.UnknownAction, actionName)
	end

	-- 3. Panic flag check — nil-safe; skipped in the spine (no panic flag yet).
	local security = ctx.security
	if security ~= nil and (security :: any).isPanicked ~= nil then
		if (security :: any):isPanicked() then
			return Result.err(Result.Codes.Rejected, "client writes rejected (panic)")
		end
	end

	-- 4. Rate check — the spine's minimal Gate enforces the action's RatePolicy token bucket.
	--    Runs IN THE SPINE so the gateway is rate-limited the moment the spine exists.
	if gate ~= nil then
		local rateResult = gate:check(ctx.player.UserId, actionName, action.rate)
		if not rateResult.ok then
			return rateResult
		end
	end

	-- 5. Ownership assert — if the action declares an ownership predicate, check the acting
	--    player owns the target. Nil-safe: the spine sample needs none.
	if action.ownerOf ~= nil and gate ~= nil then
		local ownerUserId = action.ownerOf(rawPayload)
		if ownerUserId ~= nil then
			local ownerResult = gate:assertOwner(ctx.player.UserId, ownerUserId)
			if not ownerResult.ok then
				return ownerResult
			end
		end
	end

	-- 6. Validate the untrusted payload -> typed value, or Err (BadType/OutOfRange/BadPayload).
	local validated = action.validate(rawPayload)
	if not validated.ok then
		return validated
	end

	-- 7. Call the handler INSIDE pcall so no exception ever crosses the Net boundary
	--    (concern 18). Any thrown error -> Err("Internal").
	local ok, handlerResult = pcall(action.handler, ctx, validated.value)
	if not ok then
		return Result.err(Result.Codes.Internal, tostring(handlerResult))
	end
	return handlerResult
end

return Net
