--!strict
-- core/src/client/init.client.luau   [Roblox-only — never required by a spec]
-- THE client bootstrap. Per Rojo, init.client.luau under src/client makes the `Client` folder
-- a LocalScript. See docs/CORE-DESIGN.md §2.5.
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
-- -- TODO(verify): StarterPlayerScripts replicate into Players.LocalPlayer.PlayerScripts at runtime.

local Context = require(Client.Context)
local Bootstrap = require(Client.framework.Bootstrap)

local context = Context.build() -- builds NetClient (waits for the server's remotes) + config

local controllers = {
	context.net, -- NetClient (resolves the RemoteFunction/RemoteEvent)
	require(Client.controllers.sample.SampleController), -- [SAMPLE]
}

Bootstrap.start(controllers, context)
