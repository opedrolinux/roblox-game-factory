--!strict
-- games/deep-reach/src/server/framework/PlayerLifecycle.luau   [AMENDMENT A10b — the pinned leave order]
--
-- THE ONE OWNER OF PlayerRemoving. Deep Reach's leave path has a load-bearing ORDER:
--
--     AnalyticsService session_end (needs the STILL-LOADED blob)
--       -> PlotService release (frees the dome)
--         -> DataService session release (invalidates the blob).
--
-- WHY IT HAD TO BECOME CODE. Until this module existed, that order was a COMMENT in
-- src/server/init.server.luau while DataService and AnalyticsService each connected their OWN
-- PlayerRemoving handler. Roblox fires the connections of one signal in an order this game does not
-- control (and DataService connects FIRST, being earlier in the bootstrap), so the release routinely
-- ran before session_end: the emitter then read Err(NoData) and fell back to its join-time snapshot,
-- and every session_end in the game carried the values the player had AT JOIN with `stale = true`.
-- The analytics success criterion ("session_end fires with the session's data") passes on that —
-- vacuously. A documented order is not an order.
--
-- SHAPE. `onRemoving` is PURE (no Roblox global, no require): a Tier-1 spec drives the whole
-- sequence with fakes and asserts the payload session_end actually carried — see
-- tests/unit/lifecycle.spec.luau, which fails on any other ordering. Only Start/Stop touch `game`.
--
-- HOW THE OTHER TWO STAND DOWN. Start sets `context.playerRemovingOwner = self` BEFORE DataService
-- and AnalyticsService Start (this module is first in the bootstrap list), and each of them connects
-- its own PlayerRemoving handler only when that field is nil. So the sequence cannot be run twice,
-- and a bootstrap that ever DROPPED this module degrades to "analytics may be stale" rather than to
-- "player sessions are never released" — the failure that would lose data.
local PlayerLifecycle = {}
PlayerLifecycle.name = "PlayerLifecycle"
PlayerLifecycle._connections = {} :: { any }

-- Diagnostics sink. `warn` is a Roblox global and is referenced through a guarded local so this
-- module stays Lune-requirable; a spec can replace it to assert on the message.
function PlayerLifecycle.logWarn(_self: any, message: string): ()
	local w: any = warn
	if type(w) == "function" then
		w(message)
	end
end

-- THE SEQUENCE. Pure, synchronous, and deliberately ordered — the ordering IS the deliverable.
-- Steps 1 and 2 are pcall-guarded: an emitter or a dome teardown that throws must never skip step 3,
-- which is the player's final durable write. Step 3 is NOT guarded — if the data layer raises, that
-- belongs in the error log, not swallowed by the module that was supposed to persist the session.
function PlayerLifecycle.onRemoving(self: any, context: any, player: any): ()
	if context == nil or player == nil then
		return
	end
	local data = context.data

	-- 0. Departure bookkeeping. NOT a release: it only records that the player has left, so a
	--    loadSession still yielding in flight installs nothing orphaned ([B2 B-1]). The blob stays
	--    loaded, which is what step 1 needs. DataService's own leave path repeats this call; it is
	--    idempotent (it clears one flag), and doing it first here preserves the B2 guarantee no
	--    matter how long steps 1-2 take.
	if data ~= nil and type(data.noteDeparture) == "function" then
		local ok, err = pcall(function()
			data:noteDeparture(player)
		end)
		if not ok then
			self:logWarn(`PlayerLifecycle: noteDeparture errored: {tostring(err)}`)
		end
	end

	-- 1. ANALYTICS session_end, while the blob is still loaded. This is the step the order exists
	--    for: run it after step 3 and the payload is a join-time reconstruction.
	local analytics = context.analytics
	if analytics ~= nil and type(analytics.onPlayerRemoving) == "function" then
		local ok, err = pcall(function()
			analytics:onPlayerRemoving(data, player)
		end)
		if not ok then
			self:logWarn(`PlayerLifecycle: analytics session_end errored: {tostring(err)}`)
		end
	end

	-- 2. PLOT release — frees the dome for the next player. Before the data release so the plot
	--    service can still read the leaving player's session if it needs to. Optional by design:
	--    ctx.plot is nil until PlotService Starts, and the stub seam answers `false`.
	local plot = context.plot
	if plot ~= nil and type(plot.releaseFor) == "function" then
		local ok, err = pcall(function()
			plot:releaseFor(player)
		end)
		if not ok then
			self:logWarn(`PlayerLifecycle: plot release errored: {tostring(err)}`)
		end
	end

	-- 3. DATA session release — LAST, because it is what invalidates the blob (and it retries for
	--    seconds; anything downstream of it would be reading a released session).
	if data ~= nil and type(data.onPlayerRemoving) == "function" then
		data:onPlayerRemoving(player)
	end
end

-- Start: claims the sequence, then connects the single PlayerRemoving. ROBLOX-ONLY (uses `game`);
-- no spec calls Start — specs drive onRemoving directly.
function PlayerLifecycle.Start(self: any, context: any): ()
	-- Claim FIRST: DataService and AnalyticsService read this during their own Start, and this
	-- module is listed ahead of both precisely so the claim is already in place when they look.
	context.playerRemovingOwner = self

	local Players = game:GetService("Players")
	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(player: any)
			self:onRemoving(context, player)
		end)
	)
end

function PlayerLifecycle.Stop(self: any, _context: any): ()
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
end

return PlayerLifecycle
