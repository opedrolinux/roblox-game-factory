--!strict
-- games/deep-reach/src/server/services/daily/DailyDropService.luau   [feature: daily supply drop]
--
-- THE authoritative owner of the daily supply drop. Replaces the contract-pass stub in place,
-- preserving every contract decision the stub pinned: the action name (Net.Actions.ClaimDaily), its
-- RatePolicy ({3, 10s} anti-spam — NOT the game cooldown), the closure-based registration, and the
-- deliberate absence of a ctx seam (contract.stubs.daily.seamProvided is null — nothing else in the
-- game reads daily state through a service, so installing one would invent a seam the contract does
-- not name, and a dangling seam is a promise nobody keeps).
--
-- ── WHAT THIS SERVICE OWNS ──────────────────────────────────────────────────────────────────────
--   * The 20-22h ROLLING claim window, evaluated ONLY against ctx.clock:unix() and the persisted
--     daily.lastClaimUnix. Both bounds are server constants in THIS module; the payload carries no
--     timestamp at all and the validator refuses one rather than ignoring it.
--   * The streak rule, which is NOT "claimed today +1":
--        elapsed < 20h   -> CLOSED   -> Err(OnCooldown). Nothing is written, nothing is granted.
--        20h <= e <= 22h -> OPEN     -> the streak CONTINUES (streak += 1).
--        elapsed > 22h   -> LAPSED   -> the claim is still GRANTED, but the streak RESETS to 1.
--        lastClaimUnix 0 -> NEVER    -> the first claim ever; streak starts at 1.
--     The lapse branch grants: "a player who lets the window lapse comes back to a reset streak",
--     not "a player who lets the window lapse is refused". Refusing there would make the drop
--     unclaimable forever after one missed day.
--   * The ESCALATING reward, server-derived from the streak alone and CAPPED (see REWARD_CAP_STREAK)
--     so an unbounded streak cannot mint an unbounded balance. Granted through ctx.economy:earn, so
--     stats.lifetimeCredits moves and currency_earned fires exactly once, by construction.
--   * Pushing the refreshed PlayerView after a committed claim, so the HUD badge's streak is a fact
--     the client can actually see. DataService pushes the view ONCE, on load — which is before this
--     claim lands — so without this the badge would show the join-time streak until the next
--     unrelated write.
--
-- NOT THIS SLICE: offline accrual (Offline accrual owns the away window and lastSeenUnix); the daily
-- rich wreck / restock (Depth tiers — that is a per-tier salvage-VALUE multiplier, not a claimable
-- reward); any purchase, any spend, any currency other than the Credits this grants.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The dupe this feature is one mistake away from is: read daily.lastClaimUnix, decide "the window is
-- open", YIELD in ctx.data:update, then grant + stamp. Two claims in the same frame both read the OLD
-- stamp before either writes, and the player is paid twice for one day — forever, once per spam
-- burst. Two independent mechanisms close it, and they fail in different directions:
--
--   (1) THE DECISION AND THE STAMP LIVE IN ONE LOCK-HELD TRANSFORM. Nothing outside `transform`
--       below reads daily.lastClaimUnix and nothing outside it writes one. DataService:update runs
--       the transform under the per-player FIFO lock against a snapshot RE-READ after any earlier
--       update has written (MockStore/SessionStore §4.1 step 2), and the transform itself is
--       synchronous — it contains no yield of any kind. So the second claim's transform necessarily
--       observes the first claim's stamp and takes the CLOSED branch. This is the load-bearing
--       guarantee; it holds even if (2) is deleted.
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION taken BEFORE the update can yield (`self._claiming`,
--       the same reserve-before-yield discipline PlotService uses for a dome). Luau is
--       single-threaded, so the flag is visible to every interleaved request the instant it is set,
--       and a spam-duplicated claim that arrives while the first is parked in the store is refused
--       without ever reaching the data layer. It is belt-and-braces for (1), not a substitute: it is
--       per-SERVER memory and says nothing about the same player on another server.
--
-- The flag is cleared on EVERY path — the update is pcall'd purely so that a throw cannot strand it
-- set, which would lock that player out of the drop for the life of the server.
--
-- THERE IS NO CAPTURED SESSION STATE TO RESTORE on a failed update. This feature grants from a CLOCK,
-- not from an accumulator: it zeroes nothing, holds nothing in memory between the decision and the
-- write, and its whole mutation is "stamp + streak + earn", applied to the transform's snapshot. A
-- store failure discards that snapshot wholesale, which leaves the invariant (`lastClaimUnix is the
-- instant of the last GRANTED claim`) intact with no compensating write.
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- windowFor / streakAfter / rewardFor / describe / claim / claimAction are Roblox-FREE: a spec drives
-- the whole cooldown/continue/lapse/cap lifecycle with Mocks.player + a real DataService over
-- MockStore and no engine at all. Only pushView touches the wire, and it is guarded twice over.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT service root than
-- this ServerScriptService module — so the relative string cannot reach it there; require by
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

