--!strict
-- games/collect-sim/src/server/services/shop/UpgradesShopService.luau   [upgrades-shop]
-- Feature: the currency SINK. A player spends Stardust (or Prisms) to buy ONE level in an upgrade.
--
-- The catalog — the upgrade kinds, their per-level cost curve, their currency, and the max level —
-- is SERVER-OWNED and SERVER-AUTHORITATIVE: the client supplies ONLY which upgrade to level up
-- (`upgradeId`); it NEVER supplies a price, a level, or an amount. The next-level cost is always
-- DERIVED on the server from the catalog + the player's CURRENT persisted level, so there is no
-- client-supplied number to honor and no open exploit.
--
-- Both the spent currency and the bought level live in PERSISTED PlayerData, so the ENTIRE
-- read-check-write happens INSIDE ONE ctx.data:update transform, under the per-player FIFO lock on
-- a fresh re-read snapshot. An interleaved or spam-duplicated BuyUpgrade re-reads the POST-write
-- balance and level and can never overspend or double-grant.
--
-- ----- THE EFFECT SEAM (ctx.upgrades) — the half that was missing -----
-- BuyUpgrade persisted `d.upgrades[id]` and NOTHING in the game ever read it back: capacity was a
-- constant in CollectionService, magnet range and collect period were constants in the CLIENT
-- controller, and walk-speed had no implementation anywhere (`grep WalkSpeed src/` returned zero
-- hits). A player could spend 9,625 Stardust maxing all four and the game played identically.
--
-- The rule that failure taught: A VALUE THE PLAYER PAYS FOR MUST BE READ BY THE CODE THAT GOVERNS
-- PLAY, THROUGH A NAMED SEAM, AND THE TEST MUST ASSERT THE READ, NOT THE WRITE.
--
-- Every reader below is a PURE function of the lock-held snapshot `d`, and every one returns its
-- pre-upgrade constant when `d` (or the level) is absent — so an un-upgraded player, and every
-- existing test that passes no data, sees exactly the old numbers. Level 0 == the old behavior.
--
-- Where each one is consumed:
--   capacityFor      -> CollectionService (enforced AND reported in the Collect reply)
--   collectPeriodFor -> CollectionService's clock gate (motes granted per second of server time)
--   magnetRadiusFor  -> echoed in the Collect reply; CollectionController's absorb radius
--   walkSpeedFor     -> assigned to Humanoid.WalkSpeed SERVER-SIDE (never by the client)
--   yieldMultiplierFor -> CollectionService's per-mote value (the permanent Prism upgrade)
--
-- Dual-runtime require [D1 shim]: under Lune (script == nil) these resolve via the filesystem and
-- touch no Roblox global. In Roblox, src/shared maps to ReplicatedStorage.Shared.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

-- ----- SERVER-OWNED CATALOG -----
-- `base` is the currency cost of level 1; the cost of the NEXT level is base * (level + 1).
-- `currency` names the balance key it spends. `label`/`blurb` are the strings the shop renders —
-- they live here, server-side, so the price and the promise can never drift apart in the UI.
type CatalogEntry = {
	base: number,
	maxLevel: number,
	currency: string,
	label: string,
	blurb: string,
}

local MAX_LEVEL = 10

-- Upgrade ids with this prefix are PERMANENT: they are bought with Prisms and SURVIVE a rebirth.
-- That is the whole point of a prestige currency, and it is why RebirthService clears upgrades by
-- prefix rather than assigning `d.upgrades = {}`.
local PERMANENT_PREFIX = "prism-"

local CATALOG: { [string]: CatalogEntry } = {
	["collect-speed"] = {
		base = 25,
		maxLevel = MAX_LEVEL,
		currency = "Stardust",
		label = "Collect Speed",
		blurb = "Motes stream in faster",
	},
	["backpack"] = {
		base = 40,
		maxLevel = MAX_LEVEL,
		currency = "Stardust",
		label = "Backpack",
		blurb = "Carry more before selling",
	},
	["magnet"] = {
		base = 60,
		maxLevel = MAX_LEVEL,
		currency = "Stardust",
		label = "Magnet",
		blurb = "Pull motes from further away",
	},
	["walk-speed"] = {
		base = 50,
		maxLevel = MAX_LEVEL,
		currency = "Stardust",
		label = "Walk Speed",
		blurb = "Move between islands faster",
	},
	-- The Prism sink. Before this, rebirth granted Prisms, persisted them, displayed them — and
	-- NOTHING in the codebase ever decremented them. There was no Prism shop, pad or action, so
	-- the entire prestige reward bought nothing.
	["prism-yield"] = {
		base = 2,
		maxLevel = MAX_LEVEL,
		currency = "Prisms",
		label = "Starlight Attunement",
		blurb = "Every mote is worth more — forever, through rebirths",
	},
}

