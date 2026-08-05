--!strict
-- games/deep-reach/src/server/services/leaderboard/LeaderboardService.luau   [feature: leaderboard]
--
-- THE authoritative owner of the top-N standings by `stats.lifetimeCredits`. Replaces the
-- contract-pass stub in place, preserving every contract decision the stub pinned: the action name
-- (Net.Actions.FetchLeaderboard), its RatePolicy ({5, 1.0s}), the closure-based registration (the
-- ranking snapshot IS service state and a static-module registration cannot reach it), and the
-- deliberate absence of a ctx seam (contract.stubs.leaderboard.seamProvided is null — nothing in the
-- game reads standings through a service, and a seam declared with no reader is a dangling promise
-- that gate-reachability's R1 rightly fails).
--
-- ── WHAT THIS SERVICE OWNS ──────────────────────────────────────────────────────────────────────
--   * A ranked snapshot of the players CURRENTLY ON THIS SERVER, ordered by stats.lifetimeCredits
--     descending, rebuilt on a SERVER-CLOCK cadence (REBUILD_INTERVAL_SECONDS, read from ctx.clock —
--     never os.time, never a client number) and cached per server.
--   * The `leaderboard.fetch` action, which serves the top-N slice of that snapshot plus the CALLER'S
--     OWN rank, derived server-side from the FULL ordering (not from the slice).
--   * A periodic server->client push of the same board over the shared RemoteEvent, so a board that
--     is on screen stays live without every client running its own poll.
--
-- ── IT ONLY READS. THIS IS THE WHOLE POINT ──────────────────────────────────────────────────────
-- `stats.lifetimeCredits` is the MONOTONIC earn aggregate. It is incremented by EconomyService on
-- every earn path, and every one of those paths lives in another feature (salvage, offline, daily,
-- monetization). This service therefore:
--   * NEVER calls ctx.data:update — it makes no persisted write of any kind, on any path;
--   * NEVER increments, decrements, seeds or heals lifetimeCredits;
--   * NEVER derives it from currencies.Credits (which is the SPENT-DOWN balance, so a leaderboard
--     ranked on it would demote the player who just bought something);
--   * NEVER requires a sibling service — the blob is read through the data layer (ctx.data:get), and
--     nothing else.
-- A leaderboard that writes its own ranking key is the written-never-read defect inverted: the number
-- on the board would then be a number only the board can see.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- THE STRONGEST FORM OF THE ARGUMENT IS THAT THERE IS NO MUTATION TO MAKE SAFE. This feature performs
-- ZERO economy mutations and ZERO data writes, so the read-then-write-across-a-yield hazard §4 exists
-- to close cannot arise here: there is no write to interleave with, nothing to zero before a yield and
-- nothing to restore after a failed one. Concretely:
--   * `ctx.data:get` is a synchronous table lookup (DataService.get: a `_dead` check, a `_sessions`
--     index, a Result). It does NOT yield. So `rank` below — which loops the whole roster calling
--     get — runs to completion with no interleaving point at all: Luau is single-threaded, so the
--     entire snapshot is built against ONE consistent instant of every player's blob. A snapshot that
--     yielded mid-build could rank one player's pre-collect total against another's post-collect one.
--   * The only mutable state is the per-server cache (`_snapshot`), and it is REPLACED WHOLESALE by a
--     freshly built table, never mutated in place. A reader therefore always holds either the old
--     complete snapshot or the new complete one, never a half-rebuilt mixture.
--   * Every board handed out is a COPY (`boardFor` clones each standing), so neither a client reply
--     nor a spec can reach into the cache and change what the next caller sees.
-- The spam-duplication defence is the CADENCE, not a lock: a burst of fetches inside one interval all
-- serve the same cached snapshot, so the rebuild cost is bounded by the clock rather than by how often
-- the client asks. The Gate's RatePolicy bounds the request rate on top of that.
--
-- ── NO PLAYER-AUTHORED TEXT (CLAUDE.md rule 9) ──────────────────────────────────────────────────
-- The only strings that leave this service are `player.Name` and `player.DisplayName`, both supplied
-- and moderated by Roblox. This feature has NO text input and must never grow one: the correct move
-- for rule 9 here is to have no player-authored text at all rather than to filter some.
--
-- ── SCOPE FENCE (v1) ────────────────────────────────────────────────────────────────────────────
-- SERVER-LOCAL ranking only. A cross-server global board (OrderedDataStore) is explicitly OUT of v1
-- scope, and there is no DataStore call anywhere in this file — all persistence goes through
-- src/server/data/ (CLAUDE.md §8), and this feature persists nothing.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- rank / build / current / boardFor / fetch / fetchAction are Roblox-FREE: a spec injects a roster
-- (`service._players`) plus Mocks.player + a real DataService over MockStore and drives the whole
-- ordering / tie-break / cadence / own-rank lifecycle with no engine. Only startRuntime and pushAll
-- touch `game` / `task`, each through a guarded local, so requiring and Starting this module under
-- Lune never throws.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT Rojo service root
-- than this ServerScriptService module — so the relative string cannot reach it there; require by
-- instance. Under Lune (script == nil) the filesystem path resolves.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

local LeaderboardService = {}
LeaderboardService.name = "LeaderboardService"

-- ── tunables (SERVER constants; the client never sends or influences any of them) ────────────────

-- How many standings the board shows. A SERVER constant on purpose: a client-supplied limit is a
-- free resource-exhaustion lever (ask for 10,000 rows at 5 requests/second), so the validator below
-- refuses a payload that names one rather than clamping it.
local TOP_N = 10

-- How often the snapshot is rebuilt, measured on the SERVER clock (ctx.clock:unix(), CLAUDE.md §7).
-- It is the cost bound: a fetch inside the interval serves the cache, so N players spamming the
-- action still cost ONE rebuild per interval.
local REBUILD_INTERVAL_SECONDS = 5

LeaderboardService.TOP_N = TOP_N
LeaderboardService.REBUILD_INTERVAL_SECONDS = REBUILD_INTERVAL_SECONDS

-- The RemoteEvent event name the periodic push uses. A plain push name (like the data layer's
-- "data"), NOT a Net.Actions entry: Net.Actions is the INBOUND action registry and src/shared is
-- read-only to feature work. The client controller subscribes with context.net:on("leaderboard", …).
local PUSH_EVENT = "leaderboard"
LeaderboardService.PUSH_EVENT = PUSH_EVENT

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

export type Standing = {
	rank: number, -- 1-based position in the FULL ordering, not in the slice
	userId: number,
	name: string, -- Roblox-provided Player.Name
	displayName: string, -- Roblox-provided Player.DisplayName (falls back to Name)
	lifetimeCredits: number,
}

export type Snapshot = {
	-- EVERY ranked player on this server, rank ascending. Held whole (not pre-sliced) so the caller's
	-- own rank can be answered from the cache even when they are nowhere near the top N.
	ranking: { Standing },
	builtAtUnix: number,
}

export type Board = {
	entries: { Standing }, -- the top-N slice, rank ascending
	topN: number,
	playerCount: number, -- how many players were ranked in this build
	builtAtUnix: number,
	nextRebuildUnix: number,
	you: {
		ranked: boolean, -- false when the caller was not in the ranked roster (e.g. mid-load)
		rank: number, -- 0 when not ranked
		lifetimeCredits: number,
	},
}

-- The cached snapshot for this server, or nil before the first build. Module-level so a spec can
-- drive `current` without Start.
LeaderboardService._snapshot = nil :: Snapshot?

-- The ServerContext, captured at Start: the periodic push needs context.net (the ActionContext
-- projection deliberately carries no net) and context.data.
LeaderboardService._context = nil :: any

-- TEST SEAM: an optional roster provider, `() -> { PlayerLike }`. nil in production, where the roster
-- is the engine's Players service. It exists because a spec has no engine and must still be able to
-- drive a full server's worth of standings.
LeaderboardService._players = nil :: (() -> { any })?

LeaderboardService._running = false

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6, whose header
-- records that this exact line once kept a leaderboard EMPTY in every live server while the tests
-- stayed green). Identity is therefore taken from the FIELD, which both a real Player and Mocks.player
-- answer.
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

