--!strict
-- games/collect-sim/src/server/services/leaderboard/LeaderboardService.luau   [leaderboard]
-- Feature: an in-world leaderboard that ranks the PRESENT players by lifetime Stardust EARNED.
-- It is a PURE READER: it ranks by stats.lifetimeStardust (the contract-pass-provided monotonic
-- earn aggregate, accrued by every earn path — Sell / Daily — inside the data layer's lock-held
-- transforms). This feature NEVER computes or writes lifetimeStardust, NEVER mutates any currency,
-- and emits no analytics of its own. It only READS, ranks, and exposes a top-N snapshot for the UI.
--
-- WHY lifetimeStardust and not currencies.Stardust: the spendable currency is decremented on every
-- sink (island unlock, shop buy, rebirth), so it cannot represent a never-decreasing earn total. A
-- leaderboard of "top earners" must rank by the monotonic lifetime aggregate, which only ever rises.
--
-- ----- THE CROSS-PLAYER READ PROBLEM (state ownership) -----
-- A handler's narrow ActionContext (NetServer.actionContext) exposes ONLY the CALLING player and a
-- per-player data accessor (ctx.data:get(player)). It deliberately does NOT expose every present
-- player's data — that would be a spine change. So the leaderboard cannot rank "across all players"
-- from inside a single FetchLeaderboard handler.
--
-- Instead the service OWNS an in-memory ranking snapshot — an array of { userId, name,
-- lifetimeStardust } — that it rebuilds on a SERVER-TIME interval from the set of present players.
-- The rebuild is driven by `refresh(now, players, dataGet)`: the RUNTIME driver (Start, Roblox-only)
-- feeds it the live Players list + the bound ctx.data:get accessor on a task loop; Tier-1 tests feed
-- it fake players + a fake getter. The FetchLeaderboard handler then reads ONLY this owned snapshot
-- (a top-N slice), so it needs no cross-player context and stays a trivial pure read.
--
-- ----- CONCURRENCY / SAFETY -----
-- This feature performs ZERO economy mutation: there is no ctx.data:update call anywhere in it, so
-- there is no balance to double-grant, no read-then-write across a yield, no lock to contend. The
-- ONLY shared state is the service-owned `_snapshot`/`_lastRefreshUnix`, which is read+written only
-- on the single server thread (the refresh driver and the fetch handler both run on the server's
-- main thread; the read path takes a defensive COPY before sorting so a concurrent refresh can never
-- observe a half-sorted array). `refresh` itself only READS player data via the supplied getter and
-- replaces the snapshot wholesale, so a stale or missing read for one player degrades to that player
-- being absent/zero this cycle — never corrupts another player's rank and never writes anything.
--
-- Lune-clean: relative requires only; the Roblox `task`/`Players` globals are referenced ONLY behind
-- a runtime guard in Start (nil under Lune), so a spec drives refresh/maybeRefresh/fetch directly.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- ----- SERVER-OWNED TUNABLES (the client supplies none of this) -----
-- TOP_N: how many ranked entries the fetch returns (the in-world board shows the top slice).
local TOP_N = 10
-- REFRESH_INTERVAL: minimum SERVER seconds (ctx.clock:unix()) between full snapshot rebuilds. The
-- board refreshes on this server-time cadence (§7 — server clock, never client/wall time). Reads are
-- cheap (per-player get), but a board does not need sub-second freshness, so we coalesce.
local REFRESH_INTERVAL = 5

-- One ranked row exposed to the UI. lifetimeStardust is the monotonic earn aggregate; rank is 1-based.
export type Entry = {
	rank: number,
	userId: number,
	name: string,
	lifetimeStardust: number,
}

-- One internal snapshot row (pre-rank): exactly what a present player contributed this cycle.
type Row = {
	userId: number,
	name: string,
	lifetimeStardust: number,
}

-- Pure: read a player's lifetime Stardust from a data getter result, defaulting to 0 nil-safely. A
-- player whose data is not loaded (get -> Err) or whose stats are absent contributes 0 — they still
-- appear on the board (present but not-yet-earned), never crash the rebuild, never skew anyone else.
local function lifetimeFromGet(got: any): number
	if got == nil or got.ok ~= true then
		return 0
	end
	local data = got.value
	if type(data) ~= "table" then
		return 0
	end
	local stats = data.stats
	if type(stats) ~= "table" then
		return 0
	end
	local lifetime = stats.lifetimeStardust
	if type(lifetime) ~= "number" then
		return 0
	end
	-- Defensive: a NaN can never sort sanely. Treat it as 0 rather than poison the comparator.
	if lifetime ~= lifetime then
		return 0
	end
	return lifetime
end

