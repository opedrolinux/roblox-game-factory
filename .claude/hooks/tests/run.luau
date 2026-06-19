--!strict
-- run.luau — drives the fence corpus through the pure Fence matcher and reports.
-- Exits non-zero on ANY mismatch, so it slots into the gauntlet / CI like every other
-- test in the project. Run:  lune run .claude/hooks/tests/run.luau
--
--   * a `block` row fails if the command is NOT fenced (a bypass — the dangerous case)
--   * an `allow` row fails if the command IS fenced (a false positive — breaks real work)
--   * a `cat` mismatch fails even when blocked, so a rule can't fire for the wrong reason

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Fence = require("../lib/Fence")
local corpus = require("./corpus")
local logSpec = require("./log_spec")

type Fail = { kind: string, detail: string, note: string }

local fails: { Fail } = {}
local blockChecked, allowChecked, pathChecked = 0, 0, 0

local function red(s: string): string
	return stdio.color("red") .. s .. stdio.color("reset")
end
local function green(s: string): string
	return stdio.color("green") .. s .. stdio.color("reset")
end

-- ── command rows ─────────────────────────────────────────────────────────────
for _, c in corpus.commands do
	local decision = Fence.evaluateCommand(c.cmd, c.shell, c.root)
	if c.block then
		blockChecked += 1
		if not decision.blocked then
			table.insert(fails, {
				kind = "BYPASS (should block, allowed)",
				detail = string.format("[%s] %s", c.shell, c.cmd),
				note = c.note,
			})
		elseif c.cat ~= nil and decision.category ~= c.cat then
			table.insert(fails, {
				kind = "WRONG CATEGORY",
				detail = string.format(
					"[%s] %s — got %s, want %s",
					c.shell,
					c.cmd,
					tostring(decision.category),
					c.cat
				),
				note = c.note,
			})
		end
	else
		allowChecked += 1
		if decision.blocked then
			table.insert(fails, {
				kind = "FALSE POSITIVE (should allow, blocked)",
				detail = string.format(
					"[%s] %s — blocked by %s/%s",
					c.shell,
					c.cmd,
					tostring(decision.category),
					tostring(decision.ruleId)
				),
				note = c.note,
			})
		end
	end
end

-- ── path rows ────────────────────────────────────────────────────────────────
for _, p in corpus.paths do
	pathChecked += 1
	local decision = Fence.evaluatePath(p.path, p.root)
	if decision.blocked ~= p.block then
		table.insert(fails, {
			kind = if p.block
				then "PATH BYPASS (should block)"
				else "PATH FALSE POSITIVE (should allow)",
			detail = string.format("%s (root=%s)", p.path, p.root),
			note = p.note,
		})
	end
end

-- ── run/audit log shape (the durable trace the hooks + B4 pipeline write) ──────
local logChecks, logFails = logSpec()
for _, lf in logFails do
	table.insert(fails, { kind = "LOG SHAPE", detail = lf.detail, note = lf.note })
end

-- ── report ───────────────────────────────────────────────────────────────────
local total = blockChecked + allowChecked + pathChecked
print(
	string.format(
		"fence corpus: %d cases (%d block, %d allow, %d path)",
		total,
		blockChecked,
		allowChecked,
		pathChecked
	)
)
print(string.format("run/audit log: %d shape checks", logChecks))

if #fails == 0 then
	print(
		green(
			string.format(
				"PASS — %d corpus cases + %d log checks all behaved as specified.",
				total,
				logChecks
			)
		)
	)
	process.exit(0)
else
	print(red(string.format("FAIL — %d/%d checks wrong:", #fails, total + logChecks)))
	for _, f in fails do
		print(red("  ✗ " .. f.kind))
		print("      " .. f.detail)
		print("      note: " .. f.note)
	end
	process.exit(1)
end
