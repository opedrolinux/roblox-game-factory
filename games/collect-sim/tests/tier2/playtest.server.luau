--!strict
-- games/collect-sim/tests/tier2/playtest.server.luau   [TIER-2.5 — the automated AI playtest]
--
-- WHY: T2 proves the game BOOTS and the loop RUNS. T3 is a human deciding whether it is any good.
-- Between them sits everything that is merely BROKEN — a spawn inside a wall, an island that was
-- never built, a pad wired to no action, an error spraying the output window. A human should never
-- spend their attention on those. This rung spends a machine's attention instead.
--
-- WHAT IT HONESTLY IS: a static-world inspection + synthetic-traversal + effect-assertion gate. It
-- is NOT a bot playing the game, and the difference matters. Verified by direct experiment under
-- run-in-roblox 0.3.0:
--   * The DataModel runs in EDIT MODE. Scripts do not auto-run; there is no LocalPlayer, no
--     PlayerGui, no replication.
--   * PHYSICS DOES NOT STEP. workspace:StepPhysics is a no-op and Humanoid:MoveTo moves nothing.
--     An unanchored part at y=40 is still at y=40 a second later. So traversal here is KINEMATIC
--     (raycast + box query), a geometric proxy for walking and never a substitute.
--   * Therefore the ENTIRE CLIENT is unreachable: HUD, motes, leaderboard board, prompts, camera.
-- Anything this file reports green says nothing whatsoever about any of that. See the label in
-- tier-status and the "what this is blind to" section of RUNBOOK.md.
--
-- FAIL-CLOSED, like the T2 smoke: the single evidence line prints LAST. A crash before it means no
-- line, and a missing line reads as RED, never as a silent pass.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- ── evidence accumulators ────────────────────────────────────────────────────────────────────────
local phaseOk: { [string]: boolean } = {}
local phaseDetail: { [string]: any } = {}
local diagnostics: { [string]: any } = {}
-- KNOWN-RED is reported SEPARATELY from the gating phases and deliberately excluded from the
-- pass/fail AND. A permanently-red gate with a standing waiver trains everyone to ignore the one
-- signal that is actually firing; a named, dated known-red block does not.
local knownRed: { any } = {}

local function record(name: string, ok: boolean, detail: any): ()
	phaseOk[name] = ok
	phaseDetail[name] = detail
end

local function runPhase(name: string, body: () -> (boolean, any)): ()
	local ranOk, okOrErr, detail = pcall(body)
	if not ranOk then
		record(name, false, `THREW: {tostring(okOrErr)}`)
		return
	end
	record(name, okOrErr == true, detail)
end

local function runKnownRed(name: string, body: () -> (boolean, any)): ()
	local ranOk, okOrErr, detail = pcall(body)
	if not ranOk then
		table.insert(knownRed, { name = name, ok = false, detail = `THREW: {tostring(okOrErr)}` })
		return
	end
	table.insert(knownRed, { name = name, ok = okOrErr == true, detail = detail })
end

-- ══ BOOTSTRAP (parity-checked) ═══════════════════════════════════════════════════════════════════
-- Deliberately duplicated from smoke.server.luau rather than shared: run-in-roblox runs ONE
-- standalone script with no sibling requires. What makes the duplication safe is that the parity
-- check below is duplicated WITH it — each script independently asserts its mirror is set-equal to
-- init.server.luau's real require list, so neither can drift silently. (Duplicating a
-- self-verifying block is very different from duplicating an unverified list. The unverified
-- version of this list silently omitted WorldService, which meant every "T2 green" recorded before
-- 2026-07-30 ran against a Workspace containing zero parts.)
local Server = ServerScriptService:WaitForChild("Server", 15)
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local context: any = nil
local registry: any = nil
local gate: any = nil
local net: any = nil
local Net: any = nil
local ResultMod: any = nil
local bootError: string? = nil

