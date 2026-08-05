--!strict
-- core/tests/unit/validation.spec.luau   [INDEPENDENT TEST AGENT — authored from CORE-DESIGN §3.3/§3.6]
-- The client is HOSTILE. Authored from the DESIGN, this asserts Net.dispatch REJECTS every class of
-- bad inbound payload and over-rate spam, in the right order:
--   * malformed payload (nil / non-table / wrong shape)  -> Err(BadPayload)
--   * wrong TYPE for a field                              -> Err(BadType)
--   * OUT-OF-RANGE / boundary values (below/above/non-int)-> Err(OutOfRange)
--   * unknown action (and a NON-STRING action name)      -> Err(UnknownAction)
--   * OVER-RATE spam (token bucket exhausted)             -> Err(RateLimited)
--   * ordering: rate/ownership are checked BEFORE validate, so spam is rejected cheaply (§3.3 step 4<6)
--   * a hostile handler error never crosses the wire     -> Err(Internal)
--   * the panic seam: a panicked security stub rejects writes -> Err(Rejected) (B2 seam, nil-safe now)
-- Drives the REAL Net.dispatch through Mocks.net (concern 19), so it covers production dispatch, not
-- a re-implementation. Complements net.spec with boundary + ordering + panic + bad-action-name cases.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Result = require("../../src/shared/Result")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- A representative action: validate accepts { qty:number } as an INTEGER in [1,50].
local function qtyAction(): any
	return {
		name = "test.qty",
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw: any)
			if type(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			local qty = raw.qty
			if type(qty) ~= "number" then
				return Result.err(Result.Codes.BadType)
			end
			if qty < 1 or qty > 50 or qty % 1 ~= 0 then
				return Result.err(Result.Codes.OutOfRange)
			end
			return Result.ok({ qty = qty })
		end,
		handler = function(_ctx: any, payload: any)
			return Result.ok({ qty = payload.qty })
		end,
	}
end

describe("Net validation: malformed / wrong-type / out-of-range rejection", function()
	local function harnessWith(action: any): (any, any)
		local clock = Mocks.clock(1000)
		-- gate=false: isolate VALIDATION here (rate is exercised in its own block below).
		local harness = Mocks.net({ clock = clock, gate = false })
		harness.register(action)
		return harness, Mocks.player(1)
	end

	it("nil payload -> Err(BadPayload)", function()
		local harness, player = harnessWith(qtyAction())
		expect(harness.invoke("test.qty", player, nil)):toBeErr(Result.Codes.BadPayload)
	end)

	it("non-table payloads (number/string/boolean) -> Err(BadPayload)", function()
		local harness, player = harnessWith(qtyAction())
		expect(harness.invoke("test.qty", player, 7)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke("test.qty", player, "qty")):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke("test.qty", player, true)):toBeErr(Result.Codes.BadPayload)
	end)

	it("wrong field type (qty is a string / table / boolean) -> Err(BadType)", function()
		local harness, player = harnessWith(qtyAction())
		expect(harness.invoke("test.qty", player, { qty = "5" })):toBeErr(Result.Codes.BadType)
		expect(harness.invoke("test.qty", player, { qty = {} })):toBeErr(Result.Codes.BadType)
		expect(harness.invoke("test.qty", player, { qty = true })):toBeErr(Result.Codes.BadType)
		expect(harness.invoke("test.qty", player, {})):toBeErr(Result.Codes.BadType) -- qty missing
	end)

	it("out-of-range boundary values (0, 51, negative, fractional) -> Err(OutOfRange)", function()
		local harness, player = harnessWith(qtyAction())
		expect(harness.invoke("test.qty", player, { qty = 0 })):toBeErr(Result.Codes.OutOfRange)
		expect(harness.invoke("test.qty", player, { qty = 51 })):toBeErr(Result.Codes.OutOfRange)
		expect(harness.invoke("test.qty", player, { qty = -5 })):toBeErr(Result.Codes.OutOfRange)
		expect(harness.invoke("test.qty", player, { qty = 2.5 })):toBeErr(Result.Codes.OutOfRange)
	end)

	it("the inclusive boundaries (1 and 50) are ACCEPTED (off-by-one guard)", function()
		local harness, player = harnessWith(qtyAction())
		expect(harness.invoke("test.qty", player, { qty = 1 })):toBeOk()
		expect(harness.invoke("test.qty", player, { qty = 50 })):toBeOk()
	end)
end)

describe("Net routing: unknown / bad action name", function()
	it("an unregistered action name -> Err(UnknownAction)", function()
		local harness = Mocks.net({ clock = Mocks.clock(1000), gate = false })
		harness.register(qtyAction())
		expect(harness.invoke("nope.missing", Mocks.player(1), { qty = 1 })):toBeErr(
			Result.Codes.UnknownAction
		)
	end)

	it(
		"a NON-STRING action name -> Err(UnknownAction) (hostile client can't crash the router)",
		function()
			local harness = Mocks.net({ clock = Mocks.clock(1000), gate = false })
			harness.register(qtyAction())
			expect(harness.invoke(12345 :: any, Mocks.player(1), { qty = 1 })):toBeErr(
				Result.Codes.UnknownAction
			)
		end
	)
end)

