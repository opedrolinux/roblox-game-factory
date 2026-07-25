--!strict
-- core/src/server/data/DataService.luau
-- Session-scoped per-player data: the service feature code actually uses. Owns the
-- player->session lifecycle and is the ONLY thing that holds Store sessions. Lune-clean:
-- store/clock/config are INJECTED (never sibling-requires a Roblox-only module); specs call
-- get/update/save directly with a Mocks.player. Only Start connects Roblox events, and no
-- spec calls Start. See docs/CORE-DESIGN.md §4.4 + docs/B2-SESSIONSTORE-DESIGN.md §9 (the
-- OWNED B2 changes: the SessionLocked wait budget, terminal LockStolen + dead-session state,
-- the D7 onDead seam, the D5 autosave tick, the D8 concurrent Stop).
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
		-- [B2] optional so pre-B2 test-config stubs stay valid; DataService defaults them.
		lockTtlSeconds: number?,
		heartbeatIntervalSeconds: number?,
		autosaveIntervalSeconds: number?,
		sessionLockedWaitSeconds: number?,
		globalWritesPerMinute: number?,
	},
}
export type PlayerLike = {
	UserId: number,
	Name: string,
}

-- [B2 H1] fallback when a config predates the B2 tunables (§8): >= the recommended lockTtl (30s)
-- with margin, so a crashed owner's TTL lock is always waited out rather than kicked.
local DEFAULT_SESSION_LOCKED_WAIT_SECONDS = 40

local DataService = {}
DataService.__index = DataService

-- store/clock/config injected (D1 fallback). Lune-clean.
-- `logWarn` is an OPTIONAL injected diagnostic sink (data-loss-risk warnings). It defaults to the
-- Roblox `warn` global at runtime; Tier-1 tests pass a no-op (or stderr writer) so the runner's
-- single stdout JSON line is never polluted by a warn (selene forbids reassigning `warn`).
-- `onDead` is the OPTIONAL [B2 D7] dead-session seam: called (userId, code) when a session's lock
-- is stolen. Runtime default (set in Start): kick with a "rejoin to sync" message. Tests inject
-- a spy so the reaction is Tier-1-testable.
function DataService.new(
	store: StoreLike,
	clock: ClockLike,
	config: ConfigLike,
	logWarn: ((...any) -> ())?,
	onDead: ((userId: number, code: string) -> ())?
): any
	local self = setmetatable({}, DataService)
	self.name = "DataService"
	self._store = store
	self._clock = clock
	self._config = config
	self._logWarn = logWarn or warn
	self._onDead = onDead
	-- player UserId -> the live Store Session for that player.
	self._sessions = {} :: { [number]: any }
	-- [B2 H2] userId -> true while the session is DEAD (lock stolen, delta unrecoverable).
	-- Cleared by a fresh successful loadSession (rejoin) or the player leaving.
	self._dead = {} :: { [number]: boolean }
	-- optional NetServer for pushing the client-safe view; set during Start, nil in tests.
	self._net = nil :: any
	return self
end

-- Resolve the DataStore key for a player from the configured prefix.
function DataService.keyFor(self: any, player: PlayerLike): string
	return self._config.schemaKeyPrefix .. tostring(player.UserId)
end

-- Internal: load a player's session with a budget-aware retry loop (concern 5). Distinguishes
-- SessionLocked (another server holds the lock — [B2 H1] gets its own, larger TIME budget:
-- a crashed owner's TTL lock auto-expires within lockTtlSeconds, so waiting it out lets the
-- player rejoin instead of being kicked in a loop) from Internal (transient I/O — keeps the
-- attempt-counted maxRetries budget).
function DataService.loadSession(self: any, player: PlayerLike): Result<any>
	local key = self:keyFor(player)
	local clock = self._clock
	local dataStoreConfig = self._config.dataStore
	local maxRetries = dataStoreConfig.maxRetries
	local lockWaitBudget = dataStoreConfig.sessionLockedWaitSeconds
		or DEFAULT_SESSION_LOCKED_WAIT_SECONDS
	-- Fixed poll cadence while locked (we are waiting out a TTL, not backing off a fault);
	-- never zero, so the wait always advances toward the budget (no spin).
	local lockRetryStep = math.max(dataStoreConfig.retryBaseSeconds, 0.1)
	local startMono = clock:mono()

	local attempt = 0 -- counts Internal (transient I/O) attempts only
	while true do
		local default = function()
			return Migrations.default(clock:unix())
		end
		local loaded = self._store:load(key, default)
		if loaded.ok then
			local session = loaded.value
			-- Migrate on every load (round-trip safe; §3.5).
			session.data = Migrations.migrate(session.data)
			-- Bump join bookkeeping on the SERVER clock (never client time). joinCount increments
			-- on every load. lastSeenUnix is DELIBERATELY NOT re-stamped here: it is the
			-- offline-earnings base ("written on save/release"), so the value persisted at the
			-- previous release IS the start of the away window — re-stamping it on join collapses
			-- every offline window to zero (the collect-sim integration gate caught exactly this;
			-- docs/LEARNINGS.md). A fresh player's base comes from default(); release/autosave
			-- advance it forward.
			session.data.stats.joinCount = (session.data.stats.joinCount or 0) + 1
			self._sessions[player.UserId] = session
			-- [B2] a fresh session supersedes any dead marker (rejoin recovers).
			self._dead[player.UserId] = nil
			return Result.ok(session)
		end

		local code = (loaded :: any).code
		if code == Result.Codes.SessionLocked then
			-- [B2 H1] time-budgeted wait, NOT the attempt-counted Internal budget: still locked
			-- past sessionLockedWaitSeconds -> surface (caller kicks — the exhaustion path).
			if clock:mono() - startMono >= lockWaitBudget then
				return loaded
			end
			backoff(clock, lockRetryStep)
		elseif code == Result.Codes.Internal then
			attempt += 1
			if attempt > maxRetries then
				return loaded -- exhausted budget: caller logs + kicks (cannot serve un-loadable data)
			end
			-- Back off per budget on the injected clock (Lune-safe; advances the fake clock).
			backoff(clock, dataStoreConfig.retryBaseSeconds * attempt)
		else
			-- Non-retryable error: surface it.
			return loaded
		end
	end
