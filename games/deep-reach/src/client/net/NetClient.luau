--!strict
-- core/src/client/net/NetClient.luau
-- Client side of Net: call(action, payload) -> Result (request/response over the single shared
-- RemoteFunction) and on(eventName, fn) for server->client pushes (over the single shared
-- RemoteEvent). ROBLOX-ONLY: uses script/game. Never required by a spec (D1). See §3.3.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Result = require(Shared.Result)

local REMOTE_FUNCTION_NAME = "CoreGateway"
local REMOTE_EVENT_NAME = "CoreEvents"

local NetClient = {}
NetClient.__index = NetClient

function NetClient.new(): any
	local self = setmetatable({}, NetClient)
	self.name = "NetClient"
	self._remoteFunction = nil :: any
	self._remoteEvent = nil :: any
	-- eventName -> { fn, ... } subscriptions, dispatched from the single RemoteEvent.
	self._handlers = {} :: { [string]: { (payload: any) -> () } }
	return self
end

-- Returns a Result<TOut>. payload is plain data; the client cannot be trusted, so this is just
-- a transport. The server validates everything (Net.dispatch). A wire error becomes Err.
function NetClient.call(self: any, actionName: string, payload: any): Result.Result<any>
	if self._remoteFunction == nil then
		return Result.err(Result.Codes.Internal, "NetClient not started")
	end
	local ok, response = pcall(function()
		return self._remoteFunction:InvokeServer(actionName, payload)
	end)
	if not ok then
		return Result.err(Result.Codes.Internal, tostring(response))
	end
	-- The server always returns a Result table; pass it through (guard against a nil reply).
	if type(response) ~= "table" or response.ok == nil then
		return Result.err(Result.Codes.Internal, "malformed server reply")
	end
	return response
end

-- Subscribe to a server->client push (e.g. "data" -> PlayerView). Returns the connection.
function NetClient.on(self: any, eventName: string, fn: (payload: any) -> ()): ()
	local list = self._handlers[eventName]
	if list == nil then
		list = {}
		self._handlers[eventName] = list
	end
	table.insert(list, fn)
end

-- Start: resolve the shared remotes and route incoming events to subscribers.
function NetClient.Start(self: any, _context: any): ()
	self._remoteFunction = ReplicatedStorage:WaitForChild(REMOTE_FUNCTION_NAME)
	self._remoteEvent = ReplicatedStorage:WaitForChild(REMOTE_EVENT_NAME)

	self._remoteEvent.OnClientEvent:Connect(function(eventName: any, payload: any): ()
		local list = self._handlers[eventName]
		if list ~= nil then
			for _, fn in list do
				task.spawn(fn, payload)
			end
		end
	end)
end

return NetClient