do
	local ok, err = pcall(function(): ()
		local Context = require(Server.Context) :: any
		local Bootstrap = require(Server.framework.Bootstrap) :: any
		Net = require((Shared :: any).Net) :: any
		ResultMod = require((Shared :: any).Result) :: any

		local serviceModules: { [string]: any } = {
			CollectionService = require(Server.services.collection.CollectionService),
			UpgradesShopService = require(Server.services.shop.UpgradesShopService),
			DailyStreakService = require(Server.services.daily.DailyStreakService),
			IslandsService = require(Server.services.islands.IslandsService),
			LeaderboardService = require(Server.services.leaderboard.LeaderboardService),
			MonetizationService = require(Server.services.monetization.MonetizationService),
			OfflineService = require(Server.services.offline.OfflineService),
			RestockService = require(Server.services.restock.RestockService),
			RebirthService = require(Server.services.rebirth.RebirthService),
			WorldService = require(Server.services.world.WorldService),
		}
		local order = {
			"CollectionService",
			"UpgradesShopService",
			"DailyStreakService",
			"IslandsService",
			"LeaderboardService",
			"MonetizationService",
			"OfflineService",
			"RestockService",
			"RebirthService",
			"WorldService",
		}

		local sourceOk, source = pcall(function(): string
			return (Server :: any).Source
		end)
		if sourceOk and type(source) == "string" then
			local declared: { [string]: boolean } = {}
			for name in string.gmatch(source, "require%(Server%.services%.[%w_]+%.([%w_]+)%)") do
				declared[name] = true
			end
			local drift: { string } = {}
			for name in declared do
				if serviceModules[name] == nil then
					table.insert(drift, `init.server has {name}, mirror does not`)
				end
			end
			for name in serviceModules do
				if not declared[name] then
					table.insert(drift, `mirror has {name}, init.server does not`)
				end
			end
			diagnostics.bootstrapParity = if #drift == 0 then "set-equal" else drift
			if #drift > 0 then
				error(`BOOTSTRAP PARITY DRIFT: {table.concat(drift, "; ")}`)
			end
		else
			diagnostics.bootstrapParity = "UNCHECKED (Server.Source unreadable)"
		end

		context = Context.build()
		local services = { context.net, context.data, context.analytics }
		for _, name in order do
			table.insert(services, serviceModules[name])
		end
		Bootstrap.start(services, context)
		net = context.net
		gate = context.gate
		registry = (net :: any)._registry
	end)
	if not ok then
		bootError = tostring(err)
	end
end

-- Each phase gets its OWN synthetic player. The Gate's rate buckets are PER PLAYER, so sharing one
-- id across phases would let an earlier phase's dispatches rate-shed a later one — and a shed
-- request is indistinguishable from a working one unless you look. Isolation removes the coupling
-- entirely rather than trying to reason about it.
local nextUserId = 900000
local function freshPlayer(tag: string): any
	nextUserId += 1
	return { UserId = nextUserId, Name = `T25_{tag}` }
end

local function invokeAs(player: any, actionName: string, payload: any): any
	local ctx = (net :: any):actionContext(player)
	return Net.dispatch(registry, gate, ctx, actionName, payload)
end

