--!strict
-- games/deep-reach/src/server/services/analytics/AnalyticsService.luau   [contract pass — infra]
-- THE single analytics emitter for Deep Reach. Stood up exactly ONCE here so every feature emits
-- through the SAME seam (ctx.analytics:emit(event, payload)) instead of nine builders each inventing
-- their own event plumbing. Feature builders only CALL emit — they never re-implement it.
--
-- SEAM (contract.analytics.seam): `ctx.analytics:emit(event, payload)`. Nil-safe BY CONVENTION at the
-- call site (`if ctx.analytics ~= nil then ctx.analytics:emit(...) end`), so a spec that leaves the
-- seam nil is a no-op rather than a crash.
--
-- SCOPE (deliberately narrow): this module owns the TAXONOMY + the emit seam + the SESSION LIFECYCLE
-- (session_start / session_end). Every per-feature domain emit — currency_earned, currency_spent,
-- progression, purchase, loop_completed — belongs to the feature that owns its emit point
-- (contract.emitPoints). Writing them here too would build them twice and double-count.
--
-- TIER-1 OBSERVABILITY: every emit is stamped with the SERVER clock (clock:unix(), never client time,
-- never a bare os.time) and appended to an in-memory buffer the service exposes (events() /
-- eventsOfType()). ctx.analytics IS this object, so a spec asserts "event X fired with payload Y at
-- T" with no Roblox runtime. new()/emit()/events()/sessionStart()/sessionEnd()/onPlayerAdded()/
-- onPlayerRemoving()/assertInstalled() are ALL Roblox-free; only Start()/Stop() touch `game`.
--
-- Requires NOTHING (no Result, no Types): it reads `.ok` off a Result as a plain field, so this file
-- needs no D1 cross-mount shim and stays trivially Lune-requirable.

local AnalyticsService = {}
AnalyticsService.__index = AnalyticsService
AnalyticsService.name = "AnalyticsService"

-- The taxonomy this game emits, in contract order (contract.analytics.events). Exported as an
-- ORDERED list so a spec can assert completeness against the contract, and as a set so a typo'd
-- event name is observable via isKnownEvent without coupling features to this module.
AnalyticsService.TAXONOMY = {
	"session_start",
	"session_end",
	"loop_completed",
	"currency_earned",
	"currency_spent",
	"progression",
	"purchase",
} :: { string }

local EVENTS: { [string]: boolean } = {}
for _, event in AnalyticsService.TAXONOMY do
	EVENTS[event] = true
end

-- The buffer is the Tier-1 observation surface AND a live-server memory cost. Bounded so a
-- long-running server cannot grow it without limit; drops are COUNTED (droppedCount) rather than
-- silent, because a silently truncated buffer would make a later "the event never fired" reading
-- of a test indistinguishable from "the event was evicted".
local MAX_BUFFERED_EVENTS = 2000

-- How long onPlayerAdded waits for DataService.loadSession to resolve before giving up. The load
-- YIELDS (several DataStore round trips, plus up to sessionLockedWaitSeconds of lock waiting), and
-- session_start fired BEFORE it resolves has no data to describe — the contract's lifecycle rule.
local LOAD_WAIT_ATTEMPTS = 200
local LOAD_WAIT_STEP_SECONDS = 0.25

export type Event = {
	event: string,
	payload: any,
	at: number, -- server-clock unix stamp of the emit (clock:unix())
}

export type ClockLike = {
	unix: (self: any) -> number,
	mono: (self: any) -> number,
}

-- CONSTRUCTED in Context.build (no I/O here). `clock` is the injected server clock every emit is
-- stamped with.
function AnalyticsService.new(clock: ClockLike): any
	local self = setmetatable({}, AnalyticsService)
	self.name = "AnalyticsService"
	self._clock = clock
	self._events = {} :: { Event }
	self._dropped = 0
	-- userId -> what we knew about this session at join. Two jobs: the session_end playtime base,
	-- and the NON-EMPTY fallback payload described at onPlayerRemoving below.
	self._sessions = {} :: { [number]: any }
	self._connections = {} :: { any }
	-- Tunable so a spec can drive the join wait without yielding for 50 seconds.
	self.loadWaitAttempts = LOAD_WAIT_ATTEMPTS
	self.loadWaitStepSeconds = LOAD_WAIT_STEP_SECONDS
	return self
end

-- Whether `event` is part of the declared taxonomy. An unknown event is still RECORDED (nothing is
-- silently lost) but is observable as off-taxonomy.
function AnalyticsService.isKnownEvent(_self: any, event: string): boolean
	return EVENTS[event] == true
