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
	-- [B2 D5] set by Stop so the periodic autosave loop does not race the shutdown flush.
	self._autosaveStopped = false
	-- [B2 B-1] userId -> true between beginJoin and finishJoin. loadSession YIELDS (it can poll a
	-- contended lock for sessionLockedWaitSeconds), and a player can leave inside that window —
	-- at which point PlayerRemoving finds an empty session slot and does nothing. This flag is
	-- how the install boundary learns the player already left.
	self._joining = {} :: { [number]: boolean }
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
			-- [offline join-race] SNAPSHOT THE AWAY-WINDOW BASE AT INSTALL TIME, before this session
			-- is visible to anything. `autosaveTick` re-stamps data.timestamps.lastSeenUnix to NOW on
			-- every flush (see flushOne), and the offline feature can only observe a session AFTER the
			-- line below installs it — it has no hand-off from here, so it polls. A flush landing in
			-- that gap destroys the base before anything snapshotted it, and the away window is lost
			-- PERMANENTLY and silently (docs/LEARNINGS.md — it cost a previous game's earnings).
			-- Written ONCE per load and never touched by autosave, save or release, so the base does
			-- not depend on WHEN the offline hook wakes up. Captured RAW: the reader sanitizes, because
			-- a garbage persisted stamp must read as "no base", not throw inside the load path. Lives
			-- on the session object (not `self`), so it dies with the session and cannot go stale; the
			-- store persists only `session.data`, so this field is never written to the DataStore.
			local timestamps = session.data.timestamps
			session.joinBaseUnix = if type(timestamps) == "table"
				then timestamps.lastSeenUnix
				else nil
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

-- [offline join-race] The away-window BASE for this player's CURRENT session: the value
-- `timestamps.lastSeenUnix` held at the instant loadSession installed the session, RAW (the caller
-- sanitizes). Returns nil when no session is installed — never a substitute for `get`.
--
-- Read `timestamps.lastSeenUnix` off the live blob and you are reading a field autosaveTick rewrites
-- to NOW on every flush; a reader that wakes up after a flush sees "you were not away" and there is
-- nothing left anywhere to recover the window from. This accessor is the stable base that flush
-- cannot move. It is deliberately NOT part of the persisted shape: it describes THIS load.
-- Typed `any`, not `number?`, ON PURPOSE: a persisted blob can carry a garbage stamp (a string, a
-- NaN), and narrowing here would either be a lie or would have to sanitize — which is the reader's
-- job, so that "no usable base" stays ONE decision in ONE place.
function DataService.joinBaseFor(self: any, player: PlayerLike): any
	if self._dead[player.UserId] then
		return nil
	end
	local session = self._sessions[player.UserId]
	if session == nil then
		return nil
	end
	return session.joinBaseUnix
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
		self:markDead(player.UserId, Result.Codes.LockStolen, session)
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
		if code == Result.Codes.SessionClosed then
			-- Terminal and NORMAL: this session was torn down while a writer was parked. Not a
			-- data-loss-risk (whatever replaced it owns the record now), and deliberately NOT
			-- routed to markDead — that would kick a player whose live session is healthy.
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

-- Internal: release one session (final save + unlock) with the SAME budget-aware retry policy
-- saveSession uses. The leave path and the shutdown flush both go through here, because
-- `release` IS the final durable write — a single unretried attempt would lose a whole session's
-- progress to one transient throttle, and it is the most frequent durable write in a live game.
-- LockStolen stays terminal (the new owner is authoritative; retrying is pure waste).
function DataService.releaseSession(self: any, session: any): Result<any>
	local maxRetries = self._config.dataStore.maxRetries
	local attempt = 0
	while true do
		local released = session:release()
		if released.ok then
			return released
		end
		local code = (released :: any).code
		if code == Result.Codes.LockStolen then
			self._logWarn(
				`DataService.release: key "{session.key}" lock stolen — terminal, delta unrecoverable`
			)
			return released
		end
		if code == Result.Codes.SessionClosed then
			-- Already torn down (typically by an abandon that discarded the delta). Terminal;
			-- retrying cannot write. The loss, if any, was logged where the abandon happened.
			return released
		end
		attempt += 1
		if attempt > maxRetries then
			self._logWarn(
				`DataService.release: key "{session.key}" exhausted {maxRetries} retries: {tostring(
					code
				)}`
			)
			-- Terminal give-up. The store keeps a session alive across a transient failure so this
			-- loop can retry it — so someone must tell it when the retries are over. Every caller
			-- drops its reference right after this returns, so without an explicit abandon the
			-- session is orphaned with a live heartbeat renewing its lock forever, and the player
			-- is SessionLocked out of EVERY server. The delta is already lost; the lock must not be.
			if type(session.abandon) == "function" then
				local ok, err = pcall(function()
					session:abandon()
				end)
				if not ok then
					self._logWarn(`DataService.release: abandon errored: {tostring(err)}`)
				end
			end
			return released
		end
		backoff(self._clock, self._config.dataStore.retryBaseSeconds * attempt)
	end
end

-- [B2 B-1] Join lifecycle. Call beginJoin BEFORE loadSession, noteDeparture as the FIRST thing a
-- leave does, and finishJoin with the load result. finishJoin returns true when the session is
-- live and should be served (push the client view); false when the player left mid-load, in which
-- case it performs the leave work the empty-slot PlayerRemoving skipped.
--
-- Without this the session is installed for a player who is already gone and nothing ever releases
-- it: SessionStore has spawned its heartbeat, which renews the lock for the SERVER'S WHOLE
-- LIFETIME, so that player is SessionLocked out of every other server (40s budget burn, then
-- kicked) — the H1 kick-loop reached through a different door. The autosave also re-stamps their
-- lastSeenUnix every interval, continuously destroying the offline-earnings base, and the stale
-- liveSessions entry inflates the write budget.
function DataService.beginJoin(self: any, player: PlayerLike): ()
	self._joining[player.UserId] = true
end

function DataService.noteDeparture(self: any, player: PlayerLike): ()
	self._joining[player.UserId] = nil
end

function DataService.finishJoin(self: any, player: PlayerLike, loaded: Result<any>): boolean
	local userId = player.UserId
	local stillPresent = self._joining[userId] == true
	self._joining[userId] = nil
	if not loaded.ok then
		return false
	end
	if stillPresent then
		return true
	end
	-- Left during the load: run the leave path now, on the session that was just installed.
	local session = (loaded :: any).value
	session.data.timestamps.lastSeenUnix = self._clock:unix()
	local released = self:releaseSession(session)
	if not released.ok then
		self._logWarn(
			`DataService.finishJoin: release for departed {player.Name} failed: {tostring(
				(released :: any).code
			)}`
		)
	end
	self:clearSession(userId, session)
	self._dead[userId] = nil
	return false
end

-- Retire a player's session slot, but only if it still holds `session` (pass nil to clear
-- unconditionally). Every teardown path now runs after a multi-second retry loop, during which a
-- same-server rejoin can install a replacement — clearing blindly would delete the live session
-- and strand the player with no data.
function DataService.clearSession(self: any, userId: number, session: any?): ()
	if session == nil or self._sessions[userId] == session then
		self._sessions[userId] = nil
	end
