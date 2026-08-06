--!strict
-- games/deep-reach/src/server/services/depth/DepthService.luau   [feature: depth tiers]
--
-- THE authoritative owner of the trench ladder: the five tiers (plus the VIP trench above them), THE
-- PRESSURE GATE, the per-tier salvage-value multiplier, the daily restock rich wreck, and the visible
-- descent of the dome. Replaces the contract-pass stub in place, preserving every contract decision
-- the stub pinned: the two action names (Net.Actions.Descend / Net.Actions.FetchDepth), their
-- RatePolicies ({3, 5.0s} and {10, 1.0s}), closure-based registration, and the SEPARATE seam table
-- literally named `DepthSeam` — never `context.depth = self`, which publishes the ident `self`,
-- matches no `function self.<method>(` definition anywhere, and so leaves gate-reachability's seam
-- rules with ZERO subjects and blind to every seam in the game.
--
-- ── WHAT THIS SLICE OWNS ────────────────────────────────────────────────────────────────────────
--  1. THE TIER TABLE. Five trench tiers plus the VIP trench, each with a Credits cost, a MINIMUM HULL
--     RATING, a salvage-value multiplier and a world Y. Tier 1 is where every player starts: it costs
--     nothing, demands nothing and multiplies by 1, which is why an absent `upgrades.depth` reads as
--     tier 1 rather than as a missing record.
--  2. THE PRESSURE GATE, and it is not bypassable by re-ordering purchases. See THE GATE below.
--  3. THE SEAM SALVAGE CORE READS — `DepthSeam:valueMultiplier(data, nowUnix)`. SalvageService
--     MULTIPLIES its derived rate by it, so 1 means "rate unchanged" and this is the one number that
--     makes a tier worth its price. Today's restock bonus folds into it (see 4).
--  4. THE RESTOCK ROTATION AND THE RICH WRECK. A day index derived from `ctx.clock:unix()` ONLY picks
--     exactly one trench tier per server-day; a player standing at that tier gets RESTOCK_MULTIPLIER
--     on top of their tier multiplier. AMENDMENT A7: the wreck is a REAL OBJECT, a greybox Part that
--     is cleared and re-placed on the day rollover, so "the rich wreck resets" is provable by the
--     wreck's tier AND position CHANGING between two server-days rather than by an integer flipping —
--     which is exactly the written-never-read shape this game is graded against.
--  5. THE HULL'S CONSUMER — `DepthSeam:hullRatingOf(data)`. StructuresShopService sells `hull` and
--     binds that entry's observable to THIS method (its EFFECTS table names `ctx.depth` as the
--     consumer); until this file existed the shop refused every `hull` sale with Err(PrereqUnmet)
--     because nothing in the running game read `upgrades.hull`. The gate below reads the rating
--     through the SAME method the shop probes, so buying a hull plate measurably moves the gate's
--     outcome for that blob and `hull` becomes sellable with no edit to the shop.
--  6. AMENDMENT A1's OTHER HALF — `DepthSeam:tierYFor(data)`. PlotService places a dome at the
--     player's PERSISTED tier on first claim AND every rejoin; THIS service moves the root only on a
--     successful descend. Between us every path that positions a dome is owned.
--  7. THE WORLD: the stacked trench shells as greybox Parts at descending Y, and the rich wreck.
--     COSMETIC-FOLLOWS-STATE: the authoritative fact is `upgrades.depth` and the world position is
--     derived from it, never the other way round. Nothing built here is ever read back by a rule.
--
-- NOT THIS SLICE: selling hull rating (StructuresShopService writes `upgrades.hull`; this file only
-- READS it); the income tick or the rate function (SalvageService — this supplies ONE multiplier into
-- it); granting the VIP gamepass flag (MonetizationService — only read here); resetting the tier on
-- prestige (ResurfaceService writes `upgrades.depth` back to 1).
--
-- ── THE GATE (spec: "the one rule that stops a rich player skipping the middle game") ────────────
-- `depth.descend` evaluates ALL of the following against the SAME lock-held snapshot in which it
-- debits, in this order:
--   (a) THE PREVIOUS TIER IS ALREADY UNLOCKED. Structural, not a check: the target is computed as
--       `tierOf(snapshot) + 1` INSIDE the transform, so there is no tier index anywhere on this path
--       for a client to name and no purchase order that can skip a rung. Tiers are strictly
--       sequential by construction.
--   (b) THE VIP TRENCH's flag, for the tier that declares one -> Err(PrereqUnmet) when absent.
--   (c) `hullRatingOf(snapshot) >= HULL_MIN[next]` -> Err(PrereqUnmet). NOT Insufficient: a
--       hull-too-low refusal and a plain cannot-afford refusal must not be the same code, or "the
--       pressure gate holds" is untestable.
--   (d) THE CREDITS, through `ctx.economy:spend`, which returns Err(Insufficient) itself and emits
--       currency_spent. This file never touches `data.currencies`.
-- Buying hull first, Credits first, or spamming descend all converge on this ONE guarded transform,
-- because every input it reads comes off the snapshot the lock just handed it.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The double-spend this feature is one mistake away from: read the tier (and therefore the cost and
-- the hull minimum) OUTSIDE the transform, YIELD in ctx.data:update, then debit and write. Two
-- descends in the same frame both price tier 2, both pay tier 2's price, and the player lands on
-- tier 3 for one tier's Credits — or worse, both write tier 2 and one payment vanishes. Three
-- mechanisms close it, and they fail in different directions:
--
--   (1) THE WHOLE GATE AND THE DEBIT ARE ONE LOCK-HELD TRANSFORM. Nothing outside `transform` reads
--       `upgrades.depth`, `upgrades.hull`, `flags` or the balance on a descend path. DataService:update
--       runs the transform under the per-player FIFO lock against a snapshot RE-READ after any earlier
--       update has written, and the transform is synchronous — it contains no yield of any kind. So a
--       second descend's transform necessarily observes the first one's `upgrades.depth` and computes
--       the NEXT tier up, whose hull minimum and price it then fails on its own merits. This is the
--       load-bearing guarantee; it holds even if (2) is deleted.
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION taken BEFORE the update can yield (`self._descending`,
--       the same reserve-before-yield discipline PlotService uses for a dome, DailyDropService for the
--       drop and SalvageService for the smelter). Luau is single-threaded, so the flag is visible to
--       every interleaved request the instant it is set. A duplicate that arrives while the first is
--       parked in the store is refused with Err(PrereqUnmet) — the same code the tier it is racing
--       toward would almost always give it — without ever reaching the data layer. Never RateLimited:
--       that code belongs to the Gate's anti-spam bucket, and conflating the two makes "one descend
--       per gate pass" untestable. Belt-and-braces for (1), never a substitute: it is per-SERVER
--       memory and says nothing about the same player on another server.
--   (3) THE TIER WRITE IS ROLLED BACK IF THE DEBIT REFUSES. The transform writes `upgrades.depth`
--       FIRST and debits LAST, because EconomyService emits currency_spent as its final act and no
--       later statement in a transform may throw and discard a snapshot the event already described.
--       A refused debit restores the value the snapshot held — INCLUDING nil, which restores absence —
--       and returns the Err. `spend` is atomic-or-nothing as of the current commit, so "not ok" means
--       the balance was untouched; the rollback makes THIS transaction atomic on its own side rather
--       than assuming it of the seam (the salvage gate caught exactly that assumption as a mint). And
--       if the WRITE fails the store discards the whole snapshot: nothing was durably debited or
--       levelled, and there is nothing to compensate.
--
-- THE ONE PIECE OF SESSION STATE, and why it cannot double-fire OR go silent: `loop_completed` must
-- be emitted on the FIRST successful descend of a SESSION and never again. The check and the set are
-- ONE SYNCHRONOUS PAIR run AFTER the write committed (`self._loopCompleted[userId]`), with no yield
-- between them, so two descends cannot both observe "not yet emitted". It is deliberately NOT
-- captured before the update: a value captured before a yield and acted on after it is precisely the
-- shape being defended against, and there is nothing to roll back here — an un-set flag on a failed
-- write simply means the next successful descend emits, which is correct.
--
-- WHAT THE ENTRY STORES IS THE SESSION EPOCH (`stats.joinCount`), read off the lock-held snapshot —
-- not a boolean. A boolean encodes "this userId emitted at some point on this SERVER", which stops
-- being the contract the moment a player leaves and rejoins the same server: their second session's
-- first descend would find the flag still set and emit nothing, and the core-loop funnel would
-- under-count. Nothing here may connect PlayerRemoving to notice the boundary (framework/
-- PlayerLifecycle is the one owner of that signal and its order is pinned), and the roster sweep that
-- does exist is a 60-second poll which a rejoining player is PRESENT for — so it skips them — and
-- which never runs at all under Lune. Comparing a persisted per-session identity needs neither: it is
-- pure, it is decided on the same snapshot the descend committed against, and it reads identically in
-- both runtimes. `stats.joinCount` is bumped by DataService on every loadSession and written by
-- nothing else; OfflineService already uses it as its session epoch for the same reason.
--
-- ── THE THREE ANALYTICS EMIT POINTS ─────────────────────────────────────────────────────────────
--   * `progression`     — after a successful descend COMMITS, carrying the new tier index.
--   * `loop_completed`  — on the FIRST successful descend of a session; it is the terminal step of the
--                         spec's core loop (join -> plot -> buy drone -> smelt -> descend).
--   * `currency_spent`  — emitted BY ctx.economy:spend. NEVER emitted here; doing so double-counts.
-- Every emit is nil-safe by convention at the call site and pcall-guarded: a throwing emitter must
-- never turn a committed descend into an error.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- Every decision in this file is Roblox-FREE: tierOf / tierAt / hullRatingOf / valueMultiplier /
-- tierYFor / dayIndexAt / restockTierAt / wreckPlacementAt / describe / descend / validateNoArguments
-- and both action factories run under Lune with Mocks.player + a real DataService over MockStore and
-- no engine at all. Only `startRuntime`, `pushView` and the world builders touch `game` / `task` /
-- `Instance` / `workspace`, each through a guarded local, so requiring and Starting this module under
-- Lune never throws.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT Rojo service root
-- than this ServerScriptService module — so the relative string cannot reach it there; require by
-- instance. Under Lune (script == nil) the filesystem path resolves.
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

