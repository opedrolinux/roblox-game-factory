--!strict
-- core/src/server/data/DataService.luau
-- Session-scoped per-player data: the service feature code actually uses. Owns the
-- player->session lifecycle and is the ONLY thing that holds Store sessions. Lune-clean:
-- store/clock/config are INJECTED (never sibling-requires a Roblox-only module); specs call
-- get/update/save directly with a Mocks.player. Only Start connects Roblox events, and no
-- spec calls Start. See docs/CORE-DESIGN.md §4.4.
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox (a different service than this
-- ServerScriptService module), so the relative strings can't reach it there — require by instance;
-- under Lune (script == nil) the filesystem paths resolve.
local Migrations, Types, Result
if script == nil then
	Migrations = require("../../shared/Migrations")
	Types = require("../../shared/Types")
	Result = require("../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Migrations = require((Shared :: any).Migrations)
	Types = require((Shared :: any).Types)
	Result = require((Shared :: any).Result)
end
type Result<T> = Result.Result<T>

-- Backoff between retries. Lune-safe: the Roblox `task` global is NIL under Lune, so we only
-- call task.wait when it actually exists (runtime). In BOTH runtimes we advance the injected
-- clock when it is the fake test clock (has `advance`), so the throttle floor clears between
-- retries and tests need not yield. This keeps DataService spec-callable without a real `task`.
local function backoff(clock: any, seconds: number): ()
	if type(clock) == "table" and type(clock.advance) == "function" then
		clock:advance(seconds)
	end
	-- `task` is a real global in the Roblox runtime but NIL under Lune (verified). Reference it
	-- through a guarded ref so this module stays spec-callable; call only task.wait (approved).
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

export type StoreLike = {
	load: (self: any, key: string, default: () -> any) -> Result<any>,
	isLocked: (self: any, key: string) -> boolean,
}
export type ClockLike = {
	unix: (self: any) -> number,
	mono: (self: any) -> number,
}
export type ConfigLike = {
	storeName: string,
	schemaKeyPrefix: string,
	dataStore: {
		maxRetries: number,
		retryBaseSeconds: number,
		writeMinIntervalSeconds: number,
	},
}
export type PlayerLike = {
	UserId: number,
	Name: string,
}

local DataService = {}
DataService.__index = DataService

-- store/clock/config injected (D1 fallback). Lune-clean.
-- `logWarn` is an OPTIONAL injected diagnostic sink (data-loss-risk warnings). It defaults to the
-- Roblox `warn` global at runtime; Tier-1 tests pass a no-op (or stderr writer) so the runner's
-- single stdout JSON line is never polluted by a warn (selene forbids reassigning `warn`).
function DataService.new(
	store: StoreLike,
	clock: ClockLike,
	config: ConfigLike,
	logWarn: ((...any) -> ())?
): any
	local self = setmetatable({}, DataService)
	self.name = "DataService"
	self._store = store
	self._clock = clock
	self._config = config
	self._logWarn = logWarn or warn
	-- player UserId -> the live Store Session for that player.
	self._sessions = {} :: { [number]: any }
	-- optional NetServer for pushing the client-safe view; set during Start, nil in tests.
	self._net = nil :: any
	return self
end

-- Resolve the DataStore key for a player from the configured prefix.
function DataService.keyFor(self: any, player: PlayerLike): string
	return self._config.schemaKeyPrefix .. tostring(player.UserId)
end

-- Internal: load a player's session with a budget-aware retry loop (concern 5). Distinguishes
-- SessionLocked (another server releasing — retryable) from Internal (transient I/O).
function DataService.loadSession(self: any, player: PlayerLike): Result<any>
	local key = self:keyFor(player)
	local clock = self._clock
	local maxRetries = self._config.dataStore.maxRetries

	local attempt = 0
	while true do
		local default = function()
			return Migrations.default(clock:unix())
		end
		local loaded = self._store:load(key, default)
		if loaded.ok then
			local session = loaded.value
			-- Migrate on every load (round-trip safe; §3.5).
			session.data = Migrations.migrate(session.data)
			-- Bump join bookkeeping on the SERVER clock (never client time). joinCount increments on
			-- every load. lastSeenUnix is DELIBERATELY NOT re-stamped here: it is the offline-earnings
			-- base (Types §timestamps: "written on save/release"), so the value persisted at the previous
			-- release IS the start of the away window. Re-stamping it to `now` on join would collapse every
			-- offline window to zero (elapsed = now - now), so offline would never pay. A fresh player's
			-- base is the default()/creation time; release (and the offline claim) advance it forward.
			session.data.stats.joinCount = (session.data.stats.joinCount or 0) + 1
			self._sessions[player.UserId] = session
			return Result.ok(session)
		end

		-- SessionLocked: another server is releasing — retryable, distinct from Internal.
		local code = (loaded :: any).code
		if code ~= Result.Codes.SessionLocked and code ~= Result.Codes.Internal then
			-- Non-retryable error: surface it.
			return loaded
		end

		attempt += 1
		if attempt > maxRetries then
			return loaded -- exhausted budget: caller logs + kicks (cannot serve un-loadable data)
		end
		-- Back off per budget on the injected clock (Lune-safe; advances the fake clock).
		backoff(clock, self._config.dataStore.retryBaseSeconds * attempt)
	end
end

-- Returns the loaded PlayerData for a player, or Err("NoData") if not loaded yet.
function DataService.get(self: any, player: PlayerLike): Result<any>
	local session = self._sessions[player.UserId]
	if session == nil then
		return Result.err(Result.Codes.NoData, "session not loaded")
	end
	return Result.ok(session.data)
end

-- Concurrency-safe mutation: transform runs under the session lock (Session:update).
-- THE canonical write path for all economy/state changes. The transform MUST be synchronous
-- (no client-controllable yield inside it — §3.3 authoring rule).
function DataService.update(self: any, player: PlayerLike, transform: (any) -> any): Result<any>
	local session = self._sessions[player.UserId]
	if session == nil then
		return Result.err(Result.Codes.NoData, "session not loaded")
	end
	return session:update(transform)
end

-- Force a save (throttled/retried per budget). Normally automatic on release. Retries a
-- throttled/transient save up to maxRetries; a save that exhausts the budget surfaces the Err
-- (data-loss-risk) rather than being silently swallowed (concern 6 / §9.5).
function DataService.save(self: any, player: PlayerLike): Result<any>
	local session = self._sessions[player.UserId]
	if session == nil then
		return Result.err(Result.Codes.NoData, "session not loaded")
	end
	return self:saveSession(session)
end

-- Internal: save one session with budget-aware retry. Returns the final Result; on exhaustion
-- the Err surfaces (logged data-loss-risk by the caller), never silently dropped.
function DataService.saveSession(self: any, session: any): Result<any>
	local maxRetries = self._config.dataStore.maxRetries
	local attempt = 0
	while true do
		local saved = session:save()
		if saved.ok then
			return saved
		end
		attempt += 1
		if attempt > maxRetries then
			-- Data-loss-risk: surface rather than swallow.
			self._logWarn(
				`DataService.save: key "{session.key}" exhausted {maxRetries} retries: {tostring(
					(saved :: any).code
				)}`
			)
			return saved
		end
		-- Back off per budget; advancing the clock between attempts clears the throttle floor.
		backoff(self._clock, self._config.dataStore.retryBaseSeconds * attempt)
	end
end

-- Lifecycle (Start) — Roblox event wiring only (construct already happened in Context.build).
-- ROBLOX-ONLY at runtime: references `game`. No spec calls Start (tests call get/update/save).
function DataService.Start(self: any, context: any): ()
	self._net = context.net

	local Players = game:GetService("Players")

	local function onAdded(player: any): ()
		local loaded = self:loadSession(player)
		if not loaded.ok then
			self._logWarn(
				`DataService: failed to load {player.Name} ({(loaded :: any).code}); kicking`
			)
			player:Kick("Could not load your data. Please rejoin.")
			return
		end
		-- Push the client-safe view on load (§4.5).
		if self._net ~= nil then
			self._net:fireClient(player, "data", Types.toView(loaded.value.data))
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(onAdded, player)
	end
	Players.PlayerAdded:Connect(onAdded)

	Players.PlayerRemoving:Connect(function(player: any)
		local session = self._sessions[player.UserId]
		if session ~= nil then
			session.data.timestamps.lastSeenUnix = self._clock:unix()
			session:release()
			self._sessions[player.UserId] = nil
		end
	end)
end

-- Stop (BindToClose) — budget-aware full flush (concern 6). Flushes EVERY live session,
-- respecting the write budget, retrying per maxRetries; a save that exhausts retries is logged
-- as data-loss-risk, not silently dropped. With the instant mock it completes promptly; the
-- real SessionStore (B2) staggers to honor writeMinIntervalSeconds + the global write budget.
function DataService.Stop(self: any, _context: any): ()
	for userId, session in self._sessions do
		session.data.timestamps.lastSeenUnix = self._clock:unix()
		local released = self:saveSession(session)
		if not released.ok then
			self._logWarn(
				`DataService.Stop: data-loss-risk flushing {session.key}: {tostring(
					(released :: any).code
				)}`
			)
		end
		-- Release the lock regardless so a restart can re-acquire.
		session:release()
		self._sessions[userId] = nil
	end
end

return DataService
