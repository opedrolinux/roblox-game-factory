--!strict
-- core/tests/lib/mocks.luau
-- Tier-1 fakes. Requires the REAL source modules relatively (script-relative, cwd-agnostic)
-- so the tests exercise production code, not re-implementations. No Roblox globals.
-- See docs/CORE-DESIGN.md §7.3.
local MockStore = require("../../src/server/data/MockStore")
local Clock = require("../../src/server/data/Clock")
local Gate = require("../../src/server/security/Gate")
local Config = require("../../src/shared/Config")
local Net = require("../../src/shared/Net")

local stdio = require("@lune/stdio")

local Mocks = {}

-- A diagnostic logger that writes to STDERR (so DataService's data-loss-risk warnings stay
-- visible for debugging but never pollute the runner's single stdout JSON line). Pass this as
-- DataService.new(store, clock, config, Mocks.logWarn) in tests.
function Mocks.logWarn(...: any): ()
	local parts = {}
	for index = 1, select("#", ...) do
		table.insert(parts, tostring((select(index, ...))))
	end
	stdio.ewrite("[WARN] " .. table.concat(parts, " ") .. "\n")
end

-- A Store impl backed by an in-memory table (the real MockStore). Defaults the injected clock
-- + config if the caller did not supply them, so simple tests stay terse.
function Mocks.store(options: any): any
	local opts = options or {}
	if opts.clock == nil then
		opts.clock = Mocks.clock(1000)
	end
	if opts.config == nil then
		opts.config = Config
	end
	return MockStore.new(opts)
end

-- The fake clock (advance moves BOTH unix and mono).
function Mocks.clock(startUnix: number): any
	return Clock.fake(startUnix)
end

-- A fake Player surrogate (just { UserId, Name }) so DataService can key sessions without a
-- real Instance. Handlers must only read .UserId/.Name (documented constraint).
function Mocks.player(userId: number, name: string?): any
	return { UserId = userId, Name = name or `Player_{userId}` }
end

-- The real spine Gate, over an injected clock (defaults to a fresh fake clock).
function Mocks.gate(clock: any): any
	return Gate.new(clock or Mocks.clock(1000))
end

-- A fake POSITION seam (ctx.world). `islandOf` answers with whatever island the test has placed
-- the player on, so a spec can drive the positional multiplier — "richer motes on higher islands"
-- — without an engine, a character, or physics. `standOn(userId, islandId)` moves them; a userId
-- with no entry answers nil, which is how "over the void / no character" is expressed.
--
-- This exists because the position gate is the one thing that decides how much a mote is worth,
-- and a seam that only ever exists in Roblox would put that decision permanently out of reach of
-- Tier-1 — which is exactly how the global-multiplier defect survived 361 green tests.
function Mocks.world(): any
	local standing: { [number]: number } = {}
	local world = {}
	function world.standOn(_self: any, userId: number, islandId: number?): ()
		standing[userId] = islandId
	end
	function world.islandOf(_self: any, player: any): number?
		if player == nil then
			return nil
		end
		return standing[player.UserId]
	end
	function world.applyAccess(_self: any, _player: any, _level: number): ()
		-- No physics under Lune; the ACCESS assertion belongs to the world-plan spec, which reads
		-- the pure layout instead. Present so callers can invoke it nil-safely.
	end
	return world
end

-- Drive `motes` collects the way a player does: by letting SERVER TIME pass between them. Collect
-- is clock-gated (floor(elapsed / collectPeriod) motes per call), so a loop of bare invokes now
-- grants nothing after the first — which is the point, and is exactly what stops a scripted client
-- minting ~70x a walking player's income. Returns the total granted.
function Mocks.collect(
	harness: any,
	clock: any,
	player: any,
	motes: number,
	period: number?
): number
	local step = period or 0.06
	local granted = 0
	local guard = 0
	while granted < motes and guard < motes * 4 + 50 do
		guard += 1
		clock:advance(step * math.min(20, motes - granted))
		local result = harness.invoke(Net.Actions.Collect, player, {})
		if not result.ok then
			break -- backpack full, or refused: the caller asserts on the count it got
		end
		granted += result.value.granted
		if result.value.granted == 0 and result.value.full then
			break
		end
	end
	return granted
end

-- A NetServer-EQUIVALENT harness that calls the SAME pure Net.dispatch production uses
-- (concern 19), so the mock pipeline CANNOT drift from NetServer. Register actions, then
-- invoke(name, player, payload) runs lookup -> [panic] -> [rate via Gate] -> [ownership] ->
-- validate -> pcall(handler) via Net.dispatch and returns the Result. No RemoteEvent.
--
-- `context` supplies clock/data (and optional gate/security/...); if no gate is given, one is
-- built over context.clock so rate-limiting is genuinely exercised (it can be omitted with
-- gate = false to skip rate for focused validation tests).
function Mocks.net(context: any): any
	local registry = Net.newRegistry()
	local clock = context.clock or Mocks.clock(1000)

	local gate
	if context.gate == false then
		gate = nil
	else
		gate = context.gate or Mocks.gate(clock)
	end

	local harness = {}
	harness.registry = registry

	function harness.register(action: any): ()
		registry:register(action)
	end

	function harness.invoke(name: string, player: any, payload: any): any
		-- Read the feature seams off `context` AT INVOKE TIME, not at construction: a service's
		-- Start publishes them (context.islands = seam, context.upgrades = seam), which happens
		-- AFTER Mocks.net is built. Late-reading is what lets a spec pass one shared table to both
		-- Mocks.net and Start, and then exercise a handler through the seam its sibling published.
		--
		-- These three were MISSING, and their absence hid a whole class of defect: every seam was
		-- unit-tested in isolation (islands.spec reads startCtx.islands directly) while the
		-- COMPOSITION — a handler consuming the seam through ctx — was never exercised by anything.
		-- That is precisely how a shop that persisted upgrade levels no gameplay code read shipped
		-- with a green suite.
		local ctx = {
			player = player,
			clock = clock,
			data = context.data,
			security = context.security,
			flags = context.flags,
			analytics = context.analytics,
			monetization = context.monetization,
			islands = context.islands,
			restock = context.restock,
			upgrades = context.upgrades,
			world = context.world,
			rebirth = context.rebirth,
		}
		return Net.dispatch(registry, gate, ctx, name, payload)
	end

	return harness
end

return Mocks