local DepthService = {}
DepthService.name = "DepthService"

-- ── the persisted keys (canonical; the same strings other services use) ─────────────────────────
-- `upgrades.depth` rides the OPEN `upgrades` map — no migration, no schema bump. An absent key reads
-- as tier 1 (see `tierOf`), which is the fresh-player state Migrations already seeds.
local DEPTH_UPGRADE_KEY = "depth"
-- `upgrades.hull` is written by StructuresShopService and READ HERE. This is the only reader in the
-- game, and the shop's `hull` entry is unsellable while it does not exist.
local HULL_UPGRADE_KEY = "hull"
-- Granted by MonetizationService; only ever READ here.
local VIP_TRENCH_FLAG = "gamepass.vipTrench"

DepthService.DEPTH_UPGRADE_KEY = DEPTH_UPGRADE_KEY
DepthService.HULL_UPGRADE_KEY = HULL_UPGRADE_KEY
DepthService.VIP_TRENCH_FLAG = VIP_TRENCH_FLAG

-- The currency a descend is priced in. A literal rather than a require of EconomyService: a service
-- never sibling-requires another service, and the key is the same open-map key Migrations seeds.
local DESCEND_CURRENCY = "Credits"

-- THE HULL RATING MODEL, and it MUST agree with StructuresShopService.hullRatingOf. The shop renders
-- the rating on its kiosk sign and on its buy reply; this service decides whether that rating is
-- enough. Two different formulas would show the player a number the gate does not believe, which is
-- the worst kind of disagreement — silent, and only visible as an inexplicable refusal.
-- Level 0 is rated for the surface tier; each plate is worth one more tier of pressure.
local BASE_HULL_RATING = 1
local HULL_RATING_PER_LEVEL = 1

DepthService.BASE_HULL_RATING = BASE_HULL_RATING
DepthService.HULL_RATING_PER_LEVEL = HULL_RATING_PER_LEVEL

-- A level read off a DataStore blob is data, not a fact. A level of 1e308 (or NaN) would otherwise
-- turn a rating into inf/NaN and make every comparison against it false forever.
local MAX_UPGRADE_LEVEL = 10000

-- ── THE TIER TABLE ──────────────────────────────────────────────────────────────────────────────
-- Five trench tiers plus the VIP trench. Deliberately an ARRAY indexed by tier number, not a keyed
-- catalog: the tier index IS the identity, it is strictly sequential, and there is no id for a client
-- to name. `cost` is what it costs to DESCEND INTO this tier (tier 1 is free — it is where you
-- start). `hullMin` is the rating the pressure gate demands. `valueMultiplier` is what SalvageService
-- multiplies its rate by while the player is here. `y` is the world height of the tier's shell.
--
-- The curve: each tier roughly multiplies income by 1.6x and costs ~7x the last, so a tier is bought
-- with the income of the one above it rather than skipped past — and the hull minimum makes that
-- ordering mandatory instead of merely economical. The VIP trench steps harder than 1.6x on purpose;
-- see its own note below.
export type Tier = {
	index: number,
	label: string,
	cost: number,
	hullMin: number,
	valueMultiplier: number,
	y: number,
	requiresFlag: string?,
}

-- Vertical spacing between shells, in studs. Big enough that the descent is legible from across the
-- map ("the whole dome descends to a richer trench tier" has to be SEEN, not inferred from a badge).
local TIER_DROP_STUDS = 180

