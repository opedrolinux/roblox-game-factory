--!strict
-- games/deep-reach/src/server/services/structures/StructuresShopService.luau  [feature: structures]
--
-- THE authoritative owner of the structures shop: the server-owned CATALOG, the server-derived price
-- curve, the ONE lock-held transform that debits and writes the purchased level, and the greybox
-- kiosk. Replaces the contract-pass stub in place, preserving every contract decision the stub
-- pinned: the two action names (Net.Actions.BuyStructure / Net.Actions.FetchStructures), their
-- RatePolicies ({5, 1.0s} and {10, 1.0s}), the closure-based registration, and the fact that this
-- service provides NO ctx seam (contract.stubs.structures.seamProvided is null — so nothing here is
-- published on `context.<field>`, and no other feature resolves this file).
--
-- ── WHAT THIS SLICE OWNS ────────────────────────────────────────────────────────────────────────
--  1. THE CATALOG, server-owned and server-priced. Five entries: `drones`, `conveyor`, `smelter` and
--     `hull` priced in Credits, and `pearlDrones` priced in Pearls. THE CLIENT SENDS ONLY A KEY —
--     never a price, never a level, never a quantity, never a currency. A payload that names one of
--     those is REFUSED rather than ignored (see FORBIDDEN_PAYLOAD_KEYS): a client-supplied cost is
--     the classic shop exploit, and an ignored forgery is byte-indistinguishable from a well-formed
--     request, which throws away the only signal that somebody is probing the till.
--  2. `structures.buy` — validate type + range + membership + rate, then in ONE ctx.data:update read
--     the level off the LOCK-HELD SNAPSHOT, derive the cost from it, write `upgrades.<key> += 1` and
--     debit through `ctx.economy:spend`. Nothing here ever touches `data.currencies`.
--  3. `structures.fetch` — the catalog with server-derived NEXT-LEVEL prices, this player's levels,
--     their balances and, per entry, the CURRENT and ONE-LEVEL-HIGHER reading of the observable that
--     entry moves. That is why the shop UI holds no price constants and no effect constants: both
--     come off this reply.
--  4. THE FIRST CURRENCY SINK IN THIS GAME. Credits and Pearls were granted, persisted and displayed
--     with no spend site anywhere (the "Prisms defect"). The Credits-priced entries and the
--     Pearl-priced `pearlDrones` entry are what make them currencies rather than scoreboards.
--  5. The greybox kiosk under `ctx.plot:rootFor(player)`, plus the sign that reads back the fleet.
--
-- NOT THIS SLICE: the income rate function or the tick (SalvageService owns both — this file only
-- WRITES the upgrade keys it reads); the depth unlock cost or the pressure gate (DepthService, a
-- later batch); minting Pearls or the prestige multiplier (ResurfaceService); gamepasses and dev
-- products (MonetizationService). This file registers no analytics event of its own either:
-- `currency_spent` is emitted BY `ctx.economy:spend`, which is the whole reason that seam exists.
--
-- ── NO PURCHASABLE SHIPS INERT, AND THAT IS ENFORCED HERE, NOT ONLY IN A TEST ────────────────────
-- 26 of collect-sim's 66 confirmed defects were the same shape: a purchase incremented a persisted
-- field, the test asserted the field moved, and NOTHING read it — 9,625 Stardust for no measurable
-- effect while 313 tests stayed green. So every entry in this file is bound, in `EFFECTS`, to the
-- SERVER-DERIVED OBSERVABLE it moves — and, decisively, TO THE ctx SEAM THAT READS IT. Every measure
-- resolves through somebody ELSE:
--     drones / conveyor / pearlDrones -> ctx.salvage:rateFor(blob)      (the running income rate)
--     smelter                         -> ctx.salvage:capacityFor(blob)  (and therefore the offline cap)
--     hull                            -> ctx.depth:hullRatingOf(blob)   (the pressure gate; NOT income)
-- `EFFECTS[key].measure` is called on the blob and on a one-level-higher PROBE to fill the shop row,
-- it is called BEFORE and AFTER the write inside the buy transform so the reply carries the actual
-- DELTA the purchase produced, and `auditEffects` re-runs the whole matrix at Start against a
-- reference blob so an entry that stopped moving — or that nothing reads at all — is loud at boot
-- rather than silent forever.
--
-- AND THE TILL IS SHUT ON BOTH, NOT ONLY ON THE FIRST. `buy` REFUSES (PrereqUnmet, nothing debited,
-- no currency_spent) any entry whose consumer answers and does not move — AND any entry whose
-- consumer is not installed at all. That second half is the correction the economy red-team forced:
-- an UNPROVEN entry used to be merely printed about at boot and sold anyway, which is how `hull`
-- came to debit an escalating, irreversible Credits price for a key nothing in the game reads. A
-- purchase is deliverable only while somebody OUTSIDE this file can be seen reading what it writes.
--
-- WHY THE SEAM, AND NOT JUST "A DERIVED VALUE". `hull` originally measured through `hullRatingOf`, a
-- pure function of the very `upgrades.hull` key this shop writes, defined in this file. That made the
-- audit STRUCTURALLY INCAPABLE of failing for `hull`: it compared 1 against 2, reported `moved = true`
-- forever, and printed nothing at boot while the shop sold a 400-Credit, geometrically escalating,
-- irreversible upgrade that NOTHING in the game read. A guard that certifies an entry against itself
-- is worse than no guard, because it reads like one — and it was self-certifying on precisely the one
-- entry at risk. An observable now has to be somebody else's reading or it is reported UNPROVEN
-- (`assertCatalogOrder` refuses an entry that names no consumer at all). See KNOWN LIMITATIONS.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The double-spend this feature is one mistake away from: read the level (and therefore the price)
-- OUTSIDE the transform, YIELD in ctx.data:update, then debit and write. Two buys in the same frame
-- both price level 3, both pay the level-3 price, and the player gets two levels for one price step
-- — forever, once per spam burst. And its mirror: debit outside the transform, write inside, and a
-- failed write eats the Credits.
--
-- Three facts close it, and none of them is a debounce:
--   (1) THE READ, THE PRICE, THE WRITE AND THE DEBIT ARE ONE LOCK-HELD TRANSFORM. `buy` computes
--       NOTHING about level, cost or balance before calling ctx.data:update. DataService:update runs
--       the transform under the per-player FIFO lock against a snapshot RE-READ after any earlier
--       update has committed, and the transform is synchronous — it contains no yield of any kind.
--       So two spam-duplicated buys are SERIALIZED: the second one's transform observes the level
--       the first one wrote, prices the NEXT step off it, and either pays that higher price or is
--       refused. n buys cost the sum of n consecutive steps and grant exactly n levels. There is
--       deliberately NO single-flight reservation here: unlike a smelter collect (where the second
--       request is a duplicate of the first), a second BUY is a legitimate second purchase, and
--       refusing it would be a bug wearing a safety code.
--   (2) THE DEBIT IS THE LAST MUTATION IN THE TRANSFORM. `ctx.economy:spend` guards the balance
--       BEFORE it writes (Err(Insufficient), never a negative balance) and emits `currency_spent` as
--       its final act, so keeping it last means no later statement can throw and discard a snapshot
--       the event already described. Everything after it in the transform is a READ.
--   (3) THE ROLLBACK IS EXACT. The level is written BEFORE the debit (the debit has to be last), so
--       a refused debit restores `upgrades[key]` to the value the snapshot held — including nil,
--       which restores ABSENCE — and returns the Err. `spend` is atomic-or-nothing as of the current
--       commit, so "not ok" means the balance was untouched; the rollback makes THIS transaction
--       atomic on its own side rather than assuming it of the seam (the salvage gate caught exactly
--       that assumption as a mint). And if the WRITE fails, the store discards the whole snapshot:
--       nothing was durably debited or levelled, and there is nothing to compensate.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- Every decision here is Roblox-FREE: catalog / nextCostOf / levelOf / hullRatingOf / describe /
-- describeEntry / buy / auditEffects / validateBuy / validateNoArguments and both action factories
-- run under Lune with Mocks.player + a real DataService over MockStore and no engine at all. Only
-- `startRuntime`, the join waiter and the kiosk builders touch `game` / `task` / `Instance`, each
-- through a guarded local, so requiring and Starting this module under Lune never throws.
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

