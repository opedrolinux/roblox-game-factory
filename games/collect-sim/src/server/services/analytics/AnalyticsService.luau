--!strict
-- games/collect-sim/src/server/services/analytics/AnalyticsService.luau   [analytics]
-- THE single analytics emitter. The taxonomy is stood up exactly ONCE here so every feature emits
-- through the SAME seam (ctx.analytics:emit(event, payload)) rather than each feature inventing its
-- own event plumbing. The contract pass wires this; feature builders + the named retrofits only
-- CALL emit — they never re-implement it.
--
-- SEAM (contract.analytics.seam): ctx.analytics:emit(event, payload). Nil-safe by convention at the
-- call sites (a handler does `if ctx.analytics ~= nil then ...`), so the spine + the existing tests
-- (where ctx.analytics is nil) are a no-op; a wired AnalyticsService records the event.
--
-- LIFECYCLE (contract.analytics.lifecycle): session_start on player join, session_end on player
-- leave/release. AnalyticsService:Start connects Players.PlayerAdded / PlayerRemoving for this.
--
-- TIER-1 OBSERVABILITY: every emit is stamped with the SERVER clock (ctx.clock:unix(), never client
-- time, never os.time) and appended to an in-memory buffer the service exposes (events() / sink),
-- so a test can assert "event X fired with payload Y at timestamp T" without any Roblox runtime. The
-- buffer is also overridable with an injected sink (ctx.analytics is the service object itself, so a
-- test can read the buffer directly off it).
--
-- Lune-clean at the LOGIC level: new()/emit()/events() touch no Roblox global, so a spec drives them
-- directly. Only Start() references the `game`/`Players` runtime (no spec calls Start).

local AnalyticsService = { name = "AnalyticsService" }
AnalyticsService.__index = AnalyticsService

-- The taxonomy this game emits. Declared once; features pick an event from this set. Kept as a set
-- so a stray/typo event name is catchable (isKnownEvent) without coupling features to this module.
local EVENTS = {
	session_start = true,
	session_end = true,
	loop_completed = true,
	currency_earned = true,
	currency_spent = true,
	progression = true,
	purchase = true,
}

export type Event = {
	event: string,
	payload: any,
	at: number, -- server-clock unix timestamp the emit was recorded at (ctx.clock:unix())
}

export type ClockLike = {
	unix: (self: any) -> number,
	mono: (self: any) -> number,
}

-- CONSTRUCTED in Context.build (no I/O here). `clock` is the injected server clock used to
-- timestamp every event. The in-memory `_events` buffer is the Tier-1 observation surface.
function AnalyticsService.new(clock: ClockLike): any
	local self = setmetatable({}, AnalyticsService)
	self.name = "AnalyticsService"
	self._clock = clock
	self._events = {} :: { Event }
	-- The runtime player lifecycle hookups live here so Stop can disconnect them cleanly.
	self._connections = {} :: { any }
	return self
end

-- Whether `event` is part of the declared taxonomy. Features SHOULD emit only known events; an
-- unknown one is still recorded (so nothing is silently lost) but is observable as off-taxonomy.
function AnalyticsService.isKnownEvent(_self: any, event: string): boolean
	return EVENTS[event] == true
end

-- THE emit seam (contract.analytics.seam). Records `event` + `payload`, server-clock timestamped,
-- into the in-memory buffer. Pure + synchronous: no yield, no Roblox global — Tier-1 callable.
-- Returns the recorded Event so a caller/test can inspect the stamped `at` without re-reading.
function AnalyticsService.emit(self: any, event: string, payload: any): Event
	local record: Event = {
		event = event,
		payload = payload,
		at = self._clock:unix(),
	}
	table.insert(self._events, record)
	return record
end

-- The Tier-1 observation surface: a snapshot copy of every recorded event in emit order. A test
-- asserts "event X fired with payload Y" by scanning this. A copy so callers can't mutate internals.
function AnalyticsService.events(self: any): { Event }
	return table.clone(self._events)
end

-- All recorded events whose `.event` matches `name`, in emit order. Convenience for tests.
function AnalyticsService.eventsOfType(self: any, name: string): { Event }
	local out = {}
	for _, record in self._events do
		if record.event == name then
			table.insert(out, record)
		end
	end
	return out
end

-- Start: runtime wiring only (construct already happened — §2.2). Fires session_start for every
-- player already present + every future join, and session_end on leave. ROBLOX-ONLY at runtime:
-- references `game`/`Players`. No spec calls Start (specs drive emit/events directly).
function AnalyticsService.Start(self: any, _context: any): ()
	local Players = game:GetService("Players")

	local function onJoin(player: any): ()
		self:emit("session_start", { userId = player.UserId, name = player.Name })
	end

	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
	table.insert(self._connections, Players.PlayerAdded:Connect(onJoin))

	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(player: any)
			self:emit("session_end", { userId = player.UserId, name = player.Name })
		end)
	)
end

-- Stop (BindToClose) — emit session_end for every still-present player (a leave/release at
-- shutdown) and disconnect the lifecycle hookups. Best-effort; never raises.
function AnalyticsService.Stop(self: any, _context: any): ()
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		self:emit("session_end", { userId = player.UserId, name = player.Name })
	end
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
end

return AnalyticsService