local TIERS: { Tier } = {
	{
		index = 1,
		label = "Shelf Break",
		cost = 0,
		hullMin = 1,
		valueMultiplier = 1,
		y = 0,
		requiresFlag = nil,
	},
	{
		index = 2,
		label = "Twilight Shelf",
		cost = 1500,
		hullMin = 2,
		valueMultiplier = 1.6,
		y = -TIER_DROP_STUDS,
		requiresFlag = nil,
	},
	{
		index = 3,
		label = "Midnight Slope",
		cost = 12000,
		hullMin = 4,
		valueMultiplier = 2.6,
		y = -2 * TIER_DROP_STUDS,
		requiresFlag = nil,
	},
	{
		index = 4,
		label = "Abyssal Plain",
		cost = 80000,
		hullMin = 6,
		valueMultiplier = 4.2,
		y = -3 * TIER_DROP_STUDS,
		requiresFlag = nil,
	},
	{
		index = 5,
		label = "Hadal Trench",
		cost = 500000,
		hullMin = 8,
		valueMultiplier = 7,
		y = -4 * TIER_DROP_STUDS,
		requiresFlag = nil,
	},
	-- THE VIP TRENCH (spec monetization: "an exclusive depth tier"). It sits ABOVE the five in the
	-- ladder and below them in the water. It is gated on the gamepass flag AND on a hull rating AND on
	-- Credits — the pass buys ACCESS, never a skipped rung: tier 6 still requires tier 5 unlocked.
	--
	-- ITS MULTIPLIER MUST BEAT THE RESTOCKED READING OF EVERY RUNG BELOW IT, not merely their flat
	-- ones. The rich wreck deliberately never lands here (RESTOCK_TIER_COUNT below covers the five
	-- trench tiers only, so the daily hook stays reachable by the players who can actually stand in
	-- it), which makes this the ONE rung with no compensating hot day of its own. At 12 the free
	-- Hadal Trench read 7 x RESTOCK_MULTIPLIER = 14 one day in five and out-earned a player who had
	-- paid 2,500,000 Credits AND a real-money pass — and depth is one-way (nothing walks
	-- `upgrades.depth` back up but a resurface, which resets to 1), so that was a PERMANENT pay cut
	-- on 20% of days, not a temporary swing the rotation evens out. 16 clears 14 with room for the
	-- restock bonus to be re-tuned; the spec case "the paywalled trench out-earns EVERY restocked
	-- tier below it" is what holds this true if either number moves again.
	{
		index = 6,
		label = "The Rift",
		cost = 2500000,
		hullMin = 10,
		valueMultiplier = 16,
		y = -5 * TIER_DROP_STUDS,
		requiresFlag = VIP_TRENCH_FLAG,
	},
}

local MAX_TIER = #TIERS
-- The tier a blob with no `upgrades.depth` is standing on. Not a fallback: a fresh player IS at the
-- shelf break, so this is the value the COMMON path produces.
local FIRST_TIER = 1

DepthService.TIERS = TIERS
DepthService.MAX_TIER = MAX_TIER
DepthService.FIRST_TIER = FIRST_TIER
DepthService.TIER_DROP_STUDS = TIER_DROP_STUDS

-- ── THE DAILY RESTOCK (server clock only; no client input, no os.time) ──────────────────────────
-- A server-day is a whole UTC day of `ctx.clock:unix()`. The rotation is a PURE function of that day
-- index, so every server in the game agrees on today's rich wreck without coordinating, and a spec
-- proves the rollover by advancing the injected clock.
local DAY_SECONDS = 86400

-- The wreck rotates over the FIVE base tiers only. The VIP trench is behind a paywall, and putting
-- the game's daily re-entry hook somewhere most players cannot stand would make the hook unreachable
-- for them — a re-entry reason nobody can act on is not a re-entry reason.
local RESTOCK_TIER_COUNT = 5

-- What the rich wreck is worth: it DOUBLES the salvage value of the tier it spawned in, on top of
-- that tier's own multiplier. It rides the single `valueMultiplier` seam, so Salvage core needs no
-- second multiplier input and there is exactly one place per-tier value is decided.
local RESTOCK_MULTIPLIER = 2

-- The rotation step. gcd(5, 5) would stall on one tier forever, so the stride is COPRIME with the
-- tier count: the wreck visits all five tiers across five days, in a non-adjacent order, and never
-- lands on the same tier two days running. Deterministic integer arithmetic — no hashing, nothing to
-- get subtly wrong across runtimes, and a spec can predict every day by hand.
local RESTOCK_STRIDE = 2
local RESTOCK_OFFSET = 3

DepthService.DAY_SECONDS = DAY_SECONDS
DepthService.RESTOCK_TIER_COUNT = RESTOCK_TIER_COUNT
DepthService.RESTOCK_MULTIPLIER = RESTOCK_MULTIPLIER

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

-- The ServerContext, captured at Start. The seam needs a clock when a caller supplies none, and the
-- world loop needs ctx.data / ctx.clock (the ActionContext projection deliberately carries no `net`).
DepthService._context = nil :: any
-- userId -> true while that player's descend is parked inside ctx.data:update (mechanism (2)).
DepthService._descending = {} :: { [number]: boolean }
-- userId -> the SESSION EPOCH (`stats.joinCount`) that has already emitted loop_completed. NOT a
-- boolean: a boolean makes the entry mean "this userId has emitted, ever on this server", which
-- outlives the session it was set for (see THE ONE PIECE OF SESSION STATE in the header). Per-server
-- memory, pruned on the day loop's pass over the roster so a long-lived server cannot grow it once
-- per join forever.
DepthService._loopCompleted = {} :: { [number]: number }
-- The rich wreck Part + the day index it was placed for (Roblox only; nil under Lune).
DepthService._wreck = nil :: any
DepthService._wreckDay = nil :: number?
DepthService._trenchFolder = nil :: any
DepthService._running = false
DepthService._connections = {} :: { any }

-- ── helpers (pure) ──────────────────────────────────────────────────────────────────────────────

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6). Identity is
-- taken from the FIELD, which both a live Player and Mocks.player answer.
local function userIdOf(player: any): number?
	if player == nil then
		return nil
	end
	local userId = (player :: any).UserId
	if type(userId) ~= "number" or userId ~= userId then
		return nil
	end
	if userId == math.huge or userId == -math.huge then
		return nil
	end
	return math.floor(userId)
end

local function isUsableNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitizeNow(value: any): number?
	if not isUsableNumber(value) then
		return nil
	end
	return math.floor(value)
end