end

-- THE emit seam (contract.analytics.seam). Records event + payload, server-clock stamped, into the
-- in-memory buffer. Synchronous, no yield, no Roblox global — safe to call from inside a lock-held
-- DataService transform and callable from Tier-1.
function AnalyticsService.emit(self: any, event: string, payload: any): Event
	local record: Event = {
		event = event,
		payload = payload,
		at = self._clock:unix(),
	}
	table.insert(self._events, record)
	if #self._events > MAX_BUFFERED_EVENTS then
		table.remove(self._events, 1)
		self._dropped += 1
	end
	return record
end

-- A snapshot COPY of every recorded event in emit order (callers cannot mutate internals).
function AnalyticsService.events(self: any): { Event }
	return table.clone(self._events)
end

-- Every recorded event of one type, in emit order. The usual Tier-1 assertion surface.
function AnalyticsService.eventsOfType(self: any, name: string): { Event }
	local out: { Event } = {}
	for _, record in self._events do
		if record.event == name then
			table.insert(out, record)
		end
	end
	return out
end

-- How many events the bound buffer has evicted. Non-zero means `events()` is no longer the whole
-- history — surfaced so that is never mistaken for "it did not fire".
function AnalyticsService.droppedCount(self: any): number
	return self._dropped
end

-- PURE payload projection of a loaded PlayerData blob. Defensive about every field (a mid-migration
-- or partially-loaded blob must never make the emitter throw inside a player-lifecycle handler).
local function describe(data: any): any
	local currencies = if type(data) == "table" and type(data.currencies) == "table"
		then data.currencies
		else {}
	local stats = if type(data) == "table" and type(data.stats) == "table" then data.stats else {}
	return {
		credits = currencies.Credits or 0,
		pearls = currencies.Pearls or 0,
		lifetimeCredits = stats.lifetimeCredits or 0,
		joinCount = stats.joinCount or 0,
		schemaVersion = if type(data) == "table" then data.schemaVersion else nil,
	}
end

-- session_start. Called ONLY once the session's data load has resolved (see onPlayerAdded) — the
-- contract's rule, because before that the payload has no data to describe. Also records the
-- playtime base + the fallback snapshot used by session_end.
function AnalyticsService.sessionStart(self: any, player: any, data: any): Event
	local nowUnix = self._clock:unix()
	local described = describe(data)
	self._sessions[player.UserId] = {
		joinedAtUnix = nowUnix,
		name = player.Name,
		described = described,
	}
	local payload = {
		userId = player.UserId,
		name = player.Name,
		credits = described.credits,
		pearls = described.pearls,
		lifetimeCredits = described.lifetimeCredits,
		joinCount = described.joinCount,
		schemaVersion = described.schemaVersion,
	}
	return self:emit("session_start", payload)
end

-- session_end. `data` is the STILL-LOADED blob; pass nil when the data layer already released it and
-- the join-time snapshot is used instead (payload.stale = true). sessionSeconds comes from the
-- SERVER clock delta, never from anything the client sent.
function AnalyticsService.sessionEnd(self: any, player: any, data: any?): Event
	local nowUnix = self._clock:unix()
	local session = self._sessions[player.UserId]
	local described = if data ~= nil
		then describe(data)
		elseif session ~= nil then session.described
		else describe(nil)
	local joinedAtUnix = if session ~= nil then session.joinedAtUnix else nowUnix
	self._sessions[player.UserId] = nil
	local payload = {
		userId = player.UserId,
		name = player.Name,
		sessionSeconds = math.max(0, nowUnix - joinedAtUnix),
		credits = described.credits,
		pearls = described.pearls,
		lifetimeCredits = described.lifetimeCredits,
		joinCount = described.joinCount,
		schemaVersion = described.schemaVersion,
		-- TRUE when the blob was already gone and this payload is the join-time snapshot. The event
		-- is never empty, and a reader can tell a live payload from a reconstructed one.
		stale = data == nil,
	}
	return self:emit("session_end", payload)
end

-- Internal: the bounded wait. `task` is a real global in Roblox and NIL under Lune, so it is
-- referenced through a guarded ref and this module stays spec-callable. A spec injects
-- `service._wait` to step its fake data layer instead of sleeping.
function AnalyticsService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- Wait (bounded) for this player's session blob to be installed, then return it; nil if the budget
-- ran out or the player left mid-load. `dataService` is ctx.data — get() returns Err(NoData,
-- "session not loaded") until loadSession resolves.
function AnalyticsService.awaitLoaded(self: any, dataService: any, player: any): any?
	if dataService == nil then
		return nil
	end
	for attempt = 1, self.loadWaitAttempts do
		local got = dataService:get(player)
		if type(got) == "table" and got.ok == true then
			return got.value
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return nil
end

