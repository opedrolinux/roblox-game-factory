--!strict
-- new-game.luau — CLI entry for the `new-game` skill (see SKILL.md).
--
-- Usage:  lune run .claude/skills/new-game/new-game.luau <game-slug>
--
-- Thin wrapper over lib/scaffold: validate args, fork core/ → games/<slug>/, report. All the
-- real (and tested) work lives in lib/scaffold.luau.

local process = require("@lune/process")
local stdio = require("@lune/stdio")
local scaffold = require("./lib/scaffold")

-- Lune passes everything after the script path as process.args, including a literal "--"
-- separator if one is used. Skip it and take the first real argument as the slug.
local slug: string? = nil
for _, arg in process.args do
	if arg ~= "--" and arg ~= "" then
		slug = arg
		break
	end
end
if slug == nil then
	stdio.ewrite("usage: lune run .claude/skills/new-game/new-game.luau <game-slug>\n")
	stdio.ewrite("       e.g.  lune run .claude/skills/new-game/new-game.luau collect-sim\n")
	process.exit(1)
end

local ok, result = pcall(scaffold.scaffold, slug)
if not ok then
	stdio.ewrite("[new-game] cannot scaffold: " .. tostring(result) .. "\n")
	process.exit(1)
end

local r = result :: scaffold.Result
print(string.format("[new-game] scaffolded %q", r.slug))
print(string.format("  fork:      %s", r.dest))
print(string.format("  DataStore: %s", r.store))
print("  next:")
print(string.format("    1. run the gauntlet inside %s (stylua/selene/rojo/lune)", r.dest))
print(string.format("    2. confirm the spec at specs/%s.md", r.slug))
print("    3. run build-game to decompose the spec into features")
process.exit(0)