-- ══ PHASE: world-contract ════════════════════════════════════════════════════════════════════════
-- Does the 3D world the player will stand in actually exist, and is it built sanely?
runPhase("world-contract", function(): (boolean, any)
	if bootError ~= nil then
		return false, `bootstrap failed: {bootError}`
	end
	local world = Workspace:FindFirstChild("World")
	if world == nil then
		return false, "Workspace.World does not exist — WorldService built nothing"
	end
	local islandsFolder = world:FindFirstChild("Islands")
	local padsFolder = world:FindFirstChild("Pads")
	if islandsFolder == nil or padsFolder == nil then
		return false, "World is missing its Islands and/or Pads folder"
	end

	local problems: { string } = {}
	local islands = islandsFolder:GetChildren()
	local pads = padsFolder:GetChildren()

	if #islands == 0 then
		table.insert(problems, "zero island platforms built")
	end
	if #pads == 0 then
		table.insert(problems, "zero pads built")
	end

	-- Geometry sanity over EVERY BasePart in the world. These are the classic greybox failures:
	-- an unanchored part falls on frame 1; a zero-size part is invisible and uncollidable; a
	-- fully transparent solid part is an invisible wall the player walks into.
	local partCount = 0
	for _, inst in world:GetDescendants() do
		if inst:IsA("BasePart") then
			partCount += 1
			local full = inst:GetFullName()
			if not inst.Anchored then
				table.insert(problems, `UNANCHORED (will fall on frame 1): {full}`)
			end
			local size = inst.Size
			if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
				table.insert(problems, `zero/negative size: {full}`)
			end
			if inst.Transparency >= 1 and inst.CanCollide then
				table.insert(problems, `invisible but solid (invisible wall): {full}`)
			end
		end
	end

	-- Every pad must carry the padKind attribute its client controller keys off, and must actually
	-- have the ProximityPrompt that is the ONLY way a player can trigger it. A pad with no prompt
	-- is scenery the player will walk into and nothing will happen.
	for _, pad in pads do
		local full = pad:GetFullName()
		local kind = pad:GetAttribute("padKind")
		if kind == nil then
			table.insert(problems, `pad has no padKind attribute: {full}`)
		end
		if pad:FindFirstChildWhichIsA("ProximityPrompt") == nil then
			table.insert(problems, `pad has NO ProximityPrompt (untriggerable): {full}`)
		end
		local billboard = pad:FindFirstChildWhichIsA("BillboardGui")
		if billboard == nil then
			table.insert(problems, `pad has no BillboardGui label: {full}`)
		else
			local text = billboard:FindFirstChildWhichIsA("TextLabel")
			if text == nil or text.Text == "" then
				table.insert(problems, `pad label is missing or empty: {full}`)
			end
		end
	end

	-- Exactly one SpawnLocation. Zero = the player materialises at the origin, possibly under the
	-- map. More than one = Roblox picks arbitrarily and spawning becomes nondeterministic.
	local spawns = 0
	for _, inst in Workspace:GetDescendants() do
		if inst:IsA("SpawnLocation") then
			spawns += 1
		end
	end
	if spawns ~= 1 then
		table.insert(problems, `expected exactly 1 SpawnLocation, found {spawns}`)
	end

	diagnostics.world =
		{ islands = #islands, pads = #pads, parts = partCount, spawnLocations = spawns }

	if #problems > 0 then
		return false, problems
	end
	return true,
		`{#islands} islands, {#pads} pads, {partCount} parts, 1 SpawnLocation; all anchored, sized, opaque-or-passable, every pad has padKind + prompt + label`
end)

-- ══ PHASE: spawn-safety ══════════════════════════════════════════════════════════════════════════
-- The single most common "obviously broken" first impression: you press Play and you are inside a
-- wall, or falling forever. Deterministic and zero-flake — raycast + box query, no physics needed.
runPhase("spawn-safety", function(): (boolean, any)
	local world = Workspace:FindFirstChild("World")
	if world == nil then
		return false, "no world"
	end
	local spawn = world:FindFirstChildWhichIsA("SpawnLocation")
	if spawn == nil then
		return false, "no SpawnLocation to test"
	end

	local origin = spawn.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}

	-- Is there ground beneath the spawn, and how far down? A long drop means the player free-falls
	-- on join; no hit at all means the spawn is over the void.
	local down = Workspace:Raycast(origin + Vector3.new(0, 3, 0), Vector3.new(0, -200, 0), params)
	if down == nil then
		return false,
			`NOTHING BENEATH SPAWN — the player falls into the void from {tostring(origin)}`
	end
	local drop = (origin.Y + 3) - down.Position.Y

	-- Is the character capsule clear? A standing character is roughly 2 x 5 x 1 studs. If solid
	-- geometry intersects that volume the player spawns inside a wall.
	local capsuleCentre = origin + Vector3.new(0, 3.5, 0)
	local overlapping = Workspace:GetPartBoundsInBox(
		CFrame.new(capsuleCentre),
		Vector3.new(2, 5, 1),
		OverlapParams.new()
	)
	local blockers: { string } = {}
	for _, part in overlapping do
		if part.CanCollide and part ~= spawn then
			table.insert(blockers, part:GetFullName())
		end
	end

	diagnostics.spawn = {
		position = tostring(origin),
		groundUnder = down.Instance:GetFullName(),
		dropStuds = drop,
		blockers = blockers,
	}

	if #blockers > 0 then
		return false, `SPAWN IS INSIDE GEOMETRY: {table.concat(blockers, ", ")}`
	end
	if drop > 20 then
		return false,
			`spawn is {math.floor(drop)} studs above the ground — the player free-falls on join`
	end
	return true,
		`spawn at {tostring(origin)}, {string.format("%.1f", drop)} studs above {down.Instance.Name}, capsule clear`
end)

