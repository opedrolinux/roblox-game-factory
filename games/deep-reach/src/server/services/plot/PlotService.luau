--!strict
-- games/deep-reach/src/server/services/plot/PlotService.luau   [feature: plot ownership]
--
-- THE authoritative owner of dome plots. Replaces the contract-pass stub in place, preserving every
-- contract decision the stub pinned: the two action names + their RatePolicies, the SEPARATE seam
-- table literally named `PlotSeam` (never `context.plot = self`), and the four seam methods
-- plotIdFor / rootFor / ownerOf / releaseFor with their exact signatures — PlayerLifecycle already
-- calls releaseFor as the middle step of the pinned PlayerRemoving order (analytics session_end ->
-- PLOT RELEASE -> data session release), and gate-reachability discovers seams by the `<Name>Seam`
-- identifier convention, so both the name and the shape are load-bearing.
--
-- WHAT THIS SERVICE OWNS
--   * A per-SERVER occupancy registry built at Start: a fixed set of dome plots, each free or held by
--     exactly ONE UserId. Exclusivity is enforced ENTIRELY in this server's memory — never from the
--     save blob, which is a per-player record and cannot express "who else is on this server".
--   * Claim on join (server-driven, once the session's data has loaded), persisted into
--     PlayerData.plot through ctx.data:update, with the pad lit.
--   * Refusal codes that are DISTINGUISHABLE: a second claim is Err(AlreadyClaimed); a full server is
--     Err(Unavailable). Never Err(Rejected) — Net.dispatch returns exactly Rejected for the panic
--     flag, so reusing it would make "a second claim was refused" byte-identical to "the server is
--     refusing all client writes".
--   * Release on leave: synchronous, in-memory, NO yield and NO data write, so the freed dome is
--     re-claimable by the NEXT player in the same frame and the leave->claim race can neither leak a
--     dome forever nor hand one dome to two players.
--   * AMENDMENT A1 — PLACEMENT AT THE PERSISTED TIER. The dome root is placed at claim time (first
--     claim AND every rejoin) at the Y of the player's PERSISTED tier, read through the nil-safe
--     `ctx.depth:tierYFor(data)` seam. Depth tiers is a LATER batch, so that seam is ABSENT today and
--     the default is tier 1's Y — which is exactly the fresh-player case, so the default is the
--     COMMON PATH, not a fallback. The authoritative fact is the persisted tier; the world position
--     is derived from it, never the reverse. Depth owns MOVING the root on a descend; this owns where
--     it STARTS.
--
-- NOT THIS SLICE: income of any kind, drones, the conveyor, the smelter (Salvage core); descending
-- the dome (Depth tiers); ANY currency mutation whatsoever — this service never touches ctx.economy.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4, restated for a non-currency resource) ────────────────
-- A dome is a single-writer resource exactly like a balance, and it has the SAME failure mode: read
-- "am I holding one / is this one free", then YIELD in ctx.data:update, then write. Two claims from
-- the same player in one frame (spam-duplicated), or two players racing for the last free dome, both
-- read before either writes — and the player ends up holding two domes, or two players hold one.
--
-- The fix is to RESERVE BEFORE THE YIELD. `acquire` does the exclusivity check, the free-dome pick
-- and the in-memory `occupy` with NO yield anywhere between them; Luau is single-threaded, so that
-- whole span is atomic with respect to any other request. The persist then runs against a reservation
-- that is already visible to every interleaved request:
--     * a duplicate claim from the same player finds `plotIdByOwner[userId]` set -> AlreadyClaimed;
--     * a claim from another player finds that record's `ownerUserId` set -> it picks a different one,
--       or Unavailable when there is none.
-- If the persist FAILS the reservation is rolled back (`vacate`) so a failed write can never leak a
-- dome for the life of the server — and rollback restores an INVARIANT-CLEAN state (memory and the
-- blob then agree that this player holds nothing) rather than a half-claim. That rollback is
-- GUARDED exactly like the success path: `record` was read before the yield, so a rollback that did
-- not first re-check ownership would free — and `clearContents` DESTROY the structures on — a dome
-- somebody else is now standing on.
-- If the reservation was revoked while the persist yielded (the player left mid-claim and
-- PlayerLifecycle ran releaseFor), the claim is ABANDONED with Err(SessionClosed) rather than
-- re-occupying a dome the next player may already hold — and it is abandoned WITHOUT WRITING, because
-- the revocation is checked INSIDE the update transform, on the lock-held snapshot, before the field
-- is touched (CLAUDE.md §4). A claim that writes first and disowns afterwards leaves the same
-- half-claim the rollback above exists to prevent: an error returned to the player whose durable
-- record nonetheless names a dome, and — on a leave + same-server rejoin — a stale write landing on
-- top of the LIVE session's newer claim, which is what the client highlights from.
--
-- ── PRESENCE IS ITS OWN FACT (the departure ledger) ─────────────────────────────────────────────
-- Occupancy answers "does this player hold a dome". It does NOT answer "is this player still here",
-- and the join path lives entirely in the gap between them: a player who quits while their session
-- is still LOADING gets a PlayerRemoving that frees nothing (they hold nothing yet) and never gets
-- another — while `ctx.data:get` keeps answering Ok right through DataService's yielding release.
-- So this service records departures in their own ledger (see `departures` below) and every span
-- that yields — the join hook's poll loop AND the persist inside `acquire` — takes a ticket first
-- and refuses to act on a stale one. Without it the join hook reserves domes for absent UserIds
-- that nothing ever frees, and with churn the registry fills with ghosts until every real joiner is
-- refused Err(Unavailable) and core-loop step 1 stops working server-wide until a restart.
--
-- Nothing here reads a client number: the payload for both actions is validated to carry NO plot id
-- at all (a client-named plot IS the plot-claim-hijack exploit) and the handler is handed a fresh
-- empty table, so there is physically nothing client-supplied for it to trust.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- build / acquire / describe / positionFor / plotCountFor / claimAction / fetchAction and every
-- PlotSeam method are Roblox-FREE: a spec drives the whole claim/refuse/release/rejoin lifecycle with
-- Mocks.player + a real DataService over MockStore, with no engine at all. Only `startRuntime` and the
-- world builders touch `game`/`Instance`/`workspace`, and each of those is reached through a guarded
-- local so requiring and Starting this module under Lune never throws. `build` RESETS the registry, so
-- each spec's Start begins from a clean server.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT service root than this
-- ServerScriptService module — so the relative string cannot reach it there; require by instance.
-- Under Lune (script == nil) the filesystem path resolves.
local Net, Result, Types
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
	Types = require("../../../shared/Types")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
	Types = require((Shared :: any).Types)
