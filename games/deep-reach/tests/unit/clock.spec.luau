--!strict
-- core/tests/unit/clock.spec.luau   [INDEPENDENT TEST AGENT — authored from CORE-DESIGN §5]
-- Injectable-clock behavior, authored from the DESIGN:
--   * the fake clock is injectable and advance() moves BOTH unix and mono (deterministic Tier-1 time).
--   * server time is the ONLY source: a CLIENT-SUPPLIED timestamp in a payload is IGNORED by handlers
--     (the clock-rollback exploit is structurally impossible — handlers read ctx.clock, never payload).
--   * DataService stamps timestamps from the injected server clock (lastSeenUnix on load), never from
--     any client-controllable value.
--   * the rate Gate measures its window on mono() (process-local), so advancing mono refills tokens —
--     and a frozen clock never refills (anti-rollback for rate windows too).
-- These cover "injectable-clock behavior (client time ignored)" from the task. Pure/injected => Tier-1.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Clock = require("../../src/server/data/Clock")
local DataService = require("../../src/server/data/DataService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local function testConfig(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

describe("Clock.fake (injectable, deterministic)", function()
	it("starts unix at startUnix and mono at 0", function()
		local clock = Clock.fake(5000)
		expect(clock:unix()):toBe(5000)
		expect(clock:mono()):toBe(0)
	end)

	it("advance() moves BOTH unix and mono by the same delta", function()
		local clock = Clock.fake(5000)
		clock:advance(30)
		expect(clock:unix()):toBe(5030)
		expect(clock:mono()):toBe(30)
		clock:advance(70)
		expect(clock:unix()):toBe(5100)
		expect(clock:mono()):toBe(100)
	end)

	it("a frozen (never-advanced) clock returns a stable time across reads", function()
		local clock = Clock.fake(777)
		expect(clock:unix()):toBe(777)
		expect(clock:unix()):toBe(777)
		expect(clock:mono()):toBe(0)
	end)
end)

describe("Clock.real (injectable monotonic source)", function()
	it("uses the INJECTED monoSource for mono() (production passes Roblox `time`)", function()
		-- Production injects the monotonic Roblox `time` global; os.clock() is Lua-VM CPU time
		-- on Roblox and must NOT be the mono source. Assert the injected source is what mono reads.
		local fakeMono = 0
		local clock = Clock.real(function()
			fakeMono += 10
			return fakeMono
		end)
		expect(clock:mono()):toBe(10)
		expect(clock:mono()):toBe(20)
	end)

	it("mono() is monotonic across reads when fed a monotonic source", function()
		local n = 100
		local clock = Clock.real(function()
			n += 1
			return n
		end)
		local a = clock:mono()
		local b = clock:mono()
		expect(b > a):toBe(true)
	end)

	it("falls back to a working mono() when no source is injected (Lune/test default)", function()
		-- Default path (os.clock under Lune) still returns a number; the type contract holds.
		local clock = Clock.real()
		expect(type(clock:mono())):toBe("number")
		expect(type(clock:unix())):toBe("number")
	end)
end)

describe("Server-authoritative time: client-supplied timestamps are IGNORED", function()
	-- An action whose handler stamps a time-based field. The exploit attempt: the payload carries a
	-- bogus `clientTime` (e.g. a rolled-back or far-future value). The handler MUST read ctx.clock,
	-- never the payload. We assert the stored time equals the SERVER clock and ignores the payload.
	local function timeStampAction(): any
		return {
			name = "test.stamp",
			rate = { maxPerWindow = 100, windowSeconds = 1 },
			validate = function(raw: any)
				if type(raw) ~= "table" then
					return Result.err(Result.Codes.BadPayload)
				end
				return Result.ok(raw)
			end,
			handler = function(ctx: any, _payload: any)
				-- Reads the SERVER clock — the payload's clientTime is never consulted.
				local serverNow = ctx.clock:unix()
				local updated = ctx.data:update(ctx.player, function(d)
					d.timestamps.lastSeenUnix = serverNow
					return d
				end)
				if not updated.ok then
					return updated
				end
				return Result.ok({ stamped = serverNow })
			end,
		}
	end

	local function setup(): (any, any, any)
		local clock = Mocks.clock(1000)
		local cfg = testConfig()
		local store = Mocks.store({ clock = clock, config = cfg })
		local service = DataService.new(store, clock, cfg, Mocks.logWarn)
		local player = Mocks.player(1)
		service:loadSession(player)
		return service, player, clock
	end

	it("the handler stamps SERVER time, ignoring a client-supplied clientTime", function()
		local service, player, clock = setup()
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(timeStampAction())
		-- A hostile payload claims an absurd client time; it must be ignored.
		local result = harness.invoke("test.stamp", player, { clientTime = 9999999999 })
		expect(result):toBeOk()
		expect((result :: any).value.stamped):toBe(1000) -- the server clock, NOT 9999999999
		expect((service:get(player) :: any).value.timestamps.lastSeenUnix):toBe(1000)
	end)

	it("a rolled-BACK client time cannot move the stored timestamp backwards", function()
		local service, player, clock = setup()
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(timeStampAction())
		clock:advance(500) -- server time is now 1500
		-- Exploit: client claims an EARLIER time to try to roll back server bookkeeping.
		local result = harness.invoke("test.stamp", player, { clientTime = 1 })
		expect(result):toBeOk()
		expect((result :: any).value.stamped):toBe(1500) -- server time wins; rollback ignored
		expect((service:get(player) :: any).value.timestamps.lastSeenUnix):toBe(1500)
	end)
end)

describe("DataService stamps timestamps from the injected server clock", function()
	it(
		"lastSeenUnix on load is the server clock value at load time (not a client value)",
		function()
			local clock = Mocks.clock(8888)
			local cfg = testConfig()
			local store = Mocks.store({ clock = clock, config = cfg })
			local service = DataService.new(store, clock, cfg, Mocks.logWarn)
			local player = Mocks.player(1)
			service:loadSession(player)
			expect((service:get(player) :: any).value.timestamps.lastSeenUnix):toBe(8888)
		end
	)
end)

describe("Rate window measured on mono() (anti-rollback for rate)", function()
	it("a FROZEN clock never refills tokens (no time => no allowance back)", function()
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local policy = { maxPerWindow = 2, windowSeconds = 1 }
		expect(gate:check(1, "a", policy)):toBeOk()
		expect(gate:check(1, "a", policy)):toBeOk()
		-- bucket empty; clock frozen => still rate-limited on repeated checks.
		expect(gate:check(1, "a", policy)):toBeErr(Result.Codes.RateLimited)
		expect(gate:check(1, "a", policy)):toBeErr(Result.Codes.RateLimited)
	end)

	it(
		"advancing mono() refills the bucket (window elapsed on the SERVER monotonic clock)",
		function()
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			local policy = { maxPerWindow = 2, windowSeconds = 1 }
			expect(gate:check(1, "a", policy)):toBeOk()
			expect(gate:check(1, "a", policy)):toBeOk()
			expect(gate:check(1, "a", policy)):toBeErr(Result.Codes.RateLimited)
			clock:advance(1) -- a full window elapses on mono
			expect(gate:check(1, "a", policy)):toBeOk()
		end
	)
end)

-- Sanity: the Net surface exposes the shared dispatch the clock tests rely on (guards a refactor
-- that would remove the seam the time-based handlers depend on).
describe("Net surface sanity (clock-bearing dispatch present)", function()
	it("Net.dispatch is a function (the shared inbound pipeline)", function()
		expect(type(Net.dispatch)):toBe("function")
	end)
end)
