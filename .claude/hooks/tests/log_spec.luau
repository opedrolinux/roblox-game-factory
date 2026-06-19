--!strict
-- log_spec.luau — proves the run/audit log writes well-formed, parseable JSONL.
--
-- Returns a function the corpus runner (`run.luau`) calls. It writes a couple of records
-- to a throwaway temp dir (NOT the real logs/), reads them back, asserts the shape, and
-- cleans up. Returns (checksRun, failures) so the runner can fold it into the one report.
-- Uses Log.eventTo (explicit dir) so the test never depends on $CLAUDE_PROJECT_DIR.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Log = require("../lib/Log")

type Fail = { note: string, detail: string }

local function tmpDir(): string
	local base = process.env.TEMP or process.env.TMPDIR or process.env.TMP or "/tmp"
	return base .. "/factory_log_selftest"
end

return function(): (number, { Fail })
	local fails: { Fail } = {}
	local checks = 0
	local dir = tmpDir()
	local path = dir .. "/factory.jsonl"

	local function check(note: string, ok: boolean, detail: string)
		checks += 1
		if not ok then
			table.insert(fails, { note = note, detail = detail })
		end
	end

	-- start from a clean slate
	pcall(function()
		if fs.isFile(path) then
			fs.removeFile(path)
		end
	end)

	-- a block record (keeps category/rule) and an allow record (omits them)
	local wroteBlock = Log.eventTo(dir, {
		source = "guard",
		tool = "Bash",
		shell = "bash",
		decision = "block",
		category = "destructive-git",
		rule = "git-push",
		cmd = "git push origin main",
	})
	local wroteAllow = Log.eventTo(dir, {
		source = "guard",
		tool = "Bash",
		shell = "bash",
		decision = "allow",
		cmd = "git status",
	})
	check("eventTo reports success", wroteBlock and wroteAllow, "a write returned false")

	local readOk, contents = pcall(fs.readFile, path)
	if not readOk or type(contents) ~= "string" then
		check("log file is written + readable", false, "could not read " .. path)
		return checks, fails
	end

	local lines: { string } = {}
	for line in string.gmatch(contents, "[^\n]+") do
		table.insert(lines, line)
	end
	check("two records appended", #lines == 2, "got " .. tostring(#lines) .. " line(s)")

	for i, line in lines do
		local okJson, rec = pcall(serde.decode, "json", line)
		if not okJson or type(rec) ~= "table" then
			check("line " .. i .. " parses as JSON", false, line)
		else
			local r = rec :: any
			check("line " .. i .. " stamped ts", r.ts ~= nil and r.ts ~= "", line)
			check("line " .. i .. " source=guard", r.source == "guard", tostring(r.source))
			check("line " .. i .. " has decision", r.decision ~= nil, line)
		end
	end

	if #lines == 2 then
		local _, first = pcall(serde.decode, "json", lines[1])
		local _, second = pcall(serde.decode, "json", lines[2])
		local f = first :: any
		local s = second :: any
		check(
			"block line carries rule",
			type(first) == "table" and f.rule == "git-push",
			tostring(f.rule)
		)
		check(
			"allow line omits category",
			type(second) == "table" and s.category == nil,
			"category leaked onto an allow record"
		)
	end

	-- best-effort cleanup; a leftover temp file must never fail the suite
	pcall(function()
		fs.removeFile(path)
		fs.removeDir(dir)
	end)

	return checks, fails
end
