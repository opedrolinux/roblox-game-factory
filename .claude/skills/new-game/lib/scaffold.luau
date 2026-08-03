--!strict
-- scaffold.luau — the deterministic half of the `new-game` skill.
--
-- Forks the `core/` foundation into `games/<slug>/` and makes the instance unique, so two
-- games can never collide on their Rojo project name or — the one that loses player data —
-- their DataStore name. This is pure, deterministic file work on purpose: scaffolding must
-- be reliable and testable, not LLM-improvised. The skill (SKILL.md) is the human-facing
-- wrapper; this module is the engine, and `tests/scaffold_spec.luau` proves it.
--
-- Every rename is ASSERTED to apply exactly as expected. If `core/` drifts (someone renames
-- the store key, say), the scaffold FAILS LOUDLY instead of quietly producing a non-unique
-- game — the same "an untested X is not an X" discipline as the fence.
--
-- ── WHY THIS FILE ALSO EMITS VERIFICATION MACHINERY ─────────────────────────────────────────
-- A human playtested games/collect-sim and said almost nothing worked. 66 defects were confirmed;
-- ONE pattern explained 26 of them: a value the player pays for is written to the save file, and
-- the rule that governs play is a hardcoded constant sitting right next to it, reading nothing.
-- 313 green Tier-1 tests coexisted with four shop upgrades that changed literally nothing, because
-- the tests asserted the WRITE and never the READ.
--
-- The machinery that catches that class (the T2.5 playtest harness, the dated waiver allowlist read
-- by gate-reachability) was built INSIDE collect-sim, i.e. after the damage. A gate that only exists
-- in the one game that already got burned is not a factory gate. So the scaffold now emits it on day
-- one: `tests/tier2/` (harness + AUTHORING.md + phases.json) and `tests/verification-allow.json`.
--
-- FAIL CLOSED: if the template is missing or has drifted out of the shape this file parses, the
-- scaffold ERRORS. It must never quietly produce a game with no T2.5 lane — a missing gate that
-- nobody notices is precisely how the smoke lane spent weeks green while building nothing.

local fs = require("@lune/fs")

local M = {}

export type Opts = {
	coreDir: string?, -- defaults to "core"
	gamesDir: string?, -- defaults to "games"
	templatesDir: string?, -- defaults to ".claude/skills/lib/templates"
}

-- One rostered phase, as it lands in `tests/tier2/phases.json` (schema `t25-phases/1`).
export type RosterEntry = {
	name: string,
	gating: boolean,
	structural: boolean, -- the ONLY place `deltasRequired = false` is legitimate
}

export type Manifest = {
	worldEnabled: boolean,
	roster: { RosterEntry },
}

export type Result = {
	slug: string, -- the validated game name
	dest: string, -- where the fork was written
	store: string, -- the per-game DataStore name it was given
	title: string, -- the human title used in the forked CLAUDE.md
	verification: { string }, -- repo-relative paths of the verification files emitted
}

-- ── small pure string helpers ────────────────────────────────────────────────

-- Plain (non-pattern) find/replace. Returns the new string and how many times it replaced,
-- so callers can assert the expected count. We never want Lua-pattern semantics here — the
-- needles contain `.`, `/`, `"` which are pattern metacharacters.
local function literalReplace(s: string, old: string, new: string): (string, number)
	local out: { string } = {}
	local count = 0
	local idx = 1
	while true do
		local found, stop = string.find(s, old, idx, true)
		if not found then
			break
		end
		table.insert(out, string.sub(s, idx, found - 1))
		table.insert(out, new)
		count += 1
		idx = stop + 1
	end
	table.insert(out, string.sub(s, idx))
	return table.concat(out), count
end

-- Split a kebab slug into its words, skipping empties.
local function splitHyphens(s: string): { string }
	local parts: { string } = {}
	for part in string.gmatch(s, "[^%-]+") do
		table.insert(parts, part)
	end
	return parts
end

local function capitalize(word: string): string
	return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
end

-- ── slug → derived names ─────────────────────────────────────────────────────

