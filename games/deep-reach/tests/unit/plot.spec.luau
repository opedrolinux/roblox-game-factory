--!strict
-- games/deep-reach/tests/unit/plot.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/plot.md, NOT from
--  PlotService's control flow. The implementation was read ONLY to learn its observable interface
--  (return shapes, method names); every expectation below is derived from the slice.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   * "claim a free dome on join, persist which plot, release cleanly on leave, and refuse a second
--      claim"
--   * "Never two players on one plot; never two plots for one player — including under interleaved
--      and spam-duplicated claims arriving in the same frame."
--   * a second claim is Err(AlreadyClaimed), NOT Err(Rejected) (which the spine reserves for panic);
--     a full server is Err(Unavailable).
--   * "on PlayerRemoving / session release the plot is freed and is immediately re-claimable by the
--      NEXT player. The leave->claim race must neither leak a plot forever nor hand one plot to two
--      players."
--   * rejoin: "A persisted plotId whose plot is already held on THIS server must not be honoured —
--     re-claim a free one and rewrite the field."
--   * "the payload carries NO plot id (the server picks; a client-named plot IS the plot-claim-hijack
--      exploit)"
--   * NOT THIS SLICE: "any currency mutation whatsoever".
--   * AMENDMENT A1: the dome root is placed, on a FIRST claim AND on every rejoin, at the Y of the
--     player's PERSISTED tier via the nil-safe `ctx.depth:tierYFor(data)` seam; absent seam -> tier 1.
--
-- WHY THE CONCURRENCY TESTS LOOK LIKE THIS. A dome is a single-writer scarce resource with exactly
-- the double-spend failure mode of a balance: read "is it free", YIELD in ctx.data:update, then
-- write. Sequential calls cannot distinguish a correct implementation from a broken one, because
-- nothing ever interleaves. So the race cases below drive the SAME technique economy_race.spec uses:
-- a MockStore with `yieldOnUpdate` (a forced yield inside the update critical section) plus a
-- round-robin coroutine driver, and each is paired with a FALSIFICATION counter-case proving the
-- interleave is real (a pick-then-yield-then-occupy registry, driven at the same yield point, DOES
-- hand one dome to two players).
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local PlotService = require("../../src/server/services/plot/PlotService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")
local Types = require("../../src/shared/Types")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- ── helpers ─────────────────────────────────────────────────────────────────────────────────────

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out: any = {}
	for key, child in value do
		out[key] = deepCopy(child)
	end
	return out
end

-- Round-robin coroutine driver (the economy_race.spec idiom): resume every suspended coroutine
-- repeatedly until all are dead. Deterministic, deadlock-bounded.
local function drain(cos: { thread }): ()
	local live: { thread } = {}
	for _, co in cos do
		table.insert(live, co)
	end
	local guard = 0
	while #live > 0 do
		guard += 1
		if guard > 500 then
			error("plot race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`plot race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- A fresh server: real DataService over the real MockStore, PlotService Started against a fake `net`
-- that only records the actions it registers. `Start` is the ONLY way the ctx.plot seam is obtained,
-- which is deliberate — a spec that reached into the module for its private seam table would not be
-- testing the thing gameplay code actually gets.
--
-- NOTE: set `h.depth` BEFORE calling `h:wire(...)`; Mocks.net captures the context table it is given.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or 1000)
	local store = Mocks.store({
		clock = clock,
		config = Config,
		yieldOnUpdate = opts.yieldOnUpdate,
	})
	local data = DataService.new(store, clock, Config, Mocks.logWarn)

	local registered: { [string]: any } = {}
	local startContext: any = {
		clock = clock,
		data = data,
		net = {
			register = function(_self: any, action: any): ()
				registered[action.name] = action
			end,
		},
	}
	PlotService:Start(startContext)
	if opts.plotCount ~= nil then
		PlotService:build(opts.plotCount)
	end

	local h: any = {
		clock = clock,
		store = store,
		data = data,
		seam = startContext.plot,
		registered = registered,
		depth = nil,
	}

	-- The ActionContext a direct `acquire` call receives (read fresh each call, so a test may attach
	-- a depth seam between calls — which is exactly the "rejoin at a deeper tier" scenario).
	function h.ctx(self: any): any
		return { clock = self.clock, data = self.data, plot = self.seam, depth = self.depth }
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net, with plot.claim / plot.fetch
	-- registered from the service's own action factories.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local netHarness = Mocks.net({
			clock = self.clock,
			data = self.data,
			plot = self.seam,
			depth = self.depth,
			security = w.security,
			gate = if w.gate ~= nil then w.gate else false,
		})
		netHarness.register(PlotService:claimAction())
		netHarness.register(PlotService:fetchAction())
		return netHarness
	end

	function h.join(self: any, userId: number): any
		local player = Mocks.player(userId)
		expect(self.data:loadSession(player)):toBeOk()
		return player
	end

	-- The pinned A10b leave order's two plot-relevant steps: free the dome, then release the session.
	function h.leave(self: any, player: any): ()
		self.seam:releaseFor(player)
		self.data:onPlayerRemoving(player)
	end

	function h.blob(self: any, player: any): any
		local got = self.data:get(player)
		expect(got):toBeOk()
		return (got :: any).value
	end

	return h
end

