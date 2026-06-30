--!strict
-- tier-ladder.luau — the verification ladder: turn a set of rung results into ONE honest status.
--
-- This closes the "conflation" the factory shipped a non-booting game on (VERIFICATION-LADDER.md §1):
-- every readiness signal bottomed out at one bit (gauntlet `ok`), so the loop read "ready-for-human"
-- straight off Tier-1 (Lune-green) and skipped the in-engine truth. This module makes the status an
-- ORDERED LADDER instead of a boolean: a game's status is the HIGHEST CONTIGUOUS GREEN RUNG, never a
-- bare "ready", and the loop may not escalate to the human until the last AUTOMATABLE rung is green or
-- explicitly blocked-on-human (the "exhaust-automation-first" rule, §4.1).
--
-- Pure policy, unit-tested like merge.luau. The side effects it informs — the handoff note, the
-- portfolio label, the FF decision — live in the orchestrator; this module only decides the verdict.
--
-- The ladder (VERIFICATION-LADDER.md §2):
--   T0   static     stylua · selene · rojo build          compiles to a place
--   T0.5 require     gate-require.luau                     every require resolves in the DataModel
--   T1   lune        tests/run.luau + integration          logic correct under the file loader
--   T2   engine      in-engine smoke (Studio/Open Cloud)   it BOOTS; services Start; loop on the wire
--   T3   human       playtest                              fun, feel, presentation, input, world
--
-- A higher rung's result is meaningless if a lower one is red (you cannot trust T1 logic on a tree that
-- does not compile), so "reached" is CONTIGUOUS from the bottom: the chain stops at the first non-green
-- rung. T0.5 (require) is the rung that would have caught the cross-service boot bug with no Roblox.

local M = {}

-- A rung's outcome. "blocked-on-human" is distinct from "red"/"unrun": it means the rung is not red,
-- it simply cannot be RUN by the loop right now (e.g. T2 needs Studio/Open Cloud, which is a human
-- action) — so it is allowed to not block escalation, but only when honestly labeled as such.
export type Status = "green" | "red" | "unrun" | "blocked-on-human"
export type Results = { [string]: Status }

-- Ordered, bottom-up. `automatable` marks the rungs the loop is REQUIRED to exhaust before it may
-- escalate to the human. T2 is automatable IN PRINCIPLE but only once the engine lane is provisioned
-- (Studio MCP live or an Open Cloud carve-out); until then it is recorded blocked-on-human (§4.1).
export type Rung = { id: string, label: string, automatable: boolean }

local RUNGS: { Rung } = {
	{ id = "T0", label = "static (stylua · selene · rojo build)", automatable = true },
	{ id = "T0.5", label = "require-resolution (gate-require)", automatable = true },
	{ id = "T1", label = "Lune logic (unit + integration)", automatable = true },
	{ id = "T2", label = "in-engine smoke (Studio/Open Cloud)", automatable = true },
	{ id = "T3", label = "human playtest", automatable = false },
}
M.RUNGS = RUNGS

-- 1-based position of a rung id in the ladder, or 0 if unknown.
function M.rungIndex(id: string): number
	for index, rung in RUNGS do
		if rung.id == id then
			return index
		end
	end
	return 0
end

-- The highest CONTIGUOUS green rung id, walking bottom-up and stopping at the first non-green rung.
-- "none" if even T0 is not green. This is the game's true status — never a bare "ready".
function M.highestTierReached(results: Results): string
	local highest = "none"
	for _, rung in RUNGS do
		if results[rung.id] == "green" then
			highest = rung.id
		else
			break
		end
	end
	return highest
end

export type Handoff = {
	ready: boolean, -- may the loop escalate to the human gate (T3)?
	highestGreen: string, -- highest contiguous green rung ("none" | "T0" | "T0.5" | "T1" | "T2" | "T3")
	lastAutomatable: string, -- the last rung the loop must exhaust before escalating (T1 or T2)
	label: string, -- the honest funnel/status label (carries the T2 caveat when relevant)
	blockedBy: string?, -- the rung that REFUSES handoff (nil when ready)
	reason: string,
}

