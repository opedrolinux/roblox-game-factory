--!strict
-- core/src/shared/Types.luau
-- The single persisted player shape (v1) + the client-safe projection. Lune-clean LEAF:
-- requires nothing (pure types + the pure toView function). See docs/CORE-DESIGN.md §3.2.

export type SchemaVersion = number
local CURRENT_SCHEMA_VERSION: SchemaVersion = 5

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
	-- rebirths: TOP-LEVEL count of permanent rebirths (v3 — added by the rebirth feature). Drives the
	-- Sell rebirth multiplier (1 + rebirths*REBIRTH_STEP). Client-facing (the HUD shows it) -> mirrored
	-- in PlayerView with a toView line below.
	rebirths: number,
	stats: {
		playtimeSeconds: number,
		joinCount: number,
		-- lifetimeStardust: v4 — total Stardust EARNED over the player's lifetime (monotonic; never
		-- decremented on spend). Accrued by every earn path (Sell / Daily). Rides the CLOSED `stats`
		-- literal, so toView (which copies stats wholesale) needs NO extra line for it.
		lifetimeStardust: number,
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

	-- --- daily streak (v2 — a REAL persisted field added by the daily-streak feature, NOT a
	-- reserved seam; its addition is what bumped the schema to v2 + needed a Migrations step).
	-- Server-clock gated: lastClaimUnix is SERVER unix time (§5), never client time. ---
	daily: { streak: number, lastClaimUnix: number },

	-- --- monetization (v5 — the 30-min 2x boost is now PERSISTED, so it survives a crash/rejoin
	-- instead of dying with the session). boostExpiresUnix is the SERVER-unix time the active boost
	-- EXPIRES; 0 means no active boost. The Sell stardust multiplier reads it from the lock-held
	-- snapshot (now < boostExpiresUnix => 2x). Client-facing (the HUD shows remaining boost time) ->
	-- mirrored in PlayerView with a toView line below. Its addition is what bumped the schema to v5. ---
	boostExpiresUnix: number,
}

export type AnyTable = { [string]: any }

-- The CLIENT-SAFE projection of PlayerData (concern 17). This is the ONLY shape that
-- crosses to the client. It is a TYPE (not `any`) so NetClient:on("data", fn) is typed.
-- Strips: receipts (idempotency ledger), analytics (server bookkeeping), and any future
-- internal field. Keeps the player-facing subset.
export type PlayerView = {
	schemaVersion: SchemaVersion,
	currencies: { [string]: number },
	rebirths: number, -- top-level + client-facing -> mirrored here AND copied in toView
	stats: { playtimeSeconds: number, joinCount: number, lifetimeStardust: number },
	upgrades: { [string]: number },
	flags: { [string]: boolean },
	daily: { streak: number, lastClaimUnix: number }, -- the HUD badge shows the streak
	boostExpiresUnix: number, -- v5: server-unix expiry of the active 2x boost (0 = none); HUD shows remaining
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
		rebirths = data.rebirths, -- TOP-LEVEL field: needs its own allowlist line (stats does not — copied wholesale)
		stats = data.stats, -- copies stats WHOLESALE, so lifetimeStardust rides along with NO extra line
		upgrades = data.upgrades,
		flags = data.flags,
		daily = data.daily,
		boostExpiresUnix = data.boostExpiresUnix, -- v5: top-level field -> needs its own allowlist line
	}
end

return Types
