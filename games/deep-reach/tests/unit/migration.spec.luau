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
			expect(data.currencies.Credits):toBe(0)
			expect(data.currencies.Pearls):toBe(0)
			expect(data.stats.joinCount):toBe(0)
			expect(data.stats.playtimeSeconds):toBe(0)
			-- Reserved B2 seams exist as empty tables so B2 adds logic, not schema (§3.2).
			expect(type(data.upgrades)):toBe("table")
			expect(type(data.flags)):toBe("table")
			expect(type(data.receipts)):toBe("table")
		end
	)

	it("does NOT seed the foundation game's currency (Stardust is not this game's)", function()
		-- The scaffold inherited `currencies = { Stardust = 0 }`. Left in place, Deep Reach mints
		-- a currency it does not have. Asserted as an ABSENCE so a re-inherited seed fails here.
		local data = Migrations.default(1)
		expect(data.currencies.Stardust):toBe(nil)
	end)

	it("seeds EVERY field the migration steps add (default is a separate code site)", function()
		-- A seed present in steps[] but missing from default() ships fresh players without the
		-- field — the classic half-migration. One assertion per step, so this test fails the
		-- moment a step is added without its matching default seed.
		local data = Migrations.default(1)
		expect(data.stats.lifetimeCredits):toBe(0) -- [1] v1->v2
		expect(data.plot.plotId):toBe("") -- [2] v2->v3
		expect(data.plot.claimedAtUnix):toBe(0)
		expect(data.daily.streak):toBe(0) -- [3] v3->v4
		expect(data.daily.lastClaimUnix):toBe(0)
		expect(data.smelter.storedCredits):toBe(0) -- [4] v4->v5
		expect(data.smelter.lastTickUnix):toBe(0)
		expect(data.resurfaces):toBe(0) -- [5] v5->v6
		expect(data.boostExpiresUnix):toBe(0) -- [6] v6->v7
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- Per-step migration round-trips (contract pass: v1 -> v7, six steps landing at once).
--
-- Each case below is SELF-VERIFYING against the three ways a step can be wrong:
--   * a FORGOTTEN STAMP (`schemaVersion = N`) — migrate() would spin on the same index; the
--     bounded loop below plus the "lands at CURRENT" assertion catches it. (Migrations.migrate
--     also stamps CURRENT unconditionally at the end, which is exactly why a per-step assertion
--     on the INTERMEDIATE field values — not just on the final version — is required: the final
--     stamp alone would look green with every step skipped.)
--   * a MISSING SEED — the new field reads nil.
--   * a CLOBBERED field — every PRIOR field is re-asserted after the round-trip.
-- ---------------------------------------------------------------------------------------------

-- A minimal blob at exactly `version`, carrying recognisable values in every field a step at or
-- below that version is responsible for. Deliberately hand-written (NOT built from default()), so
-- a broken default() cannot make these tests pass.
local function blobAtVersion(version: number): { [string]: any }
	local blob: { [string]: any } = {
		schemaVersion = version,
		currencies = { Credits = 900, Pearls = 4 },
		stats = { playtimeSeconds = 77, joinCount = 9 },
		timestamps = { firstJoinUnix = 111, lastSeenUnix = 222 },
		upgrades = { drones = 3, hull = 2 },
		flags = { ["gamepass.doubleCredits"] = true },
		receipts = { legacyReceipt = true },
	}
	if version >= 2 then
		blob.stats.lifetimeCredits = 5000
	end
	if version >= 3 then
		blob.plot = { plotId = "dome_4", claimedAtUnix = 1700000000 }
	end
	if version >= 4 then
		blob.daily = { streak = 6, lastClaimUnix = 1700000100 }
	end
	if version >= 5 then
		blob.smelter = { storedCredits = 250, lastTickUnix = 1700000200 }
	end
	if version >= 6 then
		blob.resurfaces = 3
	end
	if version >= 7 then
		blob.boostExpiresUnix = 1700009999
	end
	return blob
end

-- Re-assert every field a blob at `version` carried, AFTER a migrate(). Any step that clobbers a
-- predecessor's field fails here rather than silently shipping.
local function expectPriorFieldsPreserved(migrated: { [string]: any }, version: number): ()
	expect(migrated.currencies.Credits):toBe(900)
	expect(migrated.currencies.Pearls):toBe(4)
	expect(migrated.stats.playtimeSeconds):toBe(77)
	expect(migrated.stats.joinCount):toBe(9)
	expect(migrated.timestamps.firstJoinUnix):toBe(111)
	expect(migrated.timestamps.lastSeenUnix):toBe(222)
	expect(migrated.upgrades.drones):toBe(3)
	expect(migrated.upgrades.hull):toBe(2)
	expect(migrated.flags["gamepass.doubleCredits"]):toBe(true)
	expect(migrated.receipts.legacyReceipt):toBe(true)
	if version >= 2 then
		expect(migrated.stats.lifetimeCredits):toBe(5000)
	end
	if version >= 3 then
		expect(migrated.plot.plotId):toBe("dome_4")
		expect(migrated.plot.claimedAtUnix):toBe(1700000000)
	end
	if version >= 4 then
		expect(migrated.daily.streak):toBe(6)
		expect(migrated.daily.lastClaimUnix):toBe(1700000100)
	end
	if version >= 5 then
		expect(migrated.smelter.storedCredits):toBe(250)
		expect(migrated.smelter.lastTickUnix):toBe(1700000200)
	end
	if version >= 6 then
		expect(migrated.resurfaces):toBe(3)
	end
	if version >= 7 then
		expect(migrated.boostExpiresUnix):toBe(1700009999)
	end
end

describe("Migrations.steps v1->v7 (one round-trip per step)", function()
	it("CURRENT_SCHEMA_VERSION is 7 and a step is registered for every gap below it", function()
		-- Guards the gap migrate() SILENTLY swallows: an unregistered step hits the
		-- non-destructive `break`, so the blob is stamped CURRENT while its fields never arrive.
		expect(Types.CURRENT_SCHEMA_VERSION):toBe(7)
		local stepList = (Migrations :: any).steps
		expect(type(stepList)):toBe("table")
		for version = 1, Types.CURRENT_SCHEMA_VERSION - 1 do
			expect(type(stepList[version])):toBe("function")
		end
	end)

	-- DELIBERATELY THE FIRST TEST THAT TOUCHES THE STEPS, and it calls each step DIRECTLY rather
	-- than through migrate(). migrate() advances by READING the stamp a step wrote, so a step that
	-- forgets `old.schemaVersion = N` makes the loop spin on the same index FOREVER — the suite
	-- would hang, not fail, and a hang is not a red test. Running each step in isolation turns
	-- that hang into a clean assertion failure before any migrate() below can reach it.
	it("every step STAMPS its target version (an unstamped step would hang migrate())", function()
		local stepList = (Migrations :: any).steps
		for from = 1, Types.CURRENT_SCHEMA_VERSION - 1 do
			local out = stepList[from](blobAtVersion(from))
			expect(out.schemaVersion):toBe(from + 1)
		end
	end)

	it(
		"[1] v1 -> v7: seeds stats.lifetimeCredits from the Credits balance, loses nothing",
		function()
			local blob = blobAtVersion(1)
			local migrated = Migrations.migrate(blob)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- A pre-existing blob has no earn ledger: seeded from the current Credits balance.
			expect(migrated.stats.lifetimeCredits):toBe(900)
			expectPriorFieldsPreserved(migrated, 1)
			-- Every LATER step also ran on the way up (this is the full v1->v7 round-trip).
			expect(migrated.plot.plotId):toBe("")
			expect(migrated.daily.streak):toBe(0)
			expect(migrated.smelter.storedCredits):toBe(0)
			expect(migrated.resurfaces):toBe(0)
			expect(migrated.boostExpiresUnix):toBe(0)
		end
	)

	it("[1] a v1 blob with NO stats table is repaired, not crashed (defensive)", function()
		local blob: { [string]: any } = { schemaVersion = 1, currencies = { Credits = 42 } }
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.stats.lifetimeCredits):toBe(42)
	end)

	it("[2] v2 -> v7: seeds plot = { plotId = '', claimedAtUnix = 0 }, loses nothing", function()
		local blob = blobAtVersion(2)
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.plot.plotId):toBe("")
		expect(migrated.plot.claimedAtUnix):toBe(0)
		expectPriorFieldsPreserved(migrated, 2)
	end)

	it("[3] v3 -> v7: seeds daily = { streak = 0, lastClaimUnix = 0 }, loses nothing", function()
		local blob = blobAtVersion(3)
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.daily.streak):toBe(0)
		-- 0 = never claimed, so the supply-drop window is open immediately on first join.
		expect(migrated.daily.lastClaimUnix):toBe(0)
		expectPriorFieldsPreserved(migrated, 3)
	end)

	it(
		"[4] v4 -> v7: seeds smelter = { storedCredits = 0, lastTickUnix = 0 }, loses nothing",
		function()
			local blob = blobAtVersion(4)
			local migrated = Migrations.migrate(blob)
			expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(migrated.smelter.storedCredits):toBe(0)
			expect(migrated.smelter.lastTickUnix):toBe(0)
			expectPriorFieldsPreserved(migrated, 4)
		end
	)

	it("[5] v5 -> v7: seeds resurfaces = 0, loses nothing", function()
		local blob = blobAtVersion(5)
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.resurfaces):toBe(0)
		expectPriorFieldsPreserved(migrated, 5)
	end)

	it("[6] v6 -> v7: seeds boostExpiresUnix = 0, loses nothing", function()
		local blob = blobAtVersion(6)
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.boostExpiresUnix):toBe(0)
		expectPriorFieldsPreserved(migrated, 6)
	end)

	-- THE idempotency test that actually bites. Going through migrate() twice does NOT exercise
	-- this: after the first pass the blob is stamped v7, so the second pass runs ZERO steps and a
	-- step that seeds UNCONDITIONALLY (`old.resurfaces = 0` instead of only-when-absent) stays
	-- green. Measured, not assumed — that exact mutation passed the two migrate()-based cases
	-- below. So call each step DIRECTLY, on a blob at its own from-version that ALREADY carries an
	-- advanced value for the field that step seeds, and assert the value SURVIVES.
	it("EVERY step preserves an existing value (seeds only-when-absent, per step)", function()
		local stepList = (Migrations :: any).steps

		-- [1] lifetimeCredits: a v1 blob that already has one must not be re-seeded from the
		-- (much smaller, spent-down) Credits balance — that would rewrite leaderboard history.
		local one = blobAtVersion(1)
		one.stats.lifetimeCredits = 4242
		expect(stepList[1](one).stats.lifetimeCredits):toBe(4242)

		-- [2] plot: a re-migrate must never EVICT a live claim.
		local two = blobAtVersion(2)
		two.plot = { plotId = "dome_live", claimedAtUnix = 1700000500 }
		local twoOut = stepList[2](two)
		expect(twoOut.plot.plotId):toBe("dome_live")
		expect(twoOut.plot.claimedAtUnix):toBe(1700000500)

		-- [3] daily: re-seeding lastClaimUnix = 0 would re-open a claimed supply drop -> free claim.
		local three = blobAtVersion(3)
		three.daily = { streak = 12, lastClaimUnix = 1700000700 }
		local threeOut = stepList[3](three)
		expect(threeOut.daily.streak):toBe(12)
		expect(threeOut.daily.lastClaimUnix):toBe(1700000700)

		-- [4] smelter: re-seeding would DESTROY un-collected output and reset the accrual base.
		local four = blobAtVersion(4)
		four.smelter = { storedCredits = 812, lastTickUnix = 1700000600 }
		local fourOut = stepList[4](four)
		expect(fourOut.smelter.storedCredits):toBe(812)
		expect(fourOut.smelter.lastTickUnix):toBe(1700000600)

		-- [5] resurfaces: re-seeding would shrink the player's PERMANENT prestige multiplier.
		local five = blobAtVersion(5)
		five.resurfaces = 5
		expect(stepList[5](five).resurfaces):toBe(5)

		-- [6] boostExpiresUnix: re-seeding would cancel a PAID 2x boost. Real money.
		local six = blobAtVersion(6)
		six.boostExpiresUnix = 1700000800
		expect(stepList[6](six).boostExpiresUnix):toBe(1700000800)
	end)

	it("re-migrating a CURRENT blob resets no advanced value", function()
		local advanced = blobAtVersion(7)
		advanced.plot = { plotId = "dome_9", claimedAtUnix = 1700000500 }
		advanced.smelter = { storedCredits = 812, lastTickUnix = 1700000600 }
		advanced.daily = { streak = 12, lastClaimUnix = 1700000700 }
		advanced.resurfaces = 5
		advanced.boostExpiresUnix = 1700000800
		advanced.stats.lifetimeCredits = 123456

		local once = Migrations.migrate(advanced)
		local twice = Migrations.migrate(once)

		expect(twice.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(twice.stats.lifetimeCredits):toBe(123456)
		expect(twice.plot.plotId):toBe("dome_9")
		expect(twice.plot.claimedAtUnix):toBe(1700000500)
		expect(twice.smelter.storedCredits):toBe(812)
		expect(twice.smelter.lastTickUnix):toBe(1700000600)
		expect(twice.daily.streak):toBe(12)
		expect(twice.daily.lastClaimUnix):toBe(1700000700)
		expect(twice.resurfaces):toBe(5)
		expect(twice.boostExpiresUnix):toBe(1700000800)
	end)

	it(
		"a v1 blob migrated TWICE is identical to migrating it once (no double-seed drift)",
		function()
			local once = Migrations.migrate(blobAtVersion(1))
			-- Advance the values a real session would have written after the first migration...
			once.plot.plotId = "dome_2"
			once.resurfaces = 1
			once.smelter.storedCredits = 77
			once.daily.streak = 3
			once.boostExpiresUnix = 1700001111
			once.stats.lifetimeCredits = 6400
			-- ...then re-run every step over it. Nothing may be reset.
			local twice = Migrations.migrate(once)
			expect(twice.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			expect(twice.plot.plotId):toBe("dome_2")
			expect(twice.resurfaces):toBe(1)
			expect(twice.smelter.storedCredits):toBe(77)
			expect(twice.daily.streak):toBe(3)
			expect(twice.boostExpiresUnix):toBe(1700001111)
			expect(twice.stats.lifetimeCredits):toBe(6400)
		end
	)
end)

describe("Migrations.migrate (round-trip, no data loss)", function()
	it("a current-version blob round-trips unchanged (idempotent)", function()
		local data = Migrations.default(1)
		data.currencies.Credits = 123
		data.currencies.Prisms = 7 -- a NEW currency added without a migration (map, not fixed fields)
		data.upgrades.CollectSpeed = 4
		data.flags.tutorialDone = true
		local migrated = Migrations.migrate(data)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.currencies.Credits):toBe(123)
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
				currencies = { Credits = 999 },
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
			expect(migrated.currencies.Credits):toBe(999)
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
			currencies = { Credits = 1 },
			stats = { playtimeSeconds = 0, joinCount = 0 },
			timestamps = { firstJoinUnix = 0, lastSeenUnix = 0 },
			upgrades = {},
			flags = {},
			receipts = {},
		}
		local migrated = Migrations.migrate(blob)
		expect(migrated.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		expect(migrated.currencies.Credits):toBe(1)
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

	it("keeps exactly the player-facing subset, and NOT the server bookkeeping [A13]", function()
		local data = Migrations.default(1)
		data.currencies.Credits = 10
		data.upgrades.CollectSpeed = 1
		data.flags.tutorialDone = true
		local view = Types.toView(data :: any)
		expect(view.currencies.Credits):toBe(10)
		expect(view.upgrades.CollectSpeed):toBe(1)
		expect(view.flags.tutorialDone):toBe(true)
		-- [A13] Both used to ride the wire and neither was ever read by a client file.
		-- schemaVersion is Migrations' business; joinCount is analytics'. Asserted as absent
		-- rather than deleted-and-forgotten, so re-adding either is a RED, not a silent
		-- bandwidth regression that only `reachability` would notice.
		expect((view :: any).schemaVersion):toBe(nil)
		expect((view.stats :: any).joinCount):toBe(nil)
	end)

	it(
		"carries every NEW client-facing v7 field to the client (a missing line ships nil)",
		function()
			-- toView is an ALLOWLIST: a field added to PlayerData is invisible to the client until
			-- named here deliberately. That safety property has the matching failure mode — a
			-- client-facing field whose line was FORGOTTEN renders as nil in the HUD with nothing
			-- red anywhere. One assertion per allowlist line, plus stats (copied WHOLESALE, so
			-- lifetimeCredits needs no line of its own and this proves the value still arrives).
			local data = Migrations.default(1)
			data.plot = { plotId = "dome_1", claimedAtUnix = 1700000000 }
			data.smelter = { storedCredits = 33, lastTickUnix = 1700000010 }
			data.daily = { streak = 4, lastClaimUnix = 1700000020 }
			data.resurfaces = 2
			data.boostExpiresUnix = 1700000030
			data.stats.lifetimeCredits = 8800
			local view = Types.toView(data :: any)
			expect(view.plot.plotId):toBe("dome_1")
			expect(view.plot.claimedAtUnix):toBe(1700000000)
			expect(view.smelter.storedCredits):toBe(33)
			expect(view.smelter.lastTickUnix):toBe(1700000010)
			expect(view.daily.streak):toBe(4)
			expect(view.daily.lastClaimUnix):toBe(1700000020)
			expect(view.resurfaces):toBe(2)
			expect(view.boostExpiresUnix):toBe(1700000030)
			expect(view.stats.lifetimeCredits):toBe(8800)
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
