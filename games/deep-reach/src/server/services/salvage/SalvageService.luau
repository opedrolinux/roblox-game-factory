--!strict
-- games/deep-reach/src/server/services/salvage/SalvageService.luau   [feature: salvage core]
--
-- THE authoritative owner of the income engine: the smelter tick, the DERIVED income rate, the
-- capacity ceiling, and the ONE grant path that empties the smelter into the player's balance.
-- Replaces the contract-pass stub in place, preserving every contract decision the stub pinned: the
-- two action names (Net.Actions.CollectSmelter / Net.Actions.FetchSalvage), their RatePolicies
-- ({5, 1.0s} and {10, 1.0s}), the closure-based registration, and the SEPARATE seam table literally
-- named `SalvageSeam` with rateFor / capacityFor (never `context.salvage = self`: that publishes the
-- ident `self`, which gate-reachability's seam rules cannot attribute to a method definition, so they
-- discover zero subjects and fail blind).
--
-- ── ACCRUAL IS NOT AN EARN. THE DISTINCTION THIS WHOLE FILE TURNS ON ─────────────────────────────
-- `smelter.storedCredits` is UN-COLLECTED OUTPUT, not a currency. Accruing into it must NOT touch
-- data.currencies, must NOT move stats.lifetimeCredits and must NOT emit currency_earned — it is a
-- number sitting in a machine. The EARN happens exactly once, when the smelter is emptied, through
-- `ctx.economy:earn(data, "Credits", amount, "smelt")`, which increments stats.lifetimeCredits (the
-- leaderboard's ranking key) and emits currency_earned itself. Getting this backwards double-counts
-- the ranking key: every credit would be counted when it accrues AND again when it is collected.
-- Nothing in this file writes data.currencies, data.stats or ctx.analytics directly — with ONE
-- exception, which is not an earn but its UNDO: `grantStored` rolls the earn-side state back to the
-- value it captured when the earn it just made REFUSES (see the rollback there). It never invents a
-- balance; it can only restore one.
--
-- ── WHAT THIS SLICE OWNS ────────────────────────────────────────────────────────────────────────
--  1. THE TICK, and it is the ONLY tick loop in this game. ONE server-wide loop over the live roster
--     (never one loop per player), cadence TICK_INTERVAL_SECONDS on the injected server clock. Per
--     player per tick, inside ONE ctx.data:update:
--         stored = math.min(capacityFor(data), stored + rateFor(data) * (now - smelter.lastTickUnix))
--         smelter.lastTickUnix = now
--     It runs whether or not the player is standing there.
--  2. THE RATE AS A DERIVED FUNCTION, never a persisted field. See `rateAt` — it is re-evaluated on
--     every tick and every fetch from the blob alone.
--  3. THE SMELTER's capacity, from `upgrades.smelter`, clamped on EVERY tick: a full smelter stops
--     accruing, which is what makes the capacity upgrade matter (and what bounds offline accrual).
--  4. COLLECTING — `salvage.collect`, and the auto-collect gamepass path, through ONE grant function.
--  5. THE HANDOFF WITH OFFLINE ACCRUAL — the away window [timestamps.lastSeenUnix, now] belongs
--     EXCLUSIVELY to Offline accrual, so this service stamps `smelter.lastTickUnix = now` at session
--     load, BEFORE its first accruing tick (see ARMING below).
--  6. THE OBSERVATION SURFACE — `salvage.fetch` returns the derived rate, stored and capacity. This is
--     the value every later feature's success criterion asserts a delta on.
--  7. THE WORLD — the smelter, the conveyor and the drones as greybox Parts under
--     `ctx.plot:rootFor(player)`, drones on TweenService paths. Cosmetic ONLY: no client input and no
--     client timing can influence the rate (the salvage-rate spoof).
--
-- NOT THIS SLICE: selling upgrades or setting prices (Structures shop — it WRITES the upgrade levels
-- read here); the depth tier value table and the restock rotation (Depth tiers — consumed through the
-- nil-safe ctx.depth seam); the away-window computation (Offline accrual); granting the gamepass flags
-- (Monetization — they are only READ here).
--
-- ── THE MULTIPLIERS MUST ALL REACH THE NUMBER ───────────────────────────────────────────────────
-- Every input rateAt reads is from a feature built AFTER this one, so every one of them is
-- absent-safe and defaults to a NEUTRAL value — and every one genuinely reaches the returned number,
-- so when those features land they change the rate with ZERO edit to this file. A multiplier that is
-- read but never applied is the written-never-read defect this game exists to catch, so the inputs are
-- listed here against the line that applies them:
--     upgrades.drones      -> droneCount   (linear, `baseRateOf`)
--     upgrades.pearlDrones -> pearl drones (linear at a higher per-drone rate, `baseRateOf`)
--     upgrades.conveyor    -> throughput multiplier            (`multiplierAt`)
--     data.resurfaces      -> permanent prestige multiplier    (`multiplierAt`)
--     flags["gamepass.doubleCredits"] -> x2, read STRAIGHT OFF THE BLOB (no seam to race)
--     now < data.boostExpiresUnix     -> x2, read STRAIGHT OFF THE BLOB
--     ctx.depth:valueMultiplier(data, now) -> per-tier + restock, NIL-SAFE (absent today -> 1x, which
--         is the FRESH-PLAYER case, not a fallback)
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The dupe this feature is one mistake away from is the most exploitable path in the game: read
-- smelter.storedCredits, YIELD in ctx.data:update, then earn that amount and zero it. Two collects in
-- the same frame both read the same non-zero stored before either writes, and the smelter pays twice
-- for one fill — forever, once per spam burst. Three independent mechanisms close it, and they fail in
-- different directions:
--
--   (1) THE CAPTURE, THE ZERO AND THE EARN ARE ONE LOCK-HELD TRANSFORM. Nothing outside `grantStored`
--       reads or writes smelter.storedCredits on a collect path. DataService:update runs the transform
--       under the per-player FIFO lock against a snapshot RE-READ after any earlier update has written
--       (MockStore/SessionStore §4.1 step 2), and the transform is synchronous — it contains no yield
--       of any kind. So the SECOND collect's transform necessarily observes stored == 0 and returns
--       Err(Insufficient), and n spam-duplicated collects total EXACTLY the stored amount. This is the
--       load-bearing guarantee; it holds even if (2) is deleted. This is also why the amount is
--       captured INSIDE the transform rather than before it: a value read before the yield would be
--       the stale one, and paying it out is precisely the double-grant.
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION taken BEFORE the update can yield (`self._collecting`,
--       the same reserve-before-yield discipline PlotService uses for a dome and DailyDropService for
--       the drop). Luau is single-threaded, so the flag is visible to every interleaved request the
--       instant it is set, and a duplicate that arrives while the first is parked in the store is
--       refused with Err(Insufficient) — the same code the empty smelter it is about to find would
--       return — without ever reaching the data layer. Belt-and-braces for (1), never a substitute: it
--       is per-SERVER memory and says nothing about the same player on another server.
--   (3) THE RESTORE IS A FULL ROLLBACK, AND IT CANNOT BREACH THE CAP. `grantStored` zeroes first and
--       calls earn LAST (earn emits currency_earned as its final act, so no later statement in the
--       transform can discard a snapshot the event already described). If earn REFUSES, the captured
--       amount is written back — re-clamped to capacityFor(data) — AND the earn-side state (the
--       Credits balance, stats.lifetimeCredits) is rolled back to what it held before the attempt,
--       and the outcome is the Err. The rollback is the load-bearing half: `earn` is NOT
--       atomic-or-nothing on every branch (EconomyService writes `map[currency] = before + amount`
--       and only THEN discovers a missing `stats` table), so restoring ONLY the smelter would leave
--       the same amount in the tank AND in the balance — a mint of exactly one smelter per refused
--       collect, repeatable, and invisible to stats.lifetimeCredits. This file may not assume the
--       seam is atomic; it makes ITS OWN transaction atomic. Since the capture, the zero and the
--       restore all happen on ONE snapshot under the lock, capacity cannot have moved between them,
--       so the clamp is a belt on a fact that already holds. If the WRITE fails, the store discards
--       the whole snapshot: nothing was zeroed or credited durably and there is nothing to
--       compensate — that restore is the store's, and it is atomic.
--
-- The reservation is cleared on EVERY path (the update is pcall'd purely so a throw cannot strand it
-- set, which would lock that player out of their own smelter for the life of the server).
--
-- ── ARMING: WHY THE FIRST TICK OF A SESSION CREDITS NOTHING ─────────────────────────────────────
-- `smelter.lastTickUnix` is PERSISTED, so a rejoining player's blob carries a stamp from their last
-- session — and a migrated blob carries 0 (Migrations step [4] seeds it that way, and its comment
-- names this service as the reason that is safe). An accruing tick against either would credit the
-- away window a SECOND time (Offline accrual already owns it) or ~56 years of it. So a session is
-- ARMED before it accrues: the first thing this service does for a player is stamp
-- lastTickUnix = now and credit NOTHING. Two paths arm, and they converge on the same stamp:
--     * the join hook (`armOnJoin`), which waits out loadSession's yield and arms immediately, and
--     * `tickPlayer` itself, which arms on FIRST SIGHT of an un-armed player.
-- The second is not redundancy for its own sake: the join hook is Roblox-only, and a player already
-- present when this service Starts (a Studio Play session installs scripts after the local player
-- joins) has no PlayerAdded to ride.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- Every decision in this file is Roblox-FREE: rateAt / capacityOf / multiplierAt / accrue /
-- grantStored / collect / fetch / tickPlayer / tickAll / armFor and both seam methods run under Lune
-- with Mocks.player + a real DataService over MockStore and no engine at all (inject a roster with
-- `service._players`). Only `startRuntime`, the join hook's waiter and the world builders touch
-- `game` / `task` / `Instance`, each through a guarded local, so requiring and Starting this module
-- under Lune never throws.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT Rojo service root than
-- this ServerScriptService module — so the relative string cannot reach it there; require by instance.
-- Under Lune (script == nil) the filesystem path resolves.
local Net, Result, Types
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
	Types = require("../../../shared/Types")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
	Types = require((Shared :: any).Types)
end

local SalvageService = {}
SalvageService.name = "SalvageService"

-- ── tunables (SERVER constants; the client never sends or influences any of them) ────────────────

-- The tick cadence, in SERVER seconds. One loop for the whole server (see startRuntime).
local TICK_INTERVAL_SECONDS = 1

-- The starter drone that comes with the dome. WITHOUT IT THE GAME HAS NO ENTRY POINT: the first
-- purchase costs Credits, and Credits only exist because a drone salvaged them, so a fresh player with
-- zero drones has an income of exactly zero forever. One drone is the seed of the loop; every drone
-- after it is bought (Structures shop), and the purchased ones are what the "purchased structures
-- change the income rate" criterion asserts a delta on.
local STARTER_DRONES = 1

-- Credits per second per drone, before any multiplier. A fresh dome therefore earns
-- STARTER_DRONES * DRONE_RATE = 0.5/s, i.e. a first collect worth having inside a minute and a full
-- BASE_CAPACITY smelter in ~8 minutes.
local DRONE_RATE = 0.5
-- Pearl drones (`upgrades.pearlDrones`) are the prestige-only hauler: same linear shape, 5x the pull.
local PEARL_DRONE_RATE = 2.5

-- Each conveyor level moves fragments faster: +15% throughput, applied to the WHOLE drone fleet.
local CONVEYOR_STEP = 0.15
-- Each resurface is worth a permanent +10%. Read from `data.resurfaces` (the prestige COUNT), never
-- from currencies.Pearls (which is spent down and would make the multiplier shrink when it is used).
local RESURFACE_STEP = 0.10

-- The two 2x's. Both are read STRAIGHT OFF THE BLOB — no seam, so there is nothing to race — and both
-- are OWNED BY MONETIZATION, which only ever SETS them. This file only reads.
local DOUBLE_CREDITS_FLAG = "gamepass.doubleCredits"
local AUTO_COLLECT_FLAG = "gamepass.autoCollect"
local DOUBLE_CREDITS_MULTIPLIER = 2
local BOOST_MULTIPLIER = 2

-- Smelter storage. Base is non-zero so a player who has bought nothing still has somewhere to put the
-- starter drone's output; each `upgrades.smelter` level adds another BASE-sized tank.
local BASE_CAPACITY = 250
local CAPACITY_PER_LEVEL = 250

-- Upgrade levels are clamped before they reach any arithmetic. A blob is data off a DataStore, and a
-- level of 1e308 (or NaN) would otherwise turn the rate into inf/NaN and PERSIST it: NaN >= cost is
-- false forever, so a poisoned balance can never be spent again.
local MAX_UPGRADE_LEVEL = 10000

-- THERE IS NO SEPARATE BOUND ON THE COUNTED SPAN, and that is deliberate. A `MAX_TICK_ELAPSED_SECONDS
-- = 3600` clamp used to sit here as a "diagnostic" on a forward clock jump; it was DELETED because it
-- silently diverged from the slice's verbatim formula, which counts the whole of
-- (now - smelter.lastTickUnix) and bounds the result by capacity alone. It never defended anything the
-- capacity clamp did not already bound to one full smelter (ARMING and the leave hook are what keep
-- the away window out — see the header), and on a big tank (upgrades.smelter >= 15, capacity >= 4000)
-- it was the clamp rather than the ceiling that decided the number: a real income shortfall the
-- contract does not sanction, invisible on every small tank a test happened to use.

-- The earn-path label carried on currency_earned. Identical on BOTH collect triggers by contract —
-- the trigger is reported on the reply, never used for math and never used as the source.
local EARN_SOURCE = "smelt"
local EARN_CURRENCY = "Credits"

SalvageService.TICK_INTERVAL_SECONDS = TICK_INTERVAL_SECONDS
SalvageService.STARTER_DRONES = STARTER_DRONES
SalvageService.DRONE_RATE = DRONE_RATE
SalvageService.PEARL_DRONE_RATE = PEARL_DRONE_RATE
SalvageService.CONVEYOR_STEP = CONVEYOR_STEP
SalvageService.RESURFACE_STEP = RESURFACE_STEP
SalvageService.BASE_CAPACITY = BASE_CAPACITY
SalvageService.CAPACITY_PER_LEVEL = CAPACITY_PER_LEVEL
SalvageService.DOUBLE_CREDITS_FLAG = DOUBLE_CREDITS_FLAG
SalvageService.AUTO_COLLECT_FLAG = AUTO_COLLECT_FLAG
SalvageService.EARN_SOURCE = EARN_SOURCE

-- THE upgrade keys this service reads. Published so the Structures shop writes the SAME keys: a shop
-- that wrote `upgrades.drone` would persist a purchase that changes no rate at all — inert, and green
-- against any test that only asserts the field moved.
SalvageService.UPGRADE_KEYS = {
	drones = "drones",
	conveyor = "conveyor",
	pearlDrones = "pearlDrones",
	smelter = "smelter",
}

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

-- The ServerContext, captured at Start. The seam and the tick need ctx.depth / ctx.economy / net, and
-- the ActionContext projection deliberately carries no `net`.
SalvageService._context = nil :: any
-- userId -> the SERVER unix stamp at which this session was armed. An un-armed player accrues NOTHING
-- (see ARMING in the header). Pruned in tickAll against the live roster, so it cannot grow unbounded
-- over a server's lifetime.
SalvageService._armed = {} :: { [number]: number }
-- userId -> how many times this player has DEPARTED on this server. Monotonic, never cleared.
--
-- `disarmFor` alone is not enough, and the ordering is the whole reason. `tickPlayer` writes
-- `_armed[userId]` AFTER `ctx.data:update` returns, and that update YIELDS — so a leave landing inside
-- the yield clears a flag that is not set yet, and the write then re-arms A PLAYER WHO IS GONE. Their
-- rejoin finds `armFor` idempotent on that key, is never stamped, and the first accruing tick credits
-- the ABSENCE from the pre-departure `lastTickUnix` — the same span OfflineService grants. Paid twice.
--
-- `_armed` cannot detect this itself: it is empty both BEFORE a session arms and AFTER it is disarmed,
-- so it cannot tell those two apart. A counter can, and a tick that captured it before yielding can.
-- Same fix and same argument as AnalyticsService's join hook and PlotService's claim path.
SalvageService._departures = {} :: { [number]: number }
-- userId -> true while that player's collect is parked inside ctx.data:update (mechanism (2)).
SalvageService._collecting = {} :: { [number]: boolean }
-- userId -> true while that player's TICK is parked inside ctx.data:update. A tick that is still
-- waiting on the store when the next cadence fires must not be entered twice: both would read the same
-- lastTickUnix and the elapsed span would be credited twice.
SalvageService._ticking = {} :: { [number]: boolean }
-- TEST SEAM: an optional roster provider, `() -> { PlayerLike }`. nil in production, where the roster
-- is the engine's Players service. A spec has no engine and must still drive a full server's ticks.
SalvageService._players = nil :: (() -> { any })?
SalvageService._running = false
SalvageService._connections = {} :: { any }

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6). Identity is
-- taken from the FIELD, which both a live Player and Mocks.player answer.
local function userIdOf(player: any): number?
	if player == nil then
		return nil
	end
	local userId = (player :: any).UserId
	if type(userId) ~= "number" or userId ~= userId then
		return nil
	end
	if userId == math.huge or userId == -math.huge then
		return nil
	end
	return math.floor(userId)
