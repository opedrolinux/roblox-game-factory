--!strict
-- games/collect-sim/src/server/services/daily/DailyStreakService.luau   [daily-streak]
-- Feature: the once-per-day login reward. Claiming grants escalating Stardust based on a streak
-- counter, and the WHOLE thing is SERVER-CLOCK gated — the time comes from ctx.clock:unix(), NEVER
-- from the payload (the payload is the empty intent {}; no client number is ever honored).
--
-- Server-owned time windows (pinned EXACT so behavior is gradable):
--   COOLDOWN     = 72000s (20h): a claim is allowed only once at least COOLDOWN seconds have
--                  elapsed since the last claim (now - lastClaimUnix >= COOLDOWN). Sooner -> OnCooldown.
--   STREAK_RESET = 172800s (48h): if MORE than STREAK_RESET seconds elapsed since the last claim,
--                  the streak RESETS to 1 (the player let it lapse); otherwise it INCREMENTS by 1.
--                  The very first claim ever (lastClaimUnix == 0) starts the streak at 1.
-- Reward is server-DERIVED from the (new) streak: BASE_REWARD * streak, clamped at REWARD_CAP.
-- The client never supplies an amount.
--
-- CONCURRENCY (the economy red-team target — the time-gate analog of a double-spend): both operands
-- of the decision (daily.lastClaimUnix / daily.streak / currencies.Stardust) are PERSISTED, so the
-- ENTIRE read-check-write — re-read lastClaimUnix + streak + balance from the lock-held snapshot,
-- compute the decision against now, then on success write all three — is performed INSIDE ONE
-- ctx.data:update transform. That transform runs under the per-player FIFO lock on a FRESH re-read
-- snapshot (MockStore §4.1 / DataService.update), so it is atomic: an interleaved or spam-duplicated
-- daily.claim re-reads the JUST-WRITTEN lastClaimUnix (now - now = 0 < COOLDOWN) and is shed as
-- OnCooldown. It can never double-grant Stardust, never double-increment the streak. `now` is
-- captured ONCE before the transform (ctx.clock:unix() is stable for the request) and is the SAME
-- value the transform writes, so the second claimant's re-read genuinely sees a zero-elapsed window.
-- There is NO read-then-write across the yield: the transform body is synchronous and reads only the
-- snapshot it is handed.
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

-- ----- SERVER-OWNED TIME WINDOWS + REWARD CURVE (authoritative; the client supplies none of this) -----
local COOLDOWN = 72000 -- 20h: minimum elapsed seconds between claims.
local STREAK_RESET = 172800 -- 48h: more than this elapsed -> the streak lapsed, resets to 1.
local BASE_REWARD = 100 -- Stardust granted at streak 1; scales linearly with the streak.
local REWARD_CAP = 1000 -- ceiling so a long streak cannot mint unbounded Stardust.

-- Reward DERIVED from the (new) streak. Relational only: base * streak, clamped at the cap.
local function rewardForStreak(streak: number): number
	return math.min(REWARD_CAP, BASE_REWARD * streak)
end

local DailyStreakService = { name = "DailyStreakService" }

-- Build the Daily claim action. No closed-over feature state is needed: the streak, the last-claim
-- timestamp, and the Stardust balance are ALL persisted PlayerData, mutated atomically inside the
-- single update transform; the time windows are module constants.
local function makeDailyClaimAction(): Net.Action<
	{},
	{ claimed: boolean, streak: number, reward: number, balance: number }