end

-- Returns the loaded PlayerData for a player, or Err("NoData") if not loaded yet.
-- [B2 H2] a DEAD session (lock stolen) serves the dead-session code, never stale data: the
-- in-memory delta is unrecoverable and the authoritative record lives on the new owner.
-- Distinguishable from never-loaded (NoData) so callers can react.
function DataService.get(self: any, player: PlayerLike): Result<any>
	if self._dead[player.UserId] then
		return Result.err(Result.Codes.LockStolen, "session dead: rejoin to sync")
	end
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
	if self._dead[player.UserId] then
		return Result.err(Result.Codes.LockStolen, "session dead: rejoin to sync")
	end
	local session = self._sessions[player.UserId]
	if session == nil then
		return Result.err(Result.Codes.NoData, "session not loaded")
	end
	return session:update(transform)
end

-- Force a save (throttled/retried per budget). Normally automatic on release. Retries a
-- throttled/transient save up to maxRetries; a save that exhausts the budget surfaces the Err
-- (data-loss-risk) rather than being silently swallowed (concern 6 / §9.5).
-- [B2 H2/D4] a LockStolen save is TERMINAL: the session is torn down (markDead) — no retry.
function DataService.save(self: any, player: PlayerLike): Result<any>
	if self._dead[player.UserId] then
		return Result.err(Result.Codes.LockStolen, "session dead: rejoin to sync")
	end
	local session = self._sessions[player.UserId]
	if session == nil then
		return Result.err(Result.Codes.NoData, "session not loaded")
	end
	local saved = self:saveSession(session)
	if not saved.ok and (saved :: any).code == Result.Codes.LockStolen then
		self:markDead(player.UserId, Result.Codes.LockStolen)
	end
	return saved
end

-- Internal: save one session with budget-aware retry. Returns the final Result; on exhaustion
-- the Err surfaces (logged data-loss-risk by the caller), never silently dropped.
-- [B2 H2/D4] LockStolen is PERMANENT (the new owner is authoritative): retrying it wastes the
-- budget and starves other flushes during Stop — terminal, the CALLER tears the session down.
function DataService.saveSession(self: any, session: any): Result<any>
	local maxRetries = self._config.dataStore.maxRetries
	local attempt = 0
	while true do
		local saved = session:save()
		if saved.ok then
			return saved
		end
		local code = (saved :: any).code
		if code == Result.Codes.LockStolen then
			self._logWarn(
				`DataService.save: key "{session.key}" lock stolen — terminal, in-memory delta unrecoverable`
			)
			return saved
		end
		attempt += 1
		if attempt > maxRetries then
			-- Data-loss-risk: surface rather than swallow.
			self._logWarn(
				`DataService.save: key "{session.key}" exhausted {maxRetries} retries: {tostring(
					code
				)}`
			)
			return saved
		end
		-- Back off per budget; advancing the clock between attempts clears the throttle floor.
		backoff(self._clock, self._config.dataStore.retryBaseSeconds * attempt)
	end
end

-- [B2 H2/D4/D7] Terminal teardown for a stolen session: the in-memory delta can never persist
-- (the new owner is authoritative), so stop serving it and notify the D7 seam (runtime default,
-- set in Start: kick with a "rejoin to sync" message; tests inject a spy). pcall-guarded — a
-- bad onDead must never break the data path.
function DataService.markDead(self: any, userId: number, code: string): ()
	self._sessions[userId] = nil
	self._dead[userId] = true
	if self._onDead ~= nil then
		local ok, err = pcall(self._onDead, userId, code)
		if not ok then
			self._logWarn(`DataService.markDead: onDead errored: {tostring(err)}`)
		end
	end
end

