--!strict
-- core/tests/run.luau
-- The Tier-1 runner. Run: `lune run core/tests/run.luau` — from ANY cwd (repo root is the
-- gauntlet's choice, but relative requires are script-relative so cwd is moot — D4).
-- Uses an EXPLICIT, lexically-sorted `specs` list of relative requires (no fs.readDir).
-- Each require is pcall-guarded so a require-time error becomes a recorded failure and the run
-- still prints exactly ONE JSON line + exits nonzero. See docs/CORE-DESIGN.md §7.4.
local process = require("@lune/process")
local stdio = require("@lune/stdio")

-- Keep stdout pristine: the runner must print EXACTLY ONE JSON line. Modules' data-loss-risk
-- diagnostics are routed through an INJECTED logger (DataService takes `logWarn`), and the test
-- mocks pass a stderr writer (Mocks.logWarn) — so module diagnostics never pollute the JSON line.
-- (selene forbids reassigning the `warn` global, so injection is the clean path; verified on
-- lune 0.10.4: @lune/stdio.ewrite is stderr, @lune/process has no stdout/stderr field.)
local testkit = require("./lib/testkit") -- script-relative; resolves from any cwd

-- EXPLICIT, LEXICALLY-ORDERED spec list (no fs.readDir). Each entry is a script-relative path.
-- Adding a feature appends one line here; keep the list sorted so the JSON summary is byte-stable.
local SPEC_PATHS = {
	"./unit/analytics.spec",
	"./unit/clock.spec",
	"./unit/collection.spec",
	"./unit/daily.spec",
	"./unit/data.spec",
	"./unit/economy_race.spec",
	"./unit/framework.spec",
	"./unit/migration.spec",
	"./unit/net.spec",
	"./unit/sample.spec",
	"./unit/shop.spec",
	"./unit/validation.spec",
	"./unit/selene_guard.spec",
}
table.sort(SPEC_PATHS) -- belt-and-suspenders determinism (concern 10)

for _, path in SPEC_PATHS do
	-- pcall the require so a require-time error becomes a recorded failure, not an aborted run.
	local ok, err = pcall(require, path)
	if not ok then
		testkit.recordLoadFailure(path, tostring(err))
	end
end

local summary = testkit.run() -- runs every registered describe/it; returns the counts

-- If there were failures, emit the detail to STDERR so the one stdout line stays clean JSON.
if summary.failed > 0 then
	for _, failure in summary.failures do
		stdio.ewrite(`FAIL: {failure}\n`)
	end
end

-- Exactly ONE line to stdout, on success AND on failure:
print(
	string.format(
		'{"passed":%d,"failed":%d,"total":%d}',
		summary.passed,
		summary.failed,
		summary.total
	)
)

process.exit(summary.failed == 0 and 0 or 1) -- nonzero exit fails the gauntlet
