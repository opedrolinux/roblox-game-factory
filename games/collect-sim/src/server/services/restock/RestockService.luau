--!strict
-- games/collect-sim/src/server/services/restock/RestockService.luau   [restock]
-- Feature: a daily "rich vein" island event that resets each UTC day on SERVER time. Every day a
-- single island becomes the day's RICH VEIN: a player who has that island unlocked earns a bonus
-- multiplier on the Sell earn path while collecting/selling on it. The whole event is DERIVED from
-- the server day number, so it needs NO persisted field and resets automatically at each UTC day
-- boundary (math.floor(now / 86400) rolls over -> a new vein island, deterministically).
--
-- AUTHORITY (CLAUDE.md §3 + §7): EVERYTHING is server-owned and derived from the SERVER clock
-- (ctx.clock:unix(), never client/wall time). The client supplies NOTHING that affects the bonus:
--   * the day number is math.floor(serverUnix / 86400),
--   * the rich-vein island id is DERIVED deterministically from the day number over a SERVER-OWNED
--     island id set (mirroring the IslandsService catalog id range 1..N — server authoritative;
--     the client never supplies a vein, a multiplier, or an island it has not earned),
--   * the bonus MULTIPLIER is a SERVER-OWNED constant.
-- There is therefore no client number to trust and no open exploit: a player can only RECEIVE the
-- bonus, never choose it.
--
-- STATE OWNERSHIP: this feature owns NO persisted state and NO session state. It is a PURE function
-- of (server time, the player's already-persisted island-unlock flags). Because it is fully derived,
-- it self-resets at the UTC day boundary with zero migration and zero stored field — exactly the
-- spec's "resets automatically / NO persisted field" property.
--
-- THE SELL SEAM (ctx.restock:multiplierFor(d, now)): the consolidated Sell formula in
-- CollectionService consumes this with the LOCK-HELD player-data snapshot `d` and the server-clock
-- `now` (both passed by the contract-pass Sell retrofit). It returns RICH_VEIN_MULTIPLIER iff the
-- player is ELIGIBLE for today's vein island (has that island unlocked per d.flags / it is the
-- always-unlocked starting island), else the identity default 1. It is PURE + SYNCHRONOUS (no I/O,
-- no yield) so it is safe to call INSIDE the Sell transform under the per-player lock, and Tier-1
-- callable directly. When `d` is absent it returns 1 (the pre-feature Sell path is preserved).
--
-- Lune-clean: relative requires only; no Roblox global touched. The action is plain data + pure-ish
-- functions over injected ctx, so a spec can drive it through Mocks.net -> Net.dispatch.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- ----- SERVER-OWNED CONSTANTS (authoritative; the client never sees or supplies any of this) -----
-- Seconds in one UTC day. The day boundary the event resets on (server time / 86400, floored).
local SECONDS_PER_DAY = 86400

-- The bonus multiplier applied on today's rich-vein island. A SERVER-OWNED constant (CLAUDE.md §3):
-- it is never read from a payload and never client-supplied. > 1 so the vein is a real bonus.
local RICH_VEIN_MULTIPLIER = 3

-- The SERVER-OWNED island id set the vein is drawn from — mirrors the IslandsService catalog id
-- range (ids 1..5; index 1 is the always-unlocked starting island). RestockService cannot edit or
-- import IslandsService's private catalog, so the authoritative id set is mirrored here as a
-- server-owned constant; both are server authority and must agree on the id range. The vein rotates
-- across ALL islands (including the starting island), so on a starting-island day EVERY player is
-- eligible (the floor multiplier landing on the universally-unlocked island), and on other days only
-- players who have unlocked that island receive the bonus.
local ISLAND_IDS: { number } = { 1, 2, 3, 4, 5 }

-- Index 1 of the catalog is the STARTING island: always unlocked for every player, no persisted flag
-- (mirrors IslandsService.STARTING_INDEX semantics). Any island id equal to this is eligible for all.
local STARTING_ISLAND_ID = 1

-- The per-player flag key carrying the unlock state for an island id (the island.<id> convention
-- IslandsService persists into PlayerData.flags). Reading it here is a PURE read of the snapshot.
local function islandFlagKey(id: number): string
	return "island." .. tostring(id)
end

-- The SERVER day number for a unix time: math.floor(serverUnix / 86400). Rolls over at each UTC day
-- boundary, which is exactly when the rich vein resets. Pure; the ONLY time source is the server now.
local function dayNumberFor(now: number): number
	return math.floor(now / SECONDS_PER_DAY)
end