end

local function isUsableNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitizeNow(value: any): number?
	if not isUsableNumber(value) then
		return nil
	end
	return math.floor(value)
end

-- A non-negative finite amount. Garbage (nil / NaN / infinite / negative) reads as 0 rather than
-- poisoning the accrual arithmetic and persisting the poison.
local function sanitizeAmount(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return value
end

-- A purchased level: a non-negative integer, clamped. See MAX_UPGRADE_LEVEL.
local function sanitizeLevel(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return math.min(math.floor(value), MAX_UPGRADE_LEVEL)
end

-- The persisted level of one upgrade key, normalized. An absent `upgrades` map reads as all-zero,
-- which is exactly the fresh-player state Migrations seeds.
local function levelOf(data: any, key: string): number
	if type(data) ~= "table" or type(data.upgrades) ~= "table" then
		return 0
	end
	return sanitizeLevel(data.upgrades[key])
end

-- A persisted boolean flag, read STRAIGHT OFF THE BLOB. Only ever true when Monetization has granted
-- it server-side; an absent flags map reads false.
local function flagOf(data: any, key: string): boolean
	if type(data) ~= "table" or type(data.flags) ~= "table" then
		return false
	end
	return data.flags[key] == true
end

-- The `smelter` record, NORMALIZED IN PLACE, so every caller downstream can assume two numbers. A
-- missing/garbage record is repaired rather than thrown on: an error raised inside a lock-held
-- transform discards the whole write and surfaces as an opaque Internal.
local function smelterOf(data: any): any
	if type(data) ~= "table" then
		return { storedCredits = 0, lastTickUnix = 0 }
	end
	local smelter = data.smelter
	if type(smelter) ~= "table" then
		smelter = { storedCredits = 0, lastTickUnix = 0 }
		data.smelter = smelter
	end
	if not isUsableNumber(smelter.storedCredits) or smelter.storedCredits < 0 then
		smelter.storedCredits = 0
	end
	if not isUsableNumber(smelter.lastTickUnix) or smelter.lastTickUnix < 0 then
		smelter.lastTickUnix = 0
	end
	return smelter
end

-- A READ-ONLY reading of the smelter record: the same normalization smelterOf applies, computed into
-- a FRESH table instead of written into the blob. `describe`/`fetch` run on the LIVE session blob
-- (DataService.get returns session.data itself, not a copy) OUTSIDE any ctx.data:update, so repairing
-- garbage there would be an unlocked write on the single-writer path (CLAUDE.md §4) from a
-- client-callable read action — and a pointless one, since every transform works on a deepCopy
-- snapshot it commits wholesale, so any concurrent update silently discards the repair anyway.
-- Sanitize the REPLY; leave the RECORD to the tick, which repairs it under the lock.
local function readSmelter(data: any): { storedCredits: number, lastTickUnix: number }
	local stored = 0
	local lastTick = 0
	if type(data) == "table" and type(data.smelter) == "table" then
		local smelter = data.smelter
		if isUsableNumber(smelter.storedCredits) and smelter.storedCredits >= 0 then
			stored = smelter.storedCredits
		end
		if isUsableNumber(smelter.lastTickUnix) and smelter.lastTickUnix >= 0 then
			lastTick = smelter.lastTickUnix
		end
	end
	return { storedCredits = stored, lastTickUnix = lastTick }
end

-- The earn-side state of a snapshot, READ without touching it, so a refused earn can be rolled back
-- to exactly what this transform found. Nil is a legitimate captured value (an absent key), and
-- restoring nil restores absence.
local function earnStateOf(data: any): (any, any)
	local balance: any = nil
	local lifetime: any = nil
	if type(data) == "table" then
		if type(data.currencies) == "table" then
			balance = data.currencies[EARN_CURRENCY]
		end
		if type(data.stats) == "table" then
			lifetime = data.stats.lifetimeCredits
		end
	end
	return balance, lifetime
end

-- The UNDO of a refused earn (mechanism (3)). Only ever writes values captured off THIS snapshot
-- moments earlier, and only when they actually moved — it can restore a balance, never invent one.
local function restoreEarnState(data: any, balance: any, lifetime: any): ()
	if type(data) ~= "table" then
		return
	end
	if type(data.currencies) == "table" and data.currencies[EARN_CURRENCY] ~= balance then
		data.currencies[EARN_CURRENCY] = balance
	end
	if type(data.stats) == "table" and data.stats.lifetimeCredits ~= lifetime then
		data.stats.lifetimeCredits = lifetime
	end
end

-- AMENDMENT: the ctx.depth read. NIL-SAFE and value-checked — Depth tiers is a LATER batch, so this
-- seam is ABSENT today and every rate takes the 1x default, which is the FRESH-PLAYER case and
-- therefore the common path, not a fallback. A garbage multiplier from a future Depth implementation
-- is refused rather than zeroing (or NaN-ing) the whole game's income.
local function depthMultiplier(depth: any, data: any, nowUnix: number): number
	if depth == nil or type(depth.valueMultiplier) ~= "function" then
		return 1
	end
	local ok, value = pcall(function()
		return depth:valueMultiplier(data, nowUnix)
	end)
	if ok and isUsableNumber(value) and value >= 0 then
		return value
	end
	return 1
end

-- ── THE DERIVED RATE (pure over the blob; never a persisted field) ──────────────────────────────

-- How many haulers this blob runs, and of which kind. Returned as two numbers rather than one total
-- because they earn at different rates.
function SalvageService.dronesOf(_self: any, data: any): (number, number)
	local drones = STARTER_DRONES + levelOf(data, SalvageService.UPGRADE_KEYS.drones)
	local pearlDrones = levelOf(data, SalvageService.UPGRADE_KEYS.pearlDrones)
	return drones, pearlDrones
end

-- Credits per second BEFORE any multiplier: the fleet's raw pull.
function SalvageService.baseRateOf(self: any, data: any): number
	local drones, pearlDrones = self:dronesOf(data)
	return drones * DRONE_RATE + pearlDrones * PEARL_DRONE_RATE
end

-- The composed multiplier at `nowUnix`. EVERY input listed in the header is applied HERE, and the
-- product is what `rateAt` multiplies the base by — so a later feature that starts writing one of
-- these fields moves the rate with no edit to this file.
function SalvageService.multiplierAt(_self: any, data: any, nowUnix: number, depth: any?): number
	local multiplier = 1

	-- upgrades.conveyor: faster belt, more fragments delivered per second.
	multiplier *= 1 + CONVEYOR_STEP * levelOf(data, SalvageService.UPGRADE_KEYS.conveyor)

	-- data.resurfaces: the PERMANENT prestige multiplier. The count, not the currency.
	local resurfaces = 0
	if type(data) == "table" then
		resurfaces = sanitizeLevel(data.resurfaces)
	end
	multiplier *= 1 + RESURFACE_STEP * resurfaces

	-- flags["gamepass.doubleCredits"]: straight off the blob.
	if flagOf(data, DOUBLE_CREDITS_FLAG) then
		multiplier *= DOUBLE_CREDITS_MULTIPLIER
	end

	-- now < boostExpiresUnix: the 30-min dev-product boost, PERSISTED so the expiry survives a rejoin.
	-- Compared against the SERVER clock only (CLAUDE.md §7) — there is no client number in this file.
	if type(data) == "table" and isUsableNumber(data.boostExpiresUnix) then
		if nowUnix < data.boostExpiresUnix then
			multiplier *= BOOST_MULTIPLIER
		end
	end

	-- ctx.depth: per-tier value + the daily restock rich wreck. Nil-safe; 1x today.
	multiplier *= depthMultiplier(depth, data, nowUnix)

	return multiplier
end

-- THE rate: Credits per second this blob's smelter produces right now. PURE over the persisted blob
-- (plus the server clock and the nil-safe depth seam) and re-evaluated on every tick and every fetch.
function SalvageService.rateAt(self: any, data: any, nowUnix: number, depth: any?): number
	local rate = self:baseRateOf(data) * self:multiplierAt(data, nowUnix, depth)
	if not isUsableNumber(rate) or rate < 0 then
		return 0
	end
	return rate
end

-- THE capacity: the smelter's storage ceiling. Pure over the blob; no clock, no seam.
function SalvageService.capacityOf(_self: any, data: any): number
	local capacity = BASE_CAPACITY
		+ CAPACITY_PER_LEVEL * levelOf(data, SalvageService.UPGRADE_KEYS.smelter)
	if not isUsableNumber(capacity) or capacity < 0 then
		return 0
	end
	return capacity
end

-- ── ctx.salvage SEAM ────────────────────────────────────────────────────────────────────────────
-- Its OWN table, literally named `SalvageSeam`, installed on context.salvage at Start. THREE methods,
-- and no more, because a seam method with no reader is a dangling promise (gate-reachability R1) —
-- every one of these has readers: the tick and the fetch below call rateFor/capacityFor, later
-- batches read them too (the Structures shop asserts a rate DELTA through rateFor; Offline accrual
-- caps its away-window grant at capacityFor), and `disarmFor` is called by framework/PlayerLifecycle
-- as a step of the pinned leave order, exactly as PlotSeam.releaseFor is.
--
-- `nowUnix` and `depth` are OPTIONAL: the contract signature is rateFor(data), so a caller that has
-- neither still gets an answer — the captured ServerContext supplies the clock and the depth seam, and
-- a service that was never Started (a pure Tier-1 call) falls back to a boost-expired, 1x-depth
-- reading, which is deterministic rather than accidental.
local SalvageSeam = {}

-- Credits per second this blob's smelter currently produces.
function SalvageSeam.rateFor(_self: any, data: any, nowUnix: number?, depth: any?): number
	local context = SalvageService._context
	local now = sanitizeNow(nowUnix)
	if now == nil and context ~= nil and context.clock ~= nil then
		now = sanitizeNow(context.clock:unix())
	end
	local resolvedDepth = depth
	if resolvedDepth == nil and context ~= nil then
		resolvedDepth = context.depth
	end
	return SalvageService:rateAt(data, now or 0, resolvedDepth)
end

-- The smelter's storage ceiling for this blob.
function SalvageSeam.capacityFor(_self: any, data: any): number
	return SalvageService:capacityOf(data)
end

-- THE LEAVE HOOK. Drops every per-session memo this service holds for a departing player, so the NEXT
-- session on this same server is ARMED rather than inheriting the last one's armed flag.
--
-- Why it has to exist. `_armed` used to be cleared only by tickAll's prune, which runs once a cadence
-- and builds its `present` set at the START of the pass — so a player who left and rejoined before the
-- next pass (or who left mid-pass, and so survived that pass's prune too) came back with the flag
-- still set. `armFor` is idempotent on that key and returns WITHOUT stamping, so the first accruing
-- tick of the new session computed elapsed from the PERSISTED, pre-absence lastTickUnix and credited
-- the away window online — the same span OfflineService grants for
-- [timestamps.lastSeenUnix, now]. Paid twice, and it is precisely the invariant ARMING exists for.
--
-- Why it lives on the SEAM and not on a PlayerRemoving connection of our own: framework/PlayerLifecycle
-- is the one owner of that signal (AMENDMENT A10b) and its order is load-bearing, so salvage joins the
-- pinned sequence instead of racing it. The tickAll prune stays as the belt — it also covers a player
-- lost with no leave event at all.
function SalvageSeam.disarmFor(_self: any, player: any): boolean
	local userId = userIdOf(player)
	if userId == nil then
		return false
	end
	local wasArmed = SalvageService._armed[userId] ~= nil
	-- BUMP FIRST, before clearing anything. A tick parked inside its arming update captured the old
	-- value before it yielded; bumping here is what lets it discover, when it resumes, that the player
	-- it was arming has since left — and skip the write instead of re-arming a departed session.
	SalvageService._departures[userId] = (SalvageService._departures[userId] or 0) + 1
	SalvageService._armed[userId] = nil
	SalvageService._ticking[userId] = nil
	SalvageService._collecting[userId] = nil
	return wasArmed
end

SalvageService.seam = SalvageSeam

-- ── the accrual (mutates a transform's snapshot; NEVER an earn) ─────────────────────────────────

export type Accrual = {
	credited: number, -- output added to the smelter by THIS tick (never a currency)
	stored: number, -- post-accrual stored output
	capacity: number,
	rate: number,
	elapsed: number, -- the span actually counted, in SERVER seconds
	full: boolean,
}

-- ONE tick of accrual, applied IN PLACE to a transform's snapshot. Synchronous by construction: no
-- yield, no data call, no engine call. It touches ONLY data.smelter — never currencies, never
-- stats.lifetimeCredits, never ctx.analytics (see the header).
--
-- The clamp is `math.min(capacity, ...)` UNCONDITIONALLY, not just when something accrued: capacity
-- can SHRINK (a resurface wipes upgrades.smelter), and stored above the ceiling is an invariant
-- violation the offline cap and the capacity upgrade both depend on.
function SalvageService.accrue(_self: any, data: any, nowUnix: number, depth: any?): Accrual
	local smelter = smelterOf(data)
	local capacity = SalvageSeam:capacityFor(data)
	local rate = SalvageSeam:rateFor(data, nowUnix, depth)
	local stored = sanitizeAmount(smelter.storedCredits)

	local last = smelter.lastTickUnix
	local elapsed = 0
	-- A stamp of 0 is "never ticked" (Migrations seeds it) and credits nothing; a stamp in the FUTURE
	-- is a clock that moved backwards and credits nothing either. The counted span is otherwise the
	-- WHOLE of (now - lastTickUnix), verbatim as the slice's formula states it, with `capacity` below
	-- as its only ceiling — see the stamp for what a backwards clock does to the base.
	if last > 0 and nowUnix > last then
		elapsed = nowUnix - last
	end

	local credited = 0
	if elapsed > 0 and rate > 0 then
		credited = rate * elapsed
	end
	stored = math.min(capacity, stored + credited)
	-- Report what actually landed in the tank, not what was produced: a full smelter stops accruing.
	credited = math.max(0, stored - sanitizeAmount(smelter.storedCredits))

	smelter.storedCredits = stored
	-- THE TICK BASE ONLY EVER MOVES FORWARD. `Clock.real().unix` is os.time() — a wall clock an NTP
	-- correction can step BACKWARDS — and an unconditional re-stamp would drop the base into a span
	-- this session has ALREADY been paid for: the tick after the clock recovers then counts that span
	-- a SECOND time and mints output from a clock correction. Keeping the base means a backwards clock
	-- fails in the SAFE direction (nothing accrues until real time catches up) instead of paying
	-- twice. `last` is normalized non-negative by smelterOf, so the never-ticked case (last = 0) still
	-- stamps forward to nowUnix. The two ARMING stamps are deliberately NOT written this way: handing
	-- the away window to Offline accrual is their whole job, and that requires moving the base back.
	smelter.lastTickUnix = math.max(last, nowUnix)

	return {
		credited = credited,
		stored = stored,
		capacity = capacity,
		rate = rate,
		elapsed = elapsed,
		full = stored >= capacity,
	}
end

-- ── THE ONE GRANT PATH ──────────────────────────────────────────────────────────────────────────

export type CollectInfo = {
	collected: number, -- Credits moved out of the smelter by THIS grant
	balance: number, -- the post-grant Credits balance, as EconomyService computed it
	lifetimeCredits: number, -- the post-increment lifetime total, as EconomyService computed it
	stored: number, -- 0 after a successful grant
	capacity: number,
	rate: number,
	trigger: string, -- "manual" | "auto" — reporting only; the earn source is "smelt" either way
}

-- THE single grant. `salvage.collect` AND the auto-collect tick both call THIS function, so the
-- lifetime-counter increment and the currency_earned emit physically cannot be skipped on one of the
-- two triggers (ORCHESTRATOR AMENDMENT A2: auto-collect is one grant path, not two).
--
-- MUTATES the snapshot and MUST be called INSIDE a ctx.data:update transform — it is synchronous and
-- yields nowhere, which is what makes the whole capture-zero-earn sequence atomic (mechanism (1)).
function SalvageService.grantStored(
	_self: any,
	economy: any,
	data: any,
	nowUnix: number,
	depth: any?,
	trigger: string
): any
	if economy == nil or type(economy.earn) ~= "function" then
		-- ctx.economy is the ENFORCEMENT POINT for "lifetime on all earns". Granting around it would
		-- leave stats.lifetimeCredits unmoved and currency_earned unemitted, so an absent seam is a
		-- refusal, never a fall-through to a direct write of data.currencies.
		return Result.err(
			Result.Codes.Internal,
			"salvage: ctx.economy is not installed — granting here would skip stats.lifetimeCredits "
				.. "and the currency_earned event"
		)
	end

	local smelter = smelterOf(data)
	local capacity = SalvageSeam:capacityFor(data)
	local rate = SalvageSeam:rateFor(data, nowUnix, depth)

	-- CAPTURED INSIDE THE TRANSFORM, off the snapshot the lock just handed us — a value read before
	-- the yield would be the stale one, and paying that out IS the double-grant.
	local amount = sanitizeAmount(smelter.storedCredits)
	if amount <= 0 then
		-- An empty smelter is a CURRENCY shortfall, not a payload-range failure and not a panic
		-- refusal: Err(Insufficient). This is also the code a spam-duplicated collect gets, because the
		-- first one already zeroed the tank.
		return Result.err(Result.Codes.Insufficient, "salvage: the smelter is empty")
	end

	-- The earn-side state as it stands BEFORE the attempt, so a refusal can be rolled all the way
	-- back. Captured off this snapshot, under this lock, in the same synchronous stretch as the zero
	-- and the earn — so nothing can have moved it in between.
	local beforeBalance, beforeLifetime = earnStateOf(data)

	-- ZERO FIRST, EARN LAST. earn emits currency_earned as its final act, so keeping it the last
	-- mutation in the transform means no later statement can throw and discard a snapshot the event
	-- already described (EconomyService's own note on that residual edge).
	smelter.storedCredits = 0

	local granted = economy:earn(data, EARN_CURRENCY, amount, EARN_SOURCE)
	if not granted.ok then
		-- RESTORE, re-clamped to the ceiling so a refused grant can never leave the smelter above
		-- capacity. capacity was read from THIS snapshot under THIS lock and nothing between the
		-- capture and here could move it, so the clamp is a belt on a fact that already holds — but a
		-- cap-bypass on the restore path is a known factory failure mode (docs/LEARNINGS.md), so it is
		-- written, not argued.
		smelter.storedCredits = math.min(capacity, amount)
		-- AND ROLL THE EARN BACK. A refusal does NOT imply the seam changed nothing: earn writes the
		-- balance BEFORE the branch that can still refuse (a blob with no `stats` table takes exactly
		-- that path), so restoring only the smelter would commit the amount in the tank AND in
		-- currencies.Credits — one full smelter minted per refused collect, repeatable, and with
		-- stats.lifetimeCredits left behind so no leaderboard or analytic would ever show it. This
		-- transaction is made atomic HERE rather than assumed atomic there.
		restoreEarnState(data, beforeBalance, beforeLifetime)
		return granted
	end

	local grant = granted.value
	local info: CollectInfo = {
		collected = amount,
		balance = grant.balance,
		lifetimeCredits = grant.lifetimeCredits,
		stored = 0,
		capacity = capacity,
		rate = rate,
		trigger = trigger,
	}
	return Result.ok(info)
end

-- ── the collect action's body ───────────────────────────────────────────────────────────────────

function SalvageService.collect(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "salvage: context is missing data/clock")
	end
	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "salvage: player has no numeric UserId")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"salvage: the server clock returned no usable time"
		)
	end
	local nowUnix = now :: number

	-- (2) RESERVE, synchronously, before anything below can yield. A spam-duplicated collect that
	-- arrives while the first is parked in the store lands here and gets the SAME code the empty
	-- smelter it is racing toward would give it. Never RateLimited: that code belongs to the Gate's
	-- anti-spam bucket, and conflating the two makes "the smelter pays once" untestable.
	if self._collecting[userId] then
		return Result.err(
			Result.Codes.Insufficient,
			"salvage: a collect for this player is already in flight — the smelter is being emptied"
		)
	end
	self._collecting[userId] = true

	local outcome: any = nil
	local depth = ctx.depth
	local economy = ctx.economy
	-- Read BEFORE the yield, for the same reason tickPlayer reads it there: a collect that arrives
	-- before this session has been armed must NOT settle an accrual, because the span in front of it is
	-- the AWAY WINDOW and that belongs to Offline accrual. Without this an eager click on the loading
	-- screen would fill the smelter from the away window and pay it out — the exact double-credit
	-- ARMING exists to prevent, reached through the collect door instead of the tick door.
	local armed = self._armed[userId] ~= nil

	-- (1) THE ONE LOCK-HELD TRANSFORM. `now` is read BEFORE the update deliberately, so the accrual
	-- span this collect settles ends at the instant the request was judged rather than at whenever the
	-- lock happened to be granted.
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "salvage: data blob is not a table")
			return data
		end
		if armed then
			-- Settle the accrual up to `now` first, so a collect pays out every second the drones
			-- actually worked rather than only what the last tick happened to have banked. It also
			-- stamps lastTickUnix, so the next tick cannot re-count the span this collect just paid for.
			self:accrue(data, nowUnix, depth)
		else
			-- Un-armed: stamp only, exactly as the arming tick would. Whatever is already stored (the
			-- previous session's un-collected output) is still collectable below — it was banked before
			-- this session began and no away time is being converted here.
			smelterOf(data).lastTickUnix = nowUnix
		end
		outcome = self:grantStored(economy, data, nowUnix, depth, "manual")
		return data
	end

	-- (3) pcall'd ONLY so the reservation is released on every path: DataService:update already pcalls
	-- the transform, so a throw here would have to come from the data layer itself — and a reservation
	-- stranded `true` would lock this player out of their own smelter until the server dies.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	self._collecting[userId] = nil

	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "salvage: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, or a transform that
		-- threw. The snapshot was discarded either way, so NOTHING was persisted: stored was never
		-- durably zeroed and the Err is surfaced as-is rather than dressed up as a grant.
		return written
	end
	if not armed then
		-- Only NOW, after the stamp is durable, is this session allowed to accrue.
		self._armed[userId] = nowUnix
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"salvage: the update reported success but the transform produced no outcome"
		)
	end

	-- The view push is DERIVED from a committed write, comes after it, and can never undo it: guarded
	-- and pcall'd, its result discarded. An unguarded post-write push is how a committed economy write
	-- once came back to the client as Err(Internal) (docs/LEARNINGS.md).
	if outcome.ok then
		self:pushView(self._context, player)
	end
	return outcome
end

-- ── the observation surface ─────────────────────────────────────────────────────────────────────

export type SalvageInfo = {
	rate: number, -- DERIVED Credits/second right now — the delta every later feature asserts on
	baseRate: number, -- the fleet's raw pull, before multipliers
	multiplier: number, -- the composed multiplier applied to it
	stored: number,
	capacity: number,
	full: boolean,
	secondsToFull: number, -- 0 when full or when the rate is 0 (i.e. never)
	lastTickUnix: number, -- SERVER stamp of the last tick; the client extrapolates from it
	nowUnix: number, -- the SERVER instant this reading describes
	drones: number,
	pearlDrones: number,
	autoCollect: boolean,
}

-- PURE over the blob + the server clock. Side-effect free by construction: it writes nothing, grants
-- nothing and stamps nothing (an observation surface that could accrue would make the income rate
-- depend on how often the UI refreshed — a rate spoof with no exploit required).
--
-- THE SMELTER IS READ THROUGH `readSmelter`, NEVER `smelterOf`. smelterOf normalizes IN PLACE, and
-- `fetch` hands this function the LIVE session blob from outside any ctx.data:update — so the
-- convenient call would turn the game's designated read surface into an unlocked writer (§4).
function SalvageService.describe(self: any, data: any, nowUnix: number, depth: any?): SalvageInfo
	local smelter = readSmelter(data)
	local capacity = SalvageSeam:capacityFor(data)
	local rate = SalvageSeam:rateFor(data, nowUnix, depth)
	local stored = sanitizeAmount(smelter.storedCredits)
	local drones, pearlDrones = self:dronesOf(data)
	local headroom = math.max(0, capacity - stored)
	return {
		rate = rate,
		baseRate = self:baseRateOf(data),
		multiplier = self:multiplierAt(data, nowUnix, depth),
		stored = stored,
		capacity = capacity,
		full = stored >= capacity,
		secondsToFull = if rate > 0 then headroom / rate else 0,
		lastTickUnix = smelter.lastTickUnix,
		nowUnix = nowUnix,
		drones = drones,
		pearlDrones = pearlDrones,
		autoCollect = flagOf(data, AUTO_COLLECT_FLAG),
	}
end

function SalvageService.fetch(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "salvage: context is missing data/clock")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"salvage: the server clock returned no usable time"
		)
	end
	local got = ctx.data:get(ctx.player)
	if not got.ok then
		-- NoData until loadSession resolves; the client's JoinRetry guard re-issues past it.
		return got
	end
	return Result.ok(self:describe(got.value, now :: number, ctx.depth))
end

-- ── the tick ────────────────────────────────────────────────────────────────────────────────────

export type TickInfo = {
	armed: boolean, -- true when THIS call was the arming stamp (it credits nothing)
	skipped: boolean, -- true when a tick for this player was already in flight (a no-op, not an error)
	credited: number,
	stored: number,
	capacity: number,
	rate: number,
	collected: number, -- what auto-collect granted on this tick (0 without the gamepass)
}

-- ONE player's tick: exactly ONE ctx.data:update, whether it arms, accrues, or accrues and
-- auto-collects. Returns a Result so a spec can drive it directly and a caller can see refusals.
function SalvageService.tickPlayer(self: any, context: any, player: any): any
	if context == nil or context.data == nil or context.clock == nil then
		return Result.err(Result.Codes.Internal, "salvage: context is missing data/clock")
	end
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "salvage: player has no numeric UserId")
	end
	local now = sanitizeNow(context.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"salvage: the server clock returned no usable time"
		)
	end
	local nowUnix = now :: number

	-- A tick still parked in the store when the next cadence fires must not be entered twice: both
	-- would read the same lastTickUnix and the same span would be credited to the smelter twice. This
	-- is a NO-OP, not a refusal — nothing was asked for and nothing went wrong, and dressing it up as
	-- Err(RateLimited) would make a routine store hitch indistinguishable from the Gate's anti-spam
	-- bucket. The skipped span is not lost: lastTickUnix is untouched, so the in-flight tick (or the
	-- next one) still credits every second of it.
	if self._ticking[userId] then
		return Result.ok({
			armed = false,
			skipped = true,
			credited = 0,
			stored = 0,
			capacity = 0,
			rate = 0,
			collected = 0,
		} :: TickInfo)
	end

	-- Read BEFORE the yield; committed AFTER the write lands, so a failed arming write is retried on
	-- the next tick instead of silently arming a session whose stamp never persisted.
	local arming = self._armed[userId] == nil
	-- Captured BEFORE the yield too, and for the same reason the flag is written after it: this is the
	-- only way the resumed thread can tell "still the session I started arming" from "that player left
	-- and this userId now means someone else's session". See _departures.
	local departureTicket = self._departures[userId] or 0
	local depth = context.depth
	local economy = context.economy
	local outcome: any = nil

	self._ticking[userId] = true
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "salvage: data blob is not a table")
			return data
		end
		if arming then
			-- THE HANDOFF WITH OFFLINE ACCRUAL. Stamp and credit NOTHING: the span between the
			-- persisted stamp and now is the AWAY WINDOW, and it belongs exclusively to Offline
			-- accrual. Crediting it here would pay it twice (and a migrated stamp of 0 would pay
			-- decades of it, clamped to a free full smelter).
			local smelter = smelterOf(data)
			smelter.lastTickUnix = nowUnix
			outcome = Result.ok({
				armed = true,
				skipped = false,
				credited = 0,
				stored = sanitizeAmount(smelter.storedCredits),
				capacity = SalvageSeam:capacityFor(data),
				rate = SalvageSeam:rateFor(data, nowUnix, depth),
				collected = 0,
			} :: TickInfo)
			return data
		end

		local accrual = self:accrue(data, nowUnix, depth)
		local collected = 0
		-- AUTO-COLLECT: the SAME grant function `salvage.collect` uses (AMENDMENT A2), so the lifetime
		-- increment and the currency_earned emit cannot be skipped on this trigger. Dormant until
		-- Monetization grants the flag — correct and dormant, not absent. An empty smelter simply
		-- refuses (Insufficient), which is not an error worth surfacing from a background tick.
		if flagOf(data, AUTO_COLLECT_FLAG) and economy ~= nil then
			local granted = self:grantStored(economy, data, nowUnix, depth, "auto")
			if granted.ok then
				collected = granted.value.collected
			end
		end
		local smelter = smelterOf(data)
		outcome = Result.ok({
			armed = false,
			skipped = false,
			credited = accrual.credited,
			stored = sanitizeAmount(smelter.storedCredits),
			capacity = accrual.capacity,
			rate = accrual.rate,
			collected = collected,
		} :: TickInfo)
		return data
	end

	local ok, written = pcall(function(): any
		return context.data:update(player, transform)
	end)
	self._ticking[userId] = nil

	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "salvage: the data layer returned no Result")
	end
	if written.ok ~= true then
		return written -- NoData while the session loads, LockStolen, ... — nothing was persisted
	end
	if arming and (self._departures[userId] or 0) == departureTicket then
		-- Only NOW, after the stamp is durable, is this session allowed to accrue — and only if the
		-- player has not LEFT while this update was parked in the store. Re-arming a departed session
		-- is not a harmless stale entry: `armFor` is idempotent on this key, so their rejoin is never
		-- stamped and the first accruing tick credits the whole absence from the pre-departure
		-- lastTickUnix, which is the span OfflineService is already granting. Paid twice.
		--
		-- The stamp this write committed is NOT lost by skipping: it is in the persisted blob, so the
		-- rejoin's own arming re-stamps from there and simply credits nothing, which is the correct
		-- outcome for a session that was not here.
		self._armed[userId] = nowUnix
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"salvage: the update reported success but the transform produced no outcome"
		)
	end
	return outcome