>
	return {
		name = Net.Actions.Daily, -- "daily.claim"
		-- Deliberate, low-frequency action (once per ~day): a tight bucket so spam-duplicated claims
		-- are also rate-shed. The concurrency guarantee does NOT rely on this — it is defence in depth.
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload: must be a table; we accept ONLY the empty intent. Any client-smuggled
			-- time/now/reward field is ignored by never being read (we never copy a field out of raw).
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(
			ctx,
			_payload
		): Result.Result<{ claimed: boolean, streak: number, reward: number, balance: number }>
			-- SERVER time, captured ONCE before the (possibly yielding) update. This is the ONLY clock
			-- read; the payload's time is never consulted. `now` is stable for the request, and is the
			-- SAME value the transform writes to lastClaimUnix on success — so a second interleaved
			-- claim re-reading that timestamp sees now - now = 0 elapsed and is shed as OnCooldown.
			local now = ctx.clock:unix()

			-- ----- SERVER-CLOCK-GATED CLAIM (the economy red-team target) -----
			-- The ENTIRE decision is made INSIDE the transform, on the lock-held re-read snapshot. We
			-- capture the OUTCOME (new streak / reward / new balance, or a rejection code) into locals
			-- the transform closes over; the transform mutates `d` ONLY on success and returns `d`
			-- unchanged on the cooldown rejection. Because it runs under the per-player FIFO lock on
			-- the freshest value, two interleaved claims serialise: the second re-reads the already-
			-- written lastClaimUnix and is rejected. Nothing is read outside the transform and written
			-- inside.
			local rejectCode: string? = nil
			local outStreak = 0
			local outReward = 0
			local outBalance = 0

			local updated = ctx.data:update(ctx.player, function(d)
				-- Re-read the CURRENT streak / last-claim timestamp / balance from the snapshot the
				-- lock handed us (post any earlier write).
				local lastClaimUnix = (d.daily.lastClaimUnix or 0)
				local prevStreak = (d.daily.streak or 0)
				local balance = (d.currencies.Stardust or 0)

				-- Within cooldown: a prior claim exists AND not enough time has elapsed. NO grant, NO
				-- streak/timestamp change. (lastClaimUnix == 0 means first-ever claim -> never on cooldown.)
				if lastClaimUnix ~= 0 and (now - lastClaimUnix) < COOLDOWN then
					rejectCode = Result.Codes.OnCooldown
					return d
				end

				-- Claimable. Compute the new streak:
				--   first-ever claim (lastClaimUnix == 0)        -> 1
				--   lapsed (more than STREAK_RESET elapsed)      -> 1 (reset)
				--   otherwise (within the reset window)          -> previous + 1
				local newStreak: number
				if lastClaimUnix == 0 or (now - lastClaimUnix) > STREAK_RESET then
					newStreak = 1
				else
					newStreak = prevStreak + 1
				end

				local reward = rewardForStreak(newStreak)
				local newBalance = balance + reward

				-- Write all three synchronously inside this one lock-held transform (no yield): stamp
				-- the claim time to `now`, advance the streak, and ADD the server-derived reward.
				d.daily.lastClaimUnix = now
				d.daily.streak = newStreak
				d.currencies.Stardust = newBalance
				-- Lifetime accrual: the daily reward is an EARN, so add the SAME amount to the monotonic
				-- lifetimeStardust counter inside this one lock-held transform. NIL-SAFE on d.stats so a
				-- minimal test snapshot without stats cannot crash the grant.
				if d.stats ~= nil then
					d.stats.lifetimeStardust = (d.stats.lifetimeStardust or 0) + reward
				end

				outStreak = newStreak
				outReward = reward
				outBalance = newBalance
				return d
			end)

			if not updated.ok then
				-- The data write itself failed (e.g. NoData / transient). Surface it; the transform
				-- returns `d` whole (no partial change), so there is nothing to undo.
				return updated
			end

			-- A cooldown rejection decided INSIDE the transform (snapshot-based). No mutation happened,
			-- so streak / lastClaimUnix / Stardust are unchanged and persisted as-is.
			if rejectCode ~= nil then
				return Result.err(rejectCode :: string)
			end

			-- Emit currency_earned AFTER a successful claim. NIL-SAFE: ctx.analytics is nil in the spine
			-- (and the existing tests), so this is a no-op there; a wired AnalyticsService records it.
			if ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("currency_earned", {
					userId = ctx.player.UserId,
					currency = "Stardust",
					amount = outReward,
					source = "daily",
				})
			end

			return Result.ok({
				claimed = true,
				streak = outStreak,
				reward = outReward,
				balance = outBalance,
			})
		end,
	}
end

-- Start: register the single Daily claim action on the gateway. No closed-over mutable feature
-- state — the time windows are constant and all mutation lives in the persisted data layer.
function DailyStreakService:Start(context: any): ()
	context.net:register(makeDailyClaimAction())
end

return DailyStreakService