-- ══ PHASE: traversal ═════════════════════════════════════════════════════════════════════════════
-- Can a player get from the spawn island to every other island? KINEMATIC — steps a probe along a
-- line and raycasts down. It cannot tell you whether a gap is JUMPABLE (no physics); it tells you
-- where the ground is and is not, which is what catches a missing platform or an unintended pit.
runPhase("traversal", function(): (boolean, any)
	local world = Workspace:FindFirstChild("World")
	if world == nil then
		return false, "no world"
	end
	local islandsFolder = world:FindFirstChild("Islands")
	if islandsFolder == nil then
		return false, "no islands"
	end

	local platforms: { any } = {}
	for _, inst in islandsFolder:GetChildren() do
		if inst:IsA("BasePart") then
			table.insert(platforms, inst)
		end
	end
	if #platforms == 0 then
		return false, "no island platforms to traverse"
	end
	table.sort(platforms, function(a, b): boolean
		return a.Position.X < b.Position.X
	end)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}

	-- Sample the SURFACE of each island: if a platform has a hole, or a pad sits off its edge, the
	-- ray misses the platform it should hit.
	local surfaceMisses: { string } = {}
	for _, plat in platforms do
		local top = plat.Position.Y + plat.Size.Y / 2
		local halfX, halfZ = plat.Size.X / 2 - 2, plat.Size.Z / 2 - 2
		for _, offset in
			{
				Vector3.new(0, 0, 0),
				Vector3.new(halfX, 0, 0),
				Vector3.new(-halfX, 0, 0),
				Vector3.new(0, 0, halfZ),
				Vector3.new(0, 0, -halfZ),
			}
		do
			local at = Vector3.new(plat.Position.X, top, plat.Position.Z) + offset
			local hit = Workspace:Raycast(at + Vector3.new(0, 5, 0), Vector3.new(0, -12, 0), params)
			if hit == nil then
				table.insert(surfaceMisses, `{plat.Name} has no ground at {tostring(at)}`)
			end
		end
	end

	-- Walk the line between consecutive islands, measuring at every step how far a player would
	-- FALL and onto WHAT.
	--
	-- The first version of this asked "is there ground within 8 studs?" and reported a perfect 0
	-- studs of gap — because the Baseplate underlies the entire archipelago and always answered
	-- yes. It was a check that could hardly fail, which is worse than no check. What actually
	-- matters to a player is the DROP: stepping off an island onto a baseplate 7 studs below is not
	-- a hole, but it is also not a bridge, and the human should be told which one this world has.
	local worstDrop, worstAt, worstOnto = 0, "", ""
	local voidSteps = 0
	local steps = 0
	for i = 1, #platforms - 1 do
		local a, b = platforms[i], platforms[i + 1]
		local top = a.Position.Y + a.Size.Y / 2
		local x = a.Position.X
		while x < b.Position.X do
			x += 1
			steps += 1
			local from = Vector3.new(x, top + 3, a.Position.Z)
			local hit = Workspace:Raycast(from, Vector3.new(0, -400, 0), params)
			if hit == nil then
				voidSteps += 1
			else
				local drop = from.Y - hit.Position.Y
				if drop > worstDrop then
					worstDrop = drop
					worstAt = `x={math.floor(x)} between {a.Name} and {b.Name}`
					worstOnto = hit.Instance.Name
				end
			end
		end
	end

	diagnostics.traversal = {
		platforms = #platforms,
		stepsSampled = steps,
		voidSteps = voidSteps,
		worstDropStuds = worstDrop,
		worstDropAt = worstAt,
		landsOn = worstOnto,
	}

	if #surfaceMisses > 0 then
		return false, surfaceMisses
	end
	if voidSteps > 0 then
		return false,
			`{voidSteps} of {steps} sampled points between islands have NOTHING beneath them — a player who steps there falls forever`
	end
	return true,
		`{#platforms} platforms, all surfaces supported, {steps} inter-island points sampled with 0 over the void; worst fall {string.format(
			"%.1f",
			worstDrop
		)} studs onto {worstOnto} ({worstAt}) — whether that is CROSSABLE is not asserted, physics does not run here`
