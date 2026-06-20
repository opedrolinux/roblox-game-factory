--!strict
-- core/tests/unit/migration.spec.luau   [INDEPENDENT TEST AGENT — authored from CORE-DESIGN §3.2/§3.5]
-- Versioned-data-shape migration round-trips, authored from the DESIGN (not the implementation):
--   * Migrations.default(now) yields a CURRENT_SCHEMA_VERSION blob seeded from the SERVER clock.
--   * migrate() is loss-less: known fields preserved, unknown extra fields preserved, version stamped.
--   * an OLD-version blob (schemaVersion below CURRENT) is normalized to CURRENT without data loss.
--   * Types.toView is an ALLOWLIST projection: server-only ledgers (receipts/analytics) NEVER leak,
--     and a NEW PlayerData field is invisible to the client until added to toView deliberately.
-- These are the "migration round-trip if the data shape is versioned" + leak-guard checks the task
-- requires. They complement (do not duplicate) the builder's data.spec coverage with stronger
-- old-version + forward-field assertions. All pure functions => Lune Tier-1.
local testkit = require("../lib/testkit")
local Migrations = require("../../src/shared/Migrations")
local Types = require("../../src/shared/Types")
local Config = require("../../src/shared/Config")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

describe("Migrations.default (fresh player, server-time seeded)", function()
	it("produces a blob at CURRENT_SCHEMA_VERSION", function()
		local data = Migrations.default(50000)
		expect(data.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
	end)

	it("seeds BOTH timestamps from the injected server time (never client time)", function()
		local nowUnix = 1718000000
		local data = Migrations.default(nowUnix)
		expect(data.timestamps.firstJoinUnix):toBe(nowUnix)
		expect(data.timestamps.lastSeenUnix):toBe(nowUnix)
	end)

	it(
		"starts the economy + reserved seams empty (currencies/upgrades/flags/receipts present)",
		function()
			local data = Migrations.default(1)
			expect(data.currencies.Stardust):toBe(0)
			expect(data.stats.joinCount):toBe(0)
			expect(data.stats.playtimeSeconds):toBe(0)
			-- Reserved B2 seams exist as empty tables so B2 adds logic, not schema (§3.2).
			expect(type(data.upgrades)):toBe("table")
			expect(type(data.flags)):toBe("table")
			expect(type(data.receipts)):toBe("table")
		end
	)
end)

describe("Migrations.migrate (round-trip, no data loss)", function()
	it("a current-version blob round-trips unchanged (idempotent)", function()
		local data = Migrations.default(1)
		data.currencies.Stardust = 123
		data.currencies.Prisms = 7 -- a NEW currency added without a migration (map, not fixed fields)
		data.upgrades.CollectSpeed = 4
		data.flags.tutorialDone = true
		local migrated = Migrations.migrate(data)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.currencies.Stardust):toBe(123)
		expect(migrated.currencies.Prisms):toBe(7)
		expect(migrated.upgrades.CollectSpeed):toBe(4)
		expect(migrated.flags.tutorialDone):toBe(true)
	end)

	it("preserves unknown/extra fields it does not understand (forward-compatible)", function()
		local data = Migrations.default(1);
		(data :: any).futureFeatureBlob = { nested = { deep = "keepme" } }
		local migrated = Migrations.migrate(data)
		expect((migrated :: any).futureFeatureBlob.nested.deep):toBe("keepme")
	end)

	it(
		"normalizes an OLD-version blob (schemaVersion below CURRENT) up to CURRENT without losing fields",
		function()
			-- Simulate a record persisted before CURRENT: a missing/low schemaVersion + real data.
			-- The design (§3.5) requires migrate() to bring it to CURRENT and lose nothing. With no
			-- registered steps yet (v1), this exercises the non-destructive version-stamp path.
			local oldBlob: { [string]: any } = {
				schemaVersion = 0, -- below CURRENT
				currencies = { Stardust = 999 },
				stats = { playtimeSeconds = 42, joinCount = 5 },
				timestamps = { firstJoinUnix = 111, lastSeenUnix = 222 },
				upgrades = { CollectSpeed = 3 },
				flags = {},
				receipts = { legacyReceipt = true },
			}
			local migrated = Migrations.migrate(oldBlob)
			-- Version normalized to CURRENT.
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- Every pre-existing field survived the round-trip.
			expect(migrated.currencies.Stardust):toBe(999)
			expect(migrated.stats.playtimeSeconds):toBe(42)
			expect(migrated.stats.joinCount):toBe(5)
			expect(migrated.timestamps.firstJoinUnix):toBe(111)
			expect(migrated.upgrades.CollectSpeed):toBe(3)
			expect(migrated.receipts.legacyReceipt):toBe(true)
		end
	)

	it("a blob with a string schemaVersion is coerced and still normalized (defensive)", function()
		-- A corrupted/legacy blob whose version is the wrong type must not crash migrate(); the
		-- design stamps schemaVersion to CURRENT regardless (tonumber-or-0 path in §3.5).
		local blob: { [string]: any } = {
			schemaVersion = "0",
			currencies = { Stardust = 1 },
			stats = { playtimeSeconds = 0, joinCount = 0 },
			timestamps = { firstJoinUnix = 0, lastSeenUnix = 0 },
			upgrades = {},
			flags = {},
			receipts = {},
		}
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.currencies.Stardust):toBe(1)
	end)

	it(
		"migrates a v1 blob UP to v2: adds the daily field, preserves everything, terminates",
		function()
			-- A record persisted under schemaVersion 1 (before the daily-streak feature) has NO `daily`
			-- field. migrate() must run step[1] to add it, stamp v2, and lose nothing — and TERMINATE
			-- (step[1] stamps the version so the loop cannot re-run it forever).
			local v1Blob: { [string]: any } = {
				schemaVersion = 1,
				currencies = { Stardust = 500, Prisms = 2 },
				stats = { playtimeSeconds = 10, joinCount = 3 },
				timestamps = { firstJoinUnix = 100, lastSeenUnix = 200 },
				upgrades = { ["collect-speed"] = 4 },
				flags = { tutorialDone = true },
				receipts = { r1 = true },
			}
			local migrated = Migrations.migrate(v1Blob)
			expect(migrated.schemaVersion):toBe(2)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- the new v2 field is present and defaulted
			expect(type((migrated :: any).daily)):toBe("table")
			expect((migrated :: any).daily.streak):toBe(0)
			expect((migrated :: any).daily.lastClaimUnix):toBe(0)
			-- nothing pre-existing was lost in the round-trip
			expect(migrated.currencies.Stardust):toBe(500)
			expect(migrated.currencies.Prisms):toBe(2)
			expect(migrated.upgrades["collect-speed"]):toBe(4)
			expect(migrated.flags.tutorialDone):toBe(true)
			expect(migrated.receipts.r1):toBe(true)
			expect(migrated.stats.joinCount):toBe(3)
		end
	)

	it("does NOT reset an already-advanced daily value on re-migrate (idempotent)", function()
		-- Re-migrating a current (v2) blob whose streak has progressed must preserve it — step[1] is
		-- guarded (only fills daily when absent), and a v2 blob skips the steps loop entirely.
		local data = Migrations.default(1)
		data.daily.streak = 5
		data.daily.lastClaimUnix = 999
		local migrated = Migrations.migrate(data)
		expect((migrated :: any).daily.streak):toBe(5)
		expect((migrated :: any).daily.lastClaimUnix):toBe(999)
	end)
