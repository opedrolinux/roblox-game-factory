--!strict
-- core/src/server/net/NetServer.luau
-- Server side of Net: wires the single RemoteFunction (request/response) + single RemoteEvent
-- (server->client push) to the registry, and dispatches every inbound action through the ONE
-- pure Net.dispatch (so the real wire cannot drift from the test harness — concern 19).
-- ROBLOX-ONLY: uses script/game/Instance. NEVER required by a spec (D1). See §3.3.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

local REMOTE_FUNCTION_NAME = "CoreGateway"
local REMOTE_EVENT_NAME = "CoreEvents"

local NetServer = {}
NetServer.__index = NetServer

-- CONSTRUCTED in Context.build (no I/O here). `gate` is the spine rate/ownership gate (§3.6);
-- `serverContext` is the full ServerContext NetServer closes over to build each ActionContext.
function NetServer.new(gate: any): any
	local self = setmetatable({}, NetServer)
	self.name = "NetServer"
	self._registry = Net.newRegistry()
	self._gate = gate
	self._serverContext = nil :: any
	self._remoteFunction = nil :: any
	self._remoteEvent = nil :: any
	self._b2SecurityPresent = false
	return self
end

-- Context.build calls this so NetServer can close over the full ServerContext when building
-- each handler's narrow ActionContext (concern 15).
function NetServer.bindContext(self: any, serverContext: any): ()
	self._serverContext = serverContext
end

-- Feature services call this in their Start to register a named action.
function NetServer.register<TIn, TOut>(self: any, action: Net.Action<TIn, TOut>): ()
	self._registry:register(action)
	-- Publish-safety reminder (§6): warn once if a real action is exposed while the full B2
	-- security suite is absent. The spine is rate-limited + ownership-capable but NOT
	-- publish-safe until B2 lands. Suppressed in test/Studio is acceptable; this is a runtime hint.
	if
		not self._b2SecurityPresent
		and self._serverContext ~= nil
		and self._serverContext.security == nil
	then
		warn(
			`NetServer: action "{action.name}" registered without the B2 security suite. `
				.. "Spine is rate-limited + ownership-checked but NOT publish-safe until B2 (panic flag, "
				.. "violation tracking, full validators) lands. See docs/CORE-DESIGN.md §6."
		)
	end
end

-- Build the narrow, typed ActionContext for a given player by closing over the real
-- ServerContext (same object identities; same optional B2 seams — concern 15).
function NetServer.actionContext(self: any, player: any): Net.ActionContext
	local ctx = self._serverContext
	return {
		player = player,
		clock = ctx.clock,
		data = ctx.data,
		security = ctx.security,
		flags = ctx.flags,
		analytics = ctx.analytics,
		monetization = ctx.monetization,
	}
end

-- Server->client push over the single shared RemoteEvent (e.g. the data view, §4.5).
function NetServer.fireClient(self: any, player: any, eventName: string, payload: any): ()
	if self._remoteEvent ~= nil then
		self._remoteEvent:FireClient(player, eventName, payload)
	end
end

-- Start: runtime wiring only (construct already happened — §2.2). Creates/finds the
-- RemoteFunction + RemoteEvent and binds OnServerInvoke to the single pure dispatch.
function NetServer.Start(self: any, _context: any): ()
	local remoteFunction = ReplicatedStorage:FindFirstChild(REMOTE_FUNCTION_NAME)
	if remoteFunction == nil then
		remoteFunction = Instance.new("RemoteFunction")
		remoteFunction.Name = REMOTE_FUNCTION_NAME
		remoteFunction.Parent = ReplicatedStorage
	end
	self._remoteFunction = remoteFunction

	local remoteEvent = ReplicatedStorage:FindFirstChild(REMOTE_EVENT_NAME)
	if remoteEvent == nil then
		remoteEvent = Instance.new("RemoteEvent")
		remoteEvent.Name = REMOTE_EVENT_NAME
		remoteEvent.Parent = ReplicatedStorage
	end
	self._remoteEvent = remoteEvent

	-- -- TODO(verify): RemoteFunction.OnServerInvoke runs each invocation on its own thread, so a
	-- hostile client can hang only its own invocation, not the server. The dispatch pcall-wraps
	-- the handler (Net.dispatch step 7) so no exception ever crosses the wire.
	remoteFunction.OnServerInvoke = function(player: any, actionName: any, rawPayload: any): any
		local ctx = self:actionContext(player)
		local ok, dispatchResult =
			pcall(Net.dispatch, self._registry, self._gate, ctx, actionName, rawPayload)
		if not ok then
			-- A dispatch-level error must still return a Result, never throw across the wire.
			return Result.err(Result.Codes.Internal, tostring(dispatchResult))
		end
		return dispatchResult
	end
end

return NetServer
