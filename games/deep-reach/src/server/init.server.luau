--!strict
-- core/src/server/init.server.luau   [Roblox-only — never required by a spec]
-- THE server bootstrap. The ONLY place that knows the concrete service order. Per Rojo,
-- init.server.luau under src/server makes the `Server` folder a Script that runs on the server.
-- See docs/CORE-DESIGN.md §2.4.
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

local Context = require(Server.Context)
local Bootstrap = require(Server.framework.Bootstrap)
-- [AMENDMENT A10b] The single owner of PlayerRemoving. See the HOOK ORDER note below.
local PlayerLifecycle = require(Server.framework.PlayerLifecycle)

-- [contract pass — STUBS] The nine feature services. Each is a STUB today: it registers its
-- contract-named actions on the gateway with a refusing handler and, where the contract says it
-- PROVIDES one, installs its ctx seam with the IDENTITY DEFAULT. Each feature builder replaces its
-- own file in place; this registry does not change again during fan-out, which is the point —
-- src/server/init.server.luau is the #1 union-merge conflict surface.
local DepthService = require(Server.services.depth.DepthService)
local SalvageService = require(Server.services.salvage.SalvageService)
local PlotService = require(Server.services.plot.PlotService)
local DailyDropService = require(Server.services.daily.DailyDropService)
local StructuresShopService = require(Server.services.structures.StructuresShopService)
local OfflineService = require(Server.services.offline.OfflineService)
local ResurfaceService = require(Server.services.resurface.ResurfaceService)
local LeaderboardService = require(Server.services.leaderboard.LeaderboardService)
local MonetizationService = require(Server.services.monetization.MonetizationService)

-- CONSTRUCT phase: every core context field (clock, config, data, net, gate) is non-nil now.
-- B2 seams (security/flags/analytics/monetization) are constructed here too once they exist;
-- nil in the spine. (See §2.2 Construct-vs-Start.)
local context = Context.build()

-- DETERMINISTIC ORDER. Earlier = depended-upon-by-later. Each entry is the SAME object held in
-- `context` (context.net IS services[1]); they appear here only to receive Start().
-- 1. NetServer:Start binds the RemoteFunction/RemoteEvent before any service registers an action.
-- 2. DataService:Start hooks PlayerAdded/Removing before any service reads/writes data.
-- 3. AnalyticsService + EconomyService (the contract pass's cross-cutting infra) come immediately
--    after context.data and BEFORE any feature service: every feature emits through ctx.analytics
--    and mutates balances through ctx.economy, and EconomyService emits through AnalyticsService, so
--    a dependency always Starts before its dependents. Both are constructed in Context.build; their
--    Start asserts the seam actually holds them (a nil seam is a silent no-op for the whole game).
-- 4. Feature services register their actions last.
--
-- PlayerRemoving HOOK ORDER (AMENDMENT A10b) is load-bearing and belongs to no single feature:
--    AnalyticsService session_end (needs the STILL-LOADED blob)
--      -> PlotService release (frees the dome)
--        -> DataService session release (invalidates the blob).
-- A session_end emitted after the data layer releases reads NoData and describes the JOIN-TIME
-- snapshot instead of the session just played, so the analytics success criterion would pass
-- vacuously. This used to be only this comment, while DataService and AnalyticsService each
-- connected their own PlayerRemoving handler — an order this game does not control.
-- It is now CODE: PlayerLifecycle owns the one connection and runs the three steps in order. It is
-- FIRST in this list so its `context.playerRemovingOwner` claim is already set when DataService and
-- AnalyticsService Start and decide not to connect the signal themselves. Moving it after either of
-- them re-creates the defect; tests/unit/lifecycle.spec.luau asserts both the sequence and this
-- ordering, and fails if the release ever runs before session_end.
local services = {
	PlayerLifecycle, -- [A10b] claims PlayerRemoving BEFORE data/analytics Start (see note above)
	context.net, -- NetServer  (constructed in Context.build; Start binds the remotes)
	context.data, -- DataService (constructed in Context.build; Start hooks PlayerAdded)
	context.analytics, -- AnalyticsService (contract pass; Start hooks session_start/session_end)
	context.economy, -- EconomyService  (contract pass; pure helper — Start asserts the seam)
	-- [B2] context.security, context.flags, context.monetization,
	-- (AMENDMENT A10a: the sample service is DELETED — it wrote currencies.Stardust, the foundation
	--  game's currency, from a client-callable action.)
	-- --- [features] one line per feature, appended at merge. Keep this block LAST: every feature
	-- --- service registers actions and reads ctx.analytics / ctx.economy, both live by now. ---
	--
	-- SEAM PROVIDERS FIRST (contract.newCtxSeams: plot / salvage / depth). Every seam is READ at
	-- dispatch time, not at Start, so this ordering is not load-bearing for correctness — but a
	-- provider Starting before its readers means a Start that ever does want to consult a seam finds
	-- it installed, and it documents the dependency direction for the builders who replace these:
	--   depth   provides valueMultiplier (salvage multiplies by it) + tierYFor (plot places by it)
	--   salvage provides rateFor / capacityFor (offline caps its away-accrual by capacity)
	--   plot    provides plotIdFor / rootFor / ownerOf
	DepthService,
	SalvageService,
	PlotService,
	-- The rest, in build-batch order. None provides a seam; none reads another's Start.
	DailyDropService,
	StructuresShopService,
	OfflineService,
	ResurfaceService,
	LeaderboardService,
	-- MonetizationService registers NO action by contract (gamepass prompts are client-initiated
	-- MarketplaceService calls; product grants are server-driven through ProcessReceipt). It is in
	-- the list so the slot is real and the receipt handler has somewhere to land.
	MonetizationService,
}

Bootstrap.start(services, context)

game:BindToClose(function()
	-- DataService:Stop flushes all sessions within budget (§4.4).
	Bootstrap.stop(services, context)
end)
