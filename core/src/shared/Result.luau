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
