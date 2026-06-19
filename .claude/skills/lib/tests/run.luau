--!strict
-- run.luau — gauntlet entry for the build-pipeline Lune helpers' self-tests.
--
--   lune run .claude/skills/lib/tests/run.luau
--
-- Exits non-zero on any failure, so it joins the foundry's verification. (gauntlet.luau is verified
-- by running it against a real game; merge.luau is pure and corpus-tested here.)

local process = require("@lune/process")
local mergeSpec = require("./merge_spec")

local checks, failures = mergeSpec()

print(string.format("merge classifier: %d checks", checks))

if #failures > 0 then
	print(string.format("FAIL - %d of %d checks failed:", #failures, checks))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
end

print(string.format("PASS - all %d merge-classifier checks behaved as specified.", checks))
process.exit(0)