end

local PlotService = {}
PlotService.name = "PlotService"

-- ── tunables ────────────────────────────────────────────────────────────────────────────────────
-- One dome per seat, so "every dome is held" is a state a full server reaches and no further — a
-- registry SMALLER than MaxPlayers would refuse a legitimate joiner with Unavailable, which is a
-- capacity bug wearing a correct-looking error code. Start sizes the registry from Players.MaxPlayers
-- (clamped); DEFAULT_PLOT_COUNT is what Lune and an unreadable MaxPlayers get.
--
-- MAX_PLOT_COUNT IS ROBLOX'S OWN PER-SERVER CEILING, not a layout convenience. Nothing in this game
-- pins MaxPlayers — it is a Studio place setting — so any ceiling BELOW what the platform lets a human
-- type into it re-creates the exact bug this comment names: the place sells 60 seats, the registry
-- stands up 50 domes, and joiners 51-60 are refused with a correct-looking Unavailable. The ring
-- layout scales its radius with n (see positionFor), so a larger registry costs nothing but Parts.
local DEFAULT_PLOT_COUNT = 12
local MIN_PLOT_COUNT = 4
local MAX_PLOT_COUNT = 200

-- The world Y a dome sits at when the ctx.depth seam is absent (Depth tiers is a later batch) — the
-- surface tier, matching DepthService's own TIER_1_Y identity default. Not a magic fallback: a fresh
-- player IS at tier 1, so this is the value the common path produces.
local DEFAULT_TIER_Y = 0

-- Ring layout. Domes are laid out on a circle around the origin so every plot is reachable, none
-- overlaps, and the whole ring descends as one when Depth moves each root's Y.
local RING_SPACING_STUDS = 96
local MIN_RING_RADIUS_STUDS = 160

-- Greybox dimensions (art posture: "100% greybox-in-code for v1: domes = Parts + transparency").
local PAD_SIZE_STUDS = 64
local PAD_THICKNESS_STUDS = 2
local DOME_DIAMETER_STUDS = 56

-- Names other code resolves by. `plotId` IS the dome Model's name, so a client that knows the id can
-- find the model with one FindFirstChild and needs no second lookup table.
local PLOTS_FOLDER_NAME = "DeepReachPlots"
local PLOT_ID_PREFIX = "dome_"
-- The built-at-boot greybox lives under this child folder so `vacate` can clear a departed player's
-- structures (Salvage parents its smelter/conveyor/drones under the dome root) without destroying the
-- dome itself. Everything else under the Model is session content and is cleared on release.
local SHELL_FOLDER_NAME = "Shell"

-- How long the join hook waits for DataService.loadSession to resolve. The load YIELDS (several
-- DataStore round trips plus up to sessionLockedWaitSeconds of lock waiting) and a claim issued before
-- it resolves reads Err(NoData). Same budget AnalyticsService uses, for the same reason.
local LOAD_WAIT_ATTEMPTS = 200
local LOAD_WAIT_STEP_SECONDS = 0.25

PlotService.loadWaitAttempts = LOAD_WAIT_ATTEMPTS
PlotService.loadWaitStepSeconds = LOAD_WAIT_STEP_SECONDS
PlotService._connections = {} :: { any }