end)

-- ══ PHASE: no-log-errors ═════════════════════════════════════════════════════════════════════════
-- The first thing a human actually sees is the Output window. If it is spraying red, they will
-- (rightly) stop and report that instead of playing. The cheapest high-yield signal in this file.
runPhase("no-log-errors", function(): (boolean, any)
	local history = LogService:GetLogHistory()
	local errors: { string } = {}
	local warnings: { string } = {}
	-- Known, accepted warnings. Dated so they are reviewed rather than inherited forever: these are
	-- the B2 security-suite notices every action registration emits until that suite is built.
	local ACCEPTED_WARNING_SUBSTRING = "registered without the B2 security suite" -- reviewed 2026-07-30
	for _, entry in history do
		local msg = tostring(entry.message)
		if entry.messageType == Enum.MessageType.MessageError then
			table.insert(errors, msg)
		elseif entry.messageType == Enum.MessageType.MessageWarning then
			if string.find(msg, ACCEPTED_WARNING_SUBSTRING, 1, true) == nil then
				table.insert(warnings, msg)
			end
		end
	end
	diagnostics.log =
		{ errors = #errors, unacceptedWarnings = #warnings, sampleWarnings = warnings }
	if #errors > 0 then
		return false, errors
	end
	return true,
		`no errors in the output window; {#warnings} unaccepted warning(s) (the B2 security notices are an accepted, dated allowlist)`
end)

-- ══ PHASE: affordance-wiring ═════════════════════════════════════════════════════════════════════
-- Every pad the player can walk up to must lead to a REGISTERED action that returns a TYPED result.
-- This proves the action behind the pad works. It does NOT prove the pad reaches the action — that
-- last inch is client-side (Pads.luau) and structurally unreachable here. Stated, not glossed.
runPhase("affordance-wiring", function(): (boolean, any)
	if bootError ~= nil then
		return false, `bootstrap failed: {bootError}`
	end
	local world = Workspace:FindFirstChild("World")
	local padsFolder = if world ~= nil then world:FindFirstChild("Pads") else nil
	if padsFolder == nil then
		return false, "no pads to check"
	end

	local A = Net.Actions
	local PAD_ACTION: { [string]: string } = {
		refiner = A.Sell,
		shop = A.BuyUpgrade,
		rebirth = A.Rebirth,
		unlock = A.UnlockIsland,
	}

	local problems: { string } = {}
	local dispatched = 0
	local seenKinds: { [string]: boolean } = {}

	for _, pad in padsFolder:GetChildren() do
		local kind = pad:GetAttribute("padKind")
		if type(kind) ~= "string" then
			continue
		end
		seenKinds[kind] = true
		local actionName = PAD_ACTION[kind]
		if actionName == nil then
			table.insert(problems, `pad kind "{kind}" maps to NO action ({pad.Name})`)
			continue
		end
		if registry:get(actionName) == nil then
			table.insert(problems, `pad "{kind}" -> action "{actionName}" is NOT REGISTERED`)
			continue
		end
		-- Dispatch it for real, on a fresh player so no rate bucket is shared. We are not asserting
		-- success — a broke player legitimately cannot buy. We assert the request REACHED a handler
		-- and came back typed. RateLimited is deliberately NOT acceptable: it means the request
		-- never reached the handler, which is exactly the state this phase exists to detect.
		local player = freshPlayer(kind)
		context.data:loadSession(player)
		local payload: any = {}
		if kind == "shop" then
			payload = { upgradeId = "backpack" }
		elseif kind == "unlock" then
			payload = { islandId = pad:GetAttribute("islandId") or 2 }
		end
		local res = invokeAs(player, actionName, payload)
		dispatched += 1
		if res == nil then
			table.insert(problems, `{kind} -> {actionName} returned nil (not a Result)`)
		elseif res.ok == nil then
			table.insert(problems, `{kind} -> {actionName} returned a non-Result value`)
		elseif not res.ok then
			local code = tostring(res.code)
			if code == ResultMod.Codes.UnknownAction then
				table.insert(problems, `{kind} -> {actionName} is UNKNOWN to the dispatcher`)
			elseif code == ResultMod.Codes.RateLimited then
				table.insert(
					problems,
					`{kind} -> {actionName} was RATE-LIMITED — the request never reached its handler, so this pad is UNVERIFIED`
				)
			end
			-- any other typed Err (Insufficient, OutOfRange, NotOwner...) is a handler REPLYING,
			-- which is what we are proving.
		end
	end

	-- A phase that silently dispatched nothing must not report green.
	if dispatched == 0 then
		return false, "no pad dispatches were issued — this phase verified NOTHING"
	end
	diagnostics.affordance = { dispatched = dispatched, kinds = seenKinds }

	if #problems > 0 then
		return false, problems
	end
	return true,
		`{dispatched} pad dispatches, every padKind resolves to a REGISTERED action returning a typed Result (pad->action proven; pad->player reachability is client-side and NOT proven here)`
end)

-- ══ PHASE: client-load ═══════════════════════════════════════════════════════════════════════════
-- The T0.5 require gate is static. This is the only lane that drives CLIENT requires through the
-- real engine. It is an ALLOWLIST SNAPSHOT, not a sweep: most controllers touch Players.LocalPlayer
-- at module load, which is nil here, so a naive "require everything" gate would be a wall of false
-- failures. Recording which modules load and which do not is the diagnostic.
runPhase("client-load", function(): (boolean, any)
	local starterPlayer = game:GetService("StarterPlayer")
	local scripts = starterPlayer:FindFirstChild("StarterPlayerScripts")
	local client = if scripts ~= nil then scripts:FindFirstChild("Client") else nil
	if client == nil then
		return false, "StarterPlayerScripts.Client does not exist — no client code shipped at all"
	end

	local loaded: { string } = {}
	local blockedByLocalPlayer: { string } = {}
	local realFailures: { string } = {}
	for _, inst in client:GetDescendants() do
		if not inst:IsA("ModuleScript") then
			continue
		end
		local ok, err = pcall(require, inst)
		if ok then
			table.insert(loaded, inst.Name)
		else
			-- Classifying the failure is the whole difficulty. Luau does NOT hand back the
			-- underlying error: a module that throws during load reports the generic "Requested
			-- module experienced an error while loading", and the real text (here
			-- "attempt to index nil with 'WaitForChild'") only ever reaches stderr. Matching on the
			-- pcall message therefore mis-buckets every controller as a real failure — which is
			-- exactly what the first run of this phase did.
			--
			-- So classify from the SOURCE instead, which is deterministic and needs no log
			-- correlation: a module that touches Players.LocalPlayer at load CANNOT load in edit
			-- mode (there is no LocalPlayer), and that is expected, not a defect. A module that
			-- does NOT touch it and still failed has a real problem — a syntax error, a bad
			-- cross-service require, a renamed module.
			local srcOk, src = pcall(function(): string
				return (inst :: any).Source
			end)
			local touchesLocalPlayer = srcOk
				and type(src) == "string"
				and string.find(src, "LocalPlayer", 1, true) ~= nil
			if touchesLocalPlayer then
				table.insert(blockedByLocalPlayer, inst.Name)
			else
				table.insert(realFailures, `{inst.Name}: {tostring(err)}`)
			end
		end
	end

	diagnostics.client = {
		loaded = loaded,
		blockedByLocalPlayer = blockedByLocalPlayer,
		realFailures = realFailures,
	}

	if #realFailures > 0 then
		return false, realFailures
	end
	return true,
		`{#loaded} client module(s) loaded clean; {#blockedByLocalPlayer} need a real LocalPlayer (expected in edit mode, NOT a defect); 0 real load failures`
end)

