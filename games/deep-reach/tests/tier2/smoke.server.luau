--!strict
-- games/deep-reach/tests/tier2/smoke.server.luau
-- ═══ TIER-2 — THE IN-ENGINE SMOKE GATE ══════════════════════════════════════════════════════════
--
-- A SERVER **Script** (not a ModuleScript). It runs inside a real DataModel and nowhere else: this
-- file has NO `script == nil` Lune branch, every require is an INSTANCE require rooted at
-- `game:GetService(...)` (never at `script`, so it also runs verbatim from the Studio command bar),
-- and it is INERT under Lune by construction. It is authored blind — nobody has run it — and the
-- runbook beside it (RUNBOOK.md) is the only way it produces evidence.
--
-- WHY THIS RUNG EXISTS. This game's ancestor passed 313 Lune tests and did not boot in Roblox at
-- all: a cross-service `require` resolved against the FILESYSTEM under Lune (where `server/` and
-- `shared/` are siblings) and against the INSTANCE TREE in Roblox (where they are different
-- services). T0.5's static require gate now catches the bare-string form; it cannot catch a D1 shim
-- whose two branches drift, a `Start()` that throws, an infinite `WaitForChild`, a service the
-- bootstrap forgot, or a handler that is registered on a registry nothing is wired to. Only running
-- the REAL bootstrap in a REAL DataModel can.
--
-- ── THE FOUR PHASES (docs/VERIFICATION-LADDER.md §5.1) ──────────────────────────────────────────
--   0. boot-probe        — pcall the REAL bootstrap: require(Server.Context), Context.build(), and
--                          `Bootstrap.start` over the service list PARSED OUT OF THE REAL
--                          src/server/init.server.luau. One assertion that executes the Roblox
--                          instance-require branch of every D1 shim and every Context require.
--   1. wire-present      — the remotes NetServer.Start created exist AND ARE THE ONES THIS BOOT
--                          BOUND, and the live registry set-equals the full Net.Actions set.
--   2. core-loop         — claim a plot, collect the smelter, claim the daily drop, buy a structure,
--                          descend, resurface — through the REAL Net.dispatch with the REAL ctx
--                          (real Clock.real(time), real DataService) — and assert the PERSISTED
--                          PlayerView balance moved the right way AND the SERVER-REPORTED income
--                          rate moved with it.
--   3. assert-no-error   — zero engine errors across boot + loop, and the rejection matrix returns
--                          the EXACT expected Err codes with a wire-serializable Result envelope.
--
-- ── FAIL-CLOSED, AND WHAT THAT COSTS ────────────────────────────────────────────────────────────
-- The `{"tier":2,...}` line is printed ONCE, as the LAST statement in this file. **A run that dies
-- before it prints NOTHING, and the smoke-gate INGEST mode reads a missing line as T2-red.** That is
-- the whole point: a crash must never read as a silent pass. The four phase names are pinned
-- (`boot-probe` / `wire-present` / `core-loop` / `assert-no-error`); a missing or renamed phase
-- fails closed to T2-red at the reader, so this file must never rename one to dodge a red.
--
-- A phase is `ok` only when it recorded at least one PASS and zero FAILURES. A phase that observed
-- nothing is RED, never green — the predecessor T2 smoke in this factory was green for weeks while
-- building NOTHING, because its hand-kept service list silently omitted a service and every
-- assertion ran vacuously. Which is exactly why phase 0 does not carry a hand-kept list at all: it
-- PARSES `local services = { ... }` out of the real entrypoint's `.Source`, checks the ORDER, and
-- separately sweeps `Server.services` for any `*Service` module the bootstrap never boots.
--
-- ── WHAT IT STILL CANNOT SEE (be honest, do not oversell) ───────────────────────────────────────
--   * It is a SERVER script. It dispatches through the same registry/gate/ActionContext objects the
--     live `OnServerInvoke` closure holds, but it does not itself cross the client→server
--     replication boundary — no server script can. The Result envelope is audited for
--     wire-serializability instead, and the real crossing belongs to T2.7 (`/engine-pass`).
--   * No registered action declares `ownerOf`, so `Net.dispatch`'s ownership step is UNREACHABLE on
--     the live wire today. Phase 3 says so out loud, exercises `gate:assertOwner` directly, and
--     asserts the game's actual anti-hijack defence instead (a payload that NAMES a plot is refused).
--   * Nothing here looks at a pixel or at the client bootstrap. That is T2.7 and T3.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 0 — CONSTANTS
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- Rojo mount names. Project-file DATA (`default.project.json`'s `tree`), not a contract — re-read
-- them if the project file changes.
local SERVER_MOUNT = "Server"
local SHARED_MOUNT = "Shared"

-- The two remotes `NetServer.Start` creates. Duplicated from src/server/net/NetServer.luau ON
-- PURPOSE: phase 1 is the check that those names actually appear in ReplicatedStorage, so reading
-- them out of NetServer would make the assertion circular.
local REMOTE_FUNCTION_NAME = "CoreGateway"
local REMOTE_EVENT_NAME = "CoreEvents"

-- Every `*Service` module under `Server.services` that the bootstrap boots through a ctx FIELD
-- rather than by name. Without this the "did the bootstrap forget a service" sweep would false-red
-- on the two cross-cutting infra services the contract pass constructs in Context.build.
local CTX_BOOTED_SERVICES: { [string]: string } = {
	AnalyticsService = "context.analytics",
	EconomyService = "context.economy",
}

-- Budgets. Every wait in this file is BOUNDED: an unbounded `WaitForChild` is one of the exact
-- run-only defects this rung exists to catch, and hanging inside the detector would leave no line
-- at all — which reads as red, but with no diagnosis.
local MOUNT_WAIT_SECONDS = 20
local PRIOR_BOOT_WAIT_SECONDS = 20
local PLAYER_WAIT_SECONDS = 25
local SESSION_WAIT_SECONDS = 25
-- Salvage's starter fleet pulls STARTER_DRONES * DRONE_RATE = 0.5 Credits/second and the smelter
-- accrual is stamped in whole `os.time()` seconds, so this has to be comfortably more than 1s for
-- the collect to be worth more than rounding.
local ACCRUAL_WAIT_SECONDS = 8
-- Hard deadline measured on os.time() — the WALL clock. `os.clock()` on Roblox is Lua-VM CPU time
-- (see src/server/data/Clock.luau's own note) and does not advance across a `task.wait`, so a
-- deadline built on it would never fire.
local DEADLINE_SECONDS = 300
local STARTED_AT_UNIX = os.time()

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — THE VERDICT (fail-closed)
-- ════════════════════════════════════════════════════════════════════════════════════════════════

type PhaseState = {
	name: string,
	passes: { string },
	failures: { string },
	notes: { string },
	ok: boolean,
}

-- PINNED. The smoke-gate INGEST mode requires all four names present and ok to record T2-green; a
-- missing or renamed phase fails closed to T2-red.
local PHASE_ORDER = { "boot-probe", "wire-present", "core-loop", "assert-no-error" }

local phases: { [string]: PhaseState } = {}
local emitted = false

local function newPhase(name: string): PhaseState
	local state: PhaseState = { name = name, passes = {}, failures = {}, notes = {}, ok = false }
	phases[name] = state
	return state
end

local function pass(state: PhaseState, message: string): ()
	table.insert(state.passes, message)
end

local function fail(state: PhaseState, message: string): ()
	table.insert(state.failures, message)
end

local function note(state: PhaseState, message: string): ()
	table.insert(state.notes, message)
end

-- `cond` true records a pass, false records a failure. There is deliberately no way for a phase body
-- to write its own `ok`: the verdict is derived from what was observed, never declared.
local function check(state: PhaseState, cond: boolean, label: string, detail: string?): boolean
	local suffix = if detail ~= nil then ": " .. detail else ""
	if cond then
		pass(state, label .. suffix)
	else
		fail(state, label .. suffix)
	end
	return cond
end

local function say(message: string): ()
	print("[T2] " .. message)
end

local function budgetExhausted(): boolean
	return (os.time() - STARTED_AT_UNIX) >= DEADLINE_SECONDS
end

-- Bounded wait that also respects the run deadline, so a slow engine cannot push the emit past it.
local function waitFor(seconds: number, step: number, predicate: () -> boolean): boolean
	local deadline = os.time() + seconds
	while true do
		if predicate() then
			return true
		end
		if os.time() >= deadline or budgetExhausted() then
			return false
		end
		task.wait(step)
	end
end

local function runPhase(name: string, body: (PhaseState) -> ()): PhaseState
	local state = newPhase(name)
	local ok, err = pcall(body, state)
	if not ok then
		fail(state, "the phase body THREW (this is a defect, not a skip): " .. tostring(err))
	end
	-- ZERO PASSES IS RED. A phase that asserted nothing verified nothing; every vacuity defect in
	-- this factory's corpus was a lane reporting green having observed nothing.
	if #state.passes == 0 then
		fail(state, "the phase recorded ZERO passing assertions — it observed nothing")
	end
	state.ok = #state.failures == 0
	say(
		`── phase "{name}" -> {if state.ok then "OK" else "FAIL"}  ({#state.passes} pass, {#state.failures} fail)`
	)
	for _, message in state.notes do
		say("    note: " .. message)
	end
	for _, message in state.passes do
		say("    pass: " .. message)
	end
	for _, message in state.failures do
		say("    FAIL: " .. message)
	end
	return state
end

-- THE ONE LINE. Built by plain concatenation rather than JSONEncode: the encoder can raise, and a
-- verdict line that failed to encode is indistinguishable from a crash. Shape is pinned by the
-- ingest contract; do not "improve" it.
local function emitVerdict(): ()
	if emitted then
		return
	end
	emitted = true
	local parts: { string } = {}
	local allOk = true
	for _, name in PHASE_ORDER do
		local state = phases[name]
		local ok = state ~= nil and state.ok == true
		if not ok then
			allOk = false
		end
		table.insert(parts, '{"name":"' .. name .. '","ok":' .. tostring(ok) .. "}")
	end
	print('{"tier":2,"ok":' .. tostring(allOk) .. ',"phases":[' .. table.concat(parts, ",") .. "]}")
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — LOG CAPTURE (connected FIRST, before anything can throw)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- Phase 3's "zero errors" claim is only as good as the moment this connection is made, so it is made
-- at the top of the file. In Play mode this script and the real `init.server` Script start together
-- and `Context.build`'s DataStore capability probe alone takes seconds, so effectively the whole
-- boot is covered — but an error raised in the handful of instructions before this line would be
-- missed, and that is stated rather than glossed.

local MAX_CAPTURED = 400
local logErrors: { string } = {}
local logWarnings: { string } = {}

local logConnection = LogService.MessageOut:Connect(function(message: string, messageType: any): ()
	if messageType == Enum.MessageType.MessageError then
		if #logErrors < MAX_CAPTURED then
			table.insert(logErrors, message)
		end
	elseif messageType == Enum.MessageType.MessageWarning then
		if #logWarnings < MAX_CAPTURED then
			table.insert(logWarnings, message)
		end
	end
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — BOOT STATE + SHARED HELPERS
-- ════════════════════════════════════════════════════════════════════════════════════════════════

local BOOT = {
	priorBoot = false, -- did the place's own init.server already boot before we did?
	monoAdvances = false, -- does the Gate's rate window actually refill in this lane?
	sourceRead = false,
	bootTokens = {} :: { string }, -- the ordered `local services = { ... }` entries, PARSED
	serviceFolders = {} :: { [string]: string }, -- ServiceName -> services/<folder>, PARSED
	frameworkModules = {} :: { [string]: boolean }, -- framework module names, PARSED
	server = nil :: any,
	shared = nil :: any,
	context = nil :: any,
	Net = nil :: any,
	Result = nil :: any,
	Types = nil :: any,
	net = nil :: any,
	registry = nil :: any,
	gate = nil :: any,
	data = nil :: any,
	started = false,
}

-- Every dispatch this run made, for phase 3's envelope audit. A reply that never appears here is a
-- reply nothing looked at.
type WireRecord = { action: string, reply: any, threw: string? }
local wireLog: { WireRecord } = {}

local function codeOf(reply: any): string
	if type(reply) ~= "table" then
		return "<not-a-Result:" .. type(reply) .. ">"
	end
	if reply.ok == true then
		return "ok"
	end
	if reply.ok == false then
		return tostring(reply.code)
	end
	return "<no-ok-field>"
end

local function shortJson(value: any): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(value)
	end)
	if ok and type(encoded) == "string" then
		if #encoded > 400 then
			return string.sub(encoded, 1, 400) .. "…"
		end
		return encoded
	end
	return "<unencodable " .. type(value) .. ">"
end

-- THE dispatch. Goes through the SAME `Net.dispatch`, the SAME registry, the SAME Gate and the SAME
-- `NetServer:actionContext` projection the live `OnServerInvoke` closure uses — which is what makes
-- a reply here evidence about the wire rather than about a test harness.
local function dispatch(player: any, actionName: string, payload: any): any
	if not BOOT.started or BOOT.net == nil or BOOT.Net == nil then
		local record: WireRecord =
			{ action = actionName, reply = nil, threw = "dispatched before a successful boot" }
		table.insert(wireLog, record)
		return nil
	end
	local ok, reply = pcall(function(): any
		local ctx = (BOOT.net :: any):actionContext(player)
		return (BOOT.Net :: any).dispatch(BOOT.registry, BOOT.gate, ctx, actionName, payload)
	end)
	if not ok then
		table.insert(wireLog, { action = actionName, reply = nil, threw = tostring(reply) })
		return nil
	end
	table.insert(wireLog, { action = actionName, reply = reply })
	return reply
end

local function isOk(reply: any): boolean
	return type(reply) == "table" and reply.ok == true
end

local function valueOf(reply: any): any
	if isOk(reply) then
		return (reply :: any).value
	end
	return nil
end

-- The PERSISTED, CLIENT-FACING view — `Types.toView` of the live blob, i.e. exactly what the game
-- pushes to the HUD. Read through this rather than off the raw blob so the balance assertions are
-- about the surface the player actually sees.
local function viewOf(player: any): any?
	if BOOT.data == nil or BOOT.Types == nil then
		return nil
	end
	local ok, view = pcall(function(): any
		local got = (BOOT.data :: any):get(player)
		if type(got) ~= "table" or got.ok ~= true then
			return nil
		end
		return (BOOT.Types :: any).toView(got.value)
	end)
	if not ok then
		return nil
	end
	return view
end

local function creditsOf(player: any): number?
	local view = viewOf(player)
	if type(view) ~= "table" or type(view.currencies) ~= "table" then
		return nil
	end
	local credits = view.currencies.Credits
	if type(credits) ~= "number" or credits ~= credits then
		return nil
	end
	return credits
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — PHASE 0: boot-probe
-- ════════════════════════════════════════════════════════════════════════════════════════════════

local function stripComment(line: string): string
	local code = string.gsub(line, "%-%-.*$", "")
	return code
end

-- Pull `require(Server.services.<folder>.<Name>)` out of the entrypoint Source. The PATHS come from
-- the real bootstrap, not from a list maintained here — a hand-kept mirror is precisely what let the
-- predecessor smoke boot nothing and stay green.
local function parseServiceRequires(source: string): { [string]: string }
	local map: { [string]: string } = {}
	for folder, name in string.gmatch(source, "require%(Server%.services%.([%w_]+)%.([%w_]+)%)") do
		if map[name] == nil then
			map[name] = folder
		end
	end
	return map
end

local function parseFrameworkRequires(source: string): { [string]: boolean }
	local found: { [string]: boolean } = {}
	for name in string.gmatch(source, "require%(Server%.framework%.([%w_]+)%)") do
		found[name] = true
	end
	return found
end

-- Parse the ORDERED `local services = { ... }` block. Order is a deliverable here, not decoration:
-- PlayerLifecycle must Start before DataService and AnalyticsService or the pinned PlayerRemoving
-- sequence silently unhooks, and NetServer must Start before anything registers an action.
local function parseBootOrder(source: string): ({ string }, string?)
	local blockStart = string.find(source, "local services = {", 1, true)
	if blockStart == nil then
		return {}, "the entrypoint Source has no `local services = {` block — the idiom drifted"
	end
	local blockEnd = string.find(source, "\n}", blockStart, true)
	if blockEnd == nil then
		return {}, "the `local services = {` block is never closed by a line-initial `}`"
	end
	local block = string.sub(source, blockStart, blockEnd)
	local tokens: { string } = {}
	for line in string.gmatch(block, "[^\n]+") do
		local token = string.match(stripComment(line), "^%s*([%w_%.]+)%s*,")
		if token ~= nil then
			table.insert(tokens, token)
		end
	end
	return tokens, nil
end

local function resolveBootToken(token: string): (any, string?)
	if string.sub(token, 1, 8) == "context." then
		local field = string.sub(token, 9)
		local object = (BOOT.context :: any)[field]
		if object == nil then
			return nil,
				`the bootstrap boots \`{token}\`, but Context.build left that field NIL — the service would never Start`
		end
		return object, nil
	end
	if BOOT.frameworkModules[token] then
		return require(((BOOT.server :: any).framework :: any)[token]), nil
	end
	local folder = BOOT.serviceFolders[token]
	if folder == nil then
		return nil,
			`\`{token}\` is in the bootstrap's services list, but the entrypoint has no matching \`require(Server.services.<folder>.{token})\``
	end
	return require((((BOOT.server :: any).services :: any)[folder] :: any)[token]), nil
end

local function phaseBootProbe(state: PhaseState): ()
	-- (a) Was the place's own bootstrap already running? In Play/Run mode `init.server` boots too,
	-- so this run is a SECOND boot: `NetServer.Start` find-or-creates the remotes and REBINDS
	-- OnServerInvoke, so our context ends up owning the live wire, which is what the later phases
	-- assert against. Recorded, never treated as a failure — and the RUNBOOK explains why the place
	-- must be opened with Studio API access OFF (two DataService instances against a real
	-- SessionStore would steal each other's lock and kick the player).
	if RunService:IsRunning() then
		BOOT.priorBoot = waitFor(PRIOR_BOOT_WAIT_SECONDS, 0.25, function(): boolean
			return ReplicatedStorage:FindFirstChild(REMOTE_FUNCTION_NAME) ~= nil
		end)
		if BOOT.priorBoot then
			-- Let the place's own feature Starts finish before ours resets shared module state.
			task.wait(2)
		end
		note(
			state,
			`the place's own init.server bootstrap {if BOOT.priorBoot
				then "HAD already booted (this is the second boot; ours rebinds the remotes and wins)"
				else "did NOT boot within the budget (this is the only boot)"}`
		)
	else
		note(state, "edit mode: scripts do not auto-run, so this is the only bootstrap")
	end

	-- (b) Measure whether the Gate's monotonic source actually advances here. `Clock.real(time)`
	-- feeds `mono()` from the Roblox `time` global, and under some automated lanes it is FROZEN —
	-- in which case every rate bucket refills at zero and a burst is shed forever. Later phases stay
	-- inside every per-action budget so this cannot silently red them; it is recorded so a reader
	-- knows which lane produced the evidence.
	local monoBefore = time()
	task.wait(0.5)
	BOOT.monoAdvances = (time() - monoBefore) > 0.25
	note(
		state,
		`server mono clock (time()) {if BOOT.monoAdvances
			then "ADVANCES"
			else "IS FROZEN — rate buckets never refill in this lane"}`
	)

	-- (c) The mounts. Bounded: an infinite WaitForChild is one of the defects this rung exists to
	-- catch, and hanging here would produce no verdict line at all.
	local server = ServerScriptService:WaitForChild(SERVER_MOUNT, MOUNT_WAIT_SECONDS)
	if
		not check(
			state,
			server ~= nil,
			"ServerScriptService." .. SERVER_MOUNT .. " exists",
			`never appeared within {MOUNT_WAIT_SECONDS}s — the Rojo server mount is missing`
		)
	then
		return
	end
	local shared = ReplicatedStorage:WaitForChild(SHARED_MOUNT, MOUNT_WAIT_SECONDS)
	if
		not check(
			state,
			shared ~= nil,
			"ReplicatedStorage." .. SHARED_MOUNT .. " exists",
			`never appeared within {MOUNT_WAIT_SECONDS}s — the Rojo shared mount is missing`
		)
	then
		return
	end
	BOOT.server = server
	BOOT.shared = shared

	-- (d) The entrypoint's own Source. Rojo's init-collapse rule makes `src/server/init.server.luau`
	-- the `Server` Script itself, so `Server.Source` IS the bootstrap. UNREADABLE IS A FAIL, never
	-- "unchecked": writing "I could not check this" into a passing run is how a lane rots.
	local sourceOk, source = pcall(function(): string
		return (server :: any).Source
	end)
	if
		not check(
			state,
			sourceOk and type(source) == "string" and #source > 0,
			"the entrypoint Source is readable",
			"could not read ServerScriptService."
				.. SERVER_MOUNT
				.. ".Source — the boot order cannot be verified, which is a FAIL"
		)
	then
		return
	end
	BOOT.sourceRead = true
	BOOT.serviceFolders = parseServiceRequires(source)
	BOOT.frameworkModules = parseFrameworkRequires(source)

	local tokens, orderProblem = parseBootOrder(source)
	if
		not check(
			state,
			orderProblem == nil and #tokens > 0,
			"the bootstrap's ordered service list parses",
			orderProblem
				or "the `local services` block yielded ZERO entries — a zero-service boot verifies nothing"
		)
	then
		return
	end
	BOOT.bootTokens = tokens
	note(state, `bootstrap order ({#tokens}): {table.concat(tokens, " -> ")}`)

	-- The order facts that are load-bearing and belong to no single feature (AMENDMENT A10b + §2.2).
	local indexOf: { [string]: number } = {}
	for index, token in tokens do
		indexOf[token] = index
	end
	check(
		state,
		indexOf["PlayerLifecycle"] ~= nil
			and indexOf["context.data"] ~= nil
			and indexOf["PlayerLifecycle"] < indexOf["context.data"],
		"PlayerLifecycle Starts BEFORE DataService",
		"the pinned PlayerRemoving order (session_end -> plot release -> data release) only holds while PlayerLifecycle claims the signal first"
	)
	check(
		state,
		indexOf["context.net"] ~= nil and indexOf["context.net"] <= 2,
		"NetServer Starts before any feature registers an action",
		`context.net is at position {tostring(indexOf["context.net"])}`
	)

	-- (e) THE BOOT. Everything above was preparation; this is the assertion. Any cross-service
	-- require that resolves under Lune and not in Roblox throws HERE, at the first require.
	local bootOk, bootErr = pcall(function(): ()
		local Context = require((server :: any).Context) :: any
		local Bootstrap = require((server :: any).framework.Bootstrap) :: any
		BOOT.Net = require((shared :: any).Net) :: any
		BOOT.Result = require((shared :: any).Result) :: any
		BOOT.Types = require((shared :: any).Types) :: any

		BOOT.context = Context.build()

		local services: { any } = {}
		for _, token in BOOT.bootTokens do
			local object, problem = resolveBootToken(token)
			if problem ~= nil then
				error(problem)
			end
			if object == nil then
				error(`the bootstrap token \`{token}\` resolved to nil`)
			end
			table.insert(services, object)
		end

		Bootstrap.start(services, BOOT.context)
	end)

	if
		not check(
			state,
			bootOk,
			"the REAL bootstrap boots (Context.build + Bootstrap.start over the real order)",
			tostring(bootErr)
		)
	then
		-- `Bootstrap.start` re-raises as: Bootstrap.start: service "<Name>" failed to Start: <err>
		local failing = string.match(tostring(bootErr), 'service "([%w_]+)" failed to Start')
		if failing ~= nil then
			note(state, `the failing service is: {failing}`)
		end
		return
	end

	BOOT.started = true
	BOOT.net = (BOOT.context :: any).net
	BOOT.data = (BOOT.context :: any).data
	BOOT.gate = (BOOT.context :: any).gate
	BOOT.registry = (BOOT.net :: any)._registry

	check(state, BOOT.net ~= nil, "context.net is populated after boot")
	check(state, BOOT.data ~= nil, "context.data is populated after boot")
	check(state, BOOT.gate ~= nil, "context.gate is populated after boot")
	check(
		state,
		(BOOT.context :: any).analytics ~= nil and (BOOT.context :: any).economy ~= nil,
		"the cross-cutting ctx seams (analytics, economy) are non-nil from t0"
	)
	check(
		state,
		(BOOT.context :: any).plot ~= nil
			and (BOOT.context :: any).salvage ~= nil
			and (BOOT.context :: any).depth ~= nil,
		"the Deep Reach feature seams (plot, salvage, depth) were installed at Start",
		"a seam declared and never assigned is a nil every handler silently falls through"
	)
	note(
		state,
		`persistenceDegraded = {tostring((BOOT.context :: any).persistenceDegraded)} (true == the in-memory MockStore; expected with Studio API access OFF)`
	)

	-- (f) DID THE BOOTSTRAP FORGET A SERVICE? The set-diff the predecessor smoke did not have. A
	-- module that exists in the tree and is never booted is invisible to every static gate and to
	-- every one of this game's Lune tests.
	local servicesFolder = (server :: any):FindFirstChild("services")
	if servicesFolder ~= nil then
		local booted: { [string]: boolean } = {}
		for _, token in BOOT.bootTokens do
			booted[token] = true
		end
		local orphans: { string } = {}
		for _, instance in servicesFolder:GetDescendants() do
			if instance:IsA("ModuleScript") and string.match(instance.Name, "Service$") ~= nil then
				local viaCtx = CTX_BOOTED_SERVICES[instance.Name]
				local isBooted = booted[instance.Name] == true
					or (viaCtx ~= nil and booted[viaCtx] == true)
				if not isBooted then
					table.insert(orphans, instance:GetFullName())
				end
			end
		end
		table.sort(orphans)
		check(
			state,
			#orphans == 0,
			"every *Service module under services/ is actually booted",
			`NEVER BOOTED: {table.concat(orphans, ", ")} — it exists in the tree, and no static gate can see that nothing Starts it`
		)
	else
		fail(
			state,
			`{(server :: any):GetFullName()}.services does not exist — there is nothing to boot`
		)
	end
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — PHASE 1: wire-present
-- ════════════════════════════════════════════════════════════════════════════════════════════════

local function phaseWirePresent(state: PhaseState): ()
	if not BOOT.started then
		fail(state, "the boot failed, so there is no live wire to inspect (see phase boot-probe)")
		return
	end

	local remoteFunction = ReplicatedStorage:FindFirstChild(REMOTE_FUNCTION_NAME)
	local remoteEvent = ReplicatedStorage:FindFirstChild(REMOTE_EVENT_NAME)

	check(
		state,
		remoteFunction ~= nil and remoteFunction:IsA("RemoteFunction"),
		`ReplicatedStorage.{REMOTE_FUNCTION_NAME} exists and is a RemoteFunction`,
		`found: {if remoteFunction == nil then "nil" else remoteFunction.ClassName}`
	)
	check(
		state,
		remoteEvent ~= nil and remoteEvent:IsA("RemoteEvent"),
		`ReplicatedStorage.{REMOTE_EVENT_NAME} exists and is a RemoteEvent`,
		`found: {if remoteEvent == nil then "nil" else remoteEvent.ClassName}`
	)

	-- IDENTITY, not mere existence. In Play mode the place's own init.server may have created these
	-- already; asserting only "a RemoteFunction named CoreGateway exists" would pass on THAT boot's
	-- remotes while this boot's NetServer had bound nothing at all.
	check(
		state,
		rawequal((BOOT.net :: any)._remoteFunction, remoteFunction),
		"the RemoteFunction in ReplicatedStorage IS the one this boot's NetServer.Start bound",
		"this boot's NetServer holds a different (or no) RemoteFunction — Start did not wire the live remote"
	)
	check(
		state,
		rawequal((BOOT.net :: any)._remoteEvent, remoteEvent),
		"the RemoteEvent in ReplicatedStorage IS the one this boot's NetServer.Start bound"
	)

	-- OnServerInvoke is a CALLBACK property and reading one is not reliably supported; recorded as a
	-- diagnostic, never as a gate, so an engine that refuses the read cannot false-red this phase.
	local readOk, callback = pcall(function(): any
		return (remoteFunction :: any).OnServerInvoke
	end)
	note(
		state,
		`OnServerInvoke read: {if not readOk
			then "REFUSED by the engine (expected; callbacks are write-only)"
			elseif type(callback) == "function" then "bound to a function"
			else "readable but " .. type(callback)}`
	)

	-- THE REGISTRY. Every service must have registered its contract-named action on the LIVE
	-- registry — the one the OnServerInvoke closure dispatches into.
	local registry = BOOT.registry
	if not check(state, registry ~= nil, "NetServer holds a live action registry") then
		return
	end

	local registered: { [string]: boolean } = {}
	local registeredNames = (registry :: any):names()
	for _, name in registeredNames do
		registered[name] = true
	end

	local expected: { string } = {}
	for _, actionName in (BOOT.Net :: any).Actions do
		table.insert(expected, actionName)
	end
	table.sort(expected)

	check(
		state,
		#expected > 0,
		"Net.Actions declares at least one action",
		"an empty action set would make every assertion below vacuous"
	)

	local missing: { string } = {}
	for _, actionName in expected do
		if not registered[actionName] then
			table.insert(missing, actionName)
		end
	end
	local extra: { string } = {}
	local expectedSet: { [string]: boolean } = {}
	for _, actionName in expected do
		expectedSet[actionName] = true
	end
	for _, actionName in registeredNames do
		if not expectedSet[actionName] then
			table.insert(extra, actionName)
		end
	end
	table.sort(missing)
	table.sort(extra)

	check(
		state,
		#missing == 0,
		`all {#expected} Net.Actions are registered on the live wire`,
		`NEVER REGISTERED: {table.concat(missing, ", ")} — the action name exists in the shared contract and no service put a handler behind it`
	)
	check(
		state,
		#extra == 0,
		"nothing is registered that Net.Actions does not declare",
		`UNDECLARED: {table.concat(extra, ", ")}`
	)

	-- Every registered action must be COMPLETE. A handler-less or rate-less entry would throw or
	-- bypass the bucket at the first real request.
	local malformed: { string } = {}
	for _, actionName in registeredNames do
		local action = (registry :: any):get(actionName)
		local rate = if type(action) == "table" then action.rate else nil
		local wellFormed = type(action) == "table"
			and type(action.handler) == "function"
			and type(action.validate) == "function"
			and type(rate) == "table"
			and type(rate.maxPerWindow) == "number"
			and rate.maxPerWindow > 0
			and type(rate.windowSeconds) == "number"
			and rate.windowSeconds > 0
		if not wellFormed then
			table.insert(malformed, actionName)
		end
	end
	check(
		state,
		#malformed == 0,
		"every registered action carries a handler, a validator and a non-degenerate rate policy",
		`MALFORMED: {table.concat(malformed, ", ")}`
	)

	-- Stated, not glossed: the ownership step of Net.dispatch is dead code on this wire today.
	local withOwnerOf = 0
	for _, actionName in registeredNames do
		local action = (registry :: any):get(actionName)
		if type(action) == "table" and action.ownerOf ~= nil then
			withOwnerOf += 1
		end
	end
	note(
		state,
		`{withOwnerOf} of {#registeredNames} registered actions declare \`ownerOf\` — with 0, Net.dispatch's ownership step is UNREACHABLE on the live wire (phase assert-no-error exercises gate:assertOwner directly instead)`
	)
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — PHASE 2: core-loop traversal
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- A REAL Player, if one is here. This is not a nicety: `PlotService` cross-checks presence against
-- `Players:GetPlayerByUserId`, so a synthetic `{UserId, Name}` table is CORRECTLY read as "already
-- departed" inside the claim transform and `plot.claim` returns Err(SessionClosed). The loop is
-- therefore only traversable for a player the engine actually knows about — which is why the runbook
-- says Play mode (F5).
local function awaitRealPlayer(): any?
	local found: any = nil
	waitFor(PLAYER_WAIT_SECONDS, 0.5, function(): boolean
		local players = Players:GetPlayers()
		if #players > 0 then
			found = players[1]
			return true
		end
		return false
	end)
	return found
end

local function ensureSession(state: PhaseState, player: any): boolean
	-- Our own DataService.Start task.spawns a load for every player already present, so give that a
	-- chance before forcing one: two concurrent loads for the same key are exactly the contention
	-- the session lock exists to punish.
	local loaded = waitFor(SESSION_WAIT_SECONDS, 0.5, function(): boolean
		local got = (BOOT.data :: any):get(player)
		return type(got) == "table" and got.ok == true
	end)
	if loaded then
		return true
	end
	local ok, result = pcall(function(): any
		return (BOOT.data :: any):loadSession(player)
	end)
	if not ok then
		fail(state, `DataService:loadSession THREW for {tostring(player.Name)}: {tostring(result)}`)
		return false
	end
	if type(result) ~= "table" or result.ok ~= true then
		fail(
			state,
			`DataService:loadSession refused {tostring(player.Name)}: {codeOf(result)} — no session, so no loop`
		)
		return false
	end
	return true
end

local function phaseCoreLoop(state: PhaseState): ()
	if not BOOT.started then
		fail(state, "the boot failed, so the core loop cannot be driven (see phase boot-probe)")
		return
	end
	local Actions = (BOOT.Net :: any).Actions
	local Codes = (BOOT.Result :: any).Codes

	-- ── the subject ─────────────────────────────────────────────────────────────────────────────
	local player = awaitRealPlayer()
	if player == nil then
		-- Fail LOUDLY and by name. The synthetic fallback still runs so the diagnostics are rich,
		-- but this phase must not go green on a subject the engine does not know about.
		fail(
			state,
			`no Player joined within {PLAYER_WAIT_SECONDS}s. PlotService checks presence through Players:GetPlayerByUserId, so a synthetic \{UserId, Name} table reads as ALREADY DEPARTED and plot.claim returns SessionClosed. Run this in PLAY mode (F5) — see RUNBOOK.md`
		)
		player = { UserId = 900001, Name = "T2_SMOKE_SYNTHETIC" }
		note(state, "falling back to a synthetic player for diagnostics only")
	else
		pass(state, `subject is a REAL Player: {player.Name} (UserId {player.UserId})`)
	end

	if not ensureSession(state, player) then
		return
	end
	pass(state, "the subject's session is loaded through the real DataService")

	-- ── step 1: plot.claim ──────────────────────────────────────────────────────────────────────
	-- Ok OR AlreadyClaimed is correct: in Play mode PlotService's own join hook has usually already
	-- claimed a dome for this player, and refusing a second claim is the exclusivity guarantee, not
	-- a failure. The assertion that carries the claim is the FETCH below — "the player holds a dome"
	-- is the fact, and it is read back off the wire.
	local claim = dispatch(player, Actions.ClaimPlot, {})
	check(
		state,
		isOk(claim) or codeOf(claim) == Codes.AlreadyClaimed,
		"plot.claim replies Ok (or AlreadyClaimed, the join hook having claimed first)",
		`got {codeOf(claim)} — {shortJson(claim)}`
	)
	local plotView = dispatch(player, Actions.FetchPlot, {})
	local plotInfo = valueOf(plotView)
	check(
		state,
		type(plotInfo) == "table"
			and plotInfo.held == true
			and type(plotInfo.plotId) == "string"
			and plotInfo.plotId ~= "",
		"plot.fetch reports the subject HOLDS a dome (core loop step 1 completed on the live wire)",
		`got {codeOf(plotView)} — {shortJson(plotView)}`
	)

	-- ── step 2: salvage.collect ─────────────────────────────────────────────────────────────────
	-- The first collect ARMS the session (it stamps lastTickUnix and pays out whatever was already
	-- banked, which is nothing for a fresh blob), so Insufficient here is the documented arming
	-- outcome and not a defect. The second collect, after real accrual, is the one that must pay.
	local firstCollect = dispatch(player, Actions.CollectSmelter, {})
	note(state, `first salvage.collect (arming): {codeOf(firstCollect)}`)
	check(
		state,
		isOk(firstCollect) or codeOf(firstCollect) == Codes.Insufficient,
		"salvage.collect replies with a typed Result on an un-accrued smelter",
		`got {codeOf(firstCollect)} — expected ok or Insufficient`
	)

	say(`waiting {ACCRUAL_WAIT_SECONDS}s for the smelter to accrue on the REAL server clock…`)
	task.wait(ACCRUAL_WAIT_SECONDS)

	local creditsBeforeCollect = creditsOf(player)
	local collect = dispatch(player, Actions.CollectSmelter, {})
	local collectInfo = valueOf(collect)
	local collected = if type(collectInfo) == "table"
			and type(collectInfo.collected) == "number"
		then collectInfo.collected
		else -1
	check(
		state,
		isOk(collect) and collected > 0,
		`salvage.collect pays out after {ACCRUAL_WAIT_SECONDS}s of real accrual`,
		`got {codeOf(collect)}, collected = {collected} — {shortJson(collect)}`
	)
	local creditsAfterCollect = creditsOf(player)
	check(
		state,
		type(creditsBeforeCollect) == "number"
			and type(creditsAfterCollect) == "number"
			and (creditsAfterCollect :: number) > (creditsBeforeCollect :: number),
		"the PERSISTED PlayerView Credits balance ROSE on the collect",
		`{tostring(creditsBeforeCollect)} -> {tostring(creditsAfterCollect)} (a reply that moves while the persisted view does not is the defect this rung exists to see)`
	)

	-- ── step 3: daily.claim ─────────────────────────────────────────────────────────────────────
	-- The supply drop is the honest way to reach a purchasable balance inside a smoke's budget: at
	-- 0.5 Credits/second the cheapest structure would otherwise take ~100 seconds of waiting.
	-- OnCooldown is legitimate on a store that already holds a claim from an earlier run.
	local creditsBeforeDaily = creditsOf(player)
	local daily = dispatch(player, Actions.ClaimDaily, {})
	check(
		state,
		isOk(daily) or codeOf(daily) == Codes.OnCooldown,
		"daily.claim replies Ok (or OnCooldown, the 20h window not yet open)",
		`got {codeOf(daily)} — {shortJson(daily)}`
	)
	if isOk(daily) then
		local creditsAfterDaily = creditsOf(player)
		check(
			state,
			type(creditsBeforeDaily) == "number"
				and type(creditsAfterDaily) == "number"
				and (creditsAfterDaily :: number) > (creditsBeforeDaily :: number),
			"the PERSISTED PlayerView Credits balance ROSE on the daily drop",
			`{tostring(creditsBeforeDaily)} -> {tostring(creditsAfterDaily)}`
		)
	else
		note(
			state,
			"daily.claim was on cooldown — the purchase below must be funded by accrual alone"
		)
	end

	-- ── step 4: structures.buy — THE SPEND, and the governing-value assertion ───────────────────
	-- The shop reply carries SERVER-DERIVED prices and an `affordable` flag, so the purchase target
	-- is chosen from what the server says can actually be bought rather than from a constant copied
	-- into this file.
	local shop = dispatch(player, Actions.FetchStructures, {})
	local shopInfo = valueOf(shop)
	if
		not check(
			state,
			type(shopInfo) == "table"
				and type(shopInfo.entries) == "table"
				and #shopInfo.entries > 0,
			"structures.fetch returns the server-priced catalog",
			`got {codeOf(shop)} — {shortJson(shop)}`
		)
	then
		return
	end

	-- Prefer an entry whose effect is READ BY ANOTHER SERVICE through a ctx seam — the income rate,
	-- which `salvage.fetch` reports independently. Asserting only the buy reply's own `effectDelta`
	-- would be the shop grading its own homework, and "the player paid for a number nothing reads"
	-- is the root pattern behind 66 confirmed defects in this factory.
	local RATE_MOVERS: { [string]: boolean } = { drones = true, conveyor = true }
	local target: any = nil
	for _, entry in shopInfo.entries do
		if
			type(entry) == "table"
			and entry.affordable == true
			and RATE_MOVERS[entry.key] == true
			and (target == nil or entry.nextCost < target.nextCost)
		then
			target = entry
		end
	end
	if target == nil then
		fail(
			state,
			`no income-rate structure is affordable for the subject (balance {tostring(
				creditsOf(player)
			)}). The smoke funds the purchase from the daily drop; if it was on cooldown, run against a fresh session — see RUNBOOK.md`
		)
		return
	end

	local rateBeforeReply = dispatch(player, Actions.FetchSalvage, {})
	local rateBeforeInfo = valueOf(rateBeforeReply)
	local rateBefore = if type(rateBeforeInfo) == "table"
			and type(rateBeforeInfo.rate) == "number"
		then rateBeforeInfo.rate
		else -1

	local creditsBeforeBuy = creditsOf(player)
	local buy = dispatch(player, Actions.BuyStructure, { key = target.key })
	check(
		state,
		isOk(buy),
		`structures.buy("{target.key}") is granted for the server-derived price {target.nextCost}`,
		`got {codeOf(buy)} — {shortJson(buy)}`
	)
	local creditsAfterBuy = creditsOf(player)
	check(
		state,
		type(creditsBeforeBuy) == "number"
			and type(creditsAfterBuy) == "number"
			and (creditsAfterBuy :: number) < (creditsBeforeBuy :: number),
		"the PERSISTED PlayerView Credits balance FELL on the purchase",
		`{tostring(creditsBeforeBuy)} -> {tostring(creditsAfterBuy)}`
	)

	local rateAfterReply = dispatch(player, Actions.FetchSalvage, {})
	local rateAfterInfo = valueOf(rateAfterReply)
	local rateAfter = if type(rateAfterInfo) == "table"
			and type(rateAfterInfo.rate) == "number"
		then rateAfterInfo.rate
		else -1
	check(
		state,
		rateBefore >= 0 and rateAfter > rateBefore,
		`the income rate ANOTHER service reports rose after buying "{target.key}"`,
		`salvage.fetch rate {rateBefore} -> {rateAfter}. If the save moved and this did not, the player paid for a number nothing reads`
	)

	-- ── step 5/6: depth.descend and resurface.do ────────────────────────────────────────────────
	-- A smoke cannot honestly reach a tier-2 descend or a prestige threshold: both are gated on
	-- progression this run has not earned, and MINTING currency to force them would prove nothing
	-- about the game. What IS proved here is that both handlers are reachable on the live wire and
	-- answer with their own documented refusal rather than Internal, UnknownAction or a throw.
	local ADVANCED_OK: { [string]: boolean } = {
		[Codes.PrereqUnmet] = true,
		[Codes.Insufficient] = true,
	}
	local descend = dispatch(player, Actions.Descend, {})
	check(
		state,
		isOk(descend) or ADVANCED_OK[codeOf(descend)] == true,
		"depth.descend is reachable and answers Ok or its own documented gate refusal",
		`got {codeOf(descend)} — {shortJson(descend)}`
	)
	local resurface = dispatch(player, Actions.Resurface, {})
	check(
		state,
		isOk(resurface) or ADVANCED_OK[codeOf(resurface)] == true,
		"resurface.do is reachable and answers Ok or its own documented prerequisite refusal",
		`got {codeOf(resurface)} — {shortJson(resurface)}`
	)

	-- ── the remaining read surfaces, so nothing on the wire is left untouched ───────────────────
	for _, probe in
		{
			{ name = "depth.fetch", action = Actions.FetchDepth },
			{ name = "offline.peek", action = Actions.FetchOffline },
			{ name = "resurface.fetch", action = Actions.FetchResurface },
			{ name = "leaderboard.fetch", action = Actions.FetchLeaderboard },
		}
	do
		local reply = dispatch(player, probe.action, {})
		check(
			state,
			type(reply) == "table" and reply.ok ~= nil,
			`{probe.name} replies with a well-formed Result over the live wire`,
			`got {codeOf(reply)}`
		)
	end
	local offlineClaim = dispatch(player, Actions.ClaimOffline, {})
	check(
		state,
		type(offlineClaim) == "table" and offlineClaim.ok ~= nil,
		"offline.claim replies with a well-formed Result over the live wire",
		`got {codeOf(offlineClaim)}`
	)
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 7 — PHASE 3: assert-no-error / correct-rejection
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- Is this value something the engine would actually put on a remote? Functions, userdata (Instance,
-- Vector3, …), threads, NaN/inf and cycles all break remote serialization; a Result envelope that
-- carries one comes back to the client as an error rather than as a refusal, and the refusal is
-- lost. Structural, so it holds for replies this run never happened to produce a field of.
local function auditRemoteSafe(
	value: any,
	path: string,
	depth: number,
	seen: { [any]: boolean },
	problems: { string }
): ()
	local kind = type(value)
	if kind == "string" or kind == "boolean" or kind == "nil" then
		return
	end
	if kind == "number" then
		if value ~= value then
			table.insert(problems, path .. " is NaN")
		elseif value == math.huge or value == -math.huge then
			table.insert(problems, path .. " is infinite")
		end
		return
	end
	if kind ~= "table" then
		table.insert(problems, `{path} is a {kind} — not serializable over a remote`)
		return
	end
	if depth > 12 then
		table.insert(problems, path .. " nests deeper than 12 levels")
		return
	end
	if seen[value] then
		table.insert(problems, path .. " is a CYCLE")
		return
	end
	seen[value] = true
	if getmetatable(value :: any) ~= nil then
		table.insert(problems, path .. " carries a metatable (dropped in transit)")
	end
	for key, inner in value :: any do
		local keyKind = type(key)
		if keyKind ~= "string" and keyKind ~= "number" then
			table.insert(problems, `{path} has a {keyKind} key`)
		end
		auditRemoteSafe(inner, `{path}.{tostring(key)}`, depth + 1, seen, problems)
	end
	seen[value] = nil
end

local function phaseAssertNoError(state: PhaseState): ()
	if not BOOT.started then
		fail(
			state,
			"the boot failed, so neither the log nor the rejections mean anything (see phase boot-probe)"
		)
		return
	end
	local Actions = (BOOT.Net :: any).Actions
	local Codes = (BOOT.Result :: any).Codes

	-- ── (a) zero errors across boot + loop ──────────────────────────────────────────────────────
	-- WARNINGS ARE NOT FAILURES HERE, on purpose and with the reason stated: NetServer warns once per
	-- action while the full B2 security suite is absent (14 of them, by design), and Context warns
	-- loudly when it falls back to the in-memory store — which is the EXPECTED state with Studio API
	-- access off. Errors are a different thing entirely and gate this phase.
	check(
		state,
		#logErrors == 0,
		"ZERO engine errors were logged across boot + core loop",
		`{#logErrors} error(s); first: {tostring(logErrors[1])}`
	)
	note(
		state,
		`{#logWarnings} warning(s) captured (expected: the B2-security notice per action, and the MockStore fallback notice)`
	)
	for index, warning in logWarnings do
		if index <= 5 then
			note(state, "warning: " .. string.sub(warning, 1, 160))
		end
	end

	-- No dispatch this run may have thrown ACROSS the Net boundary. `Net.dispatch` pcalls the handler
	-- and `NetServer`'s closure pcalls the dispatch, so a throw reaching us means both nets tore.
	local threw: { string } = {}
	for _, record in wireLog do
		if record.threw ~= nil then
			table.insert(threw, `{record.action}: {record.threw}`)
		end
	end
	check(
		state,
		#threw == 0,
		"no dispatch threw across the Net boundary during the core loop",
		table.concat(threw, " | ")
	)

	-- An Internal anywhere in the loop is a handler that raised and got laundered into a code.
	local internals: { string } = {}
	for _, record in wireLog do
		if codeOf(record.reply) == Codes.Internal then
			table.insert(internals, `{record.action}: {tostring((record.reply :: any).message)}`)
		end
	end
	check(
		state,
		#internals == 0,
		"no action replied Err(Internal) — nothing raised inside a handler",
		table.concat(internals, " | ")
	)

	-- ── (b) the rejection matrix — the EXACT code, over the live registry + the real Gate ───────
	-- A fresh synthetic subject: these are pure gateway assertions (lookup / validate / rate all run
	-- BEFORE the handler in Net.dispatch), so no session is required, and a separate identity keeps
	-- the core-loop player's rate buckets untouched.
	local prober = { UserId = 908001, Name = "T2_SMOKE_REJECT" }

	local matrix = {
		{
			label = "an unknown action name",
			action = "deep.reach.no.such.action",
			payload = {},
			expected = Codes.UnknownAction,
		},
		{
			label = "structures.buy with a non-table payload",
			action = Actions.BuyStructure,
			payload = "not a table",
			expected = Codes.BadType,
		},
		{
			label = "structures.buy with a non-string catalog key",
			action = Actions.BuyStructure,
			payload = { key = 123 },
			expected = Codes.BadPayload,
		},
		{
			label = "structures.buy with a CLIENT-SUPPLIED price (the classic shop exploit)",
			action = Actions.BuyStructure,
			payload = { key = "drones", cost = 0 },
			expected = Codes.BadPayload,
		},
		{
			label = "plot.claim naming a plot (the plot-claim-hijack attempt)",
			action = Actions.ClaimPlot,
			payload = { plotId = "dome_1" },
			expected = Codes.BadPayload,
		},
		{
			label = "salvage.collect carrying a client clock",
			action = Actions.CollectSmelter,
			payload = { clientTime = 1 },
			expected = Codes.BadPayload,
		},
	}

	for _, case in matrix do
		local reply = dispatch(prober, case.action, case.payload)
		check(
			state,
			codeOf(reply) == case.expected,
			`{case.label} is refused with Err({case.expected})`,
			`got {codeOf(reply)} — {shortJson(reply)}`
		)
	end

	-- OVER-RATE. `salvage.fetch` allows 10 per second and is side-effect free, so bursting it is the
	-- safe way to prove the Gate sheds. Uses its own identity: a shed bucket that leaked into the
	-- core-loop player would make a later refusal indistinguishable from a working request.
	local burster = { UserId = 908002, Name = "T2_SMOKE_BURST" }
	local sawRateLimited = false
	local dispatched = 0
	for _ = 1, 40 do
		local reply = dispatch(burster, Actions.FetchSalvage, {})
		dispatched += 1
		if codeOf(reply) == Codes.RateLimited then
			sawRateLimited = true
			break
		end
	end
	check(
		state,
		sawRateLimited,
		"an over-rate burst is shed with Err(RateLimited) by the real Gate on the real clock",
		`{dispatched} dispatches of salvage.fetch and the bucket never emptied (mono clock advancing = {tostring(
			BOOT.monoAdvances
		)})`
	)

	-- OWNERSHIP. No registered action declares `ownerOf`, so `Net.dispatch`'s ownership step cannot
	-- be reached from the wire. The helper behind it is asserted directly rather than pretending the
	-- wire covered it, and the gap is recorded where a reader will see it.
	local ownerResult = (BOOT.gate :: any):assertOwner(111, 222)
	check(
		state,
		type(ownerResult) == "table"
			and ownerResult.ok == false
			and ownerResult.code == Codes.NotOwner,
		"Gate:assertOwner refuses a mismatched owner with Err(NotOwner)",
		`got {codeOf(ownerResult)}`
	)
	note(
		state,
		"NotOwner is asserted on the Gate DIRECTLY, not over the wire: no registered action declares `ownerOf`, so Net.dispatch's ownership step is unreachable today"
	)

	-- ── (c) the Result envelope survives the wire ───────────────────────────────────────────────
	-- A server script cannot cross the client→server replication boundary — no server script can, so
	-- this is a STRUCTURAL audit of every reply this run produced rather than a real crossing. The
	-- real crossing is T2.7 (`/engine-pass`), and that is stated in RUNBOOK.md rather than implied
	-- away here.
	local problems: { string } = {}
	local audited = 0
	for _, record in wireLog do
		if type(record.reply) == "table" then
			audited += 1
			auditRemoteSafe(record.reply, record.action, 0, {}, problems)
		end
	end
	check(
		state,
		audited > 0,
		"there are replies to audit",
		"no dispatch produced a table reply — the audit below would be vacuous"
	)
	check(
		state,
		#problems == 0,
		`all {audited} Result envelopes are remote-serializable (no function/userdata/cycle/NaN, string-or-number keys only)`,
		table.concat(problems, " | ")
	)
	note(
		state,
		"this audits SERIALIZABILITY structurally; it does NOT cross a replication boundary — a server script cannot. The real crossing is T2.7 (/engine-pass)"
	)
end

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SECTION 8 — RUN
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- Each phase is independently pcall'd inside `runPhase`, so a throw becomes a FAILED PHASE rather
-- than an abort that eats the verdict. The emit is the last statement in the file; there is no path
-- that prints it early and no path that prints it twice.

say("Deep Reach — Tier-2 in-engine smoke gate starting")
say(
	`RunService:IsRunning() = {tostring(RunService:IsRunning())}, players present = {#Players:GetPlayers()}`
)

runPhase("boot-probe", phaseBootProbe)
runPhase("wire-present", phaseWirePresent)
runPhase("core-loop", phaseCoreLoop)
runPhase("assert-no-error", phaseAssertNoError)

if logConnection ~= nil then
	logConnection:Disconnect()
end

say("copy the single JSON line below and feed it to `smoke-gate` INGEST mode (see RUNBOOK.md)")
emitVerdict()
