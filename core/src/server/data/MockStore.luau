--!strict
-- core/src/server/data/MockStore.luau
-- In-memory implementation of the Store interface. The spine runtime default AND the Tier-1
-- fixture. Lune-clean (relative require, no Roblox global — note: it uses ONLY coroutine.*,
-- never the Roblox `task` global, which is nil under Lune). Implements the §4.1 per-key FIFO
-- lock queue LITERALLY so the anti-double-spend guarantee is genuinely tested (§9.3).
-- See docs/CORE-DESIGN.md §4.2.
local Result = require("../../shared/Result")
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

		-- Single-process mock: grant the session lock instantly.
		heldKeys[key] = true
		if backing[key] == nil then
			backing[key] = default()
		end

		local session = {}
		session.key = key
		session.data = backing[key]

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
			local newValue = transform(current)
			backing[key] = newValue
			self.data = newValue

			-- §4.1 step 4: release the lock and resume the next FIFO waiter (which re-reads).
			release(key)

			return Result.ok(newValue)
		end

		function session.save(self: any): Result<any>
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
			local nowMono = clock:mono()
			local last = lastWriteMono[key]
			local minInterval = config.dataStore.writeMinIntervalSeconds
			if last ~= nil and (nowMono - last) < minInterval then
				return Result.err(Result.Codes.Internal, "MockStore.writeMinInterval")
			end

			lastWriteMono[key] = nowMono
			backing[key] = self.data
			return Result.ok(self.data)
		end

		function session.release(self: any): Result<any>
			-- Final save then release. Idempotent: releasing an already-released key is ok.
			local saved = session.save(self)
			heldKeys[key] = nil
			if not saved.ok then
				return saved
			end
			return Result.ok(self.data)
		end

		return Result.ok(session)
	end

	return Store
end

return MockStore