-- [B2 D5] One periodic-flush pass over every live session (Tier-1-callable; Start's loop drives
-- it every autosaveIntervalSeconds in Roblox). Advances the offline base (lastSeenUnix) on each
-- flush so an ungraceful crash costs at most one interval of progress AND away-window. A stolen
-- session found here is torn down (markDead + onDead); transient failures were already logged by
-- saveSession and simply retry next tick.
function DataService.autosaveTick(self: any): { flushed: number, stolen: number }
	local flushed = 0
	local stolen = 0
	for userId, session in self._sessions do
		session.data.timestamps.lastSeenUnix = self._clock:unix()
		local saved = self:saveSession(session)
		if saved.ok then
			flushed += 1
		elseif (saved :: any).code == Result.Codes.LockStolen then
			stolen += 1
			self:markDead(userId, Result.Codes.LockStolen)
		end
	end
	return { flushed = flushed, stolen = stolen }
end

-- Lifecycle (Start) — Roblox event wiring only (construct already happened in Context.build).
-- ROBLOX-ONLY at runtime: references `game`. No spec calls Start (tests call get/update/save).
function DataService.Start(self: any, context: any): ()
	self._net = context.net

	local Players = game:GetService("Players")

	-- [B2 D7] default dead-session reaction: kick, so the player reloads on the authoritative
	-- server. Kick-loop-safe: the new owner holds the lock, so the rejoin loads fine there.
	if self._onDead == nil then
		self._onDead = function(userId: number, _code: string)
			local player = Players:GetPlayerByUserId(userId)
			if player ~= nil then
				player:Kick("Your data was loaded on another server. Please rejoin to sync.")
			end
		end
	end

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
			local released = session:release()
			if not released.ok then
				self._logWarn(
					`DataService: release for {player.Name} failed: {tostring(
						(released :: any).code
					)}`
				)
			end
			self._sessions[player.UserId] = nil
		end
		-- Leaving clears any dead marker (a rejoin starts fresh).
		self._dead[player.UserId] = nil
	end)

	-- [B2 D5] periodic autosave: bounds ungraceful-crash data-loss to one interval. 0 disables
	-- (save-on-release-only). NOTE the SessionStore heartbeat (MemoryStore TTL renew) is a
	-- SEPARATE, store-internal loop on a different substrate (§4.4) — this loop only flushes
	-- DataStore data.
	local autosaveInterval = self._config.dataStore.autosaveIntervalSeconds or 0
	if autosaveInterval > 0 then
		task.spawn(function()
			while true do
				task.wait(autosaveInterval)
				self:autosaveTick()
			end
		end)
	end
end

-- Stop (BindToClose) — budget-aware full flush (concern 6 / [B2 D8]). Flushes EVERY live
-- session CONCURRENTLY (each key writes once; the store's global write limiter paces the burst
-- within the global DataStore budget — a serial loop behind the per-key floor would flush ~5
-- players in the ~30s window and silently drop the rest). Each flush keeps its retry budget; a
-- save that exhausts retries is logged as data-loss-risk, not silently dropped. A stolen session
-- is torn down terminally (no retry burn, lock NOT released — the new owner is authoritative).
-- Under Lune (mock store, no yields) every flush completes synchronously, so specs stay
-- deterministic; in Roblox the final wait-loop holds BindToClose until every flush finishes.
function DataService.Stop(self: any, _context: any): ()
	local realTask: any = task
	local pending = 0

	local function flushOne(userId: number, session: any): ()
		local ok, err = pcall(function()
			session.data.timestamps.lastSeenUnix = self._clock:unix()
			local saved = self:saveSession(session)
			if not saved.ok then
				local code = (saved :: any).code
				self._logWarn(
					`DataService.Stop: data-loss-risk flushing {session.key}: {tostring(code)}`
				)
				if code == Result.Codes.LockStolen then
					-- [B2 H2/D4] stolen: do NOT write and do NOT release the new owner's
					-- lock; dead-session teardown instead.
					self:markDead(userId, code)
					return
				end
			end
			-- Release the lock regardless (idempotent) so a restart can re-acquire.
			session:release()
			self._sessions[userId] = nil
		end)
		if not ok then
			self._logWarn(`DataService.Stop: flush errored: {tostring(err)}`)
		end
		pending -= 1
	end

	for userId, session in self._sessions do
		pending += 1
		if realTask ~= nil and type(realTask.spawn) == "function" then
			-- Roblox: concurrent dispatch (D8) — each key's flush yields through the store's
			-- writes while the store's global limiter paces the burst within budget. A bare
			-- coroutine.resume would strand the thread at the first scheduler yield; task.spawn
			-- parks/resumes it correctly.
			realTask.spawn(flushOne, userId, session)
		else
			-- Lune (mock store): run synchronously — deterministic for specs, and an injected
			-- logWarn may yield through Lune's async stdio, which only the MAIN thread survives.
			flushOne(userId, session)
		end
	end

	-- Hold BindToClose until every concurrent flush lands (Roblox only: under Lune the flushes
	-- already completed synchronously, so this loop never spins).
	while pending > 0 and realTask ~= nil and type(realTask.wait) == "function" do
		realTask.wait(0.1)
	end
end

return DataService
