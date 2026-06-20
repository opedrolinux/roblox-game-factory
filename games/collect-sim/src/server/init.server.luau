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
-- 3. Feature services register their actions last.
local services = {
	context.net, -- NetServer  (constructed in Context.build; Start binds the remotes)
	context.data, -- DataService (constructed in Context.build; Start hooks PlayerAdded)
	context.analytics, -- AnalyticsService (contract pass; Start fires session_start/session_end)
	-- [B2] context.security, context.flags, context.monetization,
	require(Server.services.collection.CollectionService), -- [collection-core] gather + sell
	require(Server.services.shop.UpgradesShopService), -- [upgrades-shop] server-validated Stardust purchases
	require(Server.services.daily.DailyStreakService), -- [daily-streak] once-per-day reward, server-clock gated
	-- --- contract-pass (v4) STUB services: registered so the wire is complete before fan-out. Each
	-- --- feature builder REPLACES its stub with real logic. Seam-providers (islands/restock/
	-- --- monetization) set their identity-default ctx seam in Start; order is irrelevant because the
	-- --- Sell formula reads the seams per-request (all Starts run at boot, before any request).
	require(Server.services.islands.IslandsService), -- [islands STUB] UnlockIsland/FetchIslands + ctx.islands seam
	require(Server.services.leaderboard.LeaderboardService), -- [leaderboard STUB] FetchLeaderboard
	require(Server.services.monetization.MonetizationService), -- [monetization STUB] ctx.monetization seam (no client action)
	require(Server.services.offline.OfflineService), -- [offline STUB] ClaimOffline
	require(Server.services.restock.RestockService), -- [restock STUB] FetchRestock + ctx.restock seam
	require(Server.services.rebirth.RebirthService), -- [rebirth STUB] Rebirth
}

Bootstrap.start(services, context)

game:BindToClose(function()
	-- DataService:Stop flushes all sessions within budget (§4.4).
	Bootstrap.stop(services, context)
end)