-- Drive `awaitLoaded`'s poll loop deterministically: `hook(attemptIndex)` runs in place of the
-- 0.25s sleep, which is exactly the window where the world moves (the load resolves, the player
-- leaves, DataService's yielding release keeps `_sessions[uid]` populated). The real `_wait` is
-- ALWAYS restored, even when the body throws, so one red case cannot poison every later one.
local function runWithWaitHook(hook: (number) -> (), body: () -> ()): ()
	local realWait = PlotService._wait
	local attempts = 0
	PlotService._wait = function(_self: any, _seconds: number): ()
		attempts += 1
		hook(attempts)
	end
	local ok, err = pcall(body)
	PlotService._wait = realWait
	if not ok then
		error(err, 0)
	end
end

local function claimVia(netHarness: any, player: any, payload: any?): any
	return netHarness.invoke(Net.Actions.ClaimPlot, player, payload)
end

local function fetchVia(netHarness: any, player: any, payload: any?): any
	return netHarness.invoke(Net.Actions.FetchPlot, player, payload)
end

-- ── 1. the seam + the registry ──────────────────────────────────────────────────────────────────

describe("plot: the ctx.plot seam and the per-server registry", function()
	it("Start installs the seam and registers exactly the two contracted actions", function()
		local h = newServer()
		expect(type(h.seam)):toBe("table")
		for _, method in { "plotIdFor", "rootFor", "ownerOf", "releaseFor" } do
			expect(type((h.seam :: any)[method])):toBe("function")
		end
		expect(h.registered[Net.Actions.ClaimPlot] ~= nil):toBe(true)
		expect(h.registered[Net.Actions.FetchPlot] ~= nil):toBe(true)
		-- Both actions must declare a real, non-degenerate rate policy (the Gate refuses a
		-- maxPerWindow <= 0 outright, so a missing policy would lock the feature out entirely).
		for _, name in { Net.Actions.ClaimPlot, Net.Actions.FetchPlot } do
			local action = h.registered[name]
			expect(type(action.validate)):toBe("function")
			expect(type(action.handler)):toBe("function")
			expect(action.rate.maxPerWindow > 0):toBe(true)
			expect(action.rate.windowSeconds > 0):toBe(true)
		end
	end)

	it("every seat gets a dome: the registry is never smaller than the server it serves", function()
		-- A registry SMALLER than MaxPlayers would refuse a legitimate joiner with Unavailable —
		-- a capacity bug wearing a correct-looking error code.
		--
		-- REGRESSION (F1/F5): the seat table deliberately runs PAST the old 50-dome ceiling. Nothing
		-- in this game pins MaxPlayers — it is a Studio place setting and Roblox allows it up to 200 —
		-- so a table that stopped at the clamp constant asserted the invariant in its own comment
		-- while being constructed so it could never observe the violation.
		for _, seats in { 4, 8, 12, 30, 50, 51, 60, 100, 200 } do
			expect(PlotService:plotCountFor(seats)):toBe(seats)
		end
		-- Unreadable / nonsense seat counts must still produce a USABLE registry, never 0 (which
		-- would make every claim on the server Unavailable).
		for _, bogus in { "twelve", true, -3, 0 / 0 } do
			expect(PlotService:plotCountFor(bogus) >= 1):toBe(true)
		end
		expect(PlotService:plotCountFor(nil) >= 1):toBe(true)
		expect(PlotService:plotCountFor(1) >= 1):toBe(true)
	end)

	it(
		"REGRESSION (F1/F5): a 60-seat place gets 60 DOMES — the 51st joiner is not refused Unavailable",
		function()
			-- `plotCountFor` answering 60 is not enough on its own: `build` re-applies the ceiling
			-- independently, so the registry Start actually stands up is the thing that has to be
			-- big enough. Drive the whole path the way Start does — desiredPlotCount -> build — and
			-- then take the seat that used to fall off the end.
			expect(PlotService:build(PlotService:plotCountFor(60))):toBe(60)
			expect(PlotService:plotCount()):toBe(60)
			expect(PlotService:freeCount()):toBe(60)
			expect(#PlotService:plotIds()):toBe(60)

			-- The decisive consequence, at the seat that used to be past the clamp: with 60 seats
			-- sold, the 51st and the 60th joiner must each get a dome, not a correct-looking refusal.
			local h = newServer({ plotCount = PlotService:plotCountFor(60) })
			local net = h:wire()
			local seen: { [string]: boolean } = {}
			for seat = 1, 60 do
				local claimed = claimVia(net, h:join(1000 + seat))
				expect(claimed):toBeOk()
				local plotId = (claimed :: any).value.plotId
				expect(seen[plotId]):toBe(nil) -- and still exactly one dome per player
				seen[plotId] = true
			end
			expect(PlotService:freeCount()):toBe(0)

			-- The ceiling still exists and is still sane: a nonsense-huge seat count cannot ask this
			-- server to stand up an unbounded registry.
			expect(PlotService:plotCountFor(100000) <= 200):toBe(true)
			expect(PlotService:plotCountFor(100000) >= 1):toBe(true)
		end
	)

	it("build produces distinct ids and resets every claim (a clean server)", function()
		local h = newServer({ plotCount = 5 })
		local ids = PlotService:plotIds()
		expect(#ids):toBe(5)
		local seen: { [string]: boolean } = {}
		for _, id in ids do
			expect(type(id)):toBe("string")
			expect(id ~= ""):toBe(true)
			expect(seen[id]):toBe(nil)
			seen[id] = true
		end
		expect(PlotService:freeCount()):toBe(5)
		local player = h:join(1)
		expect(PlotService:acquire(h:ctx(), player)):toBeOk()
		expect(PlotService:freeCount()):toBe(4)
		PlotService:build(5)
		expect(PlotService:freeCount()):toBe(5)
		expect(h.seam:plotIdFor(player)):toBe(nil)
	end)

	it("the seam answers nil for every shape that holds nothing, and never throws", function()
		local h = newServer({ plotCount = 3 })
		local ids = PlotService:plotIds()
		expect(h.seam:plotIdFor(nil)):toBe(nil)
		expect(h.seam:plotIdFor({})):toBe(nil)
		expect(h.seam:plotIdFor(Mocks.player(404))):toBe(nil)
		expect(h.seam:ownerOf(nil)):toBe(nil)
		expect(h.seam:ownerOf(123)):toBe(nil)
		expect(h.seam:ownerOf({})):toBe(nil)
		expect(h.seam:ownerOf("dome_does_not_exist")):toBe(nil)
		expect(h.seam:ownerOf(ids[1])):toBe(nil) -- a FREE dome has no owner
		-- rootFor is an Instance? — nil under Lune (no world was built), and must not error.
		expect(h.seam:rootFor(Mocks.player(1))):toBe(nil)
		expect(h.seam:releaseFor(nil)):toBe(false)
		expect(h.seam:releaseFor(Mocks.player(404))):toBe(false)
	end)

	it("a player with no numeric UserId claims nothing (identity comes from the field)", function()
		local h = newServer({ plotCount = 3 })
		local before = PlotService:freeCount()
		expect(PlotService:acquire(h:ctx(), { Name = "ghost" })):toBeErr(Result.Codes.BadType)
		expect(PlotService:acquire(h:ctx(), { UserId = "1", Name = "spoof" })):toBeErr(
			Result.Codes.BadType
		)
		expect(PlotService:freeCount()):toBe(before)
	end)
end)

-- ── 2. claim on join ────────────────────────────────────────────────────────────────────────────

describe("plot: claim a free dome on join, and persist WHICH dome", function()
	it(
		"a fresh join claims a dome and persists plotId + claimedAtUnix on the SERVER clock",
		function()
			local h = newServer({ plotCount = 6, startUnix = 4242000 })
			local net = h:wire()
			local player = h:join(11)
			h.clock:advance(137) -- the claim happens later than the load; the stamp must follow the clock

			local claimed = claimVia(net, player)
			expect(claimed):toBeOk()
			local info = (claimed :: any).value
			expect(info.held):toBe(true)
			expect(type(info.plotId)):toBe("string")
			expect(info.plotId ~= ""):toBe(true)

			-- in-memory truth and persisted truth agree
			expect(h.seam:plotIdFor(player)):toBe(info.plotId)
			expect(h.seam:ownerOf(info.plotId)):toBe(11)
			local blob = h:blob(player)
			expect(blob.plot.plotId):toBe(info.plotId)
			-- SERVER clock, not 0 and not the load-time value.
			expect(blob.plot.claimedAtUnix):toBe(4242137)
			expect(blob.plot.claimedAtUnix):toBe(h.clock:unix())
			expect(PlotService:freeCount()):toBe(5)
		end
	)

	it("the claimed dome is a FREE one — a second player never lands on the first's", function()
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local p1 = h:join(1)
		local p2 = h:join(2)
		local a = (claimVia(net, p1) :: any).value
		local b = (claimVia(net, p2) :: any).value
		expect(a.plotId ~= b.plotId):toBe(true)
		expect(h.seam:ownerOf(a.plotId)):toBe(1)
		expect(h.seam:ownerOf(b.plotId)):toBe(2)
		expect(PlotService:freeCount()):toBe(2)
	end)

	it("a claim before the session has loaded allocates NOTHING", function()
		local h = newServer({ plotCount = 3 })
		local net = h:wire()
		local player = Mocks.player(9) -- never loadSession'd: the join-race window
		local before = PlotService:freeCount()
		expect(claimVia(net, player)):toBeErr(Result.Codes.NoData)
		expect(PlotService:freeCount()):toBe(before)
		expect(h.seam:plotIdFor(player)):toBe(nil)
	end)

	it("claiming mutates NO currency and no other persisted record (not this slice)", function()
		local h = newServer({ plotCount = 1 })
		local net = h:wire()
		local p1 = h:join(1)
		local p2 = h:join(2) -- will be refused (Unavailable) — refusals must not mint either

		local function snapshot(player: any): any
			local blob = h:blob(player)
			return {
				currencies = deepCopy(blob.currencies),
				stats = deepCopy(blob.stats),
				timestamps = deepCopy(blob.timestamps),
				smelter = deepCopy(blob.smelter),
				daily = deepCopy(blob.daily),
				upgrades = deepCopy(blob.upgrades),
				flags = deepCopy(blob.flags),
				receipts = deepCopy(blob.receipts),
				resurfaces = blob.resurfaces,
				boostExpiresUnix = blob.boostExpiresUnix,
			}
		end

		local before1 = snapshot(p1)
		local before2 = snapshot(p2)

		expect(claimVia(net, p1)):toBeOk() -- success
		expect(claimVia(net, p1)):toBeErr(Result.Codes.AlreadyClaimed) -- refusal (duplicate)
		expect(claimVia(net, p2)):toBeErr(Result.Codes.Unavailable) -- refusal (full)
		expect(fetchVia(net, p1)):toBeOk()
		h.seam:releaseFor(p1)
		expect(claimVia(net, p2)):toBeOk() -- the re-claim

		expect(snapshot(p1)):toEqual(before1)
		expect(snapshot(p2)):toEqual(before2)
		-- and specifically the leaderboard's ranking key + the spendable balance:
		expect(h:blob(p1).currencies.Credits):toBe(before1.currencies.Credits)
		expect(h:blob(p1).stats.lifetimeCredits):toBe(0)
		expect(h:blob(p2).stats.lifetimeCredits):toBe(0)
	end)
end)

-- ── 3. refuse a second claim (and stay distinguishable from panic) ──────────────────────────────

describe("plot: a second claim is refused, distinguishably", function()
	it("the second claim is Err(AlreadyClaimed) and re-allocates nothing", function()
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local player = h:join(1)
		local first = (claimVia(net, player) :: any).value
		local firstStamp = h:blob(player).plot.claimedAtUnix

		h.clock:advance(500) -- a re-stamp would be visible
		expect(claimVia(net, player)):toBeErr(Result.Codes.AlreadyClaimed)
		expect(claimVia(net, player)):toBeErr(Result.Codes.AlreadyClaimed)

		expect(h.seam:plotIdFor(player)):toBe(first.plotId)
		expect(PlotService:freeCount()):toBe(3) -- exactly ONE dome consumed by three claims
		expect(h:blob(player).plot.plotId):toBe(first.plotId)
		expect(h:blob(player).plot.claimedAtUnix):toBe(firstStamp) -- idempotent: no re-stamp
	end)

	it(
		"AlreadyClaimed is NOT the panic code — 'refused a duplicate' and 'server panicked' differ",
		function()
			expect(Result.Codes.AlreadyClaimed ~= Result.Codes.Rejected):toBe(true)

			local h = newServer({ plotCount = 4 })
			local player = h:join(1)

			-- panicked server: the spine's blanket refusal
			local panicked = h:wire({
				security = {
					isPanicked = function(_self: any): boolean
						return true
					end,
				},
			})
			expect(claimVia(panicked, player)):toBeErr(Result.Codes.Rejected)
			expect(h.seam:plotIdFor(player)):toBe(nil) -- panic really did refuse

			-- healthy server: the duplicate refusal carries a DIFFERENT code
			local healthy = h:wire()
			expect(claimVia(healthy, player)):toBeOk()
			local second = claimVia(healthy, player)
			expect(second):toBeErr(Result.Codes.AlreadyClaimed)
			expect((second :: any).code ~= Result.Codes.Rejected):toBe(true)
		end
	)

	it(
		"a full server refuses with Unavailable — not AlreadyClaimed, NoData or Internal",
		function()
			local h = newServer({ plotCount = 2 })
			local net = h:wire()
			local p1 = h:join(1)
			local p2 = h:join(2)
			local p3 = h:join(3)
			expect(claimVia(net, p1)):toBeOk()
			expect(claimVia(net, p2)):toBeOk()
			expect(PlotService:freeCount()):toBe(0)

			local refused = claimVia(net, p3)
			expect(refused):toBeErr(Result.Codes.Unavailable)
			local code = (refused :: any).code
			expect(code ~= Result.Codes.AlreadyClaimed):toBe(true)
			expect(code ~= Result.Codes.NoData):toBe(true)
			expect(code ~= Result.Codes.Internal):toBe(true)
			expect(code ~= Result.Codes.Rejected):toBe(true)

			expect(h.seam:plotIdFor(p3)):toBe(nil)
			expect(h:blob(p3).plot.plotId):toBe("") -- the refusal wrote nothing
			-- and the refusal did not disturb the holders
			expect(h.seam:ownerOf(h.seam:plotIdFor(p1))):toBe(1)
			expect(h.seam:ownerOf(h.seam:plotIdFor(p2))):toBe(2)
		end
	)
end)

-- ── 4. the plot-claim-hijack exploit ────────────────────────────────────────────────────────────

describe("plot: the payload carries NO dome id (anti plot-claim-hijack)", function()
	it("naming another player's dome is refused with BadPayload and transfers nothing", function()
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local victim = h:join(1)
		local attacker = h:join(2)
		local target = (claimVia(net, victim) :: any).value.plotId

		local hijack = claimVia(net, attacker, { plotId = target })
		expect(hijack):toBeErr(Result.Codes.BadPayload)
		expect(h.seam:ownerOf(target)):toBe(1) -- still the victim's
		expect(h.seam:plotIdFor(attacker)):toBe(nil)
		expect(PlotService:freeCount()):toBe(3) -- and nothing else was consumed
	end)

	it("NO client-supplied selector, under ANY key, can steer the server's pick", function()
		-- The guarantee is not "one key is filtered" — it is that the SERVER picks. Whatever the
		-- attacker calls the field, the victim's dome must never change hands.
		local h = newServer({ plotCount = 8 })
		local net = h:wire()
		local victim = h:join(1)
		local target = (claimVia(net, victim) :: any).value.plotId

		local userId = 100
		for _, key in { "plotId", "plot", "id", "index", "dome", "domeId", "userId", "target" } do
			userId += 1
			local attacker = h:join(userId)
			local payload: any = {}
			payload[key] = target
			local result = claimVia(net, attacker, payload)
			-- Either refused outright, or served the SERVER's own pick — never the named dome.
			if result.ok then
				expect((result :: any).value.plotId ~= target):toBe(true)
			end
			expect(h.seam:ownerOf(target)):toBe(1)
			expect(h.seam:plotIdFor(attacker) ~= target):toBe(true)
		end
	end)

	it("an index-shaped payload cannot reach a dome by ordinal either", function()
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local victim = h:join(1)
		local target = (claimVia(net, victim) :: any).value.plotId
		local attacker = h:join(2)
		expect(claimVia(net, attacker, { index = 1 })):toBeErr(Result.Codes.BadPayload)
		expect(h.seam:ownerOf(target)):toBe(1)
	end)

	it("a non-table payload is refused as a type failure; nil is the well-formed call", function()
		local h = newServer({ plotCount = 3 })
		local net = h:wire()
		local p1 = h:join(1)
		local before = PlotService:freeCount()
		for _, junk in { "haxx", 42, true } do
			local result = claimVia(net, p1, junk)
			expect(result):toBeErr()
			local code = (result :: any).code
			expect(code == Result.Codes.BadType or code == Result.Codes.BadPayload):toBe(true)
		end
		expect(PlotService:freeCount()):toBe(before)
		expect(h.seam:plotIdFor(p1)):toBe(nil)
		-- nil payload IS the contracted client call (the payload carries nothing at all).
		expect(claimVia(net, p1, nil)):toBeOk()
		expect(PlotService:freeCount()):toBe(before - 1)
	end)
end)

-- ── 5. plot.fetch is a READ ─────────────────────────────────────────────────────────────────────

describe("plot: plot.fetch is side-effect free", function()
	it("fetch before the session loads answers NoData (the JoinRetry window)", function()
		local h = newServer({ plotCount = 3 })
		local net = h:wire()
		local player = Mocks.player(5)
		expect(fetchVia(net, player)):toBeErr(Result.Codes.NoData)
		expect(PlotService:freeCount()):toBe(3)
	end)

	it("fetching repeatedly never claims a dome", function()
		local h = newServer({ plotCount = 3 })
		local net = h:wire()
		local player = h:join(1)
		for _ = 1, 5 do
			local read = fetchVia(net, player)
			expect(read):toBeOk()
			expect((read :: any).value.held):toBe(false)
			expect((read :: any).value.plotId):toBe("")
		end
		expect(PlotService:freeCount()):toBe(3) -- five reads allocated nothing
		expect(h.seam:plotIdFor(player)):toBe(nil)
		expect(h:blob(player).plot.plotId):toBe("")
	end)

	it("fetch after a claim reports the held dome and its persisted stamp", function()
		local h = newServer({ plotCount = 3, startUnix = 7000 })
		local net = h:wire()
		local player = h:join(1)
		h.clock:advance(60)
		local claimed = (claimVia(net, player) :: any).value
		local read = fetchVia(net, player)
		expect(read):toBeOk()
		local info = (read :: any).value
		expect(info.held):toBe(true)
		expect(info.plotId):toBe(claimed.plotId)
		expect(info.claimedAtUnix):toBe(7060)
		expect(info.claimedAtUnix):toBe(h:blob(player).plot.claimedAtUnix)
		-- and reading it again changed nothing
		expect(fetchVia(net, player)):toBeOk()
		expect(PlotService:freeCount()):toBe(2)
		expect(h.seam:plotIdFor(player)):toBe(claimed.plotId)
	end)
end)

-- ── 6. rate limiting (validate type + range + ownership + RATE) ─────────────────────────────────

describe("plot: the actions are rate limited per player, per action", function()
	it("claim spam past the bucket is RateLimited, and refills on the mono clock", function()
		local h = newServer({ plotCount = 6 })
		local gate = Mocks.gate(h.clock)
		local net = h:wire({ gate = gate })
		local policy = PlotService:claimAction().rate
		local capacity = policy.burst or policy.maxPerWindow
		local p1 = h:join(1)

		for _ = 1, capacity do
			local result = claimVia(net, p1)
			-- the first is Ok, the rest AlreadyClaimed — but none may be RateLimited yet
			expect((result :: any).code ~= Result.Codes.RateLimited):toBe(true)
		end
		expect(claimVia(net, p1)):toBeErr(Result.Codes.RateLimited)

		-- a SECOND player's bucket is independent — one spammer cannot lock out the server
		local p2 = h:join(2)
		expect(claimVia(net, p2)):toBeOk()

		-- and the bucket refills on the server monotonic clock
		h.clock:advance(policy.windowSeconds + 1)
		local after = claimVia(net, p1)
		expect((after :: any).code ~= Result.Codes.RateLimited):toBe(true)
		expect(after):toBeErr(Result.Codes.AlreadyClaimed)
	end)

	it("the fetch bucket is separate from the claim bucket", function()
		local h = newServer({ plotCount = 4 })
		local gate = Mocks.gate(h.clock)
		local net = h:wire({ gate = gate })
		local capacity = PlotService:claimAction().rate.burst
			or PlotService:claimAction().rate.maxPerWindow
		local player = h:join(1)
		for _ = 1, capacity do
			claimVia(net, player)
		end
		expect(claimVia(net, player)):toBeErr(Result.Codes.RateLimited)
		-- the HUD read is on its own bucket and still works
		expect(fetchVia(net, player)):toBeOk()
	end)
end)

-- ── 7. release on leave + rejoin ────────────────────────────────────────────────────────────────

describe("plot: release cleanly on leave", function()
	it("a freed dome is immediately re-claimable by the NEXT player", function()
		local h = newServer({ plotCount = 1 })
		local net = h:wire()
		local p1 = h:join(1)
		local p2 = h:join(2)
		local dome = (claimVia(net, p1) :: any).value.plotId
		expect(claimVia(net, p2)):toBeErr(Result.Codes.Unavailable)

		h:leave(p1) -- analytics -> PLOT RELEASE -> data release

		expect(h.seam:ownerOf(dome)):toBe(nil)
		expect(PlotService:freeCount()):toBe(1)
		local reclaimed = claimVia(net, p2)
		expect(reclaimed):toBeOk()
		expect((reclaimed :: any).value.plotId):toBe(dome) -- the SAME dome, same frame
		expect(h.seam:ownerOf(dome)):toBe(2)
	end)

	it("releaseFor reports honestly and a DUPLICATE leave never evicts the new holder", function()
		local h = newServer({ plotCount = 1 })
		local net = h:wire()
		local p1 = h:join(1)
		local p2 = h:join(2)
		local dome = (claimVia(net, p1) :: any).value.plotId

		expect(h.seam:releaseFor(p1)):toBe(true)
		expect(h.seam:releaseFor(p1)):toBe(false) -- already free: nothing to report
		expect(claimVia(net, p2)):toBeOk()
		expect(h.seam:ownerOf(dome)):toBe(2)

		-- A duplicated PlayerRemoving for the DEPARTED player must not steal p2's dome.
		expect(h.seam:releaseFor(p1)):toBe(false)
		expect(h.seam:ownerOf(dome)):toBe(2)
		expect(h.seam:plotIdFor(p2)):toBe(dome)
		expect(PlotService:freeCount()):toBe(0)
	end)

	it("releasing one player's dome leaves everyone else's alone", function()
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local players = { h:join(1), h:join(2), h:join(3) }
		local domes: { string } = {}
		for _, player in players do
			table.insert(domes, (claimVia(net, player) :: any).value.plotId)
		end
		h.seam:releaseFor(players[2])
		expect(h.seam:ownerOf(domes[1])):toBe(1)
		expect(h.seam:ownerOf(domes[2])):toBe(nil)
		expect(h.seam:ownerOf(domes[3])):toBe(3)
		expect(PlotService:freeCount()):toBe(2)
	end)
end)

describe("plot: rejoin", function()
	it("a returning player gets their PERSISTED dome back when it is free", function()
		-- Discriminating by construction: after the leaves, the persisted dome is NOT the
		-- first free one, so "first free" and "the persisted one" give different answers.
		local h = newServer({ plotCount = 4 })
		local net = h:wire()
		local p1 = h:join(1)
		local p2 = h:join(2)
		local p3 = h:join(3)
		claimVia(net, p1)
		local dome2 = (claimVia(net, p2) :: any).value.plotId
		local dome3 = (claimVia(net, p3) :: any).value.plotId
		expect(dome2 ~= dome3):toBe(true)

		h:leave(p2)
		h:leave(p3)
		expect(PlotService:freeCount()):toBe(3) -- dome2, dome3 and the untouched 4th

		local returning = h:join(3) -- fresh load from the store: the persisted field is the only memory
		expect(h:blob(returning).plot.plotId):toBe(dome3) -- survived the save/reload round-trip
		local reclaimed = claimVia(net, returning)
		expect(reclaimed):toBeOk()
		expect((reclaimed :: any).value.plotId):toBe(dome3)
		expect(h.seam:ownerOf(dome3)):toBe(3)
		expect(h.seam:ownerOf(dome2)):toBe(nil)
	end)

	it(
		"a persisted dome HELD on this server is NOT honoured — a free one is taken and the field rewritten",
		function()
			local h = newServer({ plotCount = 2 })
			local net = h:wire()
			local p1 = h:join(1)
			local dome1 = (claimVia(net, p1) :: any).value.plotId
			h:leave(p1)

			local p2 = h:join(2)
			expect((claimVia(net, p2) :: any).value.plotId):toBe(dome1) -- p2 takes the freed dome

			local returning = h:join(1)
			expect(h:blob(returning).plot.plotId):toBe(dome1) -- the stale hint
			local reclaimed = claimVia(net, returning)
			expect(reclaimed):toBeOk()
			local newDome = (reclaimed :: any).value.plotId
			expect(newDome ~= dome1):toBe(true) -- NOT honoured
			expect(h.seam:ownerOf(dome1)):toBe(2) -- p2 keeps it: never two players on one dome
			expect(h.seam:ownerOf(newDome)):toBe(1)
			expect(h:blob(returning).plot.plotId):toBe(newDome) -- the field was REWRITTEN
			expect(PlotService:freeCount()):toBe(0)
		end
	)

	it("a persisted dome id this server does not have is ignored, not trusted", function()
		-- The registry can be smaller than the one that stamped the blob (another server, another
		-- MaxPlayers). An unknown id must fall through to a free dome, never be honoured blindly.
		local h = newServer({ plotCount = 2 })
		local net = h:wire()
		local player = h:join(1)
		expect(h.data:update(player, function(blob: any): any
			blob.plot.plotId = "dome_9999"
			blob.plot.claimedAtUnix = 1
			return blob
		end)):toBeOk()
		h:leave(player)

		local returning = h:join(1)
		expect(h:blob(returning).plot.plotId):toBe("dome_9999")
		local reclaimed = claimVia(net, returning)
		expect(reclaimed):toBeOk()
		local granted = (reclaimed :: any).value.plotId
		expect(granted ~= "dome_9999"):toBe(true)
		local known = false
		for _, id in PlotService:plotIds() do
			known = known or id == granted
		end
		expect(known):toBe(true)
		expect(h:blob(returning).plot.plotId):toBe(granted)
		expect(h.seam:ownerOf("dome_9999")):toBe(nil)
	end)

	it("the persisted plot survives the round-trip and reaches the client view intact", function()
		local h = newServer({ plotCount = 3, startUnix = 90000 })
		local net = h:wire()
		local player = h:join(1)
		h.clock:advance(45)
		local dome = (claimVia(net, player) :: any).value.plotId
		h:leave(player)

		local returning = h:join(1)
		local blob = h:blob(returning)
		expect(blob.plot.plotId):toBe(dome)
		expect(blob.plot.claimedAtUnix):toBe(90045)
		expect(blob.schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
		-- toView is the ONLY shape that crosses to the client; the HUD highlight reads it there.
		local view = Types.toView(blob)
		expect(view.plot.plotId):toBe(dome)
		expect(view.plot.claimedAtUnix):toBe(90045)
	end)
end)

-- ── 8. AMENDMENT A1 — placement at the PERSISTED tier ───────────────────────────────────────────

describe("plot: a lit pad is an accent, not a floodlight", function()
	it("the lit pad colour stays under the Neon blowout ceiling", function()
		-- Found in a screenshot from the player's own eye height, and nowhere else: Neon is
		-- fullbright, so RGB(64,226,255) across a 64-stud deck turned the pad into a light source
		-- and filled half the frame with flat cyan. No log, no probe and no rect measurement can
		-- see that -- but the number behind it is assertable, and this is the assertion.
		local lit = PlotService.PAD_LIT_RGB
		local dark = PlotService.PAD_DARK_RGB
		expect(#lit):toBe(3)
		for _, channel in lit do
			expect(channel <= PlotService.PAD_LIT_MAX_CHANNEL):toBe(true)
		end
		-- ...and it must still be COLD and BRIGHTER than an unclaimed pad, or "your dome lights up"
		-- stops being legible at all -- which is the opposite failure and just as bad.
		expect(lit[3] > lit[1]):toBe(true)
		expect(lit[2] >= lit[1] and lit[2] <= lit[3]):toBe(true)
		local litSum = lit[1] + lit[2] + lit[3]
		local darkSum = dark[1] + dark[2] + dark[3]
		expect(litSum > darkSum):toBe(true)
	end)
end)

describe("plot: AMENDMENT A1 — the dome starts at the persisted tier's Y", function()
	it("positionFor puts Y exactly at the tier Y and never overlaps two pads", function()
		for _, tierY in { 0, -450.5, -1200, 88 } do
			local _, y = PlotService:positionFor(1, 8, tierY)
			expect(y):toBe(tierY)
		end
		-- 200 is the registry ceiling (Roblox's per-server max): the ring must still not overlap at
		-- full size, which is what makes raising the clamp a one-line change (F1/F5).
		for _, count in { 4, 12, 50, 200 } do
			local points: { { x: number, z: number } } = {}
			for index = 1, count do
				local x, y, z = PlotService:positionFor(index, count, -300)
				expect(y):toBe(-300)
				table.insert(points, { x = x, z = z })
			end
			for i = 1, #points do
				for j = i + 1, #points do
					local dx = points[i].x - points[j].x
					local dz = points[i].z - points[j].z
					-- greybox pads are 64 studs across: closer than that and two domes intersect.
					expect(math.sqrt(dx * dx + dz * dz) >= 64):toBe(true)
				end
			end
		end
	end)

	it(
		"the tier Y is read from the ctx.depth seam, and the seam is handed the PERSISTED blob",
		function()
			local h = newServer({ plotCount = 3 })
			local player = h:join(1)
			-- A marker only the SERVER-side record carries: nothing a client could send has it.
			expect(h.data:update(player, function(blob: any): any
				blob.stats.playtimeSeconds = 4321
				return blob
			end)):toBeOk()

			local seen: { any } = {}
			local sawLiveRecord: { boolean } = {}
			h.depth = {
				tierYFor = function(_self: any, data: any): number
					table.insert(seen, data)
					-- At the moment of the read, this must BE the loaded session's record.
					table.insert(sawLiveRecord, data == (h.data:get(player) :: any).value)
					return -900
				end,
			}
			local net = h:wire()

			local claimed = claimVia(net, player)
			expect(claimed):toBeOk()
			expect((claimed :: any).value.y):toBe(-900)
			expect(#seen >= 1):toBe(true)
			-- The authoritative fact is the PERSISTED tier: the seam is handed this player's own
			-- server-side record, never a client-supplied value.
			expect(sawLiveRecord[1]):toBe(true)
			expect(seen[1].stats.playtimeSeconds):toBe(4321)
			expect(seen[1].schemaVersion):toBe(Types.CURRENT_SCHEMA_VERSION)
			-- the read surface agrees
			expect((fetchVia(net, player) :: any).value.y):toBe(-900)
		end
	)

	it(
		"a returning player at a deeper tier finds their dome at THAT tier's Y, not at Depth 1",
		function()
			local h = newServer({ plotCount = 3 })
			local net = h:wire() -- no depth seam yet: the fresh-player default
			local player = h:join(1)
			local firstClaim = (claimVia(net, player) :: any).value
			local surfaceY = firstClaim.y
			expect(type(surfaceY)):toBe("number")
			h:leave(player)

			-- Depth tiers has since moved this player to tier 4.
			h.depth = {
				tierYFor = function(_self: any, _data: any): number
					return -1200
				end,
			}
			local deepNet = h:wire()
			local returning = h:join(1)
			local rejoin = claimVia(deepNet, returning)
			expect(rejoin):toBeOk()
			expect((rejoin :: any).value.y):toBe(-1200)
			expect((rejoin :: any).value.y ~= surfaceY):toBe(true) -- NOT re-surfaced to Depth 1
			expect((rejoin :: any).value.plotId):toBe(firstClaim.plotId)
		end
	)

	it("a misbehaving Depth seam cannot park a dome at nowhere or break ownership", function()
		local h = newServer({ plotCount = 6 })
		local baselineNet = h:wire()
		local baseline = (claimVia(baselineNet, h:join(1)) :: any).value.y

		local badSeams: { any } = {
			{
				tierYFor = function(_self: any, _data: any): number
					error("depth blew up")
				end,
			},
			{
				tierYFor = function(_self: any, _data: any): any
					return "deep"
				end,
			},
			{
				tierYFor = function(_self: any, _data: any): number
					return 0 / 0
				end,
			},
			{
				tierYFor = function(_self: any, _data: any): number
					return math.huge
				end,
			},
			{ tierYFor = "not a function" },
		}
		local userId = 20
		for _, seam in badSeams do
			userId += 1
			h.depth = seam
			local net = h:wire()
			local player = h:join(userId)
			local claimed = claimVia(net, player)
			expect(claimed):toBeOk() -- ownership does not depend on Depth behaving
			local y = (claimed :: any).value.y
			expect(type(y)):toBe("number")
			expect(y == y):toBe(true) -- not NaN
			expect(y ~= math.huge and y ~= -math.huge):toBe(true)
			expect(y):toBe(baseline) -- falls back to the tier-1 default, not to nowhere
			expect(h.seam:ownerOf((claimed :: any).value.plotId)):toBe(userId)
		end
	end)
end)

-- ── 9. concurrency: interleaved + spam-duplicated claims ────────────────────────────────────────

describe(
	"plot: never two players on one dome, never two domes for one player (interleaved)",
	function()
		it(
			"TWO players race for the LAST free dome: exactly one wins, the other gets Unavailable",
			function()
				local h = newServer({ plotCount = 1, yieldOnUpdate = true })
				local p1 = h:join(1)
				local p2 = h:join(2)
				local dome = PlotService:plotIds()[1]
				local results: { any } = {}
				drain({
					coroutine.create(function()
						results[1] = PlotService:acquire(h:ctx(), p1)
					end),
					coroutine.create(function()
						results[2] = PlotService:acquire(h:ctx(), p2)
					end),
				})

				local okCount = 0
				for _, result in results do
					if result.ok then
						okCount += 1
					end
				end
				expect(okCount):toBe(1) -- exactly one dome handed out, not two
				expect(PlotService:freeCount()):toBe(0)
				local owner = h.seam:ownerOf(dome)
				expect(owner == 1 or owner == 2):toBe(true)
				-- the loser holds nothing and was told why
				local loser = if owner == 1 then 2 else 1
				expect(h.seam:plotIdFor(Mocks.player(loser))):toBe(nil)
				expect(results[loser]):toBeErr(Result.Codes.Unavailable)
				expect(h:blob(Mocks.player(loser)).plot.plotId):toBe("")
			end
		)

		it(
			"FALSIFICATION: a pick-then-yield-then-occupy registry DOES hand one dome to two",
			function()
				-- The counter-case that makes the test above meaningful. Same interleave, same yield point,
				-- but the reservation happens AFTER the yield instead of before it — and both players walk
				-- away holding the same dome. If this landed on two different domes, the race driver would
				-- not be exercising anything and the green test above would prove nothing.
				local owner: { [string]: number } = {}
				local granted: { [number]: string } = {}
				local function naiveAcquire(userId: number): ()
					local picked: string? = nil
					if owner["dome_1"] == nil then
						picked = "dome_1"
					end
					coroutine.yield() -- stands in for the yield inside ctx.data:update
					if picked ~= nil then
						owner[picked] = userId -- reserved only NOW: the other request already picked it too
						granted[userId] = picked
					end
				end
				drain({
					coroutine.create(function()
						naiveAcquire(1)
					end),
					coroutine.create(function()
						naiveAcquire(2)
					end),
				})
				expect(granted[1]):toBe("dome_1")
				expect(granted[2]):toBe("dome_1") -- the defect, reproduced
			end
		)

		it("N players and N domes, all interleaved: everyone gets one and no two share", function()
			local h = newServer({ plotCount = 3, yieldOnUpdate = true })
			local players = { h:join(1), h:join(2), h:join(3) }
			local results: { any } = {}
			local cos: { thread } = {}
			for index, player in players do
				table.insert(
					cos,
					coroutine.create(function()
						results[index] = PlotService:acquire(h:ctx(), player)
					end)
				)
			end
			drain(cos)

			local seen: { [string]: number } = {}
			for index, result in results do
				expect(result):toBeOk()
				local plotId = (result :: any).value.plotId
				expect(seen[plotId]):toBe(nil) -- no dome handed out twice
				seen[plotId] = index
				expect(h.seam:ownerOf(plotId)):toBe(index)
				expect(h:blob(players[index]).plot.plotId):toBe(plotId)
			end
			expect(PlotService:freeCount()):toBe(0)
		end)

		it(
			"SPAM-DUPLICATED claims from ONE player in the same frame yield exactly ONE dome",
			function()
				-- The spam-click class, driven through the REAL inbound pipeline (Net.dispatch), with the
				-- rate gate off so the anti-dupe guarantee is tested rather than the rate limiter.
				local h = newServer({ plotCount = 6, yieldOnUpdate = true })
				local net = h:wire()
				local player = h:join(1)
				local results: { any } = {}
				local cos: { thread } = {}
				for index = 1, 5 do
					table.insert(
						cos,
						coroutine.create(function()
							results[index] = claimVia(net, player)
						end)
					)
				end
				drain(cos)

				local okCount = 0
				local refusedCount = 0
				for _, result in results do
					if result.ok then
						okCount += 1
					else
						expect(result):toBeErr(Result.Codes.AlreadyClaimed)
						refusedCount += 1
					end
				end
				expect(okCount):toBe(1)
				expect(refusedCount):toBe(4)
				expect(PlotService:freeCount()):toBe(5) -- exactly ONE dome consumed by five requests
				local held = h.seam:plotIdFor(player)
				expect(type(held)):toBe("string")
				expect(h:blob(player).plot.plotId):toBe(held)
				-- and the registry agrees this player owns exactly that one
				local owned = 0
				for _, id in PlotService:plotIds() do
					if h.seam:ownerOf(id) == 1 then
						owned += 1
					end
				end
				expect(owned):toBe(1)
			end
		)

		it("the leave->claim race hands the dome to the ARRIVING player, not to two", function()
			local h = newServer({ plotCount = 1, yieldOnUpdate = true })
			local leaver = h:join(1)
			local arriver = h:join(2)
			local dome = PlotService:plotIds()[1]

			local leaverResult: any = nil
			local co1 = coroutine.create(function()
				leaverResult = PlotService:acquire(h:ctx(), leaver)
			end)
			expect(select(1, coroutine.resume(co1))):toBe(true)
			expect(coroutine.status(co1)):toBe("suspended") -- parked mid-claim, inside the data write

			-- ...and the player leaves right then (the pinned leave sequence frees the dome).
			expect(h.seam:releaseFor(leaver)):toBe(true)
			expect(h.seam:ownerOf(dome)):toBe(nil)

			local arriverResult: any = nil
			local co2 = coroutine.create(function()
				arriverResult = PlotService:acquire(h:ctx(), arriver)
			end)
			drain({ co1, co2 })

			expect(arriverResult):toBeOk()
			expect((arriverResult :: any).value.plotId):toBe(dome)
			expect(h.seam:ownerOf(dome)):toBe(2) -- exactly ONE holder
			expect(h.seam:plotIdFor(leaver)):toBe(nil) -- the departed player took nothing with them
			expect(leaverResult.ok):toBe(false) -- and was not told it succeeded
			expect(PlotService:freeCount()):toBe(0)
		end)

		it("a claim abandoned mid-flight by a leave does not LEAK the dome", function()
			local h = newServer({ plotCount = 1, yieldOnUpdate = true })
			local leaver = h:join(1)
			local dome = PlotService:plotIds()[1]

			local leaverResult: any = nil
			local co = coroutine.create(function()
				leaverResult = PlotService:acquire(h:ctx(), leaver)
			end)
			coroutine.resume(co)
			expect(h.seam:releaseFor(leaver)):toBe(true)
			drain({ co })
			expect(leaverResult.ok):toBe(false)

			-- The dome must be free for the life of the server, not held by a ghost.
			expect(h.seam:ownerOf(dome)):toBe(nil)
			expect(PlotService:freeCount()):toBe(1)
			local newcomer = h:join(7)
			local claimed: any = nil
			-- ALWAYS in a coroutine against a yieldOnUpdate store: the write yields, and a yield on
			-- the main thread would exit Lune 0 mid-run and mask every later failure.
			drain({
				coroutine.create(function()
					claimed = PlotService:acquire(h:ctx(), newcomer)
				end),
			})
			expect(claimed):toBeOk()
			expect((claimed :: any).value.plotId):toBe(dome)
			expect(h.seam:ownerOf(dome)):toBe(7)
		end)

		it(
			"REGRESSION (F2): an ABANDONED claim persists NOTHING — the blob never names a dome the player was refused",
			function()
				-- The header's promise (PlotService.luau:49-57) is that an abandoned claim leaves an
				-- INVARIANT-CLEAN state: memory and the blob agree this player holds nothing. Today
				-- only the failed-persist branch delivers that, and it does so trivially (the write
				-- never landed). On the SessionClosed branch the write DID land — `plot.plotId` is
				-- committed at the top of the transform and the revocation check runs afterwards —
				-- so the player is handed an error while their durable record asserts ownership of a
				-- dome the registry attributes to somebody else.
				local h = newServer({ plotCount = 1, yieldOnUpdate = true })
				local leaver = h:join(1)
				local dome = PlotService:plotIds()[1]
				expect(h:blob(leaver).plot.plotId):toBe("")

				local leaverResult: any = nil
				local co = coroutine.create(function()
					leaverResult = PlotService:acquire(h:ctx(), leaver)
				end)
				expect(select(1, coroutine.resume(co))):toBe(true)
				expect(coroutine.status(co)):toBe("suspended") -- parked inside the data write
				expect(h.seam:ownerOf(dome)):toBe(1) -- reserved before the yield, as designed

				-- The player leaves mid-claim: the pinned leave order frees the dome. The session is
				-- deliberately NOT released yet — DataService's release YIELDS, and this window (the
				-- blob still readable, the dome already free) is exactly where the stale write lands.
				expect(h.seam:releaseFor(leaver)):toBe(true)
				drain({ co })
				expect(leaverResult):toBeErr(Result.Codes.SessionClosed)

				-- THE INVARIANT: a refused claim is not a durable one.
				expect(h.seam:plotIdFor(leaver)):toBe(nil)
				expect(h:blob(leaver).plot.plotId):toBe("")
				expect(h:blob(leaver).plot.claimedAtUnix):toBe(0)

				-- ...and once the dome is genuinely somebody else's, the abandoned player's record
				-- must not be asserting ownership of it. `view.plot.plotId` is what the client
				-- highlights from (PlotController.onView), so a lie here points a live player's dome
				-- marker at a dome another player holds.
				local newcomer = h:join(7)
				local claimed: any = nil
				drain({
					coroutine.create(function()
						claimed = PlotService:acquire(h:ctx(), newcomer)
					end),
				})
				expect(claimed):toBeOk()
				expect(h.seam:ownerOf(dome)):toBe(7)
				expect(h:blob(leaver).plot.plotId ~= dome):toBe(true)
				expect(Types.toView(h:blob(leaver)).plot.plotId ~= dome):toBe(true)
			end
		)

		it(
			"REGRESSION (F2): the abandoned write cannot clobber the dome a REJOINED same-server session holds",
			function()
				-- The same-player variant. A's claim parks mid-write; A leaves; A rejoins THIS server
				-- and is granted a DIFFERENT dome (their first is now held). The stale thread's write
				-- must not land afterwards naming the old dome — the live session would then hold
				-- dome B in memory while its replicated record says dome A, which another player is
				-- standing on.
				local h = newServer({ plotCount = 2 })
				local a = h:join(1)
				local first = PlotService:plotIds()[1]

				-- A data layer that PARKS inside the write and then COMMITS it for real (the
				-- yieldOnUpdate fixture's shape, but pointed at the live session so the late write
				-- is observable through the session the player actually has).
				local parkedData: any = {}
				function parkedData.get(_self: any, player: any): any
					return h.data:get(player)
				end
				function parkedData.update(_self: any, player: any, transform: any): any
					coroutine.yield()
					return h.data:update(player, transform)
				end

				local staleResult: any = nil
				local co = coroutine.create(function()
					staleResult = PlotService:acquire(
						{ clock = h.clock, data = parkedData, plot = h.seam },
						a
					)
				end)
				expect(select(1, coroutine.resume(co))):toBe(true)
				expect(coroutine.status(co)):toBe("suspended")
				expect(h.seam:ownerOf(first)):toBe(1)

				h:leave(a) -- release the dome AND the session
				local b = h:join(2)
				expect(PlotService:acquire(h:ctx(), b)):toBeOk()
				expect(h.seam:ownerOf(first)):toBe(2) -- B now holds A's old dome

				local returning = h:join(1) -- A comes back to the SAME server
				local rejoin = PlotService:acquire(h:ctx(), returning)
				expect(rejoin):toBeOk()
				local liveDome = (rejoin :: any).value.plotId
				expect(liveDome ~= first):toBe(true) -- the held one is not honoured
				expect(h:blob(returning).plot.plotId):toBe(liveDome)

				-- ...and NOW the stale write lands.
				drain({ co })
				expect(staleResult.ok):toBe(false)

				expect(h.seam:plotIdFor(returning)):toBe(liveDome)
				expect(h.seam:ownerOf(first)):toBe(2) -- B keeps their dome
				expect(h:blob(returning).plot.plotId):toBe(liveDome) -- NOT rewritten to `first`
				expect(Types.toView(h:blob(returning)).plot.plotId):toBe(liveDome)
			end
		)

		it(
			"REGRESSION: a persist that fails rolls back THIS claim only — never the dome a live player now holds",
			function()
				-- The rollback `vacate(record)` is the ONLY occupancy write on this file's failure
				-- branch, and the success branch four lines below it re-checks `record.ownerUserId`
				-- before touching anything. The failure branch must be just as identity-guarded:
				-- `record` is read AFTER a yield, so by then it may belong to somebody else. `vacate`
				-- clears whoever holds it NOW — their plotIdByOwner entry, the record's owner, the pad
				-- light — and `clearContents` Destroys every child of the dome Model except the Shell,
				-- i.e. exactly what Salvage parents under `rootFor` (smelter/conveyor/drones).
				local h = newServer({ plotCount = 1 })
				local a = h:join(1)
				local b = h:join(2)
				local dome = PlotService:plotIds()[1]

				-- A data layer that PARKS inside the write and then reports it did not land — the
				-- union of the two fixtures this suite already uses (yieldOnUpdate + a failing update).
				local parkedData: any = {}
				function parkedData.get(_self: any, player: any): any
					return h.data:get(player)
				end
				function parkedData.update(_self: any, _player: any, _transform: any): any
					coroutine.yield()
					return Result.err(Result.Codes.LockStolen, "write did not land")
				end

				local aResult: any = nil
				local co = coroutine.create(function()
					aResult = PlotService:acquire(
						{ clock = h.clock, data = parkedData, plot = h.seam },
						a
					)
				end)
				expect(select(1, coroutine.resume(co))):toBe(true)
				expect(coroutine.status(co)):toBe("suspended") -- parked inside the write
				expect(h.seam:ownerOf(dome)):toBe(1) -- reserved before the yield, as designed

				-- A leaves (the pinned leave order frees the dome)...
				expect(h.seam:releaseFor(a)):toBe(true)
				expect(h.seam:ownerOf(dome)):toBe(nil)
				-- ...and B, who is live, takes it. B is now the one true holder.
				expect(PlotService:acquire(h:ctx(), b)):toBeOk()
				expect(h.seam:ownerOf(dome)):toBe(2)

				-- A's stale write finally fails and rolls back.
				drain({ co })
				expect(aResult.ok):toBe(false)

				-- One dome, ONE player's worth of truth. B must still hold it in memory, in the blob
				-- and through the seam Salvage/Depth parent under.
				expect(h.seam:ownerOf(dome)):toBe(2)
				expect(h.seam:plotIdFor(b)):toBe(dome)
				expect(h:blob(b).plot.plotId):toBe(dome)
				expect(PlotService:freeCount()):toBe(0)
				-- ...and the dome is NOT handed to the next claimant while B still holds it.
				local c = h:join(3)
				expect(PlotService:acquire(h:ctx(), c)):toBeErr(Result.Codes.Unavailable)
				expect(h.seam:ownerOf(dome)):toBe(2)
			end
		)

		it(
			"REGRESSION: a rejoining player's LIVE dome survives their own stale claim's rollback",
			function()
				-- The same-player variant, which an identity check alone cannot see: A parks
				-- mid-write, leaves, rejoins THIS server and re-takes the same dome. The stale
				-- thread's `record.ownerUserId` is A's UserId again — but it is a DIFFERENT claim,
				-- and rolling it back strips the live A of the dome they are standing on.
				local h = newServer({ plotCount = 1 })
				local a = h:join(1)
				local dome = PlotService:plotIds()[1]

				local parkedData: any = {}
				function parkedData.get(_self: any, player: any): any
					return h.data:get(player)
				end
				function parkedData.update(_self: any, _player: any, _transform: any): any
					coroutine.yield()
					return Result.err(Result.Codes.LockStolen, "write did not land")
				end

				local staleResult: any = nil
				local co = coroutine.create(function()
					staleResult = PlotService:acquire(
						{ clock = h.clock, data = parkedData, plot = h.seam },
						a
					)
				end)
				expect(select(1, coroutine.resume(co))):toBe(true)
				expect(coroutine.status(co)):toBe("suspended")

				h:leave(a) -- release the dome and the session
				local returning = h:join(1) -- ...and rejoin the SAME server
				expect(PlotService:acquire(h:ctx(), returning)):toBeOk()
				expect(h.seam:ownerOf(dome)):toBe(1)

				drain({ co })
				expect(staleResult.ok):toBe(false)
				-- The LIVE session still holds its dome.
				expect(h.seam:ownerOf(dome)):toBe(1)
				expect(h.seam:plotIdFor(returning)):toBe(dome)
				expect(h:blob(returning).plot.plotId):toBe(dome)
				expect(PlotService:freeCount()):toBe(0)
			end
		)

		it(
			"a persist that FAILS rolls the reservation back — no dome is lost to a write that did not land",
			function()
				local h = newServer({ plotCount = 1 })
				local player = h:join(1)
				local dome = PlotService:plotIds()[1]
				local blob = h:blob(player)

				-- A data layer whose write always fails (a stolen lock, an exhausted budget). The dome must
				-- not stay reserved for a claim that never became durable.
				local brokenData: any = {}
				function brokenData.get(_self: any, _p: any): any
					return Result.ok(blob)
				end
				function brokenData.update(_self: any, _p: any, _transform: any): any
					return Result.err(Result.Codes.LockStolen, "write did not land")
				end

				local failed = PlotService:acquire(
					{ clock = h.clock, data = brokenData, plot = h.seam },
					player
				)
				expect(failed):toBeErr(Result.Codes.LockStolen)
				expect(h.seam:plotIdFor(player)):toBe(nil)
				expect(h.seam:ownerOf(dome)):toBe(nil)
				expect(PlotService:freeCount()):toBe(1)

				-- ...and the dome is genuinely usable afterwards, by anyone.
				local newcomer = h:join(2)
				expect(PlotService:acquire(h:ctx(), newcomer)):toBeOk()
				expect(h.seam:ownerOf(dome)):toBe(2)
			end
		)
	end
)

-- ── 10. leave DURING the session load: the join hook must not reserve for a ghost ────────────────
--
-- The slice: "on PlayerRemoving / session release the plot is freed and is immediately re-claimable
-- by the NEXT player. The leave->claim race must neither leak a plot forever nor hand one plot to
-- two players." The cases in section 9 all cover a player who left AFTER their claim was in flight
-- — the reservation exists, so `releaseFor` has something to free and the post-yield identity guard
-- sees it revoked. This section covers the window BEFORE that: the player left while their session
-- was still LOADING, so PlayerRemoving found them holding nothing and will never fire again. Any
-- dome the join hook reserves after that point is held by an absent UserId until the server dies —
-- and with churn the registry fills with ghosts and every legitimate joiner gets Unavailable, which
-- is core-loop step 1 ("Join -> a free dome plot is claimed for you") failing server-wide.
--
-- Both orderings below are the SAME production interleaving, which is not exotic: the poll cadence
-- is 0.25s and the window is a full DataStore write. DataService keeps `_sessions[uid]` populated
-- across the YIELDING releaseSession in both its leave paths (finishJoin's left-during-load branch
-- and onPlayerRemoving), so `data:get` answers Ok for that whole window — the poller waking inside
-- it sees a perfectly loaded blob belonging to a player who is already gone.
describe("plot: a player who LEFT during their session load is never handed a dome", function()
	it(
		"the leave arrives BEFORE the load resolves (finishJoin's left-during-load branch)",
		function()
			local h = newServer({ plotCount = 1 })
			local player = Mocks.player(41)
			local dome = PlotService:plotIds()[1]

			local claimed: any = nil
			runWithWaitHook(function(attempt: number): ()
				if attempt ~= 1 then
					return
				end
				-- PlayerRemoving fires while loadSession is still yielding. PlayerLifecycle runs the
				-- pinned order: analytics -> plot release -> data release. The plot release returns
				-- false (this player holds nothing yet) and the data release finds no session — THIS
				-- IS THE ONLY PlayerRemoving THIS PLAYER WILL EVER GET.
				expect(h.seam:releaseFor(player)):toBe(false)
				h.data:onPlayerRemoving(player)
				-- ...and only NOW does loadSession resolve and install the session. finishJoin takes
				-- its left-during-load branch, whose releaseSession yields with the slot still set.
				expect(h.data:loadSession(player)):toBeOk()
			end, function()
				claimed = PlotService:claimOnJoin(h:ctx(), player)
			end)

			expect(claimed.ok):toBe(false) -- nothing is claimed for someone who is already gone
			expect(h.seam:plotIdFor(player)):toBe(nil)
			expect(h.seam:ownerOf(dome)):toBe(nil)
			expect(PlotService:freeCount()):toBe(1)
			expect(h:blob(player).plot.plotId):toBe("") -- and nothing was persisted either

			-- The decisive consequence: the dome is still there for the next real player.
			local newcomer = h:join(77)
			local next_ = PlotService:acquire(h:ctx(), newcomer)
			expect(next_):toBeOk()
			expect((next_ :: any).value.plotId):toBe(dome)
			expect(h.seam:ownerOf(dome)):toBe(77)
		end
	)

	it("the leave arrives within ONE POLL of the load resolving (the 0.25s window)", function()
		local h = newServer({ plotCount = 1 })
		local player = Mocks.player(42)
		local dome = PlotService:plotIds()[1]

		local claimed: any = nil
		runWithWaitHook(function(attempt: number): ()
			if attempt ~= 1 then
				return
			end
			-- The load lands while the poller is asleep...
			expect(h.data:loadSession(player)):toBeOk()
			-- ...and the player quits inside that same 0.25s. PlayerLifecycle frees their (empty)
			-- dome, then DataService.onPlayerRemoving parks in the yielding releaseSession with
			-- `_sessions[uid]` STILL populated. The poller wakes right here.
			expect(h.seam:releaseFor(player)):toBe(false)
		end, function()
			claimed = PlotService:claimOnJoin(h:ctx(), player)
		end)

		expect(claimed.ok):toBe(false)
		expect(h.seam:plotIdFor(player)):toBe(nil)
		expect(h.seam:ownerOf(dome)):toBe(nil)
		expect(PlotService:freeCount()):toBe(1)
		expect(h:blob(player).plot.plotId):toBe("")
	end)

	it("CHURN: repeated leave-during-load never exhausts the registry", function()
		-- The compounding failure. Every ghost is a dome held forever, so after `plotCount` of them
		-- a full server refuses everyone with Unavailable and no player can start the core loop
		-- again until the server restarts.
		local h = newServer({ plotCount = 3 })
		for index = 1, 8 do
			local quitter = Mocks.player(500 + index)
			runWithWaitHook(function(attempt: number): ()
				if attempt ~= 1 then
					return
				end
				expect(h.seam:releaseFor(quitter)):toBe(false)
				h.data:onPlayerRemoving(quitter)
				expect(h.data:loadSession(quitter)):toBeOk()
			end, function()
				PlotService:claimOnJoin(h:ctx(), quitter)
			end)
		end
		expect(PlotService:freeCount()):toBe(3) -- not one dome lost to the churn

		-- and three real players still get one each
		for index = 1, 3 do
			local player = h:join(600 + index)
			expect(PlotService:acquire(h:ctx(), player)):toBeOk()
		end
		expect(PlotService:freeCount()):toBe(0)
	end)

	it(
		"a player who STAYS still gets their dome (the guard refuses ghosts, not joiners)",
		function()
			-- The falsification counterpart: the same slow load, nobody leaves. A guard that simply
			-- never claimed after a wait would pass every test above and break the core loop for
			-- everyone, so this case must stay green.
			local h = newServer({ plotCount = 2 })
			local player = Mocks.player(43)

			local claimed: any = nil
			runWithWaitHook(function(attempt: number): ()
				if attempt == 2 then
					expect(h.data:loadSession(player)):toBeOk()
				end
			end, function()
				claimed = PlotService:claimOnJoin(h:ctx(), player)
			end)

			expect(claimed):toBeOk()
			expect(type((claimed :: any).value.plotId)):toBe("string")
			expect(h.seam:ownerOf((claimed :: any).value.plotId)):toBe(43)
			expect(h:blob(player).plot.plotId):toBe((claimed :: any).value.plotId)
			expect(PlotService:freeCount()):toBe(1)
		end
	)

	it("a leave during a LATER join still leaves the earlier joiner's dome alone", function()
		-- The ledger is per-UserId: one player's departure must not abandon another's in-flight
		-- join. (A global "somebody left" flag would pass every case above and fail this one.)
		local h = newServer({ plotCount = 3 })
		local stayer = Mocks.player(44)
		local quitter = Mocks.player(45)

		local claimed: any = nil
		runWithWaitHook(function(attempt: number): ()
			if attempt == 1 then
				expect(h.seam:releaseFor(quitter)):toBe(false) -- a DIFFERENT player leaves
				expect(h.data:loadSession(stayer)):toBeOk()
			end
		end, function()
			claimed = PlotService:claimOnJoin(h:ctx(), stayer)
		end)

		expect(claimed):toBeOk()
		expect(h.seam:ownerOf((claimed :: any).value.plotId)):toBe(44)
		expect(PlotService:freeCount()):toBe(2)
	end)
end)
