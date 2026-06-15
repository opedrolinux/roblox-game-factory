--!strict
-- core/tests/unit/net.spec.luau
-- Net.dispatch: validation, rate (Gate), unknown action, ownership, pcall(handler) -> Internal.
-- Drives the REAL Net.dispatch (the same function NetServer uses) through Mocks.net. See §3.3.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A trivial echo action used across cases (validate accepts { n:number } 1..10).
local function echoAction(): any
	return {
		name = "test.echo",
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw: any)
			if type(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			local n = raw.n
			if type(n) ~= "number" then
				return Result.err(Result.Codes.BadType)
			end
			if n < 1 or n > 10 then
				return Result.err(Result.Codes.OutOfRange)
			end
			return Result.ok({ n = n })
		end,
		handler = function(_ctx: any, payload: any)
			return Result.ok({ echoed = payload.n })
		end,
	}
end

describe("Net.dispatch", function()
	it("unknown action -> Err(UnknownAction)", function()
		local clock = Mocks.clock(1000)
		local harness = Mocks.net({ clock = clock })
		local player = Mocks.player(1)
		local result = harness.invoke("does.not.exist", player, {})
		expect(result):toBeErr(Result.Codes.UnknownAction)
	end)

	it("bad type -> Err(BadType); out of range -> Err(OutOfRange)", function()
		local clock = Mocks.clock(1000)
		local harness = Mocks.net({ clock = clock, gate = false })
		harness.register(echoAction())
		local player = Mocks.player(1)
		expect(harness.invoke("test.echo", player, { n = "x" })):toBeErr(Result.Codes.BadType)
		expect(harness.invoke("test.echo", player, { n = 99 })):toBeErr(Result.Codes.OutOfRange)
		expect(harness.invoke("test.echo", player, "not a table")):toBeErr(Result.Codes.BadPayload)
	end)

	it("valid call passes validation and runs the handler", function()
		local clock = Mocks.clock(1000)
		local harness = Mocks.net({ clock = clock, gate = false })
		harness.register(echoAction())
		local player = Mocks.player(1)
		local result = harness.invoke("test.echo", player, { n = 7 })
		expect(result):toBeOk()
		expect((result :: any).value.echoed):toBe(7)
	end)

	it("rate limit: the 4th call within the window -> Err(RateLimited)", function()
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local harness = Mocks.net({ clock = clock, gate = gate })
		harness.register(echoAction())
		local player = Mocks.player(42)
		-- maxPerWindow = 3, burst defaults to 3.
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeOk()
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeOk()
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeOk()
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeErr(Result.Codes.RateLimited)
	end)

	it("rate limit refills after the window elapses (server mono clock)", function()
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local harness = Mocks.net({ clock = clock, gate = gate })
		harness.register(echoAction())
		local player = Mocks.player(7)
		harness.invoke("test.echo", player, { n = 1 })
		harness.invoke("test.echo", player, { n = 1 })
		harness.invoke("test.echo", player, { n = 1 })
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeErr(Result.Codes.RateLimited)
		-- advance past the window: tokens refill.
		clock:advance(2)
		expect(harness.invoke("test.echo", player, { n = 1 })):toBeOk()
	end)

	it("rate buckets are per (player, action) — a second player is unaffected", function()
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local harness = Mocks.net({ clock = clock, gate = gate })
		harness.register(echoAction())
		local p1 = Mocks.player(1)
		local p2 = Mocks.player(2)
		harness.invoke("test.echo", p1, { n = 1 })
		harness.invoke("test.echo", p1, { n = 1 })
		harness.invoke("test.echo", p1, { n = 1 })
		expect(harness.invoke("test.echo", p1, { n = 1 })):toBeErr(Result.Codes.RateLimited)
		-- p2's bucket is independent.
		expect(harness.invoke("test.echo", p2, { n = 1 })):toBeOk()
	end)

	it("a handler that throws -> Err(Internal), no exception crosses the boundary", function()
		local clock = Mocks.clock(1000)
		local harness = Mocks.net({ clock = clock, gate = false })
		harness.register({
			name = "test.boom",
			rate = { maxPerWindow = 5, windowSeconds = 1 },
			validate = function(_raw: any)
				return Result.ok({})
			end,
			handler = function(_ctx: any, _payload: any)
				error("handler blew up")
			end,
		})
		local player = Mocks.player(1)
		local result = harness.invoke("test.boom", player, {})
		expect(result):toBeErr(Result.Codes.Internal)
	end)

	it("ownership: assertOwner mismatch -> Err(NotOwner)", function()
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local harness = Mocks.net({ clock = clock, gate = gate })
		harness.register({
			name = "test.owned",
			rate = { maxPerWindow = 5, windowSeconds = 1 },
			ownerOf = function(payload: any)
				return payload.ownerId
			end,
			validate = function(raw: any)
				return Result.ok(raw)
			end,
			handler = function(_ctx: any, _payload: any)
				return Result.ok({ done = true })
			end,
		})
		local player = Mocks.player(100)
		-- acting player 100 claims a target owned by 200 -> NotOwner.
		expect(harness.invoke("test.owned", player, { ownerId = 200 })):toBeErr(
			Result.Codes.NotOwner
		)
		-- claiming own target succeeds.
		expect(harness.invoke("test.owned", player, { ownerId = 100 })):toBeOk()
	end)

	it("registry rejects duplicate action names (no silent override)", function()
		local registry = Net.newRegistry()
		registry:register(echoAction())
		expect(function()
			registry:register(echoAction())
		end):toThrow()
	end)
end)