-- A purchased level: a non-negative integer, clamped. See MAX_UPGRADE_LEVEL.
local function sanitizeLevel(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return math.min(math.floor(value), MAX_UPGRADE_LEVEL)
end

-- The persisted level of one upgrade key, normalized. An absent `upgrades` map reads as all-zero.
local function levelOf(data: any, key: string): number
	if type(data) ~= "table" or type(data.upgrades) ~= "table" then
		return 0
	end
	return sanitizeLevel(data.upgrades[key])
end

-- THE SESSION EPOCH this blob is on — `stats.joinCount`, which DataService bumps on every
-- loadSession and nothing else writes (DataService.luau:154; OfflineService reads it for exactly the
-- same purpose, `epochOf`). It is a per-session identity that is already persisted, so "the FIRST
-- successful descend of a SESSION" can be decided by comparing two numbers on a lock-held snapshot
-- rather than by a leave signal this service is not allowed to connect (framework/PlayerLifecycle
-- owns PlayerRemoving and its pinned order) or by a 60-second roster poll that a rejoining player
-- walks straight through. Garbage / absent reads as 0, which is a legal epoch: the failure direction
-- is then the old one (one emit per userId per server), never a repeated emit.
local function epochOf(data: any): number
	if type(data) ~= "table" or type(data.stats) ~= "table" then
		return 0
	end
	local count = data.stats.joinCount
	if not isUsableNumber(count) or count < 0 then
		return 0
	end
	return math.floor(count)
end

-- A persisted boolean flag, read STRAIGHT OFF THE BLOB — no seam, so there is nothing to race. Only
-- ever true when MonetizationService has granted it server-side; an absent flags map reads false.
local function flagOf(data: any, key: string): boolean
	if type(data) ~= "table" or type(data.flags) ~= "table" then
		return false
	end
	return data.flags[key] == true
end

-- ── the tier ladder (pure over the blob) ────────────────────────────────────────────────────────

-- The tier record for an index, CLAMPED into the ladder. Never returns nil, so no caller downstream
-- has to branch on a garbage index it cannot do anything about.
function DepthService.tierAt(_self: any, index: any): Tier
	if not isUsableNumber(index) then
		return TIERS[FIRST_TIER]
	end
	local i = math.clamp(math.floor(index), FIRST_TIER, MAX_TIER)
	return TIERS[i]
end

-- THE tier this blob is standing on. An absent / garbage / out-of-range `upgrades.depth` reads as
-- tier 1 — the fresh-player state, and the value ResurfaceService writes back on a prestige.
--
-- OUT OF RANGE DEGRADES DOWN, NEVER UP, and that direction is a MONETIZATION BOUNDARY rather than a
-- taste in defaults. `requiresFlag` is consulted only inside the descend transform; every READ path
-- (the seam Salvage multiplies by, the Y PlotService places at, `describe`) trusts the index this
-- function returns and re-checks nothing. So a value that resolved UP would hand a corrupted,
-- rolled-back or mis-migrated record the deepest rung on the ladder — today the paywalled VIP trench,
-- with its 12x+ salvage multiplier and its world Y — with `flags["gamepass.vipTrench"]` absent. A
-- RANGE TEST rather than a clamp also makes the two garbage classes agree: `math.huge` and a string
-- already read as tier 1, and there is no defensible reading in which `1e308` is worth more than
-- infinity. Nothing legitimate reaches this branch — the only writers are this file (currentIndex+1)
-- and ResurfaceService (back to 1) — so degrading to the fresh-player state costs a real player
-- nothing and costs an exploited/corrupt record the paywall.
function DepthService.tierOf(_self: any, data: any): number
	if type(data) ~= "table" or type(data.upgrades) ~= "table" then
		return FIRST_TIER
	end
	local raw = data.upgrades[DEPTH_UPGRADE_KEY]
	if not isUsableNumber(raw) then
		return FIRST_TIER
	end
	local floored = math.floor(raw)
	if floored < FIRST_TIER or floored > MAX_TIER then
		return FIRST_TIER
	end
	return floored
end

-- ── THE RESTOCK ROTATION (pure over the SERVER clock) ───────────────────────────────────────────

-- Which whole server-day `nowUnix` falls in. Floor division, so it advances exactly once per 86400
-- seconds of server time and never on anything a client sent.
function DepthService.dayIndexAt(_self: any, nowUnix: any): number
	local now = sanitizeNow(nowUnix)
	if now == nil then
		return 0
	end
	return math.floor((now :: number) / DAY_SECONDS)
end

-- TODAY's rich-wreck tier: one of the five base tiers, deterministic in the day index alone.
function DepthService.restockTierAt(self: any, nowUnix: any): number
	local day = self:dayIndexAt(nowUnix)
	-- Lua's % is floor-modulo, so a NEGATIVE day index (a clock before 1970 — a fake clock in a spec,
	-- never a live server) still lands inside [0, RESTOCK_TIER_COUNT) instead of producing a negative
	-- tier that would index off the front of the ladder.
	return ((day * RESTOCK_STRIDE + RESTOCK_OFFSET) % RESTOCK_TIER_COUNT) + 1
end

export type WreckPlacement = {
	dayIndex: number,
	tier: number,
	x: number,
	y: number,
	z: number,
}

-- WHERE TODAY'S RICH WRECK SITS — pure numbers, no Vector3/CFrame (both nil under Lune), so a spec
-- asserts AMENDMENT A7's success criterion ("the rich wreck resets") as the placement CHANGING
-- between two server-days, with no engine at all. The XZ is derived from the day index as well as the
-- tier, so the wreck moves even in the (unreachable, given a coprime stride) case of two consecutive
-- days sharing a tier: "it reset" is then visible as a position, not only as an integer.
function DepthService.wreckPlacementAt(self: any, nowUnix: any): WreckPlacement
	local day = self:dayIndexAt(nowUnix)
	local tierIndex = self:restockTierAt(nowUnix)
	local tier = self:tierAt(tierIndex)
	-- A ring of 12 stations around the trench, one step per day: a visible, predictable-but-moving
	-- landmark rather than a random scatter nobody can navigate to.
	local station = day % 12
	local angle = (station / 12) * 2 * math.pi
	local radius = 120
	return {
		dayIndex = day,
		tier = tierIndex,
		x = radius * math.cos(angle),
		y = tier.y + 12, -- floating just off the trench floor, so it reads as a wreck, not a tile
		z = radius * math.sin(angle),
	}
end

-- ── ctx.depth SEAM ──────────────────────────────────────────────────────────────────────────────
-- Its OWN table, literally named `DepthSeam`, installed on context.depth at Start. Exactly THREE
-- methods, because a seam method with no reader is a dangling promise (gate-reachability R1) — and
-- all three have live readers OUTSIDE this file:
--     valueMultiplier -> SalvageService multiplies its derived income rate by it
--     tierYFor        -> PlotService places a claimed dome at this Y (AMENDMENT A1)
--     hullRatingOf    -> StructuresShopService measures what its `hull` entry buys through it
-- Every one is also called from inside this file (the gate, the fetch, the descent), which is the
-- success case, not a self-certification: the shop's audit is what certifies `hull`, and it resolves
-- through ctx.depth precisely so this file cannot certify itself.
local DepthSeam = {}

-- THE per-tier salvage-value multiplier for this blob, times today's restock bonus when the player's
-- CURRENT tier is today's restock tier. 1 = multiplicative identity (tier 1, no restock), so a fresh
-- player's income rate is exactly the base rate.
--
-- `nowUnix` is required by the contract signature SalvageService calls with, but it is treated as
-- OPTIONAL here: a caller with no clock still gets the tier multiplier, and the restock half simply
-- does not apply rather than throwing or guessing. It NEVER returns 0, NaN or a negative — Salvage
-- multiplies the whole game's income by this number.
function DepthSeam.valueMultiplier(_self: any, data: any, nowUnix: any): number
	local tier = DepthService:tierAt(DepthService:tierOf(data))
	local multiplier = tier.valueMultiplier
	if not isUsableNumber(multiplier) or multiplier <= 0 then
		multiplier = 1
	end

	local now = sanitizeNow(nowUnix)
	if now == nil then
		local context = DepthService._context
		if context ~= nil and context.clock ~= nil then
			local ok, value = pcall(function()
				return context.clock:unix()
			end)
			if ok then
				now = sanitizeNow(value)
			end
		end
	end
	if now ~= nil and DepthService:restockTierAt(now) == tier.index then
		multiplier *= RESTOCK_MULTIPLIER
	end
	return multiplier
end