local StructuresShopService = {}
StructuresShopService.name = "StructuresShopService"

-- ── the catalog ─────────────────────────────────────────────────────────────────────────────────

export type CatalogEntry = {
	-- The balance key this entry spends. Written as a LITERAL so the file that sells a thing names
	-- the currency it charges for it — a shop that resolved its currency indirectly could not be
	-- read as a sink by anything, human or gate.
	currency: string,
	base: number, -- the cost of level 1
	growth: number, -- geometric step per owned level; the cost curve, server-side and only here
	maxLevel: number,
	label: string, -- the strings the shop renders. They live SERVER-side next to the price, so the
	blurb: string, -- promise and the price can never drift apart in the UI.
}

-- THE server-owned catalog. Keys are the CANONICAL persisted upgrade keys the contract pass
-- registered and SalvageService reads (its own `UPGRADE_KEYS` table names four of these five, and
-- its header says why: "a shop that wrote `upgrades.drone` would persist a purchase that changes no
-- rate at all — inert, and green against any test that only asserts the field moved"). `hull` is the
-- fifth and is read by the Depth pressure gate, a later batch.
--
-- Prices are geometric so the curve keeps meaning across the whole run: `base` is what level 1
-- costs, `growth` is what each owned level multiplies the next one by. The client never sees these
-- numbers except as the `nextCost` the server computed for it.
local CATALOG: { [string]: CatalogEntry } = {
	["drones"] = {
		currency = "Credits",
		base = 50,
		growth = 1.35,
		maxLevel = 25,
		label = "Salvage Drone",
		blurb = "One more hauler on the wreck line",
	},
	["conveyor"] = {
		currency = "Credits",
		base = 150,
		growth = 1.45,
		maxLevel = 20,
		label = "Conveyor Belt",
		blurb = "The whole fleet delivers faster",
	},
	["smelter"] = {
		currency = "Credits",
		base = 200,
		growth = 1.5,
		maxLevel = 20,
		label = "Smelter Tank",
		blurb = "Hold more before it overflows — and bank more while you are away",
	},
	["hull"] = {
		currency = "Credits",
		base = 400,
		growth = 1.8,
		maxLevel = 10,
		label = "Hull Plating",
		blurb = "Rated for deeper trenches. No income of its own — it is what lets you descend",
	},
	-- THE PEARL SINK. Pearls are minted by resurfacing and, before this entry existed, were granted,
	-- persisted and displayed while nothing in the game could spend them. Pearl drones also SURVIVE a
	-- resurface (the contract: a resurface wipes every upgrade key except `pearlDrones`), which is
	-- what makes them worth buying with a prestige currency.
	["pearlDrones"] = {
		currency = "Pearls",
		base = 1,
		growth = 1.6,
		maxLevel = 15,
		label = "Pearl Drone",
		blurb = "A prestige hauler that survives every resurface",
	},
}

-- Display/iteration order. A map has none, and the shop must render the same rows in the same places
-- every time or the player mis-clicks the thing they were reading. Asserted complete at Start.
local CATALOG_ORDER: { string } = { "drones", "conveyor", "smelter", "hull", "pearlDrones" }

-- The hull's certified pressure rating: what `hull` buys. Level 0 is rated for the surface tier, and
-- each plate is worth one more tier of pressure. Kept HERE (not in Depth) because the rating is a
-- property of what the player bought; which rating a given trench DEMANDS is Depth's to decide.
local BASE_HULL_RATING = 1
local HULL_RATING_PER_LEVEL = 1

-- A level read off a DataStore blob is data, not a fact. A level of 1e308 (or NaN) would otherwise
-- turn a price into inf/NaN and PERSIST it: NaN >= cost is false forever, so a poisoned balance can
-- never be spent again. Every entry's own maxLevel clamps below this; this is the outer wall.
local MAX_LEVEL_CEILING = 100000

-- ── helpers (pure) ──────────────────────────────────────────────────────────────────────────────

local function isUsableNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A real Roblox Player is USERDATA, never a table — `type(player) == "table"` is false in every live
-- server and true only in a harness that mocks players as tables (gate-reachability R6). Identity is
-- taken from the FIELD, which both a live Player and Mocks.player answer.
local function userIdOf(player: any): number?
	if player == nil then
		return nil
	end
	local userId = (player :: any).UserId
	if not isUsableNumber(userId) then
		return nil
	end
	return math.floor(userId)
end

-- The maximum level of an entry, clamped. An unknown key falls back to the outer wall.
local function maxLevelOf(key: string): number
	local entry = CATALOG[key]
	if entry == nil then
		return MAX_LEVEL_CEILING
	end
	return math.min(math.floor(entry.maxLevel), MAX_LEVEL_CEILING)
end

-- One persisted level, normalized. An absent `upgrades` map, an absent key, a non-number, a NaN or a
-- negative all collapse to 0 — which is exactly the fresh-player state Migrations seeds, so the open
-- map needs no migration and no schema bump.
local function levelOf(data: any, key: string): number
	if type(data) ~= "table" or type(data.upgrades) ~= "table" then
		return 0
	end
	local level = data.upgrades[key]
	if not isUsableNumber(level) or level < 0 then
		return 0
	end
	return math.min(math.floor(level), maxLevelOf(key))
end

-- THE PRICE, and the only place it is ever computed. Integer, finite, never below `base`, and a pure
-- function of (entry, level) — so two callers a frame apart cannot disagree and the client cannot
-- influence it at all.
local function nextCostOf(entry: CatalogEntry, currentLevel: number): number
	local level = if isUsableNumber(currentLevel) and currentLevel > 0
		then math.floor(currentLevel)
		else 0
	local cost = entry.base * entry.growth ^ level
	if not isUsableNumber(cost) then
		return math.huge -- unreachable with the catalog above; an unaffordable price, never a free one
	end
	return math.max(math.floor(entry.base), math.floor(cost + 0.5))
end

-- A balance, read READ-ONLY. Prefers ctx.economy:balanceOf so the shop and the debit agree on what a
-- balance IS; falls back to the blob so a Tier-1 spec without the seam still gets a number.
local function balanceOf(ctx: any, data: any, currency: string): number
	local economy = if ctx ~= nil then ctx.economy else nil
	if economy ~= nil and type(economy.balanceOf) == "function" then
		local ok, value = pcall(function()
			return economy:balanceOf(data, currency)
		end)
		if ok and isUsableNumber(value) then
			return value
		end
	end
	if type(data) == "table" and type(data.currencies) == "table" then
		local value = data.currencies[currency]
		if isUsableNumber(value) then
			return value
		end
	end
	return 0
end

-- A THROWAWAY blob one level higher, used ONLY to take a reading. It is a FRESH table: the live
-- session blob is never mutated by a read path — `fetch` runs OUTSIDE any ctx.data:update, so a
-- read that nudged a level would be an unlocked write on the single-writer path (CLAUDE.md §4) from
-- a client-callable action. Everything the rate function reads (resurfaces, flags, boostExpiresUnix)
-- is carried over, so the probe's reading differs from the blob's in EXACTLY the one level.
local function probeAt(data: any, key: string, level: number): any
	local upgrades: { [string]: number } = {}
	if type(data) == "table" and type(data.upgrades) == "table" then
		for existingKey, value in data.upgrades do
			if type(existingKey) == "string" and isUsableNumber(value) then
				upgrades[existingKey] = value
			end
		end
	end
	upgrades[key] = level
	local probe: any = {}
	if type(data) == "table" then
		for field, value in data do
			probe[field] = value
		end
	end
	probe.upgrades = upgrades
	return probe
end

-- ── the observables (what a purchase actually moves) ────────────────────────────────────────────

-- THE running income rate, taken through the SAME derived function the tick and `salvage.fetch` run
-- on. nil means "no seam here to ask" (a Tier-1 spec that did not install ctx.salvage), which is
-- reported as unmeasured rather than as zero — "the rate is 0" and "nobody could tell me the rate"
-- are different answers and only one of them is a defect.
local function measureRate(ctx: any, data: any): number?
	local salvage = if ctx ~= nil then ctx.salvage else nil
	if salvage == nil or type(salvage.rateFor) ~= "function" then
		return nil
	end
	local ok, value = pcall(function()
		return salvage:rateFor(data)
	end)
	if ok and isUsableNumber(value) then
		return value
	end
	return nil
end

-- The smelter's storage ceiling — and therefore the ceiling on an away-window accrual, which is what
-- makes the tank upgrade matter to a player who logs off.
local function measureCapacity(ctx: any, data: any): number?
	local salvage = if ctx ~= nil then ctx.salvage else nil
	if salvage == nil or type(salvage.capacityFor) ~= "function" then
		return nil
	end
	local ok, value = pcall(function()
		return salvage:capacityFor(data)
	end)
	if ok and isUsableNumber(value) then
		return value
	end
	return nil
end

-- THE pressure rating this blob's hull is certified for, as THIS SHOP displays it. PURE over the blob:
-- the rating is a property of what the player BOUGHT, and the kiosk sign and the buy reply render it.
--
-- IT IS NOT PROOF OF ANYTHING, and must never be used as one — see `measureHullRating` below.
function StructuresShopService.hullRatingOf(_self: any, data: any): number
	return BASE_HULL_RATING + levelOf(data, "hull") * HULL_RATING_PER_LEVEL
end

-- THE HULL'S OBSERVABLE, READ THROUGH ITS CONSUMER — never through ourselves.
--
-- This function used to be `return StructuresShopService:hullRatingOf(data)`, and that made the ONE
-- runtime guard this file builds against the written-never-read defect (`auditEffects`) incapable of
-- failing for `hull`, by construction: the "observable" was a pure function of the very `upgrades.hull`
-- key the shop writes, defined in the shop itself, so the audit compared `1` against `2`, reported
-- `moved = true` forever, and printed no warning at boot no matter whether ANYTHING in the running game
-- read the key. drones/conveyor/smelter/pearlDrones bind to `ctx.salvage`, a genuinely external reader;
-- `hull` bound to itself. A self-certifying guard is worse than no guard, because it reads as one.
--
-- `hull`'s consumer is the Depth pressure gate (DepthService, a later batch), which reads the same
-- canonical `upgrades.hull` key this shop writes. So: ask `ctx.depth`, nil-safely, and return nil —
-- UNPROVEN — when no consumer is installed. nil is reported by the audit as "nobody could tell me",
-- which is loud at boot (see Start) and is deliberately NOT counted as proof of movement.
--
-- TODO(verify): `ctx.depth:hullRatingOf(data)` is the reader this shop expects DepthService to publish
-- on its seam (today the stub publishes only `valueMultiplier` / `tierYFor`). The read is optional and
-- type-guarded, so an absent method degrades to UNPROVEN rather than throwing; when the depth feature
-- lands it should expose this (or the shop's audit will keep reporting `hull` unproven, which is the
-- honest state until it does).
local function measureHullRating(ctx: any, data: any): number?
	local depth = if ctx ~= nil then ctx.depth else nil
	if depth == nil or type(depth.hullRatingOf) ~= "function" then
		return nil
	end
	local ok, value = pcall(function()
		return depth:hullRatingOf(data)
	end)
	if ok and isUsableNumber(value) then
		return value
	end
	return nil
end

export type Effect = {
	observable: string, -- the name the reply and the shop row carry
	unit: string,
	-- The ctx seam that READS this entry's upgrade key. Named so the audit can say WHOSE answer it is
	-- missing, and so a future entry cannot quietly declare a measure that resolves inside this file.
	consumer: string,
	measure: (ctx: any, data: any) -> number?,
}

-- THE EFFECT MODEL: which server-derived observable each catalog entry moves, and the function that
-- reads it. Deliberately a SEPARATE table from the catalog, and deliberately not a comment: the
-- catalog is the price model, and this is the answer to "what does this purchase actually change",
-- which is the question 26 of collect-sim's 66 defects got wrong. It is called on three paths — the
-- shop row's current/next readings, the before/after readings inside the buy transform, and the
-- boot-time audit — so an entry can neither ship without an observable nor keep one it stopped
-- moving.
-- EVERY `measure` here resolves through a ctx SEAM (`consumer`), never through a function of this
-- file's own — that is the property that lets the audit and the buy path report an entry inert at all.
local EFFECTS: { [string]: Effect } = {
	["drones"] = {
		observable = "rate",
		unit = "Credits/s",
		consumer = "salvage",
		measure = measureRate,
	},
	["conveyor"] = {
		observable = "rate",
		unit = "Credits/s",
		consumer = "salvage",
		measure = measureRate,
	},
	["pearlDrones"] = {
		observable = "rate",
		unit = "Credits/s",
		consumer = "salvage",
		measure = measureRate,
	},
	["smelter"] = {
		observable = "capacity",
		unit = "Credits",
		consumer = "salvage",
		measure = measureCapacity,
	},
	["hull"] = {
		observable = "pressure",
		unit = "rating",
		consumer = "depth",
		measure = measureHullRating,
	},
}

export type Readings = {
	rate: number,
	capacity: number,
	hullRating: number,
	measured: boolean, -- false when ctx.salvage was absent, so a reader can tell 0 from unknown
}

-- Every observable this shop moves, read off ONE blob in one place. The buy path takes this before
-- and after the write inside the transform, so the reply carries the DELTA rather than an assertion
-- that a persisted field changed.
function StructuresShopService.readingsOf(self: any, ctx: any, data: any): Readings
	local rate = measureRate(ctx, data)
	local capacity = measureCapacity(ctx, data)
	return {
		rate = rate or 0,
		capacity = capacity or 0,
		hullRating = self:hullRatingOf(data),
		measured = rate ~= nil and capacity ~= nil,
	}
end

-- ── the catalog view (structures.fetch) ─────────────────────────────────────────────────────────

export type EntryEffect = {
	observable: string,
	unit: string,
	current: number,
	next: number, -- what the observable reads one level higher
	delta: number,
	measured: boolean,
}

export type EntryView = {
	key: string,
	label: string,
	blurb: string,
	currency: string,
	level: number,
	maxLevel: number,
	maxed: boolean,
	nextCost: number, -- SERVER-DERIVED. The client holds no price constants at all.
	balance: number,
	affordable: boolean,
	effect: EntryEffect,
}

export type ShopView = {
	entries: { EntryView },
	currencies: { [string]: number },
	rate: number,
	capacity: number,
	hullRating: number,
	measured: boolean,
}

-- One row, entirely server-computed. `nextCost` and `affordable` are the server's answers; the
-- client is free to grey a row out on its own reading of the balance, but the buy path re-decides
-- both inside the lock-held transform and never consults either of these.
function StructuresShopService.describeEntry(
	_self: any,
	ctx: any,
	data: any,
	key: string
): EntryView?
	local entry = CATALOG[key]
	local effect = EFFECTS[key]
	if entry == nil or effect == nil then
		return nil
	end
	local level = levelOf(data, key)
	local maxLevel = maxLevelOf(key)
	local maxed = level >= maxLevel
	local balance = balanceOf(ctx, data, entry.currency)
	local nextCost = if maxed then 0 else nextCostOf(entry, level)

	-- The effect pair, taken through the SAME functions the running server uses: once at the level
	-- THIS FILE SAYS the player owns, once one level higher. A row therefore cannot advertise a change
	-- the gameplay code does not produce — the number it shows IS the number the game would compute.
	--
	-- BOTH READINGS GO THROUGH `probeAt`, AND THAT IS THE POINT. `current` used to be measured on the
	-- RAW blob while `next` was measured on a probe clamped to `maxLevel`, so the pair only described
	-- one level's difference while the persisted byte agreed with this file's clamp. A poisoned,
	-- legacy or mis-migrated `upgrades.drones = 1e308` reads as 25 here and as its own 10000-wide clamp
	-- in SalvageService, and the row then advertised `current` = the rate for a 10000-drone fleet
	-- against `next` = the rate for 25 — a NEGATIVE delta on an upgrade, i.e. the shop telling the
	-- player that buying more drones would slow them down. Probing both ends normalizes the ONE thing
	-- this file is the authority on (what a level means) and leaves the pair differing in exactly the
	-- one level, which is what the row claims to show. It is a no-op on every honest blob.
	local current = effect.measure(ctx, probeAt(data, key, level))
	local nextReading = effect.measure(ctx, probeAt(data, key, math.min(level + 1, maxLevel)))
	local measured = current ~= nil and nextReading ~= nil

	return {
		key = key,
		label = entry.label,
		blurb = entry.blurb,
		currency = entry.currency,
		level = level,
		maxLevel = maxLevel,
		maxed = maxed,
		nextCost = nextCost,
		balance = balance,
		affordable = not maxed and balance >= nextCost,
		effect = {
			observable = effect.observable,
			unit = effect.unit,
			current = current or 0,
			next = nextReading or 0,
			delta = (nextReading or 0) - (current or 0),
			measured = measured,
		},
	}
end

-- The whole shop, in catalog order. PURE over the blob + the ctx seams: it writes nothing, grants
-- nothing and stamps nothing. A read surface that could mutate would make the shop's own prices
-- depend on how often the UI refreshed.
function StructuresShopService.describe(self: any, ctx: any, data: any): ShopView
	local entries: { EntryView } = {}
	local currencies: { [string]: number } = {}
	for _, key in CATALOG_ORDER do
		local row = self:describeEntry(ctx, data, key)
		if row ~= nil then
			table.insert(entries, row)
			currencies[row.currency] = row.balance
		end
	end
	local readings = self:readingsOf(ctx, data)
	return {
		entries = entries,
		currencies = currencies,
		rate = readings.rate,
		capacity = readings.capacity,
		hullRating = readings.hullRating,
		measured = readings.measured,
	}
end

function StructuresShopService.fetch(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil then
		return Result.err(Result.Codes.Internal, "structures: context is missing data")
	end
	local got = ctx.data:get(ctx.player)
	if not got.ok then
		-- NoData until loadSession resolves; the client's JoinRetry guard re-issues past it.
		return got
	end
	return Result.ok(self:describe(ctx, got.value))
end

-- ── the purchase (structures.buy) ───────────────────────────────────────────────────────────────

export type BuyInfo = {
	key: string,
	label: string,
	currency: string,
	cost: number, -- what was actually debited, derived under the lock
	level: number, -- the level AFTER this purchase
	maxLevel: number,
	maxed: boolean,
	nextCost: number, -- what the NEXT one will cost, off the level just written
	balance: number, -- the post-debit balance, as EconomyService computed it
	-- The DELTA, taken before and after the write INSIDE the one transform. This is the
	-- "each purchase visibly changes the income rate" criterion, answered with two readings of a
	-- derived value rather than with a persisted field that moved.
	observable: string,
	effectBefore: number,
	effectAfter: number,
	effectDelta: number,
	rateBefore: number,
	rate: number,
	capacityBefore: number,
	capacity: number,
	hullRatingBefore: number,
	hullRating: number,
	measured: boolean,
}

-- THE purchase. Everything that decides anything happens INSIDE the transform, on the snapshot the
-- per-player FIFO lock just handed us — see the concurrency argument in the header. `buy` itself
-- computes no level, no price and no balance before the update, so there is nothing stale for an
-- interleaved request to race.
function StructuresShopService.buy(self: any, ctx: any, key: string): any
	if ctx == nil or ctx.data == nil then
		return Result.err(Result.Codes.Internal, "structures: context is missing data")
	end
	local entry = CATALOG[key]
	local effect = EFFECTS[key]
	if entry == nil or effect == nil then
		-- Defensive; `validate` already refused anything not in the catalog.
		return Result.err(Result.Codes.BadPayload, `structures: "{tostring(key)}" is not for sale`)
	end
	local player = ctx.player
	if userIdOf(player) == nil then
		return Result.err(Result.Codes.BadType, "structures: player has no numeric UserId")
	end
	local economy = ctx.economy
	if economy == nil or type(economy.spend) ~= "function" then
		-- ctx.economy is THE enforcement point for the balance guard, the never-negative rule and the
		-- currency_spent emit. Debiting around it would hand-roll all three, so an absent seam is a
		-- refusal — never a fall-through to writing data.currencies directly.
		return Result.err(
			Result.Codes.Internal,
			"structures: ctx.economy is not installed — debiting here would skip the balance guard "
				.. "and the currency_spent event"
		)
	end

	local outcome: any = nil

	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "structures: data blob is not a table")
			return data
		end
		-- Repair the open map under the lock, so every path below can assume a table. An absent
		-- `upgrades` is a legitimate blob state (the map is open and needs no migration).
		if type(data.upgrades) ~= "table" then
			data.upgrades = {}
		end

		-- READ THE LEVEL OFF THIS SNAPSHOT — never from before the yield. A spam-duplicated buy that
		-- got here second sees the level the first one wrote and is priced off THAT.
		local level = levelOf(data, key)
		local maxLevel = maxLevelOf(key)

		-- AND REPAIR THE BYTE THIS CLAMP JUST REINTERPRETED. A level read off a DataStore is data, not
		-- a fact, and `levelOf` has always clamped it — but only for the READING. The persisted byte
		-- survived untouched, so a hacked, legacy or mis-migrated `upgrades.drones = 1e308` (a usable
		-- number: only NaN and ±inf are refused) reads as this catalog's maxLevel here, takes the
		-- `level >= maxLevel` branch below, and returns BEFORE the only write in this file — bricking
		-- the entry as permanently maxed forever, while SalvageService's own, WIDER clamp goes on
		-- pricing a 10000-level fleet. Two authorities describing different fleets off one blob, and
		-- no path that ever converges them.
		--
		-- So: this file is THE authority on what its own key means, and it now says so in the store.
		-- This is the ONE lock-held transform on the snapshot the per-player FIFO lock just handed
		-- over (CLAUDE.md §4), which is the only place a repair is legal — `fetch` is a read surface
		-- and must never write. It is a no-op on every honest blob (an absent key stays absent, and a
		-- level that already equals its clamp is not rewritten), so it cannot seed a key nobody bought.
		local persisted = data.upgrades[key]
		if persisted ~= nil and persisted ~= level then
			data.upgrades[key] = level
		end
		if level >= maxLevel then
			-- A NON-CURRENCY refusal: the balance is irrelevant, the entry is finished. Deliberately
			-- not Insufficient (which would make "I cannot afford it" and "there is nothing left to
			-- buy" the same string) and not OutOfRange (the PAYLOAD was in range; the STATE is at cap).
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`structures: {key} is already at its maximum level ({maxLevel})`
			)
			return data
		end
		local cost = nextCostOf(entry, level)

		-- The readings BEFORE the purchase, off this very snapshot.
		local before = self:readingsOf(ctx, data)
		local effectBefore = effect.measure(ctx, data)

		-- NO PURCHASABLE SHIPS INERT — ENFORCED HERE, ON THE LIVE SNAPSHOT, not merely printed once at
		-- boot. Take this entry's observable through its CONSUMER now and one level higher: if the
		-- consumer answers and the reading does NOT move, this purchase would take the player's Credits
		-- and change nothing the running game can see. There is no refund and no downgrade anywhere in
		-- this game, so the Credits would be destroyed permanently — refuse instead.
		--
		-- PrereqUnmet, not Insufficient (the balance is fine) and not BadPayload (the request was
		-- well-formed): the SERVER is not currently able to deliver what this row promises.
		--
		-- AN UNMEASURED READING IS REFUSED TOO, and that is the correction the economy red-team forced.
		-- "The consumer answers and does not move" and "no consumer answers at all" are different
		-- DIAGNOSES, and this transform can tell them apart — but they are the SAME CONSEQUENCE for the
		-- player: a currency debited for a number the running game cannot observe. `hull` shipped as
		-- exactly the second case. Its declared consumer (ctx.depth) is not installed by anything in
		-- this game yet, so `grep -rn 'upgrades.hull' src` hits nothing outside this file, and the buy
		-- path let the sale through on the reasoning that absence "might just be a Tier-1 harness". It
		-- charged 400 Credits, then 720, then 1,296 — geometric, irreversible, with no refund and no
		-- downgrade anywhere in this game — for a key with no reader. Reporting that at boot does not
		-- give the Credits back; the boot audit does not hold the player's balance.
		--
		-- So an entry is DEBITABLE only while somebody outside this file can be SEEN reading what it
		-- writes. A harness that installs no seam gets a refusal, which is the correct answer there too:
		-- in THAT process nothing reads the key either. The entry stays catalogued, priced and
		-- described (the row still renders with `effect.measured = false`), and it starts selling again
		-- by itself the moment its consumer lands — no catalog edit, no re-tuning.
		if effectBefore == nil then
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`structures: nothing in this server reads what {key} buys — ctx.{effect.consumer} is `
					.. `not installed, so its declared observable "{effect.observable}" cannot be `
					.. "measured at all. Selling it would debit a real currency, with no refund and no "
					.. "downgrade, for a value the running game cannot see"
			)
			return data
		end
		local effectProbe = effect.measure(ctx, probeAt(data, key, level + 1))
		if effectProbe == nil or effectProbe == effectBefore then
			outcome = Result.err(
				Result.Codes.PrereqUnmet,
				`structures: buying {key} would not move its declared observable `
					.. `"{effect.observable}" ({effectBefore} -> {tostring(effectProbe)}) — `
					.. `ctx.{effect.consumer} is no longer reading it, so this purchase would cost `
					.. "Credits and change nothing"
			)
			return data
		end

		-- WRITE THE LEVEL FIRST, DEBIT LAST. The debit has to be the transform's final mutation
		-- (EconomyService emits currency_spent as its last act, so nothing after it may throw and
		-- discard a snapshot the event already described). `previous` is captured so a refused debit
		-- restores EXACTLY what was there — including nil, which restores absence.
		local previous = data.upgrades[key]
		data.upgrades[key] = level + 1

		local debit = economy:spend(data, entry.currency, cost, `structure.{key}`)
		if not debit.ok then
			-- Insufficient (the balance did not cover it) or a seam refusal. `spend` is
			-- atomic-or-nothing, so nothing was debited; roll the level back and surface the Err
			-- as-is rather than dressing a refusal up as a purchase.
			data.upgrades[key] = previous
			outcome = debit
			return data
		end

		-- Everything from here is a READ of the committed snapshot. pcall'd as a block: a throwing
		-- seam must not discard a transform whose currency_spent has already been emitted.
		local newLevel = level + 1
		local ok, info = pcall(function(): BuyInfo
			local after = self:readingsOf(ctx, data)
			local effectAfter = effect.measure(ctx, data)
			local maxedNow = newLevel >= maxLevel
			return {
				key = key,
				label = entry.label,
				currency = entry.currency,
				cost = cost,
				level = newLevel,
				maxLevel = maxLevel,
				maxed = maxedNow,
				nextCost = if maxedNow then 0 else nextCostOf(entry, newLevel),
				balance = debit.value.balance,
				observable = effect.observable,
				effectBefore = effectBefore or 0,
				effectAfter = effectAfter or 0,
				effectDelta = (effectAfter or 0) - (effectBefore or 0),
				rateBefore = before.rate,
				rate = after.rate,
				capacityBefore = before.capacity,
				capacity = after.capacity,
				hullRatingBefore = before.hullRating,
				hullRating = after.hullRating,
				measured = before.measured and after.measured and effectAfter ~= nil,
			}
		end)
		if ok then
			outcome = Result.ok(info)
		else
			-- THE PURCHASE STANDS: it is written into this snapshot and the debit is done, and this
			-- transform is about to commit both. So the reply degrades — it reports the purchase with
			-- `measured = false` — and it does NOT become an Err. Returning Err(Internal) here would
			-- tell a player their committed, paid-for purchase failed, which is the exact defect the
			-- salvage merge produced (an unguarded post-write step turning a committed economy write
			-- into Err(Internal), docs/LEARNINGS.md). Only the REPORTING can fail here; the
			-- transaction cannot.
			local maxedNow = newLevel >= maxLevel
			outcome = Result.ok({
				key = key,
				label = entry.label,
				currency = entry.currency,
				cost = cost,
				level = newLevel,
				maxLevel = maxLevel,
				maxed = maxedNow,
				nextCost = if maxedNow then 0 else nextCostOf(entry, newLevel),
				balance = debit.value.balance,
				observable = effect.observable,
				effectBefore = effectBefore or 0,
				effectAfter = effectBefore or 0,
				effectDelta = 0,
				rateBefore = before.rate,
				rate = before.rate,
				capacityBefore = before.capacity,
				capacity = before.capacity,
				hullRatingBefore = before.hullRating,
				hullRating = before.hullRating,
				measured = false,
			} :: BuyInfo)
		end
		return data
	end

	-- pcall'd so a data-layer throw cannot escape as an exception; DataService already pcalls the
	-- transform, so anything caught here came from the data layer itself.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		return Result.err(Result.Codes.Internal, "structures: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, SessionClosed, ...
		-- The snapshot was discarded, so NOTHING was persisted: no level, no debit.
		return written
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"structures: the update reported success but the transform produced no outcome"
		)
	end

	-- The view push and the kiosk repaint are DERIVED from a committed write, come after it, and can
	-- never undo it: both guarded and pcall'd, their results discarded. An unguarded post-write push
	-- is how a committed economy write once came back to the client as Err(Internal)
	-- (docs/LEARNINGS.md).
	if outcome.ok then
		pcall(function()
			self:pushView(self._context, player)
		end)
		pcall(function()
			self:syncWorld(self._context, player)
		end)
	end
	return outcome
