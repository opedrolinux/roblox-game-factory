--!strict
-- games/deep-reach/tests/unit/analytics.spec.luau   [contract pass — infra]
-- The analytics EMIT SEAM and the SESSION LIFECYCLE, driven under Lune with a fake clock and a fake
-- data layer. This proves the seam WORKS, not that the module exists: every assertion below reads a
-- value back off the buffer that a caller put in, and the two lifecycle cases assert the exact
-- failure the contract names (a session_start fired before the load resolves has nothing to
-- describe; a session_end fired after the release reads NoData and would go out empty).
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A fake DataService: `blob` is nil until `load()` is called, exactly like loadSession's yield.
local function fakeData(blob: any): any
	local data: any = { _loaded = false, _blob = blob }
	function data.load(_self: any): ()
		data._loaded = true
	end
	function data.release(_self: any): ()
		data._loaded = false -- the session was released; the blob is gone
	end
	function data.get(_self: any, _player: any): any
		if not data._loaded then
			return { ok = false, code = "NoData", message = "session not loaded" }
		end
		return { ok = true, value = data._blob }
	end
	return data
end

local function sampleBlob(): any
	return {
		schemaVersion = 7,
		currencies = { Credits = 250, Pearls = 4 },
		stats = { playtimeSeconds = 0, joinCount = 3, lifetimeCredits = 900 },
	}
end