-- Deterministically derive TODAY's rich-vein island id from the server day number, over the
-- server-owned id set: dayNumber % #ISLAND_IDS picks an index (1-based), so the vein rotates through
-- every island and resets at the day boundary. Same `now` -> same vein on every server (no random,
-- no per-server drift); a new UTC day -> the next island. Pure.
local function richVeinIslandId(now: number): number
	local day = dayNumberFor(now)
	-- Lua arrays are 1-based; (day % count) is in [0, count-1], so +1 maps to [1, count].
	local index = (day % #ISLAND_IDS) + 1
	return ISLAND_IDS[index]
end

-- Whether the player whose snapshot is `d` has `islandId` unlocked. The starting island is ALWAYS
-- unlocked (implicit, no flag); every other island is unlocked iff flags['island.<id>'] is truthy.
-- Pure read over the lock-held snapshot — no I/O, no yield. Nil-safe on a minimal/missing snapshot.
local function hasIslandUnlocked(d: any, islandId: number): boolean
	if islandId == STARTING_ISLAND_ID then
		return true -- starting island is always unlocked for everyone
	end
	local flags = d ~= nil and d.flags or nil
	if flags == nil then
		return false
	end
	return flags[islandFlagKey(islandId)] == true
end

-- ----- THE SELL SEAM: today's rich-vein bonus, per player, over the lock-held snapshot -----
-- multiplierFor(d, now): returns RICH_VEIN_MULTIPLIER iff the player (snapshot `d`) is eligible for
-- TODAY's vein island (derived from server `now`), else 1. PURE + SYNCHRONOUS so the Sell transform
-- can call it under the per-player lock. When `d` is nil OR `now` is not a usable number we return
-- the identity default 1, so the pre-feature Sell behavior is preserved exactly and a focused test
-- that omits a snapshot stays a no-op multiplier.
local RestockSeam = {}
function RestockSeam.multiplierFor(_self: any, d: any, now: number): number
	if d == nil then
		return 1
	end
	if type(now) ~= "number" or now ~= now then
		-- Defensive: no usable server clock value -> no bonus (never crash the Sell transform).
		return 1
	end
	local veinId = richVeinIslandId(now)
	if hasIslandUnlocked(d, veinId) then
		return RICH_VEIN_MULTIPLIER
	end
	return 1
end

local RestockService = { name = "RestockService" }

-- ----- FetchRestock: read-only HUD hint -----
-- Returns TODAY's rich-vein island id + the bonus multiplier, derived purely from the SERVER clock,
-- so the client can show a "today's rich vein" HUD hint. READ-ONLY: no mutation, no economy effect —
-- the client learns which island is hot but cannot influence it. We also return the server day number
-- + the next-reset unix so a HUD can render a countdown without ever using client time. `eligible`
-- reflects whether THIS player currently has the vein island unlocked (pure read of their data).
type RestockView = {
	islandId: number,
	multiplier: number,
	dayNumber: number,
	resetsAtUnix: number,
	eligible: boolean,
}
local function makeFetchRestockAction(): Net.Action<{}, RestockView>
	return {
		name = Net.Actions.FetchRestock, -- "restock.fetch"
		-- Read-only HUD poll: a generous bucket (mirrors the other Fetch actions) so a HUD refresh is
		-- never starved, while still rate-shedding a spam flood.
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload must be a table; we accept ONLY an empty intent (the client supplies
			-- nothing — the vein + multiplier are 100% server-derived).
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(ctx, _payload): Result.Result<RestockView>
			-- Server clock is the ONLY time source (CLAUDE.md §7). Never trust client time.
			local now = ctx.clock:unix()
			local day = dayNumberFor(now)
			local veinId = richVeinIslandId(now)
			-- Whether THIS player is currently eligible: pure read of their PERSISTED island flags.
			-- A player whose data is not loaded yet (NoData) is simply reported not-yet-eligible for
			-- the HUD — the read-only hint must never error a UI poll over a transient load state.
			local eligible = false
			local got = ctx.data:get(ctx.player)
			if got.ok then
				eligible = hasIslandUnlocked(got.value, veinId)
			end
			return Result.ok({
				islandId = veinId,
				multiplier = RICH_VEIN_MULTIPLIER,
				dayNumber = day,
				-- The next UTC day boundary in server unix time: (day + 1) * 86400. The HUD can render a
				-- countdown to the reset without ever consulting client time.
				resetsAtUnix = (day + 1) * SECONDS_PER_DAY,
				eligible = eligible,
			})
		end,
	}
end

-- Start: register the read-only FetchRestock action and publish the server-time-derived multiplier
-- seam onto the shared context so every handler's ActionContext (built per-request by NetServer)
-- sees ctx.restock — the consolidated Sell formula reads today's rich-vein bonus through it.
function RestockService:Start(context: any): ()
	context.net:register(makeFetchRestockAction())
	context.restock = RestockSeam
end

return RestockService