end

-- ── the boot-time inert audit ───────────────────────────────────────────────────────────────────

export type EffectAudit = {
	key: string,
	observable: string,
	consumer: string, -- the ctx seam that was asked
	measured: boolean,
	current: number,
	next: number,
	moved: boolean,
	-- `measured == false`: the declared consumer is not installed, so NOBODY in this process reads the
	-- key this entry writes. Not proof of inertness — and, crucially, not proof of anything else
	-- either. Broken out as its own field so Start can say it out loud rather than pass silently.
	unproven: boolean,
}

-- A minimal blob to audit against: no upgrades, no flags, no prestige. Deliberately synthetic and
-- deliberately NOT a player's — the question "does buying this move anything at all" must have the
-- same answer on every server, not one that depends on who happens to be logged in.
function StructuresShopService.referenceBlob(_self: any): any
	return {
		schemaVersion = Types.CURRENT_SCHEMA_VERSION,
		currencies = { Credits = 0, Pearls = 0 },
		stats = { playtimeSeconds = 0, joinCount = 0, lifetimeCredits = 0 },
		timestamps = { firstJoinUnix = 0, lastSeenUnix = 0 },
		plot = { plotId = "", claimedAtUnix = 0 },
		smelter = { storedCredits = 0, lastTickUnix = 0 },
		daily = { streak = 0, lastClaimUnix = 0 },
		resurfaces = 0,
		boostExpiresUnix = 0,
		upgrades = {},
		flags = {},
		receipts = {},
	}