describe("services/analytics/AnalyticsService — the emit seam", function()
	it("records event + payload, server-clock stamped, and hands them back", function()
		local clock = Mocks.clock(1_000_000)
		local service = AnalyticsService.new(clock)

		service:emit("loop_completed", { tier = 2 })
		clock:advance(30)
		service:emit("progression", { tier = 2 })

		local events = service:events()
		expect(#events):toBe(2)
		expect(events[1].event):toBe("loop_completed")
		expect(events[1].payload.tier):toBe(2)
		expect(events[1].at):toBe(1_000_000) -- the SERVER clock, not os.time
		expect(events[2].at):toBe(1_000_030) -- and it moves with the server clock
	end)

	it("events() is a copy — a caller cannot mutate the buffer through it", function()
		local service = AnalyticsService.new(Mocks.clock(10))
		service:emit("purchase", { productId = 1 })
		local snapshot = service:events()
		table.clear(snapshot)
		expect(#service:events()):toBe(1)
	end)

	it("eventsOfType filters to one event, in emit order", function()
		local service = AnalyticsService.new(Mocks.clock(10))
		service:emit("currency_earned", { amount = 1 })
		service:emit("currency_spent", { amount = 9 })
		service:emit("currency_earned", { amount = 2 })

		local earned = service:eventsOfType("currency_earned")
		expect(#earned):toBe(2)
		expect(earned[1].payload.amount):toBe(1)
		expect(earned[2].payload.amount):toBe(2)
	end)

	it("declares the contract's taxonomy exactly, and flags an off-taxonomy name", function()
		local service = AnalyticsService.new(Mocks.clock(1))
		local expected = {
			"session_start",
			"session_end",
			"loop_completed",
			"currency_earned",
			"currency_spent",
			"progression",
			"purchase",
		}
		expect(AnalyticsService.TAXONOMY):toEqual(expected)
		for _, event in expected do
			expect(service:isKnownEvent(event)):toBe(true)
		end
		expect(service:isKnownEvent("sesion_start")):toBe(false) -- a typo must be observable
		-- ...but an unknown event is still RECORDED, so nothing is ever silently lost.
		service:emit("sesion_start", {})
		expect(#service:eventsOfType("sesion_start")):toBe(1)
	end)
end)

describe("services/analytics/AnalyticsService — session lifecycle", function()
	it("fires session_start only AFTER the load resolves, and describes the loaded blob", function()
		local clock = Mocks.clock(500)
		local service = AnalyticsService.new(clock)
		service.loadWaitAttempts = 4
		local data = fakeData(sampleBlob())
		local player = Mocks.player(7, "Diver")

		-- The session installs on the 2nd poll — i.e. the join call LOST the load race first.
		local polls = 0
		service._wait = function(_self: any, _seconds: number): ()
			polls += 1
			data:load()
		end

		local record = service:onPlayerAdded(data, player)
		expect(polls):toBe(1)
		expect(record ~= nil):toBe(true)
		expect((record :: any).event):toBe("session_start")
		-- The payload describes the LOADED blob. Fired one poll earlier it would have had nothing:
		-- that is the whole reason the contract pins "AFTER the session data load resolves".
		expect((record :: any).payload.credits):toBe(250)
		expect((record :: any).payload.lifetimeCredits):toBe(900)
		expect((record :: any).payload.joinCount):toBe(3)
		expect((record :: any).payload.userId):toBe(7)
	end)

	it("emits NOTHING when the load never resolves — never an empty session_start", function()
		local service = AnalyticsService.new(Mocks.clock(500))
		service.loadWaitAttempts = 3
		service._wait = function(_self: any, _seconds: number): () end -- never loads (kicked player)

		local record = service:onPlayerAdded(fakeData(sampleBlob()), Mocks.player(8))
		expect(record):toBe(nil)
		expect(#service:events()):toBe(0)
	end)

	it("fires session_end off the STILL-LOADED blob, with server-clock playtime", function()
		local clock = Mocks.clock(1000)
		local service = AnalyticsService.new(clock)
		service.loadWaitAttempts = 1
		local data = fakeData(sampleBlob())
		data:load()
		local player = Mocks.player(9, "Salvager")

		service:onPlayerAdded(data, player)
		clock:advance(420)
		data._blob.currencies.Credits = 999 -- the session earned while it was alive

		local record = service:onPlayerRemoving(data, player)
		expect(record.event):toBe("session_end")
		expect(record.payload.sessionSeconds):toBe(420) -- the server clock, not the client's
		expect(record.payload.credits):toBe(999) -- read from the LIVE blob
		expect(record.payload.stale):toBe(false)
	end)

	it("still fires a NON-EMPTY session_end when the data layer released first", function()
		-- The exact defect the contract names: emitted after the release, `get` reads NoData and a
		-- naive emitter fires an empty payload — so the analytics criterion passes vacuously.
		local clock = Mocks.clock(1000)
		local service = AnalyticsService.new(clock)
		service.loadWaitAttempts = 1
		local data = fakeData(sampleBlob())
		data:load()
		local player = Mocks.player(10, "Late")

		service:onPlayerAdded(data, player)
		clock:advance(60)
		data:release() -- DataService got to PlayerRemoving first

		local record = service:onPlayerRemoving(data, player)
		expect(record.event):toBe("session_end")
		expect(record.payload.stale):toBe(true) -- and it SAYS the payload was reconstructed
		expect(record.payload.sessionSeconds):toBe(60)
		expect(record.payload.lifetimeCredits):toBe(900) -- join-time snapshot, never 0/nil
		expect(record.payload.userId):toBe(10)
	end)

	it("does not leak a session snapshot after the player leaves", function()
		local clock = Mocks.clock(1000)
		local service = AnalyticsService.new(clock)
		service.loadWaitAttempts = 1
		local data = fakeData(sampleBlob())
		data:load()
		local player = Mocks.player(11)

		service:onPlayerAdded(data, player)
		service:onPlayerRemoving(data, player)
		clock:advance(5000)
		-- A second leave (shutdown after PlayerRemoving) must not report a 5000s session from a
		-- stale snapshot; the snapshot is consumed.
		local again = service:onPlayerRemoving(data, player)
		expect(again.payload.sessionSeconds):toBe(0)
	end)
end)

describe("services/analytics/AnalyticsService — seam installation", function()
	it("Start refuses to run when ctx.analytics is not this service", function()
		local service = AnalyticsService.new(Mocks.clock(1))
		-- A nil seam is the silent failure this guard exists for: every ctx.analytics:emit in the
		-- game would be skipped and the buffer would be empty at grading time.
		expect(function()
			service:assertInstalled({ analytics = nil })
		end):toThrow()
		expect(function()
			service:assertInstalled({ analytics = AnalyticsService.new(Mocks.clock(1)) })
		end):toThrow()
		-- ...and passes when it IS installed.
		service:assertInstalled({ analytics = service })
	end)
end)
