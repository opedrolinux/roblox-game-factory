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
local gateSampleSpec = require("./gate_sample_spec")
local gateReachabilitySpec = require("./gate_reachability_spec")
-- Not a `_spec` module but a loader that EXERCISES the shipped T2.5 template: it slices the real
-- `templates/tier2/playtest.server.luau` off disk and runs its verdict derivation under stubs. Wired
-- in here on purpose — its fail-closed drift guards only fire if something runs them, and a drift
-- guard nobody runs is the rot it was built to catch.
local t25HarnessLoader = require("./t25_harness_loader")
local t25ForgerySpec = require("./t25_forgery_spec")

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
runSpec("sample-removal gate", gateSampleSpec)
runSpec("reachability gate", gateReachabilitySpec)
runSpec("t2.5 harness (the REAL template, loaded)", t25HarnessLoader.spec)
runSpec("t2.5 channel forgery (the REAL template)", t25ForgerySpec.spec)

if #failures > 0 then
	print(string.format("FAIL - %d of %d checks failed:", #failures, checks))
	for _, f in failures do
		print("  - " .. f)
	end
	process.exit(1)
end

print(string.format("PASS - all %d build-pipeline helper checks behaved as specified.", checks))
process.exit(0)
