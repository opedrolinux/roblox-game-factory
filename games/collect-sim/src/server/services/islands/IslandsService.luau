--!strict
-- games/collect-sim/src/server/services/islands/IslandsService.luau   [islands]
-- Feature: multiple zones gated by Stardust. Unlocking the next island is a Stardust SINK; each
-- island carries a richer per-mote `multiplier` (the islandMultiplier the consolidated Sell formula
-- reads from the player's HIGHEST unlocked island). A VIP island additionally requires the
-- flags['gamepass.vipIsland'] ownership flag.
--
-- AUTHORITY (CLAUDE.md §3): the CATALOG (island ids, costs, multipliers, unlock ORDER, vip flag) is
-- SERVER-OWNED and SERVER-AUTHORITATIVE, mirroring shop's CATALOG. The client supplies ONLY which
-- island id to unlock — NEVER a price, NEVER a multiplier, NEVER an island it has not earned. The
-- next-island cost is always DERIVED on the server from the catalog, so there is no client number to
-- honor and no open exploit (spec "No open exploit" criterion).
--
-- STATE OWNERSHIP: unlock state is PERSISTED per-player as flags['island.<id>'] booleans (the flags
-- seam, Types.PlayerData.flags). The starting island (id 1) is ALWAYS unlocked (implicit — never
-- needs a flag). Islands unlock IN ORDER: an island's immediate predecessor must already be unlocked.
--
-- CONCURRENCY-SAFE SINK (CLAUDE.md §4, the economy red-team target): BOTH operands (the Stardust
-- balance and the island unlock flag) live in PERSISTED PlayerData, so the ENTIRE read-check-write —
-- re-read the flag set + re-read the balance, re-verify order/vip/affordability, deduct the
-- server-derived cost, set the flag — happens INSIDE ONE ctx.data:update transform. That transform
-- runs under the per-player FIFO lock on a FRESH re-read snapshot (DataService.update / MockStore),
-- so it is atomic: an interleaved or spam-duplicated UnlockIsland (or an interleaved Sell/BuyUpgrade)
-- re-reads the POST-write balance + flags and can never double-spend Stardust and never set the flag
-- without the matching deduction. There is NO read-then-write across the yield: the transform body is
-- synchronous and reads ONLY the snapshot it is handed.
--
-- SEAM (ctx.islands:multiplierFor(d) -> the player's highest-unlocked-island multiplier): the
-- consolidated Sell formula consumes this. It derives the multiplier PURELY from the lock-held
-- snapshot `d` it is handed (the player's flags), so it is per-player and concurrency-correct. When
-- `d` is absent (the seam is called without a snapshot) it returns the identity default 1, so the
-- pre-feature Sell behavior is preserved exactly. No I/O, no yield — Tier-1 callable.
--
-- Dual-runtime require [D1 shim]: under Lune (script == nil) these resolve via the filesystem and touch
-- no Roblox global, so a spec drives the actions through Mocks.net -> Net.dispatch. In Roblox, src/shared
-- maps to ReplicatedStorage.Shared (a DIFFERENT service than this ServerScriptService module), so the
-- relative string can't reach it — the script ~= nil branch requires it by instance.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

-- ----- SERVER-OWNED CATALOG (authoritative; the client never sees or supplies any of this) -----
-- Islands are an ORDERED list. `id` is the stable wire identifier (the ONLY thing a client may
-- supply). `cost` is the Stardust SINK to unlock this island; `multiplier` is its per-mote mote
-- value (the islandMultiplier Sell reads from the highest unlocked island); `vip = true` marks an
-- island that ALSO requires the gamepass.vipIsland ownership flag. Each island is rarer/richer than
-- the last: cost and multiplier both rise with order.
--
-- ORDER == array index. Island at index 1 is the STARTING island: cost 0, always unlocked, no flag.
-- Unlocking the island at index i requires the island at index i-1 to already be unlocked.
type Island = { id: number, cost: number, multiplier: number, vip: boolean }

local CATALOG: { Island } = {
	{ id = 1, cost = 0, multiplier = 1, vip = false }, -- starting island: free + always unlocked
	{ id = 2, cost = 500, multiplier = 2, vip = false },
	{ id = 3, cost = 2500, multiplier = 4, vip = false },
	{ id = 4, cost = 10000, multiplier = 8, vip = false },
	{ id = 5, cost = 40000, multiplier = 16, vip = true }, -- VIP island: needs gamepass.vipIsland
}

-- The flag key checked for VIP-island ownership (a gamepass-granted per-player boolean on flags).
local VIP_FLAG = "gamepass.vipIsland"

-- The starting island is ALWAYS unlocked, with no persisted flag. Index 1 in the catalog.
local STARTING_INDEX = 1

-- The per-player flag key carrying the unlock state for an island id (the island.<id> convention).
local function islandFlagKey(id: number): string
	return "island." .. tostring(id)
end

-- Find a catalog island (and its order index) by id. Returns (island, index) or (nil, nil) for an
-- unknown id. Linear scan over a tiny fixed list — server-owned, never client-sized.
local function findIsland(id: number): (Island?, number?)
	for index, island in CATALOG do
		if island.id == id then
			return island, index
		end
	end
	return nil, nil
end

-- Whether the island at catalog `index` is unlocked for the snapshot `d`. The starting island is
-- ALWAYS unlocked (implicit); every other island is unlocked iff its flags['island.<id>'] is truthy.
-- Reads ONLY the snapshot `d` (the flags seam) — pure, no I/O.
local function isUnlocked(d: any, index: number): boolean
	if index == STARTING_INDEX then
		return true -- starting island is always unlocked
	end
	local island = CATALOG[index]
	if island == nil then
		return false
	end
	local flags = d ~= nil and d.flags or nil
	if flags == nil then
		return false
	end
	return flags[islandFlagKey(island.id)] == true
end

-- ----- THE SELL SEAM: highest-unlocked-island multiplier (pure over the snapshot) -----
-- Walk the catalog from the RICHEST island down; the first one unlocked for this player is the
-- highest, so return its multiplier. The starting island (always unlocked, multiplier 1) is the
-- floor, so a player who has unlocked nothing extra gets exactly 1 — behavior-identical to the
-- pre-feature Sell. `d` is the LOCK-HELD player-data snapshot; when absent we return the identity
-- default 1 (the current Sell caller passes nil, so this keeps that path a no-op multiplier).
local IslandsSeam = {}
function IslandsSeam.multiplierFor(_self: any, d: any): number
	if d == nil then
		return 1
	end
	for index = #CATALOG, 1, -1 do
		if isUnlocked(d, index) then
			return CATALOG[index].multiplier
		end
	end
	return 1 -- defensive: the starting island always matches above, so this is unreachable
end

local IslandsService = { name = "IslandsService" }

-- ----- UnlockIsland: the Stardust SINK -----
-- Payload: { islandId: number } — the ONLY client-supplied datum (which island to unlock). Any
-- client-supplied price/multiplier/level is ignored by never being read. Server derives everything
-- else from the catalog + the player's PERSISTED flags/balance.
local function makeUnlockIslandAction(): Net.Action<
	{ islandId: number },
	{ islandId: number, cost: number, balance: number, multiplier: number }
>
	return {
		name = Net.Actions.UnlockIsland, -- "islands.unlock"
		-- Deliberate spend (player taps an unlock pad): a tight bucket so spam-duplicated unlocks are
		-- also rate-shed. The concurrency guarantee does NOT rely on this — it is defence in depth.
		rate = { maxPerWindow = 5, windowSeconds = 1 },
		validate = function(raw): Result.Result<{ islandId: number }>
			-- Untrusted payload: must be a table whose `islandId` is a real integer. We copy out ONLY
			-- islandId; the catalog lookup (range/ownership/order) is the handler's authority job.
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			local islandId = (raw :: any).islandId
			if type(islandId) ~= "number" then
				return Result.err(Result.Codes.BadPayload)
			end
			-- Integer, finite. A NaN/inf/fractional id is malformed, not merely out of range.
			if islandId ~= islandId or islandId == math.huge or islandId == -math.huge then
				return Result.err(Result.Codes.BadPayload)
			end
			if math.floor(islandId) ~= islandId then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({ islandId = islandId })
		end,
		handler = function(
			ctx,
			payload
		): Result.Result<{ islandId: number, cost: number, balance: number, multiplier: number }>
			local islandId = payload.islandId
			local island, index = findIsland(islandId)
			if island == nil or index == nil then
				-- Unknown island id: out of the catalog range.
				return Result.err(Result.Codes.OutOfRange, "unknown island")
			end

			-- The starting island can never be "unlocked" by spending — it is always unlocked. Treat a
			-- request to unlock it as out of range (there is no next-island sink to apply).
			if index == STARTING_INDEX then
				return Result.err(Result.Codes.OutOfRange, "starting island already unlocked")
			end

			-- ----- CONCURRENCY-SAFE SPEND (the economy red-team target) -----
			-- The ENTIRE decision is made INSIDE the transform, on the lock-held re-read snapshot. We
			-- capture the OUTCOME (cost / balance / multiplier, or a rejection code) into locals the
			-- transform closes over; the transform mutates `d` ONLY on success and returns `d` unchanged
			-- on any rejection. Because it runs under the per-player FIFO lock on the freshest value, two
			-- interleaved unlocks (or an interleaved sell/buy) serialise: the second re-reads the
			-- already-deducted balance + already-set flag and can never overspend or double-grant.
			local rejectCode: string? = nil
			local rejectMessage: string? = nil
			local outCost = 0
			local outBalance = 0

			local updated = ctx.data:update(ctx.player, function(d)
				-- VIP gate: a vip island ALSO needs the gamepass.vipIsland ownership flag. Re-read from
				-- the lock-held snapshot so a flag granted concurrently is honored.
				if island.vip then
					local flags = d.flags or {}
					if flags[VIP_FLAG] ~= true then
						rejectCode = Result.Codes.NotOwner
						rejectMessage = "vip island requires gamepass.vipIsland"
						return d
					end
				end

				-- Already unlocked: idempotent no-op rejection (no second deduction). This is the
				-- spam-duplicate guard — a second request that re-reads the post-write flag stops here.
				if isUnlocked(d, index) then
					rejectCode = Result.Codes.OutOfRange
					rejectMessage = "island already unlocked"
					return d
				end

				-- ORDER gate: the immediate predecessor must already be unlocked (re-read snapshot).
				if not isUnlocked(d, index - 1) then
					rejectCode = Result.Codes.OutOfRange
					rejectMessage = "previous island not unlocked"
					return d
				end

				-- Affordability against the SERVER-DERIVED cost (re-read balance).
				local balance = (d.currencies.Stardust or 0)
				local cost = island.cost
				if balance < cost then
					rejectCode = Result.Codes.Insufficient
					rejectMessage = "cannot afford island"
					return d
				end

				-- Affordable + earned + (if vip) owned: deduct EXACTLY the server cost AND set the unlock
				-- flag, both inside this one synchronous, lock-held transform. flags is always present on
				-- real PlayerData (default()/migrate seed it); guard defensively for a minimal test fake.
				local newBalance = balance - cost
				d.currencies.Stardust = newBalance
				if d.flags == nil then
					d.flags = {}
				end
				d.flags[islandFlagKey(island.id)] = true

				outCost = cost
				outBalance = newBalance
				return d
			end)

			if not updated.ok then
				-- The data write itself failed (NoData / transient). Surface it; the transform returns `d`
				-- whole on every path, so there is no partial change to undo.
				return updated
			end

			-- A server-side rejection decided INSIDE the transform (snapshot-based). No mutation
			-- happened, so balance and flags are unchanged and persisted as-is.
			if rejectCode ~= nil then
				return Result.err(rejectCode :: string, rejectMessage)
			end

			-- Emit AFTER a successful unlock. Two events THROUGH ctx.analytics (NIL-SAFE — a no-op when
			-- analytics is absent, e.g. focused tests): `progression` (an island was unlocked) and
			-- `currency_spent` (the Stardust sink). A spend is NOT an earn, so lifetimeStardust is
			-- untouched (handled by the data layer's earn paths only).
			if ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("progression", {
					userId = ctx.player.UserId,
					kind = "island_unlock",
					islandId = island.id,
					multiplier = island.multiplier,
				});
				(ctx.analytics :: any):emit("currency_spent", {
					userId = ctx.player.UserId,
					currency = "Stardust",
					amount = outCost,
					sink = "island_unlock",
					islandId = island.id,
				})
			end

			return Result.ok({
				islandId = island.id,
				cost = outCost,
				balance = outBalance,
				multiplier = island.multiplier,
			})
		end,
	}
end

-- ----- FetchIslands: read-only UI state -----
-- Returns the SERVER-OWNED catalog projection (id, cost, multiplier, vip, order) plus this player's
-- per-island unlocked boolean, so the UI can render the unlock pads without ever learning a price
-- client-side or being able to spoof one. Pure read through ctx.data:get (no mutation, no yield).
type IslandView = {
	id: number,
	order: number,
	cost: number,
	multiplier: number,
	vip: boolean,
	unlocked: boolean,
}
local function makeFetchIslandsAction(): Net.Action<{}, { islands: { IslandView } }>
	return {
		name = Net.Actions.FetchIslands, -- "islands.fetch"
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(ctx, _payload): Result.Result<{ islands: { IslandView } }>
			local got = ctx.data:get(ctx.player)
			if not got.ok then
				return got
			end
			local d = got.value
			local out: { IslandView } = {}
			for index, island in CATALOG do
				table.insert(out, {
					id = island.id,
					order = index,
					cost = island.cost,
					multiplier = island.multiplier,
					vip = island.vip,
					unlocked = isUnlocked(d, index),
				})
			end
			return Result.ok({ islands = out })
		end,
	}
end

-- Start: register both actions and publish the per-player multiplier seam onto the shared context so
-- every handler's ActionContext (built per-request by NetServer) sees ctx.islands from now on — the
-- consolidated Sell formula reads the highest-unlocked-island multiplier through it.
function IslandsService:Start(context: any): ()
	context.net:register(makeUnlockIslandAction())
	context.net:register(makeFetchIslandsAction())
	context.islands = IslandsSeam
end

return IslandsService