-- The world Y at which this blob's CURRENT tier sits. PlotService reads it at claim time (first claim
-- AND every rejoin), so a returning player whose persisted tier is 4 finds their dome at tier 4's Y.
function DepthSeam.tierYFor(_self: any, data: any): number
	return DepthService:tierAt(DepthService:tierOf(data)).y
end

-- THE PRESSURE RATING this blob's hull is certified for. PURE over `upgrades.hull`, the canonical key
-- StructuresShopService writes — which is the whole point: the shop binds its `hull` entry's
-- observable to THIS method, so a hull plate is deliverable only while somebody outside the shop can
-- be seen reading what it buys. The gate below compares against this same function, so a level that
-- moves the rating measurably moves the gate's outcome.
function DepthSeam.hullRatingOf(_self: any, data: any): number
	return BASE_HULL_RATING + levelOf(data, HULL_UPGRADE_KEY) * HULL_RATING_PER_LEVEL
end

DepthService.seam = DepthSeam

-- ── the observation surface ─────────────────────────────────────────────────────────────────────

export type DepthInfo = {
	tier: number,
	label: string,
	y: number,
	-- The multiplier Salvage is applying RIGHT NOW (tier x restock), and the tier's own reading with
	-- the restock factored out, so the HUD can show the bonus as a bonus.
	valueMultiplier: number,
	tierValueMultiplier: number,
	maxTier: number,
	atMaxTier: boolean,
	-- The NEXT tier's requirements, all server-derived. nil-shaped fields are 0 at the bottom of the
	-- ladder, and `atMaxTier` is the field that says so — a client must never infer it from a 0.
	nextTier: number,
	nextLabel: string,
	nextCost: number,
	nextHullRequired: number,
	nextRequiresVip: boolean,
	-- What the player HAS, so the requirement panel can render "hull 4 (you have 2)" without holding
	-- a single constant of its own.
	hullRating: number,
	hullLevel: number,
	credits: number,
	vipUnlocked: boolean,
	-- The gate's verdict, precomputed the same way the transform computes it. ADVISORY ONLY: the
	-- authority is the transform, which re-evaluates every clause under the lock.
	hullMet: boolean,
	canAfford: boolean,
	vipMet: boolean,
	canDescend: boolean,
	-- Today's rich wreck.
	restockTier: number,
	restockLabel: string,
	restockMultiplier: number,
	restockActive: boolean, -- the player is STANDING in today's restock tier
	restockDayIndex: number,
	nowUnix: number,
}

-- PURE over the blob + the server clock. Side-effect free by construction: it writes nothing, grants
-- nothing and stamps nothing. `describe` runs on the LIVE session blob from OUTSIDE any
-- ctx.data:update, so it must never repair or normalize the record in place — that would be an
-- unlocked write on the single-writer path (CLAUDE.md §4) from a client-callable read action.
function DepthService.describe(self: any, data: any, nowUnix: number): DepthInfo
	local tierIndex = self:tierOf(data)
	local tier = self:tierAt(tierIndex)
	local atMax = tierIndex >= MAX_TIER
	local nextIndex = math.min(tierIndex + 1, MAX_TIER)
	local nextTier = self:tierAt(nextIndex)

	local hullRating = DepthSeam:hullRatingOf(data)
	local credits = 0
	if type(data) == "table" and type(data.currencies) == "table" then
		local balance = data.currencies[DESCEND_CURRENCY]
		if isUsableNumber(balance) then
			credits = balance
		end
	end
	local vipUnlocked = flagOf(data, VIP_TRENCH_FLAG)

	local nextRequiresVip = (not atMax) and nextTier.requiresFlag ~= nil
	local hullMet = (not atMax) and hullRating >= nextTier.hullMin
	local canAfford = (not atMax) and credits >= nextTier.cost
	local vipMet = (not nextRequiresVip) or vipUnlocked

	local restockTierIndex = self:restockTierAt(nowUnix)

	return {
		tier = tierIndex,
		label = tier.label,
		y = tier.y,
		valueMultiplier = DepthSeam:valueMultiplier(data, nowUnix),
		tierValueMultiplier = tier.valueMultiplier,
		maxTier = MAX_TIER,
		atMaxTier = atMax,
		nextTier = if atMax then tierIndex else nextIndex,
		nextLabel = if atMax then tier.label else nextTier.label,
		nextCost = if atMax then 0 else nextTier.cost,
		nextHullRequired = if atMax then 0 else nextTier.hullMin,
		nextRequiresVip = nextRequiresVip,
		hullRating = hullRating,
		hullLevel = levelOf(data, HULL_UPGRADE_KEY),
		credits = credits,
		vipUnlocked = vipUnlocked,
		hullMet = hullMet,
		canAfford = canAfford,
		vipMet = vipMet,
		canDescend = (not atMax) and hullMet and canAfford and vipMet,
		restockTier = restockTierIndex,
		restockLabel = self:tierAt(restockTierIndex).label,
		restockMultiplier = RESTOCK_MULTIPLIER,
		restockActive = restockTierIndex == tierIndex,
		restockDayIndex = self:dayIndexAt(nowUnix),
		nowUnix = nowUnix,
	}
end

function DepthService.fetch(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "depth: context is missing data/clock")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(Result.Codes.Internal, "depth: the server clock returned no usable time")
	end
	local got = ctx.data:get(ctx.player)
	if not got.ok then
		-- NoData until loadSession resolves; the client's JoinRetry guard re-issues past it.
		return got
	end
	return Result.ok(self:describe(got.value, now :: number))
end

-- ── THE DESCENT ─────────────────────────────────────────────────────────────────────────────────

export type DescendInfo = {
	tier: number, -- the tier now unlocked and occupied
	label: string,
	previousTier: number,
	cost: number,
	balance: number, -- the post-debit Credits balance, as EconomyService computed it
	hullRating: number,
	hullRequired: number,
	-- The DELTA on the number that actually matters. A purchase is asserted by a delta on the running
	-- reading, never by a persisted field changing (docs/LEARNINGS.md, "written-never-read").
	valueMultiplier: number,
	previousValueMultiplier: number,
	y: number,
	previousY: number,
	moved: boolean, -- whether an actual dome root was re-pivoted (false under Lune / no dome yet)
	loopCompleted: boolean, -- whether THIS descend emitted loop_completed
	restockActive: boolean,
}