end

-- RE-RUN THE WHOLE EFFECT MATRIX. For each catalog entry: read its observable on the reference blob,
-- read it again one level higher, and report whether it MOVED. This is the "no purchasable ships
-- inert" criterion as a runtime check rather than as a test somebody has to remember to write — the
-- defect it guards against (a level that increments while the reading stays flat) is invisible to
-- every test that asserts the persisted field.
--
-- `measured = false` means ctx.salvage was not installed, which is a Tier-1 harness talking, not a
-- defect: it is reported, never counted as inert.
function StructuresShopService.auditEffects(self: any, ctx: any, data: any?): { EffectAudit }
	local blob = if data ~= nil then data else self:referenceBlob()
	local report: { EffectAudit } = {}
	for _, key in CATALOG_ORDER do
		local effect = EFFECTS[key]
		if effect ~= nil then
			local level = levelOf(blob, key)
			local current = effect.measure(ctx, blob)
			local nextReading =
				effect.measure(ctx, probeAt(blob, key, math.min(level + 1, maxLevelOf(key))))
			local measured = current ~= nil and nextReading ~= nil
			table.insert(report, {
				key = key,
				observable = effect.observable,
				consumer = effect.consumer,
				measured = measured,
				current = current or 0,
				next = nextReading or 0,
				moved = measured and (nextReading :: number) ~= (current :: number),
				unproven = not measured,
			})
		end
	end
	return report
