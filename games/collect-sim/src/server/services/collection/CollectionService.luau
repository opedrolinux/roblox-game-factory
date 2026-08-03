--!strict
-- games/collect-sim/src/server/services/collection/CollectionService.luau   [collection-core]
-- Feature: motes accrue into a per-player backpack; selling at a refiner converts the whole
-- backpack to Stardust and empties it.
--
-- ----- WHAT CHANGED, AND WHY (three defects, one file) -----
--
-- 1. CAPACITY WAS A CONSTANT. `CAPACITY = 50` sat beside the persisted backpack level nothing read,
--    so ten levels of backpack (2,200 Stardust) did nothing. Capacity now comes from
--    ctx.upgrades:capacityFor(d) — the purchased value governs play.
--
-- 2. THE GRANT WAS PER-CALL, SO THE ECONOMY WAS PER-CALL. `collect.gather` added exactly one mote
--    per request with no position, proximity or timing check; the only defence was a 20/s rate
--    bucket. A scripted client minted ~3,600 Stardust/minute against a walking player's ~150 per
--    few minutes — about 70x — and every price in the game is calibrated against the walker.
--    Now the grant is derived from the SERVER MONOTONIC CLOCK: a call is granted
--    floor(elapsed / collectPeriod) motes since that player's last grant, capped, and the consumed
--    time is deducted. Calling 100 times in the same instant grants what one call grants. The rate
--    bucket stays as defence in depth, no longer as the only defence. This ALSO makes the
--    collect-speed upgrade real: the period comes from ctx.upgrades:collectPeriodFor(d), and a
--    faster period yields more motes per call rather than requiring more calls (which the rate
--    bucket would have shed, capping the upgrade at ~1.2x however many levels were bought).
--
-- 3. THE ISLAND MULTIPLIER WAS GLOBAL, SO ISLANDS WERE DECORATION. It was keyed off the highest
--    island you OWNED and applied at SELL time, so standing on island 1 paid the island-5 rate.
--    Mote value is now banked AT COLLECT TIME using the island the player is physically standing
--    on (ctx.world:islandOf — server-derived from the character, never client-supplied). The
--    backpack therefore carries a COUNT and a VALUE: "richer motes on higher islands" is finally a
--    real, observable property. Banking at collect (not at sell) is also what lets every island
--    have its own refiner without making the sell location a free multiplier choice.
--
-- The backpack is FEATURE-OWNED SESSION STATE keyed by player.UserId. Stardust is the persisted
-- economy and is mutated ONLY through ctx.data:update (the single-writer, lock-queued path).
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

-- BASE_* are the LEVEL-0 values, not the values. The real ones are read per request from the
-- ctx.upgrades seam so a purchased level actually changes play. These survive only as the nil-safe
-- defaults for when the seam is absent (the spine, and every Tier-1 test that wires no shop
-- service) — at level 0 the two are equal, so old behavior is preserved exactly.
local BASE_CAPACITY = 50
local BASE_COLLECT_PERIOD = 0.06 -- seconds of server time per mote at level 0
local BASE_MAGNET_RADIUS = 6 -- studs; reported to the client, which used to hold its own constant
local MOTE_VALUE = 3

-- Server-owned rebirth step: each rebirth adds REBIRTH_STEP to the Sell multiplier.
local REBIRTH_STEP = 0.1

-- ----- THE CLOCK GATE -----
-- The most time a single call may ever cash in, so standing still for ten minutes does not bank
-- ten minutes of motes and dump them in one request. Small on purpose: the player collects by
-- BEING somewhere, not by waiting somewhere.
local MAX_BANKED_MOTES = 20
-- Hard ceiling on motes granted by one request, independent of the clock. Belt to the braces.
local MAX_GRANT_PER_CALL = 25

-- ----- AUTO-COLLECT (gamepass-gated, clock-driven, deterministic) -----
local AUTO_COLLECT_INTERVAL = 1 -- seconds of elapsed mono time per auto-granted mote (pass-holders)
local AUTO_COLLECT_DRIVE_INTERVAL = 1 -- how often the runtime driver ticks every live player
local AUTO_COLLECT_FLAG = "gamepass.autoCollect"

-- A backpack holds a COUNT (what the capacity caps, what the HUD bar shows) and a VALUE (the
-- Stardust those motes are worth, already multiplied by the island they were collected on).
export type Backpack = { count: number, value: number }

local function emptyBackpack(): Backpack
	return { count = 0, value = 0 }
end

