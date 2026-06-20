--!strict
-- core/src/shared/Migrations.luau
-- Ordered migration steps + the fresh-player default. PURE functions (Tier-1 testable).
-- Lune-clean: requires only ./Types relatively (D1). See docs/CORE-DESIGN.md §3.5.
local Types = require("./Types")

-- index i migrates schemaVersion i -> i+1. Empty in v1 (no structural change yet); the
-- first time the PlayerData shape changes, append a step here.
export type MigrationStep = (old: { [string]: any }) -> { [string]: any }

local steps: { MigrationStep } = {
	-- [1] v1 -> v2: the daily-streak feature added a REAL persisted `daily` field. Add it (idempotent
	-- — preserve any existing value) and STAMP schemaVersion = 2 so migrate()'s loop advances past
	-- this step (without the stamp the loop would re-run step[1] forever on a v1 blob).
	[1] = function(old: { [string]: any }): { [string]: any }
		if old.daily == nil then
			old.daily = { streak = 0, lastClaimUnix = 0 }
		end
		old.schemaVersion = 2
		return old
	end,

	-- [2] v2 -> v3: the rebirth feature added a TOP-LEVEL `rebirths` count. Seed it to 0 IDEMPOTENTLY
	-- (preserve any existing value so a re-migrate cannot reset an advanced count) and STAMP
	-- schemaVersion = 3 so migrate()'s loop advances past this step.
	[2] = function(old: { [string]: any }): { [string]: any }
		if old.rebirths == nil then
			old.rebirths = 0
		end
		old.schemaVersion = 3
		return old
	end,

	-- [3] v3 -> v4: the contract pass added `stats.lifetimeStardust` (total Stardust earned over the
	-- player's lifetime). For EXISTING players we have no historical earn ledger, so the best-available
	-- baseline is their CURRENT Stardust balance, FLOORED (math.floor — Stardust may be fractional in
	-- principle; lifetimeStardust is a whole-number accrual counter). Idempotent: only seed when absent
	-- so a re-migrate never clobbers an already-accrued value. STAMP schemaVersion = 4.
	[3] = function(old: { [string]: any }): { [string]: any }
		if old.stats == nil then
			-- Defensive: a malformed blob missing stats entirely still migrates without crashing.
			old.stats = { playtimeSeconds = 0, joinCount = 0 }
		end
		if old.stats.lifetimeStardust == nil then
			local currencies = old.currencies or {}
			old.stats.lifetimeStardust = math.floor(currencies.Stardust or 0)
		end
		old.schemaVersion = 4
		return old
	end,

	-- [4] v4 -> v5: the boost-persistence change made the 30-min 2x boost a PERSISTED field
	-- (boostExpiresUnix) instead of in-memory session state. Seed it to 0 IDEMPOTENTLY (0 = no active
	-- boost; an existing player simply starts the new schema with no boost armed — they never had a
	-- persisted one). STAMP schemaVersion = 5 so migrate()'s loop advances past this step.
	[4] = function(old: { [string]: any }): { [string]: any }
		if old.boostExpiresUnix == nil then
			old.boostExpiresUnix = 0
		end
		old.schemaVersion = 5
		return old
	end,
}

local Migrations = {}

-- Returns a fresh default PlayerData at CURRENT_SCHEMA_VERSION (new player).
-- `nowUnix` is the INJECTED SERVER CLOCK value (never client time) — §5.
function Migrations.default(nowUnix: number): { [string]: any }
	return {
		schemaVersion = Types.CURRENT_SCHEMA_VERSION,
		-- currencies.Prisms=0 is seeded here (the fresh-player blob) — a SEPARATE code site from the
		-- migrate() steps. Prisms is the rebirth currency; it gets no migrate() step (the currencies map
		-- is open, so an absent key reads as 0 for existing players — no structural migration needed).
		currencies = { Stardust = 0, Prisms = 0 },
		-- rebirths=0 (top-level) + stats.lifetimeStardust=0 are seeded here too — again SEPARATE from the
		-- v2->v3 / v3->v4 migrate() steps (which only backfill EXISTING players).
		rebirths = 0,
		stats = {
			playtimeSeconds = 0,
			joinCount = 0,
			lifetimeStardust = 0,
		},
		timestamps = {
			firstJoinUnix = nowUnix,
			lastSeenUnix = nowUnix,
		},
		upgrades = {},
		flags = {},
		receipts = {},
		daily = { streak = 0, lastClaimUnix = 0 },
		-- boostExpiresUnix=0 (no active boost) is seeded here too — SEPARATE from the v4->v5 migrate()
		-- step (which only backfills EXISTING players). v5: the 2x boost is now persisted.
		boostExpiresUnix = 0,
	}
end

-- Runs every step from data.schemaVersion up to CURRENT, returning a current-version blob.
-- Never loses fields; unknown extra fields are preserved (round-trip tested, §9 / data.spec).
function Migrations.migrate(data: { [string]: any }): { [string]: any }
	local current = data
	local version = tonumber(current.schemaVersion) or 0

	-- Apply each step in order from the data's version to the current version.
	while version < Types.CURRENT_SCHEMA_VERSION do
		local step = steps[version]
		if step == nil then
			-- No step registered for this gap: bump the version but preserve all fields.
			-- (Only reachable if CURRENT was bumped without registering a step — guarded by
			-- data.spec migration round-trip; kept non-destructive on purpose.)
			break
		end
		current = step(current)
		version = tonumber(current.schemaVersion) or (version + 1)
	end

	-- Stamp the current version so a no-op migration still normalizes the field.
	current.schemaVersion = Types.CURRENT_SCHEMA_VERSION
	return current
end

return Migrations
