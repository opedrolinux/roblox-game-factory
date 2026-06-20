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
}

local Migrations = {}

-- Returns a fresh default PlayerData at CURRENT_SCHEMA_VERSION (new player).
-- `nowUnix` is the INJECTED SERVER CLOCK value (never client time) — §5.
function Migrations.default(nowUnix: number): { [string]: any }
	return {
		schemaVersion = Types.CURRENT_SCHEMA_VERSION,
		currencies = { Stardust = 0 },
		stats = {
			playtimeSeconds = 0,
			joinCount = 0,
		},
		timestamps = {
			firstJoinUnix = nowUnix,
			lastSeenUnix = nowUnix,
		},
		upgrades = {},
		flags = {},
		receipts = {},
		daily = { streak = 0, lastClaimUnix = 0 },
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
