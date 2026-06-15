--!strict
-- core/src/shared/Migrations.luau
-- Ordered migration steps + the fresh-player default. PURE functions (Tier-1 testable).
-- Lune-clean: requires only ./Types relatively (D1). See docs/CORE-DESIGN.md §3.5.
local Types = require("./Types")

-- index i migrates schemaVersion i -> i+1. Empty in v1 (no structural change yet); the
-- first time the PlayerData shape changes, append a step here.
export type MigrationStep = (old: { [string]: any }) -> { [string]: any }

local steps: { MigrationStep } = {
	-- [1] = function(v1) ... -> v2 end,  -- added when the shape first changes
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
