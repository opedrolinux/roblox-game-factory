--!strict
-- games/deep-reach/tests/unit/joinretry.spec.luau   [contract pass — infra]
-- The join-race guard, driven under Lune with a fake net (the same technique framework.spec uses to
-- drive the pure Bootstrap). JoinRetry is deliberately Roblox-free so this rung can reach it.
--
-- WHY THIS EXISTS: DataService.loadSession YIELDS on join, so a controller call issued from Start()
-- can land before the session is installed and come back Err(NoData, "session not loaded"). In this
-- factory's previous game that was observed in 2 of 2 real Studio Play sessions, and for the
-- grant-shaped call the loss was PERMANENT rather than deferred: autosaveTick rewrites
-- timestamps.lastSeenUnix to now on every flush, so the unclaimed away-window is erased from
-- persistence within one interval.
--
-- SCOPE HONESTY: this spec proves the MECHANISM. It cannot prove any Deep Reach controller actually
-- USES it — client controllers touch Players.LocalPlayer at module scope and are unrequirable under
-- Lune, and the T2/T2.5 engine lanes have no LocalPlayer either. That wiring is evidenced only at
-- T2.7, in a real Play session. A green run here says nothing about the wiring.
local testkit = require("../lib/testkit")
local JoinRetry = require("../../src/client/framework/JoinRetry")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A fake NetClient: records "data" subscribers and lets a test fire pushes on demand. Mirrors the
-- real contract deliberately, INCLUDING its sharpest edge — NetClient.on has no replay buffer, so a
-- handler registered after a push has already landed never sees it.
local function fakeNet(): any
	local net: any = { handlers = {} }
	function net.on(_self: any, event: string, handler: (any) -> ()): ()
		if net.handlers[event] == nil then
			net.handlers[event] = {}
		end
		table.insert(net.handlers[event], handler)
	end
	function net.push(event: string, payload: any): ()
		for _, handler in net.handlers[event] or {} do
			handler(payload)
		end
	end
	return net
end

describe("client/framework/JoinRetry", function()
	it("re-issues the call exactly once when the join attempt lost the load race", function()
		local net = fakeNet()
		local calls = 0
		JoinRetry.once(net, "offline.claim", function(): any
			calls += 1
			if calls == 1 then
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({ granted = 42 })
		end)

		expect(calls):toBe(1) -- the join attempt, which lost
		net.push("data", {})
		expect(calls):toBe(2) -- the single retry, on the server's on-load push
	end)

	it("never re-issues on later pushes — a collect push must not re-claim", function()
		local net = fakeNet()
		local calls = 0
		JoinRetry.once(net, "offline.claim", function(): any
			calls += 1
			if calls == 1 then
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({ granted = 0 })
		end)

		net.push("data", {}) -- the retry
		net.push("data", {}) -- a salvage.collect
		net.push("data", {}) -- a structures.buy
		net.push("data", {}) -- a daily.claim
		-- Without the latch this is an unbounded self-feeding remote loop: a claim ALWAYS writes,
		-- every write pushes "data", and every push would re-enter the claim.
		expect(calls):toBe(2)
	end)

	it("issues nothing further when the join attempt succeeded", function()
		local net = fakeNet()
		local calls = 0
		JoinRetry.once(net, "plot.fetch", function(): any
			calls += 1
			return Result.ok({ plotId = "dome-3" })
		end)

		expect(calls):toBe(1)
		net.push("data", {})
		net.push("data", {})
		expect(calls):toBe(1)
	end)

	it("does not retry a real rejection — only the load race", function()
		local net = fakeNet()
		local rejections = {
			Result.Codes.Insufficient,
			Result.Codes.RateLimited,
			Result.Codes.NotOwner,
			Result.Codes.OnCooldown,
			Result.Codes.AlreadyClaimed,
		}
		for _, code in rejections do
			local calls = 0
			JoinRetry.once(net, "daily.claim", function(): any
				calls += 1
				return Result.err(code, "a genuine rejection")
			end)
			net.push("data", {})
			expect(calls):toBe(1)
		end
	end)

	it("still retries when the push lands WHILE the join attempt is in flight", function()
		-- The subtle one. net:call yields inside InvokeServer, and the server's on-load push can land
		-- inside that yield. Because NetClient.on has no replay, a handler that only acts on pushes
		-- arriving AFTER the attempt resolves would miss the very push it was waiting for — the same
		-- race, one layer up.
		local net = fakeNet()
		local calls = 0
		JoinRetry.once(net, "offline.claim", function(): any
			calls += 1
			if calls == 1 then
				net.push("data", {}) -- arrives mid-flight, before this call returns
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({ granted = 5 })
		end)

		expect(calls):toBe(2)
		net.push("data", {}) -- and it is still spent afterwards
		expect(calls):toBe(2)
	end)

	it("returns the join attempt's Result unchanged so call sites keep their shape", function()
		local net = fakeNet()
		local ok = JoinRetry.once(net, "salvage.fetch", function(): any
			return Result.ok({ rate = 3 })
		end)
		expect(ok):toBeOk()

		local failed = JoinRetry.once(net, "salvage.fetch", function(): any
			return Result.err(Result.Codes.NoData, "session not loaded")
		end)
		expect(failed):toBeErr(Result.Codes.NoData)
	end)

	it("tolerates a call that returns nil without arming a retry", function()
		local net = fakeNet()
		local calls = 0
		JoinRetry.once(net, "plot.fetch", function(): any
			calls += 1
			return nil
		end)
		net.push("data", {})
		expect(calls):toBe(1)
	end)

	it("keeps its NoData literal in lockstep with Result.Codes", function()
		-- JoinRetry hardcodes the string so it stays Lune-requirable without pulling in Shared.
		-- This assertion is what stops that literal drifting if the code is ever renamed.
		expect(JoinRetry.SESSION_NOT_LOADED):toBe(Result.Codes.NoData)
	end)
end)