-- Roblox-PROVIDED display strings only (rule 9 — see the header). Never a persisted string, never
-- anything a player typed; there is no such field on this game's blob and this feature must not add
-- one. A non-string Name (only reachable from a fabricated player) degrades to a server-generated
-- label rather than crossing the wire as a non-string.
local function nameOf(player: any, userId: number): string
	local name = (player :: any).Name
	if type(name) == "string" and name ~= "" then
		return name
	end
	return `Diver {userId}`
end

local function displayNameOf(player: any, fallback: string): string
	local displayName = (player :: any).DisplayName
	if type(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	return fallback
end

-- The ranking key, normalized. Garbage (absent / nil / NaN / infinite / negative / fractional) reads
-- as 0 rather than poisoning the sort. NaN is the dangerous one: every comparison against it is
-- false, so an unchecked NaN would make the comparator below non-transitive and table.sort's
-- "invalid order function" error would take the whole board down.
local function lifetimeCreditsOf(data: any): number
	if type(data) ~= "table" or type(data.stats) ~= "table" then
		return 0
	end
	local value = data.stats.lifetimeCredits
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if value == math.huge or value == -math.huge then
		return 0
	end
	if value < 0 then
		return 0
	end
	return math.floor(value)
end

local function sanitizeNow(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	if value == math.huge or value == -math.huge then
		return nil
	end
	return math.floor(value)
end

-- ── the roster ──────────────────────────────────────────────────────────────────────────────────

-- Who is on this server right now. The injected provider wins (Tier-1), then the engine, then an
-- empty roster. `game` is a real global in Roblox and NIL under Lune, so it is reached through a
-- guarded local and the pcall keeps a Players failure from turning a read-only board into an error.
--
-- The result local is deliberately NOT called `players`: `type(<anything containing "player">) ==
-- "table"` is the shape gate-reachability's R6 bans, because that guard is the line that once kept a
-- leaderboard empty in every live server (a real Player is USERDATA). The check here is on the LIST,
-- which genuinely is a table — but a rule that had to tell those two apart by identifier plurality
-- would be a rule with a hole in it, so the name gives way, not the rule.
function LeaderboardService.roster(self: any): { any }
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

-- ── the ranking ─────────────────────────────────────────────────────────────────────────────────

-- Build the FULL ordering from a roster. SYNCHRONOUS BY CONSTRUCTION — see the concurrency argument
-- in the header: `dataService:get` is a table lookup, so nothing in this loop can yield and the whole
-- ranking describes one instant.
--
-- A player whose session is not loaded (Err NoData — still joining) or is dead (Err LockStolen) is
-- SKIPPED rather than ranked at 0: a joining player flashing in at last place and then jumping is
-- worse than simply not being on the board for a second, and ranking a dead session would publish a
-- total the authoritative server has already superseded.
function LeaderboardService.rank(_self: any, dataService: any, roster: { any }): { Standing }
	local standings: { Standing } = {}
	if dataService == nil or type(roster) ~= "table" then
		return standings
	end

	-- Deduplicated by UserId: a roster is untrusted input to this function (a spec's, or an engine
	-- list read across a rejoin), and one player appearing twice would occupy two rows and double the
	-- board's idea of how many people are here.
	local seen: { [number]: boolean } = {}

	for _, player in roster do
		local userId = userIdOf(player)
		if userId ~= nil and not seen[userId] then
			seen[userId] = true
			local got = dataService:get(player)
			if type(got) == "table" and got.ok == true then
				local name = nameOf(player, userId)
				table.insert(standings, {
					rank = 0, -- assigned after the sort
					userId = userId,
					name = name,
					displayName = displayNameOf(player, name),
					lifetimeCredits = lifetimeCreditsOf(got.value),
				})
			end
		end
	end

	-- A TOTAL order, not merely a descending compare. Ties are broken by name and then by UserId
	-- (unique after the dedup above), so the comparator is irreflexive and transitive — table.sort
	-- raises "invalid order function" on a comparator that is not, and two players on exactly 0
	-- lifetime Credits is the COMMON case on a fresh server, not an edge one.
	table.sort(standings, function(a: Standing, b: Standing): boolean
		if a.lifetimeCredits ~= b.lifetimeCredits then
			return a.lifetimeCredits > b.lifetimeCredits
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.userId < b.userId
	end)

	for index, standing in standings do
		standing.rank = index
	end
	return standings
end

-- Build and CACHE a snapshot. Replaces the cache wholesale (never mutates the live one in place).
function LeaderboardService.build(
	self: any,
	dataService: any,
	clock: any,
	roster: { any }
): Snapshot
	local nowUnix = if clock ~= nil then sanitizeNow(clock:unix()) else nil
	local snapshot: Snapshot = {
		ranking = self:rank(dataService, roster),
		builtAtUnix = nowUnix or 0,
	}
	self._snapshot = snapshot
	return snapshot
end

-- The snapshot to serve. Rebuilds when there is none, when the SERVER clock says the cadence has
-- elapsed, or when `force` is set. A clock that returns nothing usable rebuilds every time rather
-- than pinning a stale board forever (the cheaper failure of the two).
function LeaderboardService.current(
	self: any,
	dataService: any,
	clock: any,
	roster: { any },
	force: boolean?
): Snapshot
	local cached = self._snapshot
	if force == true or cached == nil then
		return self:build(dataService, clock, roster)
	end
	local nowUnix = if clock ~= nil then sanitizeNow(clock:unix()) else nil
	if nowUnix == nil then
		return self:build(dataService, clock, roster)
	end
	local age = (nowUnix :: number) - (cached :: Snapshot).builtAtUnix
	-- A snapshot stamped in the FUTURE (a clock that moved backwards between builds) has a negative
	-- age, which would never reach the interval and would freeze the board for good. Rebuild on it.
	if age < 0 or age >= REBUILD_INTERVAL_SECONDS then
		return self:build(dataService, clock, roster)
	end
	return cached :: Snapshot
end

-- Project a snapshot into the board ONE player sees: the top-N slice plus THEIR own standing,
-- resolved from the FULL ordering so a player in 40th place still learns they are 40th.
--
-- Every standing is COPIED. The cache must not be reachable from a reply: a spec (or a future
-- in-process caller) that mutated a returned row would silently rewrite what the next fetch serves.
function LeaderboardService.boardFor(_self: any, snapshot: Snapshot, userId: number?): Board
	local entries: { Standing } = {}
	local ranking = snapshot.ranking
	local limit = math.min(TOP_N, #ranking)
	for index = 1, limit do
		table.insert(entries, table.clone(ranking[index]))
	end

	local you = { ranked = false, rank = 0, lifetimeCredits = 0 }
	if userId ~= nil then
		for _, standing in ranking do
			if standing.userId == userId then
				you = {
					ranked = true,
					rank = standing.rank,
					lifetimeCredits = standing.lifetimeCredits,
				}
				break
			end
		end
	end

	return {
		entries = entries,
		topN = TOP_N,
		playerCount = #ranking,
		builtAtUnix = snapshot.builtAtUnix,
		nextRebuildUnix = snapshot.builtAtUnix + REBUILD_INTERVAL_SECONDS,
		you = you,
	}
end

-- ── the read ────────────────────────────────────────────────────────────────────────────────────

-- THE handler body. Side-effect free by construction: it writes nothing, grants nothing and changes
-- no player's state — the only thing it can change is this server's cache, which is a derived value.
function LeaderboardService.fetch(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "leaderboard: context is missing data/clock")
	end
	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "leaderboard: player has no numeric UserId")
	end

	-- The caller's OWN session must be loaded before their rank means anything. Surfacing the data
	-- layer's Err(NoData) here is what lets the client's JoinRetry guard re-issue this fetch on the
	-- on-load data push — a join-time board that answered "you: unranked" would be indistinguishable
	-- from a genuinely unranked player and would never correct itself.
	local got = ctx.data:get(player)
	if not got.ok then
		return got
	end

	local snapshot = self:current(ctx.data, ctx.clock, self:roster())
	return Result.ok(self:boardFor(snapshot, userId))
end

-- ── the action ──────────────────────────────────────────────────────────────────────────────────

-- The fetch payload carries NOTHING BY CONTRACT — no row count, no page, no target player, no
-- ranking value. A payload that names one is REFUSED rather than ignored: an ignored parameter is
-- indistinguishable from a well-formed request, and the difference is the only signal that someone
-- is probing. `limit`/`count`/`top`/`n` in particular are the resource-exhaustion levers, and
-- `lifetimeCredits`/`rank` are the "just tell the server what my score is" levers — neither is
-- clamped here, because there is nothing to clamp: the validator hands the handler a FRESH EMPTY
-- TABLE, so the handler is never given a client number at all.
local FORBIDDEN_PAYLOAD_KEYS = {
	"limit",
	"count",
	"top",
	"topN",
	"n",
	"max",
	"offset",
	"page",
	"userId",
	"targetUserId",
	"rank",
	"lifetimeCredits",
	"credits",
	"name",
	"displayName",
	"sort",
	"order",
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
				`leaderboard.fetch takes no arguments — the SERVER owns the row count, the ordering `
					.. `and every value on the board (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

LeaderboardService.validate = validateNoArguments

-- Exported so a Tier-1 spec can register the action on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as a CLOSURE over the service because the cached
-- snapshot IS service state and a static-module registration cannot reach it (contract precisionNote).
function LeaderboardService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchLeaderboard,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB. Anti-spam only; the real cost bound is the rebuild
		-- CADENCE above, which makes a burst inside one interval serve the same cached snapshot.
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(ctx: any, _payload: any): any
			return self:fetch(ctx)
		end,
	}
end

-- ── the push ────────────────────────────────────────────────────────────────────────────────────

-- Rebuild once and push each player THEIR board (the `you` block differs per player, so this cannot
-- be one broadcast). Guarded + pcall'd per player: a presentation failure for one client must never
-- take down the loop that serves everyone else. Returns how many pushes went out, so a spec can
-- assert the loop body without an engine.
function LeaderboardService.pushAll(self: any, context: any): number
	if context == nil then
		return 0
	end
	local net = context.net
	local dataService = context.data
	if net == nil or type(net.fireClient) ~= "function" or dataService == nil then
		return 0
	end
	local roster = self:roster()
	local snapshot = self:build(dataService, context.clock, roster)
	local sent = 0
	for _, player in roster do
		local userId = userIdOf(player)
		if userId ~= nil then
			local board = self:boardFor(snapshot, userId)
			local ok = pcall(function()
				net:fireClient(player, PUSH_EVENT, board)
			end)
			if ok then
				sent += 1
			end
		end
	end
	return sent
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: capture the server context and register the wire surface. Installs NO ctx seam — see the
-- header. Lune-callable: everything engine-shaped lives behind startRuntime.
function LeaderboardService.Start(self: any, context: any): ()
	self._context = context
	self._snapshot = nil -- a fresh server starts from a fresh board
	context.net:register(self:fetchAction())
	self:startRuntime(context)
end

-- ROBLOX-ONLY: the periodic rebuild + push. `task` and `game` are real globals in Roblox and NIL
-- under Lune, so both are reached through guarded locals and a spec's Start never spawns anything.
function LeaderboardService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return -- Lune: no engine to wire. Specs drive fetch / current / pushAll directly.
	end
	if self._running then
		return -- idempotent: a second Start must not run two push loops
	end
	self._running = true
	realTask.spawn(function()
		while self._running do
			realTask.wait(REBUILD_INTERVAL_SECONDS)
			if not self._running then
				break
			end
			-- pcall'd: an unguarded error here would silently kill the ONLY thing keeping every
			-- open board on the server up to date, for the rest of the server's life.
			pcall(function()
				self:pushAll(context)
			end)
		end
	end)
end

function LeaderboardService.Stop(self: any, _context: any): ()
	self._running = false
	self._snapshot = nil
	self._context = nil
end

return LeaderboardService
