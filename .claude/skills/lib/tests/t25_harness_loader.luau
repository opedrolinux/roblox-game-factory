--!strict
-- t25_harness_loader.luau — run THE REAL T2.5 harness template inside Lune, under engine stubs.
--
-- ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────────────────────────
-- `templates/tier2/playtest.server.luau` is a standalone Roblox Script: it opens with
-- `game:GetService(...)` and it is what decides whether a game's playtest is green/parked/red. A Lune
-- spec cannot `require` it, so the previous attempt to attack it wrote
-- `.verify_tmp/harvest/derivation-sim.luau` — self-described as "a VERBATIM RE-IMPLEMENTATION of the
-- verdict derivation". That is A MIRROR, and this factory has already been burned by exactly that:
-- the integration suite mirrored the real bootstrap instead of running it, the mirror drifted, and a
-- game shipped 313 GREEN TESTS WITHOUT BOOTING AT ALL (docs/VERIFICATION-LADDER.md §1). A mirror of
-- the verdict machine is worse still: every "the attack is now red" claim made against it is a claim
-- about the copy, and the copy goes stale silently the moment the template is fixed.
--
-- So: no copy. `@lune/luau`'s `load` compiles a source string with a caller-supplied environment. We
-- read the REAL FILE OFF DISK, slice it at a declared anchor, load it with the Roblox globals stubbed,
-- and drive `Harness.phase` / `Harness.finish` — the shipped functions, byte for byte.
--
-- ── HOW THE SLICE WORKS, AND WHY IT IS NOT A MIRROR ──────────────────────────────────────────────
-- The template's last line is `Harness.finish(ROSTER)`, and `Harness` is a file-local, so loading the
-- whole file both consumes the harness (`finished = true`) and hides it. We therefore take the source
-- from byte 1 up to the SECTION 5 banner — sections 1-4, the entire verdict derivation — and append
-- `return Harness`. Everything loaded is the real bytes; the only thing added is the return.
--
-- Two properties keep that honest, and both FAIL CLOSED (doctrine 1):
--   * the slice anchor must occur EXACTLY ONCE, and
--   * the sliced region must still contain `function Harness.phase`, `function Harness.finish` and
--     `local SENTINEL`.
-- If somebody moves the derivation below the banner, or renames it, this loader ERRORS. It never
-- quietly tests a shell. That is the drift guard, built into the mechanism rather than bolted beside
-- it — there is no hash to re-bless and no second copy to update.
--
-- A fork of the template fills in its GAME block (AUTHORING.md "HOW TO FORK" step 2 onward). Tests
-- need that too — an unfilled `BOOTSTRAP_MIRROR` is deliberately a hard blocker, so without it the
-- only reachable verdict is red. `substitutions` expresses that as an EXACT-LITERAL patch against the
-- real bytes, and an anchor matching zero or two times is an error. A fork that drifts breaks the
-- test loudly; it cannot rot quietly.
--
-- ── WHAT THE STUBS ARE, HONESTLY (doctrine 4: degrade honestly) ──────────────────────────────────
-- The Roblox globals below are a toy. They are NOT an engine and this loader does not pretend to be a
-- rung on the ladder: it cannot tell you the game boots, and nothing here replaces run-in-roblox.
-- What it does prove is the thing no engine run can prove cheaply and no mirror can prove at all —
-- that THE SHIPPED VERDICT DERIVATION TURNS RED ON THE INPUTS IT IS SUPPOSED TO TURN RED ON.
-- `laneLimits` is driven off a config table so the INVERTED lane-limit logic (red when a limit LIFTS)
-- can be exercised in both directions, which is the one thing a real run can never do on demand.
--
-- ── THE KNOWN FIDELITY GAPS, STATED RATHER THAN DISCOVERED LATER ─────────────────────────────────
-- 1. EMPTY-TABLE ENCODING. `HttpService:JSONEncode({})` emits `[]`; `@lune/serde` emits `{}`. So the
--    sentinel line produced here has `"parkedBy":{}` where a real run has `"parkedBy":[]`. Use this
--    loader to test the DERIVATION (does the verdict turn red). Do NOT use it to test the INGEST
--    side's parsing of the evidence line — for that, the artifact from a real run is the only honest
--    input, and asserting array-ness against this stub would verify the stub.
-- 2. `ensureBoot` / `invokeAs` / the world sweep are reachable but useless here: `require` is stubbed
--    to throw and the Workspace is empty, on purpose. Whether a game BOOTS is run-in-roblox's job and
--    this loader must never be cited as evidence for it.
-- 3. There is no scheduler. `WaitForChild` returns immediately rather than yielding, so a missing
--    mount surfaces as a nil rather than as the 15s timeout the template documents.
-- 4. `Harness.finish` re-asserts its own preconditions (attack A3): it calls `serverMount()` and
--    `Harness.logScan()` ITSELF, independent of whatever phases happen to be in the roster (section 5,
--    where `bootstrap-parity` and `no-log-errors` live, is never loaded by this slice). So every
--    fixture needs a real `ServerScriptService.Server` mount and a non-empty log history, or it reds
--    on the finisher's own re-check rather than on whatever the fixture actually means to test. Both
--    default to a working shape (`Options.serverMountChildren` / `Options.logHistory`); a fixture that
--    wants the ABSENT/EMPTY case asks for it explicitly.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local loader = {}

-- Repo-relative. Resolved by walking UP from the process cwd, so the spec runs from the repo root
-- (the gauntlet) or from anywhere below it. Not found == error, never a skipped check.
loader.TEMPLATE_PATH = ".claude/skills/lib/templates/tier2/playtest.server.luau"

-- The cut. Chosen because SECTION 5 is where the template stops being harness and starts being
-- game-specific phase declarations; sections 1-4 are the whole verdict machine.
local SLICE_ANCHOR = "-- SECTION 5 — THE UNIVERSAL PHASE ROSTER"

-- Non-vacuity: the slice is worthless if the derivation is not inside it. Checked every load.
local SLICE_MUST_CONTAIN = {
	"function Harness.phase",
	"function Harness.finish",
	"function Harness.bootstrapMirror",
	"local SENTINEL",
}

export type Substitution = {
	anchor: string, -- an EXACT literal that must occur exactly once in the sliced source
	replacement: string,
	why: string, -- cited in the error when the anchor stops matching
}

export type Limits = {
	serverClockAdvances: boolean,
	physicsSteps: boolean,
	hasLocalPlayer: boolean,
}

export type LogEntry = { message: string, messageType: string }

