--!strict
-- core/src/server/data/MockStore.luau
-- In-memory implementation of the Store interface. The spine runtime default AND the Tier-1
-- fixture. Lune-clean (under Lune the relative require resolves with no Roblox global run — note: it
-- uses ONLY coroutine.*, never the Roblox `task` global, which is nil under Lune). Implements the §4.1
-- per-key FIFO lock queue LITERALLY so the anti-double-spend guarantee is genuinely tested (§9.3).
-- See docs/CORE-DESIGN.md §4.2.
-- [D1 shim] In Roblox src/shared maps to ReplicatedStorage.Shared (a different service) -> require by instance.
local Result
if script == nil then
	Result = require("../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Result = require((Shared :: any).Result)
end
type Result<T> = Result.Result<T>

export type ClockLike = {
	unix: (self: any) -> number,
	mono: (self: any) -> number,
}
export type ConfigLike = {
	dataStore: {
		maxRetries: number,
		retryBaseSeconds: number,
		writeMinIntervalSeconds: number,
	},
}

export type MockOptions = {
	clock: ClockLike, -- injected (required)
	config: ConfigLike, -- injected: supplies maxRetries / writeMinIntervalSeconds
	failLoad: boolean?,
	failSave: boolean?,
	throttleSaves: number?, -- first N saves per key return a throttled Err, then succeed
	yieldOnUpdate: boolean?, -- force a yield in the update critical section (race tests)
	seed: { [string]: any }?, -- preload keys
	-- [B2 D6] session-lock contention hooks, so the DataService reactions are Tier-1-testable
	-- (falsify-first) without a real store (B2-SESSIONSTORE-DESIGN §11):
	returnSessionLocked: number?, -- first N loads per key return Err(SessionLocked), then grant
	stealLockAfter: number?, -- after N successful saves per key, every save returns Err(LockStolen)
}

-- Internal per-key lock state. `held` is true while a transform owns the critical section;
-- `queue` is a FIFO of parked coroutines waiting to acquire (§4.1 step 1).
type LockState = {
	held: boolean,
	queue: { thread },
}

-- Deep copy a value (tables recursively; scalars as-is). A real DataStore deserializes a FRESH
-- copy on every read, so the mock does too: `update`'s transform operates on a SNAPSHOT, not the
-- live backing table. This is what makes the lost-update race REAL (and the §9.3 test
-- falsifiable): a stale snapshot read (naive read->yield->write, no re-read) genuinely loses the
-- other update's write, whereas the lock-queue re-read snapshots the post-write value.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = deepCopy(child)
	end
	return out
end

local MockStore = {}

function MockStore.new(options: MockOptions): any
	local clock = options.clock
	local config = options.config

	-- The backing "DataStore": key -> stored value.
	local backing: { [string]: any } = {}
	if options.seed ~= nil then
		for key, value in options.seed do
			backing[key] = value
		end
	end

	local locks: { [string]: LockState } = {}
	local heldKeys: { [string]: boolean } = {}
	-- Per-key save bookkeeping for throttle + retry simulation.
	local saveThrottleRemaining: { [string]: number } = {}
	local lastWriteMono: { [string]: number } = {}
	-- [B2 D6] per-key contention-hook bookkeeping.
	local sessionLockedRemaining: { [string]: number } = {}
	local successfulSaves: { [string]: number } = {}

	local function getLock(key: string): LockState
		local state = locks[key]
		if state == nil then
			state = { held = false, queue = {} }
			locks[key] = state
		end
		return state
	end

	-- Acquire the per-key lock; if held, park THIS coroutine in the FIFO and YIELD (does NOT
	-- read the value yet — §4.1 step 1). When resumed by release(), the lock is ours.
	local function acquire(key: string): ()
		local state = getLock(key)
		if not state.held then
			state.held = true
			return
		end
		local co = coroutine.running()
		table.insert(state.queue, co)
		coroutine.yield()
		-- Resumed by release(): the lock was handed to us; state.held stays true.
	end

	-- Release the per-key lock; resume the next FIFO waiter DIRECTLY (synchronous handoff) so
	-- it performs its own re-read (§4.1 step 2). Uses coroutine.resume, never `task` (Lune-safe).
	local function release(key: string): ()
		local state = getLock(key)
		local nextCo = table.remove(state.queue, 1)
		if nextCo ~= nil then
			-- Hand the lock to the next waiter (it stays held) and resume it now.
			local ok, err = coroutine.resume(nextCo)
			if not ok then
				warn(`MockStore.release: resumed waiter errored: {tostring(err)}`)
			end
		else
			state.held = false
		end
	end

	local Store = {}

	function Store.isLocked(_: any, key: string): boolean
		return heldKeys[key] == true
	end

	function Store.load(_: any, key: string, default: () -> any): Result<any>
		if options.failLoad then
			return Result.err(Result.Codes.Internal, "MockStore.failLoad")
		end

		-- [B2 D6] returnSessionLocked: the first N loads per key see another server's live lock,
		-- so DataService's SessionLocked wait budget (incl. the exhaustion->kick path) is testable.
		if options.returnSessionLocked ~= nil then
			if sessionLockedRemaining[key] == nil then
				sessionLockedRemaining[key] = options.returnSessionLocked
			end
			if sessionLockedRemaining[key] > 0 then
				sessionLockedRemaining[key] -= 1
				return Result.err(Result.Codes.SessionLocked, "MockStore.returnSessionLocked")
			end
		end

		-- Single-process mock: grant the session lock instantly.
		heldKeys[key] = true
		if backing[key] == nil then
			backing[key] = default()
		end

		local session = {}
		session.key = key
		session.data = backing[key]
		-- Session-lifecycle state, mirroring SessionStore: set only by teardown.
		local released = false

		function session.set(self: any, value: any): ()
			self.data = value
			backing[key] = value
		end

		function session.update(self: any, transform: (current: any) -> any): Result<any>
			-- §4.1 step 1: acquire (park + yield in FIFO if already held — re-read AFTER).
			acquire(key)

			-- §4.1 step 2: now we own the lock — (re-)read the LATEST value as a fresh SNAPSHOT,
			-- after any earlier update has written. Never start from stale state. The snapshot
			-- (deepCopy) is what makes a lost update REAL if the queue were absent (§9.3).
			local current = deepCopy(backing[key])

			-- yieldOnUpdate forces a yield INSIDE the critical section (lock STILL held) so a
			-- concurrent same-key update arriving now is FORCED to park — the mechanism the
			-- §9.3 race test exercises. The test driver resumes this coroutine to continue.
			if options.yieldOnUpdate then
				coroutine.yield()
				-- With the lock held, no other writer ran; re-snapshot defensively (same value).
				current = deepCopy(backing[key])
			end

			-- §4.1 step 3: run the SYNCHRONOUS transform and write the result back to backing.
			-- pcall'd: the transform is feature code and CAN throw, and `locks` outlives the
			-- session — an error escaping here would leak the per-key lock forever, parking every
			-- later update on this key with nothing to resume it (that player's economy actions
			-- hang, surviving release AND rejoin). The transform works on a SNAPSHOT, so a
			-- half-applied mutation is discarded rather than written back.
			local ok, newValueOrErr = pcall(transform, current)
			if not ok then
				release(key)
				return Result.err(
					Result.Codes.Internal,
					`MockStore.update: transform errored: {tostring(newValueOrErr)}`
				)
			end
			backing[key] = newValueOrErr
			self.data = newValueOrErr

			-- §4.1 step 4: release the lock and resume the next FIFO waiter (which re-reads).
			release(key)

			return Result.ok(newValueOrErr)
		end

		-- One durable-write attempt. `bypassFloor` is the release path: the final write must not
		-- be refused by the per-key throttle floor (skipping it would lose the session's delta) —
		-- the same split SessionStore.persist makes, so the fixture models the real policy.
		local function persist(self: any, bypassFloor: boolean): Result<any>
			-- A torn-down session may never write again — mirrors SessionStore.persist. Modelled
			-- here because the production hazard (a stale session's parked write landing on top of
			-- its live same-server replacement) is invisible to the DataStore lock stamp, which
			-- identifies the server rather than the session, so ONLY the fixture can falsify it
			-- at Tier-1.
			if released then
				return Result.err(Result.Codes.SessionClosed, "MockStore.sessionClosed")
			end

			-- [B2 D6] stealLockAfter: after N successful saves the session lock has been re-claimed
			-- by "another server" — every further save is a PERMANENT LockStolen (never retryable),
			-- exactly the §4.2 write-exclusion outcome, so the terminal reaction is testable.
			if
				options.stealLockAfter ~= nil
				and (successfulSaves[key] or 0) >= options.stealLockAfter
			then
				return Result.err(Result.Codes.LockStolen, "MockStore.stealLockAfter")
			end

			if options.failSave then
				return Result.err(Result.Codes.Internal, "MockStore.failSave")
			end

			-- throttleSaves: the first N save attempts per key return a throttled Err so the
			-- retry-per-budget path is testable without real DataStores.
			if saveThrottleRemaining[key] == nil then
				saveThrottleRemaining[key] = options.throttleSaves or 0
			end
			if saveThrottleRemaining[key] > 0 then
				saveThrottleRemaining[key] -= 1
				return Result.err(Result.Codes.Internal, "MockStore.throttled")
			end

			-- Throttle floor against the INJECTED clock (writeMinIntervalSeconds).
			if not bypassFloor then
				local nowMono = clock:mono()
				local last = lastWriteMono[key]
				local minInterval = config.dataStore.writeMinIntervalSeconds
				if last ~= nil and (nowMono - last) < minInterval then
					return Result.err(Result.Codes.Internal, "MockStore.writeMinInterval")
				end
			end

			lastWriteMono[key] = clock:mono()
			backing[key] = self.data
			successfulSaves[key] = (successfulSaves[key] or 0) + 1
			return Result.ok(self.data)
		end

		function session.save(self: any): Result<any>
			return persist(self, false)
		end

		-- Terminal teardown: stop reporting the key as held. Mirrors SessionStore.teardown.
		local function teardown(): ()
			released = true
			heldKeys[key] = nil
		end

		-- Final save + release the session lock.
		-- Idempotent on SUCCESS, RETRYABLE on transient failure — the SessionStore contract, which
		-- this fixture MUST model or Tier-1 cannot reach the production failure state: a transient
		-- final write leaves the session ALIVE and the key HELD so the caller's retry budget can
		-- reach it, and only a success or a terminal LockStolen tears down. (This previously
		-- cleared the key unconditionally, the exact inverse of production — which is why an
		-- orphaned-session regression in SessionStore sat green through the whole suite.)
		function session.release(self: any): Result<any>
			if released then
				-- Mirrors SessionStore: a second release wrote nothing, so it must not report a
				-- successful final save.
				return Result.err(Result.Codes.SessionClosed, "MockStore.sessionClosed")
			end
			local saved = persist(self, true)
			if not saved.ok and (saved :: any).code ~= Result.Codes.LockStolen then
				return saved -- transient: stay live, stay held, let the caller retry
			end
			teardown()
			return saved
		end

		-- Terminal give-up without a write: the caller has exhausted its retry budget or is
		-- replacing this session. Mirrors SessionStore.abandon — without it an exhausted release
		-- would leave the key held forever.
		function session.abandon(_self: any): ()
			teardown()
		end

		return Result.ok(session)
	end

	return Store
end

return MockStore