local DailyDropService = {}
DailyDropService.name = "DailyDropService"

-- ── the window (SERVER constants; the client never sends or influences them) ─────────────────────
local HOUR_SECONDS = 3600
-- The drop OPENS once 20h have elapsed since the last claim.
local CLAIM_OPENS_AFTER_SECONDS = 20 * HOUR_SECONDS
-- ...and the streak LAPSES once 22h have elapsed. The 2h span between them is the "20-22h claim
-- window" the re-entry hook names: come back inside it and the streak continues; come back after it
-- and you still get a drop, at streak 1.
local STREAK_LAPSES_AFTER_SECONDS = 22 * HOUR_SECONDS

-- Boundaries are INCLUSIVE at both ends, so the window is exactly [20h, 22h]: a claim at exactly 20h
-- is open (not closed by a rounding hair) and a claim at exactly 22h still continues the streak. A
-- half-open reading would punish the player at the instant the spec calls the window's edge.
DailyDropService.CLAIM_OPENS_AFTER_SECONDS = CLAIM_OPENS_AFTER_SECONDS
DailyDropService.STREAK_LAPSES_AFTER_SECONDS = STREAK_LAPSES_AFTER_SECONDS

-- ── the escalating reward ───────────────────────────────────────────────────────────────────────
-- reward(streak) = BASE + STEP * (min(streak, CAP) - 1), i.e. 100/150/200/250/300/350/400 and then
-- FLAT at 400 forever. THE CAP IS THE POINT: the streak is a counter with no upper bound, so a
-- reward that kept escalating with it would let a player who logs in daily for a year mint an
-- arbitrarily large balance from a source that costs them nothing. Capping the REWARD (rather than
-- the streak) keeps the counter honest for the badge while bounding the mint at 400 Credits/day.
local BASE_REWARD_CREDITS = 100
local REWARD_STEP_CREDITS = 50
local REWARD_CAP_STREAK = 7

DailyDropService.BASE_REWARD_CREDITS = BASE_REWARD_CREDITS
DailyDropService.REWARD_STEP_CREDITS = REWARD_STEP_CREDITS
DailyDropService.REWARD_CAP_STREAK = REWARD_CAP_STREAK
DailyDropService.MAX_REWARD_CREDITS = BASE_REWARD_CREDITS
	+ REWARD_STEP_CREDITS * (REWARD_CAP_STREAK - 1)

-- The currency this drop pays in. A literal rather than a require of EconomyService: a service never
-- sibling-requires another service (CLAUDE.md "resolve dependencies through context"), and the key
-- is the same open-map key Migrations seeds.
local REWARD_CURRENCY = "Credits"
-- The earn-path label carried on currency_earned. Never used for math.
local EARN_SOURCE = "daily"

-- ── window status ───────────────────────────────────────────────────────────────────────────────
DailyDropService.Status = {
	Never = "never", -- no claim on record: the drop is available and starts a streak at 1
	Closed = "closed", -- inside the 20h cooldown: Err(OnCooldown)
	Open = "open", -- inside [20h, 22h]: the streak continues
	Lapsed = "lapsed", -- past 22h: granted, but the streak restarts at 1
}
local Status = DailyDropService.Status

-- ── in-flight reservations (per SERVER; see mechanism (2) in the header) ────────────────────────
-- userId -> true while that player's claim is parked inside ctx.data:update. Module-level so a spec
-- can drive `claim` without Start, and cleared on every exit path.
DailyDropService._claiming = {} :: { [number]: boolean }

-- The ServerContext, captured at Start. The handler needs it for the post-claim view push:
-- NetServer's ActionContext projection deliberately carries no `net`, and DataService pushes the
-- view only on load.
DailyDropService._context = nil :: any

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

-- A real Roblox Player is USERDATA, never a table, so identity is taken from the FIELD — which both
-- a live Player and Mocks.player answer.
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