end

-- Explicitly arm one player's session (the join hook's job — see ARMING in the header). Idempotent:
-- an already-armed session is left alone, so a re-run can never re-stamp a live tick base and silently
-- swallow the seconds since the last tick.
function SalvageService.armFor(self: any, context: any, player: any): any
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "salvage: player has no numeric UserId")
	end
	if self._armed[userId] ~= nil then
		return Result.ok({ armed = false })
	end
	return self:tickPlayer(context, player)
end

-- Who is on this server right now. The injected provider wins (Tier-1), then the engine, then an empty
-- roster. `game` is a real global in Roblox and NIL under Lune, so it is reached through a guarded
-- local and the pcall keeps a Players failure from killing the only income loop in the game.
function SalvageService.roster(self: any): { any }
	local provider = self._players
	if type(provider) == "function" then
		local ok, injected = pcall(provider)
		if ok and type(injected) == "table" then
			return injected
		end
		return {}
	end
	local realGame: any = game
	if realGame == nil then
		return {} -- Lune: no engine roster. Specs inject one.
	end
	local ok, present = pcall(function()
		return realGame:GetService("Players"):GetPlayers()
	end)
	if ok and type(present) == "table" then
		return present
	end
	return {}
end

export type TickPass = { ticked: number, armed: number, collected: number }

