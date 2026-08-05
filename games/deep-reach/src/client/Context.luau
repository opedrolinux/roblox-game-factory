--!strict
-- core/src/client/Context.luau
-- Builds + holds the client context table. CONSTRUCT phase only: news up NetClient + the
-- client-safe config subset. ROBLOX-ONLY: uses script/game. Never required by a spec. See §2.3.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local NetClient = require(Client.net.NetClient)

local Context = {}

function Context.build(): any
	local net = NetClient.new()

	local context = {
		isServer = false,
		net = net,
		-- The CLIENT-SAFE subset of Config (no store names / budgets leak to the client — §3.4).
		config = (Config :: any).clientSubset(),
	}

	return context
end

return Context
