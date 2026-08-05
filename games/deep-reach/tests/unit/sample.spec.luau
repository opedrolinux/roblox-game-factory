--!strict
-- core/tests/unit/sample.spec.luau   [SAMPLE]
-- End-to-end LOGIC proof: SampleAction -> Mocks.net (-> the REAL Net.dispatch) -> handler ->
-- DataService:update -> MockStore session. Because Mocks.net runs the PRODUCTION Net.dispatch,
-- this genuinely covers the dispatch pipeline, not a re-implementation (concern 19). Includes
-- the falsifiable single-server race proof (§9.3): two interleaved sample.ping calls against a
-- yielding store land the balance at the EXACT sum (naive read->yield->write would land wrong).
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local SampleAction = require("../../src/server/services/sample/SampleAction")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build a service over a (possibly yielding) mock store + fake clock, with one loaded player.
local function setup(storeOptions: any): (any, any, any)
	local clock = Mocks.clock(1000)
	local cfg = config()
	local opts = storeOptions or {}
	opts.clock = clock
	opts.config = cfg
	local store = Mocks.store(opts)
	local service = DataService.new(store, clock, cfg, Mocks.logWarn)
	local player = Mocks.player(1)
	service:loadSession(player)
	return service, player, clock
end

describe("sample.ping end-to-end (real Net.dispatch)", function()
	it("a valid call increments Stardust exactly once and returns the new balance", function()
		local service, player, clock = setup(nil)
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(SampleAction)
		local result = harness.invoke("sample.ping", player, { amount = 10 })
		expect(result):toBeOk()
		expect((result :: any).value.balance):toBe(10)
		expect((service:get(player) :: any).value.currencies.Stardust):toBe(10)
	end)

	it("bad type -> Err(BadType)", function()
		local service, player, clock = setup(nil)
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(SampleAction)
		expect(harness.invoke("sample.ping", player, { amount = "lots" })):toBeErr(
			Result.Codes.BadType
		)
	end)

	it("out of range (0, 101, fractional) -> Err(OutOfRange)", function()
		local service, player, clock = setup(nil)
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(SampleAction)
		expect(harness.invoke("sample.ping", player, { amount = 0 })):toBeErr(
			Result.Codes.OutOfRange
		)
		expect(harness.invoke("sample.ping", player, { amount = 101 })):toBeErr(
			Result.Codes.OutOfRange
		)
		expect(harness.invoke("sample.ping", player, { amount = 1.5 })):toBeErr(
			Result.Codes.OutOfRange
		)
	end)

	it("non-table payload -> Err(BadPayload)", function()
		local service, player, clock = setup(nil)
		local harness = Mocks.net({ clock = clock, data = service, gate = false })
		harness.register(SampleAction)
		expect(harness.invoke("sample.ping", player, 5)):toBeErr(Result.Codes.BadPayload)
	end)

	-- THE headline deliverable (§9.3): falsifiable single-server race proof.
	it(
		"two INTERLEAVED calls against a yielding store land the balance at the EXACT sum (no dupe/loss)",
		function()
			-- yieldOnUpdate forces a yield inside the per-key lock critical section, so the second
			-- update arriving during the first's yield is FORCED to park in the FIFO and re-read.
			local service, player, clock = setup({ yieldOnUpdate = true })
			local harness = Mocks.net({ clock = clock, data = service, gate = false })
			harness.register(SampleAction)

			-- Two calls without awaiting the first: +5 then +3 from 0. Correct queue => 8.
			-- A naive read->yield->write with no FIFO park/re-read would land at 3 (lost update) —
			-- which this assertion rejects, so a GREEN test distinguishes a correct queue from a no-op.
			local results: { any } = {}
			local coA = coroutine.create(function()
				results.a = harness.invoke("sample.ping", player, { amount = 5 })
			end)
			local coB = coroutine.create(function()
				results.b = harness.invoke("sample.ping", player, { amount = 3 })
			end)

			-- Round-robin driver: resume each suspended coroutine until both are dead. The exact
			-- yield count is implementation-detail; this drains both deterministically.
			local live = { coA, coB }
			local guard = 0
			while #live > 0 do
				guard += 1
				if guard > 100 then
					error("race driver did not converge (possible deadlock)")
				end
				local stillLive = {}
				for _, co in live do
					if coroutine.status(co) == "suspended" then
						local ok, err = coroutine.resume(co)
						if not ok then
							error(`race coroutine errored: {tostring(err)}`)
						end
					end
					if coroutine.status(co) ~= "dead" then
						table.insert(stillLive, co)
					end
				end
				live = stillLive
			end

			-- Both succeeded, each granted exactly once, final balance is the exact sum.
			expect(results.a):toBeOk()
			expect(results.b):toBeOk()
			expect((service:get(player) :: any).value.currencies.Stardust):toBe(8)
		end
	)
end)