-- ══ KNOWN-RED: reported separately, never gating ═════════════════════════════════════════════════
-- These are expected to FAIL against the current build because they assert the SPEC, and the build
-- does not meet it yet. They are kept out of the pass/fail AND so the gate stays meaningful, and
-- surfaced loudly so they cannot quietly become normal.

runKnownRed("upgrade-effects", function(): (boolean, any)
	if bootError ~= nil then
		return false, `bootstrap failed: {bootError}`
	end
	local A = Net.Actions
	local player = freshPlayer("upg")
	context.data:loadSession(player)
	context.data:update(player, function(d: any): any
		d.currencies.Stardust = 100000
		return d
	end)

	-- ONLY `backpack` has a server-observable channel: Collect's reply carries `capacity`. The other
	-- three upgrades live entirely in client constants, so a server script CANNOT assert their
	-- effect. Asserting "the level incremented" instead would PASS on a completely inert upgrade —
	-- a tautology dressed as a check — so they are declared UNASSERTABLE by name instead.
	local UNASSERTABLE: { [string]: string } = {
		["walk-speed"] = "Humanoid.WalkSpeed (client)",
		["magnet"] = "CollectionController ABSORB_RADIUS (client constant)",
		["collect-speed"] = "CollectionController TICK (client constant)",
	}

	local before = invokeAs(player, A.Collect, {})
	local capBefore = if before ~= nil and before.ok then before.value.capacity else -1

	local bought = invokeAs(player, A.BuyUpgrade, { upgradeId = "backpack" })
	if bought == nil or not bought.ok then
		local code = if bought ~= nil then tostring(bought.code) else "nil"
		return false, `could not buy the backpack upgrade to test it: {code}`
	end

	local after = invokeAs(player, A.Collect, {})
	local capAfter = if after ~= nil and after.ok then after.value.capacity else -1

	local detail = {
		backpackCapacityBefore = capBefore,
		backpackCapacityAfter = capAfter,
		backpackUpgradeHasEffect = capAfter > capBefore,
		unassertableFromServer = UNASSERTABLE,
	}
	if capAfter <= capBefore then
		return false, detail
	end
	return true, detail
end)

