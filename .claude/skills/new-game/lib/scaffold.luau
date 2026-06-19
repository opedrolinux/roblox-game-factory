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

local fs = require("@lune/fs")

local M = {}

export type Opts = {
	coreDir: string?, -- defaults to "core"
	gamesDir: string?, -- defaults to "games"
}

export type Result = {
	slug: string, -- the validated game name
	dest: string, -- where the fork was written
	store: string, -- the per-game DataStore name it was given
	title: string, -- the human title used in the forked CLAUDE.md
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

-- ── the scaffold ─────────────────────────────────────────────────────────────

-- Fork core/ → games/<slug>/ and make it unique. Throws (with a clear, prefix-free message)
-- on any problem; returns a Result on success.
function M.scaffold(slug: string, opts: Opts?): Result
	local options = opts or {}
	local coreDir = options.coreDir or "core"
	local gamesDir = options.gamesDir or "games"

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

	return {
		slug = slug,
		dest = dest,
		store = store,
		title = title,
	}
end

return M
