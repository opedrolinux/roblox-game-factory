--!strict
-- core/src/server/data/Store.luau
-- The low-level persistence INTERFACE. MockStore (spine) and SessionStore (B2) both
-- implement it, unchanged. All methods may yield and return a Result (no throwing across
-- the boundary). Lune-clean: under Lune (script == nil) the relative require resolves; in Roblox
-- src/shared maps to ReplicatedStorage.Shared (a different service), so require by instance. [D1 shim]
local Result
if script == nil then
	Result = require("../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Result = require((Shared :: any).Result)
end
type Result<T> = Result.Result<T>

-- A loaded, session-locked record. The lock is the single-writer guarantee: only the server
-- holding the lock may write; a second server's load waits/steals per the impl's policy
-- (B2 SessionStore). The mock grants instantly (single process).
export type Session<T> = {
	key: string,
	data: T, -- the current in-memory value (already migrated)
	-- Replace the in-memory value (does NOT write to backing store).
	set: (self: Session<T>, value: T) -> (),
	-- Atomically transform under a PER-KEY LOCK QUEUE (read-modify-write); the canonical
	-- concurrency-safe mutation. Returns the new value. See the §4.1 lock-queue contract.
	update: (self: Session<T>, transform: (current: T) -> T) -> Result<T>,
	-- Flush the in-memory value to the backing store (throttled + retried per budget).
	save: (self: Session<T>) -> Result<T>,
	-- Save (final) + release the session lock. Idempotent.
	release: (self: Session<T>) -> Result<T>,
}

export type Store = {
	-- Acquire a session lock for `key`, returning the migrated value (or a fresh default).
	-- `default` supplies the new-record value when the key is empty.
	-- May return Err("SessionLocked") if another server holds the lock and it cannot acquire
	-- within budget (B2 contention seam); the mock never returns it (single process).
	load: (self: Store, key: string, default: () -> any) -> Result<Session<any>>,
	-- True if this Store currently holds a session for `key` (single-writer check).
	isLocked: (self: Store, key: string) -> boolean,
}

local Store = {}

-- The module exports the TYPES + any shared helpers; impls are separate files. No instances
-- are created here — Store is the contract, MockStore/SessionStore are the implementations.
return Store