-- ONE pass of THE server-wide tick over every live session. This is the only tick loop in the game:
-- one pass per cadence for the whole server, never one loop per player (n loops means n independent
-- clock bases, and a player whose loop died silently stops earning with nothing to observe it).
--
-- Each player's tick is pcall'd INDIVIDUALLY: one player's data-layer failure must never stop the pass
-- that pays everyone else.
function SalvageService.tickAll(self: any, context: any): TickPass
	local pass: TickPass = { ticked = 0, armed = 0, collected = 0 }
	if context == nil or context.data == nil then
		return pass
	end
	local roster = self:roster()
	local present: { [number]: boolean } = {}

	for _, player in roster do
		local userId = userIdOf(player)
		if userId ~= nil and not present[userId] then
			present[userId] = true
			local ok, result = pcall(function(): any
				return self:tickPlayer(context, player)
			end)
			if
				ok
				and type(result) == "table"
				and result.ok == true
				and result.value.skipped ~= true
			then
				local info = result.value
				pass.ticked += 1
				if info.armed == true then
					pass.armed += 1
				end
				pass.collected += info.collected
				-- The world is DERIVED from the persisted facts and only ever read: a presentation
				-- failure must never disturb the accrual that just committed.
				pcall(function()
					self:syncWorld(context, player)
				end)
			end
		end
	end

	-- Prune arming state for players who have left. This is the BELT, not the primary: the leave hook
	-- (SalvageSeam.disarmFor, called from framework/PlayerLifecycle's pinned sequence) is what makes a
	-- fast leave->rejoin re-arm, because this loop cannot — it runs once a cadence and `present` is
	-- fixed at the START of the pass, so a rejoin that beats it inherits the stale flag. What this
	-- still owns: a player lost with NO leave event, and the unbounded growth of a per-server table
	-- across a server's hours of life. It never connects PlayerRemoving itself — that signal belongs
	-- to framework/PlayerLifecycle alone.
	for userId in self._armed do
		if not present[userId] then
			self._armed[userId] = nil
			self._ticking[userId] = nil
			self._collecting[userId] = nil
		end
	end

	return pass
end

-- ── the actions ─────────────────────────────────────────────────────────────────────────────────

-- Both payloads carry NOTHING BY CONTRACT — no amount, no rate, no capacity, no timestamp, no target.
-- A payload that names one is REFUSED rather than ignored: an ignored forgery is indistinguishable
-- from a well-formed request, and the difference is the only signal that someone is probing the rate.
-- The validator hands the handler a FRESH EMPTY TABLE, so the handler is not merely disciplined about
-- ignoring client data — it is never handed any. THIS IS THE salvage-rate-spoof defence: there is no
-- client number anywhere on this path to trust.
local FORBIDDEN_PAYLOAD_KEYS = {
	"amount",
	"credits",
	"Credits",
	"stored",
	"storedCredits",
	"collected",
	"rate",
	"multiplier",
	"capacity",
	"drones",
	"pearlDrones",
	"conveyor",
	"smelter",
	"elapsed",
	"now",
	"nowUnix",
	"time",
	"timestamp",
	"unix",
	"lastTickUnix",
	"serverTime",
	"clientTime",
	"deltaTime",
	"userId",
	"plotId",
	"trigger",
	"source",
}

local function validateNoArguments(rawPayload: any): any
	if rawPayload == nil then
		return Result.ok({})
	end
	if type(rawPayload) ~= "table" then
		return Result.err(Result.Codes.BadType, "payload must be a table or nil")
	end
	for _, key in FORBIDDEN_PAYLOAD_KEYS do
		if rawPayload[key] ~= nil then
			return Result.err(
				Result.Codes.BadPayload,
				`salvage actions take no arguments — the SERVER derives the rate, the capacity and `
					.. `every credit collected (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

SalvageService.validate = validateNoArguments

-- Exported so a Tier-1 spec can register the actions on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as CLOSURES over the service because the single-flight
-- reservation tables and the arming set ARE service state, which a static-module registration cannot
-- reach (contract precisionNote).
function SalvageService.collectAction(self: any): any
	return {
		name = Net.Actions.CollectSmelter,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB: generous enough for eager clicking, bounded so a spam
		-- burst is refused by the Gate before it ever reaches the economy's single-writer path.
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(ctx: any, _payload: any): any
			return self:collect(ctx)
		end,
	}
end

function SalvageService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchSalvage,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB.
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(ctx: any, _payload: any): any
			return self:fetch(ctx)
		end,
	}
end

-- Push the refreshed client view after a committed collect. `context` is the SERVER context (the
-- ActionContext projection carries no net). Every caller ignores the return value, because a
-- presentation failure must never turn a granted collect into an error.
function SalvageService.pushView(_self: any, context: any, player: any): boolean
	if context == nil then
		return false
	end
	local net = context.net
	if net == nil or type(net.fireClient) ~= "function" or context.data == nil then
		return false
	end
	-- THE READ IS INSIDE THE pcall, WITH THE PUSH. `context.data:get` returning Err is ordinary and
	-- handled below — but a data layer that THROWS (a released session, a metatable that errors, a
	-- future refactor) would propagate straight out of this function and into the caller's return
	-- path. Every caller here is a POST-WRITE presentation step, so that throw turns an already
	-- committed grant into an Err the player sees as a failure while their balance has moved. That is
	-- the exact defect this factory shipped once before: an unguarded post-write FireClient turned a
	-- committed Sell into Err(Internal), invisible to 352 green Lune tests. Presentation must never be
	-- able to fail a transaction that already succeeded.
	local ok, pushed = pcall(function(): boolean
		local got = context.data:get(player)
		if type(got) ~= "table" or got.ok ~= true then
			return false
		end
		net:fireClient(player, "data", Types.toView(got.value))
		return true
	end)
	return ok and pushed == true
end

-- ── the world (greybox) ─────────────────────────────────────────────────────────────────────────
-- ROBLOX-ONLY, every entry point guarded. Art posture: "drones = small Parts on TweenService paths,
-- conveyors/smelter = Parts. No external assets in v1."
--
-- COSMETIC ONLY. Nothing built here is read back by any rule: the drones are a picture OF the rate,
-- never an input to it, so a client that deleted, froze or teleported every one of them would change
-- no number on the server. That is the salvage-rate spoof closed by construction.

local RIG_NAME = "Salvage"
local DRONES_FOLDER_NAME = "Drones"
-- How many drones are ever drawn, regardless of how many the blob owns. A late-game fleet of hundreds
-- of tweened Parts per plot on a full server is a frame-rate problem, and past a handful nobody can
-- count them anyway.
local MAX_VISIBLE_DRONES = 8
-- Layout, in studs, relative to the dome root's pivot.
local WRECK_OFFSET_X = -22
local SMELTER_OFFSET_X = 18
local RIG_HEIGHT = 4
local DRONE_SIZE = 1.6
local DRONE_TRAVEL_SECONDS = 3

local function robloxRefs(): (any, any, any, any)
	local instanceGlobal: any = Instance
	local vector3Global: any = Vector3
	local color3Global: any = Color3
	local enumGlobal: any = Enum
	return instanceGlobal, vector3Global, color3Global, enumGlobal
end

local function rootPosition(root: any): any
	local vector3Global: any = Vector3
	if vector3Global == nil then
		return nil
	end
	local ok, position = pcall(function()
		return root:GetPivot().Position
	end)
	if ok and position ~= nil then
		return position
	end
	return vector3Global.new(0, 0, 0)
end

-- One drone: a small Part shuttling wreck -> smelter forever on a single tween (RepeatCount = -1,
-- Reverses = true), so there is no per-drone thread to leak and no loop to keep alive.
local function buildDrone(folder: any, index: number, origin: any): ()
	local instanceGlobal, vector3Global, color3Global, enumGlobal = robloxRefs()
	local tweenService: any = nil
	local realGame: any = game
	if realGame ~= nil then
		local ok, service = pcall(function()
			return realGame:GetService("TweenService")
		end)
		if ok then
			tweenService = service
		end
	end
	if
		instanceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
		or origin == nil
	then
		return
	end

	local lane = ((index - 1) % 4) * 2 - 3 -- spread the fleet across four lanes over the belt
	local start = origin + vector3Global.new(WRECK_OFFSET_X, RIG_HEIGHT + 1.4, lane)
	local finish = origin + vector3Global.new(SMELTER_OFFSET_X, RIG_HEIGHT + 1.4, lane)

	local drone = instanceGlobal.new("Part")
	drone.Name = `Drone{index}`
	drone.Anchored = true
	drone.CanCollide = false
	drone.CanQuery = false
	drone.CanTouch = false
	drone.Size = vector3Global.new(DRONE_SIZE, DRONE_SIZE, DRONE_SIZE)
	drone.Color = color3Global.fromRGB(226, 178, 74)
	drone.Material = enumGlobal.Material.Metal
	drone.Position = start
	drone.Parent = folder

	if tweenService == nil then
		return
	end
	local tweenInfoGlobal: any = TweenInfo
	if tweenInfoGlobal == nil then
		return
	end
	pcall(function()
		local info = tweenInfoGlobal.new(
			DRONE_TRAVEL_SECONDS,
			enumGlobal.EasingStyle.Linear,
			enumGlobal.EasingDirection.InOut,
			-1, -- repeat forever
			true, -- ...and reverse, so the drone shuttles back for the next fragment
			(index - 1) * 0.35 -- stagger the fleet so they do not fly in lockstep
		)
		tweenService:Create(drone, info, { Position = finish }):Play()
	end)
end

-- Find-or-create the rig under this player's dome root. IDEMPOTENT and CHEAP on the common path (one
-- FindFirstChild), because it runs once per player per tick.
function SalvageService.buildRig(_self: any, root: any): any
	local instanceGlobal, vector3Global, color3Global, enumGlobal = robloxRefs()
	if
		instanceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
	then
		return nil
	end
	if root == nil then
		return nil
	end
	local existing = root:FindFirstChild(RIG_NAME)
	if existing ~= nil then
		return existing
	end

	local origin = rootPosition(root)
	if origin == nil then
		return nil
	end

	local rig = instanceGlobal.new("Folder")
	rig.Name = RIG_NAME

	local conveyor = instanceGlobal.new("Part")
	conveyor.Name = "Conveyor"
	conveyor.Anchored = true
	conveyor.CanCollide = true
	conveyor.Size = vector3Global.new(SMELTER_OFFSET_X - WRECK_OFFSET_X, 1, 8)
	conveyor.Position = origin
		+ vector3Global.new((WRECK_OFFSET_X + SMELTER_OFFSET_X) / 2, RIG_HEIGHT, 0)
	conveyor.Color = color3Global.fromRGB(58, 68, 78)
	conveyor.Material = enumGlobal.Material.DiamondPlate
	conveyor.Parent = rig

	local wreck = instanceGlobal.new("Part")
	wreck.Name = "Wreck"
	wreck.Anchored = true
	wreck.CanCollide = true
	wreck.Size = vector3Global.new(8, 6, 8)
	wreck.Position = origin + vector3Global.new(WRECK_OFFSET_X - 4, RIG_HEIGHT + 3, 0)
	wreck.Color = color3Global.fromRGB(72, 84, 76)
	wreck.Material = enumGlobal.Material.CorrodedMetal
	wreck.Parent = rig

	local smelter = instanceGlobal.new("Part")
	smelter.Name = "Smelter"
	smelter.Anchored = true
	smelter.CanCollide = true
	smelter.Size = vector3Global.new(10, 10, 10)
	smelter.Position = origin + vector3Global.new(SMELTER_OFFSET_X + 5, RIG_HEIGHT + 5, 0)
	smelter.Color = color3Global.fromRGB(96, 70, 44)
	smelter.Material = enumGlobal.Material.Metal
	smelter.Parent = rig

	local glow = instanceGlobal.new("PointLight")
	glow.Name = "SmelterGlow"
	glow.Color = color3Global.fromRGB(255, 168, 64)
	glow.Range = 24
	glow.Brightness = 2
	glow.Parent = smelter

	local drones = instanceGlobal.new("Folder")
	drones.Name = DRONES_FOLDER_NAME
	drones.Parent = rig

	rig.Parent = root
	return rig
end

-- Make the drawn fleet match the persisted one. Roblox-only and pcall'd by its caller; a nil dome root
-- (the player holds no dome yet) is a NORMAL state and returns false, never an error.
function SalvageService.syncWorld(self: any, context: any, player: any): boolean
	local instanceGlobal = Instance :: any
	if instanceGlobal == nil then
		return false -- Lune: no engine to draw into
	end
	local plot = if context ~= nil then context.plot else nil
	if plot == nil or type(plot.rootFor) ~= "function" then
		return false
	end
	local root = plot:rootFor(player)
	if root == nil then
		return false -- holds no dome yet: normal, not an error
	end
	local got = context.data:get(player)
	if type(got) ~= "table" or got.ok ~= true then
		return false
	end

	local rig = self:buildRig(root)
	if rig == nil then
		return false
	end
	local folder = rig:FindFirstChild(DRONES_FOLDER_NAME)
	if folder == nil then
		return false
	end

	local drones, pearlDrones = self:dronesOf(got.value)
	local wanted = math.clamp(math.floor(drones + pearlDrones), 1, MAX_VISIBLE_DRONES)
	local origin = rootPosition(root)
	for index = 1, wanted do
		if folder:FindFirstChild(`Drone{index}`) == nil then
			buildDrone(folder, index, origin)
		end
	end
	for index = wanted + 1, MAX_VISIBLE_DRONES do
		local extra = folder:FindFirstChild(`Drone{index}`)
		if extra ~= nil then
			extra:Destroy()
		end
	end
	return true
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: install the seam FIRST (the ActionContext projection reads ctx.salvage at dispatch time, and
-- a service that Starts later may consult it during its own Start), then register the wire surface,
-- then — Roblox only — start the ONE tick loop and the join hook. Lune-callable: everything
-- engine-shaped lives behind startRuntime.
function SalvageService.Start(self: any, context: any): ()
	context.salvage = SalvageSeam
	self._context = context
	self._armed = {}
	self._collecting = {}
	self._ticking = {}
	context.net:register(self:collectAction())
	context.net:register(self:fetchAction())
	self:startRuntime(context)
end

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable. A spec can replace it to drive the join hook without sleeping.
function SalvageService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

SalvageService.loadWaitAttempts = 200
SalvageService.loadWaitStepSeconds = 0.25

-- Bounded wait for this player's session, then ARM it. Same budget and shape as PlotService's join
-- wait, for the same reason: loadSession YIELDS, and an arming stamp issued before it resolves reads
-- Err(NoData) and arms nothing — which would leave the first accruing tick to credit the away window.
function SalvageService.armOnJoin(self: any, context: any, player: any): any
	for attempt = 1, self.loadWaitAttempts do
		local got = context.data:get(player)
		if type(got) == "table" and got.ok == true then
			return self:armFor(context, player)
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return Result.err(Result.Codes.NoData, "salvage: session never loaded for this player")
end

-- ROBLOX-ONLY: THE one server-wide tick loop plus the join hook.
function SalvageService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return -- Lune: no engine to wire. Specs drive tickAll / tickPlayer / the actions directly.
	end
	if self._running then
		return -- idempotent: a second Start must not run two tick loops (two clock bases, one blob)
	end
	self._running = true
	self._connections = {}

	local Players = realGame:GetService("Players")

	local function onAdded(player: any): ()
		self:armOnJoin(context, player)
	end

	-- Players already present (a Studio Play session installs scripts after the local player joins).
	-- Spawned: armOnJoin yields and the bootstrap must not block on it.
	for _, player in Players:GetPlayers() do
		realTask.spawn(onAdded, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: any)
			realTask.spawn(onAdded, player)
		end)
	)

	realTask.spawn(function()
		while self._running do
			realTask.wait(TICK_INTERVAL_SECONDS)
			if not self._running then
				break
			end
			-- pcall'd: an unguarded error here would silently kill the ONLY income loop in the game
			-- for the rest of the server's life, and every player would quietly stop earning.
			pcall(function()
				self:tickAll(context)
			end)
		end
	end)
end

function SalvageService.Stop(self: any, _context: any): ()
	self._running = false
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
	self._armed = {}
	self._collecting = {}
	self._ticking = {}
	self._context = nil
end

return SalvageService