-- THE descend. Every refusal and the debit are decided on ONE lock-held snapshot; see THE GATE and
-- THE CONCURRENCY ARGUMENT in the header.
function DepthService.descend(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "depth: context is missing data/clock")
	end
	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "depth: player has no numeric UserId")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(Result.Codes.Internal, "depth: the server clock returned no usable time")
	end
	local nowUnix = now :: number

	-- The session epoch of the snapshot this descend commits against. Read INSIDE the transform (see
	-- below) and consulted after the write to decide loop_completed. Declared here rather than carried
	-- on DescendInfo, which is a client-facing reply.
	local sessionEpoch = 0

	local economy = ctx.economy
	if economy == nil or type(economy.spend) ~= "function" then
		-- ctx.economy is the ENFORCEMENT POINT for the spend path: it is what emits currency_spent and
		-- what refuses a debit that would take a balance negative. Debiting around it would be a
		-- direct, unaudited write of data.currencies, so an absent seam is a refusal — never a
		-- fall-through.
		return Result.err(
			Result.Codes.Internal,
			"depth: ctx.economy is not installed — debiting here would skip the balance guard and the "
				.. "currency_spent event"
		)
	end

	-- (2) RESERVE, synchronously, before anything below can yield. A spam-duplicated descend that
	-- arrives while the first is parked in the store lands here and is refused WITHOUT reaching the
	-- data layer. PrereqUnmet, not RateLimited (that is the Gate's anti-spam bucket) and not
	-- Insufficient (the balance is not the problem): the prerequisite that is unmet is that the
	-- previous descend has not landed yet, and the tier this request would target does not exist as a
	-- decided fact.
	if self._descending[userId] then
		return Result.err(
			Result.Codes.PrereqUnmet,
			"depth: a descend for this player is already in flight — the trench is being entered"
		)
	end
	self._descending[userId] = true

	local outcome: any = nil

	-- (1) THE ONE LOCK-HELD TRANSFORM. Synchronous by construction: it contains no yield of any kind,
	-- so every clause below reads the SAME snapshot the debit is applied to.
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "depth: data blob is not a table")
			return data
		end

		-- WHICH SESSION this snapshot belongs to, read off the SAME lock-held blob every clause below
		-- reads. Only consulted on the success path, after the write commits.
		sessionEpoch = epochOf(data)

		-- (a) STRICTLY SEQUENTIAL, BY CONSTRUCTION. The target is derived from the snapshot; there is
		-- no tier index on this path for a client to supply and no purchase order that can skip a rung.
		local currentIndex = self:tierOf(data)
		if currentIndex >= MAX_TIER then
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`depth: already at the deepest trench ({self:tierAt(currentIndex).label}, tier {MAX_TIER})`
			)
			return data
		end
		local nextIndex = currentIndex + 1
		local nextTier = self:tierAt(nextIndex)
		local previousMultiplier = DepthSeam:valueMultiplier(data, nowUnix)

		-- (b) THE VIP TRENCH's flag. Read straight off the blob — Monetization only ever SETS it.
		if nextTier.requiresFlag ~= nil and not flagOf(data, nextTier.requiresFlag :: string) then
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`depth: {nextTier.label} is an exclusive trench — it needs the VIP trench pass`
			)
			return data
		end

		-- (c) THE PRESSURE GATE. Read through the SAME seam method StructuresShopService measures its
		-- `hull` entry with, so a hull plate the player just bought moves this comparison.
		local hullRating = DepthSeam:hullRatingOf(data)
		if hullRating < nextTier.hullMin then
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`depth: {nextTier.label} needs hull rating {nextTier.hullMin}; this hull is rated `
					.. `{hullRating}. Depth cannot be bought with Credits alone`
			)
			return data
		end

		-- (d) THE CREDITS. WRITE THE TIER FIRST, DEBIT LAST — the debit has to be the transform's final
		-- mutation, because EconomyService emits currency_spent as its last act and nothing after it
		-- may throw and discard a snapshot the event already described.
		local upgrades = data.upgrades
		if type(upgrades) ~= "table" then
			upgrades = {}
			data.upgrades = upgrades
		end
		local previousValue = upgrades[DEPTH_UPGRADE_KEY]
		upgrades[DEPTH_UPGRADE_KEY] = nextIndex

		local spent = economy:spend(data, DESCEND_CURRENCY, nextTier.cost, `depth.{nextIndex}`)
		if not spent.ok then
			-- (3) ROLL THE TIER BACK to exactly what this snapshot held — including nil, which restores
			-- ABSENCE. `spend` is atomic-or-nothing, so the balance was untouched; this makes the
			-- transaction atomic on OUR side rather than assuming it of the seam.
			upgrades[DEPTH_UPGRADE_KEY] = previousValue
			outcome = spent
			return data
		end

		local info: DescendInfo = {
			tier = nextIndex,
			label = nextTier.label,
			previousTier = currentIndex,
			cost = nextTier.cost,
			balance = spent.value.balance,
			hullRating = hullRating,
			hullRequired = nextTier.hullMin,
			valueMultiplier = DepthSeam:valueMultiplier(data, nowUnix),
			previousValueMultiplier = previousMultiplier,
			y = nextTier.y,
			previousY = self:tierAt(currentIndex).y,
			moved = false, -- filled in after the write is durable; the world follows the fact
			loopCompleted = false,
			restockActive = self:restockTierAt(nowUnix) == nextIndex,
		}
		outcome = Result.ok(info)
		return data
	end

	-- pcall'd ONLY so the reservation is released on every path: DataService:update already pcalls the
	-- transform, so a throw here would have to come from the data layer itself — and a reservation
	-- stranded `true` would lock this player out of the trench for the life of the server.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	self._descending[userId] = nil

	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "depth: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, or a transform that
		-- threw. The snapshot was discarded either way, so NOTHING was persisted: no tier was written,
		-- no Credits were debited, and the Err is surfaced as-is rather than dressed up as a descend.
		return written
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"depth: the update reported success but the transform produced no outcome"
		)
	end
	if not outcome.ok then
		return outcome
	end

	local info: DescendInfo = outcome.value

	-- ── EVERYTHING BELOW IS DERIVED FROM A COMMITTED WRITE, COMES AFTER IT, AND CAN NEVER UNDO IT.
	-- Each step is guarded and its failure discarded: an unguarded post-write side effect is how a
	-- committed economy write once came back to the client as Err(Internal) (docs/LEARNINGS.md).

	-- loop_completed on the FIRST successful descend of this session. The check and the set are ONE
	-- synchronous pair with no yield between them, so two descends cannot both observe "not yet".
	--
	-- KEYED BY THE SESSION EPOCH, NOT BY "have we ever". A boolean here meant "this userId emitted at
	-- some point on this server", which is a different claim from the contract's ("the FIRST
	-- successful descend of a SESSION") the moment a player rejoins the same server: the only thing
	-- that cleared the entry was pruneSessions, a 60-second sweep over Players that skips a player who
	-- is present again — and it never runs at all where startRuntime returns early. The comparison
	-- below decides the session boundary from a PERSISTED per-session identity on the lock-held
	-- snapshot, so it needs no leave signal (framework/PlayerLifecycle owns PlayerRemoving and its
	-- pinned order) and no poll, and it reads the same under Lune as in a live server.
	if self._loopCompleted[userId] ~= sessionEpoch then
		self._loopCompleted[userId] = sessionEpoch
		info.loopCompleted = true
		self:emit(ctx, "loop_completed", {
			userId = userId,
			step = Net.Actions.Descend,
			loop = "join -> plot -> drone -> smelt -> descend",
			tier = info.tier,
			valueMultiplier = info.valueMultiplier,
		})
	end

	-- progression, carrying the NEW tier index.
	self:emit(ctx, "progression", {
		userId = userId,
		kind = "depth",
		tier = info.tier,
		previousTier = info.previousTier,
		label = info.label,
		cost = info.cost,
		hullRating = info.hullRating,
		valueMultiplier = info.valueMultiplier,
		previousValueMultiplier = info.previousValueMultiplier,
	})

	-- THE VISIBLE DESCENT. Cosmetic-follows-state: `upgrades.depth` is the authoritative fact and is
	-- already durable; the world position is derived from it here.
	info.moved = self:moveRoot(ctx, player, info.y)

	self:pushView(self._context, player)

	return Result.ok(info)
