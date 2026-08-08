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

	-- ── SHUTDOWN QUIESCE ─────────────────────────────────────────────────────────────────────────
	-- The adversarial review's HIGH finding: on BindToClose, `Bootstrap.stop` tears services down in
	-- reverse order while the gateway keeps dispatching, because nothing ever unbinds it. Inside that
	-- window a service has been Stopped — its in-RAM guards cleared — and its action handler is still
	-- reachable from the wire, holding `self`. For OfflineService that is catastrophic: `_pending` is
	-- the ONLY one-shot guard the away window has, `Stop` clears it, and `DataService.Stop` runs
	-- afterwards and persists, so a claim landing in the window re-pays the whole session DURABLY.
	--
	-- The fix belongs on the REGISTRY rather than in NetServer, because NetServer is Roblox-only
	-- wiring no Lune test can construct — and the mock harness deliberately runs the SAME pure
	-- Net.dispatch, so a gate here is a gate on both runtimes and cannot drift between them.
	it(
		"a quiesced registry refuses every action — a stopped service's handler is unreachable",
		function()
			local harness = Mocks.net({ clock = Mocks.clock(1000), gate = false })
			harness.register(echoAction())
			local player = Mocks.player(1)
			expect(harness.invoke("test.echo", player, { n = 1 })):toBeOk()

			harness.registry:quiesce()

			-- The action still EXISTS and is still registered. What changed is that the gateway will no
			-- longer carry a client into it.
			expect(harness.registry:get("test.echo") ~= nil):toEqual(true)
			expect(harness.invoke("test.echo", player, { n = 1 })):toBeErr(Result.Codes.Unavailable)
			-- Refused BEFORE the unknown-action check, so shutdown does not masquerade as a typo.
			expect(harness.invoke("no.such.action", player, {})):toBeErr(Result.Codes.Unavailable)
		end
	)

	it("quiesce is one-way — nothing re-opens the wire mid-teardown", function()
		local registry = Net.newRegistry()
		expect(registry:isQuiesced()):toEqual(false)
		registry:quiesce()
		expect(registry:isQuiesced()):toEqual(true)
		registry:quiesce()
		expect(registry:isQuiesced()):toEqual(true)
	end)
end)
