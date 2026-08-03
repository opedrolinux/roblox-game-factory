--!strict
-- REVIEW FALSIFIER: is the T2.5 game-contact instrument still forgeable?
--
-- Checker 1's N1: `read = function() Harness.countBaseParts(); return myLocal end` mints a `world`
-- ledger hit as a SIDE EFFECT while returning an unrelated local, so the harness credited game
-- contact the returned value never made. Runs against the REAL template through the loader.
--
-- NON-VACUOUS BY CONSTRUCTION: every assertion reads the ATTACK PHASE'S OWN entry out of the
-- structured evidence. A run that emits no sentinel, or a roster in which the attack phase is
-- missing, FAILS here rather than passing quietly — the exact trap this session exists to close.

local loader = require("./t25_harness_loader")

local spec = {}

local checks = 0
local failures: { string } = {}
local function check(name: string, cond: boolean, detail: string?)
	checks += 1
	if not cond then
		table.insert(failures, name .. " -- " .. (detail or ""))
	end
end

local function run(): (number, { string })
	local BLIND =
		{ { claim = "anything only a real client could show", becauseLimit = "hasLocalPlayer" } }
	-- The template is honestly RED out of the box (BOOTSTRAP_MIRROR = nil, by design), so a control that
	-- expects a green RUN must fork it the way new-game does.
	local FORK = { loader.filledBootstrapMirror({ "SampleService" }) }

	-- A healthy, genuinely world-touching phase, so the roster can clear MIN_SPEC_GATING_PHASES and the
	-- attack phase is judged on its own merits rather than on a roster blocker.
	local function healthy(sandbox: any, name: string): any
		local tag = name .. "-marker"
		local subject = name .. "-subject"
		return {
			name = name,
			gating = true,
			minSubjects = 1,
			blindTo = BLIND,
			body = function(probe: any): ()
				probe:subjects({ subject }, "stub subject")
				probe:delta(
					name .. " moves",
					sandbox.Harness.readWorldCount(tag, function(inst: any): boolean
						return inst.Name == tag
					end),
					function(): ()
						local part = sandbox.env.Instance.new("Part")
						part.Name = tag
						part.Parent = sandbox.env.workspace
					end,
					{ direction = "up", subject = subject }
				)
			end,
		}
	end

	local function phaseNamed(evidence: any, name: string): any
		if evidence == nil or evidence.phases == nil then
			return nil
		end
		for _, ph in evidence.phases do
			if ph.name == name then
				return ph
			end
		end
		return nil
	end

	-- Run a roster of [attack] + two healthy phases and return the attack phase's evidence entry.
	local function runAttack(name: string, makeAttack: (any) -> any): (any, any)
		local sandbox = loader.load({ substitutions = FORK })
		sandbox.Harness.phase(makeAttack(sandbox))
		sandbox.Harness.phase(healthy(sandbox, "healthy-a"))
		sandbox.Harness.phase(healthy(sandbox, "healthy-b"))
		sandbox.Harness.finish({ name, "healthy-a", "healthy-b" })
		local evidence = sandbox:evidence()
		return evidence, phaseNamed(evidence, name)
	end

	-- ── ATTACK A — the forged channel ────────────────────────────────────────────────────────────────
	do
		local evidence, ph = runAttack("forged-world-channel", function(sandbox: any): any
			local n = 0
			return {
				name = "forged-world-channel",
				gating = true,
				minSubjects = 1,
				blindTo = BLIND,
				body = function(probe: any): ()
					probe:subjects({ "forged" }, "forged subjects")
					probe:delta("a local pretending to be the world", function(): any
						sandbox.Harness.countBaseParts() -- side effect ONLY
						return n
					end, function(): ()
						n += 1
					end, { direction = "up", subject = "forged" })
				end,
			}
		end)
		check(
			"A: the run emitted a sentinel at all (else every check below is vacuous)",
			evidence ~= nil
		)
		check("A: the attack phase is present in the evidence", ph ~= nil)
		if ph ~= nil then
			check(
				"A: a side-effect call does NOT earn the phase a pass",
				ph.ok ~= true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
		end
	end

	-- ── ATTACK B — the hand-rolled reader that merely DECLARES a channel ─────────────────────────────
	do
		local evidence, ph = runAttack("hand-rolled-channel-claim", function(_sandbox: any): any
			local n = 0
			return {
				name = "hand-rolled-channel-claim",
				gating = true,
				minSubjects = 1,
				blindTo = BLIND,
				body = function(probe: any): ()
					probe:subjects({ "claimed" }, "claimed subjects")
					probe:delta("a reader that just says it is the world", {
						channel = "world",
						what = "a claim",
						read = function(): any
							return n
						end,
					}, function(): ()
						n += 1
					end, { direction = "up", subject = "claimed" })
				end,
			}
		end)
		check("B: the run emitted a sentinel at all", evidence ~= nil)
		check("B: the attack phase is present in the evidence", ph ~= nil)
		if ph ~= nil then
			check(
				"B: an author-built reader cannot claim `world`",
				ph.ok ~= true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
		end
	end

	-- ── CONTROL — the shipped minted reader must STILL work ──────────────────────────────────────────
	-- Without this the two results above would be satisfied by a blanket refusal, which is a different
	-- broken gate rather than a fixed one.
	do
		local sandbox = loader.load({ substitutions = FORK })
		sandbox.Harness.phase(healthy(sandbox, "minted-a"))
		sandbox.Harness.phase(healthy(sandbox, "minted-b"))
		sandbox.Harness.phase(healthy(sandbox, "minted-c"))
		sandbox.Harness.finish({ "minted-a", "minted-b", "minted-c" })
		local evidence = sandbox:evidence()
		local ph = phaseNamed(evidence, "minted-a")
		check("CONTROL: the run emitted a sentinel at all", evidence ~= nil)
		check("CONTROL: the minted phase is present", ph ~= nil)
		if ph ~= nil then
			check(
				"CONTROL: a genuine minted world read still PASSES",
				ph.ok == true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
		end
		if evidence ~= nil then
			check(
				"CONTROL: the whole run is green",
				evidence.verdict == "green",
				"verdict=" .. tostring(evidence.verdict)
			)
		end
	end

	return checks, failures
end

function spec.spec(): (number, { string })
	return run()
end

return spec
