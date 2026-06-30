--!strict
-- gate-sample.luau — the build-game SAMPLE-REMOVAL finalization gate.
--
-- The deletable `sample` scaffold (services/sample, controllers/sample, the [SAMPLE] Net action + the
-- bootstrap registrations) is a green-from-start smoke-test of the wiring — but it ships a
-- CLIENT-CALLABLE MINT (`SampleAction` credited a client `{amount}` straight to a currency). It MUST be
-- removed once real features replace it. The build-game pipeline once forgot to, and the mint shipped
-- PAST every gate: the per-feature harness omitted SampleService, so the gauntlet was green while the
-- live `init.server` registry still shipped the mint — a gate<->bootstrap PARITY divergence (see
-- docs/LEARNINGS.md §5). This gate closes that class: it FAILS when the sample scaffold is still present
-- in a game that ALSO has real feature services. A FRESH scaffold (sample only, green-from-start) passes;
-- a sample-free game passes.
--
-- Run it as a FINALIZATION step before handoff, NOT as a gauntlet stage — a freshly-scaffolded game
-- legitimately still carries the sample (new-game keeps it; build-game removes it at the end).
--
--   GATE_SAMPLE_CLI=1 lune run .claude/skills/lib/gate-sample.luau <gameDir>   (exit 1 on remove-sample)
--
-- Pure `classify` is corpus-tested; `detect` does the filesystem inspection.

local fs = require("@lune/fs")
local process = require("@lune/process")

local M = {}

export type Action = "ok" | "remove-sample"
export type Input = { hasRealFeatures: boolean, sampleWired: boolean, evidence: { string } }
export type Decision = { action: Action, reason: string, evidence: { string } }

-- Pure policy: a still-wired sample is fine UNTIL real features exist; after that it must be removed.
function M.classify(input: Input): Decision
	if input.sampleWired and input.hasRealFeatures then
		return {
			action = "remove-sample",
			reason = "the deletable `sample` scaffold (a client-callable mint) is STILL present in a game "
				.. "that has real feature services — remove it before handoff or it ships the mint",
			evidence = input.evidence,
		}
	end
	return {
		action = "ok",
		reason = if input.sampleWired
			then "only the sample scaffold is present (a fresh scaffold) — fine until real features exist"
			else "no sample scaffold remains",
		evidence = input.evidence,
	}
end

local function fileHasSampleTag(path: string): boolean
	if not fs.isFile(path) then
		return false
	end
	local ok, content = pcall(fs.readFile, path)
	if not ok then
		return false
	end
	return string.find(content :: string, "%[SAMPLE%]") ~= nil
end

-- Inspect a game directory: are there real feature services, and is any trace of the sample scaffold
-- still present (the dir, or a [SAMPLE]-tagged line in the bootstrap / Net registry)?
function M.detect(gameDir: string): Input
	local evidence: { string } = {}
	local sampleWired = false
	local hasRealFeatures = false

	local servicesDir = gameDir .. "/src/server/services"
	if fs.isDir(servicesDir) then
		for _, entry in fs.readDir(servicesDir) do
			if entry == "sample" then
				sampleWired = true
				table.insert(evidence, "src/server/services/sample/ exists")
			elseif fs.isDir(servicesDir .. "/" .. entry) then
				hasRealFeatures = true
			end
		end
	end

	if fs.isDir(gameDir .. "/src/client/controllers/sample") then
		sampleWired = true
		table.insert(evidence, "src/client/controllers/sample/ exists")
	end

	-- The scaffold tags every sample-specific line with `-- [SAMPLE]`, so a leftover registration in the
	-- live bootstrap / Net registry is detectable even if the service dir was partially removed.
	local taggedFiles = {
		"src/server/init.server.luau",
		"src/client/init.client.luau",
		"src/shared/Net.luau",
	}
	for _, rel in taggedFiles do
		if fileHasSampleTag(gameDir .. "/" .. rel) then
			sampleWired = true
			table.insert(evidence, rel .. " carries a [SAMPLE] marker")
		end
	end

	return { hasRealFeatures = hasRealFeatures, sampleWired = sampleWired, evidence = evidence }
end

-- CLI mode (so the build-game handoff step / a human can run it). Required-as-a-module callers (the test
-- runner) leave GATE_SAMPLE_CLI unset and just get M.
if process.env.GATE_SAMPLE_CLI == "1" then
	local serde = require("@lune/serde")
	local stdio = require("@lune/stdio")
	local gameDir: string? = nil
	for _, arg in process.args do
		if arg ~= "--" and arg ~= "" then
			gameDir = arg
			break
		end
	end
	if gameDir == nil or not fs.isDir(gameDir :: string) then
		stdio.ewrite(
			"usage: GATE_SAMPLE_CLI=1 lune run .claude/skills/lib/gate-sample.luau <gameDir>\n"
		)
		process.exit(1)
	end
	local input = M.detect(gameDir :: string)
	local decision = M.classify(input)
	print(serde.encode("json", {
		gameDir = gameDir,
		action = decision.action,
		reason = decision.reason,
		evidence = decision.evidence,
	}))
	if decision.action == "remove-sample" then
		stdio.ewrite(
			"[gate-sample] FAIL: "
				.. decision.reason
				.. "\n  evidence: "
				.. table.concat(decision.evidence, "; ")
				.. "\n  remove: src/server/services/sample, src/client/controllers/sample, the [SAMPLE] Net "
				.. "action + bootstrap registrations, and tests/unit/sample.spec.luau.\n"
		)
		process.exit(1)
	end
	stdio.ewrite("[gate-sample] OK: " .. decision.reason .. "\n")
	process.exit(0)
end

return M