-- Pure ranking: copy + sort rows DESCENDING by lifetimeStardust, breaking ties by ASCENDING userId
-- (a stable, deterministic order so the board never flickers between equal earners), then take the
-- top `n` and stamp 1-based ranks. Reads ONLY its argument; allocates a fresh result. No side effects.
local function rankTopN(rows: { Row }, n: number): { Entry }
	local copy: { Row } = {}
	for _, row in rows do
		table.insert(copy, row)
	end
	table.sort(copy, function(a: Row, b: Row): boolean
		if a.lifetimeStardust ~= b.lifetimeStardust then
			return a.lifetimeStardust > b.lifetimeStardust
		end
		-- Deterministic tiebreak: lower userId ranks first.
		return a.userId < b.userId
	end)
	local out: { Entry } = {}
	local limit = math.min(n, #copy)
	for index = 1, limit do
		local row = copy[index]
		table.insert(out, {
			rank = index,
			userId = row.userId,
			name = row.name,
			lifetimeStardust = row.lifetimeStardust,
		})
	end
	return out
end

local LeaderboardService = { name = "LeaderboardService" }
LeaderboardService.__index = LeaderboardService

-- ----- THE OWNED RANKING SNAPSHOT (service state, single-threaded server-side) -----
-- `refresh` REBUILDS the snapshot from the present players. `players` is the present-player list
-- (each only read for .UserId / .Name — the documented Player surrogate contract); `dataGet` is a
-- getter `(player) -> Result<PlayerData>` (production binds ctx.data:get; tests pass a fake). `now`
-- is SERVER time (ctx.clock:unix()). It only READS per-player data and replaces the snapshot
-- wholesale — never writes any player data, never mutates a currency. Returns the new snapshot size.
function LeaderboardService.refresh(
	self: any,
	now: number,
	players: { any },
	dataGet: (any) -> any
): number
	local rows: { Row } = {}
	for _, player in players do
		if type(player) == "table" and type(player.UserId) == "number" then
			local got = dataGet(player)
			table.insert(rows, {
				userId = player.UserId,
				name = tostring(player.Name or `Player_{player.UserId}`),
				lifetimeStardust = lifetimeFromGet(got),
			})
		end
	end
	self._snapshot = rows
	self._lastRefreshUnix = now
	return #rows
end

-- Refresh ONLY if at least REFRESH_INTERVAL SERVER seconds have elapsed since the last rebuild (the
-- server-time cadence, §7). The first call (lastRefreshUnix == nil) always refreshes. Returns true
-- iff it rebuilt this call, so a runtime loop or a test can assert the cadence deterministically.
function LeaderboardService.maybeRefresh(
	self: any,
	now: number,
	players: { any },
	dataGet: (any) -> any
): boolean
	local last = self._lastRefreshUnix
	if last ~= nil and (now - last) < REFRESH_INTERVAL then
		return false
	end
	self:refresh(now, players, dataGet)
	return true
end

-- Pure read of the OWNED snapshot: the current top-N ranking. Takes a defensive copy inside rankTopN
-- so a concurrent refresh can never be observed mid-sort. Reads nothing but service state; writes
-- nothing. This is the single source the FetchLeaderboard handler returns.
function LeaderboardService.topN(self: any, n: number?): { Entry }
	local rows: { Row } = self._snapshot or {}
	return rankTopN(rows, n or TOP_N)
end

-- Build the FetchLeaderboard action as a closure over THIS service instance, so the handler reads the
-- owned, interval-refreshed snapshot. READ-ONLY: it validates the empty intent, then returns the
-- current top-N ranking. No ctx.data:update, no currency touched, no analytics — a pure reader.
local function makeFetchLeaderboardAction(service: any): Net.Action<{}, { entries: { Entry } }>
	return {
		name = Net.Actions.FetchLeaderboard, -- "leaderboard.fetch"
		-- A UI poll: a generous per-second window (the board may refresh a few times a second on the
		-- client), still rate-shed so a spammer cannot abuse it. It reads owned state only — cheap.
		rate = { maxPerWindow = 10, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload: accept ONLY the empty intent. No client field is ever read (the server
			-- decides the ranking + the N), so a smuggled count/userId/score is ignored by never being
			-- copied out. A non-table payload is malformed.
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(_ctx, _payload): Result.Result<{ entries: { Entry } }>
			-- Pure read of the owned snapshot. Server-derived ranking; no client number honored, no
			-- mutation, no yield. The snapshot is kept fresh by the interval-driven refresh loop.
			return Result.ok({ entries = service:topN(TOP_N) })
		end,
	}
end

-- Start: register the read-only FetchLeaderboard action, then stand up the SERVER-TIME refresh driver.
-- The driver is the ONLY Roblox-dependent part (Players + task), so it is referenced behind a runtime
-- guard: under Lune (where both globals are nil) Start still registers the action and leaves the
-- snapshot empty/driveable by tests; at runtime it spins a task loop that calls maybeRefresh on the
-- server-time cadence over the live Players list and the bound ctx.data:get accessor.
function LeaderboardService:Start(context: any): ()
	self._snapshot = {} :: { Row }
	self._lastRefreshUnix = nil :: number?

	context.net:register(makeFetchLeaderboardAction(self))

	-- The data getter the refresh uses: the per-player, lock-queued read path. Bound here so the
	-- refresh function stays storage-agnostic (tests pass their own getter). Read-only — never update.
	local dataGet = function(player: any): any
		return context.data:get(player)
	end

	-- RUNTIME-ONLY driver. `task`/`game` are real globals on the Roblox server but NIL under Lune
	-- (verified — DataService uses the same guarded-ref pattern). We touch them only when they exist,
	-- so this module stays spec-callable (a spec drives refresh/maybeRefresh/topN directly instead).
	local realTask: any = task
	local realGame: any = game
	if realTask == nil or type(realTask.spawn) ~= "function" or realGame == nil then
		return
	end
	local Players = realGame:GetService("Players")

	-- Spin a single background loop on the SERVER clock cadence. Each tick: read SERVER time from the
	-- injected clock (§7 — never os.time/wall time) and maybeRefresh over the present players. The loop
	-- yields REFRESH_INTERVAL between ticks; maybeRefresh itself re-gates on server time, so even if the
	-- loop were ever driven faster it would not over-refresh.
	realTask.spawn(function(): ()
		while true do
			local now = context.clock:unix()
			self:maybeRefresh(now, Players:GetPlayers(), dataGet)
			realTask.wait(REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