-- THE join lifecycle hook. Fires session_start AFTER the load resolves. Returns the emitted Event,
-- or nil when the load never resolved (a kicked / departed player emits nothing rather than
-- emitting an empty session).
function AnalyticsService.onPlayerAdded(self: any, dataService: any, player: any): Event?
	local data = self:awaitLoaded(dataService, player)
	if data == nil then
		return nil
	end
	return self:sessionStart(player, data)
end

-- THE leave lifecycle hook. Fires session_end with the still-loaded blob when it is there.
--
-- HOOK ORDER (contract precisionNote 3 / AMENDMENT A10b): the order is AnalyticsService session_end
-- -> PlotService release -> DataService session release, because a session_end emitted AFTER the
-- data layer releases reads NoData and describes the join-time snapshot instead of the session the
-- player actually played — which makes the analytics success criterion pass vacuously.
-- That order is now REAL rather than documented: src/server/framework/PlayerLifecycle owns the one
-- PlayerRemoving connection and calls this method as step 1, while the blob is still loaded (this
-- service does not connect the signal itself when an owner claimed it — see Start).
-- The `stale = true` fallback below stays as DEFENCE, not as the design: if the blob is somehow
-- already gone, the join-time snapshot supplies the payload and the event is never empty. A
-- session_end carrying stale = true in a live server now means the pinned order was bypassed.
function AnalyticsService.onPlayerRemoving(self: any, dataService: any, player: any): Event
	local data: any = nil
	if dataService ~= nil then
		local got = dataService:get(player)
		if type(got) == "table" and got.ok == true then
			data = got.value
		end
	end
	return self:sessionEnd(player, data)
end

-- Boot-time wiring invariant: the seam MUST be the object Context.build installed. A seam that is
-- declared but never assigned is a nil every handler silently falls through, and that is invisible
-- at runtime until an analytics criterion is graded on an empty buffer. Pure (no Roblox global), so
-- Tier-1 proves the check itself works.
function AnalyticsService.assertInstalled(self: any, context: any): ()
	if context == nil or context.analytics ~= self then
		error(
			"AnalyticsService:Start — context.analytics is not this service. The emit seam is "
				.. "unreachable, so every ctx.analytics:emit(...) in the game is a silent no-op. "
				.. "Assign it in Context.build."
		)
	end
end

-- Start: runtime wiring only (construct already happened — §2.2). ROBLOX-ONLY: references `game`.
-- No spec calls Start; specs drive onPlayerAdded / onPlayerRemoving / emit directly.
function AnalyticsService.Start(self: any, context: any): ()
	self:assertInstalled(context)

	local Players = game:GetService("Players")
	local dataService = context.data

	local function onAdded(player: any): ()
		self:onPlayerAdded(dataService, player)
	end

	-- Players already present (a Studio Play session installs scripts after the local player joins).
	-- Spawned: awaitLoaded yields, and the bootstrap must not block on it.
	for _, player in Players:GetPlayers() do
		task.spawn(onAdded, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: any)
			task.spawn(onAdded, player)
		end)
	)

	-- [AMENDMENT A10b] The leave sequence (session_end -> plot release -> data release) is OWNED by
	-- src/server/framework/PlayerLifecycle, which Starts first and sets context.playerRemovingOwner;
	-- it calls onPlayerRemoving directly, while the blob is still loaded. Connecting here too would
	-- emit session_end TWICE per leave (once from each handler), and the second one — after the data
	-- release — would be the stale reconstruction. Only connect when nobody claimed the sequence, so
	-- a bootstrap without the lifecycle still emits session_end (stale, but never missing).
	if context.playerRemovingOwner == nil then
		table.insert(
			self._connections,
			Players.PlayerRemoving:Connect(function(player: any)
				self:onPlayerRemoving(dataService, player)
			end)
		)
	end
end

-- Stop (BindToClose) — every still-present player's session ends here. Best-effort and never raises:
-- a shutdown flush must not be aborted by the emitter.
function AnalyticsService.Stop(self: any, context: any): ()
	local Players = game:GetService("Players")
	local dataService = if context ~= nil then context.data else nil
	for _, player in Players:GetPlayers() do
		pcall(function()
			self:onPlayerRemoving(dataService, player)
		end)
	end
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
end

return AnalyticsService