end

-- Every catalog key must appear in the render order exactly once, and vice versa. A key missing from
-- the order is a purchasable the shop never lists (bought by nobody, and green in every test that
-- iterates the catalog); a key in the order that is not in the catalog renders an empty row.
function StructuresShopService.assertCatalogOrder(_self: any): ()
	local seen: { [string]: boolean } = {}
	for _, key in CATALOG_ORDER do
		if CATALOG[key] == nil then
			error(`StructuresShopService: CATALOG_ORDER names "{key}", which is not in the catalog`)
		end
		if seen[key] then
			error(`StructuresShopService: CATALOG_ORDER names "{key}" twice`)
		end
		seen[key] = true
	end
	for key in CATALOG do
		if not seen[key] then
			error(
				`StructuresShopService: catalog entry "{key}" is in no render order — the shop would `
					.. "never list it, and nobody could buy it"
			)
		end
		local effect = EFFECTS[key]
		if effect == nil then
			error(
				`StructuresShopService: catalog entry "{key}" declares no effect — a purchasable with `
					.. "no observable is inert by construction"
			)
		end
		-- The observable must be somebody ELSE'S reading. An entry whose measure resolves inside this
		-- file certifies itself: the audit compares the shop's own arithmetic against the shop's own
		-- arithmetic, reports `moved` forever, and goes silent about the one thing it was built to
		-- catch. `hull` shipped exactly that way.
		if type(effect.consumer) ~= "string" or #effect.consumer == 0 then
			error(
				`StructuresShopService: catalog entry "{key}" names no consumer seam — an observable `
					.. "this file measures with its own function can never report inert, so the audit "
					.. "would certify the entry against itself"
			)
		end
	end
