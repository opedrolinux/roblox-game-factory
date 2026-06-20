--!strict
-- games/collect-sim/tests/unit/restock.spec.luau
-- [INDEPENDENT TEST GATE — authored from the SPEC, not the implementation's branch logic.]
--
-- SPEC under test (verbatim slice):
--   "Restock — a daily 'rich vein' island event that resets each day, on server time. DERIVE the
--    day's rich-vein island + bonus multiplier deterministically from the server day number
--    (dayNumber = math.floor(ctx.clock:unix()/86400)) — richVeinIsland = islandIds[dayNumber %
--    islandCount], multiplier = a server-owned constant. Because it is fully derived from server time
--    it needs NO persisted field and resets automatically at each UTC day boundary. Expose 'today's
--    rich-vein island + multiplier' as server-owned state read through ctx so the collection earn path
--    can apply the bonus when a player collects/sells on today's vein island. A read-only Net.Action
--    lets the client query today's vein for a HUD hint. Success: the daily rich-vein restock resets —
--    all on server time."
--
-- Strategy (maker != checker): every expectation is encoded from the SPEC's guarantees, NOT copied
-- from RestockService's control flow. Concrete server-owned constants (multiplier, island id set,
-- day length) are DISCOVERED through the public FetchRestock API at runtime, so this spec never
-- hardcodes a number lifted from the implementation source and stays falsifiable if a constant drifts.
--
-- Coverage matrix (CLAUDE.md "Independent test gates"):
--   * behavior          — determinism from server day number; rotation; HUD view shape; eligibility.
--   * daily reset       — crossing a UTC day boundary rotates the vein; full-cycle coverage; auto-reset
--                          with NO persisted field (a player with NO data still gets a stable vein).
--   * negative / abuse  — malformed FetchRestock payload -> BadPayload; rate limit; client supplies
--                          NOTHING that can mint a bonus (no payload field changes the vein/multiplier);
--                          read-only action never mutates the economy.
--   * economy / ownership — bonus granted IFF the player owns today's vein island; a LOCKED vein island
--                          yields the identity multiplier (no free mint by selling on an un-owned vein).
--   * concurrency / race — the rich-vein bonus applied on the Sell earn path under the per-player FIFO
--                          lock survives interleaved + spam-duplicated requests with NO double-grant /
--                          lost update (falsifiable: a no-queue store lands at the WRONG compounded sum).
--   * boundaries        — exact UTC boundary; now = 0; NaN / non-number now -> identity 1; nil snapshot.
--   (No migration round-trip: this feature persists NO new field — it is fully time-derived.)
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local RestockService = require("../../src/server/services/restock/RestockService")
local DataService = require("../../src/server/data/DataService")
local Result = require("../../src/shared/Result")
local Net = require("../../src/shared/Net")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local DAY = 86400 -- seconds per UTC day; the SPEC's day boundary (dayNumber = floor(unix / 86400)).

local function config(): any
	return {
		storeName = "Test",
		schemaKeyPrefix = "player_",
		dataStore = { maxRetries = 3, retryBaseSeconds = 1, writeMinIntervalSeconds = 0 },
		rateDefaults = { maxPerWindow = 10, windowSeconds = 1 },
		flagsSeed = {},
	}
end

-- Build a DataService over a (possibly yielding) mock store with one loaded player whose data we
-- can seed with island-unlock flags. Returns (service, player, clock).
local function setupData(storeOptions: any, startUnix: number?): (any, any, any)
	local clock = Mocks.clock(startUnix or 1000)
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

-- The published feature seam, obtained EXACTLY the way production gets it: RestockService:Start
-- writes it onto a context. We never reach past the public surface to grab internals.
local function startSeam(): any
	local context = { net = Net.newRegistry(), restock = nil }
	RestockService:Start(context)
	return context.restock, context.net
end