-- ══ LANE LIMITS — assert the harness's own boundaries, and fail when they IMPROVE ═══════════════
-- Every "blind to" claim in this file rests on three properties of run-in-roblox's edit-mode
-- DataModel. Comments rot; assertions do not. So the limits are MEASURED each run and recorded.
--
-- Deliberately inverted: this goes RED when a limit LIFTS. If a future Roblox or run-in-roblox
-- release starts stepping physics or advancing the clock, that is not a regression — it is an
-- invitation to build the rungs currently declared impossible, and it should interrupt someone
-- rather than pass quietly.
runPhase("lane-limits", function(): (boolean, any)
	-- Does the SERVER clock advance? The whole rate limiter and every time-gated feature (daily
	-- streak, restock, offline earnings) key off it. Measured, not assumed: time() delta is 0.0000
	-- across a real 2s wait here, while os.clock() advances normally — so the rate window never
	-- refills, a burst drains once and every later request sheds. Any pacing or time-gate assertion
	-- in this lane is therefore MEANINGLESS, which is why no phase makes one.
	local t0, c0 = time(), os.clock()
	task.wait(0.5)
	local clockAdvances = (time() - t0) > 0.25
	local wallAdvances = (os.clock() - c0) > 0.25

	-- Does physics step? An unanchored part must fall if it does.
	local probe = Instance.new("Part")
	probe.Anchored = false
	probe.CanCollide = false
	probe.Position = Vector3.new(0, 500, 0)
	probe.Parent = Workspace
	local y0 = probe.Position.Y
	task.wait(0.5)
	local physicsSteps = math.abs(probe.Position.Y - y0) > 0.1
	probe:Destroy()

	local hasLocalPlayer = game:GetService("Players").LocalPlayer ~= nil

	local limits = {
		serverClockAdvances = clockAdvances,
		wallClockAdvances = wallAdvances,
		physicsSteps = physicsSteps,
		hasLocalPlayer = hasLocalPlayer,
	}
	diagnostics.laneLimits = limits

	local lifted: { string } = {}
	if clockAdvances then
		table.insert(
			lifted,
			"the SERVER CLOCK now advances — time-gated features and real pacing measurement became testable"
		)
	end
	if physicsSteps then
		table.insert(
			lifted,
			"PHYSICS now steps — real locomotion, falling and collision became testable"
		)
	end
	if hasLocalPlayer then
		table.insert(
			lifted,
			"a LOCALPLAYER now exists — the HUD, motes and client bootstrap became testable"
		)
	end
	if #lifted > 0 then
		return false,
			`LANE LIMITS LIFTED (this is good news, not a regression) — rebuild the blind rungs: {table.concat(
				lifted,
				"; "
			)}`
	end
	return true,
		`limits unchanged: server clock frozen, physics does not step, no LocalPlayer (wall clock does advance). Every "blind to" claim in this file still holds.`
end)

