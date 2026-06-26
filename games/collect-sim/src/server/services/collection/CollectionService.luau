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
-- Dual-runtime require [D1 shim]: under Lune (script == nil) these resolve via the filesystem and
-- touch no Roblox global, so a spec drives the actions through Mocks.net -> Net.dispatch. In Roblox,
-- src/shared maps to ReplicatedStorage.Shared (a DIFFERENT service than this ServerScriptService
-- module), so the relative string can't reach it — the script ~= nil branch requires it by instance.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

-- Feature constants (NOT persisted/upgradeable yet — a later feature reads these from PlayerData
-- upgrades). Backpack holds at most CAPACITY motes; each mote sells for MOTE_VALUE Stardust.
local CAPACITY = 50
local MOTE_VALUE = 3

-- Server-owned rebirth step: each rebirth adds REBIRTH_STEP to the Sell multiplier
-- (rebirth multiplier = 1 + rebirths*REBIRTH_STEP). Defined HERE because this is where the
-- consolidated Sell formula reads it. With rebirths = 0 the multiplier is exactly 1.
local REBIRTH_STEP = 0.1

-- ----- AUTO-COLLECT (gamepass-gated, clock-driven, deterministic) -----
-- A pass-holder's backpack fills automatically: one mote per AUTO_COLLECT_INTERVAL seconds of
-- elapsed SERVER MONOTONIC time (ctx.clock:mono(), never wall/real time). The grant is a pure
-- function of (elapsed time, current count, capacity) so it is fully deterministic and Tier-1
-- testable through the injected fake clock — no task.wait, no scheduler, no real-time dependency.
local AUTO_COLLECT_INTERVAL = 1 -- seconds of elapsed mono time per auto-granted mote (pass-holders)

-- How often the RUNTIME driver (Roblox-only) ticks every live player. Coarse on purpose: the ticker
-- carries the sub-interval remainder, so a 1s loop never grants ahead of real elapsed mono time.
local AUTO_COLLECT_DRIVE_INTERVAL = 1

-- The gamepass flag key checked on PlayerData.flags. Only players whose flags[AUTO_COLLECT_FLAG]
-- is truthy receive auto-collected motes; everyone else is a strict no-op.
local AUTO_COLLECT_FLAG = "gamepass.autoCollect"

-- Pure auto-collect math: given the mono seconds elapsed since the last tick and the current
-- backpack count, returns how many motes to grant (clamped so the backpack never exceeds CAPACITY)
-- and the leftover sub-interval time to carry forward (so fractional progress is never lost and the
-- grant can never run ahead of real elapsed time). Deterministic; no side effects.
local function autoCollectGrant(elapsed: number, count: number): (number, number)
	if elapsed < AUTO_COLLECT_INTERVAL then
		return 0, elapsed -- not a full interval yet: grant nothing, carry the whole remainder
	end
	local earnedMotes = math.floor(elapsed / AUTO_COLLECT_INTERVAL)
	local carry = elapsed - earnedMotes * AUTO_COLLECT_INTERVAL -- sub-interval remainder, never lost
	local room = CAPACITY - count
	if room < 0 then
		room = 0
	end
	local granted = math.min(earnedMotes, room) -- clamp to capacity (never overfill)
	return granted, carry
end

