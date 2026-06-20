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
		"migrates a v1 blob ALL THE WAY UP to CURRENT: chains every step, preserves everything, terminates",
		function()
			-- A record persisted under schemaVersion 1 (before daily-streak / rebirth / lifetimeStardust)
			-- has NONE of the later fields. migrate() must CHAIN step[1] (daily) -> step[2] (rebirths) ->
			-- step[3] (lifetimeStardust), stamp CURRENT, and lose nothing — and TERMINATE (each step stamps
			-- its version so the loop cannot re-run a step forever). A FORGOTTEN stamp would infinite-loop
			-- (the drain guard / hang would fail), a MISSING seed would leave a field nil (asserted below),
			-- a CLOBBERED field would fail the preservation asserts.
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
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- step[1]: the daily field is present and defaulted
			expect(type((migrated :: any).daily)):toBe("table")
			expect((migrated :: any).daily.streak):toBe(0)
			expect((migrated :: any).daily.lastClaimUnix):toBe(0)
			-- step[2]: rebirths seeded to 0
			expect((migrated :: any).rebirths):toBe(0)
			-- step[3]: lifetimeStardust seeded FLOORED at the current Stardust balance (500)
			expect((migrated :: any).stats.lifetimeStardust):toBe(500)
			-- step[4]: boostExpiresUnix seeded to 0 (a legacy player has no persisted boost)
			expect((migrated :: any).boostExpiresUnix):toBe(0)
			-- nothing pre-existing was lost in the round-trip
			expect(migrated.currencies.Stardust):toBe(500)
			expect(migrated.currencies.Prisms):toBe(2)
			expect(migrated.upgrades["collect-speed"]):toBe(4)
			expect(migrated.flags.tutorialDone):toBe(true)
			expect(migrated.receipts.r1):toBe(true)
			expect(migrated.stats.joinCount):toBe(3)
		end
	)

	it(
		"v2 -> v3: seeds rebirths=0, stamps v3 en route to CURRENT, preserves all prior fields",
		function()
			-- A record persisted at v2 (has daily, but NO rebirths and NO lifetimeStardust). migrate()
			-- must run step[2] (seed rebirths) then step[3] (seed lifetimeStardust) and reach CURRENT.
			-- FALSIFIABLE: a forgotten v2->v3 stamp would infinite-loop; a missing rebirths seed leaves it
			-- nil; a clobbered daily/currency would fail the preservation asserts.
			local v2Blob: { [string]: any } = {
				schemaVersion = 2,
				currencies = { Stardust = 250, Prisms = 1 },
				stats = { playtimeSeconds = 5, joinCount = 2 },
				timestamps = { firstJoinUnix = 1, lastSeenUnix = 2 },
				upgrades = { magnet = 3 },
				flags = { tutorialDone = true },
				receipts = { r2 = true },
				daily = { streak = 4, lastClaimUnix = 12345 },
			}
			local migrated = Migrations.migrate(v2Blob)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- the v3 field is present + seeded
			expect((migrated :: any).rebirths):toBe(0)
			-- and the chained v4 field too (lifetimeStardust floored at Stardust 250)
			expect((migrated :: any).stats.lifetimeStardust):toBe(250)
			-- everything pre-existing (incl. the v2 daily field) is preserved
			expect((migrated :: any).daily.streak):toBe(4)
			expect((migrated :: any).daily.lastClaimUnix):toBe(12345)
			expect(migrated.currencies.Stardust):toBe(250)
			expect(migrated.currencies.Prisms):toBe(1)
			expect(migrated.upgrades.magnet):toBe(3)
			expect(migrated.stats.joinCount):toBe(2)
			expect(migrated.receipts.r2):toBe(true)
		end
	)

	it(
		"v3 -> v4: seeds stats.lifetimeStardust FLOORED at the current Stardust, stamps CURRENT, preserves all",
		function()
			-- A record persisted at v3 (has rebirths, NO lifetimeStardust, NO boostExpiresUnix). migrate()
			-- runs step[3] then step[4]; step[3] seeds lifetimeStardust = floor(Stardust), the best-available
			-- baseline. FALSIFIABLE: the floor matters — a fractional Stardust (777.9) must seed 777, not
			-- 777.9 and not 0; a missing seed leaves it nil; a forgotten stamp infinite-loops.
			local v3Blob: { [string]: any } = {
				schemaVersion = 3,
				currencies = { Stardust = 777.9, Prisms = 9 },
				stats = { playtimeSeconds = 8, joinCount = 6 },
				timestamps = { firstJoinUnix = 3, lastSeenUnix = 4 },
				upgrades = { backpack = 2 },
				flags = {},
				receipts = {},
				daily = { streak = 7, lastClaimUnix = 999 },
				rebirths = 3, -- an ADVANCED rebirths value: step[3] must not touch it
			}
			local migrated = Migrations.migrate(v3Blob)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- lifetimeStardust seeded FLOORED (777.9 -> 777), not raw, not 0
			expect((migrated :: any).stats.lifetimeStardust):toBe(777)
			-- step[4] also ran on the way to CURRENT: boostExpiresUnix seeded to 0
			expect((migrated :: any).boostExpiresUnix):toBe(0)
			-- the advanced rebirths value is preserved (step[3] does not seed it; it was already set)
			expect((migrated :: any).rebirths):toBe(3)
			-- all other fields preserved
			expect(migrated.currencies.Stardust):toBe(777.9)
			expect(migrated.currencies.Prisms):toBe(9)
			expect((migrated :: any).daily.streak):toBe(7)
			expect(migrated.upgrades.backpack):toBe(2)
			expect(migrated.stats.joinCount):toBe(6)
		end
	)

	it("v4 -> v5: seeds boostExpiresUnix=0, stamps CURRENT, preserves all prior fields", function()
		-- A record persisted at v4 (has daily/rebirths/lifetimeStardust, but NO boostExpiresUnix: the
		-- 2x boost was session-only before v5). migrate() must run step[4] ONLY: seed boostExpiresUnix=0
		-- (a legacy player carries no persisted boost) and reach CURRENT. FALSIFIABLE: a missing seed
		-- leaves boostExpiresUnix nil; a forgotten v4->v5 stamp infinite-loops; a clobbered prior field
		-- fails the preservation asserts below.
		local v4Blob: { [string]: any } = {
			schemaVersion = 4,
			currencies = { Stardust = 333, Prisms = 5 },
			stats = { playtimeSeconds = 9, joinCount = 4, lifetimeStardust = 1200 },
			timestamps = { firstJoinUnix = 7, lastSeenUnix = 8 },
			upgrades = { ["collect-speed"] = 6 },
			flags = { ["gamepass.2xStardust"] = true },
			receipts = { r4 = true },
			daily = { streak = 9, lastClaimUnix = 54321 },
			rebirths = 2,
		}
		local migrated = Migrations.migrate(v4Blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		-- the v5 field is present + seeded to 0 (no active boost)
		expect((migrated :: any).boostExpiresUnix):toBe(0)
		-- every pre-existing field (incl. the v4 lifetimeStardust) is preserved untouched
		expect((migrated :: any).stats.lifetimeStardust):toBe(1200)
		expect((migrated :: any).rebirths):toBe(2)
		expect((migrated :: any).daily.streak):toBe(9)
		expect((migrated :: any).daily.lastClaimUnix):toBe(54321)
		expect(migrated.currencies.Stardust):toBe(333)
		expect(migrated.currencies.Prisms):toBe(5)
		expect(migrated.upgrades["collect-speed"]):toBe(6)
		expect(migrated.flags["gamepass.2xStardust"]):toBe(true)
		expect(migrated.receipts.r4):toBe(true)
		expect(migrated.stats.joinCount):toBe(4)
	end)

	it(
		"does NOT reset an already-armed boostExpiresUnix on re-migrate (idempotent v5 seed)",
		function()
			-- Re-migrating a CURRENT blob whose boost is ACTIVE (a future expiry) must preserve it: step[4]
			-- only seeds when boostExpiresUnix is ABSENT, and a current-version blob skips the steps loop
			-- entirely. FALSIFIABLE: a non-idempotent step would reset the armed expiry to 0 and fail here.
			local data = Migrations.default(1)
			data.boostExpiresUnix = 99999
			local migrated = Migrations.migrate(data)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect((migrated :: any).boostExpiresUnix):toBe(99999) -- NOT reset to 0
		end
	)

	it("does NOT reset an already-advanced daily value on re-migrate (idempotent)", function()
		-- Re-migrating a CURRENT blob whose streak has progressed must preserve it — step[1] is guarded
		-- (only fills daily when absent), and a current blob skips the steps loop entirely.
		local data = Migrations.default(1)
		data.daily.streak = 5
		data.daily.lastClaimUnix = 999
		local migrated = Migrations.migrate(data)
		expect((migrated :: any).daily.streak):toBe(5)
		expect((migrated :: any).daily.lastClaimUnix):toBe(999)
	end)

	it(
		"does NOT reset advanced rebirths / lifetimeStardust on re-migrate (idempotent seeds)",
		function()
			-- Re-migrating a CURRENT blob whose rebirths + lifetimeStardust have ADVANCED past their seed
			-- defaults must preserve them. step[2]/step[3] only seed when the field is ABSENT, and a
			-- current-version blob skips the steps loop entirely. FALSIFIABLE: a non-idempotent step that
			-- re-seeded would reset rebirths to 0 / lifetimeStardust to floor(Stardust) and fail here.
			local data = Migrations.default(1)
			data.currencies.Stardust = 40
			data.rebirths = 12
			data.stats.lifetimeStardust = 9999
			local migrated = Migrations.migrate(data)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect((migrated :: any).rebirths):toBe(12) -- NOT reset to 0
			expect((migrated :: any).stats.lifetimeStardust):toBe(9999) -- NOT reset to floor(40)
			expect(migrated.currencies.Stardust):toBe(40)
		end
	)

	it(
		"default() seeds the fresh-player fields: Prisms=0, rebirths=0, lifetimeStardust=0, boostExpiresUnix=0",
		function()
			-- The fresh-player blob is a SEPARATE code site from the migrate() steps; it must seed all the
			-- post-v1 fields directly. FALSIFIABLE: a forgotten default seed leaves the field nil here.
			local data = Migrations.default(1)
			expect(data.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(data.currencies.Prisms):toBe(0)
			expect((data :: any).rebirths):toBe(0)
			expect((data :: any).stats.lifetimeStardust):toBe(0)
			expect((data :: any).boostExpiresUnix):toBe(0)
		end
	)
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
