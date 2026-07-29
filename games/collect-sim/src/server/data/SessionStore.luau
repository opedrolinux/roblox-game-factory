--!strict
-- core/src/server/data/SessionStore.luau
-- The B2 REAL persistence layer: a session-locked DataStore behind the UNCHANGED `Store`
-- interface (B2-SESSIONSTORE-DESIGN §3–§7) — feature code and every Tier-1 spec see no
-- difference. ROBLOX-ONLY: touches DataStoreService/MemoryStoreService/HttpService/game.JobId/
-- task at module + construct scope and is NEVER required under Lune (the T0.5 require gate
-- treats it as reachable-not-executed; Tier-1 proves the POLICY via MockStore's D6 hooks; the
-- store's REAL behavior — persistence across rejoin, cross-server single-writer, TTL expiry —
-- is Tier-2 in-engine territory per §11).
--
-- Two-layer concurrency model (§2):
--   in-process : the §4.1 per-key FIFO queue (byte-for-byte MockStore's) — same-server writers.
--   cross-server: the session lock — a MemoryStore short-TTL LIVENESS lock (auto-expires on
--   crash, dissolving the H1 crash-rejoin kick-loop) + a DataStore lockId STAMP re-checked
--   atomically inside every UpdateAsync (the authoritative write-exclusion closing the
--   MemoryStore↔DataStore TOCTOU — an evaporated/lying MemoryStore lock can cause brief
--   contention, never a double-write).
--
-- AMENDMENT to §4.1/§4.2 (made while building; flagged for the independent review): `load`
-- performs an ATOMIC read+stamp UpdateAsync (not a GetAsync read): one transform stamps
-- lockId=myId AND returns the record. Two reasons. (a) Crash recovery: a hard crash leaves the
-- dead server's stamp in the record; §4.2-as-written would make every save by the NEXT
-- legitimate owner refuse forever (stored.lockId ~= myId). The MemoryStore claim is the
-- authority to take over, so the claim-holder may overwrite a stale stamp — at load, atomically.
-- (b) It closes the claim→first-save window: a zombie's write lands either BEFORE our
-- read+stamp (we read it — nothing lost) or AFTER (it sees our stamp and refuses). Never a
-- silent clobber.
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

-- Roblox-only module: require shared contracts by instance (no Lune branch to keep honest).
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Result = require((Shared :: any).Result)
type Result<T> = Result.Result<T>

export type SessionStoreOptions = {
	clock: any, -- injected Clock (mono/unix) — the SAME clock DataService budgets against
	config: any, -- the game Config (storeName + dataStore tunables §8)
}

-- Internal per-key lock state for the in-process FIFO (§4.1, identical to MockStore).
type LockState = {
	held: boolean,
	queue: { thread },
}

-- Deep copy (tables recursively; scalars as-is). The update critical section snapshots the
-- current value before the transform, exactly like MockStore's deserialize-fresh semantics, so
-- a transform that errors midway can never leave a half-mutated live value.
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

local SessionStore = {}

function SessionStore.new(options: SessionStoreOptions): any
	local clock = options.clock
	local config = options.config
	local budget = config.dataStore

	-- §8 tunables (defensive defaults in case a game's config fork predates B2). Each is clamped
	-- to a sane floor: a 0 in a game's config fork must never mean "wait forever" (0 reads as
	-- truthy in Lua, so `or` alone does not catch it).
	local lockTtl: number = math.max(budget.lockTtlSeconds or 30, 1)
	local heartbeatInterval: number = math.max(budget.heartbeatIntervalSeconds or 15, 1)
	local writeMinInterval: number = budget.writeMinIntervalSeconds or 6
	-- §7's real constraint is a per-SERVER budget of ~(60 + 10·players) writes/min, so a single
	-- static number cannot model it: on a 50-player server a flat 60 throttles to ~1/9 of the
	-- real allowance (and starves both the autosave pass and the shutdown flush). Model both
	-- terms; capacity is recomputed from the live session count on every token take.
	local writesBase: number = math.max(budget.globalWritesPerMinute or 60, 1)
	local writesPerPlayer: number = math.max(budget.globalWritesPerPlayerPerMinute or 10, 0)

	-- [D2] the per-server-lifetime writer identity: game.JobId is unique + non-empty on live
	-- servers and EMPTY in Studio solo — fall back to one GUID per store instance there.
	-- TODO(verify): game.JobId is non-empty + unique per live server (empty in Studio solo).
	-- Tier-2 must confirm; a colliding or empty JobId would break write-exclusion entirely.
	local myId: string = if game.JobId ~= ""
		then game.JobId
		else "studio-" .. HttpService:GenerateGUID(false)

	-- DURABLE data: the authoritative DataStore record { data, lockId?, metaVersion }.
	local dataStore = DataStoreService:GetDataStore(config.storeName)
	-- LIVENESS lock: MemoryStore hash map, entries auto-expire after lockTtl.
	local lockMap = MemoryStoreService:GetHashMap(config.storeName .. "_lock")

	-- key -> the live Session on THIS server. isLocked is deliberately LOCAL (L10): "do I hold
	-- this session in memory?", never a DataStore read (budget + wrong cross-server semantics).
	local sessions: { [string]: any } = {}

	-- ---- §4.1 in-process per-key FIFO (byte-for-byte MockStore's) ----
	local locks: { [string]: LockState } = {}

	local function getLock(key: string): LockState
		local state = locks[key]
		if state == nil then
			state = { held = false, queue = {} }
			locks[key] = state
		end
		return state
	end

	local function acquire(key: string): ()
		local state = getLock(key)
		if not state.held then
			state.held = true
			return
		end
		local co = coroutine.running()
		table.insert(state.queue, co)
		coroutine.yield()
		-- Resumed by releaseLock(): the lock was handed to us; state.held stays true.
	end

	local function releaseLock(key: string): ()
		local state = getLock(key)
		local nextCo = table.remove(state.queue, 1)
		if nextCo ~= nil then
			local ok, err = coroutine.resume(nextCo)
			if not ok then
				warn(`SessionStore.releaseLock: resumed waiter errored: {tostring(err)}`)
			end
		else
			state.held = false
		end
	end

	-- ---- [D8] global write-rate limiter: ONE token bucket across ALL keys ----
	-- Every DataStore write (load-stamp, save, release) takes a token; when the bucket is dry
	-- the writer WAITS (task.wait — all writers are Roblox-side coroutines). This is what lets
	-- DataService.Stop dispatch every key's flush concurrently and still respect the global
	-- budget: the bucket paces the burst; per-key floors don't compose into a global bound (M5).
	-- Capacity TRACKS the live session count (§7's `base + perPlayer·players`), so a full server
	-- gets the allowance it is actually granted instead of a flat floor.
	local liveSessions = 0
	local tokens: number = writesBase
	local lastRefillMono: number = clock:mono()

	local function writeCapacity(): number
		return writesBase + writesPerPlayer * liveSessions
	end

	local function takeWriteToken(): ()
		while true do
			local capacity = writeCapacity()
			local tokensPerSecond = capacity / 60
			local now = clock:mono()
			tokens = math.min(capacity, tokens + (now - lastRefillMono) * tokensPerSecond)
			lastRefillMono = now
			if tokens >= 1 then
				tokens -= 1
				return
			end
			task.wait(math.max((1 - tokens) / tokensPerSecond, 0.05))
		end
	end

	-- Per-key write floor (same policy MockStore models with writeMinIntervalSeconds).
	local lastWriteMono: { [string]: number } = {}

	local Store = {}

	function Store.isLocked(_: any, key: string): boolean
		return sessions[key] ~= nil
	end

	function Store.load(_: any, key: string, default: () -> any): Result<any>
		-- [L11] Re-entrant same-server load: one key must never have two live sessions here.
		-- Tear the prior one down FIRST — release() final-saves its delta, stops its heartbeat
		-- and clears the stamp; the fresh claim below re-stamps. (If its release fails the new
		-- read simply misses the prior session's unflushed delta — bounded, never corrupt.)
		local prior = sessions[key]
		if prior ~= nil then
			prior:release()
			-- release() now KEEPS a session alive on a transient write failure so it can be
			-- retried — but here we are about to install a replacement, and two live sessions on
			-- one key is precisely the L11 hazard. Force-drop whatever survived.
			if sessions[key] ~= nil then
				sessions[key] = nil
				liveSessions -= 1
			end
		end

		-- Take the write token BEFORE claiming (the claim→stamp gap must stay SHORT). Taking it
		-- after the claim would let a starved bucket stall us for longer than lockTtl: our claim
		-- would silently expire, another server could legitimately claim + stamp + start serving,
		-- and our late stamp would then overwrite THEIRS — killing a live session. Ordering the
		-- token first bounds the gap to one UpdateAsync round-trip.
		takeWriteToken()

		-- §4.1 step 1: claim the LIVENESS lock via an atomic MemoryStore CAS. An entry that
		-- expired (crashed owner) reads as nil — claimable in ≤ lockTtl with no manual stale
		-- sizing (the H1 fix). Our own id re-claims re-entrantly.
		-- TODO(verify): MemoryStoreHashMap:UpdateAsync(key, transform, expiration) — that this is
		-- the exact signature, that returning nil ABORTS the write without raising, and that an
		-- expired entry reads as nil. LOAD-BEARING: if a nil return RAISES instead, this pcall
		-- fails and load returns Internal rather than SessionLocked, which silently swaps the H1
		-- wait budget for the shorter Internal budget and reinstates the crash-rejoin kick-loop.
		-- Tier-1 cannot see this (MockStore hands DataService the codes directly) — Tier-2 must.
		local claimed = false
		local claimOk, claimErr = pcall(function()
			lockMap:UpdateAsync(key, function(existing: any)
				-- PURE + non-yielding (L9): may be invoked multiple times by the service, so
				-- every branch SETS `claimed` (never leaves a stale true from a prior attempt).
				if existing == nil or existing.lockId == myId then
					claimed = true
					return { lockId = myId }
				end
				claimed = false
				return nil -- a LIVE other-server lock: abort, change nothing
			end, lockTtl)
		end)
		if not claimOk then
			return Result.err(Result.Codes.Internal, `SessionStore.claim: {tostring(claimErr)}`)
		end
		if not claimed then
			return Result.err(Result.Codes.SessionLocked, "held by another server")
		end

		-- §4.1 step 2 (amended): ATOMIC read+stamp — stamp lockId=myId and read the record in
		-- ONE UpdateAsync (see the header amendment: crash-stale-stamp takeover + the
		-- claim→first-save window). Token already taken above.
		local record: any = nil
		local readOk, readErr = pcall(function()
			dataStore:UpdateAsync(key, function(stored: any)
				-- PURE + non-yielding + idempotent (L9): default() is Migrations.default —
				-- pure; no analytics/counters in here, ever.
				local rec = stored or { metaVersion = 1 }
				if rec.data == nil then
					rec.data = default()
				end
				rec.lockId = myId
				record = rec
				return rec
			end)
		end)
		if not readOk then
			-- We hold the MemoryStore claim but built no session: leave it — it auto-expires
			-- in ≤ lockTtl, and a retry within the load budget re-claims re-entrantly (myId).
			return Result.err(Result.Codes.Internal, `SessionStore.load: {tostring(readErr)}`)
		end
		lastWriteMono[key] = clock:mono()

		local session: any = {}
		session.key = key
		session.data = record.data

		-- Session-lifecycle state (closed over, never client-visible).
		local zombie = false -- heartbeat/save discovered another owner: terminal (§4.4/§9)
		local released = false
		local heartbeatThread: thread? = nil

		function session.set(self: any, value: any): ()
			self.data = value
		end

		-- §5: update is UNCHANGED semantics — in-process FIFO, in-memory only, NO network.
		-- The durable write is save/release/autosave. A zombie session still updates in
		-- memory by design (§9): DataService reacts terminally at the next save.
		function session.update(self: any, transform: (current: any) -> any): Result<any>
			acquire(key)
			-- Re-read the LATEST value under the lock as a fresh snapshot (§4.1 step 2).
			local current = deepCopy(self.data)
			-- The transform is feature code and CAN throw. It must never escape holding the
			-- per-key lock: `locks` is store-scoped and outlives the session, so a leaked lock
			-- would park every later update on this key forever (that player's economy actions
			-- hang, surviving release AND rejoin). pcall + release-in-both-paths; the snapshot
			-- means a half-applied transform is discarded, never written back.
			local ok, resultOrErr = pcall(transform, current)
			if not ok then
				releaseLock(key)
				return Result.err(
					Result.Codes.Internal,
					`SessionStore.update: transform errored: {tostring(resultOrErr)}`
				)
			end
			self.data = resultOrErr
			releaseLock(key)
			return Result.ok(resultOrErr)
		end

		-- One save attempt: floor-gated, token-gated, stamp-checked (§4.2). The RETRY loop
		-- lives in DataService.saveSession (same split MockStore models).
		local function persist(clearStamp: boolean): Result<any>
			if zombie then
				return Result.err(Result.Codes.LockStolen, "SessionStore.heartbeatLost")
			end
			if not clearStamp then
				-- Per-key throttle floor. Release (clearStamp) BYPASSES the floor: it is the
				-- terminal write for the session and skipping it would lose the final delta.
				local nowMono = clock:mono()
				local last = lastWriteMono[key]
				if last ~= nil and (nowMono - last) < writeMinInterval then
					return Result.err(Result.Codes.Internal, "SessionStore.writeMinInterval")
				end
			end
			takeWriteToken()
			local stolen = false
			-- TODO(verify): a DataStore UpdateAsync transform returning nil ABORTS the write
			-- without raising. The whole §4.2 write-exclusion rests on it — Tier-2 must confirm.
			local ok, err = pcall(function()
				dataStore:UpdateAsync(key, function(stored: any)
					-- PURE + non-yielding + idempotent (L9): the engine may invoke this more
					-- than once, so BOTH branches set `stolen` (a retry never leaves a stale
					-- true from an earlier invocation).
					if stored ~= nil and stored.lockId ~= nil and stored.lockId ~= myId then
						stolen = true
						return nil -- §4.2: our lock was lost + re-claimed -> DO NOT WRITE
					end
					stolen = false
					local rec = stored or { metaVersion = 1 }
					rec.data = session.data
					rec.lockId = if clearStamp then nil else myId
					return rec
				end)
			end)
			if not ok then
				return Result.err(Result.Codes.Internal, `SessionStore.save: {tostring(err)}`)
			end
			if stolen then
				-- Permanent for this session (§4.2/H2): the new owner is authoritative.
				zombie = true
				return Result.err(Result.Codes.LockStolen, "SessionStore.lockStolen")
			end
			lastWriteMono[key] = clock:mono()
			return Result.ok(session.data)
		end

		function session.save(_self: any): Result<any>
			return persist(false)
		end

		-- Terminal teardown: drop the session, stop the heartbeat, free our liveness lock.
		local function teardown(): ()
			released = true
			if sessions[key] ~= nil then
				sessions[key] = nil
				liveSessions -= 1
			end
			if heartbeatThread ~= nil then
				-- pcall: on a steal the heartbeat loop breaks and the thread COMPLETES, and
				-- cancelling an already-dead thread is not a behavior we can verify from here.
				-- An error escaping teardown would propagate out of load()'s L11 path and leave
				-- a player neither loaded nor kicked.
				-- TODO(verify): task.cancel on a completed thread is a no-op, not an error.
				pcall(task.cancel, heartbeatThread)
				heartbeatThread = nil
			end
			-- Free the MemoryStore lock ONLY if still ours — atomically, by re-setting it with
			-- a 1s TTL (there is no conditional remove; an unconditional RemoveAsync could
			-- delete a NEW owner's lock). Not ours -> abort, touch nothing. A rejoiner sees at
			-- most ~1s of residual lock, absorbed by the SessionLocked wait cadence.
			-- TODO(verify): expiration = 1 is an accepted MemoryStore TTL.
			pcall(function()
				lockMap:UpdateAsync(key, function(existing: any)
					if existing ~= nil and existing.lockId == myId then
						return existing
					end
					return nil
				end, 1)
			end)
		end

		-- §4.3: final save (stamp cleared) + free the liveness lock.
		-- Idempotent on SUCCESS, RETRYABLE on transient failure: a throttled/errored final write
		-- must leave the session ALIVE so the caller's retry budget can actually reach it. Tearing
		-- down first would make every retry a silent no-op (the `released` short-circuit returns
		-- ok) and lose the whole session's delta to one transient error — the most common durable
		-- write in a live game is this one, on the leave path.
		function session.release(_self: any): Result<any>
			if released then
				return Result.ok(session.data)
			end
			local saved = persist(true)
			if not saved.ok and (saved :: any).code ~= Result.Codes.LockStolen then
				return saved -- transient: stay live, stay locked, let the caller retry
			end
			-- Wrote it, or lost the lock for good (nothing left to write): tear down.
			teardown()
			return saved
		end

		-- §4.4 heartbeat: renew the MemoryStore TTL while we hold it (NOT a DataStore write — it
		-- never competes with the autosave budget).
		--
		-- DELIBERATELY ADVISORY, never terminal (deviation from §4.4-as-written, reasoned): the
		-- DataStore lockId stamp is the AUTHORITATIVE exclusion (§3), so a MemoryStore-only signal
		-- must not be allowed to kill a session on its own. If it were, this kills the WRONG
		-- server: after a MemoryStore blip evaporates every entry, whichever server re-claims
		-- first wins the map — and if that is a stale ghost rather than the true stamp-holder, the
		-- legitimate owner would see a foreign lock and terminally zombie itself, kicking a player
		-- who was on the correct server and discarding their delta. So: renew what is ours, never
		-- steal a live foreign lock, and never die here. `persist`'s stamp check settles ownership
		-- authoritatively at the next save — the ghost's write is refused, the true owner's
		-- succeeds. Cost of the deviation: a contended lock stays ambiguous for up to one autosave
		-- interval instead of being (wrongly) resolved instantly.
		heartbeatThread = task.spawn(function()
			while not released and not zombie do
				task.wait(heartbeatInterval)
				if released or zombie then
					break
				end
				pcall(function()
					lockMap:UpdateAsync(key, function(existing: any)
						-- PURE + non-yielding (L9). Ours or an expired/unclaimed slot: renew.
						if existing == nil or existing.lockId == myId then
							return { lockId = myId }
						end
						return nil -- a live FOREIGN lock: leave it alone, keep serving
					end, lockTtl)
				end)
			end
		end)

		sessions[key] = session
		liveSessions += 1
		return Result.ok(session)
	end

	return Store
end

return SessionStore
