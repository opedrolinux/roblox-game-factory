--!strict
-- gauntlet.luau — run the Tier-1 gauntlet for a game directory and emit a structured result.
--
--   lune run .claude/skills/lib/gauntlet.luau <gameDir>
--
-- Runs, with cwd = <gameDir>: `stylua --check .` · `selene src` · `rojo build` · `lune run
-- tests/run.luau` — the same four checks a human runs by hand — and prints ONE JSON line:
--   {"ok":bool,"gameDir":"...","stages":[{"name":"stylua","ok":bool,"output":"..."},...]}
-- Exit 0 iff every stage passed. The pipeline's builder / test-gate agents call this to get a
-- single deterministic verdict instead of each re-deriving the gauntlet.
--
-- NOTE: this helper invokes the toolchain via process.exec INSIDE Lune; those subprocesses are
-- the fixed, safe toolchain and do not pass through the PreToolUse fence (which only sees an
-- agent's own tool calls). The fence governs agents' direct commands, not this helper's internals.

local process = require("@lune/process")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")

type Stage = { name: string, ok: boolean, output: string }

-- Lune passes everything after the script path as args (incl. a literal "--"); take the first real one.
local function pickGameDir(): string?
	for _, arg in process.args do
		if arg ~= "--" and arg ~= "" then
			return arg
		end
	end
	return nil
end

local gameDir = pickGameDir()
if gameDir == nil then
	stdio.ewrite("usage: lune run .claude/skills/lib/gauntlet.luau <gameDir>\n")
	process.exit(1)
end
local dir = gameDir :: string
if not fs.isDir(dir) then
	stdio.ewrite(string.format("gauntlet: %q is not a directory\n", dir))
	process.exit(1)
end

-- Each stage fails CLOSED: a tool that won't spawn is a failed stage, not a skipped one — the
-- gauntlet's job is to certify green, so "couldn't check" must not read as "passed".
local function run(name: string, program: string, args: { string }): Stage
	local ok, result = pcall(function()
		return process.exec(program, args, { cwd = dir })
	end)
	if not ok then
		return {
			name = name,
			ok = false,
			output = "could not run " .. program .. ": " .. tostring(result),
		}
	end
	local r = result :: any
	local out = (r.stdout or "") .. (r.stderr or "")
	return { name = name, ok = r.ok, output = out }
end

-- The Tier-1 test summary run.luau prints as its FINAL line: {"passed":N,"failed":M,"total":T}.
-- Find the LAST such JSON object in the captured output (test names / WARN lines precede it).
local function parseSummary(out: string): { passed: number, failed: number, total: number }?
	local found: any = nil
	for line in string.gmatch(out, "[^\r\n]+") do
		local ok, decoded = pcall(serde.decode, "json", line)
		if
			ok
			and type(decoded) == "table"
			and type((decoded :: any).passed) == "number"
			and type((decoded :: any).failed) == "number"
			and type((decoded :: any).total) == "number"
		then
			found = decoded
		end
	end
	return found
end

-- The lune stage needs MORE than exit 0. A spec that aborts the Lune process (e.g. a stray
-- main-thread yield against a yielding store, which makes the scheduler drain and EXIT 0) can exit
-- BEFORE run.luau prints its summary — masking every failure after it. So the lune stage is green
-- ONLY IF the runner exits 0 AND emits a real summary with failed == 0 AND total > 0. A missing
-- summary (aborted/yielded mid-run) or any failure fails the stage. (This hole was found when an
-- offline.spec race test yielded the main thread and the gauntlet wrongly read ok:true.)
local function runLune(): Stage
	local base = run("lune", "lune", { "run", "tests/run.luau" })
	if not base.ok then
		return base -- non-zero exit already fails the stage
	end
	local summary = parseSummary(base.output)
	if summary == nil then
		return {
			name = "lune",
			ok = false,
			output = base.output
				.. "\n[gauntlet] lune exited 0 but emitted NO test summary — the runner aborted/yielded "
				.. "mid-run (a stray main-thread yield against a yielding store exits Lune 0 and masks "
				.. "failures). Treating the lune stage as FAILED.",
		}
	end
	local s = summary :: { passed: number, failed: number, total: number }
	if s.failed > 0 or s.total <= 0 then
		return { name = "lune", ok = false, output = base.output }
	end
	return { name = "lune", ok = true, output = base.output }
end

local buildOut = ".gauntlet-build.rbxlx"
local stages: { Stage } = {
	run("stylua", "stylua", { "--check", "." }),
	run("selene", "selene", { "src" }),
	run("rojo", "rojo", { "build", "default.project.json", "--output", buildOut }),
	runLune(),
}

-- Clean the rojo build artifact (best-effort; never fail the gauntlet over it).
pcall(function()
	fs.removeFile(dir .. "/" .. buildOut)
end)

local allOk = true
for _, s in stages do
	if not s.ok then
		allOk = false
	end
end

print(serde.encode("json", { ok = allOk, gameDir = dir, stages = stages }))
process.exit(if allOk then 0 else 1)