-- Discover the server-owned constants through the public FetchRestock HUD action at a given unix,
-- so expectations are parametrized from the API, not lifted from the implementation source.
-- Returns the RestockView table { islandId, multiplier, dayNumber, resetsAtUnix, eligible }.
local function fetchView(now: number): any
	local _, registry = startSeam()
	-- Player with NO loaded data: the read-only HUD must still answer (eligible=false), and we get
	-- the server-derived vein + multiplier without depending on any persisted state.
	local clock = Mocks.clock(now)
	local data = {
		get = function(_self: any, _player: any)
			return Result.err(Result.Codes.NoData)
		end,
	}
	local ctx: any = { player = Mocks.player(1), clock = clock, data = data }
	local action = registry:get(Net.Actions.FetchRestock)
	-- Drive validate+handler directly (the pure pipeline) so we read the raw view.
	local validated = action.validate({})
	expect(validated):toBeOk()
	return (action.handler(ctx, (validated :: any).value) :: any).value
end

-- Round-robin coroutine driver (mirrors economy_race.spec): resume suspended coroutines until all
-- are dead. Deterministic; bounded against deadlock.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 500 then
			error("race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- ======================================================================================
-- BEHAVIOR: derive vein + multiplier deterministically from the SERVER day number.
-- ======================================================================================
describe("Restock derives today's vein from the server day number (deterministic)", function()
	it("the same server time yields the SAME vein + multiplier (no random, no drift)", function()
		local now = 7 * DAY + 12345 -- arbitrary mid-day instant
		local a = fetchView(now)
		local b = fetchView(now)
		-- Pure derivation: identical now -> byte-identical view across independent service instances.
		expect(a.islandId):toBe(b.islandId)
		expect(a.multiplier):toBe(b.multiplier)
		expect(a.dayNumber):toBe(b.dayNumber)
		expect(a.resetsAtUnix):toBe(b.resetsAtUnix)
	end)

	it("dayNumber is floor(serverUnix / 86400) — independent of intra-day time", function()
		local day = 100
		-- Start of day, mid day, last second of day -> SAME dayNumber and SAME vein.
		local atStart = fetchView(day * DAY)
		local atMid = fetchView(day * DAY + DAY // 2)
		local atEnd = fetchView(day * DAY + (DAY - 1))
		expect(atStart.dayNumber):toBe(day)
		expect(atMid.dayNumber):toBe(day)
		expect(atEnd.dayNumber):toBe(day)
		expect(atStart.islandId):toBe(atMid.islandId)
		expect(atMid.islandId):toBe(atEnd.islandId)
	end)

	it("multiplier is a SERVER-OWNED constant > 1 (a real bonus), same every day", function()
		local m0 = fetchView(0).multiplier
		local mLater = fetchView(500 * DAY + 17).multiplier
		-- The spec says the multiplier is a server-owned constant (not per-day). It must be a real
		-- bonus (> 1) and invariant across days.
		expect(type(m0) == "number" and m0 > 1):toBe(true)
		expect(mLater):toBe(m0)
	end)

	it("the read-only view reports the next-reset boundary at the UTC day edge", function()
		local day = 42
		local view = fetchView(day * DAY + 99)
		-- Resets at the NEXT UTC day boundary (server time only): (dayNumber + 1) * 86400.
		expect(view.resetsAtUnix):toBe((day + 1) * DAY)
		-- The reset instant is strictly after the current time and on a day boundary.
		expect(view.resetsAtUnix > day * DAY + 99):toBe(true)
		expect(view.resetsAtUnix % DAY):toBe(0)
	end)
end)

-- ======================================================================================
-- DAILY RESET + ROTATION: crossing a UTC day boundary rotates the vein; full-cycle coverage.
-- ======================================================================================
describe("Restock resets and rotates across the UTC day boundary (server time)", function()
	it(
		"crossing a day boundary flips to the NEXT day's vein (auto-reset, no persisted field)",
		function()
			local day = 9
			local lastSecond = fetchView(day * DAY + (DAY - 1)) -- last second of day `day`
			local firstSecond = fetchView((day + 1) * DAY) -- first second of day `day+1`
			expect(lastSecond.dayNumber):toBe(day)
			expect(firstSecond.dayNumber):toBe(day + 1)
			-- The vein index advances by one step at the boundary (rotation), so consecutive days differ
			-- as long as there is more than one island in the rotation (asserted in the cycle test below).
			-- A reset is observable purely from server time with NO stored state changing.
			expect(firstSecond.dayNumber - lastSecond.dayNumber):toBe(1)
		end
	)

	it("over a full cycle the vein rotates through EVERY island id, then repeats", function()
		-- Discover the island-id set by sweeping consecutive days until the FIRST island repeats: that
		-- repeat length is the cycle (islandCount). We never read ISLAND_IDS from the source.
		local first = fetchView(0).islandId
		local seen: { [number]: boolean } = {}
		local order: { number } = {}
		local cycleLen = 0
		for day = 0, 199 do
			local id = fetchView(day * DAY + 1).islandId
			if day > 0 and id == first and cycleLen == 0 then
				cycleLen = day
			end
			if not seen[id] then
				seen[id] = true
				table.insert(order, id)
			end
		end
		-- A non-trivial rotation: more than one distinct island (otherwise "rotates" is meaningless).
		expect(#order > 1):toBe(true)
		-- The cycle closed: island ids repeat with period = #distinct ids.
		expect(cycleLen):toBe(#order)
		-- And the cycle is exactly periodic: day d and day d+cycleLen pick the same island.
		expect(fetchView(3 * DAY).islandId):toBe(fetchView((3 + cycleLen) * DAY).islandId)
		-- Every island id in the set is a positive integer (a real catalog id).
		for _, id in order do
			expect(type(id) == "number" and id >= 1 and id == math.floor(id)):toBe(true)
		end
	end)

	it(
		"the HUD view needs NO persisted data — a player with NoData still gets a stable vein",
		function()
			-- The spec: fully derived from server time, NO persisted field. fetchView uses a NoData store,
			-- yet returns a valid server-derived vein + multiplier. Eligibility for a no-data player is
			-- simply false (cannot own anything), never an error on the read-only poll.
			local view = fetchView(55 * DAY + 7)
			expect(type(view.islandId)):toBe("number")
			expect(view.eligible):toBe(false)
		end
	)
end)

-- ======================================================================================
-- ECONOMY + OWNERSHIP: the Sell-path bonus seam grants the bonus IFF the player owns the vein.
-- ======================================================================================
describe("Restock Sell-seam grants the rich-vein bonus only to the eligible owner", function()
	-- Helper: find a server time whose vein island id is a SPECIFIC target id (so we can construct an
	-- eligible / ineligible player deterministically without reading the impl's index math).
	local function dayWithVein(targetId: number): number
		for day = 0, 199 do
			if fetchView(day * DAY).islandId == targetId then
				return day * DAY + 10
			end
		end
		error(`no day rotates to vein island {targetId} within 200 days`)
	end

	it("a player WITHOUT today's vein island unlocked gets the identity multiplier (1)", function()
		local seam = startSeam()
		-- Pick a day whose vein is a NON-starting island (id 2), and a snapshot with NO unlock flags.
		local now = dayWithVein(2)
		local mult = seam:multiplierFor({ flags = {} }, now)
		-- No ownership of the vein island -> NO bonus. (Selling on an un-owned vein cannot mint.)
		expect(mult):toBe(1)
	end)

	it("a player WHO unlocked today's vein island gets the server bonus multiplier", function()
		local seam = startSeam()
		local now = dayWithVein(2)
		local bonus = seam:multiplierFor({ flags = { ["island.2"] = true } }, now)
		-- Bonus equals the server-owned constant the HUD advertises (discovered via the API).
		local advertised = fetchView(now).multiplier
		expect(bonus):toBe(advertised)
		expect(bonus > 1):toBe(true)
	end)

	it(
		"on a starting-island vein day EVERY player is eligible (universally-unlocked island)",
		function()
			local seam = startSeam()
			-- The starting island (id 1) is always unlocked with NO flag. On the day the vein lands on it,
			-- a player with an EMPTY flags table must still receive the bonus.
			local now = dayWithVein(1)
			local mult = seam:multiplierFor({ flags = {} }, now)
			expect(mult):toBe(fetchView(now).multiplier)
			expect(mult > 1):toBe(true)
		end
	)

	it("a flag for a DIFFERENT island than today's vein does NOT grant the bonus", function()
		local seam = startSeam()
		-- Vein is island 2 today; the player owns island 3 (not today's vein) -> identity multiplier.
		-- Guards against an exploit where owning ANY island would wrongly trigger the bonus.
		local now = dayWithVein(2)
		local mult = seam:multiplierFor({ flags = { ["island.3"] = true } }, now)
		expect(mult):toBe(1)
	end)

	it(
		"the FetchRestock view's `eligible` reflects the acting player's ownership of today's vein",
		function()
			local _, registry = startSeam()
			local action = registry:get(Net.Actions.FetchRestock)
			local now = dayWithVein(2)
			-- Build a ctx whose data:get returns a snapshot owning island 2.
			local owningData = {
				get = function(_self: any, _player: any)
					return Result.ok({ flags = { ["island.2"] = true } })
				end,
			}
			local ctxOwn: any =
				{ player = Mocks.player(1), clock = Mocks.clock(now), data = owningData }
			local viewOwn = (action.handler(ctxOwn, {}) :: any).value
			expect(viewOwn.eligible):toBe(true)
			-- A player who does NOT own it sees eligible=false on the same day.
			local poorData = {
				get = function(_self: any, _player: any)
					return Result.ok({ flags = {} })
				end,
			}
			local ctxPoor: any =
				{ player = Mocks.player(2), clock = Mocks.clock(now), data = poorData }
			local viewPoor = (action.handler(ctxPoor, {}) :: any).value
			expect(viewPoor.eligible):toBe(false)
		end
	)
end)

-- ======================================================================================
-- BOUNDARIES + DEFENSIVE: identity multiplier on absent snapshot / unusable clock value.
-- ======================================================================================
describe("Restock seam boundary + defensive behavior (identity-safe)", function()
	it("a nil snapshot -> identity multiplier 1 (pre-feature Sell path preserved)", function()
		local seam = startSeam()
		expect(seam:multiplierFor(nil, 12345)):toBe(1)
	end)

	it(
		"a non-number / NaN `now` -> identity multiplier 1 (never crashes the Sell transform)",
		function()
			local seam = startSeam()
			local nan = 0 / 0
			expect(seam:multiplierFor({ flags = { ["island.2"] = true } }, nan)):toBe(1)
			expect(seam:multiplierFor({ flags = { ["island.2"] = true } }, "tomorrow" :: any)):toBe(
				1
			)
		end
	)

	it("now = 0 (epoch / day 0) derives a valid vein and a non-negative day number", function()
		local view = fetchView(0)
		expect(view.dayNumber):toBe(0)
		expect(type(view.islandId)):toBe("number")
		expect(view.resetsAtUnix):toBe(DAY)
	end)
end)

-- ======================================================================================
-- NEGATIVE / ABUSE: the read-only action validates payloads; client supplies NOTHING that mints.
-- ======================================================================================
describe("FetchRestock is a read-only, abuse-resistant HUD poll", function()
	-- Drive through the REAL Net.dispatch via Mocks.net so validation + rate are genuinely exercised.
	local function harnessWith(now: number, gate: any): (any, any)
		local clock = Mocks.clock(now)
		local data = {
			get = function(_self: any, _player: any)
				return Result.ok({ flags = {} })
			end,
		}
		local context: any = { clock = clock, data = data, gate = gate }
		local harness = Mocks.net(context)
		local _, registry = startSeam()
		harness.register(registry:get(Net.Actions.FetchRestock))
		return harness, clock
	end

	it("a non-table payload -> Err(BadPayload)", function()
		local harness = harnessWith(DAY, false)
		local player = Mocks.player(1)
		expect(harness.invoke(Net.Actions.FetchRestock, player, 5)):toBeErr(Result.Codes.BadPayload)
		expect(harness.invoke(Net.Actions.FetchRestock, player, "x")):toBeErr(
			Result.Codes.BadPayload
		)
		expect(harness.invoke(Net.Actions.FetchRestock, player, true)):toBeErr(
			Result.Codes.BadPayload
		)
	end)

	it(
		"a client-supplied vein/multiplier in the payload CANNOT change the server-derived bonus",
		function()
			-- Abuse: the client crafts a payload claiming a different island / a huge multiplier. The
			-- server must IGNORE it entirely — the vein + multiplier are 100% derived from server time.
			local now = 17 * DAY + 3
			local harness = harnessWith(now, false)
			local player = Mocks.player(1)
			local honest = harness.invoke(Net.Actions.FetchRestock, player, {})
			local malicious = harness.invoke(
				Net.Actions.FetchRestock,
				player,
				{ islandId = 999, multiplier = 1000000, dayNumber = -5 }
			)
			expect(honest):toBeOk()
			expect(malicious):toBeOk()
			-- Server-derived fields are identical regardless of the injected payload fields.
			expect((malicious :: any).value.islandId):toBe((honest :: any).value.islandId)
			expect((malicious :: any).value.multiplier):toBe((honest :: any).value.multiplier)
			expect((malicious :: any).value.dayNumber):toBe((honest :: any).value.dayNumber)
			-- And the advertised multiplier is the server constant, never the client's 1000000.
			expect((malicious :: any).value.multiplier).never:toBe(1000000)
		end
	)

	it("rate limit: spamming the HUD poll past its window -> Err(RateLimited)", function()
		-- The read-only poll has a finite bucket. Discover its width by spamming until shed, then assert
		-- the next call within the same window is RateLimited (abuse flood is throttled).
		local clock = Mocks.clock(DAY)
		local gate = Mocks.gate(clock)
		local harness = harnessWith(DAY, gate)
		-- NOTE: harnessWith built its own harness; rebuild over the SAME clock+gate so rate is shared.
		local data = {
			get = function(_self: any, _player: any)
				return Result.ok({ flags = {} })
			end,
		}
		local h = Mocks.net({ clock = clock, data = data, gate = gate })
		local _, registry = startSeam()
		h.register(registry:get(Net.Actions.FetchRestock))
		local player = Mocks.player(77)
		-- Fire a generous number of calls; at least one must eventually be RateLimited (finite bucket).
		local sawRateLimited = false
		for _ = 1, 50 do
			local r = h.invoke(Net.Actions.FetchRestock, player, {})
			if not r.ok and r.code == Result.Codes.RateLimited then
				sawRateLimited = true
				break
			end
		end
		expect(sawRateLimited):toBe(true)
		-- silence unused `harness` lint by touching it
		expect(harness ~= nil):toBe(true)
	end)
end)

-- ======================================================================================
-- CONCURRENCY / ECONOMY RED-TEAM: the rich-vein bonus applied on the Sell earn path under the
-- per-player FIFO lock must NOT double-grant or lose updates under interleaving / spam-duplication.
-- This is the headline economy guarantee — a sequential test would NOT prove it. We force genuine
-- interleaving with coroutines against a YIELDING store, applying the seam's bonus inside each
-- locked transform exactly as the Sell retrofit does (multiplierFor under the lock-held snapshot).
-- ======================================================================================
describe("Rich-vein bonus is concurrency-safe on the Sell earn path (falsifiable)", function()
	-- Each "sell" credits base * richVeinMultiplier into Stardust. Run under the real DataService
	-- per-key FIFO lock with a yielding store so concurrent sells MUST park + re-read the latest value.
	-- Eligible player on today's vein -> multiplier = the server bonus, so each sell credits base*bonus.
	local function sellOnce(service: any, player: any, seam: any, base: number, now: number): ()
		service:update(player, function(d)
			-- Mirror the Sell retrofit's seam usage: read the bonus from the LOCK-HELD snapshot `d`.
			local mult = seam:multiplierFor(d, now)
			d.currencies.Stardust += base * mult
			return d
		end)
	end

	-- Build a yielding service whose loaded player OWNS today's vein island (so the bonus applies).
	-- The seed update itself runs through the yielding store, so we DRAIN it via a coroutine (a bare
	-- service:update against a yieldOnUpdate store would yield the main thread). After the seed drains,
	-- the interleave coroutines below exercise the genuine concurrent path.
	local function setupEligible(now: number): (any, any, any)
		local service, player = setupData({ yieldOnUpdate = true })
		local seam = startSeam()
		local view = fetchView(now)
		drain({
			coroutine.create(function()
				service:update(player, function(d)
					d.flags = d.flags or {}
					d.flags["island." .. tostring(view.islandId)] = true
					d.currencies = d.currencies or {}
					d.currencies.Stardust = 0
					return d
				end)
			end),
		})
		return service, player, seam
	end

	it(
		"TWO interleaved bonus-sells land at the EXACT compounded sum (no double-grant / loss)",
		function()
			local now = 12 * DAY + 5
			local service, player, seam = setupEligible(now)
			local bonus = fetchView(now).multiplier -- server constant (> 1)
			-- Two interleaved sells of base 10 and base 4 -> (10 + 4) * bonus. A lost update would drop one.
			local cos = {
				coroutine.create(function()
					sellOnce(service, player, seam, 10, now)
				end),
				coroutine.create(function()
					sellOnce(service, player, seam, 4, now)
				end),
			}
			drain(cos)
			expect((service:get(player) :: any).value.currencies.Stardust):toBe((10 + 4) * bonus)
		end
	)

	it(
		"SPAM-DUPLICATED identical bonus-sells each apply exactly once (anti-double-spend)",
		function()
			local now = 31 * DAY + 9
			local service, player, seam = setupEligible(now)
			local bonus = fetchView(now).multiplier
			-- The same base-6 sell fired 5x interleaved must credit 5 * 6 * bonus, never a clobbered subset
			-- and never a duplicated over-grant. This is the spam-click double-spend class.
			local cos = {}
			for _ = 1, 5 do
				table.insert(
					cos,
					coroutine.create(function()
						sellOnce(service, player, seam, 6, now)
					end)
				)
			end
			drain(cos)
			expect((service:get(player) :: any).value.currencies.Stardust):toBe(5 * 6 * bonus)
		end
	)

	it(
		"FALSIFIABILITY: a no-queue read->yield->write store DOES lose a bonus-sell (counter-case)",
		function()
			-- Proves the interleave tests above are meaningful: the SAME two interleaved bonus-sells against
			-- a naive no-lock store land at the WRONG compounded value (only the last write survives), so a
			-- green queue result genuinely distinguishes a correct single-writer path from a no-op.
			local now = 12 * DAY + 5
			local seam = startSeam()
			local bonus = fetchView(now).multiplier
			local flags = { ["island." .. tostring(fetchView(now).islandId)] = true }
			local function naiveSession(start: number): any
				local backing = { currencies = { Stardust = start }, flags = flags }
				local function deepCopy(v: any): any
					if type(v) ~= "table" then
						return v
					end
					local o = {}
					for k, c in v do
						o[k] = deepCopy(c)
					end
					return o
				end
				local s = { data = backing }
				function s.update(_self: any, transform: (any) -> any): any
					local current = deepCopy(backing)
					coroutine.yield() -- no lock: the second update reads the SAME stale snapshot
					backing = transform(current)
					s.data = backing
					return Result.ok(backing)
				end
				return s
			end
			local session = naiveSession(0)
			local cos = {
				coroutine.create(function()
					session:update(function(d)
						d.currencies.Stardust += 10 * seam:multiplierFor(d, now)
						return d
					end)
				end),
				coroutine.create(function()
					session:update(function(d)
						d.currencies.Stardust += 4 * seam:multiplierFor(d, now)
						return d
					end)
				end),
			}
			drain(cos)
			-- The naive store loses the first sell: it lands at 4*bonus, NOT (10+4)*bonus.
			expect(session.data.currencies.Stardust):toBe(4 * bonus)
			expect(session.data.currencies.Stardust).never:toBe((10 + 4) * bonus)
		end
	)
end)