-- A persisted streak, normalized. Garbage (nil / NaN / infinite / negative / fractional) reads as 0,
-- i.e. "no streak", rather than poisoning the reward arithmetic. NaN is the dangerous one: every
-- comparison against it is false, so an unchecked NaN streak would silently take whichever branch
-- happened to be the else.
local function sanitizeStreak(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if value == math.huge or value == -math.huge then
		return 0
	end
	if value < 0 then
		return 0
	end
	return math.floor(value)
end

-- A persisted claim stamp, normalized against the server clock. 0 / absent / garbage all mean
-- "never claimed".
--
-- A stamp in the FUTURE is clamped to now, and that clamp is load-bearing: without it a stamp ahead
-- of the server clock (a record written under a mis-set clock, a blob migrated from a different clock
-- base) leaves `elapsed` negative, so the window NEVER opens again and the player silently loses the
-- feature for good. Clamping costs the player at most one window and can never grant early — it only
-- ever makes them wait a full 20h from now.
--
-- CLAMPING ON READ IS NOT ENOUGH, and that is the subtle half: a read-time clamp re-clamps to the NEW
-- `now` on every call, so `elapsed` is 0 every time and the lockout is permanent anyway — the repair
-- has to be PERSISTED. `healRecord` below writes the normalized value back inside the transform, so
-- the 20h then actually elapses against a fixed point. It is the one write a refused claim may make,
-- it is idempotent (a second pass finds nothing to change), and it cannot grant anything.
local function sanitizeStamp(value: any, nowUnix: number): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if value == math.huge or value == -math.huge then
		return 0
	end
	if value <= 0 then
		return 0
	end
	if value > nowUnix then
		return nowUnix
	end
	return math.floor(value)
end

local function sanitizeNow(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	if value == math.huge or value == -math.huge then
		return nil
	end
	return math.floor(value)
end

-- ── the pure window / streak / reward math (Tier-1 drives these directly) ───────────────────────

-- Normalize a `daily` record IN PLACE and report whether anything had to be repaired. Called at the
-- top of the transform, on EVERY path including the refusal, so an invalid persisted stamp is fixed
-- once and for all rather than re-clamped to a moving `now` on every request (which would leave
-- `elapsed` pinned at 0 and the drop unclaimable forever). Grants nothing; only ever moves a stamp
-- BACKWARD to now and a streak toward 0.
function DailyDropService.healRecord(_self: any, daily: any, nowUnix: number): boolean
	local stamp = sanitizeStamp(daily.lastClaimUnix, nowUnix)
	local streak = sanitizeStreak(daily.streak)
	local healed = false
	if daily.lastClaimUnix ~= stamp then
		daily.lastClaimUnix = stamp
		healed = true
	end
	if daily.streak ~= streak then
		daily.streak = streak
		healed = true
	end
	return healed
end

-- Returns (status, secondsUntilOpen). secondsUntilOpen is 0 unless the status is Closed.
function DailyDropService.windowFor(
	_self: any,
	lastClaimUnix: any,
	nowUnix: number
): (string, number)
	local stamp = sanitizeStamp(lastClaimUnix, nowUnix)
	if stamp == 0 then
		return Status.Never, 0
	end
	local elapsed = nowUnix - stamp
	if elapsed < CLAIM_OPENS_AFTER_SECONDS then
		return Status.Closed, CLAIM_OPENS_AFTER_SECONDS - elapsed
	end
	if elapsed <= STREAK_LAPSES_AFTER_SECONDS then
		return Status.Open, 0
	end
	return Status.Lapsed, 0
end

-- The streak this claim lands on. ONLY the Open branch continues; Never and Lapsed both restart at 1
-- (a granted claim always leaves the player on a streak of at least 1 — a granted drop that left the
-- streak at 0 would make the badge lie about a day the player did show up for).
function DailyDropService.streakAfter(_self: any, previousStreak: any, status: string): number
	if status == Status.Open then
		return sanitizeStreak(previousStreak) + 1
	end
	return 1
end

-- The Credits this streak is worth. Server-derived from the streak alone — no client number reaches
-- this — and flat above REWARD_CAP_STREAK.
function DailyDropService.rewardFor(_self: any, streak: any): number
	local value = sanitizeStreak(streak)
	if value < 1 then
		value = 1
	end
	local capped = math.min(value, REWARD_CAP_STREAK)
	return BASE_REWARD_CREDITS + REWARD_STEP_CREDITS * (capped - 1)
end

export type ClaimInfo = {
	streak: number,
	lastClaimUnix: number, -- the SERVER stamp this claim wrote
	reward: number, -- Credits granted by THIS claim
	balance: number, -- the post-grant Credits balance, as EconomyService computed it
	status: string, -- "never" | "open" | "lapsed" (a refusal never describes)
	continued: boolean, -- true when this claim continued an existing streak
	opensAtUnix: number, -- when the NEXT claim window opens
	lapsesAtUnix: number, -- when the streak lapses if unclaimed
	secondsUntilOpen: number,
}

function DailyDropService.describe(
	_self: any,
	streak: number,
	lastClaimUnix: number,
	reward: number,
	balance: number,
	status: string,
	nowUnix: number
): ClaimInfo
	local stamp = sanitizeStamp(lastClaimUnix, nowUnix)
	local opensAt = if stamp == 0 then nowUnix else stamp + CLAIM_OPENS_AFTER_SECONDS
	local lapsesAt = if stamp == 0 then nowUnix else stamp + STREAK_LAPSES_AFTER_SECONDS
	return {
		streak = streak,
		lastClaimUnix = stamp,
		reward = reward,
		balance = balance,
		status = status,
		continued = status == Status.Open,
		opensAtUnix = opensAt,
		lapsesAtUnix = lapsesAt,
		secondsUntilOpen = math.max(0, opensAt - nowUnix),
	}
end

-- ── the claim ───────────────────────────────────────────────────────────────────────────────────

-- THE single grant path. Everything that decides and everything that writes happens inside the one
-- transform below; this function's own body only reserves, calls, and un-reserves.
function DailyDropService.claim(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "daily: context is missing data/clock")
	end

	-- ctx.economy is the ENFORCEMENT POINT for "lifetime on all earns": granting around it would
	-- leave stats.lifetimeCredits (the leaderboard's ranking key) unmoved and currency_earned
	-- unemitted. An absent seam is therefore a refusal, never a fall-through to a direct write.
	local economy = ctx.economy
	if economy == nil or type(economy.earn) ~= "function" then
		return Result.err(
			Result.Codes.Internal,
			"daily: ctx.economy is not installed — granting here would skip stats.lifetimeCredits "
				.. "and the currency_earned event"
		)
	end

	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "daily: player has no numeric UserId")
	end

	local nowUnix = sanitizeNow(ctx.clock:unix())
	if nowUnix == nil then
		return Result.err(Result.Codes.Internal, "daily: the server clock returned no usable time")
	end
	local now = nowUnix :: number

	-- (1) RESERVE, synchronously, before anything below can yield. A spam-duplicated claim that
	-- arrives while the first is parked in the store lands here and is refused with the same
	-- game-cooldown code the window itself uses — this IS the cooldown, observed a few milliseconds
	-- early. (Never RateLimited: that code belongs to the Gate's anti-spam bucket, and conflating
	-- the two makes the daily-window test indistinguishable from a rate-limit test.)
	if self._claiming[userId] then
		return Result.err(
			Result.Codes.OnCooldown,
			"daily: a claim for this player is already in flight"
		)
	end
	self._claiming[userId] = true

	-- Captured by the transform; the transform is the only thing that ever sets it.
	local outcome: any = nil

	-- (2) THE ONE LOCK-HELD TRANSFORM. Synchronous by construction: no yield, no data call, no
	-- engine call. `now` was read BEFORE the update deliberately, so the instant the window is
	-- JUDGED against is the very instant stamped as lastClaimUnix — reading the clock again after
	-- the lock was granted would silently push the next window later by however long this request
	-- waited behind another writer.
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "daily: data blob is not a table")
			return data
		end

		local daily = data.daily
		if type(daily) ~= "table" then
			-- Recoverable rather than a throw: an error raised inside a lock-held transform
			-- discards the whole write and surfaces as an opaque Internal.
			daily = { streak = 0, lastClaimUnix = 0 }
			data.daily = daily
		end

		-- Normalize the persisted record FIRST, and persist the normalization (see healRecord's note
		-- above): a stamp ahead of the server clock re-clamps to the moving `now` on every read, so
		-- clamping without writing back leaves the drop unclaimable for the life of the record.
		self:healRecord(daily, now)

		local status, secondsUntilOpen = self:windowFor(daily.lastClaimUnix, now)
		if status == Status.Closed then
			-- REFUSED: NOTHING IS GRANTED and no claim is stamped. (The only write a refusal can
			-- make is healRecord's repair above, which strictly normalizes an already-invalid
			-- record and can never move the window forward.) The cooldown is a GAME state, so it
			-- is Err(OnCooldown) and never RateLimited.
			outcome = Result.err(
				Result.Codes.OnCooldown,
				`daily: the supply drop opens in {math.floor(secondsUntilOpen)}s`
			)
			return data
		end

		local streak = self:streakAfter(daily.streak, status)
		local reward = self:rewardFor(streak)

		-- THE single balance mutation. It increments stats.lifetimeCredits and emits
		-- currency_earned itself, which is exactly why nothing here touches data.currencies,
		-- data.stats or ctx.analytics.
		local granted = economy:earn(data, REWARD_CURRENCY, reward, EARN_SOURCE)
		if not granted.ok then
			-- earn validates BEFORE it writes, so a refusal leaves the blob unchanged — and the
			-- stamp below is skipped, so a failed grant never burns the player's window.
			outcome = granted
			return data
		end

		-- Stamped LAST, and only after the grant is applied to this snapshot. The two assignments
		-- below cannot throw (`daily` was proven to be a table above), so no statement after the
		-- currency_earned emit can discard the snapshot the event describes.
		daily.streak = streak
		daily.lastClaimUnix = now

		outcome = Result.ok(self:describe(streak, now, reward, granted.value.balance, status, now))
		return data
	end

	-- (3) pcall'd ONLY so the reservation below is released on every path: DataService:update
	-- already pcalls the transform, so a throw here would have to come from the data layer itself —
	-- and a reservation stranded `true` would lock this player out of the drop until the server dies.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	self._claiming[userId] = nil

	if not ok then
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		-- The data layer always returns a Result; anything else would cross the Net boundary as a
		-- shape the client cannot read, so it is converted rather than forwarded.
		return Result.err(Result.Codes.Internal, "daily: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, or a transform
		-- that threw. The transform never ran, or its snapshot was discarded; either way NOTHING
		-- was persisted, so the Err is surfaced as-is rather than dressed up as a grant.
		return written
	end
	if outcome == nil then
		return Result.err(
			Result.Codes.Internal,
			"daily: the update reported success but the transform produced no outcome"
		)
	end

	-- (4) The view push is DERIVED from a committed write, comes after it, and can never undo it:
	-- guarded and pcall'd, its result discarded. An unguarded post-write push is how a committed
	-- economy write once came back to the client as Err(Internal).
	if outcome.ok then
		self:pushView(self._context, player)
	end
	return outcome
end

-- Push the refreshed client view after a committed claim. `context` is the SERVER context (the
-- ActionContext projection carries no net). Returns whether a push actually went out; every caller
-- ignores it, because a presentation failure must never turn a granted drop into an error.
function DailyDropService.pushView(_self: any, context: any, player: any): boolean
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

-- ── the action ──────────────────────────────────────────────────────────────────────────────────

-- The claim payload carries NO TIMESTAMP BY CONTRACT — and no streak, and no amount. A payload that
-- names one is REFUSED rather than ignored: an ignored forgery is indistinguishable from a
-- well-formed request, and the difference is the only signal that someone is probing the window. The
-- validator hands the handler a FRESH EMPTY TABLE, so the handler is not merely disciplined about
-- ignoring client data — it is never handed any.
local FORBIDDEN_PAYLOAD_KEYS = {
	"now",
	"nowUnix",
	"time",
	"timestamp",
	"unix",
	"serverTime",
	"clientTime",
	"lastClaimUnix",
	"claimedAtUnix",
	"elapsed",
	"streak",
	"reward",
	"amount",
	"credits",
	"currency",
	"userId",
}

local function validateNoTime(rawPayload: any): any
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
				`daily.claim takes no arguments — the SERVER derives the time, the streak and the `
					.. `reward (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

DailyDropService.validate = validateNoTime

-- Exported so a Tier-1 spec can register the action on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as a CLOSURE over the service because the
-- single-flight reservation table IS service state and a static-module registration cannot reach it.
function DailyDropService.claimAction(self: any): any
	return {
		name = Net.Actions.ClaimDaily,
		validate = validateNoTime,
		-- PRESERVED FROM THE CONTRACT-PASS STUB. This bucket is anti-spam only: it stops a click
		-- burst from reaching the transform. The real once-per-20h limit is the WINDOW, enforced in
		-- the transform and refused with OnCooldown — a different code, on purpose.
		rate = { maxPerWindow = 3, windowSeconds = 10.0 },
		handler = function(ctx: any, _payload: any): any
			return self:claim(ctx)
		end,
	}
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: capture the server context (for the post-claim view push) and register the wire surface.
-- Installs NO ctx seam — see the header. Lune-callable: nothing here touches a Roblox global.
function DailyDropService.Start(self: any, context: any): ()
	self._context = context
	self._claiming = {}
	context.net:register(self:claimAction())
end

function DailyDropService.Stop(self: any, _context: any): ()
	self._claiming = {}
	self._context = nil
end

return DailyDropService
