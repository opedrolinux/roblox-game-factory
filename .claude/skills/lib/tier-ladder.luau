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
--   T0   static      stylua · selene · rojo build          compiles to a place
--   T0.5 require     gate-require.luau                     every require resolves in the DataModel
--   T1   lune        tests/run.luau + gate-reachability    logic correct AND statically REACHABLE
--   T2   engine      in-engine smoke (Studio/Open Cloud)   it BOOTS; services Start; loop on the wire
--   T2.5 playtest    automated AI playtest (run-in-roblox) nothing merely BROKEN survives to the human
--   T2.7 studio      agent-driven LIVE Studio pass         the client wiring + how it actually LOOKS
--   T3   human       playtest                              fun, feel, presentation, input, world
--
-- T2.5 and T2.7 were admitted here (HANDOFF-2) once the machinery that produces their evidence landed.
-- They were deliberately NOT invented as a "T3" — an agent driving Studio is not a human playtest: it
-- cannot see fun, cannot contend two clients, and `game.JobId` is `""`, so cross-server exclusion is
-- untestable BY CONSTRUCTION. T3 stays reserved for the human (`automatable = false`).
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
	{
		id = "T1",
		label = "Lune logic (unit + integration) + static reachability (gate-reachability)",
		automatable = true,
	},
	{ id = "T2", label = "in-engine smoke (Studio/Open Cloud)", automatable = true },
	{ id = "T2.5", label = "automated AI playtest (edit-mode, run-in-roblox)", automatable = true },
	{ id = "T2.7", label = "agent-driven live Studio pass", automatable = true },
	{ id = "T3", label = "human playtest", automatable = false },
}
M.RUNGS = RUNGS

-- The rungs that need an ENGINE to produce evidence, in ladder order. Each has its OWN lane: T2/T2.5
-- ride run-in-roblox, T2.7 needs a live Studio session with the MCP bridge. A single boolean cannot
-- describe three lanes, which is why `handoff` takes a per-rung map (and still accepts the legacy
-- boolean — see `normalizeLanes`).
local ENGINE_RUNGS = { "T2", "T2.5", "T2.7" }
M.ENGINE_RUNGS = ENGINE_RUNGS

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
	highestGreen: string, -- highest contiguous green rung ("none" | "T0" | … | "T2.5" | "T2.7" | "T3")
	lastAutomatable: string, -- the last rung the loop must exhaust before escalating (T1 … T2.7)
	label: string, -- the honest funnel/status label (carries the T2 caveat when relevant)
	blockedBy: string?, -- the rung that REFUSES handoff (nil when ready)
	reason: string,
}

-- Which engine rungs are RUNNABLE right now. `true`/`false` is still accepted for the ~60 corpus cases
-- and every existing caller, and means EXACTLY what it always meant: "the T2 in-engine smoke lane is
-- provisioned". It does NOT imply the T2.5 or T2.7 lanes — a lane that was never declared is not
-- available (fail-closed: an undeclared lane must never turn an un-run rung into a handoff BLOCKER on a
-- machine that cannot run it, and must never be read as "that rung is fine").
export type Lanes = { [string]: boolean }

local function normalizeLanes(lanes: (boolean | Lanes)?): Lanes
	if type(lanes) == "table" then
		local out: Lanes = {}
		for _, id in ENGINE_RUNGS do
			out[id] = (lanes :: Lanes)[id] == true
		end
		return out
	end
	return { ["T2"] = lanes == true, ["T2.5"] = false, ["T2.7"] = false }
end