end

-- ── the actions ─────────────────────────────────────────────────────────────────────────────────

-- THE PAYLOAD CARRIES A CATALOG KEY AND NOTHING ELSE. Every name below is a price, a quantity, an
-- identity or a balance the SERVER derives, and a payload that carries one is REFUSED rather than
-- ignored: a client-supplied cost is the classic shop exploit, and silently dropping it makes a
-- probe indistinguishable from an honest request.
local FORBIDDEN_PAYLOAD_KEYS = {
	"cost",
	"price",
	"amount",
	"value",
	"currency",
	"level",
	"levels",
	"nextCost",
	"quantity",
	"count",
	"balance",
	"credits",
	"Credits",
	"pearls",
	"Pearls",
	"discount",
	"free",
	"rate",
	"capacity",
	"hullRating",
	"userId",
	"plotId",
	"player",
	"target",
}

-- Longest key the catalog could ever hold, with room to spare. A bound on the string BEFORE it is
-- used in a message keeps a megabyte payload from being echoed back through the log.
local MAX_KEY_LENGTH = 64

local function validateBuy(rawPayload: any): any
	if type(rawPayload) ~= "table" then
		return Result.err(Result.Codes.BadType, "payload must be a table")
	end
	for _, forbidden in FORBIDDEN_PAYLOAD_KEYS do
		if rawPayload[forbidden] ~= nil then
			return Result.err(
				Result.Codes.BadPayload,
				`structures.buy takes only a catalog key — the SERVER derives the price, the level `
					.. `and the balance (rejected key "{forbidden}")`
			)
		end
	end
	local key = rawPayload.key
	if type(key) ~= "string" then
		return Result.err(Result.Codes.BadPayload, "payload.key must be a catalog key string")
	end
	if #key == 0 or #key > MAX_KEY_LENGTH then
		return Result.err(Result.Codes.BadPayload, "payload.key is not a plausible catalog key")
	end
	if CATALOG[key] == nil then
		-- An unknown key is a MALFORMED PAYLOAD, not an out-of-range number: the catalog is the whole
		-- domain of this field, and a key outside it never named anything.
		return Result.err(Result.Codes.BadPayload, `structures: "{key}" is not in the catalog`)
	end
	-- A FRESH table: the handler is not merely disciplined about ignoring client data, it is never
	-- handed any beyond the one key it needs.
	return Result.ok({ key = key })
end

local function validateNoArguments(rawPayload: any): any
	if rawPayload == nil then
		return Result.ok({})
	end
	if type(rawPayload) ~= "table" then
		return Result.err(Result.Codes.BadType, "payload must be a table or nil")
	end
	for _, forbidden in FORBIDDEN_PAYLOAD_KEYS do
		if rawPayload[forbidden] ~= nil then
			return Result.err(
				Result.Codes.BadPayload,
				`structures.fetch takes no arguments — the SERVER derives every price and every `
					.. `reading (rejected key "{forbidden}")`
			)
		end
	end
	return Result.ok({})
end

StructuresShopService.validateBuy = validateBuy
StructuresShopService.validateFetch = validateNoArguments