-- The exhaust-automation-first guard (VERIFICATION-LADDER.md §4.1).
--
-- `engineLaneAvailable` = is the T2 in-engine smoke runnable right now (Studio MCP live / Open Cloud
-- carve-out provisioned)? When false, T2 is the human's lane: T1 is the last automatable rung and T2 is
-- recorded blocked-on-human — escalation is allowed but the label MUST say T2 is unverified.
--
-- The rule: the loop must NOT emit ready-for-human until every automatable rung up to lastAutomatable
-- is green (T2 may instead be blocked-on-human when the lane is unavailable). If a lower automatable
-- rung is red or un-run, the loop is in-progress and REFUSES handoff — it cannot reach the human while
-- a cheaper automatable check is still red/un-run (the exact failure the conflation caused).
function M.handoff(results: Results, engineLaneAvailable: boolean): Handoff
	local highestGreen = M.highestTierReached(results)
	local lastAutomatable = if engineLaneAvailable then "T2" else "T1"
	local lastIdx = M.rungIndex(lastAutomatable)

	-- Walk the automatable rungs bottom-up; the first one that is neither green nor (legitimately)
	-- blocked-on-human refuses handoff.
	for _, rung in RUNGS do
		if M.rungIndex(rung.id) > lastIdx then
			break
		end
		local status = results[rung.id]
		if status == "green" then
			continue
		end
		-- T2 is allowed to be blocked-on-human ONLY when the engine lane is unavailable (then it is not
		-- in the must-exhaust set anyway, lastAutomatable == T1, so this loop never reaches T2). Any
		-- other non-green automatable rung — red or un-run — blocks handoff.
		return {
			ready = false,
			highestGreen = highestGreen,
			lastAutomatable = lastAutomatable,
			label = string.format("in-progress (%s %s), NOT ready", rung.id, status or "unrun"),
			blockedBy = rung.id,
			reason = string.format(
				"%s (%s) is %s; the loop refuses to escalate to a human while an automatable rung "
					.. "is red/un-run — exhaust automation first (VERIFICATION-LADDER.md §4.1)",
				rung.id,
				rung.label,
				status or "unrun"
			),
		}
	end

	-- Every automatable rung up to lastAutomatable is green. Escalation is allowed; the label states
	-- the honest highest tier. T2-green earns the engine-smoked label HOWEVER it was produced — the
	-- automated lane OR a human Studio run fed back through smoke-gate ingest (in which case the lane is
	-- still "unavailable" but T2 is genuinely verified). So the label keys off the T2 RESULT, not the
	-- lane flag — otherwise a human-verified boot would be under-claimed as "NOT engine-booted".
	if results["T2"] == "green" then
		return {
			ready = true,
			highestGreen = highestGreen,
			lastAutomatable = lastAutomatable,
			label = "engine-smoked-T2 — ready for human playtest (T3)",
			blockedBy = nil,
			reason = "T0..T2 green; in-engine smoke passed; the only rung left is the human playtest",
		}
	end
	return {
		ready = true,
		highestGreen = highestGreen,
		lastAutomatable = lastAutomatable,
		label = "verified-local-T1 (logic only, NOT engine-booted) — T2 blocked-on-human: engine lane "
			.. "not connected; awaiting-human-gate-T3",
		blockedBy = nil,
		reason = "T0..T1 green and the engine lane is unavailable, so T2 is the human's to run (open the "
			.. "place in Studio with the MCP plugin / provision Open Cloud); escalation is honest only "
			.. "with the T2-unverified label",
	}
end

-- Convenience: map a gauntlet.luau result ({ ok, stages: [{ name, ok }] }) to T0/T0.5/T1 rung statuses.
-- stylua+selene+rojo => T0 (all three must be green); the "require" stage => T0.5; "lune" => T1. A stage
-- the gauntlet did not emit reads as "unrun" (fail-closed: absent is never green). T2/T3 are not part of
-- the gauntlet — the caller layers them in from the smoke gate / the human.
function M.fromGauntlet(
	gauntlet: { ok: boolean, stages: { { name: string, ok: boolean } } }
): Results
	local byName: { [string]: boolean } = {}
	local seen: { [string]: boolean } = {}
	for _, stage in gauntlet.stages do
		if seen[stage.name] then
			-- Duplicate stage name (the real gauntlet never emits one, but stay fail-closed on malformed
			-- input): a red occurrence wins, so a red can never be laundered green by a later duplicate.
			byName[stage.name] = byName[stage.name] and stage.ok
		else
			byName[stage.name] = stage.ok
			seen[stage.name] = true
		end
	end
	local function statusOf(names: { string }): Status
		local allSeen = true
		local allOk = true
		for _, n in names do
			if not seen[n] then
				allSeen = false
			elseif not byName[n] then
				allOk = false
			end
		end
		if not allSeen then
			return "unrun"
		end
		return if allOk then "green" else "red"
	end
	return {
		["T0"] = statusOf({ "stylua", "selene", "rojo" }),
		["T0.5"] = statusOf({ "require" }),
		["T1"] = statusOf({ "lune" }),
	}
end

return M
