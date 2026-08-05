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
-- [contract pass] The join-race guard. Installed on the net BELOW rather than left for each
-- controller to remember: context.net is the only wire out of the client, so guarding it here is
-- what makes "every join-time fetch is race-safe" a property of the framework instead of a rule in
-- a comment that the tenth controller's author has not read.
local JoinRetry = require(Client.framework.JoinRetry)

local Context = {}

function Context.build(): any
	-- Every controller's FIRST call of a given action is routed through JoinRetry: DataService's
	-- loadSession yields on join, so a call issued from a controller's Start can arrive before the
	-- session exists and come back Err(NoData). For a grant-shaped action (offline.claim) that loss
	-- is PERMANENT — autosave re-stamps lastSeenUnix and erases the away window. A controller cannot
	-- bypass this by construction: it has no other net to call.
	local net = JoinRetry.install(NetClient.new())

	local context = {
		isServer = false,
		net = net,
		-- The CLIENT-SAFE subset of Config (no store names / budgets leak to the client — §3.4).
		config = (Config :: any).clientSubset(),
	}

	return context
end

return Context