end

-- Nil-safe analytics emit (ctx.analytics:emit(event, payload)). An unwired seam is a no-op, and a
-- throwing emitter must never turn a committed descend into an error.
function DepthService.emit(_self: any, ctx: any, event: string, payload: any): boolean
	local analytics = if ctx ~= nil then ctx.analytics else nil
	if analytics == nil or type(analytics.emit) ~= "function" then
		return false
	end
	local ok = pcall(function()
		analytics:emit(event, payload)
	end)
	return ok
end

-- Move this player's dome root to `tierY`, PRESERVING its X/Z. PlotService owns the ring layout (and
-- therefore X/Z); this service owns only the Y, so the pivot is read and one component replaced
-- rather than the ring math being duplicated here and left to drift. Returns whether an instance was
-- actually moved (false under Lune, or before the player holds a dome).
function DepthService.moveRoot(_self: any, ctx: any, player: any, tierY: number): boolean
	local plot = if ctx ~= nil then ctx.plot else nil
	if plot == nil or type(plot.rootFor) ~= "function" then
		return false
	end
	local cframeGlobal: any = CFrame
	if cframeGlobal == nil then
		return false -- Lune: no engine to move anything in
	end
	local ok, moved = pcall(function(): boolean
		local root = plot:rootFor(player)
		if root == nil then
			return false
		end
		local position = root:GetPivot().Position
		root:PivotTo(cframeGlobal.new(position.X, tierY, position.Z))
		return true
	end)
	return ok and moved == true
end

-- Push the refreshed client view after a committed descend. `context` is the SERVER context (the
-- ActionContext projection carries no net). DataService pushes the view once, on load — which is long
-- before this descend — so without this the HUD's `view.upgrades.depth` would describe the tier the
-- player joined at until the next unrelated write. Guarded + pcall'd; the return value is ignored.
function DepthService.pushView(_self: any, context: any, player: any): boolean
	if context == nil then
		return false
	end
	local net = context.net
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

-- ── the actions ─────────────────────────────────────────────────────────────────────────────────

-- BOTH payloads carry NOTHING BY CONTRACT — no tier, no cost, no hull rating, no timestamp, no day.
-- A payload that names one is REFUSED rather than ignored: an ignored forgery is byte-identical to a
-- well-formed request, and the difference is the only signal that somebody is probing the gate. The
-- validator hands the handler a FRESH EMPTY TABLE, so the handler is not merely disciplined about
-- ignoring client data — it is never handed any. THIS IS THE depth-gate-bypass defence: there is no
-- client number anywhere on this path to trust, and the target tier is arithmetic on a lock-held
-- snapshot.
local FORBIDDEN_PAYLOAD_KEYS = {
	"tier",
	"depth",
	"nextTier",
	"targetTier",
	"level",
	"cost",
	"price",
	"credits",
	"Credits",
	"currency",
	"amount",
	"balance",
	"hull",
	"hullRating",
	"multiplier",
	"valueMultiplier",
	"restock",
	"restockTier",
	"day",
	"dayIndex",
	"now",
	"nowUnix",
	"time",
	"timestamp",
	"unix",
	"serverTime",
	"clientTime",
	"y",
	"userId",
	"plotId",
	"flags",
	"vip",
	"force",
}

