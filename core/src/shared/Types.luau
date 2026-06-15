--!strict
-- core/src/shared/Types.luau
-- The single persisted player shape (v1) + the client-safe projection. Lune-clean LEAF:
-- requires nothing (pure types + the pure toView function). See docs/CORE-DESIGN.md §3.2.

export type SchemaVersion = number
local CURRENT_SCHEMA_VERSION: SchemaVersion = 1

-- The single persisted player shape (v1). One table, versioned. Every field a deferred
-- (B2) module touches is reserved now so migrations stay additive and a union-merge of
-- two features that each add a field is trivial.
export type PlayerData = {
	schemaVersion: SchemaVersion,

	-- --- economy (concurrency-safe writes go through DataService) ---
	-- numbers are server-authored; a map (not fixed fields) so a game adds a currency
	-- without a migration.
	currencies: { [string]: number },

	-- --- progression ---
	stats: {
		playtimeSeconds: number,
		joinCount: number,
	},

	-- --- time-based features (server clock only; never client time) ---
	timestamps: {
		firstJoinUnix: number,
		lastSeenUnix: number, -- written on save/release; offline-earnings base in B2
	},

	-- --- reserved seams (present + empty in v1 so B2 adds logic, not schema) ---
	upgrades: { [string]: number }, -- [B2 shop] purchased upgrade levels
	flags: { [string]: boolean }, -- [B2 live-ops / one-time grants] per-player booleans
	receipts: { [string]: boolean }, -- [B2 monetization] processed receipt IDs (idempotency)
	analytics: { lastEventUnix: number }?, -- [B2 analytics] light per-player bookkeeping
}

export type AnyTable = { [string]: any }

-- The CLIENT-SAFE projection of PlayerData (concern 17). This is the ONLY shape that
-- crosses to the client. It is a TYPE (not `any`) so NetClient:on("data", fn) is typed.
-- Strips: receipts (idempotency ledger), analytics (server bookkeeping), and any future
-- internal field. Keeps the player-facing subset.
export type PlayerView = {
	schemaVersion: SchemaVersion,
	currencies: { [string]: number },
	stats: { playtimeSeconds: number, joinCount: number },
	upgrades: { [string]: number },
	flags: { [string]: boolean },
}

local Types = {}
Types.CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION

-- PURE projection: PlayerData -> PlayerView. DataService calls this before every push (§4.5).
-- ALLOWLIST (never blocklist) so a NEW PlayerData field is invisible to the client by
-- default — a field is only replicated if added here deliberately. Lune-clean, Tier-1 tested.
function Types.toView(data: PlayerData): PlayerView
	return {
		schemaVersion = data.schemaVersion,
		currencies = data.currencies,
		stats = data.stats,
		upgrades = data.upgrades,
		flags = data.flags,
	}
end

return Types
