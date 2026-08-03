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

-- Renders a channel tally for a FAILURE message only. Kept tiny and total (nil-safe) because a
-- detail string that itself throws would turn a readable red into a stack trace.
local function shortish(tally: any): string
	if type(tally) ~= "table" then
		return tostring(tally)
	end
	local parts: { string } = {}
	for k, v in tally do
		table.insert(parts, tostring(k) .. "=" .. tostring(v))
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function run(): (number, { string })
	local BLIND =
		{ { claim = "anything only a real client could show", becauseLimit = "hasLocalPlayer" } }
	-- The template is honestly RED out of the box (BOOTSTRAP_MIRROR = nil, by design), so a control that
	-- expects a green RUN must fork it the way new-game does.
	-- `relaxSelfParentRule` is here for attacks A/B/C, which are about the MINT and the per-subject
	-- channel rule, not about self-parenting -- and which cannot make the world move any other way
	-- in a sandbox with no booted game. Attack D below deliberately does NOT pass it.
	local FORK = { loader.filledBootstrapMirror({ "SampleService" }), loader.relaxSelfParentRule() }

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

	-- ── ATTACK C — THE LAUNDERED SUBJECT ─────────────────────────────────────────────────────────
	-- The channel rule used to be per-PHASE: `reached = channels.reply + channels.world`, evaluated
	-- once over the whole phase. So a phase that legitimately watched a rock respawn (a real `world`
	-- delta) satisfied the rule for EVERY save-only delta sitting beside it. That is the root pattern
	-- with an alibi: "HARDCODED_CAPACITY is still 50, the saved value is 60" passes, because a
	-- DIFFERENT subject in the same phase touched the game.
	--
	-- The saved-channel delta below is built the way the A2 attack actually hid: an UNMINTED closure
	-- that trips the save counter as a side effect and returns a local. The harness demotes it to
	-- `saved` (never promotes), which is exactly the classification this attack needs.
	local function launderingPhase(sandbox: any, giveCapacityItsOwnReader: boolean): any
		local n = 0
		local savedReader = sandbox.Harness.readSaved({ Name = "p1" }, "upgrades.capacity")
		local tag = "laundered-rock"
		return {
			name = "laundered-subject",
			gating = true,
			minSubjects = 1,
			blindTo = BLIND,
			body = function(probe: any): ()
				probe:subjects({ "rock-respawn", "capacity-upgrade" }, "two unrelated subjects")
				-- SUBJECT 1 — genuine game contact. This one is honest, and it is the alibi.
				probe:delta(
					"a rock respawns",
					sandbox.Harness.readWorldCount(tag, function(inst: any): boolean
						return inst.Name == tag
					end),
					function(): ()
						local part = sandbox.env.Instance.new("Part")
						part.Name = tag
						part.Parent = sandbox.env.workspace
					end,
					{ direction = "up", subject = "rock-respawn" }
				)
				-- SUBJECT 2 — the save file and nothing else. The defect.
				probe:delta("capacity is SAVED", function(): any
					savedReader.read() -- trips the save counter; the value returned is a local
					return n
				end, function(): ()
					n += 1
				end, { direction = "up", subject = "capacity-upgrade" })
				-- The CONTROL arm gives subject 2 its own paired game-contact reader, which is the
				-- fix an author is supposed to make. Without this arm, a blanket refusal of every
				-- multi-subject phase would score as a pass here — a different broken gate.
				if giveCapacityItsOwnReader then
					local tag2 = "capacity-effect"
					probe:delta(
						"and the capacity is APPLIED in the world",
						sandbox.Harness.readWorldCount(tag2, function(inst: any): boolean
							return inst.Name == tag2
						end),
						function(): ()
							local part = sandbox.env.Instance.new("Part")
							part.Name = tag2
							part.Parent = sandbox.env.workspace
						end,
						{ direction = "up", subject = "capacity-upgrade" }
					)
				end
			end,
		}
	end

	local function runLaundering(giveCapacityItsOwnReader: boolean): (any, any)
		local sandbox = loader.load({ substitutions = FORK })
		sandbox.Harness.phase(launderingPhase(sandbox, giveCapacityItsOwnReader))
		sandbox.Harness.phase(healthy(sandbox, "healthy-a"))
		sandbox.Harness.phase(healthy(sandbox, "healthy-b"))
		sandbox.Harness.finish({ "laundered-subject", "healthy-a", "healthy-b" })
		local evidence = sandbox:evidence()
		return evidence, phaseNamed(evidence, "laundered-subject")
	end

	do
		local evidence, ph = runLaundering(false)
		check("C: the run emitted a sentinel at all", evidence ~= nil)
		check("C: the laundering phase is present in the evidence", ph ~= nil)
		if ph ~= nil then
			-- The alibi must be REAL, or this fixture proves nothing: if the rock delta had not
			-- landed on `world`, the phase would go red on the old aggregate rule too and the
			-- per-subject rule would be untested.
			local perSubject = ph.subjectChannels
			local rock = if perSubject ~= nil then perSubject["rock-respawn"] else nil
			check(
				"C: the alibi subject genuinely reached the game (else the fixture is vacuous)",
				rock ~= nil and (rock.world or 0) > 0,
				"rock-respawn channels=" .. tostring(rock and rock.world)
			)
			local cap = if perSubject ~= nil then perSubject["capacity-upgrade"] else nil
			check(
				"C: the laundered subject is recorded as save-only (else the fixture is vacuous)",
				cap ~= nil and (cap.saved or 0) > 0 and (cap.world or 0) + (cap.reply or 0) == 0,
				"capacity-upgrade channels=" .. shortish(cap)
			)
			check(
				"C: a save-only subject is REFUSED even when another subject reached the game",
				ph.ok ~= true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
			check(
				"C: the refusal NAMES the laundered subject, not just the phase",
				ph.ok ~= true and string.find(tostring(ph.detail), "capacity%-upgrade") ~= nil,
				"detail=" .. tostring(ph.detail)
			)
		end
	end

	do
		local evidence, ph = runLaundering(true)
		check("C-CONTROL: the run emitted a sentinel at all", evidence ~= nil)
		check("C-CONTROL: the phase is present", ph ~= nil)
		if ph ~= nil then
			check(
				"C-CONTROL: giving the subject its OWN paired reader makes the phase pass",
				ph.ok == true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
		end
		if evidence ~= nil then
			check(
				"C-CONTROL: the whole run is green",
				evidence.verdict == "green",
				"verdict=" .. tostring(evidence.verdict)
			)
		end
	end

	-- ── ATTACK D — THE SELF-PARENTED SUBJECT ─────────────────────────────────────────────────────
	-- The template SHIPPED this shape as `example-delta`: make a Folder, then count the IntValues you
	-- parent into it. The reader is genuinely minted, the ledger is genuinely hit, the number
	-- genuinely moves -- and the whole thing is the harness measuring its own hand. It was the
	-- pattern being taught to every author who read the example.
	--
	-- This block runs on the UNRELAXED template (no `relaxSelfParentRule`), because it is the rule
	-- under test. The two arms differ ONLY in whether the act goes through a harness-owned action.
	local STRICT = { loader.filledBootstrapMirror({ "SampleService" }) }

	local function selfParentPhase(sandbox: any, driveThroughGame: boolean): any
		local tag = "self-parented-marker"
		return {
			name = "self-parented",
			gating = true,
			minSubjects = 1,
			blindTo = BLIND,
			body = function(probe: any): ()
				probe:subjects({ "own-hand" }, "an instance this phase makes itself")
				probe:delta(
					"a part this phase parents itself",
					sandbox.Harness.readWorldCount(tag, function(inst: any): boolean
						return inst.Name == tag
					end),
					function(): ()
						-- The ONLY difference between the two arms. `moveBody` is harness-owned, so
						-- the game is known to have been given a chance to react; parenting a Part
						-- is not.
						if driveThroughGame then
							-- An explicit position, because `spawnPoint()` requires exactly one
							-- SpawnLocation and this sandbox has no place file.
							local player = sandbox.Harness.freshPlayer("d")
							sandbox.Harness.embody(player, sandbox.env.Vector3.new(0, 5, 0))
							sandbox.Harness.moveBody(player, sandbox.env.Vector3.new(0, 6, 0))
						end
						local part = sandbox.env.Instance.new("Part")
						part.Name = tag
						part.Parent = sandbox.env.workspace
					end,
					{ direction = "up", subject = "own-hand" }
				)
			end,
		}
	end

	local function runSelfParent(driveThroughGame: boolean): (any, any)
		local sandbox = loader.load({ substitutions = STRICT })
		sandbox.Harness.phase(selfParentPhase(sandbox, driveThroughGame))
		-- The run itself will be red either way (one phase cannot clear MIN_SPEC_GATING_PHASES) and
		-- that is fine: every assertion below reads THIS PHASE'S OWN entry, never the verdict.
		sandbox.Harness.finish({ "self-parented" })
		local evidence = sandbox:evidence()
		return evidence, phaseNamed(evidence, "self-parented")
	end

	do
		local evidence, ph = runSelfParent(false)
		check("D: the run produced evidence at all", evidence ~= nil)
		check("D: the self-parented phase is present", ph ~= nil)
		if ph ~= nil then
			check(
				"D: a world delta whose act made no game action is REFUSED",
				ph.ok ~= true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
			check(
				"D: the refusal says WHY, naming the missing game action",
				string.find(tostring(ph.detail), "no invokeAs") ~= nil,
				"detail=" .. tostring(ph.detail)
			)
		end
	end

	do
		-- The positive control. Without it, a rule that refused every world delta outright would
		-- score as a pass above -- a different broken gate, not a fixed one.
		local _evidence, ph = runSelfParent(true)
		check("D-CONTROL: the phase is present", ph ~= nil)
		if ph ~= nil then
			check(
				"D-CONTROL: routing the act through a harness-owned action clears the rule",
				ph.ok == true,
				"ok=" .. tostring(ph.ok) .. " detail=" .. tostring(ph.detail)
			)
		end
	end

	return checks, failures
end

function spec.spec(): (number, { string })
	return run()
end

return spec