-- server-throughput / pacing is DELIBERATELY NOT a rung here. It cannot be one: the server clock is
-- frozen in this lane (asserted above), so the rate window never refills and the mote grant curve —
-- a function of elapsed time — never advances. A measurement attempted anyway produced exactly the
-- burst size (30 successes, then 290 rate-shed of 320 dispatches), which measures the harness, not
-- the game. Reporting that as RED would be a false signal, and a false red trains people to ignore
-- reds just as surely as a false green trains them to trust greens. Time-to-first-sell stays a
-- human observation until a lane with a running clock exists.

-- ══ SUMMARY ══════════════════════════════════════════════════════════════════════════════════════
local EXPECTED_PHASES = {
	"world-contract",
	"spawn-safety",
	"traversal",
	"no-log-errors",
	"affordance-wiring",
	"client-load",
	"lane-limits",
}
local phases: { any } = {}
local allOk = true
for _, name in EXPECTED_PHASES do
	local ok = phaseOk[name] == true
	if not ok then
		allOk = false
	end
	table.insert(phases, { name = name, ok = ok, detail = phaseDetail[name] or "phase never ran" })
end

print("── tier-2.5 AI PLAYTEST ──")
for _, p in phases do
	print(`  [{if p.ok then "PASS" else "FAIL"}] {p.name}: {HttpService:JSONEncode(p.detail)}`)
end
print("── known-red (NOT gating; assert the spec, which the build does not yet meet) ──")
for _, k in knownRed do
	print(`  [{if k.ok then "PASS" else "RED "}] {k.name}: {HttpService:JSONEncode(k.detail)}`)
end
print(`── diagnostics: {HttpService:JSONEncode(diagnostics)}`)

print(HttpService:JSONEncode({
	tier = 2.5,
	ok = allOk,
	phases = phases,
	knownRed = knownRed,
	blindTo = "the ENTIRE client: HUD, motes, leaderboard board, client bootstrap, ProximityPrompt reachability, and ALL physics (jumping, falling, collision). Physics does not step in this lane and there is no LocalPlayer. A green here is NOT 'ready to play'.",
}))
