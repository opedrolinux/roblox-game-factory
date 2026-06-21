--!strict
-- games/collect-sim/src/server/services/offline/OfflineService.luau   [offline]
-- Feature: offline earnings. Passive collectors accrue CAPPED Stardust while the player is away,
-- claimed on join. The accrual base is the EXISTING server-written timestamps.lastSeenUnix (the data
-- layer stamps it on save/release/join) — NEVER a client-supplied time. On a claim the server derives
-- elapsed = ctx.clock:unix() - lastSeenUnix, computes a server-owned per-second rate scaled by the
-- player's CURRENT highest-unlocked-island mote value (ctx.islands:multiplierFor(d)), CAPS the grant at
-- a server-owned ceiling, credits Stardust, and advances lastSeenUnix to now so a re-claim accrues from
-- zero. Crediting offline Stardust is an EARN path: it also increments stats.lifetimeStardust and emits
-- currency_earned through ctx.analytics.
--
-- AUTHORITY (CLAUDE.md §3 / §7): the payload is the empty intent {} — NO client number is ever honored.
-- elapsed, rate, multiplier and the cap are ALL server-derived. A forged offline duration is impossible:
-- the server reads lastSeenUnix from the lock-held snapshot and clamps the grant to the cap, so a long
-- absence OR a tampered client clock yields nothing beyond the ceiling (spec "forgery yields nothing
-- extra").
--
-- STATE OWNERSHIP: NO feature-owned mutable state. The accrual base (timestamps.lastSeenUnix), the
-- balance (currencies.Stardust) and the lifetime counter (stats.lifetimeStardust) are ALL persisted
-- PlayerData. The rate, the cap and the per-second formula are module constants. So the action needs no
-- closed-over session state — everything mutates atomically inside the single update transform.
--
-- CONCURRENCY-SAFE EARN + IDEMPOTENT CLAIM (CLAUDE.md §4, the economy red-team target): the WHOLE
-- read-elapsed/grant/advance-base happens INSIDE ONE ctx.data:update transform on the lock-held re-read
-- snapshot. `now` is captured ONCE before the (possibly yielding) update (ctx.clock:unix() is stable for
-- the request) and is the SAME value the transform writes to lastSeenUnix. Because the transform runs
-- under the per-player FIFO lock on the FRESH snapshot, two interleaved or spam-duplicated claims
-- serialise: the FIRST advances lastSeenUnix to now and grants the accrual; the SECOND re-reads that
-- just-written lastSeenUnix, sees elapsed = now - now = 0, grants nothing and leaves the balance
-- untouched. There is NO read-then-write across the yield — the transform body is synchronous and reads
-- ONLY the snapshot it is handed. This is what makes claiming twice in one session grant nothing the
-- second time (spec idempotency).
--
-- Dual-runtime require [D1 shim]: under Lune (script == nil) these resolve via the filesystem and touch
-- no Roblox global, so a spec drives the action through Mocks.net -> Net.dispatch. In Roblox, src/shared
-- maps to ReplicatedStorage.Shared (a DIFFERENT service than this ServerScriptService module), so the
-- relative string can't reach it — the script ~= nil branch requires it by instance.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

-- ----- SERVER-OWNED ACCRUAL CONSTANTS (authoritative; the client supplies NONE of this) -----
-- RATE_PER_SECOND: base Stardust accrued per second of offline time, BEFORE the island multiplier.
-- CAP: the server-owned ceiling on a single offline grant. A long absence or a forged clock can never
--      mint more than CAP * islandMultiplier — the cap is applied to the BASE accrual (rate*elapsed)
--      so the multiplier scales an already-bounded amount; the final grant is bounded by CAP*mult.
local RATE_PER_SECOND = 1 -- Stardust/sec base accrual (pre-multiplier)
local CAP = 7200 -- ceiling on the BASE accrual (rate*elapsed) — ~2h of accrual at rate 1

-- Pure accrual math over SERVER-derived inputs only. Given the elapsed seconds (server-derived, never
-- from the client) and the player's island multiplier, returns the granted Stardust:
--   base = clamp(rate * elapsed, 0, CAP)   -- a negative/zero elapsed (clock skew, fresh join) -> 0
--   grant = floor(base * islandMultiplier) -- whole number; the multiplier scales the CAPPED base
-- Deterministic, no side effects, no I/O. The cap is applied to the BASE so the ceiling holds
-- regardless of how large the forged elapsed is.
local function accrue(elapsed: number, islandMultiplier: number): number
	if elapsed ~= elapsed then
		return 0 -- NaN guard (defensive; elapsed is server-derived from two unix reads)
	end
	if elapsed <= 0 then
		return 0 -- no time away (or negative skew) -> nothing accrued
	end
	local base = RATE_PER_SECOND * elapsed
	if base > CAP then
		base = CAP -- CAP the base so a long absence / forged clock cannot mint unbounded Stardust
	end
	local mult = islandMultiplier
	if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
		mult = 1 -- nil-safe / defensive: a missing or bad multiplier defaults to identity 1
	end
	return math.floor(base * mult)
end

local OfflineService = { name = "OfflineService" }

-- Build the ClaimOffline action. No closed-over feature state: the accrual base, the balance and the
-- lifetime counter are ALL persisted PlayerData, mutated atomically inside the one update transform; the
-- rate and cap are module constants.
local function makeClaimOfflineAction(): Net.Action<
	{},
	{ claimed: boolean, granted: number, elapsed: number, balance: number }
>
	return {
		name = Net.Actions.ClaimOffline, -- "offline.claim"
		-- Claim-on-join is a deliberate, low-frequency action: a tight bucket so spam-duplicated claims
		-- are also rate-shed. The idempotency guarantee does NOT rely on this — it is defence in depth.
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload: must be a table; we accept ONLY the empty intent. Any client-smuggled
			-- time/now/elapsed/amount field is ignored by never being read (we never copy a field out of
			-- raw). The server derives elapsed from lastSeenUnix + ctx.clock:unix().
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(
			ctx,
			_payload
		): Result.Result<{ claimed: boolean, granted: number, elapsed: number, balance: number }>
			-- SERVER time, captured ONCE before the (possibly yielding) update. This is the ONLY clock
			-- read; the payload's time is never consulted. `now` is stable for the request and is the SAME
			-- value the transform writes to lastSeenUnix on success — so a second interleaved claim
			-- re-reading that timestamp sees elapsed = now - now = 0 and grants nothing.
			local now = ctx.clock:unix()

			-- ----- CONCURRENCY-SAFE, IDEMPOTENT OFFLINE EARN (the economy red-team target) -----
			-- The ENTIRE read-elapsed/grant/advance-base is made INSIDE the transform on the lock-held
			-- re-read snapshot. We capture the OUTCOME (granted / elapsed / new balance) into locals the
			-- transform closes over; the transform ALWAYS advances lastSeenUnix to `now` (so a re-claim
			-- accrues from zero) and adds the grant. Because it runs under the per-player FIFO lock on the
			-- freshest value, two interleaved claims serialise: the second re-reads the just-written
			-- lastSeenUnix (now - now = 0 elapsed -> grant 0). Nothing is read outside the transform and
			-- written inside.
			local outGranted = 0
			local outElapsed = 0
			local outBalance = 0

			local updated = ctx.data:update(ctx.player, function(d)
				-- Re-read the accrual base from the snapshot the lock handed us (post any earlier write).
				-- lastSeenUnix is server-written by the data layer on save/release/join; it is NEVER a
				-- client value. Nil-safe on the timestamps table for a minimal test snapshot.
				local timestamps = d.timestamps or {}
				local lastSeenUnix = (timestamps.lastSeenUnix or now)

				-- elapsed is SERVER-DERIVED from two server reads (now and the persisted base). A forged
				-- client clock cannot touch either operand.
				local elapsed = now - lastSeenUnix

				-- The island multiplier scales the accrual by the player's CURRENT highest-unlocked-island
				-- mote value, read PURELY from the lock-held snapshot `d` via the ctx.islands seam. Nil-safe:
				-- an unwired seam (the focused-test world) defaults the factor to identity 1.
				local islandMultiplier = 1
				if ctx.islands ~= nil then
					local m = (ctx.islands :: any):multiplierFor(d)
					if type(m) == "number" then
						islandMultiplier = m
					end
				end

				local granted = accrue(elapsed, islandMultiplier)

				-- ADVANCE THE BASE MONOTONICALLY toward `now` (the idempotency pivot): once we have read
				-- elapsed for this claim, the next claim must accrue from no earlier than `now`, whether or
				-- not the grant was non-zero — so a re-claim in the same session sees zero elapsed and grants
				-- nothing. CLAMP with math.max so the base can ONLY move forward: two genuinely concurrent
				-- claims capture DIFFERENT `now` values, and if the LATER-now claim's transform commits first
				-- (advancing the base ahead) and an EARLIER-now claim runs second, an unconditional write
				-- would pull the base BACKWARD by the inter-request delta and re-open an already-consumed
				-- accrual window (a bounded re-mint on the next claim). math.max(lastSeenUnix, now) makes the
				-- base monotonic, so a late, earlier-timestamped claim can never move it back.
				if d.timestamps == nil then
					d.timestamps = { firstJoinUnix = now, lastSeenUnix = now }
				else
					d.timestamps.lastSeenUnix = math.max(lastSeenUnix, now)
				end

				local balance = (d.currencies.Stardust or 0)
				if granted > 0 then
					-- Credit the server-derived grant and accrue the SAME amount into the monotonic lifetime
					-- counter (this is an EARN path). NIL-SAFE on d.stats for a minimal test snapshot.
					balance = balance + granted
					d.currencies.Stardust = balance
					if d.stats ~= nil then
						d.stats.lifetimeStardust = (d.stats.lifetimeStardust or 0) + granted
					end
				end

				outGranted = granted
				-- Report the (non-negative) elapsed window the grant was derived from; clamp the reported
				-- value at 0 so a fresh-join / clock-skew negative window reads as 0 rather than negative.
				outElapsed = math.max(0, elapsed)
				outBalance = balance
				return d
			end)

			if not updated.ok then
				-- The data write itself failed (e.g. NoData / transient). Surface it; the transform returns
				-- `d` whole on every path, so there is no partial change to undo.
				return updated
			end

			-- Emit currency_earned AFTER a successful grant, ONLY when something was actually granted (a
			-- zero-grant re-claim is not an earn event). NIL-SAFE: ctx.analytics is nil in focused tests, so
			-- this is a no-op there; a wired AnalyticsService records it.
			if outGranted > 0 and ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("currency_earned", {
					userId = ctx.player.UserId,
					currency = "Stardust",
					amount = outGranted,
					source = "offline",
				})
			end

			return Result.ok({
				claimed = true,
				granted = outGranted,
				elapsed = outElapsed,
				balance = outBalance,
			})
		end,
	}
end

-- Start: register the single ClaimOffline action on the gateway. No closed-over mutable feature state —
-- the rate and cap are constants and all mutation lives in the persisted data layer.
function OfflineService:Start(context: any): ()
	context.net:register(makeClaimOfflineAction())
end

return OfflineService