-- Nil-safe seam reader: a feature/stub service may populate ctx.islands / ctx.restock /
-- ctx.monetization later; in the spine they are nil. Every multiplier DEFAULTS TO 1 when its seam
-- (or its method, or the value) is absent, so the consolidated Sell is behavior-identical to the
-- pre-retrofit `count * MOTE_VALUE` whenever no feature seam is wired (the existing tests' world).
local function seamMultiplier(value: number?): number
	if type(value) ~= "number" then
		return 1
	end
	return value
end

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

			-- ----- CONSOLIDATED, SERVER-DERIVED EARN FORMULA -----
			-- earned = baseSellValue * islandMult * restockMult * stardustMult * (1 + rebirths*STEP).
			-- baseSellValue is the pre-retrofit count*MOTE_VALUE. Every feature multiplier is read
			-- NIL-SAFELY (default 1) from its seam, and `rebirths` from the LOCK-HELD snapshot (default
			-- 0), so when no seam is wired AND rebirths == 0 every factor is 1 and earned == the
			-- original count*MOTE_VALUE EXACTLY (the existing tests' invariant). math.floor keeps earned
			-- a whole number once fractional multipliers land (a no-op on the all-1 path).
			local baseSellValue = count * MOTE_VALUE
			local now = ctx.clock:unix()

			-- `earned` is captured OUT of the transform but COMPUTED inside it (it depends on `rebirths`
			-- + the island / restock / stardust multipliers, ALL read from the lock-held `d` INSIDE the
			-- transform); the transform writes both Stardust and lifetimeStardust.
			local earned = 0

			-- 3. add the captured earnings INSIDE the lock-held synchronous transform (no yield), and
			--    accrue the SAME amount into the lifetime counter.
			local updated = ctx.data:update(ctx.player, function(d)
				-- ALL THREE feature multipliers are PURE seam reads over the lock-held snapshot `d` (no
				-- yield), so per-island mote value, today's rich-vein bonus, AND the 2x boost/gamepass
				-- reach the sale, read off the SAME snapshot the sale commits on (atomic, no read-check-
				-- write across a yield). Nil-safe: an unwired seam leaves its factor at 1.
				local islandMult = 1
				if ctx.islands ~= nil then
					islandMult = seamMultiplier((ctx.islands :: any):multiplierFor(d))
				end
				local restockMult = 1
				if ctx.restock ~= nil then
					restockMult = seamMultiplier((ctx.restock :: any):multiplierFor(d, now))
				end
				-- stardustMult (2x boost OR 2x gamepass) is read from the lock-held `d` too (v5: the boost
				-- is persisted), so a boost arming/expiring concurrently is seen atomically with the sale.
				local stardustMult = 1
				if ctx.monetization ~= nil then
					stardustMult =
						seamMultiplier((ctx.monetization :: any):stardustMultiplierFor(d, now))
				end
				local rebirths = (d.rebirths or 0)
				local rebirthMult = 1 + rebirths * REBIRTH_STEP
				earned = math.floor(
					baseSellValue * islandMult * restockMult * stardustMult * rebirthMult
				)
				d.currencies.Stardust = (d.currencies.Stardust or 0) + earned
				-- Accrue the SAME amount into the lifetime counter. NIL-SAFE on `d.stats`: a real
				-- PlayerData always has stats (default()/migrate seed it), but a minimal test fake may
				-- hand a snapshot without one — guard so the lifetime accrual never crashes the grant.
				if d.stats ~= nil then
					d.stats.lifetimeStardust = (d.stats.lifetimeStardust or 0) + earned
				end
				return d
			end)

			if not updated.ok then
				-- 4. The grant FAILED: restore the captured count so the player keeps their motes.
				-- (Add back rather than overwrite, in case other motes auto-collected during the
				-- yield window — those must not be lost either.) CLAMP to CAPACITY: if the backpack
				-- refilled to capacity during the yield, the restore must not push it OVER the cap
				-- (that would let the player later sell more than a backpack can hold). Overflow motes
				-- past capacity are dropped — the holding-cap invariant wins over never-lose-a-mote.
				backpacks[userId] = math.min(CAPACITY, (backpacks[userId] or 0) + count)
				return updated
			end

			local balance = updated.value.currencies.Stardust

			-- Emit currency_earned AFTER a successful grant. NIL-SAFE: ctx.analytics is nil in the spine
			-- (and in the existing tests), so this is a no-op there; a wired AnalyticsService records it.
			if ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("currency_earned", {
					userId = userId,
					currency = "Stardust",
					amount = earned,
					source = "sell",
				})
			end

			return Result.ok({ sold = count, earned = earned, balance = balance })
		end,
	}
end

-- Build the auto-collect ticker as a closure over the SAME backpack table the Collect/Sell actions
-- share. `tick(ctx, player)` is the deterministic, clock-driven, gamepass-gated grant: it reads the
-- player's PERSISTED flags through ctx.data:get, and only if flags[AUTO_COLLECT_FLAG] is truthy does
-- it grant accrued motes (one per AUTO_COLLECT_INTERVAL of elapsed mono time, clamped to capacity).
-- It is concurrency-safe with Collect/Sell: it only ever ADDS to the in-memory backpack and clamps
-- to CAPACITY (same invariant the Collect action enforces), and it carries the sub-interval remainder
-- so it can never grant ahead of real elapsed time. Returns the number of motes granted (0 for
-- non-holders / no-elapsed), so a test can assert the grant deterministically via the fake clock.
local function makeAutoCollectTicker(backpacks: { [number]: number })
	local lastMono: { [number]: number } = {} -- per-player last tick time (mono seconds)
	return function(ctx: any, player: any): number
		local userId = player.UserId
		local now = ctx.clock:mono()
		local previous = lastMono[userId]
		if previous == nil then
			-- First observation for this player: anchor the clock, grant nothing (no elapsed window).
			lastMono[userId] = now
			return 0
		end

		-- Gamepass gate: only pass-holders auto-collect. Read the PERSISTED flag nil-safely; a player
		-- with no loaded data or no flag is a strict no-op (but we still advance the anchor so a later
		-- grant after the pass is bought measures only post-purchase elapsed time).
		local hasPass = false
		local got = ctx.data:get(player)
		if got.ok and got.value.flags ~= nil and got.value.flags[AUTO_COLLECT_FLAG] then
			hasPass = true
		end

		local elapsed = now - previous
		if not hasPass then
			lastMono[userId] = now
			return 0
		end

		local count = backpacks[userId] or 0
		local granted, carry = autoCollectGrant(elapsed, count)
		-- Advance the anchor by the CONSUMED time only (now - carry), so the unspent sub-interval
		-- remainder is preserved for the next tick — fractional progress is never silently dropped.
		lastMono[userId] = now - carry
		if granted > 0 then
			backpacks[userId] = count + granted
		end
		return granted
	end
end

-- Start: construct the actions as closures over a single backpack table, then register each on
-- the gateway. One table instance shared by all three (Collect/Sell/auto-collect) => Collect fills
-- what Sell empties, and the auto-collect ticker grants into the same backpack for pass-holders.
function CollectionService:Start(context: any): ()
	local backpacks: { [number]: number } = {}
	context.net:register(makeCollectAction(backpacks))
	context.net:register(makeSellAction(backpacks))
	-- Expose the deterministic, clock-driven auto-collect ticker (Tier-1 tested directly via the fake
	-- clock — no task.wait inside it). The RUNTIME driver below feeds it the live players.
	self.tickAutoCollect = makeAutoCollectTicker(backpacks)

	-- ----- RUNTIME-ONLY auto-collect driver (Roblox-only; a strict no-op under Lune) -----
	-- `game`/`task` are real globals on the Roblox server but NIL under Lune, so the whole driver sits
	-- behind the established guard (the LeaderboardService/DataService pattern): under Lune, Start has
	-- ALREADY registered the actions + set the ticker above, then returns here — so the existing tests
	-- (which drive tickAutoCollect directly) are untouched. Only at runtime do we spin the loop that
	-- ticks every live player, granting auto-collected motes into the SAME backpack Collect/Sell share.
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return
	end
	local Players = realGame:GetService("Players")
	-- The narrow ctx the ticker needs: the injected SERVER clock (mono) + the per-player data accessor.
	local tickCtx = { clock = context.clock, data = context.data }
	realTask.spawn(function(): ()
		while true do
			for _, player in Players:GetPlayers() do
				-- Isolate each tick: a throw for ONE player must not unwind the loop and silently kill
				-- auto-collect server-wide. (The ticker is engineered throw-free — get returns a Result,
				-- the math is pure — but defend in depth, mirroring Net.dispatch's per-handler pcall.)
				pcall(self.tickAutoCollect, tickCtx, player)
			end
			realTask.wait(AUTO_COLLECT_DRIVE_INTERVAL)
		end
	end)
end

return CollectionService