local function validateNoArguments(rawPayload: any): any
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
				`depth actions take no arguments — the SERVER derives the next tier, its price and `
					.. `every requirement (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

DepthService.validate = validateNoArguments

-- Exported so a Tier-1 spec can register the actions on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as CLOSURES over the service because the single-flight
-- reservation table and the per-session loop_completed set ARE service state, which a static-module
-- registration cannot reach.
function DepthService.descendAction(self: any): any
	return {
		name = Net.Actions.Descend,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB: a descend is a rare, expensive progression step, so
		-- the bucket is tight — a spam burst is refused by the Gate before it ever reaches the
		-- economy's single-writer path.
		rate = { maxPerWindow = 3, windowSeconds = 5.0 },
		handler = function(ctx: any, _payload: any): any
			return self:descend(ctx)
		end,
	}
end

function DepthService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchDepth,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB.
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		-- SIDE-EFFECT FREE: fetch never descends, never debits, never writes and never stamps. A read
		-- surface that could mutate would make the tier depend on how often the UI refreshed.
		handler = function(ctx: any, _payload: any): any
			return self:fetch(ctx)
		end,
	}
end

-- ── the world (greybox) ─────────────────────────────────────────────────────────────────────────
-- ROBLOX-ONLY, every entry point guarded. Art posture: "trench tiers = stacked Part shells at
-- descending Y." COSMETIC ONLY — nothing built here is read back by any rule, so a client that
-- deleted, froze or teleported every one of these Parts would change no number on the server.

local TRENCH_FOLDER_NAME = "DeepReachTrenches"
local WRECK_NAME = "RichWreck"
-- Wide enough to sit under PlotService's whole dome ring (radius ~183 studs for a 12-dome server plus
-- a 64-stud pad), so every plot on every tier has a floor rather than a void.
local SHELL_SPAN_STUDS = 640
local SHELL_THICKNESS_STUDS = 4
-- The shell's TOP surface must meet the bottom of a dome pad parked at the tier's Y. PlotService's
-- pad is 2 studs thick and pivots at the tier Y, so its underside is `y - 1`.
local SHELL_TOP_GAP_STUDS = 1
local WRECK_SIZE_STUDS = 14

local function robloxRefs(): (any, any, any, any)
	local instanceGlobal: any = Instance
	local vector3Global: any = Vector3
	local color3Global: any = Color3
	local enumGlobal: any = Enum
	return instanceGlobal, vector3Global, color3Global, enumGlobal
end

-- Progressively darker, colder shells with depth: the tier ladder should be readable as a gradient
-- from across the map, before any label is legible.
local function shellColorFor(color3Global: any, index: number): any
	local t = (index - 1) / math.max(1, MAX_TIER - 1)
	local shade = math.floor(70 - 52 * t)
	return color3Global.fromRGB(shade, math.floor(shade * 1.25), math.floor(shade * 1.6))
end

-- One trench shell: a wide anchored slab at the tier's Y, plus a neon rim so the tier boundary reads
-- as a boundary. Idempotent by name — a shell that already exists is left alone.
function DepthService.buildShell(_self: any, folder: any, tier: Tier): any
	local instanceGlobal, vector3Global, color3Global, enumGlobal = robloxRefs()
	-- CFrame is guarded alongside the rest: this function is exported, so a spec may call it directly
	-- and every Roblox global it touches has to be nil-checked in ONE place rather than most of them.
	local cframeGlobal: any = CFrame
	if
		instanceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
		or cframeGlobal == nil
		or folder == nil
	then
		return nil
	end
	local name = `Trench{tier.index}`
	local existing = folder:FindFirstChild(name)
	if existing ~= nil then
		return existing
	end

	local model = instanceGlobal.new("Model")
	model.Name = name

	local slab = instanceGlobal.new("Part")
	slab.Name = "Floor"
	slab.Anchored = true
	slab.Size = vector3Global.new(SHELL_SPAN_STUDS, SHELL_THICKNESS_STUDS, SHELL_SPAN_STUDS)
	slab.Position =
		vector3Global.new(0, tier.y - SHELL_TOP_GAP_STUDS - SHELL_THICKNESS_STUDS / 2, 0)
	slab.Color = shellColorFor(color3Global, tier.index)
	slab.Material = enumGlobal.Material.Slate
	slab.TopSurface = enumGlobal.SurfaceType.Smooth
	slab.BottomSurface = enumGlobal.SurfaceType.Smooth
	slab.Parent = model

	local rim = instanceGlobal.new("Part")
	rim.Name = "Rim"
	rim.Anchored = true
	rim.CanCollide = false
	rim.Shape = enumGlobal.PartType.Cylinder
	-- A cylinder's length runs along X, so it is laid flat by rotating it a quarter turn about Z.
	rim.Size = vector3Global.new(2, SHELL_SPAN_STUDS * 0.62, SHELL_SPAN_STUDS * 0.62)
	rim.CFrame = cframeGlobal.new(0, tier.y + 1, 0) * cframeGlobal.Angles(0, 0, math.rad(90))
	rim.Color = color3Global.fromRGB(64, 226, 255)
	rim.Material = enumGlobal.Material.Neon
	rim.Transparency = 0.75
	rim.Parent = model

	model.PrimaryPart = slab
	model.Parent = folder
	return model
end

-- Find-or-create the trench folder and every shell. IDEMPOTENT.
function DepthService.buildWorld(self: any): boolean
	local instanceGlobal = Instance :: any
	local workspaceGlobal: any = workspace
	if instanceGlobal == nil or workspaceGlobal == nil then
		return false -- Lune: no engine to build in
	end
	local folder = workspaceGlobal:FindFirstChild(TRENCH_FOLDER_NAME)
	if folder == nil then
		folder = instanceGlobal.new("Folder")
		folder.Name = TRENCH_FOLDER_NAME
		folder.Parent = workspaceGlobal
	end
	self._trenchFolder = folder
	for _, tier in TIERS do
		self:buildShell(folder, tier)
	end
	return true
end

-- AMENDMENT A7: THE RICH WRECK IS A REAL OBJECT. Place (or re-place) it for the day `nowUnix` falls
-- in. Returns true when the wreck was actually (re)placed on this call — i.e. when the day rolled
-- over — so the caller can log a rollover it did not otherwise observe.
--
-- The wreck is DESTROYED AND REBUILT rather than nudged, because "the wreck resets each day" has to
-- be observable as the object itself changing, not as a Part that quietly slid: an old wreck left
-- behind in yesterday's tier would keep advertising a bonus that is no longer there.
function DepthService.syncWreck(self: any, nowUnix: any): boolean
	local placement = self:wreckPlacementAt(nowUnix)
	if self._wreck ~= nil and self._wreckDay == placement.dayIndex then
		return false
	end

	local instanceGlobal, vector3Global, color3Global, enumGlobal = robloxRefs()
	if
		instanceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
	then
		-- Lune: there is no Part to move. The PLACEMENT is still a pure fact a spec can assert; the
		-- day stamp is deliberately NOT advanced here, so a later call in a real runtime still builds.
		return false
	end
	local folder = self._trenchFolder
	if folder == nil then
		return false
	end

	if self._wreck ~= nil then
		pcall(function()
			self._wreck:Destroy()
		end)
		self._wreck = nil
	end
	-- Also clear a wreck left by a previous Start (a re-Start in the same session), so the folder can
	-- never hold two.
	local stale = folder:FindFirstChild(WRECK_NAME)
	if stale ~= nil then
		pcall(function()
			stale:Destroy()
		end)
	end

	local wreck = instanceGlobal.new("Part")
	wreck.Name = WRECK_NAME
	wreck.Anchored = true
	wreck.CanCollide = false
	wreck.Size = vector3Global.new(WRECK_SIZE_STUDS, WRECK_SIZE_STUDS * 0.6, WRECK_SIZE_STUDS * 1.8)
	wreck.Position = vector3Global.new(placement.x, placement.y, placement.z)
	wreck.Color = color3Global.fromRGB(255, 206, 92)
	wreck.Material = enumGlobal.Material.Neon
	wreck.Parent = folder

	local glow = instanceGlobal.new("PointLight")
	glow.Name = "WreckLight"
	glow.Color = color3Global.fromRGB(255, 206, 92)
	glow.Range = 60
	glow.Brightness = 3
	glow.Parent = wreck

	self._wreck = wreck
	self._wreckDay = placement.dayIndex
	return true
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable.
function DepthService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- How often the day-rollover watcher wakes. A whole day is 86400s; checking every minute makes the
-- wreck reset within a minute of midnight, which is far tighter than a player can perceive and costs
-- one comparison a minute.
local RESTOCK_CHECK_SECONDS = 60
DepthService.RESTOCK_CHECK_SECONDS = RESTOCK_CHECK_SECONDS

-- Start: install the seam, register the wire surface, then (Roblox only) build the greybox and start
-- the day watcher. The seam assignment is deliberately FIRST — the ActionContext projection reads
-- ctx.depth at DISPATCH time, and PlotService/SalvageService/StructuresShopService may consult it
-- during their own Start. Lune-callable: everything engine-shaped lives behind startRuntime.
function DepthService.Start(self: any, context: any): ()
	context.depth = DepthSeam
	self._context = context
	self._descending = {}
	self._loopCompleted = {}
	context.net:register(self:descendAction())
	context.net:register(self:fetchAction())
	self:startRuntime(context)
end

function DepthService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	if realGame == nil then
		return -- Lune: no engine to wire. Specs drive descend / fetch / the seam directly.
	end
	self._connections = {}
	self:buildWorld()

	local clock = context.clock
	self:syncWreck(if clock ~= nil then clock:unix() else 0)

	self._running = true
	-- ONE watcher for the whole server (never one per player): the restock is a SERVER-day fact, not a
	-- per-player one. It also prunes the per-session loop_completed set against the live roster, so
	-- per-server memory cannot grow once per join for the life of the server. Doing it here rather
	-- than from a second PlayerRemoving connection keeps the pinned leave sequence owned by
	-- framework/PlayerLifecycle, which is the only thing allowed to connect that signal.
	task.spawn(function()
		while self._running do
			pcall(function()
				self:syncWreck(if clock ~= nil then clock:unix() else 0)
				self:pruneSessions(realGame)
			end)
			if not self._running then
				break
			end
			self:_wait(RESTOCK_CHECK_SECONDS)
		end
	end)
end

-- Drop per-session bookkeeping for players who have left. Guarded: a Players failure must never kill
-- the restock watcher that runs in the same loop.
function DepthService.pruneSessions(self: any, realGame: any): ()
	if realGame == nil then
		return
	end
	local ok, present = pcall(function()
		local live: { [number]: boolean } = {}
		for _, player in realGame:GetService("Players"):GetPlayers() do
			local userId = userIdOf(player)
			if userId ~= nil then
				live[userId] = true
			end
		end
		return live
	end)
	if not ok or type(present) ~= "table" then
		return
	end
	for userId in self._loopCompleted do
		if not present[userId] then
			self._loopCompleted[userId] = nil
			self._descending[userId] = nil
		end
	end
end

function DepthService.Stop(self: any, _context: any): ()
	self._running = false
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
end

return DepthService