-- ── state (per SERVER; `build` resets it) ───────────────────────────────────────────────────────
export type PlotRecord = {
	id: string,
	index: number,
	ownerUserId: number?, -- THE authority on exclusivity; nil == free
	model: any?, -- the dome Model (the seam's `rootFor`); nil under Lune / before buildWorld
	pad: any?, -- the pad Part whose light is the "claimed" signal
}

export type ClaimInfo = {
	plotId: string,
	claimedAtUnix: number,
	plotCount: number,
	freeCount: number,
	held: boolean,
	x: number,
	y: number, -- the tier Y this dome is placed at (AMENDMENT A1)
	z: number,
}

local plots: { PlotRecord } = {}
local plotById: { [string]: PlotRecord } = {}
-- The REVERSE index of `record.ownerUserId`. Maintained ONLY by occupy/vacate below, which are the
-- only two functions in this file that write occupancy — two indexes that drift are two answers to
-- "does this player hold a dome", and the exclusivity guarantee is exactly that question.
local plotIdByOwner: { [number]: string } = {}

-- ── THE DEPARTURE LEDGER (presence across a yield) ──────────────────────────────────────────────
-- userId -> how many times this service has observed that player LEAVE. It is a GENERATION COUNTER,
-- not a boolean: every operation that yields takes a "ticket" (the count as of its start) and, after
-- the yield, refuses to act if the count moved. That makes it self-clearing across a rejoin — a
-- boolean would have to be un-set by someone, and nothing here reliably observes a JOIN.
--
-- WHY IT HAS TO EXIST. The occupancy registry can answer "does this player hold a dome"; it cannot
-- answer "is this player still on this server", and those come apart in exactly one window:
--   * PlayerRemoving fires -> PlayerLifecycle runs `plot:releaseFor(P)`, which frees NOTHING because
--     P's join-time claim has not happened yet. That is P's ONLY PlayerRemoving.
--   * DataService then installs the session and releases it — and `_sessions[uid]` stays populated
--     across that YIELDING release (finishJoin's left-during-load branch, and onPlayerRemoving), so
--     `data:get(P)` answers Ok for the whole window.
--   * the join hook's poller wakes inside it, sees a perfectly loaded blob, and reserves a dome for
--     a player who is gone. Nothing ever frees it: releaseFor already ran and never runs again.
-- `releaseFor` is the right place to record this because PlayerLifecycle calls it for EVERY leaving
-- player (holder or not) as step 2 of the pinned order — so the signal costs nothing to collect.
--
-- DELIBERATELY NOT RESET BY `build`: only DELTAS are ever read, so the absolute value is irrelevant,
-- and clearing it mid-session would make an in-flight ticket compare equal after a real departure.
local departures: { [number]: number } = {}

local function departureTicket(userId: number?): number
	if userId == nil then
		return 0
	end
	return departures[userId] or 0
end

local function noteDeparture(userId: number): ()
	departures[userId] = (departures[userId] or 0) + 1
end

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6). So identity
-- is taken from the FIELD, which both a real Player and Mocks.player answer.
local function userIdOf(player: any): number?
	if player == nil then
		return nil
	end
	local userId = (player :: any).UserId
	if type(userId) ~= "number" or userId ~= userId then
		return nil
	end
	return userId
end

-- The persisted dome id on a blob, or nil. "" means "holds none" (Migrations seeds it that way).
local function persistedPlotIdOf(data: any): string?
	if type(data) ~= "table" or type(data.plot) ~= "table" then
		return nil
	end
	local plotId = data.plot.plotId
	if type(plotId) ~= "string" or plotId == "" then
		return nil
	end
	return plotId
end

-- AMENDMENT A1's seam read. Nil-safe and value-checked: Depth tiers is a later batch, so ctx.depth is
-- ABSENT today and every claim takes the default. A non-number / NaN / infinite Y from a future Depth
-- implementation is refused rather than pivoting a dome to nowhere.
local function tierYFor(ctx: any, data: any): number
	local depth = if ctx ~= nil then ctx.depth else nil
	if depth ~= nil and type(depth.tierYFor) == "function" then
		local ok, y = pcall(function()
			return depth:tierYFor(data)
		end)
		if ok and type(y) == "number" and y == y and y ~= math.huge and y ~= -math.huge then
			return y
		end
	end
	return DEFAULT_TIER_Y
end

-- Guarded runtime refs: these globals are REAL in Roblox and NIL under Lune.
local function robloxInstance(): any
	local instanceGlobal: any = Instance
	return instanceGlobal
end

-- Has this player left since `ticket` was taken? TWO INDEPENDENT SIGNALS, and either is enough,
-- because they fail in different directions:
--   * the departure ledger — driven by releaseFor, i.e. by the pinned leave order itself. This is
--     the signal that exists under Lune, so it is the one a Tier-1 spec can drive.
--   * the engine roster — `Players:GetPlayerByUserId`. Belt and braces for a leave that never
--     reached PlayerLifecycle (a bootstrap that dropped it, a handler that threw before step 2).
-- Absent an engine the roster answer is simply unavailable, NOT "gone": treating a nil `game` as a
-- departure would make every Lune-driven claim fail, which is the opposite failure.
local function hasDeparted(player: any, ticket: number): boolean
	local userId = userIdOf(player)
	if userId == nil then
		return true -- no identity to be present under
	end
	if departureTicket(userId) ~= ticket then
		return true
	end
	local realGame: any = game
	if realGame == nil then
		return false -- Lune: the ledger is the whole answer
	end
	local ok, found = pcall(function()
		return realGame:GetService("Players"):GetPlayerByUserId(userId)
	end)
	return ok and found == nil
end

-- Pad lighting — "a free dome plot is claimed for you at Depth 1 and its pad lights up" (core loop,
-- step 1). Cosmetic only, and pcall-guarded: a presentation failure must never break the occupancy
-- bookkeeping it is describing.
local function setPadLit(record: PlotRecord, lit: boolean): ()
	local pad = record.pad
	if pad == nil then
		return
	end
	local color3Global: any = Color3
	local enumGlobal: any = Enum
	if color3Global == nil or enumGlobal == nil then
		return
	end
	pcall(function()
		if lit then
			pad.Color = color3Global.fromRGB(64, 226, 255)
			pad.Material = enumGlobal.Material.Neon
		else
			pad.Color = color3Global.fromRGB(48, 56, 64)
			pad.Material = enumGlobal.Material.Slate
		end
		local light = pad:FindFirstChildOfClass("PointLight")
		if light ~= nil then
			light.Enabled = lit
		end
	end)
end

-- Everything the DEPARTED player parented under this dome root (Salvage's smelter/conveyor/drones)
-- goes with them; the greybox shell stays. Without this the next claimant inherits the last player's
-- structures, which is the same class of leak as an unreleased plot, only visible.
local function clearContents(record: PlotRecord): ()
	local model = record.model
	if model == nil then
		return
	end
	pcall(function()
		for _, child in model:GetChildren() do
			if child.Name ~= SHELL_FOLDER_NAME then
				child:Destroy()
			end
		end
	end)
end

-- THE only two occupancy writers in this file. Synchronous by construction: no yield, no data call,
-- no engine call that can fail unguarded — which is what makes the reserve-before-yield argument in
-- the header hold, and what makes release-on-leave safe to run inside the pinned leave sequence.
local function occupy(record: PlotRecord, userId: number): ()
	record.ownerUserId = userId
	plotIdByOwner[userId] = record.id
	setPadLit(record, true)
end

local function vacate(record: PlotRecord): ()
	local userId = record.ownerUserId
	if userId ~= nil and plotIdByOwner[userId] == record.id then
		plotIdByOwner[userId] = nil
	end
	record.ownerUserId = nil
	setPadLit(record, false)
	clearContents(record)
end

-- ── ctx.plot SEAM ───────────────────────────────────────────────────────────────────────────────
-- Its OWN table, named `PlotSeam`, installed on context.plot. NOT `context.plot = self`: that
-- publishes the ident `self`, which matches no `function self.<method>(` definition anywhere, so
-- gate-reachability's seam rules found ZERO subjects and were blind to every seam in the game. The
-- separate table also keeps the seam surface honest — what is on PlotSeam is what gameplay may call;
-- Start, the action factories and the world builders are this service's own business.
local PlotSeam = {}

-- The dome id this player holds, or nil when they hold none. In-memory truth, NOT the blob: the blob
-- is a per-player record and cannot answer "is this dome held by someone else on this server".
function PlotSeam.plotIdFor(_self: any, player: any): string?
	local userId = userIdOf(player)
	if userId == nil then
		return nil
	end
	return plotIdByOwner[userId]
end

-- The world root (the dome Model) every structure parents under, or nil when this player holds no
-- dome / the world has not been built (Lune, edit mode before Start). Depth tiers moves THIS instance
-- down the Y axis on a successful descend.
function PlotSeam.rootFor(_self: any, player: any): any?
	local plotId = PlotSeam:plotIdFor(player)
	if plotId == nil then
		return nil
	end
	local record = plotById[plotId]
	if record == nil then
		return nil
	end
	return record.model
end

-- The UserId currently holding `plotId`, or nil when the dome is free or unknown.
function PlotSeam.ownerOf(_self: any, plotId: any): number?
	if type(plotId) ~= "string" then
		return nil
	end
	local record = plotById[plotId]
	if record == nil then
		return nil
	end
	return record.ownerUserId
end

-- Free whatever dome this player holds; returns whether anything was actually released.
--
-- STEP 2 OF THE PINNED LEAVE SEQUENCE (AMENDMENT A10b): analytics session_end -> THIS -> data session
-- release. PlayerLifecycle calls it by this exact name, so renaming it silently unhooks
-- release-on-leave. It is deliberately SYNCHRONOUS and writes NOTHING to the data layer:
--   * a yield here would sit between session_end and the player's final durable write, and would open
--     the very leave->claim window this method exists to close;
--   * the persisted plotId is left ALONE on purpose. It is a HINT, not a lock — on rejoin the player
--     re-takes that dome when it is free, and takes a different one (rewriting the field) when it is
--     not. Clearing it here would throw away dome stability across a rejoin for no gain.
function PlotSeam.releaseFor(_self: any, player: any): boolean
	local userId = userIdOf(player)
	if userId == nil then
		return false
	end
	-- RECORD THE DEPARTURE FIRST, unconditionally — before the "holds nothing" early return below.
	-- The leak this closes is precisely the case where the player holds nothing YET: their join-time
	-- claim is still parked in awaitLoaded, and this is the only PlayerRemoving they will ever get.
	-- The return value keeps its old meaning ("was a dome actually freed"); presence is a separate
	-- fact, and conflating them is what made the empty release look like a no-op.
	noteDeparture(userId)
	local plotId = plotIdByOwner[userId]
	if plotId == nil then
		return false
	end
	local record = plotById[plotId]
	if record == nil then
		-- Registry rebuilt under a live holder (only reachable if build() ran mid-session). Drop the
		-- dangling reverse-index entry so the player is not permanently "already claimed".
		plotIdByOwner[userId] = nil
		return true
	end
	vacate(record)
	return true
end

-- ── selection ───────────────────────────────────────────────────────────────────────────────────
-- Prefer the player's PERSISTED dome when it is free (a returning player finds their own dome), else
-- the first free one. A persisted id whose dome is already held on THIS server is NOT honoured — the
-- claim falls through to a free dome and the field is rewritten, which is the rejoin rule.
local function pickFree(preferredId: string?): PlotRecord?
	if preferredId ~= nil then
		local preferred = plotById[preferredId]
		if preferred ~= nil and PlotSeam:ownerOf(preferred.id) == nil then
			return preferred
		end
	end
	for _, record in plots do
		if PlotSeam:ownerOf(record.id) == nil then
			return record
		end
	end
	return nil
end

-- ── registry ────────────────────────────────────────────────────────────────────────────────────

-- Clamp a MaxPlayers reading into a sane registry size. Separate from `build` so a spec can build a
-- ONE-dome server and reach the Unavailable path deliberately.
function PlotService.plotCountFor(_self: any, maxPlayers: any): number
	if type(maxPlayers) == "number" and maxPlayers == maxPlayers and maxPlayers >= 1 then
		return math.clamp(math.floor(maxPlayers), MIN_PLOT_COUNT, MAX_PLOT_COUNT)
	end
	return DEFAULT_PLOT_COUNT
end

function PlotService.desiredPlotCount(self: any): number
	local realGame: any = game
	if realGame ~= nil then
		local ok, maxPlayers = pcall(function()
			return realGame:GetService("Players").MaxPlayers
		end)
		if ok then
			return self:plotCountFor(maxPlayers)
		end
	end
	return self:plotCountFor(nil)
end

-- (Re)build the occupancy registry. RESETS all state — every dome free, no owners — so a spec's Start
-- always begins from a clean server rather than inheriting the previous test's claims.
function PlotService.build(_self: any, count: any): number
	local n = DEFAULT_PLOT_COUNT
	if type(count) == "number" and count == count and count >= 1 then
		n = math.min(math.floor(count), MAX_PLOT_COUNT)
	end
	plots = {}
	plotById = {}
	plotIdByOwner = {}
	for index = 1, n do
		local record: PlotRecord = {
			id = PLOT_ID_PREFIX .. tostring(index),
			index = index,
			ownerUserId = nil,
			model = nil,
			pad = nil,
		}
		table.insert(plots, record)
		plotById[record.id] = record
	end
	return n
end

function PlotService.plotCount(_self: any): number
	return #plots
end

function PlotService.plotIds(_self: any): { string }
	local ids: { string } = {}
	for _, record in plots do
		table.insert(ids, record.id)
	end
	return ids
end

function PlotService.freeCount(_self: any): number
	local free = 0
	for _, record in plots do
		if record.ownerUserId == nil then
			free += 1
		end
	end
	return free
end

-- ── placement (AMENDMENT A1) ────────────────────────────────────────────────────────────────────

-- PURE ring layout: plain numbers, no Vector3/CFrame (both nil under Lune), so a spec asserts the
-- placement math — and specifically that Y IS THE PERSISTED TIER'S Y — with no engine.
function PlotService.positionFor(
	_self: any,
	index: number,
	count: number,
	tierY: number
): (number, number, number)
	local n = math.max(1, math.floor(count))
	local i = math.clamp(math.floor(index), 1, n)
	local radius = math.max(MIN_RING_RADIUS_STUDS, (n * RING_SPACING_STUDS) / (2 * math.pi))
	local angle = ((i - 1) / n) * 2 * math.pi
	return radius * math.cos(angle), tierY, radius * math.sin(angle)
end

-- Move this player's dome root to its ring slot at `tierY`. Called on EVERY claim — first claim and
-- rejoin alike — so a returning player whose persisted tier is 4 finds their dome at tier 4's Y, not
-- at Depth 1. Returns whether an instance was actually moved (false under Lune / before buildWorld).
function PlotService.placeFor(self: any, player: any, tierY: number): boolean
	local plotId = PlotSeam:plotIdFor(player)
	if plotId == nil then
		return false
	end
	local record = plotById[plotId]
	if record == nil then
		return false
	end
	local root = PlotSeam:rootFor(player)
	if root == nil then
		return false
	end
	local cframeGlobal: any = CFrame
	if cframeGlobal == nil then
		return false
	end
	local x, y, z = self:positionFor(record.index, #plots, tierY)
	local ok = pcall(function()
		root:PivotTo(cframeGlobal.new(x, y, z))
	end)
	return ok
end

-- ── the claim ───────────────────────────────────────────────────────────────────────────────────

function PlotService.describe(
	self: any,
	record: PlotRecord?,
	claimedAtUnix: number,
	tierY: number
): ClaimInfo
	if record == nil then
		return {
			plotId = "",
			claimedAtUnix = 0,
			plotCount = #plots,
			freeCount = self:freeCount(),
			held = false,
			x = 0,
			y = tierY,
			z = 0,
		}
	end
	local x, y, z = self:positionFor((record :: PlotRecord).index, #plots, tierY)
	return {
		plotId = (record :: PlotRecord).id,
		claimedAtUnix = claimedAtUnix,
		plotCount = #plots,
		freeCount = self:freeCount(),
		held = true,
		x = x,
		y = y,
		z = z,
	}
end

-- THE single allocation path. Both the join hook and the plot.claim action go through here, so there
-- is exactly one place where a dome changes hands. See the concurrency argument in the header.
function PlotService.acquire(self: any, ctx: any, player: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "plot: context is missing data/clock")
	end
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "plot: player has no numeric UserId")
	end

	-- (1) EXCLUSIVITY, evaluated before anything can yield. A duplicate request that arrived in the
	-- same frame as a claim already in flight lands here, because that claim reserved synchronously.
	local held = plotIdByOwner[userId]
	if held ~= nil then
		return Result.err(Result.Codes.AlreadyClaimed, `plot: this player already holds {held}`)
	end

	-- (2) The session blob. `get` is a synchronous table lookup — no yield — and answers
	-- Err(NoData) until loadSession resolves, which the client's JoinRetry guard re-issues past.
	local got = ctx.data:get(player)
	if not got.ok then
		return got
	end
	local data = got.value

	-- (3) Pick, still without yielding.
	local record = pickFree(persistedPlotIdOf(data))
	if record == nil then
		return Result.err(
			Result.Codes.Unavailable,
			`plot: all {#plots} domes on this server are held`
		)
	end

	-- (4) RESERVE. From here the dome is this player's as far as every other request is concerned,
	-- and this player is "already claimed" — both facts are visible before the first yield below.
	occupy(record, userId)

	local nowUnix = ctx.clock:unix()
	local tierY = tierYFor(ctx, data)

	-- The presence ticket, taken BEFORE the yield below (same discipline as the reservation itself).
	-- Comparing it afterwards is the only way to tell "this record is still MY claim" from "this
	-- record is mine AGAIN" — a leave + same-server rejoin + re-claim restores `ownerUserId` to this
	-- very UserId, so an identity check alone cannot see that a different claim now owns the dome.
	local ticket = departureTicket(userId)

	-- (5) PERSIST through the single-writer path. This YIELDS: the transform runs under the
	-- per-player FIFO lock. Nothing after this point may assume the world stood still.
	--
	-- THE REVOCATION CHECK LIVES INSIDE THE TRANSFORM (CLAUDE.md §4: the whole read-check-write goes
	-- in ONE ctx.data:update transform, on the lock-held snapshot, never read-then-write across a
	-- yield). The yield is BEFORE the transform — in MockStore's forced yield and in SessionStore's
	-- FIFO `acquire` alike — so the transform body is the first moment after the yield at which this
	-- claim can still decide not to write. Checking only AFTERWARDS, as step (6) used to on its own,
	-- means an abandoned claim commits `plot.plotId` and then returns an error: the player is told
	-- their claim failed while their durable record asserts ownership of a dome the registry now
	-- attributes to someone else, and a same-server rejoin's stale thread lands on top of the LIVE
	-- session's own newer claim — the client renders `view.plot.plotId`, so that is a live player's
	-- dome marker pointing at a dome another player is standing on.
	local abandoned = false
	local written = ctx.data:update(player, function(blob: any): any
		if hasDeparted(player, ticket) or record.ownerUserId ~= userId then
			abandoned = true
			return blob -- write NOTHING: this reservation is no longer ours to record
		end
		local plot = blob.plot
		if type(plot) ~= "table" then
			plot = { plotId = "", claimedAtUnix = 0 }
			blob.plot = plot
		end
		plot.plotId = record.id
		plot.claimedAtUnix = nowUnix
		return blob
	end)
	local departed = hasDeparted(player, ticket)

	if not written.ok then
		-- ROLL BACK the reservation — but ONLY this claim's. A dome held by a claim that never
		-- persisted would be lost for the life of the server; a dome VACATED out from under whoever
		-- holds it now is worse, because `vacate` clears THEIR plotIdByOwner entry, nils the owner,
		-- unlights the pad and `clearContents` Destroys everything they parented under `rootFor`
		-- (Salvage's smelter/conveyor/drones) — one dome, two players' worth of truth. Both guards
		-- are needed and they catch different things: the identity check sees a DIFFERENT player's
		-- record, the ticket sees THIS player's record re-taken by a newer claim of their own after
		-- a leave + rejoin. This mirrors the success branch below, which has always re-checked.
		if not departed and record.ownerUserId == userId then
			vacate(record)
		end
		return written
	end

	-- (6) The reservation may have been revoked while (5) yielded — the player left and the pinned
	-- leave sequence ran releaseFor. Do NOT re-occupy: the next player may already hold this dome,
	-- and `departed` additionally covers the case where the next holder is this same player's newer
	-- session, which `ownerUserId` alone reports as "still mine". `abandoned` is the transform's own
	-- verdict, which is the one that decided whether anything was written; the two conditions after
	-- it re-check the same facts at the outer level, so a revocation landing in the sliver AFTER the
	-- transform returns is still refused (it simply has no write to undo).
	if abandoned or departed or record.ownerUserId ~= userId then
		return Result.err(
			Result.Codes.SessionClosed,
			"plot: claim abandoned — the session was released mid-claim"
		)
	end

	-- (7) The world is DERIVED from the persisted facts, and only after they are durable.
	self:placeFor(player, tierY)

	return Result.ok(self:describe(record, nowUnix, tierY))
end

-- ── actions ─────────────────────────────────────────────────────────────────────────────────────

-- The claim payload carries NO plot id BY CONTRACT — the server picks. A client-named plot IS the
-- plot-claim-hijack exploit, so a payload that names one is REFUSED rather than ignored (an ignored
-- hijack attempt is indistinguishable from a well-formed request, and the difference is the only
-- signal that someone is probing). The validator returns a FRESH EMPTY TABLE, so the handler is not
-- merely disciplined about ignoring client data — it is never handed any.
local FORBIDDEN_PAYLOAD_KEYS = { "plotId", "plot", "id", "index", "dome", "domeId", "userId" }

local function validateNoTarget(rawPayload: any): any
	if rawPayload == nil then
		return Result.ok({})
	end
	if type(rawPayload) ~= "table" then
		return Result.err(Result.Codes.BadType, "payload must be a table or nil")
	end
	for _, key in FORBIDDEN_PAYLOAD_KEYS do
		if rawPayload[key] ~= nil then
			return Result.err(
				Result.Codes.BadPayload,
				`plot actions take no target — the SERVER picks the dome (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

-- Exported so a Tier-1 spec can register the action on a Mocks.net harness without Starting the
-- service against a Roblox runtime.
function PlotService.claimAction(self: any): any
	return {
		name = Net.Actions.ClaimPlot,
		validate = validateNoTarget,
		-- Preserved from the contract-pass stub: a claim happens once per session; a few retries
		-- around a join race, never a stream.
		rate = { maxPerWindow = 3, windowSeconds = 5.0 },
		handler = function(ctx: any, _payload: any): any
			return self:acquire(ctx, ctx.player)
		end,
	}
end

function PlotService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchPlot,
		validate = validateNoTarget,
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		-- SIDE-EFFECT FREE: fetch never claims, never releases, never writes. The HUD reads it; a
		-- read surface that could allocate would make "the player holds one dome" depend on how
		-- often the UI refreshed.
		handler = function(ctx: any, _payload: any): any
			local player = ctx.player
			local got = ctx.data:get(player)
			if not got.ok then
				return got -- NoData until loadSession resolves; JoinRetry re-issues on the data push
			end
			local data = got.value
			local tierY = tierYFor(ctx, data)
			local plotId = PlotSeam:plotIdFor(player)
			if plotId == nil then
				return Result.ok(self:describe(nil, 0, tierY))
			end
			local record = plotById[plotId]
			local claimedAtUnix = 0
			if type(data.plot) == "table" and type(data.plot.claimedAtUnix) == "number" then
				claimedAtUnix = data.plot.claimedAtUnix
			end
			return Result.ok(self:describe(record, claimedAtUnix, tierY))
		end,
	}
end

-- ── join lifecycle ──────────────────────────────────────────────────────────────────────────────

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable. A spec can replace `_wait` to drive its fake data layer without sleeping.
function PlotService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- Bounded wait for this player's session blob. Returns nil when the budget ran out or the player left
-- mid-load — in which case nothing is claimed, rather than a dome being reserved for someone who is
-- already gone (that dome would then be held until the server dies).
function PlotService.awaitLoaded(self: any, dataService: any, player: any): any?
	if dataService == nil then
		return nil
	end
	-- Taken BEFORE the first poll: everything after this point runs across yields.
	local ticket = departureTicket(userIdOf(player))
	for attempt = 1, self.loadWaitAttempts do
		-- PRESENCE BEFORE DATA, every iteration. `dataService:get` answering Ok is NOT evidence the
		-- player is here: DataService keeps `_sessions[uid]` populated across the yielding release on
		-- BOTH its leave paths, so a departed player's blob reads perfectly for the whole write. A
		-- dome reserved in that window is held by an absent UserId until the server dies — releaseFor
		-- already ran and nothing reconciles the registry against Players — and with churn the whole
		-- registry fills with ghosts and every real joiner is refused Unavailable.
		if hasDeparted(player, ticket) then
			return nil
		end
		local got = dataService:get(player)
		if type(got) == "table" and got.ok == true then
			return got.value
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return nil
end

-- Push the refreshed client view after a join-time claim. DataService pushes the view once, on load —
-- which is BEFORE this claim lands — so without this the HUD's `view.plot` would describe the state
-- the player joined with until the next unrelated write. Also the signal JoinRetry re-issues a lost
-- join-time `plot.fetch` on. Guarded + pcall'd: a push failure must never undo a committed claim.
function PlotService.pushView(_self: any, context: any, player: any): boolean
	local net = if context ~= nil then context.net else nil
	if net == nil or type(net.fireClient) ~= "function" or context.data == nil then
		return false
	end
	local got = context.data:get(player)
	if type(got) ~= "table" or got.ok ~= true then
		return false
	end
	local ok = pcall(function()
		net:fireClient(player, "data", Types.toView(got.value))
	end)
	return ok
end

-- THE join hook: wait for the load, then claim. Idempotent by construction — it goes through
-- `acquire`, so a second run for the same player returns Err(AlreadyClaimed) and allocates nothing.
function PlotService.claimOnJoin(self: any, context: any, player: any): any
	local ticket = departureTicket(userIdOf(player))
	local loaded = self:awaitLoaded(context.data, player)
	if loaded == nil then
		-- Distinguish the two ways the wait ends, because they mean opposite things operationally:
		-- a budget exhaustion is a data-layer problem worth looking at, a departure is the normal
		-- outcome of someone quitting on the loading screen and must not read as one.
		if hasDeparted(player, ticket) then
			return Result.err(
				Result.Codes.SessionClosed,
				"plot: the player left before their session loaded — nothing claimed"
			)
		end
		return Result.err(Result.Codes.NoData, "plot: session never loaded for this player")
	end
	local claimed = self:acquire(context, player)
	if claimed.ok then
		self:pushView(context, player)
	end
	return claimed
end

-- ── world (greybox) ─────────────────────────────────────────────────────────────────────────────
-- ROBLOX-ONLY, every entry point guarded. "100% greybox-in-code for v1: domes = Parts + transparency."

local function buildDome(folder: any, record: PlotRecord): ()
	local instanceGlobal = robloxInstance()
	local color3Global: any = Color3
	local vector3Global: any = Vector3
	local enumGlobal: any = Enum
	if
		instanceGlobal == nil
		or color3Global == nil
		or vector3Global == nil
		or enumGlobal == nil
	then
		return
	end

	local model = instanceGlobal.new("Model")
	model.Name = record.id

	local shell = instanceGlobal.new("Folder")
	shell.Name = SHELL_FOLDER_NAME
	shell.Parent = model

	local pad = instanceGlobal.new("Part")
	pad.Name = "Pad"
	pad.Anchored = true
	pad.Size = vector3Global.new(PAD_SIZE_STUDS, PAD_THICKNESS_STUDS, PAD_SIZE_STUDS)
	pad.TopSurface = enumGlobal.SurfaceType.Smooth
	pad.BottomSurface = enumGlobal.SurfaceType.Smooth
	pad.Parent = shell

	local light = instanceGlobal.new("PointLight")
	light.Name = "PadLight"
	light.Color = color3Global.fromRGB(64, 226, 255)
	light.Range = 48
	light.Brightness = 2
	light.Enabled = false
	light.Parent = pad

	local dome = instanceGlobal.new("Part")
	dome.Name = "Shield"
	dome.Shape = enumGlobal.PartType.Ball
	dome.Anchored = true
	dome.CanCollide = false
	dome.Transparency = 0.7
	dome.Color = color3Global.fromRGB(120, 200, 220)
	dome.Material = enumGlobal.Material.Glass
	dome.Size = vector3Global.new(DOME_DIAMETER_STUDS, DOME_DIAMETER_STUDS, DOME_DIAMETER_STUDS)
	dome.Position = pad.Position + vector3Global.new(0, DOME_DIAMETER_STUDS / 2, 0)
	dome.Parent = shell

	model.PrimaryPart = pad
	model.Parent = folder

	record.model = model
	record.pad = pad
	setPadLit(record, record.ownerUserId ~= nil)
end

-- Find-or-create the plots folder and every dome Model, then park each one at its ring slot on the
-- default tier. IDEMPOTENT: a dome that already has a model is left alone.
function PlotService.buildWorld(self: any): boolean
	local instanceGlobal = robloxInstance()
	local workspaceGlobal: any = workspace
	if instanceGlobal == nil or workspaceGlobal == nil then
		return false
	end
	local folder = workspaceGlobal:FindFirstChild(PLOTS_FOLDER_NAME)
	if folder == nil then
		folder = instanceGlobal.new("Folder")
		folder.Name = PLOTS_FOLDER_NAME
		folder.Parent = workspaceGlobal
	end
	local cframeGlobal: any = CFrame
	for _, record in plots do
		if record.model == nil then
			buildDome(folder, record)
			if record.model ~= nil and cframeGlobal ~= nil then
				local x, y, z = self:positionFor(record.index, #plots, DEFAULT_TIER_Y)
				pcall(function()
					record.model:PivotTo(cframeGlobal.new(x, y, z))
				end)
			end
		end
	end
	return true
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: install the seam, size + build the registry, register the wire surface, then (Roblox only)
-- build the greybox and hook the join path. The seam assignment is deliberately FIRST — the
-- ActionContext projection reads ctx.plot at DISPATCH time, and a service that Starts later may read
-- it during its own Start. Lune-callable: everything engine-shaped lives behind startRuntime.
function PlotService.Start(self: any, context: any): ()
	context.plot = PlotSeam
	self:build(self:desiredPlotCount())
	context.net:register(self:claimAction())
	context.net:register(self:fetchAction())
	self:startRuntime(context)
end

function PlotService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	if realGame == nil then
		return -- Lune: no engine to wire. Specs drive acquire / the seam / the actions directly.
	end
	self._connections = {}
	self:buildWorld()

	local Players = realGame:GetService("Players")

	local function onAdded(player: any): ()
		self:claimOnJoin(context, player)
	end

	-- Players already present (a Studio Play session installs scripts after the local player joins).
	-- Spawned: awaitLoaded yields and the bootstrap must not block on it.
	for _, player in Players:GetPlayers() do
		task.spawn(onAdded, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: any)
			task.spawn(onAdded, player)
		end)
	)

	-- [AMENDMENT A10b] The leave sequence is OWNED by src/server/framework/PlayerLifecycle, which
	-- Starts first, claims it, and calls PlotSeam.releaseFor as its middle step. Connecting here as
	-- well would free the dome from a SECOND handler on the same signal, in an order this game does
	-- not control. Still connect when nobody claimed the sequence, so a bootstrap that ever dropped
	-- the lifecycle degrades to "analytics may be stale" rather than to "domes are never freed".
	if context.playerRemovingOwner == nil then
		table.insert(
			self._connections,
			Players.PlayerRemoving:Connect(function(player: any)
				PlotSeam:releaseFor(player)
			end)
		)
	end
end

function PlotService.Stop(self: any, _context: any): ()
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
end

return PlotService
