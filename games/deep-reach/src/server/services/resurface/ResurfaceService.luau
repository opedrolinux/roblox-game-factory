--!strict
-- games/deep-reach/src/server/services/resurface/ResurfaceService.luau   [feature: resurface/prestige]
--
-- THE authoritative owner of the prestige: the minimum-depth requirement, the Pearl mint, the
-- ONE-TRANSFORM wipe, the permanent multiplier's COUNT, and the server-truthed confirm preview.
-- Replaces the contract-pass stub in place, preserving every contract decision the stub pinned: the
-- two action names (Net.Actions.Resurface / Net.Actions.FetchResurface), their RatePolicies
-- ({2, 10.0s} — the tightest bucket in the game, because this is the most destructive action and the
-- one a duplicate could dupe Pearls through — and {10, 1.0s}), and closure-based registration.
--
-- This service installs NO ctx seam (contract.stubs.resurface.seamProvided is null). It publishes
-- nothing for another service to read, because the ONE thing this feature produces for the rest of
-- the game — the permanent multiplier — is already read off the blob by SalvageService.
--
-- ── THE MULTIPLIER IS NOT IMPLEMENTED HERE, AND THAT IS THE POINT ───────────────────────────────
-- SalvageService.multiplierAt ALREADY reads `data.resurfaces` at a documented +10% per resurface
-- (SalvageService.luau:168-170, :427-432), and it deliberately reads the COUNT rather than
-- currencies.Pearls (the currency is spent down, which would make the multiplier SHRINK when it is
-- used). So incrementing `resurfaces` lands the permanent multiplier with ZERO edit to salvage, and
-- re-deriving the +10% here would be a second copy of a live constant, drifting silently.
--
-- What this file therefore must NOT do is ship that multiplier INERT (the written-never-read pattern
-- this game is graded against). It does not merely trust the wiring — it MEASURES it, and hands the
-- measurement to the client and to any test:
--     `prestigeMultiplierAt(salvage, count)` = ctx.salvage:rateFor({resurfaces = count})
--                                            / ctx.salvage:rateFor({resurfaces = 0})
-- Two readings of THE running rate function on two otherwise-identical synthetic blobs. Every other
-- input (drones, conveyor, flags, boost, depth) is equal on both and cancels, so the ratio IS the
-- prestige multiplier — derived from the live formula rather than restated from a constant. If the
-- ratio ever stops moving, `multiplierMeasured` / the preview's numbers stop moving with it, and the
-- feature fails loudly instead of quietly. `rateBefore` / `rateAfter` on the reply are the same
-- reading taken on the REAL blob either side of the transform.
--
-- ── WHAT SURVIVES A RESURFACE. THE THING THIS FEATURE IS MOST LIKELY TO GET SILENTLY WRONG ──────
-- SURVIVES, UNTOUCHED — this file never writes any of them:
--     resurfaces (INCREMENTED, never reset)   currencies.Pearls (the mint ADDS to it)
--     upgrades.pearlDrones — Pearl purchases are permanent; that is what makes a prestige currency
--         worth spending, and StructuresShopService sells the entry on exactly that promise.
--     stats.lifetimeCredits — LOAD-BEARING: it is the leaderboard's ranking key, so resetting it
--         would rank prestiged players LAST. The Credits reset below is a RESET, not a spend, so it
--         deliberately does NOT go through ctx.economy (spend would refuse it anyway, and neither
--         earn nor spend may move lifetime on a reset).
--     daily · plot · flags · receipts · timestamps · schemaVersion · analytics
--     boostExpiresUnix — AMENDMENT A6. It is the expiry of a 30-minute 2x boost bought with REAL
--         MONEY, and a voluntary prestige confiscating paid time the player has not spent is a refund
--         request, not a game mechanic. It also keeps multiplying: `rateAfter` is measured on the
--         post-wipe snapshot, so a live boost is still in that number.
-- WIPED:
--     currencies.Credits    -> 0
--     upgrades.drones / conveyor / smelter / hull -> 0
--     upgrades.depth        -> the LITERAL 1
--     smelter.storedCredits -> 0
-- The four structure levels are set to 0 rather than deleted. Server-side the two are identical
-- (every reader normalizes an absent key to 0), but `Types.toView` copies `data.upgrades` WHOLESALE,
-- and StructuresController's view handler only overwrites a row's level when the key is a number —
-- so a DELETED key leaves the shop rendering the pre-prestige levels until its next poll. A wipe the
-- player can still see is a wipe that did not happen as far as they are concerned.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The dupe this feature is one mistake away from is the worst in the game: check the depth
-- requirement, YIELD in ctx.data:update, then mint Pearls and wipe. Two resurfaces in the same frame
-- both pass the check against the same pre-wipe snapshot, and the player is paid TWICE for one run —
-- a named success-criterion failure. Three mechanisms close it, and they fail in different
-- directions:
--
--   (1) THE CHECK, THE MINT AND THE WIPE ARE ONE LOCK-HELD TRANSFORM. Nothing outside `transform`
--       reads the tier, computes the Pearls or writes a byte on a resurface path. DataService:update
--       runs the transform under the per-player FIFO lock against a snapshot RE-READ after any
--       earlier update has written, and the transform is synchronous — it contains no yield of any
--       kind. THE WIPE IS ITSELF THE IDEMPOTENCY GUARD: it sets `upgrades.depth` to 1, and the
--       requirement is tier >= MIN_RESURFACE_TIER (5), so the SECOND resurface's transform
--       necessarily observes tier 1 and returns Err(PrereqUnmet). n spam-duplicated resurfaces mint
--       EXACTLY ONE batch of Pearls. This is the load-bearing guarantee; it holds even if (2) is
--       deleted. It is also why the Pearl amount is computed INSIDE the transform: a number derived
--       before the yield would be the stale one, and paying it out IS the dupe.
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION taken BEFORE the update can yield
--       (`self._resurfacing`, the same reserve-before-yield discipline SalvageService uses for the
--       smelter and DepthService for a descend). Luau is single-threaded, so the flag is visible to
--       every interleaved request the instant it is set, and a duplicate that arrives while the first
--       is parked in the store is refused with Err(PrereqUnmet) — the same code the tier-1 blob it is
--       racing toward would give it — without ever reaching the data layer. Never RateLimited: that
--       code belongs to the Gate's anti-spam bucket, and conflating the two makes "exactly one batch
--       of Pearls" untestable. Belt-and-braces for (1), never a substitute: it is per-SERVER memory
--       and says nothing about the same player on another server.
--   (3) THE WIPE IS ROLLED BACK, BYTE-FOR-BYTE, IF THE MINT REFUSES. The transform wipes FIRST and
--       calls `ctx.economy:earn` LAST, because earn emits currency_earned as its final act and no
--       later statement in a transform may throw and discard a snapshot the event already described.
--       A refused mint restores every value this snapshot held — INCLUDING absence, since a captured
--       `nil` written back restores a missing key — and returns the Err. `earn` is atomic-or-nothing
--       as of the current commit, so "not ok" means no balance moved; the rollback makes THIS
--       transaction atomic on its OWN side rather than assuming it of the seam (the salvage gate
--       caught exactly that assumption as a mint). And if the WRITE fails, the store discards the
--       whole snapshot: nothing was wiped or minted durably, and there is nothing to compensate.
--
-- EVERY REFUSAL IS DECIDED BEFORE THE FIRST MUTATION (EconomyService's own lesson): a blob with no
-- `currencies` table is refused up front rather than discovered halfway through a wipe.
--
-- ── THE FETCH IS STRICTLY SIDE-EFFECT FREE ──────────────────────────────────────────────────────
-- `resurface.fetch` writes nothing, stamps nothing, grants nothing and normalizes nothing IN PLACE.
-- It runs on the LIVE session blob from OUTSIDE any ctx.data:update, so an in-place repair there
-- would be an unlocked write on the single-writer path (§4) from a client-callable read action. Its
-- post-resurface numbers are computed on a DEEP COPY (`simulate`), which is also what makes the
-- preview honest: the copy is wiped by the SAME `applyWipe` the real transform uses, so the previewed
-- rate cannot drift from the rate the player actually lands on.
--
-- NOT THIS SLICE: the Pearl-only drone catalog entry or its price (StructuresShopService sells it and
-- prices it in Pearls); the depth tier table, the pressure gate or the restock (DepthService — this
-- file only RESETS `upgrades.depth` to 1); the income tick and the rate formula (SalvageService reads
-- `data.resurfaces` itself); `loop_completed` (DepthService owns that emit point — emitting it here
-- too would double-count the core-loop funnel).
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- Every decision in this file is Roblox-FREE: tierOf / pearlsFor / prestigeMultiplierAt / captureWipe
-- / applyWipe / restoreWipe / simulate / describe / fetch / resurface / validateNoArguments and both
-- action factories run under Lune with Mocks.player + a real DataService over MockStore and no engine
-- at all. Only `pushView` touches a Roblox-shaped seam, and it is guarded and pcall'd.
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

local ResurfaceService = {}
ResurfaceService.name = "ResurfaceService"

-- ── the persisted keys (canonical; the same strings the services that OWN them use) ─────────────

-- The prestige currency. Minted ONLY here, and ONLY through ctx.economy:earn — which BRANCHES on
-- currency, so a Pearls mint correctly does not touch stats.lifetimeCredits (that counter is Credits
-- only). Spent by StructuresShopService's `pearlDrones` entry.
local PEARL_CURRENCY = "Pearls"
-- The soft currency the reset zeroes. Written DIRECTLY, never through ctx.economy:spend — see
-- THE RESET IS NOT A SPEND below.
local CREDIT_CURRENCY = "Credits"
-- The earn-path label carried on currency_earned. Never used for math.
local EARN_SOURCE = "resurface"

-- The structure levels a resurface clears. These are SalvageService.UPGRADE_KEYS minus pearlDrones,
-- plus DepthService's `hull` — i.e. everything the Credits economy bought.
local WIPED_UPGRADE_KEYS: { string } = { "drones", "conveyor", "smelter", "hull" }
-- The upgrade key that SURVIVES. Listed as data (not only in prose) so the preview can say so and a
-- test can read the promise off the module instead of off a comment.
local SURVIVING_UPGRADE_KEYS: { string } = { "pearlDrones" }
-- DepthService's key. Reset to the LITERAL FIRST_DEPTH_TIER, never a sentinel — see tierOf.
local DEPTH_UPGRADE_KEY = "depth"

ResurfaceService.PEARL_CURRENCY = PEARL_CURRENCY
ResurfaceService.CREDIT_CURRENCY = CREDIT_CURRENCY
ResurfaceService.EARN_SOURCE = EARN_SOURCE
ResurfaceService.WIPED_UPGRADE_KEYS = WIPED_UPGRADE_KEYS
ResurfaceService.SURVIVING_UPGRADE_KEYS = SURVIVING_UPGRADE_KEYS
ResurfaceService.DEPTH_UPGRADE_KEY = DEPTH_UPGRADE_KEY

-- ── THE DEPTH REQUIREMENT ───────────────────────────────────────────────────────────────────────
-- Spec, verbatim: "Long game: 5 depth tiers, then resurface". So the requirement is the BOTTOM of
-- the five-tier trench ladder, and reaching it is the whole run.
--
-- CONTRACT COUPLING, stated out loud because it is a duplicated constant. DepthService OWNS the
-- ladder (its TIERS array: five trench tiers plus the paywalled VIP trench at index 6, MAX_TIER = 6,
-- FIRST_TIER = 1). A service never sibling-requires another service, and the ctx.depth seam publishes
-- exactly three methods — valueMultiplier / tierYFor / hullRatingOf — none of which returns a tier
-- INDEX. So the ladder's bounds are mirrored here, and `tierOf` below reproduces DepthService.tierOf
-- EXACTLY, degrade rule included. If the ladder ever grows a seventh tier, this ceiling must move
-- with it (a player standing on the new tier would otherwise read as tier 1 and be refused).
local FIRST_DEPTH_TIER = 1
local DEPTH_TIER_CEILING = 6
local MIN_RESURFACE_TIER = 5

ResurfaceService.FIRST_DEPTH_TIER = FIRST_DEPTH_TIER
ResurfaceService.DEPTH_TIER_CEILING = DEPTH_TIER_CEILING
ResurfaceService.MIN_RESURFACE_TIER = MIN_RESURFACE_TIER

-- ── THE PEARL FORMULA (server-derived; no client number reaches it) ─────────────────────────────
-- Pearls scale with the SQUARE ROOT of stats.lifetimeCredits — the standard prestige curve: strongly
-- diminishing, so a player cannot farm one long run into an unbounded prestige, and monotone, so more
-- progress is never worth fewer Pearls.
--
-- WHY LIFETIME AND NOT "CREDITS SINCE THE LAST RESURFACE": a since-last counter would need a NEW
-- PERSISTED FIELD, and src/shared is read-only to feature work (CLAUDE.md) — that is a contract
-- amendment, not a feature decision. It is also not needed: the depth requirement already forces a
-- fresh run between mints. `upgrades.depth` is reset to 1 by this very transform, so the next
-- resurface cannot happen until the player has re-descended the whole ladder, which costs
-- 1,500 + 12,000 + 80,000 + 500,000 = 593,500 Credits of NEW earnings. lifetimeCredits therefore
-- cannot repeat, and neither can a Pearl payout.
--
-- The divisor sets the scale: a first resurface at ~600k lifetime Credits mints
-- floor(sqrt(600000 / 1000)) = 24 Pearls, which buys the first several `pearlDrones` levels (base 1,
-- growth 1.6) — a prestige worth doing on the first attempt rather than on the fifth.
local PEARL_CREDIT_DIVISOR = 1000
-- Descending PAST the minimum is worth Pearls of its own: +25% per tier above MIN_RESURFACE_TIER, so
-- the VIP trench (tier 6) pays 1.25x. Clamped at 0 below the minimum, so the preview a player sees at
-- tier 1 is the honest sqrt reading rather than a shrunken one for a resurface they cannot do anyway.
local PEARL_TIER_BONUS = 0.25
-- THE FLOOR IS LOAD-BEARING, NOT COSMETIC. ctx.economy:earn REFUSES an amount <= 0 (OutOfRange), so a
-- computed 0 would make the whole resurface fail — the player's structures preserved, but the action
-- permanently broken for a blob whose lifetimeCredits is garbage or below the divisor. A resurface
-- that is allowed always mints at least one Pearl.
local MIN_PEARLS = 1
-- The outer wall. A lifetimeCredits read off a DataStore is data, not a fact; without a ceiling a
-- poisoned 1e308 would mint an unspendable, un-displayable balance and persist it.
local MAX_PEARLS = 1000000000

ResurfaceService.PEARL_CREDIT_DIVISOR = PEARL_CREDIT_DIVISOR
ResurfaceService.PEARL_TIER_BONUS = PEARL_TIER_BONUS
ResurfaceService.MIN_PEARLS = MIN_PEARLS
ResurfaceService.MAX_PEARLS = MAX_PEARLS

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

-- The ServerContext, captured at Start. The ActionContext projection deliberately carries no `net`,
-- and pushView needs one.
ResurfaceService._context = nil :: any
-- userId -> true while that player's resurface is parked inside ctx.data:update (mechanism (2)).
ResurfaceService._resurfacing = {} :: { [number]: boolean }

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

-- A non-negative finite amount; garbage reads as 0 rather than poisoning the arithmetic downstream.
local function sanitizeAmount(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return value
end

-- A non-negative integer count, clamped well below the float ceiling so `resurfaces + 1` can never
-- saturate into a value the multiplier maths cannot use.
local function sanitizeCount(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return math.min(math.floor(value), 1000000)
end

-- THE tier this blob is standing on. A MIRROR of DepthService.tierOf, degrade rule included: an
-- absent / garbage / OUT-OF-RANGE `upgrades.depth` reads as tier 1, never as the deepest rung.
--
-- OUT OF RANGE DEGRADES DOWN, NEVER UP, and here that is a DUPE boundary as well as a monetization
-- one: a value that resolved UP would let a corrupted or rolled-back record clear the resurface
-- requirement it never earned, and mint Pearls for it.
local function tierOf(data: any): number
	if type(data) ~= "table" or type(data.upgrades) ~= "table" then
		return FIRST_DEPTH_TIER
	end
	local raw = data.upgrades[DEPTH_UPGRADE_KEY]
	if not isUsableNumber(raw) then
		return FIRST_DEPTH_TIER
	end
	local floored = math.floor(raw)
	if floored < FIRST_DEPTH_TIER or floored > DEPTH_TIER_CEILING then
		return FIRST_DEPTH_TIER
	end
	return floored
end

ResurfaceService.tierOf = function(_self: any, data: any): number
	return tierOf(data)
end

-- A READ-ONLY reading of a numeric leaf on a nested record. Used by `describe`, which runs on the
-- LIVE session blob outside any lock and therefore may not repair anything in place.
local function readNumber(data: any, record: string, key: string): number
	if type(data) ~= "table" or type(data[record]) ~= "table" then
		return 0
	end
	return sanitizeAmount(data[record][key])
end

-- Deep copy of a plain-data blob. PlayerData is pure data (no cycles, no metatables, no userdata), so
-- a bounded recursive copy is total. The DEPTH BOUND is not decoration: a blob is data off a
-- DataStore, and a maliciously or accidentally deep structure must not turn a client-callable read
-- action into an unbounded recursion.
local MAX_COPY_DEPTH = 12
local function deepCopy(value: any, depth: number): any
	if type(value) ~= "table" or depth > MAX_COPY_DEPTH then
		return value
	end
	local copy: any = {}
	for key, child in value do
		copy[key] = deepCopy(child, depth + 1)
	end
	return copy
end

-- ── THE PEARL MINT AMOUNT (pure over the blob) ──────────────────────────────────────────────────

-- What a resurface WOULD mint for this blob, right now. The SINGLE definition: `describe` previews it
-- and `resurface` mints it by calling THIS function, so the confirm dialog cannot promise a number
-- the transform does not pay. Trusts nothing but the persisted blob — there is no client input on
-- this path at all.
function ResurfaceService.pearlsFor(_self: any, data: any): number
	local lifetime = 0
	if type(data) == "table" and type(data.stats) == "table" then
		lifetime = sanitizeAmount(data.stats.lifetimeCredits)
	end
	local bonus = 1 + PEARL_TIER_BONUS * math.max(0, tierOf(data) - MIN_RESURFACE_TIER)
	local raw = math.sqrt(lifetime / PEARL_CREDIT_DIVISOR) * bonus
	if not isUsableNumber(raw) or raw < 0 then
		return MIN_PEARLS
	end
	return math.clamp(math.floor(raw), MIN_PEARLS, MAX_PEARLS)
end

-- ── THE PERMANENT MULTIPLIER, MEASURED THROUGH THE LIVE RATE FUNCTION ───────────────────────────

-- A synthetic blob that differs from its sibling in EXACTLY ONE field: the resurface count. Shaped
-- like PlayerData so `ctx.salvage:rateFor` reads it the same way it reads a real one.
local function syntheticBlob(count: number): any
	return {
		currencies = {},
		stats = { lifetimeCredits = 0, joinCount = 0, playtimeSeconds = 0 },
		upgrades = {},
		flags = {},
		smelter = { storedCredits = 0, lastTickUnix = 0 },
		resurfaces = count,
		boostExpiresUnix = 0,
	}
end

-- ctx.salvage:rateFor, nil-safe and value-checked. Returns nil when the seam is absent or answers
-- with something unusable, so a caller can report "not measured" instead of inventing a number.
local function rateThrough(salvage: any, data: any, nowUnix: number, depth: any?): number?
	if salvage == nil or type(salvage.rateFor) ~= "function" then
		return nil
	end
	local ok, value = pcall(function()
		return salvage:rateFor(data, nowUnix, depth)
	end)
	if ok and isUsableNumber(value) and value >= 0 then
		return value
	end
	return nil
end

-- THE PERMANENT MULTIPLIER AT `count` RESURFACES, measured rather than restated: two readings of the
-- game's own rate function on two synthetic blobs that differ only in `resurfaces`. Every other input
-- — drones, conveyor, the gamepass 2x, the paid boost, the depth tier and today's restock — is
-- IDENTICAL on both and cancels in the ratio, so what survives is exactly the prestige factor
-- SalvageService.multiplierAt applies to `data.resurfaces`.
--
-- Returns (multiplier, measured). `measured == false` means ctx.salvage was not installed (a Tier-1
-- harness that did not wire it) or the seam answered unusably — the multiplier then reads 1x and the
-- caller SAYS SO, rather than a silent 1 that would make an inert multiplier look neutral.
function ResurfaceService.prestigeMultiplierAt(
	_self: any,
	salvage: any,
	count: number,
	nowUnix: number,
	depth: any?
): (number, boolean)
	local baseline = rateThrough(salvage, syntheticBlob(0), nowUnix, depth)
	if baseline == nil or baseline <= 0 then
		return 1, false
	end
	local raised = rateThrough(salvage, syntheticBlob(sanitizeCount(count)), nowUnix, depth)
	if raised == nil then
		return 1, false
	end
	local ratio = raised / baseline
	if not isUsableNumber(ratio) or ratio <= 0 then
		return 1, false
	end
	return ratio, true
end

-- ── THE WIPE (pure mutation of one snapshot, plus its exact undo) ───────────────────────────────

export type WipeSnapshot = {
	credits: any, -- may be nil: a blob that never held Credits restores to ABSENT
	upgradeLevels: { [string]: any },
	upgradesTable: any,
	smelterTable: any,
	storedCredits: any,
	resurfaces: any,
}

-- Capture every value `applyWipe` is about to overwrite, off THIS snapshot, so a refused mint can be
-- rolled back byte-for-byte. A captured `nil` is a legitimate value (an absent key), and writing nil
-- back restores absence — which is why no sentinel is needed anywhere here.
function ResurfaceService.captureWipe(_self: any, data: any): WipeSnapshot
	local upgrades = data.upgrades
	local levels: { [string]: any } = {}
	if type(upgrades) == "table" then
		for _, key in WIPED_UPGRADE_KEYS do
			levels[key] = upgrades[key]
		end
		levels[DEPTH_UPGRADE_KEY] = upgrades[DEPTH_UPGRADE_KEY]
	end
	local smelter = data.smelter
	return {
		credits = data.currencies[CREDIT_CURRENCY],
		upgradeLevels = levels,
		upgradesTable = upgrades,
		smelterTable = smelter,
		storedCredits = if type(smelter) == "table" then smelter.storedCredits else nil,
		resurfaces = data.resurfaces,
	}
end

-- THE ONE TRANSFORM'S MUTATION, applied IN PLACE. Synchronous by construction: no yield, no data
-- call, no engine call, no analytics emit. It is called on the real snapshot inside the lock AND on a
-- deep copy by `simulate`, which is what keeps the preview and the outcome from ever disagreeing.
--
-- THE RESET IS NOT A SPEND. `currencies.Credits = 0` is written directly and deliberately NOT through
-- ctx.economy:spend: spend would refuse a debit larger than the balance, would emit currency_spent
-- for a sink that does not exist, and — the contract's rule — a RESET must leave stats.lifetimeCredits
-- alone. Nothing in this function touches data.stats at all.
function ResurfaceService.applyWipe(_self: any, data: any): ()
	-- The soft balance: reset, not spent.
	data.currencies[CREDIT_CURRENCY] = 0

	local upgrades = data.upgrades
	if type(upgrades) ~= "table" then
		-- A blob with no `upgrades` map is repaired to the shape Migrations seeds. The repair is NOT
		-- undone by restoreWipe beyond restoring the original value of `data.upgrades` itself.
		upgrades = {}
		data.upgrades = upgrades
	end
	-- The Credits-bought structures. Set to 0, not deleted — see the header (a deleted key leaves the
	-- shop rendering pre-prestige levels off the replicated view).
	for _, key in WIPED_UPGRADE_KEYS do
		upgrades[key] = 0
	end
	-- THE LITERAL 1, never a sentinel and never 0: DepthService.tierOf degrades an out-of-range value
	-- DOWN to tier 1, so 0 would still read as tier 1 — but it would persist a value the ladder does
	-- not contain, and the next reader to clamp instead of degrade would resolve it differently.
	upgrades[DEPTH_UPGRADE_KEY] = FIRST_DEPTH_TIER
	-- `pearlDrones` is NOT in WIPED_UPGRADE_KEYS and is not touched by any line above: Pearl purchases
	-- are permanent.

	local smelter = data.smelter
	if type(smelter) ~= "table" then
		smelter = { storedCredits = 0, lastTickUnix = 0 }
		data.smelter = smelter
	end
	-- Un-collected output goes with the structures that produced it. `lastTickUnix` is NOT touched:
	-- it is SalvageService's accrual base, and moving it would either re-credit or skip a span this
	-- feature has no business deciding.
	smelter.storedCredits = 0

	-- THE PERMANENT MULTIPLIER, landed. SalvageService reads this count; nothing else here does.
	data.resurfaces = sanitizeCount(data.resurfaces) + 1
end

-- The exact undo of applyWipe, from a captureWipe snapshot. Only ever writes values captured off THIS
-- snapshot moments earlier — it can restore a level, never invent one.
function ResurfaceService.restoreWipe(_self: any, data: any, snapshot: WipeSnapshot): ()
	data.currencies[CREDIT_CURRENCY] = snapshot.credits
	if type(data.upgrades) == "table" then
		-- DRIVEN BY THE KEY LIST applyWipe WROTE, NEVER BY ITERATING THE CAPTURED TABLE. A captured
		-- `nil` is a legitimate value (the key was ABSENT — an untouched structure is absent, not 0,
		-- because every reader normalizes absence to 0 and so nothing ever writes the 0), and
		-- generalized iteration never yields a nil value: it would silently skip exactly the keys
		-- whose absence the rollback is supposed to restore, leaving the wipe's 0 in place and making
		-- the byte-for-byte claim false on the one shape it matters for. Walking the same fixed list
		-- applyWipe walked visits every key it could have written, so writing the captured value back
		-- — including nil — restores absence.
		for _, key in WIPED_UPGRADE_KEYS do
			data.upgrades[key] = snapshot.upgradeLevels[key]
		end
		data.upgrades[DEPTH_UPGRADE_KEY] = snapshot.upgradeLevels[DEPTH_UPGRADE_KEY]
	end
	-- Restores ABSENCE when the blob carried no upgrades map at all (snapshot.upgradesTable is nil).
	data.upgrades = snapshot.upgradesTable
	if type(snapshot.smelterTable) == "table" then
		snapshot.smelterTable.storedCredits = snapshot.storedCredits
	end
	data.smelter = snapshot.smelterTable
	data.resurfaces = snapshot.resurfaces
end

-- A post-resurface blob WITHOUT touching the real one: deep copy, then the SAME applyWipe. Used only
-- by the preview, so what the confirm dialog shows is computed the way the outcome is computed.
function ResurfaceService.simulate(self: any, data: any): any
	local copy = deepCopy(data, 0)
	if type(copy) ~= "table" then
		return copy
	end
	if type(copy.currencies) ~= "table" then
		copy.currencies = {}
	end
	self:applyWipe(copy)
	return copy
end

-- ── the observation surface ─────────────────────────────────────────────────────────────────────

export type ResurfacePreview = {
	-- WHERE THE PLAYER IS
	resurfaces: number, -- the prestige count TODAY
	nextResurfaces: number, -- what it becomes
	depthTier: number,
	minDepthTier: number,
	depthMet: boolean,
	canResurface: boolean, -- the gate's verdict. ADVISORY: the transform re-evaluates it under the lock
	-- WHAT THEY GET
	pearls: number, -- what would be minted, from the SAME function the mint calls
	pearlBalance: number,
	lifetimeCredits: number, -- the input to the Pearl formula, and a field that SURVIVES
	-- THE PERMANENT MULTIPLIER, measured through ctx.salvage:rateFor (never restated from a constant)
	multiplier: number,
	nextMultiplier: number,
	multiplierMeasured: boolean,
	-- THE RUNNING RATE, either side of the wipe. Same seam, same clock, real blob vs simulated one.
	rateNow: number,
	rateAfter: number,
	rateMeasured: boolean,
	-- WHAT IT COSTS — so the confirm dialog states both halves and the player is never surprised
	credits: number,
	storedCredits: number,
	wipes: { string },
	survives: { string },
	pearlDrones: number,
	boostExpiresUnix: number, -- AMENDMENT A6: survives, untouched
	nowUnix: number,
}

-- PURE over the blob + the server clock + the nil-safe ctx.salvage seam. SIDE-EFFECT FREE BY
-- CONSTRUCTION: it writes nothing, stamps nothing, grants nothing and normalizes nothing in place.
-- Every post-resurface number comes off a DEEP COPY.
function ResurfaceService.describe(
	self: any,
	data: any,
	nowUnix: number,
	salvage: any?,
	depth: any?
): ResurfacePreview
	local tier = tierOf(data)
	local depthMet = tier >= MIN_RESURFACE_TIER
	local count = sanitizeCount(if type(data) == "table" then data.resurfaces else 0)

	local multiplier, measured = self:prestigeMultiplierAt(salvage, count, nowUnix, depth)
	local nextMultiplier, nextMeasured =
		self:prestigeMultiplierAt(salvage, count + 1, nowUnix, depth)

	local after = self:simulate(data)
	local rateNow = rateThrough(salvage, data, nowUnix, depth)
	local rateAfter = rateThrough(salvage, after, nowUnix, depth)

	local wipes: { string } = {}
	for _, key in WIPED_UPGRADE_KEYS do
		table.insert(wipes, key)
	end
	table.insert(wipes, DEPTH_UPGRADE_KEY)

	local survives: { string } = {}
	for _, key in SURVIVING_UPGRADE_KEYS do
		table.insert(survives, key)
	end

	return {
		resurfaces = count,
		nextResurfaces = count + 1,
		depthTier = tier,
		minDepthTier = MIN_RESURFACE_TIER,
		depthMet = depthMet,
		canResurface = depthMet,
		pearls = self:pearlsFor(data),
		pearlBalance = readNumber(data, "currencies", PEARL_CURRENCY),
		lifetimeCredits = readNumber(data, "stats", "lifetimeCredits"),
		multiplier = multiplier,
		nextMultiplier = nextMultiplier,
		multiplierMeasured = measured and nextMeasured,
		rateNow = rateNow or 0,
		rateAfter = rateAfter or 0,
		rateMeasured = rateNow ~= nil and rateAfter ~= nil,
		credits = readNumber(data, "currencies", CREDIT_CURRENCY),
		storedCredits = readNumber(data, "smelter", "storedCredits"),
		wipes = wipes,
		survives = survives,
		pearlDrones = readNumber(data, "upgrades", SURVIVING_UPGRADE_KEYS[1]),
		boostExpiresUnix = if type(data) == "table" and isUsableNumber(data.boostExpiresUnix)
			then data.boostExpiresUnix
			else 0,
		nowUnix = nowUnix,
	}
end

-- `resurface.fetch`. STRICTLY side-effect free: one `get`, one pure `describe`, no write anywhere.
function ResurfaceService.fetch(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "resurface: context is missing data/clock")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"resurface: the server clock returned no usable time"
		)
	end
	local got = ctx.data:get(ctx.player)
	if not got.ok then
		-- NoData until loadSession resolves; the client's JoinRetry guard re-issues past it.
		return got
	end
	return Result.ok(self:describe(got.value, now :: number, ctx.salvage, ctx.depth))
end

-- ── THE RESURFACE ───────────────────────────────────────────────────────────────────────────────

export type ResurfaceInfo = {
	resurfaces: number, -- the NEW count — the number the permanent multiplier is derived from
	previousResurfaces: number,
	pearls: number, -- minted by THIS resurface
	pearlBalance: number, -- the post-mint balance, as EconomyService computed it
	depthTier: number, -- the tier resurfaced FROM
	minDepthTier: number,
	-- THE DELTA ON THE PERMANENT MULTIPLIER, measured through ctx.salvage:rateFor.
	multiplier: number,
	previousMultiplier: number,
	multiplierMeasured: boolean,
	-- THE DELTA ON THE RUNNING RATE, read off the real snapshot either side of the wipe.
	rateBefore: number,
	rateAfter: number,
	rateMeasured: boolean,
	-- WHAT THE RESET CLEARED (reporting only; no client number was involved in any of it).
	creditsCleared: number,
	storedCleared: number,
	-- THE SURVIVE-LIST, READABLE OFF THE REPLY. Every one of these is a field this transform did not
	-- write, carried here so the promise is observable rather than only documented.
	lifetimeCredits: number,
	pearlDrones: number,
	boostExpiresUnix: number,
	nowUnix: number,
}

-- THE resurface. The requirement check, the Pearl amount, the wipe and the mint all happen in the ONE
-- lock-held transform; see THE CONCURRENCY ARGUMENT in the header.
function ResurfaceService.resurface(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "resurface: context is missing data/clock")
	end
	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "resurface: player has no numeric UserId")
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"resurface: the server clock returned no usable time"
		)
	end
	local nowUnix = now :: number

	local economy = ctx.economy
	if economy == nil or type(economy.earn) ~= "function" then
		-- ctx.economy is the ENFORCEMENT POINT for every mint in this game: it is what emits
		-- currency_earned and what BRANCHES on currency so a Pearls mint leaves stats.lifetimeCredits
		-- alone. Minting around it would be a direct, unaudited write of data.currencies, so an absent
		-- seam is a refusal — never a fall-through.
		return Result.err(
			Result.Codes.Internal,
			"resurface: ctx.economy is not installed — minting here would skip the currency_earned "
				.. "event and the lifetime-counter branch"
		)
	end

	-- (2) RESERVE, synchronously, before anything below can yield. A spam-duplicated resurface that
	-- arrives while the first is parked in the store lands here and is refused WITHOUT reaching the
	-- data layer, with the SAME code the tier-1 blob it is racing toward would give it.
	if self._resurfacing[userId] then
		return Result.err(
			Result.Codes.PrereqUnmet,
			"resurface: a resurface for this player is already in flight — the dome is already surfacing"
		)
	end
	self._resurfacing[userId] = true

	local salvage = ctx.salvage
	local depth = ctx.depth
	local outcome: any = nil

	-- (1) THE ONE LOCK-HELD TRANSFORM. Synchronous by construction: it contains no yield of any kind,
	-- so the requirement, the Pearl amount, the wipe and the mint all read and write the SAME snapshot.
	local function transform(data: any): any
		-- EVERY REFUSAL IS DECIDED BEFORE THE FIRST MUTATION.
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "resurface: data blob is not a table")
			return data
		end
		if type(data.currencies) ~= "table" then
			-- Refused UP FRONT rather than discovered halfway through a wipe: ctx.economy:earn needs
			-- this map too, and a blob half-wiped by a transform that then refuses is the worst
			-- possible outcome of a prestige.
			outcome = Result.err(Result.Codes.Internal, "resurface: data.currencies is missing")
			return data
		end

		local tier = tierOf(data)
		if tier < MIN_RESURFACE_TIER then
			-- PrereqUnmet, never Insufficient: this is a NON-CURRENCY prerequisite, and the two codes
			-- must stay distinguishable or "the depth requirement holds" is untestable. This is ALSO
			-- the code the second of two same-frame resurfaces gets, because the first one's committed
			-- wipe put `upgrades.depth` back to 1.
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`resurface: the trench floor is at depth tier {MIN_RESURFACE_TIER}; this dome is at `
					.. `tier {tier}. Resurfacing is what you do AFTER the descent, not instead of it`
			)
			return data
		end

		local previousResurfaces = sanitizeCount(data.resurfaces)
		-- COMPUTED INSIDE THE TRANSFORM, off the snapshot the lock just handed us — a number derived
		-- before the yield would be the stale one, and paying that out IS the dupe.
		local pearls = self:pearlsFor(data)
		local rateBefore = rateThrough(salvage, data, nowUnix, depth)
		local previousMultiplier, previousMeasured =
			self:prestigeMultiplierAt(salvage, previousResurfaces, nowUnix, depth)
		local creditsCleared = sanitizeAmount(data.currencies[CREDIT_CURRENCY])
		local storedCleared = readNumber(data, "smelter", "storedCredits")

		-- WIPE FIRST, MINT LAST. earn emits currency_earned as its final act, so keeping it the last
		-- mutation in the transform means no later statement can throw and discard a snapshot the event
		-- already described.
		local snapshot = self:captureWipe(data)
		self:applyWipe(data)

		local rateAfter = rateThrough(salvage, data, nowUnix, depth)
		local multiplier, measured =
			self:prestigeMultiplierAt(salvage, data.resurfaces, nowUnix, depth)

		local granted = economy:earn(data, PEARL_CURRENCY, pearls, EARN_SOURCE)
		if not granted.ok then
			-- (3) ROLL THE WHOLE WIPE BACK, byte-for-byte, to exactly what this snapshot held —
			-- including absent keys. `earn` is atomic-or-nothing as of the current commit, so nothing
			-- was credited; this makes the transaction atomic on OUR side rather than assuming it of
			-- the seam. Without it a refused mint would leave the player's entire run destroyed and
			-- nothing paid for it.
			self:restoreWipe(data, snapshot)
			outcome = granted
			return data
		end

		local info: ResurfaceInfo = {
			resurfaces = data.resurfaces,
			previousResurfaces = previousResurfaces,
			pearls = pearls,
			pearlBalance = granted.value.balance,
			depthTier = tier,
			minDepthTier = MIN_RESURFACE_TIER,
			multiplier = multiplier,
			previousMultiplier = previousMultiplier,
			multiplierMeasured = measured and previousMeasured,
			rateBefore = rateBefore or 0,
			rateAfter = rateAfter or 0,
			rateMeasured = rateBefore ~= nil and rateAfter ~= nil,
			creditsCleared = creditsCleared,
			storedCleared = storedCleared,
			-- READ, NEVER WRITTEN, by anything above: the survive-list, off the post-wipe snapshot.
			lifetimeCredits = readNumber(data, "stats", "lifetimeCredits"),
			pearlDrones = readNumber(data, "upgrades", SURVIVING_UPGRADE_KEYS[1]),
			boostExpiresUnix = if isUsableNumber(data.boostExpiresUnix)
				then data.boostExpiresUnix
				else 0,
			nowUnix = nowUnix,
		}
		outcome = Result.ok(info)
		return data
	end

	-- pcall'd ONLY so the reservation is released on every path: DataService:update already pcalls the
	-- transform, so a throw here would have to come from the data layer itself — and a reservation
	-- stranded `true` would lock this player out of their own prestige for the life of the server.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	self._resurfacing[userId] = nil

	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "resurface: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, or a transform that
		-- threw. The snapshot was discarded either way, so NOTHING was persisted: nothing was wiped,
		-- no Pearl was minted, and the Err is surfaced as-is rather than dressed up as a prestige.
		return written
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"resurface: the update reported success but the transform produced no outcome"
		)
	end
	if not outcome.ok then
		return outcome
	end

	local info: ResurfaceInfo = outcome.value

	-- ── EVERYTHING BELOW IS DERIVED FROM A COMMITTED WRITE, COMES AFTER IT, AND CAN NEVER UNDO IT.
	-- Each step is guarded and its failure discarded: an unguarded post-write side effect is how a
	-- committed economy write once came back to the client as Err(Internal) (docs/LEARNINGS.md).

	-- `progression`, carrying the NEW resurface count. `currency_earned` for the Pearl mint was
	-- already emitted BY ctx.economy:earn — emitting it here too would double-count the mint.
	self:emit(ctx, "progression", {
		userId = userId,
		kind = "resurface",
		resurfaces = info.resurfaces,
		previousResurfaces = info.previousResurfaces,
		pearls = info.pearls,
		pearlBalance = info.pearlBalance,
		depthTier = info.depthTier,
		multiplier = info.multiplier,
		previousMultiplier = info.previousMultiplier,
		lifetimeCredits = info.lifetimeCredits,
	})

	-- The view push. Without it the HUD would show the pre-prestige Credits, levels, depth and
	-- resurface count until the next unrelated write.
	self:pushView(self._context, player)

	return Result.ok(info)
