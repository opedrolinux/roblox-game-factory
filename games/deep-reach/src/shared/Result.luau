--!strict
-- core/src/shared/Result.luau
-- The cross-boundary result type. No exceptions cross the Net boundary — every handler
-- and every client call returns a Result. Lune-clean LEAF: requires nothing (everyone
-- requires IT). See docs/CORE-DESIGN.md §3.1.

export type Ok<T> = { ok: true, value: T }
export type Err = { ok: false, code: string, message: string? }
export type Result<T> = Ok<T> | Err

local Result = {}

-- Stable error codes the spine defines (B2 extends, never renames). Documented in §3.1.
-- type/range/payload: BadPayload, BadType, OutOfRange
-- authority: NotOwner, RateLimited, Rejected (panic flag)
-- routing/data: UnknownAction, NoData, Internal
-- lock contention (returned by the B2 SessionStore; MockStore returns them ONLY under the
-- D6 test hooks returnSessionLocked/stealLockAfter): SessionLocked, LockStolen
-- session lifecycle: SessionClosed — this SESSION was torn down (released/abandoned) and may
--   never write again. Distinct from LockStolen (which means another SERVER owns the record and
--   triggers a dead-session kick): SessionClosed is normal, expected, and must NOT kick anyone,
--   because the live replacement session for that player is usually healthy.
Result.Codes = {
	BadPayload = "BadPayload",
	BadType = "BadType",
	OutOfRange = "OutOfRange",
	NotOwner = "NotOwner",
	RateLimited = "RateLimited",
	UnknownAction = "UnknownAction",
	NoData = "NoData",
	Internal = "Internal",
	Rejected = "Rejected",
	SessionLocked = "SessionLocked",
	LockStolen = "LockStolen",
	SessionClosed = "SessionClosed",

	-- [contract pass] Deep Reach's game-state refusals. The scaffold genuinely lacks these (they
	-- exist only in collect-sim), and every spend / cooldown / prerequisite path in the plan returns
	-- one of them. Each is a code the spine could NOT already express:
	-- A CURRENCY shortfall: the balance does not cover the cost (structures.buy, depth.descend, and
	--   salvage.collect on an empty smelter). Not OutOfRange (that is a payload-range failure, not a
	--   balance state) and not Rejected (the panic refusal).
	Insufficient = "Insufficient",
	-- A GAME cooldown has not elapsed: the daily supply drop before its 20-22h window opens.
	--   Deliberately NOT RateLimited — that is the Gate's per-action anti-spam token bucket, and
	--   conflating a 20-hour game cooldown with it makes the daily-window test indistinguishable
	--   from a rate-limit test.
	OnCooldown = "OnCooldown",
	-- A NON-CURRENCY prerequisite is unmet: hull below the tier minimum, the previous tier not
	--   unlocked, the VIP-trench flag absent, or resurfacing below the minimum depth. Kept separate
	--   from Insufficient so "the pressure gate holds" is testable — a hull-too-low refusal and a
	--   plain can't-afford refusal must not be the same code.
	PrereqUnmet = "PrereqUnmet",
	-- The resource EXISTS but none is free right now: every dome plot on this server is held. Not
	--   NoData ("no record for this key"), not Internal (this is a normal capacity state).
	Unavailable = "Unavailable",
	-- This player ALREADY holds one: a second plot claim. Rejected cannot serve here — Net.dispatch
	--   returns exactly Rejected for the panic flag, so "a second claim is refused" would be
	--   byte-indistinguishable from "the server is panicked and refusing all client writes".
	AlreadyClaimed = "AlreadyClaimed",
}

function Result.ok<T>(value: T): Ok<T>
	return { ok = true, value = value }
end

function Result.err(code: string, message: string?): Err
	return { ok = false, code = code, message = message }
end

-- Convenience predicates (kept tiny; tests use these to stay readable).
function Result.isOk(result: Result<any>): boolean
	return result.ok == true
end

function Result.isErr(result: Result<any>): boolean
	return result.ok == false
end

return Result
