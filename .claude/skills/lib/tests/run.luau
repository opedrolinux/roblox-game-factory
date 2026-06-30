--!strict
-- run.luau — gauntlet entry for the build-pipeline Lune helpers' self-tests.
--
--   lune run .claude/skills/lib/tests/run.luau
--
-- Exits non-zero on any failure, so it joins the foundry's verification. (gauntlet.luau is verified
-- by running it against a real game; merge.luau is pure and corpus-tested here.)

local process = require("@lune/process")
local mergeSpec = require("./merge_spec")
local tierLadderSpec = require("./tier_ladder_spec")

local checks = 0
local failures: { string } = {}

local function runSpec(name: string, spec: () -> (number, { string }))
	local specChecks, specFailures = spec()
	checks += specChecks
	print(string.format("%s: %d checks", name, specChecks))
	for _, f in specFailures do
		table.insert(failures, name .. ": " .. f)
	end
end

runSpec("merge classifier", mergeSpec)
runSpec("verification ladder", tierLadderSpec)

if #failures > 0 then
	print(string.format("FAIL - %d of %d checks failed:", #failures, checks))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
end

print(string.format("PASS - all %d build-pipeline helper checks behaved as specified.", checks))
process.exit(0)