-- Exported so a Tier-1 spec can register the actions on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as CLOSURES over the service so the handler reaches
-- this instance's captured context (the kiosk repaint needs the SERVER context, which the
-- ActionContext projection does not carry).
function StructuresShopService.buyAction(self: any): any
	return {
		name = Net.Actions.BuyStructure,
		validate = validateBuy,
		-- PRESERVED FROM THE CONTRACT-PASS STUB: generous enough to buy several levels in a burst,
		-- bounded so a spam flood is refused by the Gate before it reaches the economy's
		-- single-writer path.
		rate = { maxPerWindow = 5, windowSeconds = 1.0 },
		handler = function(ctx: any, payload: any): any
			return self:buy(ctx, payload.key)
		end,
	}
end

function StructuresShopService.fetchAction(self: any): any
	return {
		name = Net.Actions.FetchStructures,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB.
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(ctx: any, _payload: any): any
			return self:fetch(ctx)
		end,
	}
end

-- Push the refreshed client view after a committed purchase, so the HUD's balances and
-- `view.upgrades` describe the state the player just bought rather than the state they joined with.
-- `context` is the SERVER context (the ActionContext projection carries no net). Every caller
-- ignores the return value: a presentation failure must never turn a granted purchase into an error.
function StructuresShopService.pushView(_self: any, context: any, player: any): boolean
	if context == nil then
		return false
	end
	local net = context.net
	if net == nil or type(net.fireClient) ~= "function" or context.data == nil then
		return false
	end
	-- THE WHOLE READ-THEN-FIRE BLOCK IS GUARDED, not just the fire. `context.data` is a SEAM — the
	-- bootstrap decides what answers `get` here — and this runs AFTER the transform committed the
	-- level and after ctx.economy:spend debited and emitted currency_spent. A throw on the READ would
	-- escape `buy`'s post-write step, and Net.dispatch converts any throw out of a handler into
	-- Err(Internal) (src/shared/Net.luau), telling a player their paid, persisted purchase failed:
	-- exactly the defect the salvage merge produced (docs/LEARNINGS.md). It was benign only because
	-- the one implementation currently behind this seam (DataService.get) happens to be a pure table
	-- read — the transaction was protected by its callee rather than by this file.
	local ok, fired = pcall(function(): boolean
		local got = context.data:get(player)
		if type(got) ~= "table" or got.ok ~= true then
			return false -- NoData (the session is not loaded): nothing to describe, not an error
		end
		net:fireClient(player, "data", Types.toView(got.value))
		return true
	end)
	return ok and fired
end

-- ── the world (greybox kiosk) ───────────────────────────────────────────────────────────────────
-- ROBLOX-ONLY, every entry point guarded. Art posture: "100% greybox-in-code for v1". COSMETIC ONLY:
-- nothing built here is read back by any rule, so a client that deleted or moved the whole kiosk
-- would change no number on the server. The shop is bought through the gateway, never by touching a
-- part.

local KIOSK_NAME = "StructuresKiosk"
local SIGN_NAME = "Sign"
local SIGN_LABEL_NAME = "SignLabel"
-- Layout, in studs, relative to the dome root's pivot. Parked clear of SalvageService's rig (which
-- runs along the X axis between its wreck at -22 and its smelter at +18).
local KIOSK_OFFSET_Z = -20
local KIOSK_HEIGHT = 4

local function robloxRefs(): (any, any, any, any)
	local instanceGlobal: any = Instance
	local vector3Global: any = Vector3
	local color3Global: any = Color3
	local enumGlobal: any = Enum
	return instanceGlobal, vector3Global, color3Global, enumGlobal
end

-- The two GUI globals, reached through the same guarded-local discipline: both are real in Roblox
-- and NIL under Lune, and a bare reference to one at module scope would make this file unrequirable
-- in a spec.
local function guiRefs(): (any, any)
	local udim2Global: any = UDim2
	local vector2Global: any = Vector2
	return udim2Global, vector2Global
end

local function rootPosition(root: any): any
	local vector3Global: any = Vector3
	if vector3Global == nil then
		return nil
	end
	local ok, position = pcall(function()
		return root:GetPivot().Position
	end)
	if ok and position ~= nil then
		return position
	end
	return vector3Global.new(0, 0, 0)
end

-- Find-or-create the kiosk under this player's dome root. IDEMPOTENT and cheap on the common path
-- (one FindFirstChild), because it runs on every join poll and after every purchase.
function StructuresShopService.buildKiosk(_self: any, root: any): any
	local instanceGlobal, vector3Global, color3Global, enumGlobal = robloxRefs()
	if
		instanceGlobal == nil
		or vector3Global == nil
		or color3Global == nil
		or enumGlobal == nil
		or root == nil
	then
		return nil
	end
	local udim2Global, vector2Global = guiRefs()
	if udim2Global == nil or vector2Global == nil then
		return nil
	end
	local existing = root:FindFirstChild(KIOSK_NAME)
	if existing ~= nil then
		return existing
	end
	local origin = rootPosition(root)
	if origin == nil then
		return nil
	end

	local kiosk = instanceGlobal.new("Folder")
	kiosk.Name = KIOSK_NAME

	local console = instanceGlobal.new("Part")
	console.Name = "Console"
	console.Anchored = true
	console.CanCollide = true
	console.Size = vector3Global.new(10, 4, 3)
	console.Position = origin + vector3Global.new(0, KIOSK_HEIGHT, KIOSK_OFFSET_Z)
	console.Color = color3Global.fromRGB(40, 52, 62)
	console.Material = enumGlobal.Material.DiamondPlate
	console.Parent = kiosk

	local sign = instanceGlobal.new("Part")
	sign.Name = SIGN_NAME
	sign.Anchored = true
	sign.CanCollide = false
	sign.Size = vector3Global.new(10, 5, 0.4)
	sign.Position = origin + vector3Global.new(0, KIOSK_HEIGHT + 4.5, KIOSK_OFFSET_Z)
	sign.Color = color3Global.fromRGB(16, 26, 34)
	sign.Material = enumGlobal.Material.SmoothPlastic
	sign.Parent = kiosk

	local glow = instanceGlobal.new("PointLight")
	glow.Name = "KioskGlow"
	glow.Color = color3Global.fromRGB(64, 226, 255)
	glow.Range = 20
	glow.Brightness = 2
	glow.Parent = sign

	-- -- TODO(verify): a SurfaceGui with Face = Enum.NormalId.Front renders on the +Z face of the
	-- part. If it faces the wrong way the consequence is a sign readable from the far side and
	-- nothing else — every number on it is also on the HUD panel.
	local surface = instanceGlobal.new("SurfaceGui")
	surface.Name = "SignGui"
	surface.Face = enumGlobal.NormalId.Front
	surface.CanvasSize = vector2Global.new(400, 200)
	surface.Parent = sign

	local label = instanceGlobal.new("TextLabel")
	label.Name = SIGN_LABEL_NAME
	label.BackgroundTransparency = 1
	label.Size = udim2Global.new(1, 0, 1, 0)
	label.Font = enumGlobal.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = color3Global.fromRGB(64, 226, 255)
	label.Text = "STRUCTURES"
	label.Parent = surface

	kiosk.Parent = root
	return kiosk
end

