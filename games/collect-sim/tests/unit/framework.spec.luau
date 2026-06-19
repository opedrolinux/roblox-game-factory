--!strict
-- core/tests/unit/framework.spec.luau
-- Bootstrap order + context resolution + non-nil deps on Start. Drives the PURE Bootstrap
-- driver under Lune with fake services (it knows nothing about Roblox). See §2.2 / §9.
local testkit = require("../lib/testkit")
local Bootstrap = require("../../src/server/framework/Bootstrap")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

describe("framework/Bootstrap", function()
	it("runs Start in array order", function()
		local order: { string } = {}
		local function makeService(name: string)
			return {
				name = name,
				Start = function(_self: any, _ctx: any)
					table.insert(order, name)
				end,
			}
		end
		local services = { makeService("a"), makeService("b"), makeService("c") }
		Bootstrap.start(services, {})
		expect(order):toEqual({ "a", "b", "c" })
	end)

	it("runs Stop in REVERSE order; missing Stop is a no-op", function()
		local order: { string } = {}
		local function makeService(name: string, withStop: boolean)
			local service: any = {
				name = name,
				Start = function() end,
			}
			if withStop then
				service.Stop = function(_self: any, _ctx: any)
					table.insert(order, name)
				end
			end
			return service
		end
		local services = { makeService("a", true), makeService("b", false), makeService("c", true) }
		local started = Bootstrap.start(services, {})
		Bootstrap.stop(started, {})
		-- b has no Stop (no-op); c then a in reverse.
		expect(order):toEqual({ "c", "a" })
	end)

	it("a later feature service sees non-nil context deps on Start (construct-vs-start)", function()
		-- Simulate Context.build: every core field non-nil at t0 (the same objects in the array).
		local fakeNet = { name = "NetServer", Start = function() end }
		local fakeData = { name = "DataService", Start = function() end }
		local context = {
			isServer = true,
			clock = {
				unix = function()
					return 0
				end,
				mono = function()
					return 0
				end,
			},
			config = { rateDefaults = { maxPerWindow = 1, windowSeconds = 1 } },
			net = fakeNet,
			data = fakeData,
			gate = {},
		}

		local observed: { [string]: boolean } = {}
		local feature = {
			name = "FeatureService",
			Start = function(_self: any, ctx: any)
				observed.net = ctx.net ~= nil
				observed.data = ctx.data ~= nil
				observed.clock = ctx.clock ~= nil
				observed.config = ctx.config ~= nil
			end,
		}

		local services = { fakeNet, fakeData, feature }
		Bootstrap.start(services, context)

		expect(observed.net):toBe(true)
		expect(observed.data):toBe(true)
		expect(observed.clock):toBe(true)
		expect(observed.config):toBe(true)
	end)

	it("a failing Start raises loudly with the service name", function()
		local bad = {
			name = "BadService",
			Start = function()
				error("boom")
			end,
		}
		expect(function()
			Bootstrap.start({ bad }, {})
		end):toThrow()
	end)
end)