export type Options = {
	source: string?, -- pre-read source; otherwise read from `sourcePath`
	sourcePath: string?, -- defaults to loader.TEMPLATE_PATH
	substitutions: { Substitution }?,
	-- The three limits the lane measures. Defaults to the values MEASURED under run-in-roblox 0.3.0
	-- (AUTHORING.md §1): all false. Flip one to prove the inverted lane-limits logic reds.
	limits: Limits?,
	-- Defaults to one benign `MessageInfo` line so the finisher's OWN log scan (template :2066, "the
	-- finisher's OWN log scan read ZERO lines" is a hard blocker) has something to read. Pass `{}`
	-- EXPLICITLY for the fixture that proves an empty history reds the run — `or` cannot tell "you
	-- gave me nothing" from "you gave me an empty table", so the default only ever fills in a true nil.
	logHistory: { LogEntry }?,
	-- Optional raycast oracle for Harness.groundUnder: (origin, direction) -> hitName, hitY. Default
	-- is the void, because a stub that invents ground would manufacture passes.
	raycast: ((origin: any, direction: any) -> (any?, number?))?,
	-- Names declared in ServerScriptService.Server's `.Source`, in the `require(Server.services.<ns>.
	-- <Name>)` idiom BOOTSTRAP_PATTERN parses. `Harness.finish` calls `serverMount()` itself (template
	-- :2045) to re-assert bootstrap parity, so a fork with no mount at all could never even reach the
	-- phases that used to be the only thing checking this. Defaults to DEFAULT_MOUNT_CHILDREN, which is
	-- exactly what `FORK` (below) declares in `BOOTSTRAP_MIRROR`, so parity holds for free on every
	-- fixture that does not say otherwise.
	serverMountChildren: { string }?,
	-- true == build NO `Server` instance under ServerScriptService at all, so `WaitForChild` finds
	-- nothing and `serverMount()` throws exactly as it would against a fork that never mounted one.
	-- Default false: the mount is always present unless a fixture deliberately asks for its absence.
	omitServerMount: boolean?,
}

export type Sandbox = {
	Harness: any,
	env: any,
	output: { string }, -- every line the harness printed, in order
	source: string, -- the sliced source that was actually loaded
	sentinelPrefix: string, -- read OUT OF the real source, never hardcoded here
	sentinelLine: (self: Sandbox) -> string?,
	evidence: (self: Sandbox) -> any?, -- decoded evidence, or nil == RED per the consumer contract
}

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- SOURCE: read, slice, patch
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

local function resolvePath(path: string): string
	local prefix = ""
	for _ = 1, 6 do
		local candidate = prefix .. path
		if fs.isFile(candidate) then
			return candidate
		end
		prefix ..= "../"
	end
	error(
		`t25_harness_loader: could not find "{path}" from the process cwd or any of its 5 parents. `
			.. "The template is the subject under test — a missing subject is a FAILURE, not a skip."
	)
end

function loader.readTemplate(path: string?): string
	return fs.readFile(resolvePath(path or loader.TEMPLATE_PATH))
end

local function countOccurrences(haystack: string, needle: string): number
	local count, at = 0, 1
	while true do
		local found = string.find(haystack, needle, at, true)
		if found == nil then
			return count
		end
		count += 1
		at = found + #needle
	end
end

-- Slice sections 1-4 out of the real source and make `Harness` reachable. Every failure here is an
-- error, because "I loaded something that might not be the harness" is the exact shape of the bug
-- this whole file exists to avoid.
function loader.derivationSource(source: string): string
	local occurrences = countOccurrences(source, SLICE_ANCHOR)
	if occurrences ~= 1 then
		error(
			`t25_harness_loader: the slice anchor "{SLICE_ANCHOR}" occurs {occurrences} time(s) in the template, expected exactly 1. `
				.. "The template's section structure changed; re-derive the cut instead of testing whatever happens to load."
		)
	end
	local at = string.find(source, SLICE_ANCHOR, 1, true) :: number
	local sliced = string.sub(source, 1, at - 1)
	for _, required in SLICE_MUST_CONTAIN do
		if string.find(sliced, required, 1, true) == nil then
			error(
				`t25_harness_loader: the sliced region no longer contains "{required}". `
					.. "The verdict derivation moved out of sections 1-4 — this loader would be exercising a shell, which is the mirror failure wearing a new coat."
			)
		end
	end
	return sliced
		.. "\n-- appended by t25_harness_loader (the only line not from the template)\nreturn Harness\n"
end

local function applySubstitutions(source: string, substitutions: { Substitution }): string
	local out = source
	for _, sub in substitutions do
		local occurrences = countOccurrences(out, sub.anchor)
		if occurrences ~= 1 then
			error(
				`t25_harness_loader: substitution anchor occurs {occurrences} time(s), expected exactly 1.\n`
					.. `  anchor: {sub.anchor}\n  why:    {sub.why}\n`
					.. "The template drifted away from what this test patches. Fix the anchor deliberately; do not loosen the match."
			)
		end
		local at = string.find(out, sub.anchor, 1, true) :: number
		out = string.sub(out, 1, at - 1) .. sub.replacement .. string.sub(out, at + #sub.anchor)
	end
	return out
end

-- The sentinel prefix is READ OUT OF the template, not restated here. A test that hardcodes
-- `"##T25-EVIDENCE## "` keeps passing after somebody changes the constant, and the consumer contract
-- ("no sentinel line == RED") would then be verified against a string nothing emits.
local function sentinelFrom(source: string): string
	local literal = string.match(source, '\nlocal SENTINEL = "([^"]*)"')
	if literal == nil then
		error(
			't25_harness_loader: could not read `local SENTINEL = "..."` out of the template. '
				.. "The evidence contract is the thing under test; guessing its prefix would verify nothing."
		)
	end
	return literal :: string
end

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- THE STUBBED ENGINE.  A toy, and labelled as one.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

local vectorMeta: any = {}
vectorMeta.__index = function(self: any, key: string): any
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	end
	return nil
end
vectorMeta.__add = function(a: any, b: any): any
	return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, vectorMeta)
end
vectorMeta.__sub = function(a: any, b: any): any
	return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }, vectorMeta)
end
vectorMeta.__mul = function(a: any, b: any): any
	if type(a) == "number" then
		a, b = b, a
	end
	return setmetatable({ X = a.X * b, Y = a.Y * b, Z = a.Z * b }, vectorMeta)
end
vectorMeta.__eq = function(a: any, b: any): boolean
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
vectorMeta.__tostring = function(self: any): string
	return `({self.X}, {self.Y}, {self.Z})`
end

local function vector3(x: number, y: number, z: number): any
	return setmetatable({ X = x, Y = y, Z = z }, vectorMeta)
end

-- Just enough of the class tree for `IsA`, which the world sweep and the client-load phase key off.
local CLASS_PARENT: { [string]: string } = {
	Part = "BasePart",
	SpawnLocation = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	PVInstance = "Instance",
	Folder = "Instance",
	ModuleScript = "LuaSourceContainer",
	Script = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
	IntValue = "Instance",
}

local instanceMeta: any = {}

local function makeInstance(className: string): any
	local props: { [string]: any } = {
		ClassName = className,
		Name = className,
		Anchored = true,
		CanCollide = true,
		Transparency = 0,
		Position = vector3(0, 0, 0),
		Size = vector3(1, 1, 1),
		Source = "",
	}
	local self = setmetatable(
		{ _props = props, _children = {} :: { any }, _parent = nil :: any },
		instanceMeta
	)
	return self
end

local instanceMethods: { [string]: any } = {}

function instanceMethods.IsA(self: any, className: string): boolean
	local current: string? = self._props.ClassName
	while current ~= nil do
		if current == className then
			return true
		end
		current = CLASS_PARENT[current :: string]
	end
	return className == "Instance"
end

function instanceMethods.GetChildren(self: any): { any }
	return table.clone(self._children)
end

function instanceMethods.GetDescendants(self: any): { any }
	local out: { any } = {}
	for _, child in self._children do
		table.insert(out, child)
		for _, deep in instanceMethods.GetDescendants(child) do
			table.insert(out, deep)
		end
	end
	return out
end

function instanceMethods.FindFirstChild(self: any, name: string): any?
	for _, child in self._children do
		if child._props.Name == name then
			return child
		end
	end
	return nil
end

-- No yielding: this sandbox has no scheduler, and a WaitForChild that blocks forever would turn a
-- missing mount into a hang instead of a failure.
function instanceMethods.WaitForChild(self: any, name: string, _timeout: number?): any?
	return instanceMethods.FindFirstChild(self, name)
end

function instanceMethods.GetFullName(self: any): string
	local parts = { self._props.Name }
	local node = self._parent
	while node ~= nil do
		table.insert(parts, 1, node._props.Name)
		node = node._parent
	end
	return table.concat(parts, ".")
end

function instanceMethods.IsDescendantOf(self: any, other: any): boolean
	local node = self._parent
	while node ~= nil do
		if node == other then
			return true
		end
		node = node._parent
	end
	return false
end

local function detach(self: any): ()
	local parent = self._parent
	if parent == nil then
		return
	end
	for index, child in parent._children do
		if child == self then
			table.remove(parent._children, index)
			break
		end
	end
	self._parent = nil
end

function instanceMethods.Destroy(self: any): ()
	detach(self)
	self._props.Name = self._props.Name
	table.clear(self._children)
end

instanceMeta.__index = function(self: any, key: string): any
	if key == "Parent" then
		return self._parent
	end
	if key == "PrimaryPart" then
		return rawget(self, "_primaryPart")
	end
	local method = instanceMethods[key]
	if method ~= nil then
		return method
	end
	return self._props[key]
end

instanceMeta.__newindex = function(self: any, key: string, value: any): ()
	if key == "Parent" then
		detach(self)
		self._parent = value
		if value ~= nil then
			table.insert(value._children, self)
		end
		return
	end
	if key == "PrimaryPart" then
		rawset(self, "_primaryPart", value)
		return
	end
	self._props[key] = value
end

instanceMeta.__tostring = function(self: any): string
	return self._props.Name
end

local DEFAULT_LIMITS: Limits = {
	-- As MEASURED under run-in-roblox 0.3.0 and re-measured by the lane every run. Not assumed.
	serverClockAdvances = false,
	physicsSteps = false,
	hasLocalPlayer = false,
}

-- The one name every green-path fixture's mount declares and `FORK` (below) mirrors. A single shared
-- constant so the two can never drift apart the way a hand-copied literal in two places eventually
-- does.
local DEFAULT_MOUNT_CHILDREN = { "SampleService" }

-- One benign line, so `Harness.logScan`'s `scanned == 0` floor (template :2069) is never tripped by a
-- fixture that has nothing to say about logging. `MessageInfo` because it must count toward `scanned`
-- without also landing in `errors` or `unacceptedWarnings`.
local DEFAULT_LOG_HISTORY: { LogEntry } = {
	{ message = "t25_harness_loader stub: sandbox booted", messageType = "MessageInfo" },
}

-- Renders `names` into the exact `require(Server.services.<ns>.<Name>)` idiom `BOOTSTRAP_PATTERN`
-- parses (template :236). The namespace segment is arbitrary to the pattern — it only captures the
-- last component — so it is just the lowercased name; readable failures, not extra fidelity.
local function renderMountSource(names: { string }): string
	local lines: { string } = { "local services = {" }
	for _, name in names do
		table.insert(lines, `\trequire(Server.services.{string.lower(name)}.{name}),`)
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

local function buildEnvironment(options: Options, output: { string }): any
	local limits: Limits = options.limits or DEFAULT_LIMITS
	local logHistory = options.logHistory or DEFAULT_LOG_HISTORY

	local workspace = makeInstance("Workspace")
	workspace.Name = "Workspace"
	local serverScriptService = makeInstance("Folder")
	serverScriptService.Name = "ServerScriptService"
	if options.omitServerMount ~= true then
		-- Name "Server" mirrors `GAME.mounts.server`'s SHIPPED default (template :242). This loader
		-- tests the template as shipped, never a per-game fork, so that default is the right constant
		-- to assume here — same treatment the SENTINEL prefix gets, minus re-deriving it from source,
		-- because unlike the sentinel this name is not read back out of the sliced region at all.
		local serverMount = makeInstance("Script")
		serverMount.Name = "Server"
		serverMount.Source =
			renderMountSource(options.serverMountChildren or DEFAULT_MOUNT_CHILDREN)
		serverMount.Parent = serverScriptService
	end
	local replicatedStorage = makeInstance("Folder")
	replicatedStorage.Name = "ReplicatedStorage"
	local starterPlayer = makeInstance("Folder")
	starterPlayer.Name = "StarterPlayer"

	-- The frozen server clock IS the lane limit. `time()` only advances when the config says the
	-- limit has lifted, which is how the inverted lane-limits phase can be driven both ways.
	local serverClock = 0

	local players: any = {
		LocalPlayer = if limits.hasLocalPlayer then { Name = "StubLocalPlayer" } else nil,
	}

	local messageTypes = {
		MessageOutput = "MessageOutput",
		MessageInfo = "MessageInfo",
		MessageWarning = "MessageWarning",
		MessageError = "MessageError",
	}

	local logService: any = {}
	function logService.GetLogHistory(_self: any): { any }
		local out: { any } = {}
		for _, entry in logHistory do
			table.insert(out, { message = entry.message, messageType = entry.messageType })
		end
		return out
	end

	-- Roblox's JSONEncode raises on cycles / NaN / userdata; the harness sanitises first precisely so
	-- that never happens, and serde encodes what survives sanitising. Substituting the ENGINE API is
	-- the point of a sandbox; the derivation around it is the real thing.
	local httpService: any = {}
	function httpService.JSONEncode(_self: any, value: any): string
		return serde.encode("json", value)
	end
	function httpService.JSONDecode(_self: any, value: string): any
		return serde.decode("json", value)
	end

	local services: { [string]: any } = {
		HttpService = httpService,
		LogService = logService,
		Players = players,
		ReplicatedStorage = replicatedStorage,
		ServerScriptService = serverScriptService,
		StarterPlayer = starterPlayer,
		Workspace = workspace,
	}

	local gameStub: any = { JobId = "" }
	function gameStub.GetService(_self: any, name: string): any
		local service = services[name]
		if service == nil then
			error(`t25_harness_loader stub: game:GetService("{name}") is not stubbed`)
		end
		return service
	end

	-- Physics is a lane limit too. Unanchored parts under Workspace fall only when the config says
	-- the limit has lifted; otherwise `task.wait` is pure bookkeeping, exactly like edit mode.
	local function stepWorld(seconds: number): ()
		if not limits.physicsSteps then
			return
		end
		for _, inst in instanceMethods.GetDescendants(workspace) do
			if not inst._props.Anchored and inst._props.Position ~= nil then
				inst._props.Position = inst._props.Position - vector3(0, 100 * seconds, 0)
			end
		end
	end

	local taskStub: any = {}
	function taskStub.wait(seconds: number?): number
		local delta = seconds or 0
		if limits.serverClockAdvances then
			serverClock += delta
		end
		stepWorld(delta)
		return delta
	end
	function taskStub.spawn(fn: any, ...: any): ()
		fn(...)
	end
	taskStub.defer = taskStub.spawn

	local raycast = options.raycast

	function workspace.Raycast(_self: any, origin: any, direction: any, _params: any): any?
		if raycast == nil then
			return nil -- the VOID. A stub that invented ground would manufacture passes.
		end
		local name, y = (raycast :: any)(origin, direction)
		if name == nil then
			return nil
		end
		local hitInstance = makeInstance("Part")
		hitInstance.Name = name
		return { Instance = hitInstance, Position = vector3(origin.X, y or 0, origin.Z) }
	end

	local env: any = {
		game = gameStub,
		workspace = workspace,
		Instance = {
			new = function(className: string): any
				return makeInstance(className)
			end,
		},
		Vector3 = { new = vector3 },
		RaycastParams = {
			new = function(): any
				return { FilterType = nil, FilterDescendantsInstances = {} }
			end,
		},
		Enum = {
			RaycastFilterType = { Exclude = "Exclude", Include = "Include" },
			MessageType = messageTypes,
		},
		task = taskStub,
		time = function(): number
			return serverClock
		end,
		tick = function(): number
			return serverClock
		end,
		script = makeInstance("Script"),
		-- Lune's injected `require` is filesystem-relative and would resolve nothing sensible here;
		-- a sandbox that silently returned a table would let `ensureBoot` fake a successful boot.
		require = function(_module: any): any
			error(
				"t25_harness_loader stub: require() is not available in the sandbox — the sliced "
					.. "derivation must not need it. Booting a real game is run-in-roblox's job."
			)
		end,
		print = function(...: any): ()
			local parts: { string } = {}
			for index = 1, select("#", ...) do
				table.insert(parts, tostring((select(index, ...))))
			end
			table.insert(output, table.concat(parts, " "))
		end,
		warn = function(...: any): ()
			local parts: { string } = {}
			for index = 1, select("#", ...) do
				table.insert(parts, tostring((select(index, ...))))
			end
			table.insert(output, "[warn] " .. table.concat(parts, " "))
		end,
	}
	env._G = env
	return env
end

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- THE LOADER
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

function loader.load(options: Options?): Sandbox
	local opts: Options = options or {}
	local raw = opts.source or loader.readTemplate(opts.sourcePath)
	local sentinelPrefix = sentinelFrom(raw)
	local source = loader.derivationSource(raw)
	if opts.substitutions ~= nil then
		source = applySubstitutions(source, opts.substitutions :: { Substitution })
	end

	local output: { string } = {}
	local env = buildEnvironment(opts, output)
	local chunk = luau.load(source, {
		environment = env,
		debugName = "playtest.server.luau (sliced, sandboxed)",
	})
	local Harness = chunk()
	if type(Harness) ~= "table" or type(Harness.phase) ~= "function" then
		error(
			"t25_harness_loader: the sliced template did not yield a Harness table with a `phase` "
				.. "function. Refusing to report on a subject that is not the harness."
		)
	end

	local sandbox: any = {
		Harness = Harness,
		env = env,
		output = output,
		source = source,
		sentinelPrefix = sentinelPrefix,
	}

	-- THE CONSUMER CONTRACT, enforced here as it is at ingest: exactly one sentinel line, last. Two
	-- lines would let a reader pick the wrong one, so two is an error rather than a first-wins.
	function sandbox.sentinelLine(self: any): string?
		local found: string? = nil
		for _, line in self.output do
			if string.sub(line, 1, #self.sentinelPrefix) == self.sentinelPrefix then
				if found ~= nil then
					error(
						"t25_harness_loader: TWO sentinel lines were emitted; the contract is one, last"
					)
				end
				found = string.sub(line, #self.sentinelPrefix + 1)
			end
		end
		return found
	end

	-- nil is not "absent" and not "skipped": no sentinel == RED. Callers assert on that directly.
	function sandbox.evidence(self: any): any?
		local line = self:sentinelLine()
		if line == nil then
			return nil
		end
		local ok, decoded = pcall(serde.decode, "json" :: any, line)
		if not ok then
			return nil
		end
		return decoded
	end

	return sandbox :: Sandbox
end

-- The patch a FORK applies at "HOW TO FORK" step 2. Exposed because every green-path test needs it:
-- shipped, `BOOTSTRAP_MIRROR` is nil and `Harness.finish` blocks the run red by design, so without
-- this the only reachable verdict is red and a "we saw green" claim would be untestable.
function loader.filledBootstrapMirror(names: { string }): Substitution
	local rendered: { string } = {}
	for _, name in names do
		table.insert(rendered, `"{name}"`)
	end
	return {
		anchor = "local BOOTSTRAP_MIRROR: { string }? = nil",
		replacement = `local BOOTSTRAP_MIRROR: \{ string }? = \{ {table.concat(rendered, ", ")} }`,
		why = "a fork fills BOOTSTRAP_MIRROR from init.server.luau; unfilled is a deliberate hard blocker",
	}
end

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- THE DEMONSTRATION.  Driven by tests/run.luau.
--
-- Every check below runs the SHIPPED derivation. None of them restates it. The last check is the
-- load-bearing one: it mutates the derivation in an IN-MEMORY copy and asserts the observed
-- behaviour changes with it — which is the property a mirror can never have, and the reason this
-- file exists.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════

local FORK = { loader.filledBootstrapMirror(DEFAULT_MOUNT_CHILDREN) }

-- Failure detail only. A check that fails must say what it SAW, or the next agent re-derives it.
local function shortJson(value: any): string
	local ok, encoded = pcall(serde.encode, "json" :: any, value)
	return if ok then tostring(encoded) else `<unencodable {type(value)}>`
end

-- `blindTo` is now unconditionally MANDATORY on every non-structural phase (template :1746) — an
-- absent list fails the phase regardless of gating. None of the fixtures below are testing THAT rule
-- (it needs no dedicated proof: a missing declaration reds a phase the same way any other missing
-- assertion would), so they all share one harmless, always-valid claim rather than each inventing its
-- own and accidentally drifting into testing blindTo instead of whatever they actually name.
local STUB_BLIND_TO =
	{ { claim = "anything only a real client could show", becauseLimit = "hasLocalPlayer" } }

-- A phase that does everything right: discovers a subject and asserts a real before/after delta
-- through `Harness.readWorldCount` — the SHIPPED "world" mint, not a hand-rolled reader. A reader that
-- merely CLAIMS `channel = "world"` without calling the file-local `noteContact("world")` from inside
-- its own `read()` is worse than a bare `opaque` closure: `effectiveChannel` (template :448) demotes it
-- AND fails the phase outright ("a mint that touched nothing is a claim, not a measurement"). Only the
-- shipped minted readers make that call, so this helper is threaded the SANDBOX itself and drives its
-- real Workspace: `act` parents a marker Part in, `readWorldCount` counts it out.
local function healthyPhase(sandbox: Sandbox, name: string, gating: boolean, moves: boolean): any
	local tagName = `{name}-marker`
	local subjectId = `{name}-subject`
	return {
		name = name,
		gating = gating,
		minSubjects = 1,
		blindTo = STUB_BLIND_TO,
		body = function(probe: any): ()
			probe:subjects({ subjectId }, "stub subject")
			probe:delta(
				`{name} moves its value`,
				(sandbox.Harness :: any).readWorldCount(tagName, function(inst: any): boolean
					return inst.Name == tagName
				end),
				function(): ()
					if moves then
						local marker = makeInstance("Part")
						marker.Name = tagName
						marker.Parent = sandbox.env.workspace
					end
				end,
				{ direction = "up", subject = subjectId }
			)
		end,
	}
end

function loader.spec(sourcePath: string?): (number, { string })
	local checks = 0
	local failures: { string } = {}

	local function check(note: string, condition: boolean, detail: string?): ()
		checks += 1
		if not condition then
			table.insert(failures, `{note}{if detail ~= nil then `: {detail}` else ""}`)
		end
	end

	-- ── 0. the subject is the real file, and the slice really contains the machine ───────────────
	-- Read ONCE and threaded into every load below, so `spec(path)` can be pointed at a deliberately
	-- regressed copy of the template and OBSERVED GOING RED. A gate never seen red is not known to
	-- work (doctrine 3), and that applies to this file as much as to anything it checks.
	local template = loader.readTemplate(sourcePath)
	check("the real template is readable off disk", #template > 10000, `read {#template} bytes`)
	local sliced = loader.derivationSource(template)
	-- Not `example-delta`: that name legitimately appears in ROSTER back in section 2. The thing that
	-- must NOT survive the cut is section 5's phase DECLARATIONS and the terminal emit.
	check(
		"the slice drops SECTION 5's phase declarations",
		string.find(sliced, "Harness.phase({", 1, true) == nil,
		"a phase declaration leaked into the sliced region"
	)
	check(
		"the slice drops the terminal Harness.finish(ROSTER)",
		string.find(sliced, "Harness.finish(ROSTER)", 1, true) == nil,
		"the template's own emit leaked in; the harness would be spent before a test could drive it"
	)
	check(
		"the slice keeps the verdict derivation",
		string.find(sliced, "gatingPhasesPassed", 1, true) ~= nil,
		"the finish() verdict block is missing from the slice"
	)

	-- ── 1. END TO END: a healthy gating phase greens the REAL derivation ─────────────────────────
	-- `Harness.finish` now refuses fewer than MIN_SPEC_GATING_PHASES (3) spec-derived gating phases
	-- (template :2009) — the universal phases (section 5, never loaded by this slice) prove the
	-- HARNESS works, not the GAME, so one custom phase alone can never claim green. Pad to 3.
	local green = loader.load({ source = template, substitutions = FORK })
	green.Harness.phase(healthyPhase(green, "delta-ok", true, true))
	green.Harness.phase(healthyPhase(green, "delta-ok-2", true, true))
	green.Harness.phase(healthyPhase(green, "delta-ok-3", true, true))
	green.Harness.finish({ "delta-ok", "delta-ok-2", "delta-ok-3" })
	local greenEvidence = green:evidence()
	check("a healthy run emits a sentinel line", greenEvidence ~= nil, "no sentinel == RED")
	if greenEvidence ~= nil then
		check(
			"a healthy gating phase yields verdict green",
			greenEvidence.verdict == "green",
			`verdict={tostring(greenEvidence.verdict)} blockers={shortJson(greenEvidence.blockers)}`
		)
		check(
			"`ok` agrees with the verdict (a disagreement is a MALFORMED artifact)",
			greenEvidence.ok == true,
			tostring(greenEvidence.ok)
		)
		check(
			"the evidence carries the schema tag",
			greenEvidence["$schema"] == "verification-evidence/1"
		)
		check(
			"the evidence carries the tier",
			greenEvidence.tier == 2.5,
			tostring(greenEvidence.tier)
		)
	end

	-- ── 2. the delta is the verdict: the SAME phase whose act moves nothing is RED ───────────────
	-- Doctrine 5. This pair is the whole point: identical shape, identical subjects, identical
	-- dispatch — the only difference is whether the value the phase promised actually MOVED.
	local red = loader.load({ source = template, substitutions = FORK })
	red.Harness.phase(healthyPhase(red, "delta-flat", true, false))
	red.Harness.finish({ "delta-flat" })
	local redEvidence = red:evidence()
	check("a flat-delta run still emits evidence", redEvidence ~= nil)
	if redEvidence ~= nil then
		check(
			"a phase whose value did NOT move is red",
			redEvidence.verdict == "red" and redEvidence.gatingPhasesPassed == false,
			`verdict={tostring(redEvidence.verdict)}`
		)
	end

	-- ── 3. NON-VACUITY: zero subjects is red, never a quiet pass (doctrine 2) ────────────────────
	local vacuous = loader.load({ source = template, substitutions = FORK })
	vacuous.Harness.phase({
		name = "found-nothing",
		gating = true,
		minSubjects = 1,
		body = function(_probe: any): () end,
	})
	vacuous.Harness.finish({ "found-nothing" })
	local vacuousEvidence = vacuous:evidence()
	check("a zero-subject run emits evidence", vacuousEvidence ~= nil)
	if vacuousEvidence ~= nil then
		check(
			"a phase that discovered NOTHING is red",
			vacuousEvidence.verdict == "red",
			tostring(vacuousEvidence.verdict)
		)
		check(
			"and it says WHY (discovery found nothing)",
			string.find(vacuousEvidence.phases[1].detail, "discovery found nothing", 1, true) ~= nil,
			tostring(vacuousEvidence.phases[1].detail)
		)
	end

	-- ── 4. `probe:expect` alone can never green a phase ──────────────────────────────────────────
	local shapeOnly = loader.load({ source = template, substitutions = FORK })
	shapeOnly.Harness.phase({
		name = "shape-only",
		gating = true,
		minSubjects = 1,
		blindTo = STUB_BLIND_TO,
		body = function(probe: any): ()
			probe:subjects({ "thing-a", "thing-b", "thing-c" }, "things that exist")
			probe:expect("they exist", true, "and nothing was moved")
		end,
	})
	shapeOnly.Harness.finish({ "shape-only" })
	local shapeEvidence = shapeOnly:evidence()
	if shapeEvidence ~= nil then
		check(
			"shape checks with zero deltas cannot green a phase",
			shapeEvidence.verdict == "red",
			tostring(shapeEvidence.verdict)
		)
	else
		check("shape-only run emits evidence", false, "no sentinel")
	end

	-- ── 5. `deltasRequired = false` is refused outside the three structural phases ───────────────
	local sneaky = loader.load({ source = template, substitutions = FORK })
	sneaky.Harness.phase({
		name = "not-structural",
		gating = true,
		minSubjects = 1,
		deltasRequired = false,
		blindTo = STUB_BLIND_TO,
		body = function(probe: any): ()
			probe:subjects({ "not-structural-subject" }, "subject")
		end,
	})
	sneaky.Harness.finish({ "not-structural" })
	local sneakyEvidence = sneaky:evidence()
	if sneakyEvidence ~= nil then
		check(
			"an ordinary phase cannot opt out of the delta requirement",
			sneakyEvidence.verdict == "red",
			tostring(sneakyEvidence.verdict)
		)
	else
		check("opt-out run emits evidence", false, "no sentinel")
	end

	-- ── 6. `probe:unmeasurable` disqualifies green and never decorates a pass ────────────────────
	local unmeasured = loader.load({ source = template, substitutions = FORK })
	unmeasured.Harness.phase({
		name = "cannot-check",
		gating = false,
		minSubjects = 1,
		blindTo = STUB_BLIND_TO,
		body = function(probe: any): ()
			probe:subjects({ "cannot-check-subject" }, "subject")
			probe:unmeasurable("the client HUD", "there is no LocalPlayer in this lane")
		end,
	})
	-- `Harness.finish` refuses fewer than MIN_SPEC_GATING_PHASES (3) spec-derived GATING phases
	-- regardless of what parks the run, so a lone non-gating phase would red on the count floor
	-- rather than park on the thing this test is actually about. Pad with three healthy gating
	-- phases so the unmeasurable claim is the ONLY reason left standing.
	unmeasured.Harness.phase(healthyPhase(unmeasured, "cannot-check-gate-a", true, true))
	unmeasured.Harness.phase(healthyPhase(unmeasured, "cannot-check-gate-b", true, true))
	unmeasured.Harness.phase(healthyPhase(unmeasured, "cannot-check-gate-c", true, true))
	unmeasured.Harness.finish({
		"cannot-check",
		"cannot-check-gate-a",
		"cannot-check-gate-b",
		"cannot-check-gate-c",
	})
	local unmeasuredEvidence = unmeasured:evidence()
	if unmeasuredEvidence ~= nil then
		check(
			"an unmeasurable claim on a NON-gating phase parks the run",
			unmeasuredEvidence.verdict == "parked",
			tostring(unmeasuredEvidence.verdict)
		)
		check(
			"and `ok` is false while parked (parked is not green)",
			unmeasuredEvidence.ok == false,
			tostring(unmeasuredEvidence.ok)
		)
	else
		check("unmeasurable run emits evidence", false, "no sentinel")
	end

	-- The non-gating case above parks for TWO independent reasons (the phase failed, and
	-- `unverified-claims-present`), so on its own it cannot tell the PHASE-level clause
	-- `#state.unmeasurable == 0` from the finish-level one. Deleting the phase-level clause from the
	-- real source left that check green — found by running this spec against a mutant. A GATING
	-- phase separates them: only the phase-level clause can turn "I could not check this" into a
	-- gating failure, and a gating failure is red rather than parked.
	local unmeasuredGating = loader.load({ source = template, substitutions = FORK })
	unmeasuredGating.Harness.phase({
		name = "cannot-check-gating",
		gating = true,
		minSubjects = 1,
		blindTo = STUB_BLIND_TO,
		body = function(probe: any): ()
			probe:subjects({ "cannot-check-gating-subject" }, "subject")
			-- A real "world" mint (nothing is ever parented under this tag, so the count never moves):
			-- a hand-rolled `{channel = "world", read = ...}` never calls the file-local `noteContact`,
			-- and `effectiveChannel` (template :448) demotes an untouched mint to opaque AND fails the
			-- phase — which would confound this test with the very floor it exists to isolate FROM.
			probe:delta(
				"a real delta, so only the unmeasurable entry is in play",
				unmeasuredGating.Harness.readWorldCount(
					"cannot-check-gating-marker",
					function(inst: any): boolean
						return inst.Name == "cannot-check-gating-marker"
					end
				),
				function(): () end,
				{ direction = "unchanged", subject = "cannot-check-gating-subject" }
			)
			probe:unmeasurable("the client HUD", "there is no LocalPlayer in this lane")
		end,
	})
	unmeasuredGating.Harness.finish({ "cannot-check-gating" })
	local unmeasuredGatingEvidence = unmeasuredGating:evidence()
	if unmeasuredGatingEvidence ~= nil then
		check(
			"an unmeasurable claim FAILS its phase, so a GATING phase reds the run",
			unmeasuredGatingEvidence.verdict == "red",
			tostring(unmeasuredGatingEvidence.verdict)
		)
		check(
			"and it can never decorate a pass — the phase itself is not ok",
			unmeasuredGatingEvidence.phases[1].ok == false,
			tostring(unmeasuredGatingEvidence.phases[1].detail)
		)
	else
		check("gating-unmeasurable run emits evidence", false, "no sentinel")
	end

	-- ── 7. the two-sided roster diff ─────────────────────────────────────────────────────────────
	-- Rostering ONE of two phases, rather than rostering none. An empty roster reds for its own
	-- separate reason ("a lane with no phases scores 100%"), which masked the ran-but-unrostered
	-- branch entirely — also found by running this spec against a mutant.
	local unrostered = loader.load({ source = template, substitutions = FORK })
	unrostered.Harness.phase(healthyPhase(unrostered, "listed", true, true))
	unrostered.Harness.phase(healthyPhase(unrostered, "ran-but-unlisted", true, true))
	unrostered.Harness.finish({ "listed" })
	local unrosteredEvidence = unrostered:evidence()
	if unrosteredEvidence ~= nil then
		check(
			"a phase that ran but is NOT rostered reds the run",
			unrosteredEvidence.verdict == "red",
			tostring(unrosteredEvidence.verdict)
		)
		check(
			"both phases themselves passed — the roster diff is what reds it",
			unrosteredEvidence.phases[1].ok == true and unrosteredEvidence.phases[2].ok == true,
			shortJson(unrosteredEvidence.blockers)
		)
	else
		check("unrostered run emits evidence", false, "no sentinel")
	end

	local emptyRoster = loader.load({ source = template, substitutions = FORK })
	emptyRoster.Harness.phase(healthyPhase(emptyRoster, "orphan", true, true))
	emptyRoster.Harness.finish({})
	local emptyRosterEvidence = emptyRoster:evidence()
	if emptyRosterEvidence ~= nil then
		check(
			"an EMPTY roster reds the run (a lane with no phases scores 100%)",
			emptyRosterEvidence.verdict == "red",
			tostring(emptyRosterEvidence.verdict)
		)
	else
		check("empty-roster run emits evidence", false, "no sentinel")
	end

	local ghost = loader.load({ source = template, substitutions = FORK })
	ghost.Harness.finish({ "never-declared" })
	local ghostEvidence = ghost:evidence()
	if ghostEvidence ~= nil then
		check(
			"a rostered phase that NEVER RAN reds the run",
			ghostEvidence.verdict == "red",
			tostring(ghostEvidence.verdict)
		)
	else
		check("ghost-roster run emits evidence", false, "no sentinel")
	end

	-- ── 8. the shipped template, unfilled, cannot report green ───────────────────────────────────
	local unfilled = loader.load({ source = template })
	unfilled.Harness.phase(healthyPhase(unfilled, "delta-ok", true, true))
	unfilled.Harness.finish({ "delta-ok" })
	local unfilledEvidence = unfilled:evidence()
	if unfilledEvidence ~= nil then
		check(
			"an unfilled BOOTSTRAP_MIRROR blocks the run red",
			unfilledEvidence.verdict == "red",
			tostring(unfilledEvidence.verdict)
		)
	else
		check("unfilled-template run emits evidence", false, "no sentinel")
	end

	-- ── 9. the INVERTED lane limits: a blindness claim citing a LIFTED limit is a lie ────────────
	-- Only reachable here. A real run cannot lift a limit on demand, so this branch of the shipped
	-- code had never been observed executing at all.
	local blindClaim = {
		claim = "anything the client renders",
		becauseLimit = "hasLocalPlayer",
	}
	local blindOk = loader.load({ source = template, substitutions = FORK })
	blindOk.Harness.phase({
		name = "blind-ok",
		gating = true,
		minSubjects = 1,
		blindTo = { blindClaim },
		body = function(probe: any): ()
			probe:subjects({ "blind-ok-subject" }, "subject")
			-- A real "world" mint, per the note on `unmeasuredGating` above: a hand-rolled
			-- `channel = "world"` reader that never calls `noteContact` fails outright rather than
			-- reading opaque, which would confound this test with an unrelated floor.
			probe:delta(
				"moves",
				blindOk.Harness.readWorldCount("blind-ok-marker", function(inst: any): boolean
					return inst.Name == "blind-ok-marker"
				end),
				function(): () end,
				{ direction = "unchanged", subject = "blind-ok-subject" }
			)
		end,
	})
	-- Same MIN_SPEC_GATING_PHASES floor as every other green-path fixture: pad to 3.
	blindOk.Harness.phase(healthyPhase(blindOk, "blind-ok-gate-b", true, true))
	blindOk.Harness.phase(healthyPhase(blindOk, "blind-ok-gate-c", true, true))
	blindOk.Harness.finish({ "blind-ok", "blind-ok-gate-b", "blind-ok-gate-c" })
	local blindOkEvidence = blindOk:evidence()
	if blindOkEvidence ~= nil then
		local blindOkDetail = shortJson(blindOkEvidence.blockers)
		check(
			"a blindness claim citing a limit that is STILL IN FORCE is accepted",
			blindOkEvidence.verdict == "green",
			`verdict={tostring(blindOkEvidence.verdict)} blockers={blindOkDetail}`
		)
	else
		check("blind-ok run emits evidence", false, "no sentinel")
	end

	local blindStale = loader.load({
		source = template,
		substitutions = FORK,
		limits = { serverClockAdvances = false, physicsSteps = false, hasLocalPlayer = true },
	})
	blindStale.Harness.phase({
		name = "blind-stale",
		gating = true,
		minSubjects = 1,
		blindTo = { blindClaim },
		body = function(probe: any): ()
			probe:subjects({ "blind-stale-subject" }, "subject")
			probe:delta(
				"moves",
				blindStale.Harness.readWorldCount("blind-stale-marker", function(inst: any): boolean
					return inst.Name == "blind-stale-marker"
				end),
				function(): () end,
				{ direction = "unchanged", subject = "blind-stale-subject" }
			)
		end,
	})
	blindStale.Harness.finish({ "blind-stale" })
	local blindStaleEvidence = blindStale:evidence()
	if blindStaleEvidence ~= nil then
		check(
			"the SAME claim reds the run once that limit has LIFTED",
			blindStaleEvidence.verdict == "red",
			tostring(blindStaleEvidence.verdict)
		)
		check(
			"the lane limits are reported as measured, not as assumed",
			blindStaleEvidence.laneLimits.hasLocalPlayer == true,
			shortJson(blindStaleEvidence.laneLimits)
		)
	else
		check("blind-stale run emits evidence", false, "no sentinel")
	end

	-- ── 10. the shipped bootstrap-parity regex, against a real Source string ─────────────────────
	local parity = loader.load({ source = template, substitutions = FORK })
	local entrypoint = parity.env.Instance.new("Script")
	entrypoint.Name = "Server"
	entrypoint.Source = table.concat({
		"local services = {",
		"\trequire(Server.services.collection.CollectionService),",
		"\trequire(Server.services.shop.ShopService),",
		"}",
	}, "\n")
	local matchedOk, matchedDetail, declared =
		parity.Harness.bootstrapMirror(entrypoint, { "CollectionService", "ShopService" })
	check("the real bootstrap regex finds both services", declared == 2, `declared={declared}`)
	check("a set-equal mirror passes parity", matchedOk == true, tostring(matchedDetail))
	local driftOk, driftDetail = parity.Harness.bootstrapMirror(entrypoint, { "CollectionService" })
	check(
		"a mirror missing a booted service FAILS parity (the WorldService defect)",
		driftOk == false,
		tostring(driftDetail)
	)
	local nilOk = parity.Harness.bootstrapMirror(entrypoint, nil)
	check("a nil mirror fails parity rather than skipping it", nilOk == false)

	-- ── 11. PROOF IT IS NOT A MIRROR ─────────────────────────────────────────────────────────────
	-- A CONTROL and a MUTANT, differing only in one clause of the REAL source, run through the same
	-- code path. The subject is a phase that asserts a genuine delta but declares ZERO subjects —
	-- isolated so that the subject floor is the ONLY clause standing between it and `ok`. That is
	-- the historical defect in its exact form: the WorldService phases asserted things about a
	-- Workspace containing nothing and passed for weeks.
	--
	-- Isolation now means more than it used to: `blindTo` is mandatory on every non-structural phase,
	-- and a hand-rolled reader that CLAIMS channel "world" without calling the file-local
	-- `noteContact("world")` from inside its own `read()` fails outright rather than reading opaque
	-- (`effectiveChannel`, template :448-452) — either would stand between this phase and `ok`
	-- ALONGSIDE the subject floor. Both are neutralised here — a `blindTo` declaration and the SHIPPED
	-- `Harness.readWorldCount` mint, driven against the sandbox's real Workspace — so the subject floor
	-- is, once again, the ONLY variable the mutation moves.
	--
	-- If this file were a re-implementation, the mutation would change nothing and the two runs
	-- would agree. They must disagree. (`.verify_tmp` is never touched — the mutant lives and dies
	-- inside this function, so there is no second copy on disk to go stale.)
	local function zeroSubjectsButMoving(sandbox: Sandbox): any
		return {
			name = "no-subjects",
			gating = true,
			minSubjects = 1,
			blindTo = STUB_BLIND_TO,
			body = function(probe: any): ()
				probe:delta(
					"a real delta, on nothing discovered",
					(sandbox.Harness :: any).readWorldCount(
						"no-subjects-marker",
						function(inst: any): boolean
							return inst.Name == "no-subjects-marker"
						end
					),
					function(): ()
						local marker = makeInstance("Part")
						marker.Name = "no-subjects-marker"
						marker.Parent = sandbox.env.workspace
					end,
					{ direction = "up" }
				)
			end,
		}
	end

	local control = loader.load({ source = template, substitutions = FORK })
	control.Harness.phase(zeroSubjectsButMoving(control))
	control.Harness.finish({ "no-subjects" })
	local controlEvidence = control:evidence()

	local MUTATION: Substitution = {
		anchor = "and (not state.applicable or state.subjects >= minSubjects)",
		replacement = "and true --[[ MUTATED: subject floor removed ]]",
		why = "the subject floor in Harness.phase's verdict derivation",
	}
	-- pcall'd on purpose. If the template is refactored past the mutation anchor, that is DRIFT and
	-- must be red — but recorded as a FAILURE rather than thrown, so the other 30-odd results
	-- survive to be read. A throw here would blank the whole report at exactly the moment somebody
	-- needs it.
	local mutantOk, mutant = pcall(function(): any
		local sandbox = loader.load({ source = template, substitutions = { FORK[1], MUTATION } })
		sandbox.Harness.phase(zeroSubjectsButMoving(sandbox))
		sandbox.Harness.finish({ "no-subjects" })
		return sandbox:evidence()
	end)
	local mutatedEvidence = if mutantOk then mutant else nil
	check(
		"the mutation anchor still exists in the template (the drift guard)",
		mutantOk,
		`the derivation moved past the anchor this proof mutates: {tostring(mutant)}`
	)

	if controlEvidence ~= nil and mutatedEvidence ~= nil then
		check(
			"CONTROL: the shipped subject floor reds a phase that discovered nothing",
			controlEvidence.phases[1].ok == false,
			tostring(controlEvidence.phases[1].detail)
		)
		check(
			"MUTANT: deleting that floor from the REAL source flips the SAME phase to ok",
			mutatedEvidence.phases[1].ok == true,
			`mutated phase ok={tostring(mutatedEvidence.phases[1].ok)} — the loader is NOT bound to the template bytes`
		)
		check(
			"the two runs disagree, which is the property a mirror cannot have",
			controlEvidence.phases[1].ok ~= mutatedEvidence.phases[1].ok
		)
		-- Defence in depth, and worth stating: even with the phase-level floor deleted, `finish` has
		-- an INDEPENDENT zero-subject blocker, so the run still reds. Two guards, not one.
		check(
			"and finish()'s independent zero-subject blocker still reds the mutant",
			mutatedEvidence.verdict == "red",
			tostring(mutatedEvidence.verdict)
		)
	else
		check("the control/mutant pair both emit evidence", false, "no sentinel on one or both")
	end

	-- The mutation anchor must exist. If the template is refactored so it no longer does, `load`
	-- above throws and the suite fails loudly — which is the fail-closed drift guard, not a skip.

	-- ── 12. THE THREE HARDENED FINISHER RULES, PROVEN RED ON PURPOSE ────────────────────────────
	-- Each of the three was, until now, only reached BY ACCIDENT — as one confound among several in
	-- fixtures built for something else. That is exactly the shape section 7 warns about ("masked the
	-- ran-but-unrostered branch entirely"): a rule nobody deliberately reds is not known to work
	-- (doctrine 3). Each fixture below isolates ONE of the three so it fails loudly on its own.

	-- 12a. Exactly 2 spec-derived gating phases — one short of MIN_SPEC_GATING_PHASES — and BOTH of
	-- them individually pass, so the only thing standing between this run and green is the count.
	local tooFewGating = loader.load({ source = template, substitutions = FORK })
	tooFewGating.Harness.phase(healthyPhase(tooFewGating, "only-one", true, true))
	tooFewGating.Harness.phase(healthyPhase(tooFewGating, "only-two", true, true))
	tooFewGating.Harness.finish({ "only-one", "only-two" })
	local tooFewGatingEvidence = tooFewGating:evidence()
	if tooFewGatingEvidence ~= nil then
		check(
			"exactly 2 spec-derived gating phases reds the run on the MIN_SPEC_GATING_PHASES floor",
			tooFewGatingEvidence.verdict == "red",
			tostring(tooFewGatingEvidence.verdict)
		)
		check(
			"both phases themselves passed — the COUNT is what reds it, nothing else",
			tooFewGatingEvidence.phases[1].ok == true and tooFewGatingEvidence.phases[2].ok == true,
			shortJson(tooFewGatingEvidence.blockers)
		)
		check(
			"the blocker names the exact floor",
			string.find(table.concat(tooFewGatingEvidence.blockers, " | "), "needs >= 3", 1, true)
				~= nil,
			shortJson(tooFewGatingEvidence.blockers)
		)
	else
		check("too-few-gating-phases run emits evidence", false, "no sentinel")
	end

	-- 12b. An ABSENT server mount reds the run — never silently skipped. `Harness.finish` calls
	-- `serverMount()` ITSELF (template :2045) regardless of whether any `bootstrap-parity`-named
	-- phase is on the roster (section 5 is never loaded by this slice), so this is reachable even
	-- with a fully healthy, well-rostered gating trio.
	local noMount = loader.load({
		source = template,
		substitutions = FORK,
		omitServerMount = true,
	})
	noMount.Harness.phase(healthyPhase(noMount, "mount-a", true, true))
	noMount.Harness.phase(healthyPhase(noMount, "mount-b", true, true))
	noMount.Harness.phase(healthyPhase(noMount, "mount-c", true, true))
	noMount.Harness.finish({ "mount-a", "mount-b", "mount-c" })
	local noMountEvidence = noMount:evidence()
	if noMountEvidence ~= nil then
		check(
			"an ABSENT server mount reds the run, never silently skipped",
			noMountEvidence.verdict == "red",
			tostring(noMountEvidence.verdict)
		)
		check(
			"and names the mount as unreachable, not some other blocker",
			string.find(
				table.concat(noMountEvidence.blockers, " | "),
				"could not reach the server mount",
				1,
				true
			) ~= nil,
			shortJson(noMountEvidence.blockers)
		)
	else
		check("absent-server-mount run emits evidence", false, "no sentinel")
	end

	-- 12c. An EMPTY log history reds the run: "a scan that read nothing cannot tell 'clean' from
	-- 'never ran'" (template :2071). `logHistory = {}` is passed EXPLICITLY — `or` cannot tell "you
	-- gave me nothing" from "you gave me an empty table", so this is the one case the default can
	-- never produce on its own.
	local noLogs = loader.load({
		source = template,
		substitutions = FORK,
		logHistory = {},
	})
	noLogs.Harness.phase(healthyPhase(noLogs, "logs-a", true, true))
	noLogs.Harness.phase(healthyPhase(noLogs, "logs-b", true, true))
	noLogs.Harness.phase(healthyPhase(noLogs, "logs-c", true, true))
	noLogs.Harness.finish({ "logs-a", "logs-b", "logs-c" })
	local noLogsEvidence = noLogs:evidence()
	if noLogsEvidence ~= nil then
		check(
			"an EMPTY log history reds the run",
			noLogsEvidence.verdict == "red",
			tostring(noLogsEvidence.verdict)
		)
		check(
			"and names the zero-lines blocker specifically",
			string.find(table.concat(noLogsEvidence.blockers, " | "), "read ZERO lines", 1, true)
				~= nil,
			shortJson(noLogsEvidence.blockers)
		)
	else
		check("empty-log-history run emits evidence", false, "no sentinel")
	end

	return checks, failures
end

return loader