-- The exhaust-automation-first guard (VERIFICATION-LADDER.md §4.1).
--
-- The rule: the loop must NOT emit ready-for-human until every automatable rung up to lastAutomatable
-- is green (an engine rung may instead be blocked-on-human when ITS lane is unavailable). If a lower
-- automatable rung is red or un-run, the loop is in-progress and REFUSES handoff — it cannot reach the
-- human while a cheaper automatable check is still red/un-run (the exact failure the conflation caused).
--
-- HANDOFF-4 — A RED IS RED REGARDLESS OF THE RUNG BELOW IT. The recorded reds are swept FIRST, before
-- the contiguous walk. The bug this closes was real and shipped: tier-status.luau wrapped its T2.5
-- gating in `if t2 == "green"`, so with the engine lane down and T2 un-run, a RECORDED RED PLAYTEST WAS
-- SILENTLY IGNORED and handoff still returned ready. "We never got round to booting it" is not a reason
-- to stop believing the playtest that already told us it is broken.
function M.handoff(results: Results, lanes: (boolean | Lanes)?): Handoff
	local highestGreen = M.highestTierReached(results)
	local lane = normalizeLanes(lanes)
	local lastAutomatable = "T1"
	for _, id in ENGINE_RUNGS do
		if lane[id] then
			lastAutomatable = id
		end
	end

	local function refuse(rungId: string, status: Status?, why: string): Handoff
		return {
			ready = false,
			highestGreen = highestGreen,
			lastAutomatable = lastAutomatable,
			label = string.format("in-progress (%s %s), NOT ready", rungId, status or "unrun"),
			blockedBy = rungId,
			reason = string.format("%s (%s) %s", rungId, RUNGS[M.rungIndex(rungId)].label, why),
		}
	end

	-- The base rungs T0..T1 are ALWAYS runnable, so all three must be green to escalate. The first
	-- non-green one refuses handoff — this is where the conflation dies: a require-red (T0.5) or un-run
	-- T1 tree can never reach the human, no matter how green the rungs above it look.
	for _, id in { "T0", "T0.5", "T1" } do
		if results[id] ~= "green" then
			return refuse(
				id,
				results[id],
				"is red/un-run; exhaust automation before escalating to a human (VERIFICATION-LADDER.md §4.1)"
			)
		end
	end

	-- HANDOFF-4, first: a RECORDED failure on ANY engine rung is fatal regardless of the lane flags and
	-- regardless of whether a rung BELOW it was ever run. Swept before the walk so an un-run T2 can never
	-- shadow a red T2.5 the way the old tier-status bolt-on did.
	for _, id in ENGINE_RUNGS do
		if results[id] == "red" then
			return refuse(
				id,
				"red",
				"FAILED — a recorded engine failure is never relabeled 'ready', no matter which rung below "
					.. "it was or was not run"
			)
		end
	end

	-- Now walk the engine rungs bottom-up. Each is: green -> keep climbing; un-run with ITS lane up ->
	-- an un-exhausted automatable rung, refuse; un-run with its lane down -> the human's to run, so
	-- escalate with a label that names EXACTLY what is still unverified. `blocked-on-human` recorded on a
	-- rung whose lane IS up is a contradiction (the loop could run it) and is treated as un-run.
	--
	-- The labels below are keyed off the RUNG RESULTS, never off the lane flags, so a rung a human ran by
	-- hand (a Studio smoke fed back through smoke-gate ingest) is never under-claimed as unverified.
	local escalate: { [string]: { label: string, reason: string } } = {
		["T2"] = {
			label = "verified-local-T1 (logic only, NOT engine-booted) — T2 blocked-on-human: engine lane "
				.. "not connected; awaiting-human-gate-T3",
			reason = "T0..T1 green and the engine lane is unavailable, so T2 is the human's to run (open the "
				.. "place in Studio with the MCP plugin / provision Open Cloud); escalation is honest only "
				.. "with the T2-unverified label",
		},
		["T2.5"] = {
			label = "engine-smoked-T2 — ready for human playtest (T3); T2.5 (automated playtest) "
				.. "blocked-on-human: the run-in-roblox lane is not connected, so nothing has checked that the "
				.. "game is not merely BROKEN",
			reason = "T0..T2 green; the in-engine smoke passed but the automated playtest lane is down, so the "
				.. "human is the first thing to walk the world",
		},
		["T2.7"] = {
			label = "scene-verified-T2.5 — geometry, wiring and server effects checked. T2.7 (live Studio "
				.. "pass) blocked-on-human: the ENTIRE CLIENT (HUD, motes, leaderboard, client bootstrap, "
				.. "prompt reachability) and ALL physics are UNVERIFIED and are the human's first job at T3",
			reason = "T0..T2.5 green; the edit-mode lane structurally cannot see client wiring (no LocalPlayer), "
				.. "so a live Studio session or the human is the only thing that can",
		},
	}
	for _, id in ENGINE_RUNGS do
		if results[id] ~= "green" then
			if lane[id] then
				return refuse(
					id,
					results[id],
					string.format(
						"is un-run and its lane is available — run it before escalating (%s)",
						id
					)
				)
			end
			local e = escalate[id]
			return {
				ready = true,
				highestGreen = highestGreen,
				lastAutomatable = lastAutomatable,
				label = e.label,
				blockedBy = nil,
				reason = e.reason,
			}
		end
	end

	-- Every engine rung green. The claim is still bounded: one Studio session cannot contend with itself
	-- and `game.JobId` is `""` there, so multi-client contention and cross-server persistence are
	-- untestable BY CONSTRUCTION and must be said out loud rather than swallowed by a clean label.
	return {
		ready = true,
		highestGreen = highestGreen,
		lastAutomatable = lastAutomatable,
		label = "engine-verified-T2.7 — ready for human playtest (T3). Multi-client contention and "
			.. "cross-server persistence remain UNTESTABLE (one session cannot contend with itself; JobId "
			.. "is \"\"), and whether it is any FUN is still nobody's measurement but a human's",
		blockedBy = nil,
		reason = "T0..T2.7 green; every automatable rung is exhausted; the only rung left is the human playtest",
	}
