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

	-- §8 tunables (defensive defaults in case a game's config fork predates B2).
	local lockTtl: number = budget.lockTtlSeconds or 30
	local heartbeatInterval: number = budget.heartbeatIntervalSeconds or 15
	local writeMinInterval: number = budget.writeMinIntervalSeconds or 6
	local writesPerMinute: number = budget.globalWritesPerMinute or 60

	-- [D2] the per-server-lifetime writer identity: game.JobId is unique + non-empty on live
	-- servers and EMPTY in Studio solo — fall back to one GUID per store instance there.
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
	-- ~(60 + 10·players)/min budget: the bucket paces the burst; per-key floors don't compose
	-- into a global bound (M5).
	local tokensPerSecond = writesPerMinute / 60
	local tokens: number = writesPerMinute
	local lastRefillMono: number = clock:mono()

	local function takeWriteToken(): ()
		while true do
			local now = clock:mono()
			tokens = math.min(writesPerMinute, tokens + (now - lastRefillMono) * tokensPerSecond)
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
		end

		-- §4.1 step 1: claim the LIVENESS lock via an atomic MemoryStore CAS. An entry that
		-- expired (crashed owner) reads as nil — claimable in ≤ lockTtl with no manual stale
		-- sizing (the H1 fix). Our own id re-claims re-entrantly.
		local claimed = false
		local claimOk, claimErr = pcall(function()
			lockMap:UpdateAsync(key, function(existing: any)
				-- PURE + non-yielding (L9): may be invoked multiple times by the service.
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
		-- claim→first-save window). Counts against the global write budget.
		takeWriteToken()
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
			local newValue = transform(current)
			self.data = newValue
			releaseLock(key)
			return Result.ok(newValue)
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
			local ok, err = pcall(function()
				dataStore:UpdateAsync(key, function(stored: any)
					-- PURE + non-yielding + idempotent (L9).
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

		-- §4.3: final save (stamp cleared) + free the liveness lock. Idempotent.
		function session.release(_self: any): Result<any>
			if released then
				return Result.ok(session.data)
			end
			released = true
			sessions[key] = nil
			if heartbeatThread ~= nil then
				task.cancel(heartbeatThread)
				heartbeatThread = nil
			end
			local saved = persist(true)
			-- Free the MemoryStore lock ONLY if still ours — atomically, by re-setting it with
			-- a 1s TTL (there is no conditional remove; an unconditional RemoveAsync could
			-- delete a NEW owner's lock). Not ours -> abort, touch nothing. A rejoiner sees at
			-- most ~1s of residual lock, absorbed by the SessionLocked wait cadence.
			pcall(function()
				lockMap:UpdateAsync(key, function(existing: any)
					if existing ~= nil and existing.lockId == myId then
						return existing
					end
					return nil
				end, 1)
			end)
			return saved
		end

		-- §4.4 heartbeat: renew the MemoryStore TTL while held (NOT a DataStore write — it
		-- never competes with the autosave budget). Finding another owner => zombie, stop.
		-- A FAILED renewal (throttle/outage) keeps looping: heartbeat = ttl/2 leaves margin,
		-- and even a fully evaporated lock is fenced by the §4.2 stamp check.
		heartbeatThread = task.spawn(function()
			while not released and not zombie do
				task.wait(heartbeatInterval)
				if released or zombie then
					break
				end
				local renewed = false
				local ok = pcall(function()
					lockMap:UpdateAsync(key, function(existing: any)
						if existing == nil or existing.lockId == myId then
							-- Ours (or expired-and-unclaimed): renew the TTL.
							renewed = true
							return { lockId = myId }
						end
						renewed = false
						return nil
					end, lockTtl)
				end)
				if ok and not renewed then
					zombie = true -- expired + re-claimed by another server (§4.4)
					break
				end
			end
		end)

		sessions[key] = session
		return Result.ok(session)
	end

	return Store
end

return SessionStore
