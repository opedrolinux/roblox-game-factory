--!strict
-- games/deep-reach/src/server/services/offline/OfflineService.luau   [feature: offline accrual]
--
-- THE authoritative owner of the AWAY WINDOW: the span `[timestamps.lastSeenUnix, ctx.clock:unix()]`,
-- what the drones produced across it, the smelter-capacity cap that bounds it, and the ONE-SHOT claim
-- that pays it. Replaces the contract-pass stub in place, preserving every contract decision the stub
-- pinned: the two action names (Net.Actions.ClaimOffline / Net.Actions.FetchOffline), their
-- RatePolicies ({3, 10s} and {10, 1.0s}), the closure-based registration (the pending grant IS service
-- state, which a static-module registration cannot reach), and the deliberate absence of a ctx seam
-- (contract.stubs.offline.seamProvided is null — nothing else in this game reads offline state through
-- a service, and a seam with no reader is a dangling promise gate-reachability rightly fails).
--
-- ── THE RULE, EXACTLY AS THE SLICE STATES IT ────────────────────────────────────────────────────
--     amount = min(ctx.salvage:rateFor(data) * awaySeconds, ctx.salvage:capacityFor(data))
-- with `awaySeconds` clamped at 0 for a negative or absurd delta. THE CAP IS THE SMELTER CAPACITY,
-- and that is a design decision, not a safety valve: upgrading the smelter visibly raises the offline
-- grant (which is what makes the capacity upgrade matter), and an enormous away time — or a forged
-- one, or a clock that jumped — cannot mint more than ONE smelter-full. There is deliberately NO
-- second clamp on `awaySeconds`: a clamp there would silently reduce the grant of a max-capacity
-- player who was genuinely away for a long time, and the capacity cap already bounds the exploit.
--
-- NO CLIENT TIME ANYWHERE, AND NO CLIENT NUMBER ANYWHERE. Both payloads carry nothing by contract and
-- the validator REFUSES a payload that names a timestamp/duration/amount rather than ignoring it — an
-- ignored forgery is indistinguishable from a well-formed request, and the difference is the only
-- signal that someone is probing the away time. The offline-time-forgery exploit is closed by
-- construction: there is no number on this path that did not come from the persisted blob or
-- ctx.clock.
--
-- ── WHERE THE PENDING GRANT LIVES, AND WHY IT MUST ─────────────────────────────────────────────
-- IN SERVER MEMORY (`_pending`), computed ONCE per session as soon as that session's data is loaded,
-- and NEVER recomputed for the same session. It cannot live in PlayerData (no new persisted field, no
-- migration — the contract is explicit) and it must not be recomputed at claim time, because:
--
--     `DataService.autosaveTick` REWRITES `timestamps.lastSeenUnix` TO NOW ON EVERY FLUSH.
--
-- So within one autosave interval the away window is ERASED from persistence and any later
-- recomputation reads elapsed ~= 0. Computing at claim time would therefore pay nothing to exactly the
-- players this feature exists for — a long absence means a long load, which is the same yield that
-- loses the join race. That defect shipped in this factory's previous game, cost the earnings
-- PERMANENTLY, and was invisible to every offline verification rung (docs/LEARNINGS.md;
-- src/client/framework/JoinRetry.luau's header). The window is snapshotted the instant it is still
-- true, and the claim pays the SNAPSHOT.
--
-- THE SESSION EPOCH IS `stats.joinCount`. A memory record needs to know which SESSION it describes:
--   * within one session it must NEVER be recomputed (a recomputation from the unchanged base would
--     hand out the same window a second time — a double-grant with no exploit required, reachable
--     just by the join hook completing after an eager claim), and
--   * on a REJOIN to the same server it MUST be recomputed (the leave path stamped lastSeenUnix, so
--     there is a genuinely new away window to pay).
-- DataService bumps `stats.joinCount` on every loadSession and nothing else writes it, so it is a
-- per-session identity that is already persisted. `ensurePending` computes only when the stored
-- record's epoch differs from the blob's — which makes both properties fall out of one comparison
-- instead of out of a join/leave hook ordering this service does not control.
--
-- ── THE CONCURRENCY ARGUMENT (CLAUDE.md §4) ─────────────────────────────────────────────────────
-- The dupe this feature is one mistake away from: read the pending amount, YIELD in ctx.data:update,
-- then earn it. Two claims in the same frame both read the same non-zero pending before either
-- writes, and the away window is paid twice — repeatable once per spam burst. Three mechanisms close
-- it, and they fail in different directions:
--
--   (1) THE CAPTURE AND THE ZERO HAPPEN BEFORE THE UPDATE CAN YIELD, SYNCHRONOUSLY. `claim` reads the
--       pending amount and sets it to 0 in the same synchronous stretch, BEFORE ctx.data:update is
--       entered. Luau is single-threaded, so an interleaved or spam-duplicated claim that arrives
--       while the first is parked in the store necessarily observes 0 and is refused with
--       Err(Insufficient). This is the load-bearing guarantee. (SalvageService captures INSIDE its
--       transform because its amount lives in the BLOB, which only the lock makes safe to read; this
--       amount lives in server memory, where the lock buys nothing and the pre-yield capture is
--       exactly the equivalent discipline.)
--   (2) A SYNCHRONOUS SINGLE-FLIGHT RESERVATION (`_claiming`), taken before anything can yield — the
--       same reserve-before-yield discipline PlotService uses for a dome and DailyDropService for the
--       drop. Belt-and-braces for (1), never a substitute: it is per-SERVER memory and says nothing
--       about the same player on another server. (The cross-server case is closed anyway: the record
--       is loaded under the session lock, so two servers cannot hold the same player's session.)
--   (3) THE RESTORE IS BOUNDED BY THE CAP. If the earn refuses, or the update never commits, the
--       captured amount is put back — RE-CLAMPED to the capacity this window was computed against, so
--       a failed claim can never restore a pending grant larger than the cap that bounds it
--       (cap-bypass on the restore path is a known factory failure mode). The earn-side state is
--       rolled back too: this transaction is made atomic HERE rather than assumed atomic in the seam.
--
-- ONE MORE THING THE CLAIM DOES NOT DO: it does not write `timestamps.lastSeenUnix`. That field is the
-- data layer's (PERSISTENCE, in the slice: this feature writes only currencies.Credits +
-- stats.lifetimeCredits, through ctx.economy). It does not need to for durability either: a
-- ctx.data:update is IN-MEMORY ONLY (SessionStore §5 — "the durable write is save/release/autosave"),
-- and BOTH durable writers stamp lastSeenUnix = now as part of the same write that persists the
-- granted Credits. So the grant and the advance of the base are durably atomic without this file
-- touching the field, and an ungraceful crash loses both together rather than paying the window twice.
--
-- ── WHAT THIS SLICE DOES NOT OWN ────────────────────────────────────────────────────────────────
-- The rate and capacity FORMULAS (Salvage core — read through the ctx.salvage seam, never
-- re-derived here); `smelter.storedCredits` and `smelter.lastTickUnix` (Salvage core, which stamps
-- lastTickUnix at session load precisely so its online tick never re-counts this window — this file
-- touches neither, so the handoff needs no coordination beyond not interfering); the daily supply
-- drop; the restock; the depth multiplier (it reaches the number through ctx.salvage:rateFor, which
-- applies it — nothing here reads ctx.depth at all, so there is nothing to guard).
--
-- ── TIER-1 SHAPE ────────────────────────────────────────────────────────────────────────────────
-- awaySecondsFor / accrualFor / computePending / ensurePending / peek / claim / describe and both
-- action factories are Roblox-FREE: a spec drives the entire compute -> peek -> peek -> claim -> claim
-- lifecycle with Mocks.player + a real DataService over MockStore and no engine at all. Only
-- startRuntime, the join hook's waiter and the roster touch `game` / `task`, each through a guarded
-- local, so requiring and Starting this module under Lune never throws.
--
-- [D1 shim] src/shared maps to ReplicatedStorage.Shared in Roblox — a DIFFERENT Rojo service root than
-- this ServerScriptService module — so the relative string cannot reach it there; require by instance.
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

local OfflineService = {}
OfflineService.name = "OfflineService"

-- ── constants (SERVER-side; the client never sends or influences any of them) ────────────────────

-- The currency the away window pays in, and the earn-path label carried on currency_earned. The label
-- is never used for math; it is how "offline accrual is a source" is observable in analytics.
local EARN_CURRENCY = "Credits"
local EARN_SOURCE = "offline"

OfflineService.EARN_CURRENCY = EARN_CURRENCY
OfflineService.EARN_SOURCE = EARN_SOURCE

-- How long the join hook waits for DataService.loadSession to resolve before giving up. Same budget
-- and shape as SalvageService's arming wait and AnalyticsService's session_start wait, for the same
-- reason: loadSession YIELDS, and a window computed before it resolves reads Err(NoData) and computes
-- nothing — which is the permanent-loss defect, reached through the server door instead of the client
-- one. Tunable so a spec can drive the hook without yielding for 50 seconds.
OfflineService.loadWaitAttempts = 200
OfflineService.loadWaitStepSeconds = 0.25

-- ── state (per SERVER; Start resets it) ─────────────────────────────────────────────────────────

-- The ServerContext, captured at Start: the post-claim view push needs `net`, and the ActionContext
-- projection deliberately carries none.
OfflineService._context = nil :: any
-- userId -> the ONE pending away-window record for that player's CURRENT session. See THE SESSION
-- EPOCH in the header; `amount` is zeroed by the claim BEFORE the update can yield.
OfflineService._pending = {} :: { [number]: any }
-- userId -> true while that player's claim is parked inside ctx.data:update (mechanism (2)).
OfflineService._claiming = {} :: { [number]: boolean }
-- TEST SEAM: an optional roster provider, `() -> { PlayerLike }`. nil in production, where the roster
-- is the engine's Players service. Only the memory prune reads it.
OfflineService._players = nil :: (() -> { any })?
OfflineService._running = false
OfflineService._connections = {} :: { any }

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

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

-- A persisted unix stamp, normalized. 0 / absent / garbage / negative all read as 0, which this file
-- treats as "NO USABLE BASE" — see awaySecondsFor: a missing base grants nothing rather than paying
-- from the epoch, which would hand a free full smelter to any blob whose stamp failed to persist.
local function sanitizeStamp(value: any): number
	if not isUsableNumber(value) or value <= 0 then
		return 0
	end
	return math.floor(value)
end

-- A non-negative finite count (the session epoch). Garbage reads as 0.
local function sanitizeCount(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return math.floor(value)
end

-- A non-negative finite quantity. Garbage (nil / NaN / infinite / negative) reads as 0 rather than
-- poisoning the accrual arithmetic — a NaN amount would reach ctx.economy:earn and, if it ever got
-- past it, persist as a balance no comparison can ever satisfy again.
local function sanitizeAmount(value: any): number
	if not isUsableNumber(value) or value < 0 then
		return 0
	end
	return value
end

-- The session epoch this blob is on. See THE SESSION EPOCH in the header.
local function epochOf(data: any): number
	if type(data) ~= "table" or type(data.stats) ~= "table" then
		return 0
	end
	return sanitizeCount(data.stats.joinCount)
end

-- ── the pure away-window math (Tier-1 drives these directly) ────────────────────────────────────

-- The span this feature is allowed to pay for, in SERVER seconds. CLAMPED AT 0 on every degenerate
-- reading: no base (a stamp of 0/absent/garbage), a stamp in the FUTURE (a clock that moved backwards
-- or a record written under a mis-set clock), or a `now` this service could not read. A clock skew
-- must never mint, and the failure direction here is always "pay nothing", never "pay something
-- unbounded".
function OfflineService.awaySecondsFor(_self: any, lastSeenUnix: any, nowUnix: number): number
	local stamp = sanitizeStamp(lastSeenUnix)
	if stamp <= 0 then
		return 0
	end
	if not isUsableNumber(nowUnix) or nowUnix <= stamp then
		return 0
	end
	return nowUnix - stamp
end

export type Accrual = {
	amount: number, -- what a claim would grant: min(rate * awaySeconds, capacity)
	uncapped: number, -- what the drones produced before the ceiling — the popup's "you lost this much"
	capped: boolean, -- true when the ceiling actually bit
	capacity: number,
	rate: number,
	awaySeconds: number,
}

-- THE rule. Pure: three numbers in, one accrual out. `capped` is reported because the popup shows it
-- and the slice's success criterion names it — a cap that nothing can observe is a cap nobody can be
-- taught to upgrade past.
function OfflineService.accrualFor(_self: any, rate: any, awaySeconds: any, capacity: any): Accrual
	local safeRate = sanitizeAmount(rate)
	local safeAway = sanitizeAmount(awaySeconds)
	local safeCapacity = sanitizeAmount(capacity)

	local uncapped = safeRate * safeAway
	if not isUsableNumber(uncapped) or uncapped < 0 then
		-- inf/NaN can only arrive from a poisoned blob (both inputs are sanitized above, but their
		-- PRODUCT can still overflow). Treat it as "the ceiling bit": pay the cap, never the poison.
		uncapped = math.huge
	end

	local amount = if uncapped > safeCapacity then safeCapacity else uncapped
	return {
		amount = amount,
		uncapped = uncapped,
		capped = uncapped > safeCapacity,
		capacity = safeCapacity,
		rate = safeRate,
		awaySeconds = safeAway,
	}
end

-- The two numbers this feature borrows from Salvage core. Read THROUGH THE SEAM, never re-derived:
-- the rate formula (drones, conveyor, resurfaces, both 2x gamepasses, the depth multiplier) and the
-- capacity formula belong to SalvageService, and a second copy here would drift the moment either
-- changes — an offline grant computed from a stale rate is the salvage-rate spoof, self-inflicted.
--
-- An ABSENT seam is a REFUSAL, not a fall-through: without capacityFor there is no cap, and granting
-- an uncapped away window is precisely the exploit this slice is built around. Refusing loudly also
-- makes a broken boot observable, where a silent 0 would look exactly like "you were not away".
local function salvageReading(salvage: any, data: any): (number?, number?, string?)
	if
		salvage == nil
		or type(salvage.rateFor) ~= "function"
		or type(salvage.capacityFor) ~= "function"
	then
		return nil,
			nil,
			"offline: ctx.salvage is not installed — the away window has no rate to "
				.. "accrue at and no smelter capacity to be capped by, and an UNCAPPED offline grant is "
				.. "the exploit this feature exists to bound"
	end
	local ok, rate, capacity = pcall(function()
		return salvage:rateFor(data), salvage:capacityFor(data)
	end)
	if not ok then
		return nil, nil, `offline: ctx.salvage refused to read this blob: {tostring(rate)}`
	end
	return sanitizeAmount(rate), sanitizeAmount(capacity), nil
end

-- ── the pending record ──────────────────────────────────────────────────────────────────────────

export type Pending = {
	epoch: number, -- stats.joinCount at compute time: WHICH SESSION this window belongs to
	amount: number, -- what is still claimable. Zeroed BEFORE the claim's update can yield.
	claimed: boolean,
	uncapped: number,
	capped: boolean,
	capacity: number,
	rate: number,
	awaySeconds: number,
	lastSeenUnix: number, -- the base the window was measured from (SERVER stamp)
	computedAtUnix: number, -- the SERVER instant the window was closed at
}

-- THE BASE THE WINDOW IS MEASURED FROM, and the reason this is not simply `data.timestamps
-- .lastSeenUnix`: that field is REWRITTEN TO NOW by DataService.autosaveTick on every flush, and this
-- service does not get a hand-off when a session is installed — its join hook POLLS
-- (loadWaitStepSeconds, and task.wait is a floor, so a join storm widens the gap without bound). A
-- flush landing between the install and the first poll erases the base before anything snapshotted
-- it, and because ensurePending MEMOIZES the record for the session's epoch, that zero poisons the
-- peek AND the claim for the rest of the session: the earnings are gone permanently and silently,
-- which is the exact defect that shipped in this factory's previous game (docs/LEARNINGS.md).
--
-- So the base is taken from the data layer's LOAD-TIME snapshot (`DataService:joinBaseFor`), which is
-- written once when the session is installed and which autosave never touches. That makes the window
-- independent of WHEN this service wakes up — the gap can be arbitrarily wide and the base still
-- reads the value the player logged out at.
--
-- The blob remains the FALLBACK, for a source whose data layer has no such accessor (a spec's
-- instrumented double, a foreign seam). Narrowing to the accessor alone would turn every such caller
-- into a silent zero, which is the same failure wearing a different hat.
local function joinBaseFor(source: any, player: any, data: any): number
	local dataLayer = if type(source) == "table" then source.data else nil
	if player ~= nil and dataLayer ~= nil and type(dataLayer.joinBaseFor) == "function" then
		local ok, base = pcall(function()
			return dataLayer:joinBaseFor(player)
		end)
		if ok and base ~= nil then
			return sanitizeStamp(base)
		end
	end
	if type(data) == "table" and type(data.timestamps) == "table" then
		return sanitizeStamp(data.timestamps.lastSeenUnix)
	end
	return 0
end

-- Compute ONE session's away window from the loaded blob. PURE over (blob, clock, ctx.salvage): it
-- writes nothing to the blob, stamps nothing and grants nothing — it only reads. That is what lets
-- `offline.peek` share this path and still be strictly side-effect free (AMENDMENT A5).
--
-- `player` is optional and is used ONLY to ask the data layer for the load-time base (see above); a
-- call without it measures from the blob, which is what a spec driving the pure math wants.
function OfflineService.computePending(
	self: any,
	source: any,
	data: any,
	nowUnix: number,
	player: any?
): any
	local rate, capacity, seamError = salvageReading(source.salvage, data)
	if rate == nil or capacity == nil then
		return Result.err(Result.Codes.Internal, seamError)
	end

	local lastSeen = joinBaseFor(source, player, data)
	local awaySeconds = self:awaySecondsFor(lastSeen, nowUnix)
	local accrual = self:accrualFor(rate, awaySeconds, capacity)

	local pending: Pending = {
		epoch = epochOf(data),
		amount = accrual.amount,
		claimed = false,
		uncapped = accrual.uncapped,
		capped = accrual.capped,
		capacity = accrual.capacity,
		rate = accrual.rate,
		awaySeconds = accrual.awaySeconds,
		lastSeenUnix = lastSeen,
		computedAtUnix = nowUnix,
	}
	return Result.ok(pending)
end

-- The ONE way anything in this file obtains a pending record. Computes it EXACTLY ONCE per session
-- (see THE SESSION EPOCH in the header) and returns the stored record on every later call, so
-- peek-peek-claim grants the peeked amount exactly once and a claim can never be paid from a window
-- that was already consumed.
--
-- `source` is anything carrying .data / .clock / .salvage — the ActionContext a handler is given, or
-- the ServerContext the join hook holds. It never yields: ctx.data:get is a memory read.
function OfflineService.ensurePending(self: any, source: any, player: any): any
	if source == nil or source.data == nil or source.clock == nil then
		return Result.err(Result.Codes.Internal, "offline: context is missing data/clock")
	end
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "offline: player has no numeric UserId")
	end
	local now = sanitizeNow(source.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"offline: the server clock returned no usable time"
		)
	end

	local got = source.data:get(player)
	if type(got) ~= "table" or got.ok ~= true then
		-- NoData until loadSession resolves (the client's JoinRetry guard re-issues past it), or
		-- LockStolen for a dead session. Nothing is computed and nothing is remembered, so the next
		-- attempt still sees the untouched away window.
		return if type(got) == "table"
			then got
			else Result.err(
				Result.Codes.Internal,
				"offline: the data layer returned no Result"
			)
	end

	local data = got.value
	local epoch = epochOf(data)
	local existing = self._pending[userId]
	if existing ~= nil and existing.epoch == epoch then
		return Result.ok(existing)
	end

	local computed = self:computePending(source, data, now :: number, player)
	if not computed.ok then
		return computed
	end
	self._pending[userId] = computed.value
	return computed
end

-- ── the read surface (AMENDMENT A5) ─────────────────────────────────────────────────────────────

export type PendingInfo = {
	amount: number, -- the pending grant; 0 once it has been claimed
	capped: boolean,
	uncapped: number,
	capacity: number,
	rate: number,
	awaySeconds: number,
	lastSeenUnix: number,
	nowUnix: number,
	claimed: boolean, -- true once this session's window has been paid
}

function OfflineService.describe(_self: any, pending: any, nowUnix: number): PendingInfo
	return {
		amount = pending.amount,
		capped = pending.capped,
		uncapped = pending.uncapped,
		capacity = pending.capacity,
		rate = pending.rate,
		awaySeconds = pending.awaySeconds,
		lastSeenUnix = pending.lastSeenUnix,
		nowUnix = nowUnix,
		claimed = pending.claimed,
	}
end

-- `offline.peek` — STRICTLY SIDE-EFFECT FREE, and that is the whole reason AMENDMENT A5 exists: the
-- popup has to show the amount BEFORE the player claims it, and a peek that granted, that cleared the
-- pending amount, or that re-stamped the away window would be the defect the amendment was created to
-- avoid. It calls ensurePending (which may compute the window the first time, in memory) and then only
-- READS it — no ctx.data:update, no write to the blob, no mutation of the record.
function OfflineService.peek(self: any, ctx: any): any
	local prepared = self:ensurePending(ctx, if ctx ~= nil then ctx.player else nil)
	if not prepared.ok then
		return prepared
	end
	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"offline: the server clock returned no usable time"
		)
	end
	return Result.ok(self:describe(prepared.value, now :: number))
end

-- ── the claim ───────────────────────────────────────────────────────────────────────────────────

export type ClaimInfo = {
	amount: number, -- Credits granted by THIS claim
	capped: boolean,
	uncapped: number,
	capacity: number,
	rate: number,
	awaySeconds: number,
	lastSeenUnix: number,
	nowUnix: number,
	balance: number, -- the post-grant Credits balance, as EconomyService computed it
	lifetimeCredits: number, -- the post-increment lifetime total, as EconomyService computed it
}

-- THE single grant path. ONE-SHOT PER SESSION: the second call finds a zeroed pending and is refused
-- with Err(Insufficient) — the same code an empty smelter returns, and deliberately NOT RateLimited
-- (that belongs to the Gate's anti-spam bucket, and conflating them makes "the away window pays
-- exactly once" untestable).
function OfflineService.claim(self: any, ctx: any): any
	if ctx == nil or ctx.data == nil or ctx.clock == nil then
		return Result.err(Result.Codes.Internal, "offline: context is missing data/clock")
	end

	-- ctx.economy is the ENFORCEMENT POINT for "lifetime on all earns": granting around it would leave
	-- stats.lifetimeCredits (the leaderboard's ranking key) unmoved and currency_earned unemitted. An
	-- absent seam is therefore a refusal, never a fall-through to a direct write of data.currencies.
	local economy = ctx.economy
	if economy == nil or type(economy.earn) ~= "function" then
		return Result.err(
			Result.Codes.Internal,
			"offline: ctx.economy is not installed — granting here would skip stats.lifetimeCredits "
				.. "and the currency_earned event"
		)
	end

	local player = ctx.player
	local userId = userIdOf(player)
	if userId == nil then
		return Result.err(Result.Codes.BadType, "offline: player has no numeric UserId")
	end

	local now = sanitizeNow(ctx.clock:unix())
	if now == nil then
		return Result.err(
			Result.Codes.Internal,
			"offline: the server clock returned no usable time"
		)
	end
	local nowUnix = now :: number

	-- (2) RESERVE, synchronously, before anything below can yield. A spam-duplicated claim that
	-- arrives while the first is parked in the store lands here and gets the same shortfall code the
	-- zeroed pending it is racing toward would give it.
	if self._claiming[userId] then
		return Result.err(
			Result.Codes.Insufficient,
			"offline: a claim for this player is already in flight — the away window is being paid"
		)
	end
	self._claiming[userId] = true

	local prepared = self:ensurePending(ctx, player)
	if not prepared.ok then
		self._claiming[userId] = nil
		return prepared
	end
	local pending = prepared.value

	-- (1) CAPTURE AND ZERO, SYNCHRONOUSLY, BEFORE THE UPDATE CAN YIELD. From here on the pending
	-- amount is 0 for every other caller in this server, so an interleaved duplicate — and a peek —
	-- sees nothing left to claim. This is the load-bearing half of the one-shot guarantee.
	local amount = sanitizeAmount(pending.amount)
	local capacity = sanitizeAmount(pending.capacity)
	pending.amount = 0

	if amount <= 0 then
		self._claiming[userId] = nil
		-- Nothing to pay: either this session's window was already claimed, or the player was not
		-- away (the fresh-player case, which is the common one). A CURRENCY shortfall, not a payload
		-- failure and not a panic refusal.
		--
		-- `claimed` IS NOT SET HERE, and the ordering is the point. It is the A5 read surface's answer
		-- to "did this session's window get paid?", so setting it on the refused path would tell a
		-- player who was never away that they had already collected — the two states are different
		-- and the popup is entitled to tell them apart. The ZERO above stays where it is: that write
		-- is the load-bearing half of the one-shot guarantee (it must happen before anything can
		-- yield) and it is already 0 on this path anyway.
		return Result.err(
			Result.Codes.Insufficient,
			"offline: there is no pending away-window accrual to claim"
		)
	end

	-- Paying from here. Flagged BEFORE the update can yield, alongside the zero, so an interleaved
	-- peek sees a consistent record; `restore()` clears it again if nothing commits.
	pending.claimed = true

	-- Everything the transform needs, read BEFORE the yield. `outcome` is set only by the transform.
	local outcome: any = nil

	-- (3) THE ONE LOCK-HELD TRANSFORM. Synchronous by construction: no yield, no data call, no engine
	-- call. It performs exactly ONE mutation — ctx.economy:earn — which increments
	-- stats.lifetimeCredits and emits currency_earned itself, which is why nothing here touches
	-- data.currencies, data.stats, data.timestamps or ctx.analytics.
	local function transform(data: any): any
		if type(data) ~= "table" then
			outcome = Result.err(Result.Codes.Internal, "offline: data blob is not a table")
			return data
		end

		-- The earn-side state BEFORE the attempt, so a refusal can be rolled all the way back. `earn`
		-- is documented to decide every refusal before its first mutation, but this transaction is
		-- made atomic HERE rather than assumed atomic there: a seam that credited the balance and then
		-- refused would otherwise leave the amount in currencies.Credits AND restored to the pending
		-- record — a mint of one away window per refused claim, with stats.lifetimeCredits unmoved so
		-- nothing downstream could see it. (This is not hypothetical: the salvage gate caught exactly
		-- that shape.) Nil is a legitimate captured value; restoring nil restores absence.
		local beforeBalance: any = nil
		local beforeLifetime: any = nil
		if type(data.currencies) == "table" then
			beforeBalance = data.currencies[EARN_CURRENCY]
		end
		if type(data.stats) == "table" then
			beforeLifetime = data.stats.lifetimeCredits
		end

		local earned = economy:earn(data, EARN_CURRENCY, amount, EARN_SOURCE)
		if not earned.ok then
			if
				type(data.currencies) == "table"
				and data.currencies[EARN_CURRENCY] ~= beforeBalance
			then
				data.currencies[EARN_CURRENCY] = beforeBalance
			end
			if type(data.stats) == "table" and data.stats.lifetimeCredits ~= beforeLifetime then
				data.stats.lifetimeCredits = beforeLifetime
			end
			outcome = earned
			return data
		end

		outcome = Result.ok({
			amount = amount,
			capped = pending.capped,
			uncapped = pending.uncapped,
			capacity = pending.capacity,
			rate = pending.rate,
			awaySeconds = pending.awaySeconds,
			lastSeenUnix = pending.lastSeenUnix,
			nowUnix = nowUnix,
			balance = earned.value.balance,
			lifetimeCredits = earned.value.lifetimeCredits,
		} :: ClaimInfo)
		return data
	end

	-- pcall'd ONLY so the reservation is released on every path: DataService:update already pcalls the
	-- transform, so a throw here would have to come from the data layer itself — and a reservation
	-- stranded `true` would lock this player out of their own away window for the life of the server.
	local ok, written = pcall(function(): any
		return ctx.data:update(player, transform)
	end)
	self._claiming[userId] = nil

	-- THE RESTORE (mechanism (3)). Only ever puts back the amount captured moments ago, RE-CLAMPED to
	-- the capacity this window was computed against, and only when NOTHING was committed — so the
	-- player can claim again (their earnings are not lost to a transient store failure) and a failed
	-- claim can never restore more than one smelter-full.
	local function restore(): ()
		local record = self._pending[userId]
		if record == nil or record ~= pending then
			return -- a newer session's record replaced it; that window is not this one's to touch
		end
		record.amount = math.min(amount, capacity)
		record.claimed = false
	end

	if not ok then
		restore()
		return Result.err(Result.Codes.Internal, tostring(written))
	end
	if type(written) ~= "table" or written.ok == nil then
		restore()
		return Result.err(Result.Codes.Internal, "offline: the data layer returned no Result")
	end
	if written.ok ~= true then
		-- NoData (session not loaded — JoinRetry re-issues past it), LockStolen, or a transform that
		-- threw. The snapshot was discarded either way, so NOTHING was persisted and the away window
		-- is still owed.
		restore()
		return written
	end
	if outcome == nil then
		restore()
		return Result.err(
			Result.Codes.Internal,
			"offline: the update reported success but the transform produced no outcome"
		)
	end
	if not outcome.ok then
		-- The transform ran and REFUSED (the earn was rejected and rolled back above). The write
		-- committed an unchanged snapshot, so the window is still owed.
		restore()
		return outcome
	end

	-- The view push is DERIVED from a committed write, comes after it, and can never undo it: guarded
	-- and pcall'd, its result discarded. An unguarded post-write push is how a committed economy write
	-- once came back to the client as Err(Internal) (docs/LEARNINGS.md).
	self:pushView(self._context, player)
	return outcome
end

-- Push the refreshed client view after a committed claim. `context` is the SERVER context (the
-- ActionContext projection carries no net). Every caller ignores the return value, because a
-- presentation failure must never turn a granted claim into an error.
function OfflineService.pushView(_self: any, context: any, player: any): boolean
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

-- Both payloads carry NOTHING BY CONTRACT — no timestamp, no duration, no amount, no rate. A payload
-- that names one is REFUSED rather than ignored (see NO CLIENT TIME ANYWHERE in the header). The
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
	"lastSeenUnix",
	"lastTickUnix",
	"awaySeconds",
	"away",
	"elapsed",
	"seconds",
	"duration",
	"offline",
	"amount",
	"credits",
	"Credits",
	"currency",
	"rate",
	"multiplier",
	"capacity",
	"capped",
	"uncapped",
	"userId",
	"source",
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
				`offline actions take no arguments — the SERVER derives the away window, the rate and `
					.. `every credit granted (rejected key "{key}")`
			)
		end
	end
	return Result.ok({})
end

OfflineService.validate = validateNoArguments

-- Exported so a Tier-1 spec can register the actions on a Mocks.net harness without Starting the
-- service against a Roblox runtime. Registered as CLOSURES over the service because the pending
-- record and the single-flight reservation ARE service state, which a static-module registration
-- cannot reach (contract.precisionNotes[5]).
function OfflineService.claimAction(self: any): any
	return {
		name = Net.Actions.ClaimOffline,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB. Anti-spam only: it bounds the JoinRetry re-issue
		-- burst. The real once-per-session limit is the zeroed pending record, enforced before the
		-- update can yield and refused with Insufficient — a different code, on purpose.
		rate = { maxPerWindow = 3, windowSeconds = 10.0 },
		handler = function(ctx: any, _payload: any): any
			return self:claim(ctx)
		end,
	}
end

function OfflineService.peekAction(self: any): any
	return {
		name = Net.Actions.FetchOffline,
		validate = validateNoArguments,
		-- PRESERVED FROM THE CONTRACT-PASS STUB. A read surface, so it is generous — and it can afford
		-- to be, because peeking is side-effect free.
		rate = { maxPerWindow = 10, windowSeconds = 1.0 },
		handler = function(ctx: any, _payload: any): any
			return self:peek(ctx)
		end,
	}
end

-- ── the join hook ───────────────────────────────────────────────────────────────────────────────

-- Who is on this server right now. The injected provider wins (Tier-1), then the engine, then an empty
-- roster. Only the memory prune reads this.
function OfflineService.roster(self: any): { any }
	local provider = self._players
	if type(provider) == "function" then
		local ok, injected = pcall(provider)
		if ok and type(injected) == "table" then
			return injected
		end
		return {}
	end
	local realGame: any = game
	if realGame == nil then
		return {} -- Lune: no engine roster. Specs inject one.
	end
	local ok, present = pcall(function()
		return realGame:GetService("Players"):GetPlayers()
	end)
	if ok and type(present) == "table" then
		return present
	end
	return {}
end

-- Drop pending records for players who have left. Per-server memory grows once per join otherwise, and
-- a server lives for hours. Done here rather than from a PlayerRemoving connection because the leave
-- sequence is PINNED and owned by framework/PlayerLifecycle (AMENDMENT A10b) — a second handler on
-- that signal runs in an order this game does not control.
--
-- An EMPTY roster prunes NOTHING: under Lune (and for a moment during a Studio boot) "nobody is here"
-- is indistinguishable from "the roster could not be read", and deleting a live session's computed
-- window would silently drop earnings that are already owed. Note the epoch check makes this purely a
-- memory hygiene measure — correctness never depends on it.
function OfflineService.prune(self: any): number
	local roster = self:roster()
	if #roster == 0 then
		return 0
	end
	local present: { [number]: boolean } = {}
	for _, player in roster do
		local userId = userIdOf(player)
		if userId ~= nil then
			present[userId] = true
		end
	end
	local dropped = 0
	for userId in self._pending do
		if not present[userId] then
			self._pending[userId] = nil
			self._claiming[userId] = nil
			dropped += 1
		end
	end
	return dropped
end

-- `task` is a real global in Roblox and NIL under Lune; reached through a guarded ref so this module
-- stays spec-callable. A spec can replace it to drive the join hook without sleeping.
function OfflineService._wait(_self: any, seconds: number): ()
	local realTask: any = task
	if realTask ~= nil and type(realTask.wait) == "function" then
		realTask.wait(seconds)
	end
end

-- THE MOST IMPORTANT FUNCTION IN THIS FILE. Bounded wait for this player's session, then close the
-- away window IMMEDIATELY — before autosaveTick can re-stamp `timestamps.lastSeenUnix` and erase it.
-- Everything else here is bookkeeping around this one race.
function OfflineService.prepareOnJoin(self: any, context: any, player: any): any
	for attempt = 1, self.loadWaitAttempts do
		local got = context.data:get(player)
		if type(got) == "table" and got.ok == true then
			local prepared = self:ensurePending(context, player)
			self:prune()
			return prepared
		end
		if attempt < self.loadWaitAttempts then
			self:_wait(self.loadWaitStepSeconds)
		end
	end
	return Result.err(Result.Codes.NoData, "offline: session never loaded for this player")
end

-- ── lifecycle ───────────────────────────────────────────────────────────────────────────────────

-- Start: reset the per-server state, register the wire surface, then — Roblox only — hook joins.
-- Installs NO ctx seam (see the header). Lune-callable: everything engine-shaped lives behind
-- startRuntime.
function OfflineService.Start(self: any, context: any): ()
	self._context = context
	self._pending = {}
	self._claiming = {}
	context.net:register(self:claimAction())
	context.net:register(self:peekAction())
	self:startRuntime(context)
end

-- ROBLOX-ONLY: the join hook. Players already present are covered too (a Studio Play session installs
-- scripts after the local player has joined, so there is no PlayerAdded to ride) — without that branch
-- the very first player of a Studio test never gets a window computed, which is precisely the case a
-- human is looking at when they judge this feature.
function OfflineService.startRuntime(self: any, context: any): ()
	local realGame: any = game
	local realTask: any = task
	if realGame == nil or realTask == nil or type(realTask.spawn) ~= "function" then
		return -- Lune: no engine to wire. Specs drive prepareOnJoin / the actions directly.
	end
	if self._running then
		return -- idempotent: a second Start must not connect a second join hook
	end
	self._running = true
	self._connections = {}

	local Players = realGame:GetService("Players")

	local function onAdded(player: any): ()
		-- pcall'd: prepareOnJoin waits on the data layer, and a throw here would kill the thread that
		-- is the ONLY thing standing between this player's away window and the next autosave.
		local ok, err = pcall(function()
			self:prepareOnJoin(context, player)
		end)
		if not ok then
			warn(`OfflineService: preparing the away window failed: {tostring(err)}`)
		end
	end

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

function OfflineService.Stop(self: any, _context: any): ()
	self._running = false
	for _, connection in self._connections do
		if connection ~= nil and type(connection.Disconnect) == "function" then
			connection:Disconnect()
		end
	end
	self._connections = {}
	self._pending = {}
	self._claiming = {}
	self._context = nil
end

return OfflineService
