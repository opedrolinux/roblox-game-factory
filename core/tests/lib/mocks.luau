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
		local ctx = {
			player = player,
			clock = clock,
			data = context.data,
			security = context.security,
			flags = context.flags,
			analytics = context.analytics,
			monetization = context.monetization,
		}
		return Net.dispatch(registry, gate, ctx, name, payload)
	end

	return harness
end

return Mocks