-- A kebab slug must: be non-empty, start with a lowercase letter, contain only [a-z0-9-],
-- have no double/trailing hyphen, and not be the reserved name "core". The charset alone
-- makes path traversal impossible (no `/`, `\`, or `.` can appear), so the slug can never
-- escape `games/`.
function M.validateSlug(slug: string): (boolean, string?)
	if type(slug) ~= "string" or slug == "" then
		return false, "game name is empty"
	end
	if #slug > 40 then
		return false, "game name is too long (max 40 characters)"
	end
	if string.match(slug, "^[a-z]") == nil then
		return false, "game name must start with a lowercase letter (a-z)"
	end
	if string.match(slug, "[^a-z0-9%-]") ~= nil then
		return false, "game name may contain only lowercase letters, digits, and hyphens"
	end
	if string.match(slug, "%-%-") ~= nil then
		return false, "game name must not contain a double hyphen"
	end
	if string.sub(slug, -1) == "-" then
		return false, "game name must not end with a hyphen"
	end
	if slug == "core" then
		return false, "'core' is reserved — it is the foundation, not a game"
	end
	return true, nil
end

-- "collect-sim" → "CollectSimData_v1". This mapping MUST be INJECTIVE: two distinct slugs must
-- never yield the same store name, or two games could silently share a DataStore and
-- cross-contaminate player data (the exact failure this whole module exists to prevent).
--
-- A letter-word boundary is recoverable because the word's first letter is uppercased. But a
-- DIGIT word's first character can't be uppercased, so a hyphen before a digit-word would
-- vanish — "game-2" and "game2" would BOTH give "Game2Data_v1". We therefore mark a digit-word
-- boundary with an underscore (a character a slug can never contain), keeping the map one-to-one:
-- "game-2" → "Game_2Data_v1" ≠ "game2" → "Game2Data_v1".
function M.slugToStore(slug: string): string
	local out: { string } = {}
	for index, word in splitHyphens(slug) do
		if index > 1 and string.match(word, "^%d") ~= nil then
			table.insert(out, "_")
		end
		table.insert(out, capitalize(word))
	end
	return table.concat(out) .. "Data_v1"
end

-- "collect-sim" → "Collect Sim". Human title for the forked CLAUDE.md heading.
function M.slugToTitle(slug: string): string
	local out: { string } = {}
	for _, word in splitHyphens(slug) do
		table.insert(out, capitalize(word))
	end
	return table.concat(out, " ")
end

-- ── file mutators (each fails loud) ──────────────────────────────────────────

local function applyRename(path: string, old: string, new: string, expected: number)
	if not fs.isFile(path) then
		error(string.format("expected file missing from the fork: %s", path), 0)
	end
	local replaced, count = literalReplace(fs.readFile(path), old, new)
	if count ~= expected then
		error(
			string.format(
				"rename mismatch in %s: expected %d occurrence(s) of [%s], found %d. "
					.. "core/ may have drifted — update the scaffolder before forking again.",
				path,
				expected,
				old,
				count
			),
			0
		)
	end
	fs.writeFile(path, replaced)
end

local function fillTokens(path: string, tokens: { [string]: string })
	if not fs.isFile(path) then
		error(string.format("CLAUDE.md missing from the fork: %s", path), 0)
	end
	local content = fs.readFile(path)
	for key, value in tokens do
		content = (literalReplace(content, "{{" .. key .. "}}", value))
	end
	if string.find(content, "{{", 1, true) ~= nil then
		error(string.format("unfilled {{token}} remains in %s after substitution", path), 0)
	end
	fs.writeFile(path, content)
end

-- Defense in depth behind the injective slugToStore: before forking, make sure no ALREADY
-- scaffolded game carries this store name (e.g. one whose storeName was edited by hand). Two
-- games sharing a DataStore name silently cross-contaminate player data, so a clash fails loud.
local function assertStoreUnique(gamesDir: string, store: string, slug: string)
	if not fs.isDir(gamesDir) then
		return
	end
	local needle = 'storeName = "' .. store .. '"'
	for _, entry in fs.readDir(gamesDir) do
		if entry ~= slug then
			local cfg = gamesDir .. "/" .. entry .. "/src/shared/Config.luau"
			if fs.isFile(cfg) and string.find(fs.readFile(cfg), needle, 1, true) ~= nil then
				error(
					string.format(
						"DataStore name %q is already used by game %q — choose a different game "
							.. "name so player data stays isolated.",
						store,
						entry
					),
					0
				)
			end
		end
	end
end

-- ── the T2.5 verification machinery the fork is born with ────────────────────

-- `deltasRequired = false` is legitimate for exactly these three phase names and no others: they
-- are STRUCTURAL — they assert the harness's own preconditions, and there is nothing in them to
-- move. Any other phase asking to skip the delta requirement is asking to be allowed to observe
-- nothing, which is the whole defect class. The harness hardcodes this same set; we cross-check
-- against it, so a drift on either side fails the scaffold instead of silently widening the hole.
local STRUCTURAL_PHASES: { [string]: boolean } = {
	["lane-limits"] = true,
	["bootstrap-parity"] = true,
	["no-log-errors"] = true,
}

-- Deterministic JSON emitter. `serde.encode` cannot promise key order for a Lua table, and these
-- files are REVIEWED IN DIFFS — the whole point of `phases.json` being a separate committed file is
-- that deleting a red phase shows up in a diff. A field order that shuffles run to run destroys
-- that. So the bytes are built by hand, ordered, and byte-stable.
local function manifestJson(manifest: Manifest): string
	local lines: { string } = {}
	table.insert(lines, "{")
	table.insert(lines, '\t"$schema": "t25-phases/1",')
	table.insert(
		lines,
		string.format('\t"world": { "enabled": %s },', tostring(manifest.worldEnabled))
	)
	table.insert(lines, '\t"roster": [')
	for index, entry in manifest.roster do
		table.insert(
			lines,
			string.format(
				'\t\t{ "name": %q, "gating": %s, "structural": %s }%s',
				entry.name,
				tostring(entry.gating),
				tostring(entry.structural),
				if index < #manifest.roster then "," else ""
			)
		)
	end
	table.insert(lines, "\t]")
	table.insert(lines, "}")
	return table.concat(lines, "\n") .. "\n"
end

-- Pull the harness's inline `ROSTER` mirror out of the template source.
--
-- The harness is a STANDALONE Roblox Script — `run-in-roblox` runs one script with no filesystem —
-- so it cannot read `phases.json`. It carries an inline mirror and emits it as `roster`; the ingest
-- side set-diffs the two. That only works if the scaffold derives `phases.json` FROM the template
-- rather than from a second hardcoded list here: a third copy of the roster would be a third thing
-- to drift, and this file would be the one place nobody thinks to look.
function M.parseRoster(source: string): { string }
	-- Deliberately tolerant of an EMPTY block (`local ROSTER = {\n}`): an emptied roster must fall
	-- through to the explicit "parsed to ZERO phases" error below, not be misreported as a missing
	-- ROSTER. The two are different mistakes and the message has to name the right one.
	local block = string.match(source, "\nlocal ROSTER = {\n(.-)}")
	if block == nil then
		error(
			"could not find `local ROSTER = { ... }` in the T2.5 template — the template has drifted; "
				.. "update .claude/skills/new-game/lib/scaffold.luau before scaffolding again",
			0
		)
	end
	local names: { string } = {}
	for line in string.gmatch(block :: string, "[^\n]+") do
		local name = string.match(line, '^%s*"([%w%-]+)",')
		if name ~= nil then
			table.insert(names, name :: string)
		end
	end
	if #names == 0 then
		error(
			"the T2.5 template's ROSTER parsed to ZERO phases — refusing to emit an empty roster",
			0
		)
	end
	return names
end

-- Pull every `Harness.phase({ name = ..., gating = ... })` declaration out of the template source.
--
-- Parsed independently of ROSTER on purpose: the two are then CROSS-CHECKED two-sided below. A
-- roster line with no phase behind it, or a phase nobody rostered, is a drifted template and fails
-- the scaffold. (`function Harness.phase(spec: PhaseSpec)` does not match — the needle requires the
-- literal table-call `Harness.phase({`.)
function M.parsePhases(source: string): { { name: string, gating: boolean, structural: boolean } }
	local found: { { name: string, gating: boolean, structural: boolean } } = {}
	local needle = "Harness.phase({"
	local index = 1
	while true do
		local start = string.find(source, needle, index, true)
		if start == nil then
			break
		end
		index = (start :: number) + #needle
		-- A phase spec always reaches its `body =` field; that bounds the window without an
		-- arbitrary character budget that a longer spec would silently overrun.
		local stop = string.find(source, "body = ", index, true) or (index + 400)
		local chunk = string.sub(source, index, stop)
		local name, gating =
			string.match(chunk, '^%s*name%s*=%s*"([%w%-]+)",%s*gating%s*=%s*(%a+),')
		if name == nil then
			error(
				string.format(
					"a `Harness.phase({...})` in the T2.5 template does not lead with "
						.. '`name = "...", gating = <bool>,` — the template has drifted. Offending text: %s',
					string.sub(chunk, 1, 80)
				),
				0
			)
		end
		table.insert(found, {
			name = name :: string,
			gating = (gating == "true"),
			structural = string.find(chunk, "deltasRequired = false", 1, true) ~= nil,
		})
	end
	if #found == 0 then
		error("the T2.5 template declared ZERO phases — refusing to emit a vacuous manifest", 0)
	end
	return found
end

-- Build `phases.json`'s contents from the template, cross-checking every claim.
function M.buildManifest(source: string): Manifest
	local rosterNames = M.parseRoster(source)
	local phases = M.parsePhases(source)

	local byName: { [string]: { name: string, gating: boolean, structural: boolean } } = {}
	for _, phase in phases do
		byName[phase.name] = phase
	end

	-- TWO-SIDED, exactly as the ingest side checks the emitted `roster` against this file. A
	-- one-sided check is satisfied by deleting a failing phase from the side it looks at.
	local roster: { RosterEntry } = {}
	for _, name in rosterNames do
		local phase = byName[name]
		if phase == nil then
			error(
				string.format(
					"T2.5 template roster lists %q but no `Harness.phase` declares it — template drift",
					name
				),
				0
			)
		end
		-- The structural carve-out is the one hole through which a phase can legitimately observe
		-- nothing, so it is pinned to a fixed name set on BOTH sides rather than trusted from either.
		if phase.structural ~= (STRUCTURAL_PHASES[name] == true) then
			error(
				string.format(
					"T2.5 template phase %q disagrees with the structural (deltasRequired=false) set — "
						.. "a non-structural phase must never be allowed to assert zero deltas",
					name
				),
				0
			)
		end
		table.insert(roster, { name = name, gating = phase.gating, structural = phase.structural })
	end
	for _, phase in phases do
		local rostered = false
		for _, name in rosterNames do
			if name == phase.name then
				rostered = true
				break
			end
		end
		if not rostered then
			error(
				string.format(
					"T2.5 template declares phase %q but ROSTER does not list it — template drift",
					phase.name
				),
				0
			)
		end
	end

	local worldRaw = string.match(source, "\nlocal GAME = {.-world%s*=%s*{.-enabled%s*=%s*(%a+),")
	if worldRaw ~= "true" and worldRaw ~= "false" then
		error("could not read `GAME.world.enabled` from the T2.5 template — template drift", 0)
	end

	return { worldEnabled = (worldRaw == "true"), roster = roster }
end

-- Copy the T2.5 harness + its authoring guide into the fork and derive the committed roster
-- manifest and the starter waiver allowlist. Returns the repo-relative paths written, so callers
-- (and the self-test) can assert on the real outputs rather than on this function's say-so.
local function emitVerification(dest: string, templatesDir: string): { string }
	local tier2Src = templatesDir .. "/tier2"
	local harnessSrc = tier2Src .. "/playtest.server.luau"
	local authoringSrc = tier2Src .. "/AUTHORING.md"
	for _, path in { harnessSrc, authoringSrc } do
		if not fs.isFile(path) then
			-- FAIL CLOSED. A game scaffolded with no T2.5 lane is a game whose lane can never go
			-- red, which is indistinguishable from a lane that is always green.
			error(
				string.format(
					"T2.5 template missing at %s — refusing to scaffold a game with no automated "
						.. "playtest lane",
					path
				),
				0
			)
		end
	end

	local tier2Dir = dest .. "/tests/tier2"
	if not fs.isDir(tier2Dir) then
		fs.writeDir(tier2Dir)
	end

	local harness = fs.readFile(harnessSrc)
	local manifest = M.buildManifest(harness) -- parses BEFORE writing anything

	local harnessDest = tier2Dir .. "/playtest.server.luau"
	local authoringDest = tier2Dir .. "/AUTHORING.md"
	local manifestDest = tier2Dir .. "/phases.json"
	local allowDest = dest .. "/tests/verification-allow.json"

	fs.writeFile(harnessDest, harness)
	fs.writeFile(authoringDest, fs.readFile(authoringSrc))
	fs.writeFile(manifestDest, manifestJson(manifest))

	-- The dated waiver allowlist, read by gate-reachability (`verification-allow/1`) and mirrored by
	-- the T2.5 harness. It ships EMPTY and it ships PRESENT: present so the format is discoverable
	-- and every waiver is a reviewable diff against a file that already exists; empty because a
	-- scaffold has nothing to excuse. Every entry needs `expiresUnix` within 30 days of `addedUnix`
	-- and must MATCH something, or the gate that names it fails — a date in a comment expires
	-- nothing, and a stale waiver for a fixed problem is how an allowlist rots into blanket
	-- suppression. Note we never write `tests/tier0/reachability-baseline.json`: a fabricated
	-- all-zero baseline would make the monotonic subject-count check unfailable forever.
	fs.writeFile(allowDest, '{\n\t"$schema": "verification-allow/1",\n\t"entries": []\n}\n')

	return { harnessDest, authoringDest, manifestDest, allowDest }
end

-- ── the scaffold ─────────────────────────────────────────────────────────────

-- Fork core/ → games/<slug>/ and make it unique. Throws (with a clear, prefix-free message)
-- on any problem; returns a Result on success.
function M.scaffold(slug: string, opts: Opts?): Result
	local options = opts or {}
	local coreDir = options.coreDir or "core"
	local gamesDir = options.gamesDir or "games"
	local templatesDir = options.templatesDir or ".claude/skills/lib/templates"

	local ok, why = M.validateSlug(slug)
	if not ok then
		error(string.format("invalid game name %q: %s", tostring(slug), tostring(why)), 0)
	end

	if not fs.isDir(coreDir) then
		error(string.format("core foundation not found at %q", coreDir), 0)
	end

	local store = M.slugToStore(slug)
	local title = M.slugToTitle(slug)

	local dest = gamesDir .. "/" .. slug
	if fs.isDir(dest) or fs.isFile(dest) then
		error(
			string.format("game %q already exists at %s — refusing to overwrite", slug, dest),
			0
		)
	end

	-- No two games may share a DataStore name, or their player data cross-contaminates.
	assertStoreUnique(gamesDir, store, slug)

	-- Prepare the games/ parent (clean error if the path is a file, not a directory).
	if fs.isFile(gamesDir) then
		error(string.format("games path %q is a file, not a directory", gamesDir), 0)
	end
	if not fs.isDir(gamesDir) then
		fs.writeDir(gamesDir)
	end

	-- One recursive copy forks the whole foundation tree.
	fs.copy(coreDir, dest)

	-- Uniqueness in the fork: the Rojo project name, the DataStore name, and the wally package.
	applyRename(dest .. "/default.project.json", '"name": "core"', '"name": "' .. slug .. '"', 1)
	applyRename(dest .. "/src/shared/Config.luau", '"CoreData_v1"', '"' .. store .. '"', 1)
	applyRename(
		dest .. "/wally.toml",
		'name = "factory/core"',
		'name = "factory/' .. slug .. '"',
		1
	)

	-- Fill the per-game engineering contract the fork carried from core/CLAUDE.md.
	fillTokens(dest .. "/CLAUDE.md", {
		GAME_SLUG = slug,
		GAME_TITLE = title,
		STORE_NAME = store,
	})

	-- The fork is born with its own T2.5 lane and its own waiver allowlist. Emitted LAST so a
	-- template drift fails after a fully-formed fork exists (easier to inspect) but still before any
	-- caller can mistake the game for finished — the error is unhandled and the scaffold reports red.
	local verification = emitVerification(dest, templatesDir)

	return {
		slug = slug,
		dest = dest,
		store = store,
		title = title,
		verification = verification,
	}
end

return M
