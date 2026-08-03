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
	-- T2.5/T2.7 were admitted to the ladder (HANDOFF-2), so "through the human gate" now REQUIRES them:
	-- a T3 claim over an un-run automated playtest is exactly the non-contiguous claim this function
	-- exists to refuse.
	eq(
		ladder.highestTierReached({
			T0 = "green",
			["T0.5"] = "green",
			T1 = "green",
			T2 = "green",
			["T2.5"] = "green",
			["T2.7"] = "green",
			T3 = "green",
		}),
		"T3",
		"through the human gate -> T3"
	)
	eq(
		ladder.highestTierReached({
			T0 = "green",
			["T0.5"] = "green",
			T1 = "green",
			T2 = "green",
			T3 = "green",
		}),
		"T2",
		"a green T3 over an un-run T2.5 does not count (contiguity holds for the new rungs too)"
	)
	eq(
		ladder.highestTierReached({
			T0 = "green",
			["T0.5"] = "green",
			T1 = "green",
			T2 = "green",
			["T2.5"] = "green",
		}),
		"T2.5",
		"through the automated playtest -> T2.5"
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
			stage("reachability", true),
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
			stage("reachability", true),
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
			stage("reachability", true),
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
			stage("reachability", true),
			stage("lune", true),
		},
	})
	eq(
		noRequireStage["T0.5"],
		"unrun",
		"absent require stage -> T0.5 unrun (fail-closed, never green)"
	)

	-- The reachability gate joined T1. Two properties, both load-bearing:
	--  (a) a RED reachability stage makes T1 red even with every Lune test green — that combination is
	--      the exact state collect-sim shipped in: 313 green tests beside four upgrades that did nothing,
	--      because the tests asserted the WRITE and never the READ;
	--  (b) an OLD gauntlet artifact that predates the stage reads T1 "unrun", never "green" — the same
	--      fail-closed rule the require stage got, so a stale artifact cannot launder itself into a tier
	--      it was never measured against.
	local reachRed = ladder.fromGauntlet({
		ok = false,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
			stage("require", true),
			stage("reachability", false),
			stage("lune", true),
		},
	})
	eq(reachRed["T0"], "green", "T0 unaffected by a reachability failure")
	eq(reachRed["T0.5"], "green", "T0.5 unaffected by a reachability failure")
	eq(
		reachRed["T1"],
		"red",
		"reachability red + every Lune test green -> T1 RED (inert logic is not certified logic)"
	)

	local noReachStage = ladder.fromGauntlet({
		ok = true,
		stages = {
			stage("stylua", true),
			stage("selene", true),
			stage("rojo", true),
			stage("require", true),
			stage("lune", true),
		},
	})
	eq(
		noReachStage["T1"],
		"unrun",
		"absent reachability stage -> T1 unrun (fail-closed, never green)"
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
				-- the reachability stage rides with lune: both are T1, and every case below that wants a
				-- green T1 needs BOTH present and green
				stage("reachability", lune),
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

	-- ── the admitted rungs: T2.5 (automated playtest) and T2.7 (live Studio) ──
	local greenBase = { T0 = "green", ["T0.5"] = "green", T1 = "green" }
	local function withRungs(extra: { [string]: string }): { [string]: any }
		local r: { [string]: any } = {}
		for k, v in greenBase do
			r[k] = v
		end
		for k, v in extra do
			r[k] = v
		end
		return r
	end

	-- HANDOFF-4, THE regression this rewrite exists for. Before it, tier-status wrapped its T2.5 gating
	-- in `if t2 == "green"`, so with the engine lane down and T2 never run, a RECORDED RED PLAYTEST WAS
	-- SILENTLY IGNORED and handoff still returned ready-for-human. A red is red regardless of the rung
	-- below it.
	local redPlaytestUnrunSmoke = ladder.handoff(withRungs({ ["T2.5"] = "red" }), false)
	eq(
		redPlaytestUnrunSmoke.ready,
		false,
		"a RED T2.5 blocks handoff even though T2 below it was never run (HANDOFF-4)"
	)
	eq(redPlaytestUnrunSmoke.blockedBy, "T2.5", "the red playtest is named as the blocker")

	local redStudioPass = ladder.handoff(withRungs({ T2 = "green", ["T2.7"] = "red" }), false)
	eq(redStudioPass.ready, false, "a RED T2.7 blocks handoff with its own lane down")
	eq(redStudioPass.blockedBy, "T2.7", "the red Studio pass is named as the blocker")

	-- Lane map: each engine rung has its OWN lane. The T2.5 lane being up makes an un-run T2.5 a
	-- BLOCKER (an un-exhausted automatable rung), exactly as the T2 lane always did for T2.
	local t25LaneUp = ladder.handoff(
		withRungs({ T2 = "green" }),
		{ ["T2"] = true, ["T2.5"] = true, ["T2.7"] = false }
	)
	eq(t25LaneUp.ready, false, "T2.5 lane up + T2.5 un-run -> run it before escalating")
	eq(t25LaneUp.blockedBy, "T2.5", "blocked by the un-run automated playtest")
	eq(t25LaneUp.lastAutomatable, "T2.5", "lastAutomatable is the highest rung with a live lane")

	-- The legacy BOOLEAN must never be read as "all three engine lanes are up": a lane that was never
	-- declared is not available (fail-closed), so `true` still means only the T2 smoke lane.
	local legacyBool = ladder.handoff(withRungs({ T2 = "green" }), true)
	eq(legacyBool.ready, true, "legacy boolean true does not silently claim a T2.5 lane")
	eq(legacyBool.lastAutomatable, "T2", "legacy boolean true -> lastAutomatable stays T2")

	-- T2.5 green with the Studio lane down: escalate, with a label that names the ENTIRE CLIENT as
	-- unverified. The edit-mode lane has no LocalPlayer, so it is structurally blind to client wiring.
	local sceneVerified = ladder.handoff(withRungs({ T2 = "green", ["T2.5"] = "green" }), false)
	eq(sceneVerified.ready, true, "T2.5 green + Studio lane down -> may escalate")
	eq(sceneVerified.highestGreen, "T2.5", "highestGreen reaches T2.5")
	check(
		string.find(sceneVerified.label, "scene%-verified%-T2%.5") ~= nil,
		"the label claims T2.5 only when T2.5 actually passed"
	)
	check(
		string.find(sceneVerified.label, "ENTIRE CLIENT") ~= nil,
		"the label names what is still unverified rather than implying readiness"
	)

	-- Every automatable rung exhausted. The claim is still BOUNDED: one Studio session cannot contend
	-- with itself and JobId is "" there, so that limit must be said out loud in the label.
	local fullyVerified =
		ladder.handoff(withRungs({ T2 = "green", ["T2.5"] = "green", ["T2.7"] = "green" }), false)
	eq(fullyVerified.ready, true, "T0..T2.7 green -> ready for the human")
	eq(fullyVerified.highestGreen, "T2.7", "highestGreen reaches T2.7")
	check(
		string.find(fullyVerified.label, "engine%-verified%-T2%.7") ~= nil,
		"the top automatable label is claimed only with T2.7 evidence"
	)
	check(
		string.find(fullyVerified.label, "UNTESTABLE") ~= nil,
		"even the top automatable label states what remains untestable by construction"
	)

	-- statusFor carries the higher evidence through, and DEFAULTS it to un-run (never green by absence).
	local sHigher = ladder.statusFor(
		gauntlet(true, true, true, true, true),
		"green",
		nil,
		false,
		{ ["T2.5"] = "green", ["T2.7"] = "green" }
	)
	eq(sHigher.highestGreen, "T2.7", "statusFor layers T2.5/T2.7 evidence in")
	local sNoHigher = ladder.statusFor(gauntlet(true, true, true, true, true), "green", nil, false)
	eq(
		sNoHigher.highestGreen,
		"T2",
		"absent T2.5/T2.7 evidence defaults to un-run, never green (fail-closed)"
	)
	local sRedHigher = ladder.statusFor(
		gauntlet(true, true, true, true, true),
		nil,
		nil,
		false,
		{ ["T2.5"] = "red" }
	)
	eq(sRedHigher.ready, false, "statusFor refuses on a recorded red T2.5 with T2 un-run")

	-- ── rungIndex ────────────────────────────────────────────────────────────
	check(ladder.rungIndex("T0") < ladder.rungIndex("T0.5"), "T0 below T0.5")
	check(ladder.rungIndex("T1") < ladder.rungIndex("T2"), "T1 below T2")
	eq(ladder.rungIndex("nope"), 0, "unknown rung -> 0")

	return checks, failures
end
