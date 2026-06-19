--!strict
-- Log.luau — the factory's append-only run/audit log.
--
-- One JSON object per line ("JSONL") at <project-root>/logs/factory.jsonl. This is the
-- durable trace a human-on-the-loop reads to debug an unattended run — every fence
-- decision and self-heal event the hooks make, persisted instead of vanishing with the
-- turn. The B4 build pipeline writes its per-run journal into the same file (one `source`
-- field per producer), so you tail ONE file to see everything the factory did.
--
-- TOTALLY non-fatal by contract: every write is pcall-guarded and returns silently on any
-- error. Logging must NEVER change a fence decision or break a hook — a missing, locked,
-- or unwritable log is always preferable to a bricked agent.
--
-- Lune has no O_APPEND, so this is read-modify-write. Under heavy parallel fan-out two
-- concurrent writers can rarely drop a line; that is an accepted trade for an audit log and
-- is documented in `.claude/hooks/README.md`. Lune-only; never loaded inside Roblox.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local DateTime = require("@lune/datetime")

local Log = {}

-- RFC-3339 UTC, trimmed to whole seconds (drop fractional + keep it greppable).
local function isoNow(): string
	local ok, iso = pcall(function()
		return DateTime.now():toIsoDate()
	end)
	if not ok or type(iso) ~= "string" then
		return ""
	end
	return (string.gsub(iso, "%.%d+", ""))
end

-- Append one record as a single JSON line to <logDir>/factory.jsonl. Stamps `ts` if the
-- caller didn't. Returns true on a successful write — callers ignore it; the test reads it.
function Log.eventTo(logDir: string, record: { [string]: any }): boolean
	local ok = pcall(function()
		if record.ts == nil then
			record.ts = isoNow()
		end
		if not fs.isDir(logDir) then
			fs.writeDir(logDir)
		end
		local path = logDir .. "/factory.jsonl"
		local line = serde.encode("json", record) .. "\n"
		local existing = if fs.isFile(path) then fs.readFile(path) else ""
		fs.writeFile(path, existing .. line)
	end)
	return ok
end

-- Resolve the project root: $CLAUDE_PROJECT_DIR when Claude Code sets it (production),
-- else the hook payload's cwd (`rootHint`), else the process working directory.
local function projectRoot(rootHint: string?): string
	local env = process.env.CLAUDE_PROJECT_DIR
	if type(env) == "string" and string.match(env, "%S") ~= nil then
		return env
	end
	if type(rootHint) == "string" and string.match(rootHint, "%S") ~= nil then
		return rootHint
	end
	return "."
end

-- Append one record to <project-root>/logs/factory.jsonl.
function Log.event(record: { [string]: any }, rootHint: string?)
	Log.eventTo(projectRoot(rootHint) .. "/logs", record)
end

return Log
