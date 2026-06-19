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
-- economy: Insufficient (player cannot afford a server-priced purchase)
-- authority: NotOwner, RateLimited, Rejected (panic flag)
-- routing/data: UnknownAction, NoData, Internal
-- lock contention (reserved now for the B2 SessionStore, never returned by MockStore):
--   SessionLocked, LockStolen
Result.Codes = {
	BadPayload = "BadPayload",
	BadType = "BadType",
	OutOfRange = "OutOfRange",
	Insufficient = "Insufficient",
	NotOwner = "NotOwner",
	RateLimited = "RateLimited",
	UnknownAction = "UnknownAction",
	NoData = "NoData",
	Internal = "Internal",
	Rejected = "Rejected",
	SessionLocked = "SessionLocked",
	LockStolen = "LockStolen",
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
