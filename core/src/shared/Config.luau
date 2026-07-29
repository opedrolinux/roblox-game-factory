--!strict
-- core/src/shared/Config.luau
-- Static tunables. Lune-clean LEAF: requires nothing (pure data + types).
-- The whole table is server-side; only a documented client-safe subset is exposed via
-- ClientContext.config (no store names / budgets leak to the client). See §3.4.

export type DataStoreBudget = {
	maxRetries: number, -- same-key write retry budget (DataStore budget awareness)
	retryBaseSeconds: number, -- backoff base (uses injected clock in tests)
	writeMinIntervalSeconds: number, -- throttle floor between same-key writes
	-- [B2 SessionStore] session-lock + write-cadence tunables (B2-SESSIONSTORE-DESIGN §8):
	lockTtlSeconds: number, -- MemoryStore lock TTL (auto-expiry = crash-safe steal; D1/D3)
	heartbeatIntervalSeconds: number, -- TTL renew cadence (= lockTtl/2, beats the TTL under jitter)
	-- Periodic DataStore flush (D5). 0 disables it — but note this is now LOAD-BEARING beyond
	-- data loss: the autosave is what makes a displaced server discover, via the lock stamp on its
	-- next write, that it no longer owns a session. With 0 that discovery is deferred to the
	-- terminal write (leave/shutdown), so a stolen-from server can serve stale in-memory data for
	-- a whole session. Keep it non-zero in production.
	autosaveIntervalSeconds: number,
	sessionLockedWaitSeconds: number, -- load's SessionLocked-specific wait budget (>= lockTtl; H1)
	-- Global write budget (D8). Roblox grants a SERVER ~(60 + 10·players) DataStore writes/min, so
	-- the limiter models BOTH terms — a flat number would throttle a full server to a fraction of
	-- its real allowance and stall both the autosave pass and the shutdown flush (§7/M5).
	globalWritesPerMinute: number, -- the base term
	globalWritesPerPlayerPerMinute: number, -- the per-live-session term
}

export type RateDefault = {
	maxPerWindow: number,
	windowSeconds: number,
}

export type Config = {
	storeName: string, -- DataStore name (new-game renames this per game for isolation)
	schemaKeyPrefix: string, -- per-player key prefix, e.g. "player_"
	dataStore: DataStoreBudget,
	rateDefaults: RateDefault, -- fallback RatePolicy
	flagsSeed: { [string]: boolean }, -- [B2 live-ops] compile-time default flag values
}

local Config: Config = {
	storeName = "CoreData_v1", -- new-game renames this per game
	schemaKeyPrefix = "player_",
	dataStore = {
		maxRetries = 4,
		retryBaseSeconds = 1.0,
		writeMinIntervalSeconds = 6.0,
		lockTtlSeconds = 30,
		heartbeatIntervalSeconds = 15,
		autosaveIntervalSeconds = 60,
		sessionLockedWaitSeconds = 40,
		globalWritesPerMinute = 60,
		globalWritesPerPlayerPerMinute = 10,
	},
	rateDefaults = {
		maxPerWindow = 10,
		windowSeconds = 1.0,
	},
	flagsSeed = {},
}

-- The documented client-safe subset (no store names / budgets). ClientContext.config uses this.
export type ClientConfig = {
	rateDefaults: RateDefault,
}

local CONFIG = Config :: any

function CONFIG.clientSubset(): ClientConfig
	return {
		rateDefaults = Config.rateDefaults,
	}
end

return Config
