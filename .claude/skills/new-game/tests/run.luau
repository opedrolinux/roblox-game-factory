--!strict
-- run.luau — gauntlet entry for the new-game scaffolder self-test.
--
--   lune run .claude/skills/new-game/tests/run.luau
--
-- Exits non-zero if any scaffolder check fails, so it can join the foundry's verification.

local process = require("@lune/process")
local scaffoldSpec = require("./scaffold_spec")

local checks, failures = scaffoldSpec()

print(string.format("new-game scaffolder: %d checks", checks))

if #failures > 0 then
	print(string.format("FAIL - %d of %d checks failed:", #failures, checks))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
end

print(string.format("PASS - all %d scaffolder checks behaved as specified.", checks))
process.exit(0)
