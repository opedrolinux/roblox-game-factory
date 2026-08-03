--!strict
-- Pins the T2.5 staleness rule (ATTACK A9) against the artifact that motivated it.
--
-- THE DEFECT, MEASURED, NOT ASSUMED. Before this rule existed, `tier-status games/collect-sim` read
-- `tests/tier2/last-playtest.json` — dated 2026-08-01, verdict green, NO provenance block at all —
-- and reported:
--     highestGreen: "T2.5", ready: true,
--     label: "scene-verified-T2.5 — geometry, wiring and server effects checked"
-- while the harness and the game source had both changed underneath it. That is the whole of A9: a
-- hang emits no sentinel, no sentinel writes no artifact, and the previous green quietly covers
-- code it never saw.
--
-- Every check below drives the SHIPPED module. None restates its logic.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Provenance = require("../t25-provenance")

local spec = {}

local checks = 0
local failures: { string } = {}
local function check(name: string, cond: boolean, detail: string?)
	checks += 1
	if not cond then
		table.insert(failures, name .. " -- " .. (detail or ""))
	end
end

-- A game dir that really exists and really has a harness on disk, so the hash clause is exercised
-- against a real file rather than a mocked one.
local GAME = "games/collect-sim"
local HARNESS = GAME .. "/tests/tier2/playtest.server.luau"

local function run(): (number, { string })
	-- Guard first: if the fixture game moved, every check below would pass vacuously by falling into
	-- an earlier clause. Say so instead.
	check(
		"the fixture game's harness is on disk (else every hash check below is vacuous)",
		fs.isFile(HARNESS),
		HARNESS .. " not found"
	)
	if not fs.isFile(HARNESS) then
		return checks, failures
	end
	local realSha = serde.hash("sha256", fs.readFile(HARNESS))

	-- ── THE HISTORICAL ARTIFACT, VERBATIM IN SHAPE ───────────────────────────────────────────────
	local historical = { ok = true, verdict = "green", tier = 2.5, phases = {} }
	local reason = Provenance.staleReason(GAME, historical, nil)
	check(
		"an artifact with NO provenance block is stale (the collect-sim 2026-08-01 case)",
		reason ~= nil,
		"reason=" .. tostring(reason)
	)
	check(
		"and the reason NAMES the missing block rather than saying 'red'",
		reason ~= nil and string.find(tostring(reason), "no `provenance` block") ~= nil,
		"reason=" .. tostring(reason)
	)

	-- ── THE PLACEHOLDER THE TEMPLATE SHIPS ───────────────────────────────────────────────────────
	-- `PROVENANCE.scriptSha256` is "unknown" until a capture recipe stamps it. An unstamped run must
	-- not be able to credit anything — this is the fail-closed clause, and it is the one most likely
	-- to be "relaxed" later by somebody in a hurry.
	local unstamped = {
		provenance = { scriptSha256 = "unknown", ranAtUnix = 1785000000 },
	}
	local unstampedReason = Provenance.staleReason(GAME, unstamped, nil)
	check(
		'a scriptSha256 of "unknown" is stale, not exempt',
		unstampedReason ~= nil,
		"reason=" .. tostring(unstampedReason)
	)

	-- ── THE HARNESS CHANGED SINCE THE RUN ────────────────────────────────────────────────────────
	local wrongHash = {
		provenance = { scriptSha256 = string.rep("a", 64), ranAtUnix = 1785000000 },
	}
	local wrongHashReason = Provenance.staleReason(GAME, wrongHash, nil)
	check(
		"a recorded script hash that does not match the harness on disk is stale",
		wrongHashReason ~= nil and string.find(tostring(wrongHashReason), "CHANGED") ~= nil,
		"reason=" .. tostring(wrongHashReason)
	)

	-- ── THE GAME CHANGED SINCE THE RUN ───────────────────────────────────────────────────────────
	-- The mtime is injected rather than read, so this asserts the RULE and not the filesystem clock.
	local ranAt = 1785000000
	local matching = { provenance = { scriptSha256 = realSha, ranAtUnix = ranAt } }
	local afterReason = Provenance.staleReason(GAME, matching, ranAt + 60)
	check(
		"source modified AFTER the run is stale, even with a matching harness hash",
		afterReason ~= nil and string.find(tostring(afterReason), "modified AFTER") ~= nil,
		"reason=" .. tostring(afterReason)
	)
	check(
		"and the reason quantifies the gap, so a reader can judge it",
		afterReason ~= nil and string.find(tostring(afterReason), "60s later") ~= nil,
		"reason=" .. tostring(afterReason)
	)

	-- ── THE POSITIVE CONTROL ─────────────────────────────────────────────────────────────────────
	-- Without this, a module that returned a reason unconditionally would score six passes above.
	-- That is a different broken gate, not a fixed one.
	local beforeReason = Provenance.staleReason(GAME, matching, ranAt - 60)
	check(
		"CONTROL: a matching hash and source older than the run is FRESH",
		beforeReason == nil,
		"reason=" .. tostring(beforeReason)
	)
	local equalReason = Provenance.staleReason(GAME, matching, ranAt)
	check(
		"CONTROL: source touched in the same second as the run is fresh (not a strict inequality)",
		equalReason == nil,
		"reason=" .. tostring(equalReason)
	)

	-- ── AN UNASKABLE QUESTION IS NOT A PASS FOR THE OTHER ONE ────────────────────────────────────
	-- A nil mtime means "src/ could not be swept". The hash clause must still stand on its own.
	local nilMtimeStillChecksHash = Provenance.staleReason(GAME, wrongHash, nil)
	check(
		"an unsweepable src/ does not excuse a mismatched harness hash",
		nilMtimeStillChecksHash ~= nil,
		"reason=" .. tostring(nilMtimeStillChecksHash)
	)

	-- ── ranAtUnix MISSING ────────────────────────────────────────────────────────────────────────
	local noTime = { provenance = { scriptSha256 = realSha } }
	check(
		"a matching hash with NO ranAtUnix is still stale — it cannot be shown to postdate the code",
		Provenance.staleReason(GAME, noTime, nil) ~= nil
	)

	-- ── newestMtimeUnder ─────────────────────────────────────────────────────────────────────────
	local swept = Provenance.newestMtimeUnder(GAME .. "/src")
	check(
		"newestMtimeUnder returns a real timestamp for a real tree",
		type(swept) == "number" and (swept :: number) > 0,
		"swept=" .. tostring(swept)
	)
	check(
		"newestMtimeUnder returns nil for a tree that is not there",
		Provenance.newestMtimeUnder(GAME .. "/no-such-dir-xyz") == nil
	)

	return checks, failures
end

function spec.spec(): (number, { string })
	return run()
end

return spec
