--!strict
-- t25-provenance.luau — is a recorded T2.5 artifact still ABOUT the tree it is being used to credit?
--
-- ATTACK A9, and the only reason this module exists. A hung playtest emits no sentinel line. No
-- sentinel means no new artifact — and the PREVIOUS artifact is still on disk, still green. The lane
-- then credits its last success to whatever the tree contains now, which is exactly the code nobody
-- managed to run. Nothing about a green `last-playtest.json` says WHEN it ran, or against WHAT.
--
-- This was not theoretical. `games/collect-sim/tests/tier2/last-playtest.json` (2026-08-01, verdict
-- green, NO provenance block at all) was read by `tier-status` as
--   highestGreen T2.5, ready: true, "scene-verified-T2.5 — geometry, wiring and server effects
--   checked"
-- while the harness and the game source had both changed underneath it. That artifact is the fixture
-- this module's spec is built from.
--
-- Two independent staleness questions, because they fail in different ways:
--   * did the HARNESS change since this ran?  -> compare the recorded script hash to the file on disk
--   * did the GAME change since this ran?     -> compare `ranAtUnix` to the newest mtime under src/
-- Either one failing means the artifact describes a different program than the one being credited.
--
-- FAIL-CLOSED THROUGHOUT. An artifact with no provenance is stale, not exempt; a `scriptSha256` of
-- "unknown" is stale, not exempt. "The field was missing" has never been a reason to trust a claim.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local provenance = {}

-- Newest mtime anywhere under `root`, or nil if the tree is absent/unreadable. nil is deliberately
-- NOT treated as fresh by the caller's mtime clause — it is treated as "this question could not be
-- asked", and the hash clause above it still stands on its own.
function provenance.newestMtimeUnder(root: string): number?
	if not fs.isDir(root) then
		return nil
	end
	local newest: number? = nil
	local function walk(path: string): ()
		for _, entry in fs.readDir(path) do
			local full = path .. "/" .. entry
			if fs.isDir(full) then
				walk(full)
			else
				local ok, meta = pcall(fs.metadata, full)
				if ok and meta ~= nil and (meta :: any).modifiedAt ~= nil then
					local at = ((meta :: any).modifiedAt :: any).unixTimestamp
					if type(at) == "number" and (newest == nil or at > (newest :: number)) then
						newest = at
					end
				end
			end
		end
	end
	if not pcall(walk, root) then
		return nil
	end
	return newest
end

-- Returns nil when the artifact is fresh, or a HUMAN-READABLE reason it is not. The reason is the
-- product here: a bare `false` would send the next reader hunting through phase results for a
-- failure that is not in them, because the artifact's phases all passed. It is the artifact itself
-- that no longer describes this tree.
--
-- `now` is injectable so the spec can drive the mtime clause deterministically rather than racing
-- the filesystem clock.
function provenance.staleReason(gameDir: string, artifact: any, newestSrcMtime: number?): string?
	if type(artifact) ~= "table" then
		return "the artifact is not a table, so it carries no provenance to check"
	end
	local p = (artifact :: any).provenance
	if type(p) ~= "table" then
		return "the artifact records no `provenance` block at all, so nothing says what tree it ran against"
	end

	local recorded = (p :: any).scriptSha256
	if type(recorded) ~= "string" or recorded == "" or recorded == "unknown" then
		return '`provenance.scriptSha256` is absent or "unknown" — an unidentified harness cannot be matched to the one on disk'
	end
	local harness = gameDir .. "/tests/tier2/playtest.server.luau"
	if not fs.isFile(harness) then
		return "the artifact claims a harness hash but " .. harness .. " is not on disk"
	end
	local hashed, actual = pcall(function(): string
		return serde.hash("sha256", fs.readFile(harness))
	end)
	if not hashed then
		return "the harness on disk could not be hashed to compare against the artifact"
	end
	local onDisk = actual :: string
	if string.lower(onDisk) ~= string.lower(recorded) then
		local was, now = string.sub(recorded, 1, 12), string.sub(onDisk, 1, 12)
		return `the harness on disk has CHANGED since this ran (artifact scriptSha256 {was}…, on disk {now}…) — this green describes a different harness`
	end

	local ranAt = (p :: any).ranAtUnix
	if type(ranAt) ~= "number" or ranAt <= 0 then
		return "`provenance.ranAtUnix` is absent — an artifact with no timestamp cannot be shown to postdate the code it is crediting"
	end
	if newestSrcMtime ~= nil and (newestSrcMtime :: number) > ranAt then
		local lag = (newestSrcMtime :: number) - ranAt
		return `game source under src/ was modified AFTER this playtest ran ({lag}s later) — the run never saw the code it is being used to credit. This is what a hang looks like from the outside: no new artifact, and the old one quietly covering new code.`
	end
	return nil
end

return provenance
