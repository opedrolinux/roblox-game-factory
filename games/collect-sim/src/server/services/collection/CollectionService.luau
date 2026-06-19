--!strict
-- games/collect-sim/src/server/services/collection/CollectionService.luau   [collection-core]
-- Feature: motes auto-collect into a per-player backpack; selling at the refiner converts the
-- whole backpack to Stardust (count x mote value) and empties it.
--
-- The backpack is FEATURE-OWNED SESSION STATE: an in-memory map keyed by player.UserId, NOT
-- persisted (persisted/upgradeable capacity arrives with a later feature). Because it lives in
-- service state (not PlayerData), the Collect/Sell actions are built INSIDE Start() as closures
-- over the backpack table, then registered on the gateway. Stardust is the persisted economy
-- and is mutated ONLY through ctx.data:update (the single-writer, lock-queued path).
--
-- Lune-clean: relative requires only; no Roblox global touched. The actions are plain data +
-- pure-ish functions over injected ctx, so a spec can drive them through Mocks.net -> Net.dispatch.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- Feature constants (NOT persisted/upgradeable yet — a later feature reads these from PlayerData
-- upgrades). Backpack holds at most CAPACITY motes; each mote sells for MOTE_VALUE Stardust.
local CAPACITY = 50
local MOTE_VALUE = 3

local CollectionService = { name = "CollectionService" }

-- Build the Collect action as a closure over `backpacks` (UserId -> mote count).
-- Payload: {} (no client-supplied data — server adds exactly one mote to the CALLER's backpack;
-- mote identity/proximity is a Tier-3 server-authority concern, deliberately NOT trusted here).
-- Rate: collect is frequent (auto-collect) -> a generous window. Returns {count, capacity, full}.
local function makeCollectAction(
	backpacks: { [number]: number }
): Net.Action<{}, { count: number, capacity: number, full: boolean }>
	return {
		name = Net.Actions.Collect, -- "collect.gather"
		-- Frequent action (motes stream in): allow a high per-second rate with burst.
		rate = { maxPerWindow = 20, windowSeconds = 1, burst = 30 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload must be a table; we accept ONLY an empty intent (no client fields
			-- are trusted — the server decides what a "collect" does to the caller's backpack).
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(
			ctx,
			_payload
		): Result.Result<{ count: number, capacity: number, full: boolean }>
			local userId = ctx.player.UserId
			local count = backpacks[userId] or 0
			if count >= CAPACITY then
				-- Backpack full: refuse to over-fill. OutOfRange = "no room" (range = capacity).
				return Result.err(Result.Codes.OutOfRange, "backpack full")
			end
			count += 1
			backpacks[userId] = count
			return Result.ok({ count = count, capacity = CAPACITY, full = count >= CAPACITY })
		end,
	}
end

-- Build the Sell action as a closure over `backpacks`.
-- Payload: {} (no client-supplied data — sell converts the CALLER's whole backpack).
-- Rate: selling is deliberate (player returns to the refiner) -> a tight window.
-- Returns {sold, earned, balance}. CONCURRENCY-SAFE: see the order-of-operations note below.
local function makeSellAction(
	backpacks: { [number]: number }
): Net.Action<{}, { sold: number, earned: number, balance: number }>
	return {
		name = Net.Actions.Sell, -- "collect.sell"
		-- Deliberate action: a tight bucket so spam-duplicated sells are also rate-shed.
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(
			ctx,
			_payload
		): Result.Result<{ sold: number, earned: number, balance: number }>
			local userId = ctx.player.UserId
			local count = backpacks[userId] or 0
			if count <= 0 then
				-- Nothing to sell: not an error condition that grants currency. Report empty sale.
				local current = ctx.data:get(ctx.player)
				if not current.ok then
					return current
				end
				local balance = (current.value.currencies.Stardust or 0)
				return Result.ok({ sold = 0, earned = 0, balance = balance })
			end

			-- ----- CONCURRENCY-SAFE SELL (the hard part) -----
			-- ctx.data:update can YIELD on the per-player lock queue. If we read the count, called
			-- update (yield), then zeroed the backpack AFTER, two interleaved/spam-duplicated sells
			-- would each see the SAME non-zero count and double-grant. So we:
			--   1. capture the count,
			--   2. EMPTY the backpack to 0 BEFORE the (possibly yielding) update,
			-- so any second sell that interleaves now sees an empty backpack and grants nothing.
			backpacks[userId] = 0
			local earned = count * MOTE_VALUE

			-- 3. add the captured earnings INSIDE the lock-held synchronous transform (no yield).
			local updated = ctx.data:update(ctx.player, function(d)
				d.currencies.Stardust = (d.currencies.Stardust or 0) + earned
				return d
			end)

			if not updated.ok then
				-- 4. The grant FAILED: restore the captured count so the player keeps their motes.
				-- (Add back rather than overwrite, in case other motes auto-collected during the
				-- yield window — those must not be lost either.)
				backpacks[userId] = (backpacks[userId] or 0) + count
				return updated
			end

			local balance = updated.value.currencies.Stardust
			return Result.ok({ sold = count, earned = earned, balance = balance })
		end,
	}
end

-- Start: construct the actions as closures over a single backpack table, then register each on
-- the gateway. One table instance shared by both actions => Collect fills what Sell empties.
function CollectionService:Start(context: any): ()
	local backpacks: { [number]: number } = {}
	context.net:register(makeCollectAction(backpacks))
	context.net:register(makeSellAction(backpacks))
end

return CollectionService
