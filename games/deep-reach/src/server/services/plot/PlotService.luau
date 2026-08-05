--!strict
-- games/deep-reach/src/server/services/plot/PlotService.luau   [contract pass — STUB]
--
-- THIS IS A STUB. It exists so the WIRE is complete before fan-out: both plot actions are
-- registered on the gateway and the ctx.plot seam is installed with IDENTITY DEFAULTS, so every
-- consumer of either already resolves to something well-defined. The plot feature builder REPLACES
-- this file wholesale with the authoritative logic (server-picked dome, exclusivity, release on
-- leave). NOTHING here is feature logic — every handler refuses with Internal("stub: ...").
--
-- WHY a stub at all: nine features fan out in parallel against a frozen shared contract. A seam
-- that is declared (Net.ActionContext.plot) but never assigned is a nil that every reader silently
-- falls through, and an action that is named (Net.Actions.ClaimPlot) but never registered dispatches
-- to Err(UnknownAction) — both of which look exactly like "not built yet" AND exactly like "built
-- and broken". Installing the identity default now makes the difference observable.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT service root than
-- this ServerScriptService module — so the relative string cannot reach it there; require by
-- instance. Under Lune (script == nil) the filesystem path resolves.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

local PlotService = {}
PlotService.name = "PlotService"

-- STUB validate: a permissive passthrough. A stub must NOT pretend to validate — the real builder
-- writes the typed + range-checked validator (§10.3). Note the claim payload carries NO plot id by
-- contract (a client-named plot IS the plot-claim-hijack exploit), so there is nothing to range-check
-- here even in the real thing.
local function passthrough(rawPayload: any): any
	return Result.ok(rawPayload)
end

-- ----- ctx.plot SEAM (contract.stubs.plot.seamProvided) — IDENTITY DEFAULTS -----
-- "No plot is claimed yet", which is the truth until the real service lands. Every lookup answers
-- nil, so a consumer's `if ctx.plot ~= nil then local id = ctx.plot:plotIdFor(player) end` composes
-- to the same behaviour it has today with the seam unassigned — but reaches a REAL object, so a
-- typo'd method name is a boot-time error rather than a silent nil.
--
-- NAMED `PlotSeam`, not `self`: the seam is its OWN table, installed on context.plot, and the
-- `<X>Seam` name is the convention gate-reachability's seam-installed / seam-read rules discover by
-- (gate-reachability.luau §R2). Installing the SERVICE (`context.plot = self`) published the ident
-- `self`, which matches no `function self.<method>(` definition anywhere — so BOTH seam rules found
-- ZERO subjects, and zero subjects is a hard FAIL by design: the gate was blind to every seam in
-- this game. A separate table also keeps the seam surface honest — what is on PlotSeam is what
-- gameplay may call; Start/name/the action factories are the service's own business.
local PlotSeam = {}

-- The dome id this player holds, or nil when they hold none.
function PlotSeam.plotIdFor(_self: any, _player: any): string?
	return nil
end

-- The world root (an Instance) of this player's dome, or nil when they hold none.
function PlotSeam.rootFor(_self: any, _player: any): any?
	return nil
end

-- The UserId currently holding `plotId`, or nil when the plot is free / unknown.
function PlotSeam.ownerOf(_self: any, _plotId: string): number?
	return nil
end

-- Free whatever dome this player holds; returns whether anything was actually released.
-- This is the METHOD NAME for the middle step of the pinned PlayerRemoving sequence (AMENDMENT
-- A10b: analytics session_end -> PLOT RELEASE -> data session release). The amendment named the
-- step but not the call, so the step could not be wired; PlayerLifecycle calls this. The stub's
-- honest answer is `false` — no plot was ever claimed, so nothing was freed — and the real
-- PlotService replaces it with the occupancy-map release WITHOUT the caller changing.
function PlotSeam.releaseFor(_self: any, _player: any): boolean
	return false
end

-- ----- actions -----
-- Registered as CLOSURES over the service (contract.precisionNotes[5]): the scaffold's static-module
-- registration cannot reach service state, and the real plot feature's occupancy map IS that state.

local function makeClaimPlotAction(_service: any): any
	return {
		name = Net.Actions.ClaimPlot,
		validate = passthrough,
		-- A claim happens once per session; a few retries around a join race, never a stream.
		rate = { maxPerWindow = 3, windowSeconds = 5.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: plot not implemented")
		end,
	}
end

local function makeFetchPlotAction(_service: any): any
	return {
		name = Net.Actions.FetchPlot,
		validate = passthrough,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(_ctx: any, _payload: any): any
			return Result.err(Result.Codes.Internal, "stub: plot not implemented")
		end,
	}
end

-- Start: registers the wire surface and INSTALLS the seam. Lune-callable (no Roblox global).
-- The seam assignment is deliberately FIRST: services that Start later may read ctx.plot, and the
-- NetServer ActionContext projection reads it at dispatch time, so an install at Start is visible to
-- every request the game ever serves.
function PlotService.Start(self: any, context: any): ()
	context.plot = PlotSeam
	context.net:register(makeClaimPlotAction(self))
	context.net:register(makeFetchPlotAction(self))
end

return PlotService
