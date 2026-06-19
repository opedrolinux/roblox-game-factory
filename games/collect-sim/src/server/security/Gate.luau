--!strict
-- core/src/server/security/Gate.luau
-- The minimal spine rate/ownership gate. Original, Lune-clean (relative require + injected
-- clock, no Roblox global). The seed B2's full RateLimiter/ViolationTracker grow from, behind
-- the same Net.dispatch call site. See docs/CORE-DESIGN.md §3.6.
local Result = require("../../shared/Result")
type Result<T> = Result.Result<T>

export type ClockLike = {
	mono: (self: any) -> number,
}

export type RatePolicy = {
	maxPerWindow: number,
	windowSeconds: number,
	burst: number?,
}

export type Gate = {
	-- Token-bucket rate check keyed by (userId, actionName), measured on the MONOTONIC clock.
	-- Returns ok or Err("RateLimited"). Pure logic over an injected clock => Tier-1 testable.
	check: (self: Gate, userId: number, actionName: string, policy: RatePolicy) -> Result<true>,
	-- Ownership assertion helper: a feature passes the acting userId + the claimed owner;
	-- returns Err("NotOwner") on mismatch.
	assertOwner: (self: Gate, actingUserId: number, ownerUserId: number) -> Result<true>,
}

-- Per-bucket token state.
type Bucket = {
	tokens: number,
	lastRefillMono: number,
}

local Gate = {}

-- clock is injected (the server Clock §5). Buckets live in-memory keyed by "userId|actionName".
-- Token-bucket: capacity = burst (or maxPerWindow); refill rate = maxPerWindow / windowSeconds
-- tokens per second, measured on mono() (process-local, never persisted — §5).
function Gate.new(clock: ClockLike): Gate
	local buckets: { [string]: Bucket } = {}

	local self = {}

	function self.check(
		_: Gate,
		userId: number,
		actionName: string,
		policy: RatePolicy
	): Result<true>
		local capacity = policy.burst or policy.maxPerWindow
		local windowSeconds = policy.windowSeconds
		if windowSeconds <= 0 or policy.maxPerWindow <= 0 then
			-- A degenerate policy means "no allowance" — reject rather than divide by zero.
			return Result.err(Result.Codes.RateLimited, "degenerate rate policy")
		end
		local refillPerSecond = policy.maxPerWindow / windowSeconds

		local bucketKey = `{userId}|{actionName}`
		local now = clock:mono()
		local bucket = buckets[bucketKey]
		if bucket == nil then
			bucket = { tokens = capacity, lastRefillMono = now }
			buckets[bucketKey] = bucket
		end

		-- Refill since last check (clamped to capacity).
		local elapsed = now - bucket.lastRefillMono
		if elapsed > 0 then
			bucket.tokens = math.min(capacity, bucket.tokens + elapsed * refillPerSecond)
			bucket.lastRefillMono = now
		end

		if bucket.tokens < 1 then
			return Result.err(Result.Codes.RateLimited, actionName)
		end

		bucket.tokens -= 1
		return Result.ok(true)
	end

	function self.assertOwner(_: Gate, actingUserId: number, ownerUserId: number): Result<true>
		if actingUserId ~= ownerUserId then
			return Result.err(Result.Codes.NotOwner, "acting player does not own target")
		end
		return Result.ok(true)
	end

	return (self :: any) :: Gate
end

return Gate
