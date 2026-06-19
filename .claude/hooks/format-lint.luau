--!strict
-- format-lint.luau — PostToolUse self-healing hook (FACTORY.md §3).
--
-- After an Edit/Write/MultiEdit to a `.luau` file, run the gauntlet's front two checks
-- on just that file — `stylua --check` and `selene` — and, if either reports something,
-- feed the findings straight back to the model (PostToolUse, exit 2 → stderr is shown to
-- Claude) so it fixes them in the same turn instead of discovering them later at the full
-- gauntlet. This is the "self-healing, not blind generation" mechanism.
--
-- Scoping: it only checks a file that lives under a directory tree carrying a
-- `stylua.toml`, walking up from the file. That naturally limits it to `core/` (and any
-- future game dir with its own config) and, deliberately, does NOT lint the Lune hook
-- scripts themselves — they use process/stdio APIs the core's roblox-fenced selene std
-- would (correctly, for game code) reject.
--
-- This hook NEVER blocks — PostToolUse runs after the tool already executed. Exit 2 here
-- only surfaces feedback; any tooling problem (missing binary, missing config) fails open
-- silently. Lune-only; never loaded in Roblox.

local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local process = require("@lune/process")
local fs = require("@lune/fs")

local Log = require("./lib/Log")

local function done(code: number)
	process.exit(code)
end

-- ── parse stdin (fail-open) ──────────────────────────────────────────────────
local raw = stdio.readToEnd()
if not string.match(raw, "%S") then
	done(0)
end

local ok, payload = pcall(serde.decode, "json", raw)
if not ok or type(payload) ~= "table" then
	done(0)
end

local toolInput = payload.tool_input
if type(toolInput) ~= "table" or type(toolInput.file_path) ~= "string" then
	done(0)
end

local cwdHint: string? = if type(payload.cwd) == "string" then payload.cwd else nil
local filePath: string = toolInput.file_path
if not string.match(filePath, "%.luau$") then
	done(0) -- only Luau files
end

-- ── locate the nearest config dir by walking up ──────────────────────────────
local function parentDir(path: string): string?
	local normalized = string.gsub(path, "\\", "/")
	local parent = string.match(normalized, "^(.*)/[^/]+$")
	return parent
end

local function findConfigDir(fromFile: string): (string?, boolean)
	local dir = parentDir(fromFile)
	local guard = 0
	while dir and guard < 40 do
		guard += 1
		local styluaCfg = dir .. "/stylua.toml"
		if fs.isFile(styluaCfg) then
			local seleneCfg = fs.isFile(dir .. "/selene.toml")
			return dir, seleneCfg
		end
		local up = parentDir(dir)
		if up == dir then
			break
		end
		dir = up
	end
	return nil, false
end

local configDir, hasSelene = findConfigDir(filePath)
if not configDir then
	done(0) -- file isn't in a checked tree
end
local cfgDir: string = configDir :: string

-- ── run the checks (each fails open) ─────────────────────────────────────────
local findings: { string } = {}

local function runTool(program: string, args: { string }): (boolean, string)
	local execOk, result = pcall(function()
		return process.exec(program, args, { cwd = cfgDir })
	end)
	if not execOk then
		return true, "" -- binary missing or spawn failed → skip (fail open)
	end
	local r = result :: any
	local combined = (r.stdout or "") .. (r.stderr or "")
	return r.ok, combined
end

-- stylua --check: exits non-zero if the file would be reformatted
local styluaOk, styluaOut = runTool("stylua", { "--check", filePath })
if not styluaOk and string.match(styluaOut, "%S") then
	table.insert(findings, "stylua (formatting):\n" .. styluaOut)
end

-- selene: only if this tree has a selene.toml
if hasSelene then
	local seleneOk, seleneOut = runTool("selene", { filePath })
	-- selene exits non-zero on lint findings; a config/parse error also fails non-zero,
	-- but its output names the problem, so surfacing it is still useful.
	if not seleneOk and string.match(seleneOut, "%S") then
		table.insert(findings, "selene (lint):\n" .. seleneOut)
	end
end

if #findings == 0 then
	Log.event(
		{ source = "format-lint", tool = payload.tool_name, file = filePath, decision = "clean" },
		cwdHint
	)
	done(0)
end

Log.event({
	source = "format-lint",
	tool = payload.tool_name,
	file = filePath,
	decision = "issues",
	findings = #findings,
}, cwdHint)

stdio.ewrite(
	"[fence:format-lint] "
		.. filePath
		.. " needs attention before it will pass the gauntlet:\n\n"
		.. table.concat(findings, "\n\n")
		.. "\nFix these now (same turn) so the file stays green.\n"
)
done(2)