end)

describe("Types.toView (allowlist projection — the client-safe contract)", function()
	it("strips server-only ledgers: receipts and analytics never reach the client", function()
		local data = Migrations.default(1)
		data.receipts["receipt_xyz"] = true
		(data :: any).analytics = { lastEventUnix = 12345 }
		local view = Types.toView(data :: any)
		expect((view :: any).receipts):toBe(nil)
		expect((view :: any).analytics):toBe(nil)
	end)

	it(
		"keeps exactly the player-facing subset (currencies/stats/upgrades/flags/version)",
		function()
			local data = Migrations.default(1)
			data.currencies.Stardust = 10
			data.upgrades.CollectSpeed = 1
			data.flags.tutorialDone = true
			local view = Types.toView(data :: any)
			expect(view.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(view.currencies.Stardust):toBe(10)
			expect(view.stats.joinCount):toBe(0)
			expect(view.upgrades.CollectSpeed):toBe(1)
			expect(view.flags.tutorialDone):toBe(true)
		end
	)

	it(
		"a NEW PlayerData field is invisible to the client by default (allowlist, not blocklist)",
		function()
			-- The design (§3.2): toView allowlists, so any field NOT named in toView is absent from
			-- the view. A future internal ledger added to PlayerData therefore cannot silently leak.
			local data = Migrations.default(1);
			(data :: any).secretServerLedger = { adminFlag = true }
			local view = Types.toView(data :: any)
			expect((view :: any).secretServerLedger):toBe(nil)
		end
	)
end)

describe("Config.clientSubset (client-safe config — no store names / budgets leak)", function()
	-- The design (§3.4): ClientContext.config exposes ONLY a documented subset; store names,
	-- key prefixes, and DataStore budgets are SERVER-ONLY and must never reach the client. This
	-- mirrors the toView leak-guard above so the client-safe-config contract is test-enforced.
	it("omits server-only fields (storeName / schemaKeyPrefix / dataStore are absent)", function()
		local subset = (Config :: any).clientSubset()
		expect((subset :: any).storeName):toBe(nil)
		expect((subset :: any).schemaKeyPrefix):toBe(nil)
		expect((subset :: any).dataStore):toBe(nil)
		expect((subset :: any).flagsSeed):toBe(nil)
	end)

	it("keeps the documented client-safe subset (rateDefaults present and intact)", function()
		local subset = (Config :: any).clientSubset()
		expect(type(subset.rateDefaults)):toBe("table")
		expect(subset.rateDefaults.maxPerWindow):toBe(Config.rateDefaults.maxPerWindow)
		expect(subset.rateDefaults.windowSeconds):toBe(Config.rateDefaults.windowSeconds)
	end)
end)
