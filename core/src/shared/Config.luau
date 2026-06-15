--!strict
-- core/src/shared/Config.luau
-- Static tunables. Lune-clean LEAF: requires nothing (pure data + types).
-- The whole table is server-side; only a documented client-safe subset is exposed via
-- ClientContext.config (no store names / budgets leak to the client). See §3.4.

export type DataStoreBudget = {
	maxRetries: number, -- same-key write retry budget (DataStore budget awareness)
	retryBaseSeconds: number, -- backoff base (uses injected clock in tests)
	writeMinIntervalSeconds: number, -- throttle floor between same-key writes
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