end

-- Convenience: map a gauntlet.luau result ({ ok, stages: [{ name, ok }] }) to T0/T0.5/T1 rung statuses.
-- stylua+selene+rojo => T0 (all three must be green); the "require" stage => T0.5; "lune" AND
-- "reachability" => T1. A stage the gauntlet did not emit reads as "unrun" (fail-closed: absent is never
-- green). T2..T3 are not part of the gauntlet — the caller layers them in from the smoke gate, the
-- playtest lane, the Studio pass, the human.
--
-- WHY reachability IS T1 AND NOT A NEW RUNG. A reachability failure means the game's LOGIC IS INERT —
-- an upgrade the player paid 9,625 Stardust for changes nothing — which is exactly what T1 claims to
-- certify. T0.5's label is specifically require-resolution. And a game whose gauntlet predates the
-- reachability stage now reads T1 "unrun", not "green": the same fail-closed treatment the require stage
-- got, and the reason an old artifact can never launder itself into a tier it was never measured against.
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
		["T1"] = statusOf({ "lune", "reachability" }),
	}
end

-- The aggregator (VERIFICATION-LADDER.md §4.2): compose a full ladder from a gauntlet result plus any
-- higher-rung evidence the gauntlet cannot produce — `t2` from an in-engine smoke (smoke-gate), `t3`
-- from a human playtest, and (optionally) `higher` carrying T2.5 / T2.7 evidence from the automated
-- playtest lane and the live Studio pass. EVERY one of them defaults to "unrun" (fail-closed: absent
-- evidence is never green, and a rung with no evidence artifact is NEVER reported as anything else).
-- This is what the build-game handoff step calls so the verdict is computed, not asserted in prose. The
-- runnable CLI `tier-status.luau` is a thin wrapper over this.
--
-- `higher` is a trailing optional so every existing 4-argument caller keeps working unchanged.
function M.statusFor(
	gauntlet: { ok: boolean, stages: { { name: string, ok: boolean } } },
	t2: Status?,
	t3: Status?,
	lanes: (boolean | Lanes)?,
	higher: Results?
): Handoff
	local results = M.fromGauntlet(gauntlet)
	results["T2"] = t2 or "unrun"
	results["T2.5"] = (higher and higher["T2.5"]) or "unrun"
	results["T2.7"] = (higher and higher["T2.7"]) or "unrun"
	results["T3"] = t3 or "unrun"
	return M.handoff(results, lanes)
end

return M
