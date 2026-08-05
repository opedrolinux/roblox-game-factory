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
-- SCOPE. The first block proves the MECHANISM (JoinRetry.once). The second proves the WIRING is not
-- optional: JoinRetry.install puts the guard on context.net itself, so a controller's first call of
-- an action is guarded whether or not its author knew this module exists. That matters because the
-- earlier version of this file was honest that it could not prove any controller used the guard —
-- and nothing under src/ required JoinRetry at all, so nothing did. The install seam replaces "every
-- controller must remember" with "there is no other net to call", and the structural assertion at
-- the bottom fails if Context.build ever hands out a raw NetClient again.
-- Still out of reach from here: a real LocalPlayer. Client controllers are unrequirable under Lune
-- and the T2/T2.5 engine lanes have no LocalPlayer, so the live behaviour is evidenced at T2.7.
local testkit = require("../lib/testkit")
local JoinRetry = require("../../src/client/framework/JoinRetry")
local Result = require("../../src/shared/Result")

local fs = require("@lune/fs")

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

-- A fake NetClient with a `call` on it, so install() has something to wrap. `sent` is what reached
-- the "server"; the guard is proven by what it does to that list.
local function fakeCallableNet(reply: (action: string, attempt: number) -> any): any
	local net: any = { handlers = {}, sent = {} :: { string } }
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
	local attempts: { [string]: number } = {}
	function net.call(_self: any, action: string, _payload: any): any
		attempts[action] = (attempts[action] or 0) + 1
		table.insert(net.sent, action)
		return reply(action, attempts[action])
	end
	return net
end

local function countOf(list: { string }, wanted: string): number
	local n = 0
	for _, entry in list do
		if entry == wanted then
			n += 1
		end
	end
	return n
end

describe("client/framework/JoinRetry.install (the guard is on the wire, not opt-in)", function()
	it("guards the FIRST call of an action without the caller doing anything", function()
		-- The caller here is deliberately naive: a plain net:call from a controller's Start, with no
		-- knowledge of JoinRetry. If the guard were opt-in this attempt would be lost for good.
		local net = fakeCallableNet(function(_action: string, attempt: number): any
			if attempt == 1 then
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({ granted = 42 })
		end)
		JoinRetry.install(net)

		local first = net:call("offline.claim", {})
		expect(first):toBeErr(Result.Codes.NoData)
		expect(countOf(net.sent, "offline.claim")):toBe(1)

		net.push("data", {}) -- the server's on-load push
		expect(countOf(net.sent, "offline.claim")):toBe(2) -- re-issued BY THE GUARD
	end)

	it("guards each action's own first call — two controllers race independently", function()
		local net = fakeCallableNet(function(_action: string, attempt: number): any
			if attempt == 1 then
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({})
		end)
		JoinRetry.install(net)

		net:call("plot.fetch", {})
		net:call("salvage.fetch", {})
		net.push("data", {})

		expect(countOf(net.sent, "plot.fetch")):toBe(2)
		expect(countOf(net.sent, "salvage.fetch")):toBe(2)
	end)

	it("passes later calls straight through — a collect is not a join read", function()
		-- The failure mode on the other side: re-arming per call would make every "data" push
		-- re-issue every action ever called, an unbounded self-feeding remote loop.
		local net = fakeCallableNet(function(_action: string, _attempt: number): any
			return Result.err(Result.Codes.NoData, "session not loaded")
		end)
		JoinRetry.install(net)

		net:call("salvage.collect", {}) -- first: guarded
		net.push("data", {}) -- spends the single retry
		local before = countOf(net.sent, "salvage.collect")
		net:call("salvage.collect", {}) -- a player click, ten minutes later
		net.push("data", {})
		net.push("data", {})
		expect(countOf(net.sent, "salvage.collect")):toBe(before + 1)
	end)

	it("returns the underlying Result unchanged, so call sites keep their shape", function()
		local net = fakeCallableNet(function(_action: string, _attempt: number): any
			return Result.ok({ rate = 3 })
		end)
		JoinRetry.install(net)
		local result = net:call("salvage.fetch", {})
		expect(result):toBeOk()
		expect(result.value.rate):toBe(3)
	end)

	it("is idempotent — installing twice must not double-issue", function()
		local net = fakeCallableNet(function(_action: string, attempt: number): any
			if attempt == 1 then
				return Result.err(Result.Codes.NoData, "session not loaded")
			end
			return Result.ok({})
		end)
		JoinRetry.install(net)
		JoinRetry.install(net)

		net:call("daily.claim", {})
		net.push("data", {})
		expect(countOf(net.sent, "daily.claim")):toBe(2) -- not 3, and not an infinite wrap
	end)

	it("the client context installs it, so no controller can reach an unguarded net", function()
		-- THE non-bypass proof. Context.build is Roblox-only (LocalPlayer at module scope), so it is
		-- asserted structurally: if it ever hands NetClient.new() to the context bare again, a first
		-- fetch reaches the server unguarded and this fails.
		local source: string? = nil
		for _, path in
			{
				"src/client/Context.luau",
				"games/deep-reach/src/client/Context.luau",
				"../src/client/Context.luau",
			}
		do
			if fs.isFile(path) then
				source = fs.readFile(path)
				break
			end
		end
		expect(source ~= nil):toBe(true)
		local text = source :: string
		expect(string.find(text, "JoinRetry.install(NetClient.new())", 1, true) ~= nil):toBe(true)
		-- and the context must carry THAT net, not a second one built beside it.
		local bareAt = string.find(text, "local net = NetClient.new()", 1, true)
		expect(bareAt == nil):toBe(true)
	end)
end)