end

-- [B2 H2/D4/D7] Terminal teardown for a stolen session: the in-memory delta can never persist
-- (the new owner is authoritative), so stop serving it and notify the D7 seam (runtime default,
-- set in Start: kick with a "rejoin to sync" message; tests inject a spy). pcall-guarded — a
-- bad onDead must never break the data path.
-- `session` is optional but SHOULD be passed: it hands the store its session back so the store
-- drops it too. Without that the store keeps the entry for the server's whole lifetime, its
-- `isLocked(key)` then lies about a session we no longer own, and the data blob leaks. Releasing
-- a stolen session writes NOTHING (the store short-circuits on its own steal flag) — it only
-- tears down.
function DataService.markDead(self: any, userId: number, code: string, session: any?): ()
	-- Identity-guarded (same reasoning as the store's teardown): the save/release paths now retry
	-- for seconds, and a same-server rejoin inside that window installs a NEW session for this
	-- userId. A resuming loop that then cleared the slot unconditionally would evict the LIVE
	-- session, leaving the player in-game with no data at all (every get/update/save returns
	-- NoData). Only retire the slot if it still holds the session we were working on.
	-- Capture identity BEFORE clearSession nils the slot, then gate EVERY userId-keyed effect on
	-- it — not just the slot. `_dead` is checked ahead of `_sessions` by get/update/save, so a
	-- stale session's marker would shadow a live, healthy replacement for its whole life, and the
	-- onDead default kicks that player. Guarding only the slot (as the first pass did) leaves the
	-- two more damaging effects unguarded.
	local isCurrent = session == nil or self._sessions[userId] == session
	self:clearSession(userId, session)
	if session ~= nil then
		local ok, err = pcall(function()
			session:release()
		end)
		if not ok then
			self._logWarn(`DataService.markDead: store teardown errored: {tostring(err)}`)
		end
	end
	if not isCurrent then
		return -- a stale session died; the live replacement is unaffected
	end
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
-- Dispatched CONCURRENTLY for the same reason Stop is: each save can block on the store's global
-- write limiter, so a serial pass over a full server would take longer than the interval itself
-- and the disclosed "crash costs at most one autosave interval" guarantee would quietly stop
-- being true. Under Lune every flush completes synchronously, so the returned counts stay
-- deterministic for specs.
function DataService.autosaveTick(self: any): { flushed: number, stolen: number }
	local realTask: any = task
	local flushed = 0
	local stolen = 0
	local pending = 0

	local function flushOne(userId: number, session: any): ()
		local ok, err = pcall(function()
			-- Stop may have begun while this thread was queued behind the store's write limiter;
			-- flushing now would burn shutdown budget and re-stamp a record Stop just released.
			if self._autosaveStopped then
				return
			end
			session.data.timestamps.lastSeenUnix = self._clock:unix()
			local saved = self:saveSession(session)
			if saved.ok then
				flushed += 1
			elseif (saved :: any).code == Result.Codes.LockStolen then
				stolen += 1
				self:markDead(userId, Result.Codes.LockStolen, session)
			end
		end)
		if not ok then
			-- pcall'd so `pending` is ALWAYS decremented: the drain loop below has no deadline,
			-- so a single escaping error (e.g. a throwing injected logWarn) would hang the
			-- autosave thread forever and silently kill the only periodic durability mechanism.
			pcall(function()
				self._logWarn(`DataService.autosaveTick: flush errored: {tostring(err)}`)
			end)
		end
		pending -= 1
	end

	-- Snapshot the keys first: markDead mutates _sessions, and mutating a table while iterating
	-- it is undefined behavior in Luau.
	local live: { { userId: number, session: any } } = {}
	for userId, session in self._sessions do
		table.insert(live, { userId = userId, session = session })
	end

	for _, entry in live do
		pending += 1
		if realTask ~= nil and type(realTask.spawn) == "function" then
			realTask.spawn(flushOne, entry.userId, entry.session)
		else
			flushOne(entry.userId, entry.session)
		end
	end

	while pending > 0 and realTask ~= nil and type(realTask.wait) == "function" do
		realTask.wait(0.1)
	end
	return { flushed = flushed, stolen = stolen }
end

-- THE leave path: the player's final durable write, then the session slot is retired. Extracted
-- from Start's PlayerRemoving closure so the ORDER it sits in is expressible ([AMENDMENT A10b] —
-- src/server/framework/PlayerLifecycle calls this LAST, after analytics has read the still-loaded
-- blob) and so Tier-1 can drive it. Roblox-free, like every other method on this service.
function DataService.onPlayerRemoving(self: any, player: PlayerLike): ()
	-- FIRST: record the departure, so a load still in flight installs nothing orphaned. (The
	-- lifecycle owner calls this too, at the head of the sequence; it is idempotent.)
	self:noteDeparture(player)
	local session = self._sessions[player.UserId]
	if session ~= nil then
		session.data.timestamps.lastSeenUnix = self._clock:unix()
		-- Budget-aware RETRY: this is the session's final durable write, so a single
		-- throttled attempt would discard everything the player just did.
		local released = self:releaseSession(session)
		if not released.ok then
			self._logWarn(
				`DataService: release for {player.Name} failed: {tostring((released :: any).code)}`
			)
		end
		-- Identity-guarded: releaseSession above can retry for seconds, and a fast rejoin
		-- inside that window installs a new session for this userId.
		self:clearSession(player.UserId, session)
		-- Leaving clears any dead marker (a rejoin starts fresh) — but ONLY when this leave
		-- corresponds to the session we just released. Clearing unconditionally could
		-- un-mark a genuinely dead live replacement and resume serving its stale data.
		self._dead[player.UserId] = nil
	elseif self._sessions[player.UserId] == nil then
		self._dead[player.UserId] = nil
	end
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
		self:beginJoin(player)
		local loaded = self:loadSession(player)
		if not loaded.ok then
			self:finishJoin(player, loaded)
			self._logWarn(
				`DataService: failed to load {player.Name} ({(loaded :: any).code}); kicking`
			)
			player:Kick("Could not load your data. Please rejoin.")
			return
		end
		-- loadSession yields, so the player may already be gone; finishJoin releases the session
		-- in that case rather than leaving an orphan holding the lock forever.
		if not self:finishJoin(player, loaded) then
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

	-- [AMENDMENT A10b] PlayerRemoving is a PINNED SEQUENCE — AnalyticsService session_end (which
	-- needs the still-loaded blob) -> PlotService release -> THIS release, which invalidates the
	-- blob. src/server/framework/PlayerLifecycle owns that sequence and Starts before this service,
	-- setting context.playerRemovingOwner. Connecting here as well would run the release from a
	-- SECOND handler on the same signal, in an order this game does not control — which is exactly
	-- how session_end came to fire on a released session and report the join-time snapshot.
	-- Still connect when nobody claimed it: a bootstrap that drops the lifecycle must degrade to
	-- "analytics may be stale", never to "sessions are never released".
	if context.playerRemovingOwner == nil then
		Players.PlayerRemoving:Connect(function(player: any)
			self:onPlayerRemoving(player)
		end)
	end

	-- [B2 D5] periodic autosave: bounds ungraceful-crash data-loss to one interval. 0 disables
	-- (save-on-release-only). NOTE the SessionStore heartbeat (MemoryStore TTL renew) is a
	-- SEPARATE, store-internal loop on a different substrate (§4.4) — this loop only flushes
	-- DataStore data.
	local autosaveInterval = self._config.dataStore.autosaveIntervalSeconds or 0
	if autosaveInterval > 0 then
		task.spawn(function()
			while not self._autosaveStopped do
				task.wait(autosaveInterval)
				if self._autosaveStopped then
					break
				end
				-- pcall: an unguarded error here would silently kill the ONLY periodic
				-- durability mechanism for the rest of the server's life — every player would
				-- then be relying on release-only saves without any signal that it happened.
				local ok, err = pcall(function()
					self:autosaveTick()
				end)
				if not ok then
					self._logWarn(`DataService.autosave: tick errored: {tostring(err)}`)
				end
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
	-- Stop the periodic autosave first: left running it would race this flush, burn write-budget
	-- tokens the shutdown window cannot spare, and re-stamp records these releases just cleared.
	self._autosaveStopped = true

	local function flushOne(userId: number, session: any): ()
		local ok, err = pcall(function()
			session.data.timestamps.lastSeenUnix = self._clock:unix()
			-- ONE durable write per key (§7). `release` IS the final save (it flushes AND clears
			-- the lock stamp), so the previous save-then-release did two writes per player and
			-- halved the effective shutdown capacity in the exact window the budget protects.
			local released = self:releaseSession(session)
			if not released.ok then
				local code = (released :: any).code
				self._logWarn(
					`DataService.Stop: data-loss-risk flushing {session.key}: {tostring(code)}`
				)
				if code == Result.Codes.LockStolen then
					-- [B2 H2/D4] stolen: wrote nothing, and the new owner's lock is left
					-- untouched; dead-session teardown instead.
					self:markDead(userId, code, session)
					return
				end
			end
			self:clearSession(userId, session)
		end)
		if not ok then
			-- pcall'd for the same reason as autosaveTick: `pending` must always reach 0 or the
			-- drain loop below holds BindToClose until the engine kills the server.
			pcall(function()
				self._logWarn(`DataService.Stop: flush errored: {tostring(err)}`)
			end)
		end
		pending -= 1
	end

	-- Snapshot first: flushOne clears _sessions (and markDead mutates it too), and under Lune it
	-- runs synchronously inside this loop — mutating a table while iterating it is undefined.
	local live: { { userId: number, session: any } } = {}
	for userId, session in self._sessions do
		table.insert(live, { userId = userId, session = session })
	end

	for _, entry in live do
		pending += 1
		if realTask ~= nil and type(realTask.spawn) == "function" then
			-- Roblox: concurrent dispatch (D8) — each key's flush yields through the store's
			-- writes while the store's global limiter paces the burst within budget. A bare
			-- coroutine.resume would strand the thread at the first scheduler yield; task.spawn
			-- parks/resumes it correctly.
			realTask.spawn(flushOne, entry.userId, entry.session)
		else
			-- Lune (mock store): run synchronously — deterministic for specs, and an injected
			-- logWarn may yield through Lune's async stdio, which only the MAIN thread survives.
			flushOne(entry.userId, entry.session)
		end
	end

	-- Hold BindToClose until every concurrent flush lands (Roblox only: under Lune the flushes
	-- already completed synchronously, so this loop never spins).
	while pending > 0 and realTask ~= nil and type(realTask.wait) == "function" do
		realTask.wait(0.1)
	end
end

return DataService
