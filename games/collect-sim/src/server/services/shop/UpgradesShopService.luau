--!strict
-- games/collect-sim/src/server/services/shop/UpgradesShopService.luau   [upgrades-shop]
-- Feature: the Stardust SINK. A player spends Stardust to buy ONE level in an upgrade.
--
-- The catalog (the four upgrade kinds, their per-level cost curve, and the max level) is
-- SERVER-OWNED and SERVER-AUTHORITATIVE: the client supplies ONLY which upgrade to level up
-- (`upgradeId`); it NEVER supplies a price, a level, or an amount. The next-level cost is always
-- DERIVED on the server from the catalog + the player's CURRENT persisted level. There is no
-- client-supplied number to honor, so there is no open exploit (spec success criterion).
--
-- Both the spent Stardust and the bought level live in PERSISTED PlayerData
-- (currencies.Stardust and upgrades[upgradeId]). Unlike Collection's Sell (which empties an
-- in-memory backpack BEFORE the yielding update), here BOTH operands are persisted, so the
-- ENTIRE read-check-write — re-read level + re-read balance, compute cost, affordability check,
-- deduct, bump — is performed INSIDE ONE ctx.data:update transform. That transform runs under
-- the per-player FIFO lock on a fresh re-read snapshot (MockStore §4.1 / DataService.update), so
-- it is atomic: an interleaved or spam-duplicated BuyUpgrade re-reads the POST-write balance and
-- level and can never overspend, never grant a level without the matching deduction, and never
-- double-grant a level for a single payment. There is NO read-then-write across the yield: the
-- transform body is synchronous and reads only the snapshot it is handed.
--
-- Lune-clean: relative requires only; no Roblox global touched. The action is plain data +
-- pure-ish functions over injected ctx, so a spec can drive it through Mocks.net -> Net.dispatch.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- ----- SERVER-OWNED CATALOG (authoritative; the client never sees or supplies any of this) -----
-- Each upgrade kind: a Stardust `base` cost and a `maxLevel`. The cost of the NEXT level (when
-- the player currently owns `level` levels) is a rising curve: base * (level + 1). So the first
-- level (0 -> 1) costs base*1, the second base*2, ... the tenth base*10. Levels start at 0 and
-- cap at maxLevel.
type CatalogEntry = { base: number, maxLevel: number }

local MAX_LEVEL = 10

local CATALOG: { [string]: CatalogEntry } = {
	["collect-speed"] = { base = 25, maxLevel = MAX_LEVEL },
	["backpack"] = { base = 40, maxLevel = MAX_LEVEL },
	["magnet"] = { base = 60, maxLevel = MAX_LEVEL },
	["walk-speed"] = { base = 50, maxLevel = MAX_LEVEL },
}

-- Cost of the NEXT level given the CURRENT level. Server-derived; integer (base + level are ints).
local function nextLevelCost(entry: CatalogEntry, currentLevel: number): number
	return entry.base * (currentLevel + 1)
end

local UpgradesShopService = { name = "UpgradesShopService" }

-- Build the BuyUpgrade action. No closed-over feature state is needed: the catalog is a module
-- constant and the only mutable state (Stardust + the upgrade level) is persisted PlayerData,
-- mutated atomically inside the single update transform.
local function makeBuyUpgradeAction(): Net.Action<
	{ upgradeId: string },
	{ upgradeId: string, level: number, cost: number, balance: number }
>
	return {
		name = Net.Actions.BuyUpgrade, -- "shop.buy"
		-- Deliberate spend (player taps a shop button): a tight bucket so spam-duplicated buys are
		-- also rate-shed. The concurrency guarantee does NOT rely on this — it is defence in depth.
		rate = { maxPerWindow = 5, windowSeconds = 1 },
		validate = function(raw): Result.Result<{ upgradeId: string }>
			-- Untrusted payload: must be a table whose `upgradeId` is one of the four known kinds.
			-- Trust NO other field — we copy out ONLY upgradeId (any client price/level/amount is
			-- ignored by never being read).
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			local upgradeId = (raw :: any).upgradeId
			if type(upgradeId) ~= "string" then
				return Result.err(Result.Codes.BadPayload)
			end
			if CATALOG[upgradeId] == nil then
				-- Unknown upgrade kind: a malformed/unknown payload, not a range error.
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({ upgradeId = upgradeId })
		end,
		handler = function(
			ctx,
			payload
		): Result.Result<{ upgradeId: string, level: number, cost: number, balance: number }>
			local upgradeId = payload.upgradeId
			local entry = CATALOG[upgradeId]
			if entry == nil then
				-- Defensive: validate already guarantees this, but never trust the path.
				return Result.err(Result.Codes.BadPayload)
			end

			-- ----- CONCURRENCY-SAFE SPEND (the economy red-team target) -----
			-- The ENTIRE decision is made INSIDE the transform, on the lock-held re-read snapshot.
			-- We capture the OUTCOME (cost / new level / new balance, or a rejection code) into
			-- locals the transform closes over; the transform mutates `d` ONLY on success and
			-- returns `d` unchanged on any rejection. Because the transform runs under the per-
			-- player FIFO lock on the freshest value, two interleaved buys serialise: the second
			-- re-reads the already-deducted balance and already-bumped level, so it can never
			-- overspend or double-grant. No state is read outside the transform and written inside.
			local rejectCode: string? = nil
			local outCost = 0
			local outLevel = 0
			local outBalance = 0

			local updated = ctx.data:update(ctx.player, function(d)
				-- Re-read CURRENT level and balance from the snapshot the lock handed us.
				local currentLevel = (d.upgrades[upgradeId] or 0)
				local balance = (d.currencies.Stardust or 0)

				if currentLevel >= entry.maxLevel then
					-- Already maxed: nothing to buy, no change. (OutOfRange = level out of range.)
					rejectCode = Result.Codes.OutOfRange
					return d
				end

				local cost = nextLevelCost(entry, currentLevel)
				if balance < cost then
					-- Cannot afford: NO deduction, NO level change.
					rejectCode = Result.Codes.Insufficient
					return d
				end

				-- Affordable: deduct EXACTLY the server-derived cost AND bump the level by 1,
				-- both inside this one synchronous, lock-held transform.
				local newBalance = balance - cost
				local newLevel = currentLevel + 1
				d.currencies.Stardust = newBalance
				d.upgrades[upgradeId] = newLevel

				outCost = cost
				outLevel = newLevel
				outBalance = newBalance
				return d
			end)

			if not updated.ok then
				-- The data write itself failed (e.g. NoData / transient). Surface it; the transform
				-- made no partial change it returned (it returns `d` whole), so nothing to undo.
				return updated
			end

			-- A server-side rejection decided INSIDE the transform (snapshot-based). No mutation
			-- happened, so balance and level are unchanged and persisted as-is.
			if rejectCode ~= nil then
				return Result.err(rejectCode :: string)
			end

			return Result.ok({
				upgradeId = upgradeId,
				level = outLevel,
				cost = outCost,
				balance = outBalance,
			})
		end,
	}
end

-- Start: register the single BuyUpgrade action on the gateway. No closed-over mutable feature
-- state — the catalog is constant and all mutation lives in the persisted data layer.
function UpgradesShopService:Start(context: any): ()
	context.net:register(makeBuyUpgradeAction())
end

return UpgradesShopService