end

-- Nil-safe analytics emit (ctx.analytics:emit(event, payload)). An unwired seam is a no-op, and a
-- throwing emitter must never turn a committed resurface into an error.
function ResurfaceService.emit(_self: any, ctx: any, event: string, payload: any): boolean
	local analytics = if ctx ~= nil then ctx.analytics else nil
	if analytics == nil or type(analytics.emit) ~= "function" then
		return false
	end
	local ok = pcall(function()
		analytics:emit(event, payload)
	end)
	return ok
end

-- Push the refreshed client view after a committed resurface. `context` is the SERVER context (the
-- ActionContext projection carries no net). Guarded + pcall'd; the return value is ignored by its
-- caller, because a presentation failure must never turn a granted prestige into an error.
function ResurfaceService.pushView(_self: any, context: any, player: any): boolean
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

-- BOTH payloads carry NOTHING BY CONTRACT — no amount, no multiplier, no tier, no confirmation token,
-- no timestamp. A payload that names one is REFUSED rather than ignored: an ignored forgery is
-- byte-identical to a well-formed request, and the difference is the only signal that somebody is
-- probing the mint. The validator hands the handler a FRESH EMPTY TABLE, so the handler is not merely
-- disciplined about ignoring client data — it is never handed any. There is no client number anywhere
-- on this path: the Pearl amount is arithmetic on a lock-held snapshot.
local FORBIDDEN_PAYLOAD_KEYS = {
	"pearls",
	"Pearls",
	"amount",
	"credits",
	"Credits",
	"currency",
	"balance",
	"multiplier",
	"resurfaces",
	"prestige",
	"count",
	"tier",
	"depth",
	"minDepth",
	"level",
	"upgrades",
	"drones",
	"pearlDrones",
	"conveyor",
	"smelter",
	"hull",
	"stored",
	"storedCredits",
	"lifetimeCredits",
	"rate",
	"boost",
	"boostExpiresUnix",
	"now",
	"nowUnix",
	"time",
	"timestamp",
	"unix",
	"serverTime",
	"clientTime",
	"userId",
	"plotId",
	"confirm",
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
				`resurface actions take no arguments — the SERVER derives the requirement, the Pearls `
					.. `and the multiplier (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

ResurfaceService.validate = validateNoArguments

-- Exported so a Tier-1 spec can register the actions on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as CLOSURES over the service because the single-flight
-- reservation table IS service state, which a static-module registration cannot reach.
function ResurfaceService.resurfaceAction(self: any): any
	return {
		name = Net.Actions.Resurface,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB: the tightest bucket of any action in this game. This
		-- is the most destructive action the player has and the one a duplicate could dupe Pearls
		-- through, so a spam burst is refused by the Gate before it ever reaches the single-writer path.
		rate = { maxPerWindow = 2, windowSeconds = 10.0 },
		handler = function(ctx: any, _payload: any): any
			return self:resurface(ctx)
		end,
	}
end

function ResurfaceService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchResurface,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB.
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		-- SIDE-EFFECT FREE: the preview never resurfaces, never mints, never writes and never stamps.
		handler = function(ctx: any, _payload: any): any
			return self:fetch(ctx)
		end,
	}
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: capture the context (pushView needs the `net` the ActionContext projection does not carry),
-- reset the per-server state, register the wire surface. Installs NO seam and starts NO loop — this
-- feature has no tick, no world and nothing to publish. Fully Lune-callable: nothing here touches a
-- Roblox global.
function ResurfaceService.Start(self: any, context: any): ()
	self._context = context
	self._resurfacing = {}
	context.net:register(self:resurfaceAction())
	context.net:register(self:fetchAction())
end

function ResurfaceService.Stop(self: any, _context: any): ()
	self._resurfacing = {}
	self._context = nil
end

return ResurfaceService
