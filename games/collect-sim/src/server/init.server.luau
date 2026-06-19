--!strict
-- core/src/server/init.server.luau   [Roblox-only — never required by a spec]
-- THE server bootstrap. The ONLY place that knows the concrete service order. Per Rojo,
-- init.server.luau under src/server makes the `Server` folder a Script that runs on the server.
-- See docs/CORE-DESIGN.md §2.4.
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

local Context = require(Server.Context)
local Bootstrap = require(Server.framework.Bootstrap)

-- CONSTRUCT phase: every core context field (clock, config, data, net, gate) is non-nil now.
-- B2 seams (security/flags/analytics/monetization) are constructed here too once they exist;
-- nil in the spine. (See §2.2 Construct-vs-Start.)
local context = Context.build()

-- DETERMINISTIC ORDER. Earlier = depended-upon-by-later. Each entry is the SAME object held in
-- `context` (context.net IS services[1]); they appear here only to receive Start().
-- 1. NetServer:Start binds the RemoteFunction/RemoteEvent before any service registers an action.
-- 2. DataService:Start hooks PlayerAdded/Removing before any service reads/writes data.
-- 3. Feature services (the sample) register their actions last.
local services = {
	context.net, -- NetServer  (constructed in Context.build; Start binds the remotes)
	context.data, -- DataService (constructed in Context.build; Start hooks PlayerAdded)
	-- [B2] context.security, context.flags, context.analytics, context.monetization,
	require(Server.services.sample.SampleService), -- [SAMPLE]
	require(Server.services.collection.CollectionService), -- [collection-core] gather + sell
}

Bootstrap.start(services, context)

game:BindToClose(function()
	-- DataService:Stop flushes all sessions within budget (§4.4).
	Bootstrap.stop(services, context)
end)
