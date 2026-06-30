--!strict
-- gate_sample_spec.luau — corpus for the sample-removal finalization gate's pure classifier.
-- The load-bearing case: sample STILL wired + real features exist -> remove-sample (the mint must not
-- ship). A fresh scaffold (sample only) and a sample-free game both pass. Driven by tests/run.luau.

local gateSample = require("../gate-sample")

return function(): (number, { string })
	local failures: { string } = {}
	local checks = 0
	local function expect(input: gateSample.Input, want: gateSample.Action, note: string)
		checks += 1
		local got = gateSample.classify(input).action
		if got ~= want then
			table.insert(failures, string.format("%s: classify -> %s, want %s", note, got, want))
		end
	end

	-- THE failure: a real game still shipping the deletable mint.
	expect(
		{ sampleWired = true, hasRealFeatures = true, evidence = {} },
		"remove-sample",
		"sample wired + real features -> must remove (the mint class)"
	)
	-- A freshly-scaffolded game legitimately still carries the sample (green-from-start).
	expect(
		{ sampleWired = true, hasRealFeatures = false, evidence = {} },
		"ok",
		"sample only, no real features yet -> fine (a fresh scaffold)"
	)
	-- A real game that correctly removed the sample.
	expect(
		{ sampleWired = false, hasRealFeatures = true, evidence = {} },
		"ok",
		"sample removed + real features -> ok"
	)
	-- Degenerate: nothing present.
	expect(
		{ sampleWired = false, hasRealFeatures = false, evidence = {} },
		"ok",
		"neither sample nor real features -> ok"
	)

	return checks, failures
end