-- Repaint the kiosk sign from the PERSISTED facts. Roblox-only and pcall'd by its callers; a nil
-- dome root (the player holds no dome yet) is a NORMAL state and returns false, never an error.
function StructuresShopService.syncWorld(self: any, context: any, player: any): boolean
	local instanceGlobal: any = Instance
	if instanceGlobal == nil then
		return false -- Lune: no engine to draw into
	end
	if context == nil or context.data == nil then
		return false
	end
	local plot = context.plot
	if plot == nil or type(plot.rootFor) ~= "function" then
		return false
	end
	local root = plot:rootFor(player)
	if root == nil then
		return false -- holds no dome yet: normal, not an error
	end
	local got = context.data:get(player)
	if type(got) ~= "table" or got.ok ~= true then
		return false
	end
	local kiosk = self:buildKiosk(root)
	if kiosk == nil then
		return false
	end
	local sign = kiosk:FindFirstChild(SIGN_NAME)
	local surface = if sign ~= nil then sign:FindFirstChild("SignGui") else nil
	local label = if surface ~= nil then surface:FindFirstChild(SIGN_LABEL_NAME) else nil
	if label == nil then
		return false
	end

	local data = got.value
	local owned = 0
	for _, key in CATALOG_ORDER do
		owned += levelOf(data, key)
	end
	local readings = self:readingsOf(context, data)
	label.Text = string.format(
		"STRUCTURES\n%d built · %.1f/s\nhull rated %d",
		math.floor(owned),
		readings.rate,
		math.floor(readings.hullRating)
	)
	return true
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Which audit sentences this PROCESS has already said. See Start.
local AUDIT_ANNOUNCED: { [string]: boolean } = {}

StructuresShopService._context = nil :: any
StructuresShopService._audit = {} :: { EffectAudit }
StructuresShopService._running = false
StructuresShopService._connections = {} :: { any }
StructuresShopService.loadWaitAttempts = 200
StructuresShopService.loadWaitStepSeconds = 0.25

-- Start: capture the context (the buy path's post-write push and the kiosk need the SERVER context,
-- which the ActionContext projection does not carry), assert the catalog is internally complete,
-- register the wire surface, run the inert audit, then — Roblox only — hook the join path.
-- Lune-callable: everything engine-shaped lives behind startRuntime.
function StructuresShopService.Start(self: any, context: any): ()
	self._context = context
	self:assertCatalogOrder()
	context.net:register(self:buyAction())
	context.net:register(self:fetchAction())

	-- The inert audit is a REPORT, not a boot gate: refusing to boot over it would take the whole game
	-- down for a shop row. The BUY PATH is the gate — it re-runs the same measurement on the live
	-- snapshot and refuses BOTH failing states before any Credits move. This loop exists so an entry
	-- the till has quietly stopped selling is still SAID OUT LOUD once per server, rather than being
	-- discovered one refused player at a time:
	--   INERT    — the consumer answers and does not move. The print names the entry so it can be
	--              pulled from the catalog rather than merely refused forever.
	--   UNPROVEN — the declared consumer is not installed at all, so nothing in this process reads the
	--              key this entry writes. Previously SILENT for `hull`, because its observable resolved
	--              inside this very file and therefore always "moved"; then merely printed, while the
	--              shop went on charging for it. Now it is printed AND refused.
	-- Once per PROCESS, not once per Start: a spec that stands the shop up forty times would otherwise
	-- bury its own output, and a restart loop in Studio would bury the log. The machine-readable rows
	-- stay on `self._audit` either way, so nothing is lost by not repeating the sentence.
	self._audit = self:auditEffects(context, nil)
	for _, row in self._audit do
		local announced = `{row.key}:{if row.measured then "inert" else "unproven"}`
		if AUDIT_ANNOUNCED[announced] then
			continue
		end
		AUDIT_ANNOUNCED[announced] = true
		if row.measured and not row.moved then
			print(
				`[structures] INERT ENTRY "{row.key}": buying it does not move its declared `
					.. `observable "{row.observable}" ({row.current} -> {row.next}). Players would pay `
					.. "for nothing."
			)
		elseif row.unproven then
			print(
				`[structures] UNPROVEN ENTRY "{row.key}": nothing in this server reads what it buys — `
					.. `ctx.{row.consumer} is not installed, so its declared observable `
					.. `"{row.observable}" cannot be measured at all. It is on sale, it is priced in a `
					.. "real currency, and there is no refund."
			)
		end
	end

	self:startRuntime(context)
end

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable. A spec can replace it to drive the join hook without sleeping.
function StructuresShopService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- Bounded wait for this player's session AND their dome, then draw the kiosk. Both yields are real:
-- loadSession yields, and PlotService's join claim yields after it, so the dome root does not exist
-- for a while after the blob does. Returns whether the kiosk was actually drawn.
function StructuresShopService.buildOnJoin(self: any, context: any, player: any): boolean
	for attempt = 1, self.loadWaitAttempts do
		if self:syncWorld(context, player) then
			return true
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return false
end

-- ROBLOX-ONLY: the join hook. There is no tick here — the kiosk is repainted on join and after every
-- purchase, which are the only two moments its numbers can change.
function StructuresShopService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return -- Lune: no engine to wire. Specs drive buy / fetch / describe directly.
	end
	if self._running then
		return -- idempotent: a second Start must not run two join hooks
	end
	self._running = true
	self._connections = {}

	local Players = realGame:GetService("Players")

	local function onAdded(player: any): ()
		self:buildOnJoin(context, player)
	end

	-- Players already present (a Studio Play session installs scripts after the local player joins).
	-- Spawned: buildOnJoin yields and the bootstrap must not block on it.
	for _, player in Players:GetPlayers() do
		realTask.spawn(onAdded, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: any)
			realTask.spawn(onAdded, player)
		end)
	)
end

function StructuresShopService.Stop(self: any, _context: any): ()
	self._running = false
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
	self._context = nil
end

-- Exposed for Tier-1: the catalog and its order are SERVER facts, and a spec asserts against them
-- rather than re-declaring prices of its own (which would only prove the spec agrees with itself).
StructuresShopService.CATALOG = CATALOG
StructuresShopService.CATALOG_ORDER = CATALOG_ORDER
StructuresShopService.EFFECTS = EFFECTS
StructuresShopService.BASE_HULL_RATING = BASE_HULL_RATING
StructuresShopService.HULL_RATING_PER_LEVEL = HULL_RATING_PER_LEVEL
-- Method-shaped (`self:` first), like every other public entry point on this table, so a caller can
-- never lose an argument to the colon.
function StructuresShopService.nextCostOf(_self: any, entry: CatalogEntry, level: number): number
	return nextCostOf(entry, level)
end

function StructuresShopService.levelOf(_self: any, data: any, key: string): number
	return levelOf(data, key)
end

-- ── KNOWN LIMITATIONS (stated here so the gate is not surprised) ────────────────────────────────
--  * `hull` IS CATALOGUED AND PRICED, AND CURRENTLY UNBUYABLE ON A REAL SERVER — deliberately.
--    DepthService is still a contract-pass stub (its descend handler returns Err(Internal, "stub"),
--    its seam is pure identity defaults and publishes no `hullRatingOf`), so nothing in this game
--    reads `upgrades.hull`. Until that lands, `structures.buy("hull")` returns Err(PrereqUnmet) and
--    debits NOTHING; the boot audit prints UNPROVEN; `structures.fetch` still sends the row, with
--    `effect.measured = false`, so the client renders the blurb instead of a fake delta. That is the
--    honest state: the row is a promise the server cannot currently keep, and the one thing it must
--    never do is take an irreversible payment for it. WITHDRAWING the row from CATALOG_ORDER is still
--    not this file's call (the slice keeps `hull` in the catalog and the gate asserts it is priced and
--    described), and it is no longer needed to protect the player. When DepthService publishes a
--    reader of `upgrades.hull` on ctx.depth, `hull` starts selling again with no edit here.
--  * The refusal is symmetric by design: an entry whose consumer answers and does not move, and an
--    entry whose consumer is absent entirely, are different diagnoses (the audit reports them
--    separately) with the same consequence for the player, so both refuse. A Tier-1 harness that
--    installs no seam therefore cannot buy anything — which is correct there too: in that process
--    nothing reads the key either.
--  * There is no refund and no downgrade. Levels only go up; the resurface wipe (which clears every
--    key here except `pearlDrones`) belongs to ResurfaceService and is not implemented in this file.
return StructuresShopService