-- Display/iteration order. A map has none, and the shop must render the same rows in the same
-- places every time or the player mis-clicks the thing they were reading.
local CATALOG_ORDER: { string } =
	{ "collect-speed", "backpack", "magnet", "walk-speed", "prism-yield" }

local function nextLevelCost(entry: CatalogEntry, currentLevel: number): number
	return entry.base * (currentLevel + 1)
end

-- ----- THE TUNING CURVES -----
local BASE_CAPACITY = 50 -- motes; CollectionService's former `CAPACITY` constant
local CAPACITY_PER_LEVEL = 10
local BASE_MAGNET_RADIUS = 6 -- studs; CollectionController's former `ABSORB_RADIUS`
local MAGNET_RADIUS_PER_LEVEL = 1.6
local BASE_COLLECT_PERIOD = 0.06 -- seconds per mote; the former client `TICK`
local COLLECT_PERIOD_FLOOR = 0.018 -- never faster than this, whatever the level
local COLLECT_PERIOD_PER_LEVEL = 0.0042
local BASE_WALK_SPEED = 16 -- studs/s; Roblox's Humanoid default
local WALK_SPEED_PER_LEVEL = 1.6
local YIELD_PER_LEVEL = 0.2 -- +20% mote value per permanent Prism level

-- Read one persisted level, clamped to the catalog's max. Nil-safe at every step: absent data,
-- absent `upgrades` table, absent key, or a non-number all collapse to level 0.
local function levelOf(d: any, upgradeId: string): number
	if d == nil or type(d) ~= "table" then
		return 0
	end
	local upgrades = (d :: any).upgrades
	if type(upgrades) ~= "table" then
		return 0
	end
	local level = upgrades[upgradeId]
	if type(level) ~= "number" or level ~= level or level < 0 then
		return 0 -- also rejects NaN, which would poison every arithmetic reader below
	end
	local entry = CATALOG[upgradeId]
	local cap = if entry ~= nil then entry.maxLevel else MAX_LEVEL
	return math.min(math.floor(level), cap)
end

local UpgradesSeam = {}

-- Levels are exposed so a caller can assert the READ moved, not just the stored number.
function UpgradesSeam.levelOf(_self: any, d: any, upgradeId: string): number
	return levelOf(d, upgradeId)
end

function UpgradesSeam.capacityFor(_self: any, d: any): number
	return BASE_CAPACITY + levelOf(d, "backpack") * CAPACITY_PER_LEVEL
end

function UpgradesSeam.magnetRadiusFor(_self: any, d: any): number
	return BASE_MAGNET_RADIUS + levelOf(d, "magnet") * MAGNET_RADIUS_PER_LEVEL
end

function UpgradesSeam.collectPeriodFor(_self: any, d: any): number
	local period = BASE_COLLECT_PERIOD - levelOf(d, "collect-speed") * COLLECT_PERIOD_PER_LEVEL
	return math.max(COLLECT_PERIOD_FLOOR, period)
end

function UpgradesSeam.walkSpeedFor(_self: any, d: any): number
	return BASE_WALK_SPEED + levelOf(d, "walk-speed") * WALK_SPEED_PER_LEVEL
end

function UpgradesSeam.yieldMultiplierFor(_self: any, d: any): number
	return 1 + levelOf(d, "prism-yield") * YIELD_PER_LEVEL
end

