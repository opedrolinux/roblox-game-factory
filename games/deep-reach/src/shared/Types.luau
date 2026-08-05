--!strict
-- core/src/shared/Types.luau
-- The single persisted player shape (v1) + the client-safe projection. Lune-clean LEAF:
-- requires nothing (pure types + the pure toView function). See docs/CORE-DESIGN.md §3.2.

export type SchemaVersion = number
-- v7: the Deep Reach contract pass. v1->v2 stats.lifetimeCredits, v2->v3 plot, v3->v4 daily,
-- v4->v5 smelter, v5->v6 resurfaces, v6->v7 boostExpiresUnix. One step per structural field,
-- each registered in Migrations.steps AND seeded in Migrations.default (two separate code sites).
local CURRENT_SCHEMA_VERSION: SchemaVersion = 7

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
		-- Total Credits EARNED over the player's lifetime. MONOTONIC: incremented on every earn
		-- path (EconomyService:earn, Credits only), never decremented on a spend and never reset
		-- by resurface — it is the leaderboard's ranking key. currencies.Credits is the SPENT-DOWN
		-- balance and therefore cannot represent it. [v1->v2]
		lifetimeCredits: number,
	},

	-- --- time-based features (server clock only; never client time) ---
	timestamps: {
		firstJoinUnix: number,
		lastSeenUnix: number, -- written on save/release; offline-earnings base in B2
	},

	-- --- Deep Reach fixed-shape records (each one a migration step; none fits an open map) ---
	-- The dome plot this player holds. plotId == "" means "holds no plot". [v2->v3]
	plot: {
		plotId: string,
		claimedAtUnix: number,
	},
	-- The smelter's un-collected output plus the ACCRUAL TICK BASE. storedCredits is NOT a
	-- currency (unspendable, never debited by a purchase); lastTickUnix must stay DISTINCT from
	-- timestamps.lastSeenUnix, which the data layer re-stamps on every autosave. [v4->v5]
	smelter: {
		storedCredits: number,
		lastTickUnix: number,
	},
	-- Daily supply-drop streak + the server-unix stamp of the last claim (0 = never). [v3->v4]
	daily: {
		streak: number,
		lastClaimUnix: number,
	},
	-- Prestige count: how many times this player has resurfaced. Not currencies.Pearls (spent
	-- down) and not upgrades (wiped by the resurface itself). [v5->v6]
	resurfaces: number,
	-- Server-unix expiry of the 30-min 2x boost; 0 = none. PERSISTED, so the expiry survives a
	-- crash/rejoin. Read by salvage's rateFor as `now < boostExpiresUnix`. [v6->v7]
	boostExpiresUnix: number,

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
	-- AMENDMENT A4: stats is a NARROW FIXED RECORD here. toView copies data.stats wholesale, so
	-- the VALUE of lifetimeCredits arrives either way — but a client reading
	-- view.stats.lifetimeCredits against a narrower annotation is a --!strict property error.
	-- Widening PlayerData.stats alone would ship a leaderboard that cannot read its ranking key.
	stats: { playtimeSeconds: number, joinCount: number, lifetimeCredits: number },
	upgrades: { [string]: number },
	flags: { [string]: boolean },
	plot: { plotId: string, claimedAtUnix: number },
	smelter: { storedCredits: number, lastTickUnix: number },
	daily: { streak: number, lastClaimUnix: number },
	resurfaces: number,
	boostExpiresUnix: number,
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
		-- stats is copied WHOLESALE, so stats.lifetimeCredits needs no line of its own here.
		stats = data.stats,
		upgrades = data.upgrades,
		flags = data.flags,
		-- One allowlist line per NEW TOP-LEVEL client-facing field. receipts / analytics stay out.
		plot = data.plot,
		smelter = data.smelter,
		daily = data.daily,
		resurfaces = data.resurfaces,
		boostExpiresUnix = data.boostExpiresUnix,
	}
end

return Types
