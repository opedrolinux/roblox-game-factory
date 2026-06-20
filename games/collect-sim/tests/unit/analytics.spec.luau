--!strict
-- games/collect-sim/tests/unit/analytics.spec.luau   [analytics]
-- Proves the single analytics emitter seam (contract.analytics): emit -> buffered + server-clock
-- timestamped + observable, so any feature that emits through ctx.analytics:emit(event, payload) has
-- a Tier-1 observation surface. Drives the REAL AnalyticsService logic (new/emit/events) directly
-- over the fake clock — no Roblox runtime, no Start (Start is the runtime-only lifecycle wiring).
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

describe("AnalyticsService — the single emit seam", function()
	it("emit buffers the event with its payload, observable via events()", function()
		local analytics = AnalyticsService.new(Mocks.clock(1000))
		analytics:emit("currency_earned", { userId = 7, currency = "Stardust", amount = 50 })

		local events = analytics:events()
		expect(#events):toBe(1)
		expect(events[1].event):toBe("currency_earned")
		expect(events[1].payload.userId):toBe(7)
		expect(events[1].payload.currency):toBe("Stardust")
		expect(events[1].payload.amount):toBe(50)
	end)

	it("each event is stamped with the SERVER clock (ctx.clock:unix()), not client time", function()
		local clock = Mocks.clock(1000)
		local analytics = AnalyticsService.new(clock)

		analytics:emit("session_start", { userId = 1 })
		clock:advance(250) -- server time moves
		analytics:emit("session_end", { userId = 1 })

		local events = analytics:events()
		expect(events[1].at):toBe(1000)
		expect(events[2].at):toBe(1250) -- timestamp tracks the injected server clock, deterministically
	end)

	it("preserves emit order across many events", function()
		local analytics = AnalyticsService.new(Mocks.clock(1000))
		analytics:emit("session_start", {})
		analytics:emit("loop_completed", {})
		analytics:emit("currency_spent", {})

		local events = analytics:events()
		expect(#events):toBe(3)
		expect(events[1].event):toBe("session_start")
		expect(events[2].event):toBe("loop_completed")
		expect(events[3].event):toBe("currency_spent")
	end)

	it("events() returns a COPY — mutating it cannot corrupt the buffer", function()
		local analytics = AnalyticsService.new(Mocks.clock(1000))
		analytics:emit("progression", {})

		local snapshot = analytics:events()
		table.clear(snapshot) -- tamper with the returned table
		expect(#analytics:events()):toBe(1) -- internal buffer is intact
	end)

	it("eventsOfType filters to one event name in emit order", function()
		local analytics = AnalyticsService.new(Mocks.clock(1000))
		analytics:emit("currency_earned", { amount = 10 })
		analytics:emit("currency_spent", { amount = 5 })
		analytics:emit("currency_earned", { amount = 20 })

		local earned = analytics:eventsOfType("currency_earned")
		expect(#earned):toBe(2)
		expect(earned[1].payload.amount):toBe(10)
		expect(earned[2].payload.amount):toBe(20)
	end)

	it("isKnownEvent recognises the declared taxonomy and rejects strays", function()
		local analytics = AnalyticsService.new(Mocks.clock(1000))
		expect(analytics:isKnownEvent("session_start")):toBe(true)
		expect(analytics:isKnownEvent("currency_earned")):toBe(true)
		expect(analytics:isKnownEvent("purchase")):toBe(true)
		expect(analytics:isKnownEvent("not_a_real_event")):toBe(false)
	end)

	it("a handler emitting through the ctx.analytics seam is observable on the service", function()
		-- The seam contract: a feature receives the service as ctx.analytics and calls :emit. Here we
		-- stand in for that call site to prove the SAME object a handler would hold records the event.
		local analytics = AnalyticsService.new(Mocks.clock(2000))
		local ctx = { analytics = analytics }

		if ctx.analytics ~= nil then
			(ctx.analytics :: any):emit("purchase", { userId = 42, productId = "vip" })
		end

		local purchases = analytics:eventsOfType("purchase")
		expect(#purchases):toBe(1)
		expect(purchases[1].payload.productId):toBe("vip")
		expect(purchases[1].at):toBe(2000)
	end)
end)