-- Whether an upgrade id survives a rebirth. RebirthService asks through the seam rather than
-- re-deriving the convention, so the two can never disagree about what a rebirth costs.
function UpgradesSeam.isPermanent(_self: any, upgradeId: string): boolean
	return type(upgradeId) == "string"
		and string.sub(upgradeId, 1, #PERMANENT_PREFIX) == PERMANENT_PREFIX
end

-- The complete tuning a client needs, as one table. The client used to hold its own copies of
-- these numbers as module constants sitting next to nothing.
function UpgradesSeam.tuningFor(
	_self: any,
	d: any
): {
	capacity: number,
	magnetRadius: number,
	collectPeriod: number,
	walkSpeed: number,
	yieldMultiplier: number,
}
	return {
		capacity = UpgradesSeam:capacityFor(d),
		magnetRadius = UpgradesSeam:magnetRadiusFor(d),
		collectPeriod = UpgradesSeam:collectPeriodFor(d),
		walkSpeed = UpgradesSeam:walkSpeedFor(d),
		yieldMultiplier = UpgradesSeam:yieldMultiplierFor(d),
	}
end

-- The value this upgrade currently delivers, and what the next level would deliver, as numbers the
-- shop renders as "Hold 60 → 70". Derived from the SAME curve functions the game runs on, by
-- simulating a one-level-higher snapshot — so a shop row can never advertise an effect the
-- gameplay code does not produce.
local function effectPair(d: any, upgradeId: string): (number, number, string)
	local level = levelOf(d, upgradeId)
	local simulated: any = { upgrades = {} }
	if d ~= nil and type((d :: any).upgrades) == "table" then
		for key, value in (d :: any).upgrades do
			simulated.upgrades[key] = value
		end
	end
	simulated.upgrades[upgradeId] = level + 1

	if upgradeId == "backpack" then
		return UpgradesSeam:capacityFor(d), UpgradesSeam:capacityFor(simulated), "motes"
	elseif upgradeId == "magnet" then
		return UpgradesSeam:magnetRadiusFor(d), UpgradesSeam:magnetRadiusFor(simulated), "studs"
	elseif upgradeId == "collect-speed" then
		-- Reported as motes per second, not as a period: "16.7/s → 17.9/s" is a number the player
		-- can reason about; "0.060 → 0.056" is not.
		return 1 / UpgradesSeam:collectPeriodFor(d),
			1 / UpgradesSeam:collectPeriodFor(simulated),
			"motes/s"
	elseif upgradeId == "walk-speed" then
		return UpgradesSeam:walkSpeedFor(d), UpgradesSeam:walkSpeedFor(simulated), "studs/s"
	elseif upgradeId == "prism-yield" then
		return UpgradesSeam:yieldMultiplierFor(d),
			UpgradesSeam:yieldMultiplierFor(simulated),
			"x value"
	end
	return 0, 0, ""
end

local UpgradesShopService = { name = "UpgradesShopService" }

-- ----- RUNTIME EFFECT APPLICATION (Roblox-only) -----
-- Walk speed is the one upgrade whose effect lives on an Instance rather than in a reply, so it is
-- assigned SERVER-SIDE — on every spawn and after every successful buy. Never let the client set
-- its own speed: that is a client-authored gameplay value, which is exactly what rule 3 forbids.
local function applyWalkSpeed(player: any, d: any): boolean
	local realGame: any = game
	if realGame == nil or player == nil then
		return false
	end
	local character: any = (player :: any).Character
	if character == nil then
		return false
	end
	local humanoid: any = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end
	local ok = pcall(function()
		humanoid.WalkSpeed = UpgradesSeam:walkSpeedFor(d)
	end)
	return ok
end

-- Build the BuyUpgrade action.
local function makeBuyUpgradeAction(): Net.Action<{ upgradeId: string }, {
	upgradeId: string,
	level: number,
	cost: number,
	currency: string,
	balance: number,
	tuning: any,
}>
	return {
		name = Net.Actions.BuyUpgrade, -- "shop.buy"
		rate = { maxPerWindow = 5, windowSeconds = 1 },
		validate = function(raw): Result.Result<{ upgradeId: string }>
			-- Untrusted payload: must be a table whose `upgradeId` is a known kind. Trust NO other
			-- field — we copy out ONLY upgradeId (any client price/level/amount is never read).
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			local upgradeId = (raw :: any).upgradeId
			if type(upgradeId) ~= "string" then
				return Result.err(Result.Codes.BadPayload)
			end
			if CATALOG[upgradeId] == nil then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({ upgradeId = upgradeId })
		end,
		handler = function(ctx, payload): Result.Result<any>
			local upgradeId = payload.upgradeId
			local entry = CATALOG[upgradeId]
			if entry == nil then
				return Result.err(Result.Codes.BadPayload) -- defensive; validate guarantees this
			end

			-- ----- CONCURRENCY-SAFE SPEND -----
			-- The ENTIRE decision is made INSIDE the transform, on the lock-held re-read snapshot.
			local rejectCode: string? = nil
			local outCost = 0
			local outLevel = 0
			local outBalance = 0
			local outSnapshot: any = nil

			local updated = ctx.data:update(ctx.player, function(d)
				local currentLevel = (d.upgrades[upgradeId] or 0)
				local balance = (d.currencies[entry.currency] or 0)

				if currentLevel >= entry.maxLevel then
					rejectCode = Result.Codes.OutOfRange
					return d
				end

				local cost = nextLevelCost(entry, currentLevel)
				if balance < cost then
					rejectCode = Result.Codes.Insufficient
					return d
				end

				local newBalance = balance - cost
				local newLevel = currentLevel + 1
				d.currencies[entry.currency] = newBalance
				d.upgrades[upgradeId] = newLevel

				outCost = cost
				outLevel = newLevel
				outBalance = newBalance
				outSnapshot = d
				return d
			end)

			if not updated.ok then
				return updated
			end
			if rejectCode ~= nil then
				return Result.err(rejectCode :: string)
			end

			-- The bought level takes effect on the CHARACTER immediately. Without this the
			-- walk-speed upgrade would only apply on the next respawn, which reads as "nothing
			-- happened" — the exact complaint that started this work.
			applyWalkSpeed(ctx.player, updated.value)

			if ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("currency_spent", {
					userId = ctx.player.UserId,
					currency = entry.currency,
					amount = outCost,
					upgradeId = upgradeId,
				})
			end

			return Result.ok({
				upgradeId = upgradeId,
				level = outLevel,
				cost = outCost,
				currency = entry.currency,
				balance = outBalance,
				-- The DERIVED tuning after the purchase. The client re-reads its magnet radius and
				-- collect period from this, so a bought level changes play on the very next frame
				-- instead of after a reconnect.
				tuning = UpgradesSeam:tuningFor(outSnapshot or updated.value),
			})
		end,
	}
end

-- ----- FetchUpgrades: the shop's read side -----
-- Every number a player needs BEFORE committing: the price, the currency, whether they can afford
-- it, the level, whether it is maxed, and what the level actually does. The shop used to render
-- "Backpack — Lv 0" and nothing else, so you discovered prices by being charged.
local function makeFetchUpgradesAction(): Net.Action<{}, any>
	return {
		name = Net.Actions.FetchUpgrades, -- "shop.fetch"
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(ctx, _payload): Result.Result<any>
			local got = ctx.data:get(ctx.player)
			if not got.ok then
				return got
			end
			local d = got.value
			local entries: { any } = {}
			for order, upgradeId in CATALOG_ORDER do
				local entry = CATALOG[upgradeId]
				if entry ~= nil then
					local level = levelOf(d, upgradeId)
					local maxed = level >= entry.maxLevel
					local cost = if maxed then 0 else nextLevelCost(entry, level)
					local balance = (d.currencies[entry.currency] or 0)
					local now, next, unit = effectPair(d, upgradeId)
					table.insert(entries, {
						id = upgradeId,
						order = order,
						label = entry.label,
						blurb = entry.blurb,
						currency = entry.currency,
						level = level,
						maxLevel = entry.maxLevel,
						maxed = maxed,
						cost = cost,
						affordable = (not maxed) and balance >= cost,
						permanent = UpgradesSeam:isPermanent(upgradeId),
						effectNow = now,
						effectNext = next,
						effectUnit = unit,
					})
				end
			end
			-- The prestige block rides along on the same round trip. It belongs to the same
			-- question — "what can I buy, and what would it cost me?" — and the rebirth altar had
			-- no way to state its price at all before this.
			local rebirthPreview: any = nil
			if ctx.rebirth ~= nil and type((ctx.rebirth :: any).previewFor) == "function" then
				local ok, preview = pcall(function()
					return (ctx.rebirth :: any):previewFor(d)
				end)
				if ok then
					rebirthPreview = preview
				end
			end

			return Result.ok({
				entries = entries,
				tuning = UpgradesSeam:tuningFor(d),
				balances = {
					Stardust = (d.currencies.Stardust or 0),
					Prisms = (d.currencies.Prisms or 0),
				},
				rebirth = rebirthPreview,
			})
		end,
	}
end

-- Start: register both actions, publish the effect seam, and hook character spawns so walk speed
-- is applied without waiting for a purchase.
function UpgradesShopService:Start(context: any): ()
	context.net:register(makeBuyUpgradeAction())
	context.net:register(makeFetchUpgradesAction())
	context.upgrades = UpgradesSeam

	local realGame: any = game
	if realGame == nil then
		return -- Lune: no characters to apply anything to
	end
	local Players = realGame:GetService("Players")
	local function hook(player: any): ()
		player.CharacterAdded:Connect(function(): ()
			local got = context.data:get(player)
			if got ~= nil and got.ok then
				applyWalkSpeed(player, got.value)
			end
		end)
		if player.Character ~= nil then
			local got = context.data:get(player)
			if got ~= nil and got.ok then
				applyWalkSpeed(player, got.value)
			end
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
end

return UpgradesShopService