-- Pure auto-collect math: given the mono seconds elapsed since the last tick and the current
-- backpack count, returns how many motes to grant (clamped so the backpack never exceeds capacity)
-- and the leftover sub-interval time to carry forward. Deterministic; no side effects.
local function autoCollectGrant(elapsed: number, count: number, capacity: number): (number, number)
	if elapsed < AUTO_COLLECT_INTERVAL then
		return 0, elapsed -- not a full interval yet: grant nothing, carry the whole remainder
	end
	local earnedMotes = math.floor(elapsed / AUTO_COLLECT_INTERVAL)
	local carry = elapsed - earnedMotes * AUTO_COLLECT_INTERVAL -- remainder, never lost
	local room = capacity - count
	if room < 0 then
		room = 0
	end
	return math.min(earnedMotes, room), carry
end

-- Nil-safe seam reader: every multiplier DEFAULTS TO 1 when its seam (or its method, or the value)
-- is absent, so the consolidated Sell is behavior-identical to the pre-retrofit `count * MOTE_VALUE`
-- whenever no feature seam is wired (the existing tests' world).
local function seamMultiplier(value: number?): number
	if type(value) ~= "number" or value ~= value then
		return 1
	end
	return value
end

-- Read one tuning number off the ctx.upgrades seam over a snapshot, with a hard fallback. Shared by
-- capacity / period / magnet so the defensive shape is written once: a broken or absent seam must
-- never uncap the backpack, never make the period zero (an infinite grant), and never throw on the
-- hot Collect path.
local function tuningFrom(
	ctx: any,
	d: any,
	method: string,
	fallback: number,
	minimum: number
): number
	local seam = ctx.upgrades
	if seam == nil or type(seam[method]) ~= "function" or d == nil then
		return fallback
	end
	local ok, value = pcall(seam[method], seam, d)
	if not ok or type(value) ~= "number" or value ~= value or value < minimum then
		return fallback
	end
	return value
end

local function capacityFrom(ctx: any, d: any): number
	return math.floor(tuningFrom(ctx, d, "capacityFor", BASE_CAPACITY, 1))
end

local function collectPeriodFrom(ctx: any, d: any): number
	-- A minimum of 0.001s: a zero or negative period would make floor(elapsed/period) infinite.
	return tuningFrom(ctx, d, "collectPeriodFor", BASE_COLLECT_PERIOD, 0.001)
end

local function magnetRadiusFrom(ctx: any, d: any): number
	return tuningFrom(ctx, d, "magnetRadiusFor", BASE_MAGNET_RADIUS, 0.1)
end

-- The player's current snapshot, or nil. ctx.data:get is a synchronous in-memory session lookup
-- (no yield), so it is safe on the hot Collect path. A session that is not loaded yet returns nil
-- and every reader falls back to its base — a join race must never look like an infinite backpack.
local function snapshotOf(ctx: any, player: any): any
	local got = ctx.data:get(player)
	if got == nil or not got.ok then
		return nil
	end
	return got.value
end

-- WHERE the player is standing, server-derived. nil means "unknown / not on an island".
local function islandOf(ctx: any, player: any): number?
	local world = ctx.world
	if world == nil or type(world.islandOf) ~= "function" then
		return nil -- no world wired (Lune, focused tests): position is simply not a factor
	end
	local ok, islandId = pcall(world.islandOf, world, player)
	if not ok or type(islandId) ~= "number" then
		return nil
	end
	return islandId
end

-- The per-mote value at the player's CURRENT position. Positional: the island multiplier is read
-- from the island they are STANDING ON, not the richest one they own. The permanent Prism yield
-- rides here too, so a prestige purchase is felt on the very next mote rather than at the till.
local function moteValueFor(ctx: any, d: any, islandId: number?): number
	local islandMult = 1
	if ctx.islands ~= nil and d ~= nil then
		local ok, value = pcall(function()
			return (ctx.islands :: any):multiplierFor(d, islandId)
		end)
		if ok then
			islandMult = seamMultiplier(value)
		end
	end
	-- Today's rich vein is POSITIONAL too, and for the same reason: it is supposed to be a reason
	-- to go somewhere. Banked per mote against the island the player was standing on, so a vein on
	-- island 3 pays for motes gathered on island 3 — not for everything you do anywhere because
	-- you happen to own island 3.
	local restockMult = 1
	if ctx.restock ~= nil and d ~= nil then
		local ok, value = pcall(function()
			return (ctx.restock :: any):multiplierFor(d, ctx.clock:unix(), islandId)
		end)
		if ok then
			restockMult = seamMultiplier(value)
		end
	end
	local yieldMult = tuningFrom(ctx, d, "yieldMultiplierFor", 1, 0)
	return MOTE_VALUE * islandMult * restockMult * yieldMult
end

local CollectionService = { name = "CollectionService" }

export type CollectReply = {
	count: number,
	capacity: number,
	full: boolean,
	-- How many motes THIS call actually granted. 0 is a legitimate, non-error outcome: the player
	-- asked before the server clock had produced another mote. This field is the delta a test
	-- asserts on, and the number of motes the client animates into the player.
	granted: number,
	-- The Stardust the backpack is currently worth (already island-multiplied at collect time).
	value: number,
	islandId: number,
	-- What a mote is worth HERE, versus the starting island. The HUD shows it, because "richer
	-- motes further out" is a spec promise the player had no way to observe.
	islandMultiplier: number,
	-- Server-owned tuning, echoed so the client never holds its own copy of these numbers. The
	-- magnet radius and the collect period WERE client constants sitting beside the persisted
	-- levels that were supposed to control them.
	magnetRadius: number,
	collectPeriod: number,
}

-- Build the Collect action as a closure over the shared per-player state.
-- Payload: {} — no client-supplied data whatsoever. The server decides how many motes the caller
-- has earned (from its own clock) and what they are worth (from the caller's own position).
local function makeCollectAction(
	backpacks: { [number]: Backpack },
	collectCredit: { [number]: number },
	lastSeenMono: { [number]: number }
): Net.Action<{}, CollectReply>
	return {
		name = Net.Actions.Collect, -- "collect.gather"
		-- Defence in depth only. The economy is governed by the clock gate in the handler; this
		-- bucket exists so a flood costs the server nothing, not so it costs the player nothing.
		rate = { maxPerWindow = 20, windowSeconds = 1, burst = 30 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(ctx, _payload): Result.Result<CollectReply>
			local userId = ctx.player.UserId
			local pack = backpacks[userId] or emptyBackpack()
			local d = snapshotOf(ctx, ctx.player)

			-- ----- POSITION GATE -----
			-- A collect must happen SOMEWHERE. When a world is wired and the player is over the
			-- void (or has no character), there is nothing to collect and the request is refused.
			-- When no world is wired at all — Lune, focused specs — position is not a factor and
			-- the island falls back to the starting island's value.
			local hasWorld = ctx.world ~= nil and type((ctx.world :: any).islandOf) == "function"
			local islandId = islandOf(ctx, ctx.player)
			if hasWorld and islandId == nil then
				return Result.err(Result.Codes.Rejected, "no motes out here — stand on an island")
			end

			-- ONE read of each tuning value, used for BOTH enforcement and the number reported to
			-- the client. Deliberate: the two drifting apart is exactly the class of bug this file
			-- exists to kill (the HUD said "50" while the shop sold levels nothing enforced).
			local capacity = capacityFrom(ctx, d)
			local period = collectPeriodFrom(ctx, d)
			local magnetRadius = magnetRadiusFrom(ctx, d)

			local islandMultiplier = moteValueFor(ctx, d, islandId) / MOTE_VALUE

			local function reply(granted: number): Result.Result<CollectReply>
				return Result.ok({
					count = pack.count,
					capacity = capacity,
					full = pack.count >= capacity,
					granted = granted,
					value = pack.value,
					islandId = islandId or 1,
					islandMultiplier = islandMultiplier,
					magnetRadius = magnetRadius,
					collectPeriod = period,
				})
			end

			if pack.count >= capacity then
				return Result.err(Result.Codes.OutOfRange, "backpack full")
			end

			-- ----- THE CLOCK GATE (the anti-exploit that replaced "one mote per request") -----
			-- Credit is accumulated in MOTES, not in seconds. Two reasons, both load-bearing:
			--   * `collectPeriod` changes the moment a collect-speed level is bought, so seconds
			--     banked under the old period would silently convert at the new rate.
			--   * a seconds-based ledger has to compare `now - (now - period)` against `period`,
			--     and in floating point that lands a hair BELOW it — so the very first collect of
			--     every session floored to zero and the player's opening sale was empty.
			local now = ctx.clock:mono()
			local credit = collectCredit[userId]
			local seen = lastSeenMono[userId]
			if credit == nil or seen == nil then
				-- First collect of the session is instant, so arriving somewhere feels responsive.
				credit = 1
				seen = now
			end
			local elapsed = math.max(0, now - seen)
			-- Idling does not bank motes: the ceiling is small, so the player collects by BEING
			-- somewhere rather than by waiting somewhere.
			credit = math.min(credit + elapsed / period, MAX_BANKED_MOTES)
			lastSeenMono[userId] = now

			local allowed = math.floor(credit)
			if allowed < 1 then
				-- Nothing has accrued yet. NOT an error: the client polls faster than the server
				-- mints, by design. `granted = 0` is the honest answer and the delta a test reads.
				collectCredit[userId] = credit
				return reply(0)
			end

			local room = capacity - pack.count
			local granted = math.min(allowed, room, MAX_GRANT_PER_CALL)
			-- Spend EXACTLY what was paid out; the fractional remainder carries forward, so a grant
			-- can never run ahead of real elapsed server time and progress is never silently lost.
			collectCredit[userId] = credit - granted

			pack.count += granted
			pack.value += granted * moteValueFor(ctx, d, islandId)
			backpacks[userId] = pack
			return reply(granted)
		end,
	}
end

-- Build the Sell action as a closure over the shared backpack table.
-- Payload: {} — sell converts the CALLER's whole backpack. Returns {sold, earned, balance}.
local function makeSellAction(
	backpacks: { [number]: Backpack }
): Net.Action<{}, { sold: number, earned: number, balance: number }>
	return {
		name = Net.Actions.Sell, -- "collect.sell"
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
			local pack = backpacks[userId] or emptyBackpack()
			local count = pack.count
			if count <= 0 then
				local current = ctx.data:get(ctx.player)
				if not current.ok then
					return current
				end
				return Result.ok({
					sold = 0,
					earned = 0,
					balance = (current.value.currencies.Stardust or 0),
				})
			end

			-- ----- CONCURRENCY-SAFE SELL -----
			-- ctx.data:update can YIELD on the per-player lock queue. If we read the count, called
			-- update (yield), then zeroed the backpack AFTER, two interleaved sells would each see
			-- the SAME non-zero count and double-grant. So we EMPTY the backpack BEFORE the
			-- (possibly yielding) update: any second sell that interleaves sees an empty backpack.
			local bankedValue = pack.value
			backpacks[userId] = emptyBackpack()

			-- ----- THE CONSOLIDATED EARN FORMULA -----
			-- earned = bankedValue * restockMult * stardustMult * (1 + rebirths*STEP).
			-- The ISLAND multiplier is NOT here: it was applied per mote at COLLECT time, against
			-- the island the player was actually standing on. Every remaining factor is read
			-- NIL-SAFELY (default 1) from its seam, and `rebirths` from the LOCK-HELD snapshot, so
			-- with no seams wired and rebirths == 0 earned == count*MOTE_VALUE EXACTLY (the
			-- existing tests' invariant).
			local now = ctx.clock:unix()
			local earned = 0

			local updated = ctx.data:update(ctx.player, function(d)
				local stardustMult = 1
				if ctx.monetization ~= nil then
					stardustMult =
						seamMultiplier((ctx.monetization :: any):stardustMultiplierFor(d, now))
				end
				-- The rebirth multiplier is READ FROM ITS SEAM, like every other factor in this
				-- formula. It used to be a second copy of the curve computed inline here, and the
				-- two copies did not agree: `RebirthSeam.multiplierFor` clamps with
				-- `math.max(0, math.floor(rebirths))` and this line did not, so a negative or
				-- fractional `rebirths` paid differently depending on which copy you asked. The
				-- factory reachability gate reported the seam as ORPHANED — that was the symptom;
				-- the duplicated rule was the defect. The fallback below is the clamped form, so
				-- the two paths now agree even with no seam wired.
				local rebirthMult
				if ctx.rebirth ~= nil then
					rebirthMult = seamMultiplier((ctx.rebirth :: any):multiplierFor(d))
				else
					rebirthMult = 1 + math.max(0, math.floor(d.rebirths or 0)) * REBIRTH_STEP
				end
				earned = math.floor(bankedValue * stardustMult * rebirthMult)
				d.currencies.Stardust = (d.currencies.Stardust or 0) + earned
				if d.stats ~= nil then
					d.stats.lifetimeStardust = (d.stats.lifetimeStardust or 0) + earned
				end
				return d
			end)

			if not updated.ok then
				-- The grant FAILED: restore the captured motes so the player keeps them. Add back
				-- rather than overwrite (motes may have auto-collected during the yield), and clamp
				-- the COUNT to the player's CURRENT capacity — re-read here rather than reusing a
				-- pre-yield value, because a BuyUpgrade could have landed in between and clamping
				-- to the stale smaller number would destroy motes the player now has room for.
				local capacity = capacityFrom(ctx, snapshotOf(ctx, ctx.player))
				local current = backpacks[userId] or emptyBackpack()
				local restoredCount = math.min(capacity, current.count + count)
				-- Restore value in proportion to the motes that actually fit, so a clamp can never
				-- leave the player holding 10 motes worth 50 motes of Stardust.
				local keptFraction = if count > 0
					then (restoredCount - current.count) / count
					else 0
				backpacks[userId] = {
					count = restoredCount,
					value = current.value + bankedValue * math.clamp(keptFraction, 0, 1),
				}
				return updated
			end

			local balance = updated.value.currencies.Stardust

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

-- Build the auto-collect ticker as a closure over the SAME backpack table the actions share.
-- Deterministic, clock-driven, gamepass-gated. Returns the number of motes granted so a test can
-- assert the grant through the fake clock.
local function makeAutoCollectTicker(backpacks: { [number]: Backpack })
	local lastMono: { [number]: number } = {}
	return function(ctx: any, player: any): number
		local userId = player.UserId
		local now = ctx.clock:mono()
		local previous = lastMono[userId]
		if previous == nil then
			lastMono[userId] = now -- anchor the clock; no elapsed window yet
			return 0
		end

		local d = snapshotOf(ctx, player)
		local hasPass = d ~= nil and d.flags ~= nil and d.flags[AUTO_COLLECT_FLAG] == true
		local elapsed = now - previous
		if not hasPass then
			lastMono[userId] = now
			return 0
		end

		-- Capacity for THIS ticked player. Deliberately not the ctx.player helper: the ticker walks
		-- every live player, so ctx.player is not necessarily `player`.
		local capacity = capacityFrom(ctx, d)
		local pack = backpacks[userId] or emptyBackpack()
		local granted, carry = autoCollectGrant(elapsed, pack.count, capacity)
		lastMono[userId] = now - carry -- advance by CONSUMED time only; remainder never dropped
		if granted > 0 then
			pack.count += granted
			pack.value += granted * moteValueFor(ctx, d, islandOf(ctx, player))
			backpacks[userId] = pack
		end
		return granted
	end
end

-- Start: construct the actions as closures over one shared backpack table, then register each.
function CollectionService:Start(context: any): ()
	local backpacks: { [number]: Backpack } = {}
	-- Per-player collect ledger: `collectCredit` is unspent motes (fractional), `lastSeenMono` is
	-- the server-mono time the credit was last accrued to. Both are cleared on leave.
	local collectCredit: { [number]: number } = {}
	local lastSeenMono: { [number]: number } = {}
	context.net:register(makeCollectAction(backpacks, collectCredit, lastSeenMono))
	context.net:register(makeSellAction(backpacks))
	self.tickAutoCollect = makeAutoCollectTicker(backpacks)

	-- Exposed so a test (and the T2.5 lane) can read the authoritative backpack without a Collect
	-- round trip, and so the session-cleanup below has one named place to reach.
	self.backpackOf = function(_self: any, userId: number): Backpack
		return backpacks[userId] or emptyBackpack()
	end
	self.forgetPlayer = function(_self: any, userId: number): ()
		backpacks[userId] = nil
		collectCredit[userId] = nil
		lastSeenMono[userId] = nil
	end

	-- ----- RUNTIME-ONLY (Roblox-only; a strict no-op under Lune) -----
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return
	end
	local Players = realGame:GetService("Players")

	-- SESSION LIFECYCLE. These tables used to grow one entry per unique visitor for the server's
	-- lifetime, and a rejoining player inherited a server-side backpack their HUD knew nothing
	-- about — the HUD read 0 over a server holding 50, which then latched "backpack full"
	-- immediately. Clearing on leave makes the in-memory state match what the player is shown.
	Players.PlayerRemoving:Connect(function(player: any): ()
		self:forgetPlayer(player.UserId)
	end)

	-- Pass the LIVE context, not a snapshot of its seams. CollectionService starts BEFORE
	-- UpgradesShopService and WorldService, so a copied table would have captured
	-- `upgrades = nil, islands = nil, world = nil` forever — the auto-collect a player paid real
	-- money for would silently ignore their backpack level and their island. The per-request
	-- ActionContext already reads the seams live; the ticker must do the same.
	realTask.spawn(function(): ()
		while true do
			for _, player in Players:GetPlayers() do
				-- Isolate each tick: a throw for ONE player must not unwind the loop and silently
				-- kill auto-collect server-wide.
				pcall(self.tickAutoCollect, context, player)
			end
			realTask.wait(AUTO_COLLECT_DRIVE_INTERVAL)
		end
	end)
end

return CollectionService
