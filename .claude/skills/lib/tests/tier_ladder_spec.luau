--!strict
-- tier_ladder_spec.luau — corpus for the verification ladder. The load-bearing cases mirror the real
-- showstopper: a tree that is Lune-green but require-red (the cross-service boot bug) MUST refuse
-- handoff, never read as "ready". Driven by tests/run.luau, same discipline as the merge corpus.

local ladder = require("../tier-ladder")

return function(): (number, { string })
	local failures: { string } = {}
	local checks = 0

	local function check(cond: boolean, note: string)
		checks += 1
		if not cond then
			table.insert(failures, note)
		end
	end
	local function eq(got: any, want: any, note: string)
		checks += 1
		if got ~= want then
			table.insert(
				failures,
				string.format("%s: got %s, want %s", note, tostring(got), tostring(want))
			)
		end
	end

	-- ── highestTierReached: contiguous from the bottom ───────────────────────
	eq(
		ladder.highestTierReached({ T0 = "green", ["T0.5"] = "green", T1 = "green" }),
		"T1",
		"T0..T1 green, T2 absent -> T1"
	)
	eq(ladder.highestTierReached({ T0 = "red" }), "none", "T0 red -> none")
	eq(ladder.highestTierReached({}), "none", "empty results -> none")
	eq(
		ladder.highestTierReached({ T0 = "green", ["T0.5"] = "red", T1 = "green" }),
		"T0",
		"T0.5 red breaks the chain even though T1 is green (contiguity)"
	)
	eq(
		ladder.highestTierReached({ T0 = "red", ["T0.5"] = "green", T1 = "green" }),
		"none",
		"a green rung above a red T0 does not count (non-contiguous)"
	)
	eq(
		ladder.highestTierReached({
			T0 = "green",
			["T0.5"] = "green",
			T1 = "green",
			T2 = "green",
		}),
		"T2",
		"through T2 -> T2"
	)
	eq(
		ladder.highestTierReached({
			T0 = "green",
			["T0.5"] = "green",
			T1 = "green",
			T2 = "green",
			T3 = "green",
		}),
		"T3",
		"through the human gate -> T3"
	)

	-- ── handoff: THE conflation regression — Lune-green but require-red ───────
	-- This is the exact tree that shipped a non-booting game: T0 compiles, Lune logic passes, but the
	-- cross-service require fails in the DataModel (T0.5 red). The loop MUST refuse handoff.
	local boot = ladder.handoff({ T0 = "green", ["T0.5"] = "red", T1 = "green" }, false)
	eq(boot.ready, false, "require-red tree REFUSES handoff (the whole point)")
	eq(boot.blockedBy, "T0.5", "the blocking rung is named: T0.5")
	check(string.find(boot.label, "NOT ready") ~= nil, "require-red label says NOT ready")
	-- highestGreen is the contiguous chain (stops at the red T0.5), even though T1 is green.
	eq(boot.highestGreen, "T0", "handoff reports highestGreen = T0 (chain stops at the red T0.5)")

	-- ── handoff: engine lane unavailable (today's reality) ───────────────────
	local local1 = ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green" }, false)
	eq(local1.ready, true, "T0..T1 green + no engine lane -> may escalate (T1 is last automatable)")
	eq(local1.lastAutomatable, "T1", "no engine lane -> last automatable is T1")
	eq(local1.blockedBy, nil, "ready handoff has no blocker")
	check(
		string.find(local1.label, "NOT engine%-booted") ~= nil,
		"honest label: T1-ready is explicitly NOT engine-booted (no false 'ready')"
	)
	check(
		string.find(local1.label, "T2 blocked%-on%-human") ~= nil,
		"label records T2 as blocked-on-human, not silently skipped"
	)

	-- T1 not yet run -> in-progress, refuses handoff.
	local t1unrun = ladder.handoff({ T0 = "green", ["T0.5"] = "green" }, false)
	eq(t1unrun.ready, false, "T1 un-run refuses handoff")
	eq(t1unrun.blockedBy, "T1", "blocked by the un-run T1")

	-- T0 red -> in-progress at the very bottom.
	local t0red = ladder.handoff({ T0 = "red" }, false)
	eq(t0red.ready, false, "T0 red refuses handoff")
	eq(t0red.blockedBy, "T0", "blocked by T0")

	-- ── handoff: engine lane AVAILABLE (T2 becomes mandatory) ────────────────
	-- Once the lane exists, T1-green is no longer enough: an un-run T2 is now an un-exhausted
	-- automatable rung, so the loop must run it before escalating.
	local laneT2unrun = ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green" }, true)
	eq(laneT2unrun.ready, false, "engine lane available + T2 un-run -> must run T2 first")
	eq(laneT2unrun.blockedBy, "T2", "blocked by the un-run T2")
	eq(laneT2unrun.lastAutomatable, "T2", "engine lane -> last automatable is T2")

	local laneT2red =
		ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green", T2 = "red" }, true)
	eq(laneT2red.ready, false, "T2 red refuses handoff")
	eq(laneT2red.blockedBy, "T2", "blocked by the red T2")

	local laneT2green =
		ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green", T2 = "green" }, true)
	eq(laneT2green.ready, true, "T0..T2 green -> ready for the human playtest")
	eq(laneT2green.blockedBy, nil, "engine-smoked handoff has no blocker")
	eq(laneT2green.highestGreen, "T2", "engine-smoked handoff reports highestGreen = T2")
	check(
		string.find(laneT2green.label, "engine%-smoked%-T2") ~= nil,
		"engine-smoked label claims T2 only when T2 actually passed"
	)

	-- A human ran the smoke in Studio (T2 green) but the AUTOMATED lane is still down: T2 is genuinely
	-- verified, so the label must be engine-smoked, NOT under-claimed as "verified-local-T1". The label
	-- keys off the T2 RESULT, not the lane flag (regression for review finding L-1).
	local humanSmoke =
		ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green", T2 = "green" }, false)
	eq(humanSmoke.ready, true, "T2 green via a human Studio run -> ready")
	eq(humanSmoke.highestGreen, "T2", "human-verified T2 counts as T2 reached")
	check(
		string.find(humanSmoke.label, "engine%-smoked%-T2") ~= nil,
		"T2-green earns the engine-smoked label even when the automated lane is unavailable"
	)
	check(
		string.find(humanSmoke.label, "NOT engine%-booted") == nil,
		"a genuinely-booted T2 is NOT mislabeled 'NOT engine-booted'"
	)

	-- A RECORDED in-engine FAILURE (T2 red) blocks handoff EVEN with the lane down — a known non-booting
	-- game is never relabeled "ready". (Regression: the earlier walk-based handoff swallowed a red T2 when
	-- the lane was unavailable, wrongly emitting verified-local-T1.)
	local smokeFailedLaneDown =
		ladder.handoff({ T0 = "green", ["T0.5"] = "green", T1 = "green", T2 = "red" }, false)
	eq(
		smokeFailedLaneDown.ready,
		false,
		"a recorded T2 FAILURE blocks handoff even with the lane down"
	)
	eq(smokeFailedLaneDown.blockedBy, "T2", "blocked by the failed in-engine smoke")
	check(
		string.find(smokeFailedLaneDown.label, "T2 red") ~= nil,
		"the label names the failed engine smoke, not a false 'verified-local-T1'"
	)

	-- The blocked-on-human boundary: with the engine lane AVAILABLE, a rung marked blocked-on-human is a
	-- contradiction (the loop could run it) -> it is non-green and refuses handoff (finding L-2).
	local laneT2blocked = ladder.handoff(
		{ T0 = "green", ["T0.5"] = "green", T1 = "green", T2 = "blocked-on-human" },
		true
	)
	eq(
		laneT2blocked.ready,
		false,
		"engine lane available + T2 blocked-on-human -> refuses (run it)"
	)
	eq(laneT2blocked.blockedBy, "T2", "blocked by the not-actually-green T2")

	-- ── fromGauntlet: real gauntlet shape -> rung statuses ───────────────────
	local function stage(name: string, ok: boolean): { name: string, ok: boolean }
		return { name = name, ok = ok }
	end
	local allGreen = ladder.fromGauntlet({
		ok = true,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
			stage("require", true),
			stage("lune", true),
		},
	})
	eq(allGreen["T0"], "green", "all static stages green -> T0 green")
	eq(allGreen["T0.5"], "green", "require stage green -> T0.5 green")
	eq(allGreen["T1"], "green", "lune stage green -> T1 green")

	local requireRed = ladder.fromGauntlet({
		ok = false,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
			stage("require", false),
			stage("lune", true),
		},
	})
	eq(requireRed["T0"], "green", "T0 still green when only require fails")
	eq(requireRed["T0.5"], "red", "require stage red -> T0.5 red")
	eq(requireRed["T1"], "green", "lune green -> T1 green (but the chain breaks at T0.5)")

	local rojoRed = ladder.fromGauntlet({
		ok = false,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", false),
			stage("require", true),
			stage("lune", true),
		},
	})
	eq(rojoRed["T0"], "red", "one static stage red -> T0 red")

	-- An OLD gauntlet that predates the require gate: T0.5 must read "unrun", never "green".
	local noRequireStage = ladder.fromGauntlet({
		ok = true,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
			stage("lune", true),
		},
	})
	eq(
		noRequireStage["T0.5"],
		"unrun",
		"absent require stage -> T0.5 unrun (fail-closed, never green)"
	)

	-- A duplicated stage name (malformed input the real gauntlet never emits): a red occurrence must win,
	-- so a later green duplicate can NEVER launder a red to green (finding L-4, fail-closed).
	local dupRedThenGreen = ladder.fromGauntlet({
		ok = true,
		stages = {
			stage("stylua", false),
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
		},
	})
	eq(dupRedThenGreen["T0"], "red", "duplicate stylua [red, then green] -> T0 red (red wins)")

	-- ── statusFor: the aggregator (gauntlet result -> handoff verdict) ────────
	local function gauntlet(
		stylua: boolean,
		selene: boolean,
		rojo: boolean,
		require_: boolean,
		lune: boolean
	)
		return {
			ok = stylua and selene and rojo and require_ and lune,
			stages = {
				stage("stylua", stylua),
				stage("selene", selene),
				stage("rojo", rojo),
				stage("require", require_),
				stage("lune", lune),
			},
		}
	end

	-- A fully green gauntlet, no engine lane, no smoke yet -> verified-local-T1, ready for the human gate.
	local sFresh = ladder.statusFor(gauntlet(true, true, true, true, true), nil, nil, false)
	eq(sFresh.ready, true, "all-green gauntlet + no lane -> ready (T1)")
	eq(sFresh.highestGreen, "T1", "fresh status reaches T1")
	check(
		string.find(sFresh.label, "NOT engine%-booted") ~= nil,
		"fresh status label is honest (T1 only)"
	)

	-- The conflation, end-to-end from a real gauntlet shape: require stage red -> refuse handoff.
	local sBoot = ladder.statusFor(gauntlet(true, true, true, false, true), nil, nil, false)
	eq(sBoot.ready, false, "require-red gauntlet -> statusFor refuses handoff")
	eq(sBoot.blockedBy, "T0.5", "statusFor names the require rung as the blocker")

	-- A recorded human/engine smoke (T2 green) layered onto a green gauntlet -> engine-smoked.
	local sSmoked = ladder.statusFor(gauntlet(true, true, true, true, true), "green", nil, false)
	eq(sSmoked.ready, true, "T2 evidence layered in -> ready")
	eq(sSmoked.highestGreen, "T2", "layered T2 green reaches T2")
	check(
		string.find(sSmoked.label, "engine%-smoked%-T2") ~= nil,
		"statusFor surfaces engine-smoked"
	)

	-- Engine lane available but no smoke recorded yet -> must run T2 first.
	local sLane = ladder.statusFor(gauntlet(true, true, true, true, true), nil, nil, true)
	eq(sLane.ready, false, "lane available + T2 unrun -> statusFor refuses (run the smoke)")
	eq(sLane.blockedBy, "T2", "statusFor blocks on the un-run T2 when the lane exists")

	-- ── rungIndex ────────────────────────────────────────────────────────────
	check(ladder.rungIndex("T0") < ladder.rungIndex("T0.5"), "T0 below T0.5")
	check(ladder.rungIndex("T1") < ladder.rungIndex("T2"), "T1 below T2")
	eq(ladder.rungIndex("nope"), 0, "unknown rung -> 0")

	return checks, failures
end