describe("Net rate-limiting: over-rate spam is rejected", function()
	it("the 4th call in the window (maxPerWindow=3) -> Err(RateLimited)", function()
		local clock = Mocks.clock(1000)
		local harness = Mocks.net({ clock = clock, gate = Mocks.gate(clock) })
		harness.register(qtyAction())
		local player = Mocks.player(9)
		expect(harness.invoke("test.qty", player, { qty = 1 })):toBeOk()
		expect(harness.invoke("test.qty", player, { qty = 1 })):toBeOk()
		expect(harness.invoke("test.qty", player, { qty = 1 })):toBeOk()
		expect(harness.invoke("test.qty", player, { qty = 1 })):toBeErr(Result.Codes.RateLimited)
	end)

	it(
		"RATE is checked BEFORE validation: spam with a BAD payload still rate-limits (cheap reject)",
		function()
			-- Design §3.3: steps 3-5 (panic/rate/ownership) are ordered BEFORE validate (step 6) so an
			-- exploiter's spam is rejected cheaply. Falsifiable: if validate ran first, an over-rate call
			-- with a bad payload would return BadType, not RateLimited. We assert RateLimited wins.
			local clock = Mocks.clock(1000)
			local harness = Mocks.net({ clock = clock, gate = Mocks.gate(clock) })
			harness.register(qtyAction())
			local player = Mocks.player(11)
			-- Exhaust the bucket with valid calls.
			harness.invoke("test.qty", player, { qty = 1 })
			harness.invoke("test.qty", player, { qty = 1 })
			harness.invoke("test.qty", player, { qty = 1 })
			-- Now spam a MALFORMED payload: rate is checked first, so it's RateLimited (not BadType).
			expect(harness.invoke("test.qty", player, { qty = "garbage" })):toBeErr(
				Result.Codes.RateLimited
			)
		end
	)

	it("burst capacity is honored (burst > maxPerWindow allows a larger initial spike)", function()
		-- Design §3.6: capacity = burst (or maxPerWindow). With burst=5 the bucket starts at 5 tokens.
		local clock = Mocks.clock(1000)
		local gate = Mocks.gate(clock)
		local policy = { maxPerWindow = 2, windowSeconds = 1, burst = 5 }
		for _ = 1, 5 do
			expect(gate:check(1, "burst.act", policy)):toBeOk()
		end
		expect(gate:check(1, "burst.act", policy)):toBeErr(Result.Codes.RateLimited)
	end)

	it(
		"a degenerate rate policy (windowSeconds<=0 or maxPerWindow<=0) rejects, never divides by zero",
		function()
			local clock = Mocks.clock(1000)
			local gate = Mocks.gate(clock)
			expect(gate:check(1, "z", { maxPerWindow = 0, windowSeconds = 1 })):toBeErr(
				Result.Codes.RateLimited
			)
			expect(gate:check(1, "z", { maxPerWindow = 5, windowSeconds = 0 })):toBeErr(
				Result.Codes.RateLimited
			)
		end
	)
end)

describe("Net handler safety: no exception crosses the boundary", function()
	it("a handler that throws -> Err(Internal) (pcall-wrapped, Result-only contract)", function()
		local harness = Mocks.net({ clock = Mocks.clock(1000), gate = false })
		harness.register({
			name = "test.throws",
			rate = { maxPerWindow = 9, windowSeconds = 1 },
			validate = function(_raw: any)
				return Result.ok({})
			end,
			handler = function(_ctx: any, _payload: any)
				error("hostile crash attempt")
			end,
		})
		expect(harness.invoke("test.throws", Mocks.player(1), {})):toBeErr(Result.Codes.Internal)
	end)
end)

describe("Net panic seam (B2): a panicked security stub rejects client writes", function()
	it(
		"when ctx.security:isPanicked() is true -> Err(Rejected); nil security is a no-op",
		function()
			-- The spine has no panic flag (security is nil => skipped). We supply a B2-shaped stub to
			-- prove the seam wired in Net.dispatch (step 3) fires the reserved 'Rejected' code unchanged.
			local panicSecurity = {
				isPanicked = function(_self: any)
					return true
				end,
			}
			local clock = Mocks.clock(1000)
			local harness = Mocks.net({ clock = clock, gate = false, security = panicSecurity })
			harness.register(qtyAction())
			expect(harness.invoke("test.qty", Mocks.player(1), { qty = 1 })):toBeErr(
				Result.Codes.Rejected
			)
		end
	)

	it(
		"a NON-panicked security stub lets a valid call through (seam is conditional, not always-on)",
		function()
			local calmSecurity = {
				isPanicked = function(_self: any)
					return false
				end,
			}
			local clock = Mocks.clock(1000)
			local harness = Mocks.net({ clock = clock, gate = false, security = calmSecurity })
			harness.register(qtyAction())
			expect(harness.invoke("test.qty", Mocks.player(1), { qty = 3 })):toBeOk()
		end
	)
end)
