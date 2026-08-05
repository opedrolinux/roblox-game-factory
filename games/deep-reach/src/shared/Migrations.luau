--!strict
-- core/src/shared/Migrations.luau
-- Ordered migration steps + the fresh-player default. PURE functions (Tier-1 testable).
-- Lune-clean: requires only ./Types relatively (D1). See docs/CORE-DESIGN.md §3.5.
local Types = require("./Types")

-- index i migrates schemaVersion i -> i+1. Empty in v1 (no structural change yet); the
-- first time the PlayerData shape changes, append a step here.
export type MigrationStep = (old: { [string]: any }) -> { [string]: any }

-- EVERY step MUST do two things or it is broken:
--   (a) seed its field IDEMPOTENTLY — only when absent, so a re-migrate never clobbers a live
--       value (a re-run must not evict a claimed plot or reset an advanced prestige count);
--   (b) STAMP schemaVersion = its target version. migrate() reads the stamp to advance; an
--       unstamped step makes the loop spin on the same index forever. The `break` in migrate()
--       only guards a MISSING step, so a missing STAMP is invisible without the round-trip tests.
-- `steps[i]` migrates schemaVersion i -> i+1. Mutating + returning `old` is intentional: migrate()
-- reassigns `current = step(current)`, and every field not touched here survives untouched.
local steps: { MigrationStep } = {
	-- [1] v1 -> v2: stats.lifetimeCredits — the monotonic lifetime Credits total (the
	-- leaderboard's ranking key). First step because every earn path must increment it, so it
	-- has to exist before any feature builds. A pre-existing blob has no historical earn ledger,
	-- so seed from the CURRENT Credits balance — the only honest lower bound available.
	[1] = function(old)
		local stats = old.stats
		if type(stats) ~= "table" then
			-- Defensive: a blob that predates/lost `stats` must not crash the migration.
			stats = { playtimeSeconds = 0, joinCount = 0 }
			old.stats = stats
		end
		if stats.lifetimeCredits == nil then
			local currencies = old.currencies
			local credits = 0
			if type(currencies) == "table" and type(currencies.Credits) == "number" then
				credits = currencies.Credits
			end
			stats.lifetimeCredits = math.floor(credits)
		end
		old.schemaVersion = 2
		return old
	end,

	-- [2] v2 -> v3: plot. An empty plotId means "holds no plot"; the join claim fills it.
	-- Idempotent so a re-migrate can never evict a live claim.
	[2] = function(old)
		if type(old.plot) ~= "table" then
			old.plot = { plotId = "", claimedAtUnix = 0 }
		end
		old.schemaVersion = 3
		return old
	end,

	-- [3] v3 -> v4: daily. lastClaimUnix = 0 means never claimed, so the supply-drop window is
	-- open immediately on first join.
	[3] = function(old)
		if type(old.daily) ~= "table" then
			old.daily = { streak = 0, lastClaimUnix = 0 }
		end
		old.schemaVersion = 4
		return old
	end,

	-- [4] v4 -> v5: smelter. lastTickUnix = 0 is safe ONLY because SalvageService re-stamps it to
	-- `now` at session load before its first tick — otherwise the first tick would credit ~56
	-- years of accrual (clamped to capacity, but still a free full smelter on every legacy blob).
	[4] = function(old)
		if type(old.smelter) ~= "table" then
			old.smelter = { storedCredits = 0, lastTickUnix = 0 }
		end
		old.schemaVersion = 5
		return old
	end,

	-- [5] v5 -> v6: resurfaces. Preserves any existing value so a re-migrate cannot reset an
	-- advanced prestige count (which would shrink the player's permanent multiplier).
	[5] = function(old)
		if type(old.resurfaces) ~= "number" then
			old.resurfaces = 0
		end
		old.schemaVersion = 6
		return old
	end,

	-- [6] v6 -> v7: boostExpiresUnix. 0 = no active boost; an existing player simply starts the
	-- new schema unboosted, since no expiry was ever persisted for them.
	[6] = function(old)
		if type(old.boostExpiresUnix) ~= "number" then
			old.boostExpiresUnix = 0
		end
		old.schemaVersion = 7
		return old
	end,
}

local Migrations = {}

-- Exported so the round-trip spec can assert, per step, that a step EXISTS for every version gap
-- below CURRENT and that it STAMPS its target version. Both failures are otherwise invisible:
-- migrate() `break`s non-destructively on a missing step (stamping CURRENT over an unmigrated
-- blob), and an unstamped step spins the loop forever instead of failing an assertion. Read-only
-- by contract — nothing outside migrate() may call these.
Migrations.steps = steps

-- Returns a fresh default PlayerData at CURRENT_SCHEMA_VERSION (new player).
-- `nowUnix` is the INJECTED SERVER CLOCK value (never client time) — §5.
function Migrations.default(nowUnix: number): { [string]: any }
	-- NOTE: default() is a SEPARATE CODE SITE from steps[] above. A field seeded in a step but
	-- NOT here ships fresh players without it (and vice versa) — the classic half-migration.
	-- Every step above has a matching seed below; keep them in lockstep.
	return {
		schemaVersion = Types.CURRENT_SCHEMA_VERSION,
		-- Deep Reach's currencies. Credits = the soft primary (the shared balance salvage/offline/
		-- daily/monetization credit and structures/depth debit); Pearls = prestige. Both ride the
		-- OPEN currencies map, so a new key needs no migration — only this seed.
		-- (The scaffold's inherited `Stardust` seed is the FOUNDATION game's currency and is gone.)
		currencies = { Credits = 0, Pearls = 0 },
		stats = {
			playtimeSeconds = 0,
			joinCount = 0,
			lifetimeCredits = 0,
		},
		timestamps = {
			firstJoinUnix = nowUnix,
			lastSeenUnix = nowUnix,
		},
		plot = { plotId = "", claimedAtUnix = 0 },
		smelter = { storedCredits = 0, lastTickUnix = 0 },
		daily = { streak = 0, lastClaimUnix = 0 },
		resurfaces = 0,
		boostExpiresUnix = 0,
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
		local stamped = tonumber(current.schemaVersion) or (version + 1)
		if stamped <= version then
			-- The step did NOT stamp a higher version. Left alone this loop would re-run the same
			-- step forever and HANG the caller (a hang is not a failing test — it is a timeout
			-- with no diagnosis). Break non-destructively, exactly as for a missing step: the
			-- blob keeps every field, later steps simply never ran, and the per-step round-trip
			-- spec sees the un-seeded field and fails LOUDLY.
			break
		end
		version = stamped
	end

	-- Stamp the current version so a no-op migration still normalizes the field.
	current.schemaVersion = Types.CURRENT_SCHEMA_VERSION
	return current
end

return Migrations
