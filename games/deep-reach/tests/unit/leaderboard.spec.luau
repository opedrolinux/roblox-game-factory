--!strict
-- games/deep-reach/tests/unit/leaderboard.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/leaderboard.md, NOT
--  from LeaderboardService's control flow. The implementation was read ONLY to learn its observable
--  interface (method names, return shapes) so expectations could be PARAMETRIZED on constants the
--  API exposes (board.topN, the registered action's RatePolicy, REBUILD_INTERVAL_SECONDS) rather
--  than hard-coded. Every assertion below is derived from the slice's guarantees.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   * "top players by lifetime Credits" — "A ranked snapshot of the players currently on this server,
--     ordered by `stats.lifetimeCredits` descending, top-N (N a server constant), rebuilt on a
--     server-clock cadence and pushed/served to clients."
--   * "The `leaderboard.fetch` action returning that snapshot."
--   * "Names: use only the Roblox-provided Name/DisplayName. Do NOT render any player-authored free
--     text — this feature has no text input and must not add one (rule 9)."
--   * CRITICAL — "YOU ONLY READ. … You must not increment it, must not compute it from a balance,
--     and must not require or depend on any other feature's service. Read the field off the loaded
--     player data through the data layer."
--   * SCOPE FENCE — "v1 is SERVER-LOCAL ranking … do not add DataStore calls outside
--     `src/server/data/`."
--   * "PERSISTENCE: none of your own. Append-only: one Net action, zero schema change."
--   * CLAUDE.md §3 — validate type + range + ownership + rate on every inbound client request.
--   * CLAUDE.md §4 — no double-spend and no currency dupes from interleaved / spam-duplicated
--     requests.
--
-- WHY THE READ-ONLY TESTS LOOK LIKE THIS. The single most valuable thing this gate can do is prove
-- a NEGATIVE: that a client-callable action which touches the economy's ranking key writes nothing.
-- A test that only asserted the returned numbers would pass just as happily against a board that
-- "healed" stats.lifetimeCredits from currencies.Credits on every fetch — which would silently mint
-- lifetime for a player who had spent down, and silently ERASE it for one who had. So the service is
-- driven through a COUNTING PROXY over the real DataService, and every read path is asserted to make
-- zero `update` and zero `save` calls, with the whole blob deep-compared before and after.
--
-- WHY THE CONCURRENCY TESTS LOOK LIKE THIS. Sequential calls cannot distinguish a correct
-- implementation from a broken one, because nothing ever interleaves. So the race cases drive the
-- SAME technique economy_race.spec uses: a MockStore with `yieldOnUpdate` (a forced yield inside the
-- update critical section) plus a round-robin coroutine driver, so a fetch genuinely lands in the
-- middle of an in-flight earn. Each is paired with a FALSIFICATION counter-case: a board that
-- read-then-wrote the ranking key, driven at the SAME yield point, DOES lose the earn — which proves
-- the interleave is real and that the green above is not vacuous.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local LeaderboardService = require("../../src/server/services/leaderboard/LeaderboardService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Net = require("../../src/shared/Net")
local Result = require("../../src/shared/Result")

local HudRoot = require("../../src/client/framework/HudRoot")
local fs = require("@lune/fs")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local ACTION = Net.Actions.FetchLeaderboard

-- inf - inf, not 0/0: selene's divide_by_zero lint bans the literal form, and this is the same NaN.
local NAN = math.huge - math.huge

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

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, valueA in a do
		if not deepEqual(valueA, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
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
			error("leaderboard race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`leaderboard race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- A fresh server. The service is Started against a fake `net` that only records registrations, and
-- is handed a COUNTING PROXY over the real DataService — the slice's CRITICAL constraint is
-- read-only, so the spec must be able to SEE a write if one ever appears.
--
-- `h.raw` is the real DataService (used to seat players and to seed the ranking key, so seeding
-- never inflates the write counters). `h.data` is the proxy the service actually receives.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or 1000)
	-- Kept by reference so a test can flip the forced-yield hook ON after seating players (seating
	-- runs on the main thread, which cannot yield).
	local storeOptions: any = { clock = clock, config = Config, yieldOnUpdate = false }
	local store = Mocks.store(storeOptions)
	local data = DataService.new(store, clock, Config, Mocks.logWarn)

	-- `get` is counted as well, and it is the BUILD DETECTOR: a snapshot build reads EVERY rostered
	-- player's blob, so a cache-served fetch costs exactly one get (the caller's own ownership read)
	-- while a rebuild costs one more per rostered player. Without a build counter, "a burst inside one
	-- interval costs exactly ONE build" is unobservable — a frozen clock makes builtAtUnix identical
	-- whether the board rebuilt thirty times or once.
	local writes = { update = 0, save = 0, get = 0 }
	local countingData: any = {}
	function countingData.get(_self: any, player: any): any
		writes.get += 1
		return data:get(player)
	end
	function countingData.update(_self: any, player: any, transform: any): any
		writes.update += 1
		return data:update(player, transform)
	end
	function countingData.save(_self: any, player: any): any
		writes.save += 1
		return data:save(player)
	end

	local roster: { any } = {}
	local registered: { [string]: any } = {}

	-- Module-level service state: reset it, then inject the Tier-1 roster provider (there is no
	-- engine Players service under Lune).
	LeaderboardService._snapshot = nil
	LeaderboardService._players = function(): { any }
		return roster
	end

	local startContext: any = {
		clock = clock,
		data = countingData,
		net = {
			register = function(_self: any, action: any): ()
				registered[action.name] = action
			end,
		},
	}
	LeaderboardService:Start(startContext)

	local h: any = {
		clock = clock,
		store = store,
		storeOptions = storeOptions,
		raw = data,
		data = countingData,
		writes = writes,
		roster = roster,
		registered = registered,
		startContext = startContext,
	}

	-- Seat a player ON this server: load their session, seed the ranking key, add to the roster.
	function h.seat(self: any, userId: number, lifetimeCredits: any?, name: string?): any
		local player = Mocks.player(userId, name)
		self.raw:loadSession(player)
		if lifetimeCredits ~= nil then
			self.raw:update(player, function(d: any): any
				d.stats.lifetimeCredits = lifetimeCredits
				return d
			end)
		end
		table.insert(self.roster, player)
		return player
	end

	-- Present on the server but NOT loaded (still joining) — the data layer answers Err(NoData).
	function h.seatUnloaded(self: any, userId: number, name: string?): any
		local player = Mocks.player(userId, name)
		table.insert(self.roster, player)
		return player
	end

	function h.enableYield(self: any): ()
		self.storeOptions.yieldOnUpdate = true
	end

	function h.resetWrites(self: any): ()
		self.writes.update = 0
		self.writes.save = 0
		self.writes.get = 0
	end

	-- The real inbound pipeline: Net.dispatch through Mocks.net with leaderboard.fetch registered
	-- from the service's own action factory. `rate = true` opts INTO the real Gate.
	function h.wire(self: any, wireOptions: any?): any
		local w: any = wireOptions or {}
		local netHarness = Mocks.net({
			clock = self.clock,
			data = self.data,
			gate = if w.rate == true then Mocks.gate(self.clock) else false,
			-- The slice forbids depending on any other feature's service; these stay nil on purpose.
			economy = w.economy,
			plot = w.plot,
			salvage = w.salvage,
			depth = w.depth,
		})
		netHarness.register(LeaderboardService:fetchAction())
		return netHarness
	end

	-- ctx for a direct `fetch` call (no wire), with every feature seam deliberately absent.
	function h.ctx(self: any, player: any): any
		return { player = player, clock = self.clock, data = self.data }
	end

	return h
end

local function boardOf(result: any): any
	return (result :: any).value
end

-- ── the wire contract: payload, rate, ownership (CLAUDE.md §3) ───────────────────────────────────

describe("leaderboard.fetch — the wire contract", function()
	it("Start registers exactly the leaderboard.fetch action on the gateway", function()
		local h = newServer()
		expect(h.registered[ACTION]).never:toBe(nil)
		expect(h.registered[ACTION].name):toBe(ACTION)
		-- One action, not a per-feature RemoteEvent and not a family of them.
		local count = 0
		for _ in h.registered do
			count += 1
		end
		expect(count):toBe(1)
	end)

	it("the payload carries NOTHING by contract: nil and {} are both accepted", function()
		local h = newServer()
		h:seat(1, 10)
		h:seat(2, 20)
		local harness = h:wire()
		local plain = harness.invoke(ACTION, h.roster[1], nil)
		local empty = harness.invoke(ACTION, h.roster[1], {})
		expect(plain):toBeOk()
		expect(empty):toBeOk()
		-- "carries nothing" is only true if the two are INDISTINGUISHABLE. An acceptance-only check
		-- stays green against a service that branched on nil vs {} — which is precisely a payload
		-- carrying something.
		local a, b = boardOf(plain), boardOf(empty)
		expect(a.topN):toBe(b.topN)
		expect(a.playerCount):toBe(b.playerCount)
		expect(a.builtAtUnix):toBe(b.builtAtUnix)
		expect(a.nextRebuildUnix):toBe(b.nextRebuildUnix)
		expect(#a.entries):toBe(#b.entries)
		expect(#a.entries):toBe(2)
		for index, standing in a.entries do
			expect(b.entries[index].userId):toBe(standing.userId)
			expect(b.entries[index].rank):toBe(standing.rank)
			expect(b.entries[index].name):toBe(standing.name)
			expect(b.entries[index].lifetimeCredits):toBe(standing.lifetimeCredits)
		end
		expect(a.you.ranked):toBe(b.you.ranked)
		expect(a.you.rank):toBe(b.you.rank)
		expect(a.you.lifetimeCredits):toBe(b.you.lifetimeCredits)
	end)

	it("a non-table payload -> Err(BadType) (type validation, never a crash)", function()
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire()
		expect(harness.invoke(ACTION, p, "give me the board")):toBeErr(Result.Codes.BadType)
		expect(harness.invoke(ACTION, p, 42)):toBeErr(Result.Codes.BadType)
		expect(harness.invoke(ACTION, p, true)):toBeErr(Result.Codes.BadType)
	end)

	it("a client-supplied ROW COUNT is REFUSED, not clamped -> Err(BadPayload)", function()
		-- The resource-exhaustion lever: "ask for 10,000 rows at 5 requests/second". The slice makes
		-- N a SERVER constant, so a payload that names one is not a well-formed request.
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire()
		for _, key in { "limit", "count", "top", "topN", "n", "max", "offset", "page" } do
			local payload: any = {}
			payload[key] = 10000
			expect(harness.invoke(ACTION, p, payload)):toBeErr(Result.Codes.BadPayload)
		end
	end)

	it("a client-supplied SCORE or RANK is REFUSED -> Err(BadPayload)", function()
		-- "just tell the server what my score is". lifetimeCredits is owned by EconomyService; this
		-- action must never accept a number that could reach the ranking.
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire()
		for _, key in { "lifetimeCredits", "credits", "rank" } do
			local payload: any = {}
			payload[key] = 999999999
			expect(harness.invoke(ACTION, p, payload)):toBeErr(Result.Codes.BadPayload)
		end
	end)

	it("a client-supplied TARGET player or NAME is REFUSED -> Err(BadPayload)", function()
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire()
		for _, key in { "userId", "targetUserId", "name", "displayName", "sort", "order" } do
			local payload: any = {}
			payload[key] = "x"
			expect(harness.invoke(ACTION, p, payload)):toBeErr(Result.Codes.BadPayload)
		end
	end)

	it("NO request shape yields more rows than the server's top-N", function()
		-- The guarantee, stated as an invariant over every payload the wire will accept: whatever the
		-- client sends, the row count is min(server topN, players ranked).
		local h = newServer()
		for userId = 1, 25 do
			h:seat(userId, userId * 100)
		end
		local harness = h:wire()
		local plain = harness.invoke(ACTION, h.roster[1], nil)
		expect(plain):toBeOk()
		local board = boardOf(plain)
		expect(board.playerCount):toBe(25)
		expect(#board.entries):toBe(board.topN)
		expect(#board.entries < board.playerCount):toBe(true)
		-- `#entries == board.topN` compares one field of the reply to another field of the SAME reply,
		-- so it is satisfied by a service that set topN = #entries. The row count is bounded against
		-- the SERVER CONSTANT, which no reply can move.
		expect(board.topN):toBe(LeaderboardService.TOP_N)
		expect(#board.entries <= LeaderboardService.TOP_N):toBe(true)
		-- and the refused "give me all of them" shape returns no rows at all.
		local greedy = harness.invoke(ACTION, h.roster[1], { limit = 10000 })
		expect(greedy):toBeErr(Result.Codes.BadPayload)
		expect((greedy :: any).value):toBe(nil)
	end)

	it("an ACCEPTED unrecognized payload changes nothing (rows, order, you)", function()
		-- The blocklist is a blocklist, not an allowlist: `{ rows = 10000 }`, an ARRAY, and a NESTED
		-- table all pass validation today. The property that actually protects the server is therefore
		-- not "every dangerous key is refused" (a list can always be one key short) but "an accepted
		-- payload cannot move the row count, the ordering or the target". That is asserted here, for
		-- every accepted shape, against the board the contract-empty payload produces.
		local h = newServer()
		for userId = 1, LeaderboardService.TOP_N + 5 do
			h:seat(userId, userId * 100)
		end
		local caller = h.roster[1] -- deliberately the POOREST player: off the displayed board
		local harness = h:wire()
		local baseline = boardOf(harness.invoke(ACTION, caller, nil))
		expect(#baseline.entries):toBe(LeaderboardService.TOP_N)
		expect(baseline.you.ranked):toBe(true)

		local accepted: { any } = {
			{},
			{ foo = 1 },
			{ rows = 10000 },
			{ size = 10000 },
			{ Limit = 10000 },
			{ 1, 2, 3 },
			{ nested = { limit = 10000, userId = 999 } },
		}
		for _, payload in accepted do
			local result = harness.invoke(ACTION, caller, payload)
			expect(result):toBeOk()
			local got = boardOf(result)
			expect(got.topN):toBe(LeaderboardService.TOP_N)
			expect(#got.entries):toBe(#baseline.entries)
			expect(got.playerCount):toBe(baseline.playerCount)
			for index, standing in baseline.entries do
				expect(got.entries[index].userId):toBe(standing.userId)
				expect(got.entries[index].rank):toBe(standing.rank)
				expect(got.entries[index].lifetimeCredits):toBe(standing.lifetimeCredits)
			end
			-- and the caller is still the TARGET: no payload redirects `you` at another player.
			expect(got.you.ranked):toBe(baseline.you.ranked)
			expect(got.you.rank):toBe(baseline.you.rank)
			expect(got.you.lifetimeCredits):toBe(baseline.you.lifetimeCredits)
		end
	end)

	it("the GATEWAY's registered action carries a REAL rate bound", function()
		-- Both rate cases below read a FRESH LeaderboardService:fetchAction().rate, so they prove the
		-- FACTORY is rate-limited, not the action the gateway actually dispatches through. And a policy
		-- read only against itself is no bound at all: widening it to maxPerWindow = 100000 keeps every
		-- parametrized rate test green while removing the limit the tests exist to guarantee.
		local h = newServer()
		local held = h.registered[ACTION]
		expect(held).never:toBe(nil)
		local policy = held.rate
		expect(policy).never:toBe(nil)
		expect(type(policy.maxPerWindow)):toBe("number")
		expect(type(policy.windowSeconds)):toBe("number")
		expect(policy.maxPerWindow > 0):toBe(true)
		expect(policy.maxPerWindow <= 20):toBe(true)
		expect(policy.windowSeconds > 0):toBe(true)
		expect(policy.windowSeconds <= 60):toBe(true)
		-- the registered action and the factory declare the SAME policy
		local fresh = LeaderboardService:fetchAction().rate
		expect(policy.maxPerWindow):toBe(fresh.maxPerWindow)
		expect(policy.windowSeconds):toBe(fresh.windowSeconds)
		-- the other two server-owned cost bounds, likewise bounded rather than merely present
		expect(LeaderboardService.REBUILD_INTERVAL_SECONDS >= 1):toBe(true)
		expect(LeaderboardService.REBUILD_INTERVAL_SECONDS <= 60):toBe(true)
		expect(LeaderboardService.TOP_N > 0):toBe(true)
		expect(LeaderboardService.TOP_N <= 50):toBe(true)
	end)

	it("gate LIVE: a fabricated non-numeric UserId is refused, buckets nobody", function()
		-- The fabricated-player case elsewhere runs with the gate OFF, so dispatch skips step 4 and the
		-- Err comes from inside the handler. Net.dispatch calls gate:check(ctx.player.UserId, …) BEFORE
		-- validate, so with the gate live a string UserId becomes a bucket key — that path is exercised
		-- here, and it must still end in an Err with no board and no write.
		local h = newServer()
		local honest = h:seat(1, 100)
		local harness = h:wire({ rate = true })
		local fake: any = { UserId = "1 or 1=1", Name = "Exploiter" }
		h:resetWrites()
		local policy = LeaderboardService:fetchAction().rate
		for _ = 1, policy.maxPerWindow + 3 do
			local result = harness.invoke(ACTION, fake, nil)
			expect(result):toBeErr()
			expect((result :: any).value):toBe(nil)
		end
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
		-- and the fabricated caller did not consume the honest player's allowance
		expect(harness.invoke(ACTION, honest, nil)):toBeOk()
	end)

	it("rate: the call past the action's own maxPerWindow -> Err(RateLimited)", function()
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire({ rate = true })
		-- Parametrized on the policy the action itself declares, not a copied literal.
		local policy = LeaderboardService:fetchAction().rate
		expect(policy.maxPerWindow > 0):toBe(true)
		for _ = 1, policy.maxPerWindow do
			expect(harness.invoke(ACTION, p, nil)):toBeOk()
		end
		expect(harness.invoke(ACTION, p, nil)):toBeErr(Result.Codes.RateLimited)
	end)

	it("rate refills after the window elapses on the SERVER clock", function()
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire({ rate = true })
		local policy = LeaderboardService:fetchAction().rate
		for _ = 1, policy.maxPerWindow do
			harness.invoke(ACTION, p, nil)
		end
		expect(harness.invoke(ACTION, p, nil)):toBeErr(Result.Codes.RateLimited)
		h.clock:advance(policy.windowSeconds * 2)
		expect(harness.invoke(ACTION, p, nil)):toBeOk()
	end)

	it("rate buckets are per player — one spammer cannot lock the board for everyone", function()
		local h = newServer()
		local spammer = h:seat(1, 10)
		local bystander = h:seat(2, 20)
		local harness = h:wire({ rate = true })
		local policy = LeaderboardService:fetchAction().rate
		for _ = 1, policy.maxPerWindow do
			harness.invoke(ACTION, spammer, nil)
		end
		expect(harness.invoke(ACTION, spammer, nil)):toBeErr(Result.Codes.RateLimited)
		expect(harness.invoke(ACTION, bystander, nil)):toBeOk()
	end)

	it("ownership: `you` is derived from the CALLER, never from the payload", function()
		-- Two players served from the SAME cached snapshot must each get their own standing. If the
		-- caller's identity were taken from anywhere but ctx.player, this would hand one player
		-- another's rank.
		local h = newServer()
		local first = h:seat(1, 900, "Aaa")
		local second = h:seat(2, 100, "Bbb")
		local harness = h:wire()
		local a = boardOf(harness.invoke(ACTION, first, nil))
		local b = boardOf(harness.invoke(ACTION, second, nil))
		expect(a.builtAtUnix):toBe(b.builtAtUnix) -- the same snapshot
		expect(a.you.rank):toBe(1)
		expect(a.you.lifetimeCredits):toBe(900)
		expect(b.you.rank):toBe(2)
		expect(b.you.lifetimeCredits):toBe(100)
	end)

	it("an unknown action name is not answered by this service", function()
		local h = newServer()
		local p = h:seat(1, 10)
		local harness = h:wire()
		expect(harness.invoke("leaderboard.fetchall", p, nil)):toBeErr(Result.Codes.UnknownAction)
	end)
end)

-- ── the ranking itself ──────────────────────────────────────────────────────────────────────────

describe("leaderboard ranking — order, ties, top-N, own rank", function()
	it("orders by lifetimeCredits DESCENDING, not by join order", function()
		local h = newServer()
		h:seat(1, 50, "Aaa") -- seated first, lowest
		h:seat(2, 500, "Bbb")
		h:seat(3, 250, "Ccc")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(#board.entries):toBe(3)
		expect(board.entries[1].userId):toBe(2)
		expect(board.entries[2].userId):toBe(3)
		expect(board.entries[3].userId):toBe(1)
		expect(board.entries[1].lifetimeCredits):toBe(500)
		expect(board.entries[3].lifetimeCredits):toBe(50)
	end)

	it("ranks on LIFETIME, never on the spent-down Credits balance", function()
		-- The slice: "NEVER derives it from currencies.Credits (which is the SPENT-DOWN balance, so a
		-- leaderboard ranked on it would demote the player who just bought something)". Big spender
		-- vs. hoarder: the spender has earned far more but holds far less.
		local h = newServer()
		local spender = h:seat(1, nil, "Aaa")
		local hoarder = h:seat(2, nil, "Bbb")
		h.raw:update(spender, function(d: any): any
			d.stats.lifetimeCredits = 5000
			d.currencies.Credits = 1 -- spent it all
			return d
		end)
		h.raw:update(hoarder, function(d: any): any
			d.stats.lifetimeCredits = 400
			d.currencies.Credits = 400 -- never spent
			return d
		end)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, spender, nil))
		expect(board.entries[1].userId):toBe(1)
		expect(board.entries[1].lifetimeCredits):toBe(5000)
		expect(board.entries[2].userId):toBe(2)
	end)

	it("ranks are 1..n, contiguous and ascending down the board", function()
		local h = newServer()
		for userId = 1, 6 do
			h:seat(userId, userId * 10)
		end
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		for index, standing in board.entries do
			expect(standing.rank):toBe(index)
		end
	end)

	it("the top-N cap holds: more players than rows -> exactly topN entries", function()
		local h = newServer()
		local topN = LeaderboardService.TOP_N
		for userId = 1, topN + 5 do
			h:seat(userId, userId * 7)
		end
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(board.topN):toBe(topN)
		expect(#board.entries):toBe(topN)
		expect(board.playerCount):toBe(topN + 5)
	end)

	it("boundary: exactly topN players -> every one is shown", function()
		local h = newServer()
		local topN = LeaderboardService.TOP_N
		for userId = 1, topN do
			h:seat(userId, userId * 7)
		end
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(#board.entries):toBe(topN)
		expect(board.playerCount):toBe(topN)
	end)

	it("boundary: a single player -> one entry, rank 1", function()
		local h = newServer()
		local p = h:seat(1, 0)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(#board.entries):toBe(1)
		expect(board.entries[1].rank):toBe(1)
		expect(board.you.ranked):toBe(true)
		expect(board.you.rank):toBe(1)
	end)

	it("own rank comes from the FULL ordering: last place still learns it is last", function()
		-- A player far below the cut must still be told where they stand — the slice's snapshot is
		-- "top-N" for DISPLAY, but the caller's own rank is resolved against everyone.
		local h = newServer()
		local topN = LeaderboardService.TOP_N
		local total = topN + 4
		for userId = 1, total do
			-- userId 1 is the RICHEST; the last seated is the poorest.
			h:seat(userId, (total - userId + 1) * 100)
		end
		local last = h.roster[total]
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, last, nil))
		expect(#board.entries):toBe(topN)
		expect(board.you.ranked):toBe(true)
		expect(board.you.rank):toBe(total)
		expect(board.you.lifetimeCredits):toBe(100)
		-- and they are genuinely NOT on the displayed board.
		local onBoard = false
		for _, standing in board.entries do
			if standing.userId == last.UserId then
				onBoard = true
			end
		end
		expect(onBoard):toBe(false)
	end)

	it("ties do not crash and produce distinct, deterministic adjacent ranks", function()
		-- Two players on exactly 0 lifetime Credits is the COMMON case on a fresh server. A merely
		-- descending comparator is not a total order and table.sort raises on one.
		local h = newServer()
		for userId = 1, 5 do
			h:seat(userId, 0)
		end
		local harness = h:wire()
		local first = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(#first.entries):toBe(5)
		local seenRanks: { [number]: boolean } = {}
		for _, standing in first.entries do
			expect(seenRanks[standing.rank]):toBe(nil)
			seenRanks[standing.rank] = true
		end
		-- Deterministic: a rebuild of the SAME roster yields the SAME order.
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
		local second = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		for index, standing in first.entries do
			expect(second.entries[index].userId):toBe(standing.userId)
		end
	end)

	it("a tie STRADDLING the top-N cut: distinct ranks, order-independent cut", function()
		-- The existing tie case seats 5 players on 0 with TOP_N = 10, so every tie sits well inside the
		-- cut and the BOUNDARY is never exercised. The interesting case is players tied ACROSS it: the
		-- one just below must be told TOP_N+1 rather than sharing the last displayed rank, and which
		-- players make the cut must not depend on the order the roster happens to arrive in (an engine
		-- roster is read across joins and rejoins, so its order is not stable).
		local h = newServer()
		local topN = LeaderboardService.TOP_N
		for userId = 1, topN + 2 do
			h:seat(userId, 4242, `Diver{userId + 100}`) -- IDENTICAL totals, distinct names
		end
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(#board.entries):toBe(topN)
		expect(board.playerCount):toBe(topN + 2)

		local onBoard: { [number]: boolean } = {}
		local seenRank: { [number]: boolean } = {}
		for index, standing in board.entries do
			expect(standing.lifetimeCredits):toBe(4242)
			expect(standing.rank):toBe(index)
			expect(seenRank[standing.rank]):toBe(nil)
			seenRank[standing.rank] = true
			onBoard[standing.userId] = true
		end

		-- the two tied players BELOW the cut each learn a distinct rank past it, and neither appears
		local belowRanks: { [number]: boolean } = {}
		local below = 0
		for _, player in h.roster do
			if not onBoard[player.UserId] then
				below += 1
				local mine = boardOf(harness.invoke(ACTION, player, nil))
				expect(mine.you.ranked):toBe(true)
				expect(mine.you.rank > topN):toBe(true)
				expect(belowRanks[mine.you.rank]):toBe(nil)
				belowRanks[mine.you.rank] = true
				for _, standing in mine.entries do
					expect(standing.userId).never:toBe(player.UserId)
				end
			end
		end
		expect(below):toBe(2)
		expect(belowRanks[topN + 1]):toBe(true)
		expect(belowRanks[topN + 2]):toBe(true)

		-- Same players, same totals, REVERSED join order: a tiebreak that is a genuine total order
		-- gives byte-for-byte the same cut. One that falls back to roster order does not.
		local reversed: { any } = {}
		for index = #h.roster, 1, -1 do
			table.insert(reversed, h.roster[index])
		end
		for index = 1, #h.roster do
			h.roster[index] = reversed[index]
		end
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
		local again = boardOf(harness.invoke(ACTION, h.roster[1], nil))
		expect(#again.entries):toBe(topN)
		for index, standing in board.entries do
			expect(again.entries[index].userId):toBe(standing.userId)
			expect(again.entries[index].rank):toBe(standing.rank)
		end
	end)

	it(
		"a caller who is loaded but NOT on the roster gets a board with you.ranked = false",
		function()
			local h = newServer()
			h:seat(1, 100)
			local offRoster = Mocks.player(99)
			h.raw:loadSession(offRoster) -- loaded, but never added to the roster
			local harness = h:wire()
			local board = boardOf(harness.invoke(ACTION, offRoster, nil))
			expect(board.you.ranked):toBe(false)
			expect(board.you.rank):toBe(0)
			expect(board.you.lifetimeCredits):toBe(0)
			expect(#board.entries):toBe(1)
		end
	)

	it("the JOIN WINDOW is bounded and self-consistent", function()
		-- The suite covers the OFF-roster caller and the UNLOADED caller but not the common join-time
		-- path: B joins inside the cadence, B's own get succeeds, and `current` serves a snapshot built
		-- before B arrived. The slice PERMITS that staleness — the board is "rebuilt on a server-clock
		-- cadence" — but it bounds it at one interval, and it never permits an INCONSISTENT board: a
		-- caller told a standing that does not match the ranking it was handed.
		local h = newServer({ startUnix = 1000 })
		local incumbent = h:seat(1, 100, "Aaa")
		local harness = h:wire()
		expect(boardOf(harness.invoke(ACTION, incumbent, nil)).playerCount):toBe(1)

		h.clock:advance(1) -- still inside the interval
		local joiner = h:seat(2, 5000, "Bbb") -- fully loaded, on the roster, richest player here
		local duringWindow = boardOf(harness.invoke(ACTION, joiner, nil))
		local onBoard = false
		for _, standing in duringWindow.entries do
			if standing.userId == joiner.UserId then
				onBoard = true
			end
		end
		-- whichever way the cached snapshot answers, the two halves of the reply AGREE
		expect(duringWindow.you.ranked):toBe(onBoard)
		if not duringWindow.you.ranked then
			expect(duringWindow.you.rank):toBe(0)
			expect(duringWindow.playerCount):toBe(1)
		end

		-- and the window CLOSES on the cadence: one interval later the joiner is ranked, at the top
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local closed = boardOf(harness.invoke(ACTION, joiner, nil))
		expect(closed.playerCount):toBe(2)
		expect(closed.you.ranked):toBe(true)
		expect(closed.you.rank):toBe(1)
		expect(closed.entries[1].userId):toBe(joiner.UserId)
		expect(closed.nextRebuildUnix - closed.builtAtUnix):toBe(
			LeaderboardService.REBUILD_INTERVAL_SECONDS
		)
	end)

	it("an empty roster serves an empty board, not an error", function()
		local h = newServer()
		local lonely = Mocks.player(5)
		h.raw:loadSession(lonely)
		local harness = h:wire()
		local result = harness.invoke(ACTION, lonely, nil)
		expect(result):toBeOk()
		local board = boardOf(result)
		expect(#board.entries):toBe(0)
		expect(board.playerCount):toBe(0)
		expect(board.you.ranked):toBe(false)
	end)

	it(
		"a roster listing one player TWICE ranks them once (no dupe row, no inflated count)",
		function()
			local h = newServer()
			local p = h:seat(1, 300)
			table.insert(h.roster, p) -- the same player object again (a rejoin-window read)
			table.insert(h.roster, Mocks.player(1, "Player_1")) -- and a second object, same UserId
			h:seat(2, 100)
			local harness = h:wire()
			local board = boardOf(harness.invoke(ACTION, p, nil))
			expect(board.playerCount):toBe(2)
			expect(#board.entries):toBe(2)
			expect(board.entries[1].userId):toBe(1)
			expect(board.entries[2].userId):toBe(2)
		end
	)

	it("a player who is still LOADING is skipped, never ranked at 0", function()
		-- Ranking an unloaded session at 0 would flash a joining player in at last place and then
		-- jump them; it would also let a mid-load blob be published as a real total.
		local h = newServer()
		local loaded = h:seat(1, 500)
		h:seatUnloaded(2)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, loaded, nil))
		expect(board.playerCount):toBe(1)
		expect(#board.entries):toBe(1)
		expect(board.entries[1].userId):toBe(1)
	end)

	it("a DEAD session (lock stolen elsewhere) is skipped, not published", function()
		local h = newServer()
		local alive = h:seat(1, 500)
		local dead = h:seat(2, 999999)
		h.raw:markDead(dead.UserId, Result.Codes.LockStolen)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, alive, nil))
		expect(board.playerCount):toBe(1)
		expect(board.entries[1].userId):toBe(1)
	end)

	it(
		"a freshly loaded default blob ranks at exactly 0 (the field is read, never created)",
		function()
			local h = newServer()
			local p = h:seat(1) -- no seeding: the production default blob
			local harness = h:wire()
			local board = boardOf(harness.invoke(ACTION, p, nil))
			expect(board.entries[1].lifetimeCredits):toBe(0)
			expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(0)
		end
	)
end)

-- ── the ranking key is read defensively (boundaries / overflow) ──────────────────────────────────

describe("leaderboard ranking key — boundary and garbage values", function()
	local function entryFor(board: any, userId: number): any
		for _, standing in board.entries do
			if standing.userId == userId then
				return standing
			end
		end
		return nil
	end

	it("a NaN ranking key reads as 0 and does not take the whole board down", function()
		-- Every comparison against NaN is false, so an unchecked NaN makes the comparator
		-- non-transitive and table.sort raises "invalid order function".
		local h = newServer()
		local sane = h:seat(1, 100, "Aaa")
		h:seat(2, NAN, "Bbb")
		local harness = h:wire()
		local result = harness.invoke(ACTION, sane, nil)
		expect(result):toBeOk()
		local board = boardOf(result)
		expect(board.playerCount):toBe(2)
		expect(entryFor(board, 2).lifetimeCredits):toBe(0)
		expect(board.entries[1].userId):toBe(1)
	end)

	it("an INFINITE ranking key reads as 0 and cannot seize rank 1", function()
		local h = newServer()
		local honest = h:seat(1, 100, "Aaa")
		h:seat(2, math.huge, "Bbb")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, honest, nil))
		expect(board.entries[1].userId):toBe(1)
		expect(entryFor(board, 2).lifetimeCredits):toBe(0)
	end)

	it("a NEGATIVE ranking key reads as 0 (never a negative number on the board)", function()
		local h = newServer()
		local p = h:seat(1, -5000, "Aaa")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.entries[1].lifetimeCredits):toBe(0)
		expect(board.you.lifetimeCredits):toBe(0)
	end)

	it("a FRACTIONAL ranking key is floored, never rendered as a fraction", function()
		local h = newServer()
		local p = h:seat(1, 1234.987, "Aaa")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.entries[1].lifetimeCredits):toBe(1234)
	end)

	it("a very large but FINITE total is preserved exactly (no overflow, no clamp)", function()
		local h = newServer()
		local whale = h:seat(1, 9007199254740992, "Aaa") -- 2^53
		h:seat(2, 100, "Bbb")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, whale, nil))
		expect(board.entries[1].userId):toBe(1)
		expect(board.entries[1].lifetimeCredits):toBe(9007199254740992)
	end)

	it("a non-number ranking key reads as 0 rather than crossing the wire", function()
		local h = newServer()
		local p = h:seat(1, "999999999" :: any, "Aaa")
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.entries[1].lifetimeCredits):toBe(0)
		expect(type(board.entries[1].lifetimeCredits)):toBe("number")
	end)

	it("a whole roster of garbage keys sorts without error and loses nobody", function()
		local h = newServer()
		local p = h:seat(1, NAN, "Aaa")
		h:seat(2, math.huge, "Bbb")
		h:seat(3, -1, "Ccc")
		h:seat(4, NAN, "Ddd")
		h:seat(5, 0, "Eee")
		local harness = h:wire()
		local result = harness.invoke(ACTION, p, nil)
		expect(result):toBeOk()
		expect(boardOf(result).playerCount):toBe(5)
		expect(#boardOf(result).entries):toBe(5)
	end)

	it("a blob missing `stats` entirely reads as 0 rather than crashing the board", function()
		local h = newServer()
		local broken = h:seat(1, nil, "Aaa")
		h.raw:update(broken, function(d: any): any
			d.stats = nil
			return d
		end)
		h:seat(2, 50, "Bbb")
		local harness = h:wire()
		local result = harness.invoke(ACTION, h.roster[2], nil)
		expect(result):toBeOk()
		local board = boardOf(result)
		expect(board.entries[1].userId):toBe(2)
		expect(entryFor(board, 1).lifetimeCredits):toBe(0)
	end)
end)

-- ── THE CRITICAL CONSTRAINT: the board only reads ────────────────────────────────────────────────

describe("leaderboard is READ-ONLY (the slice's CRITICAL constraint)", function()
	it("FALSIFICATION: the write detector is live — a write through it IS counted", function()
		-- Every "writes.update == 0" assertion below is worthless if the counting proxy is dead. This
		-- is the instrument's own calibration: the SAME object the service is handed, written through
		-- once, must register. Without it a proxy that silently forgot to increment would make the
		-- whole read-only suite green against a board that wrote on every fetch.
		local h = newServer()
		local p = h:seat(1, 100)
		h:resetWrites()
		expect(h.writes.update):toBe(0)
		h.data:update(p, function(d: any): any
			d.stats.lifetimeCredits = 999
			return d
		end)
		expect(h.writes.update):toBe(1)
		h.data:save(p)
		expect(h.writes.save):toBe(1)
		-- and the write really landed, so the proxy is not swallowing the call either.
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(999)
	end)

	it("FALSIFICATION: the blob comparator is live — a one-field delta IS detected", function()
		-- The write counter is calibrated above; `deepEqual` was not. It is the ONLY instrument that
		-- can catch an in-place mint (DataService.get hands back the LIVE session table, so a service
		-- can mutate a blob with zero update/save calls), and it is only ever asserted in the TRUE
		-- direction — an always-true comparator would hollow out the byte-identical test silently.
		local h = newServer()
		local p = h:seat(1, 100)
		local before = deepCopy((h.raw:get(p) :: any).value)
		expect(deepEqual((h.raw:get(p) :: any).value, before)):toBe(true)
		-- exactly the mutation the byte-identical test is looking for: one field, moved by one
		h.raw:update(p, function(d: any): any
			d.stats.lifetimeCredits = 101
			return d
		end)
		expect(deepEqual((h.raw:get(p) :: any).value, before)):toBe(false)
		-- an ADDED key, a REMOVED key and a NESTED delta are all caught, in both argument orders
		expect(deepEqual({ a = 1 }, { a = 1, b = 2 })):toBe(false)
		expect(deepEqual({ a = 1, b = 2 }, { a = 1 })):toBe(false)
		expect(deepEqual({ a = { b = 1 } }, { a = { b = 2 } })):toBe(false)
		expect(deepEqual({ a = 1 }, { a = "1" })):toBe(false)
	end)

	it("a fetch makes ZERO data:update and ZERO data:save calls", function()
		local h = newServer()
		local p = h:seat(1, 400)
		h:seat(2, 300)
		local harness = h:wire()
		h:resetWrites()
		expect(harness.invoke(ACTION, p, nil)):toBeOk()
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
	end)

	it("SPAMMED fetches leave every ranked player's blob byte-identical", function()
		-- The mint/erase check, stated as a DELTA over the whole persisted shape: a board that
		-- "healed" stats.lifetimeCredits from currencies.Credits would pass a numbers-only test and
		-- fail this one.
		local h = newServer()
		local a = h:seat(1, 5000, "Aaa")
		local b = h:seat(2, 0, "Bbb")
		h.raw:update(a, function(d: any): any
			d.currencies.Credits = 3
			return d
		end)
		h.raw:update(b, function(d: any): any
			d.currencies.Credits = 7777
			return d
		end)
		local beforeA = deepCopy((h.raw:get(a) :: any).value)
		local beforeB = deepCopy((h.raw:get(b) :: any).value)
		local harness = h:wire()
		h:resetWrites()
		for _ = 1, 20 do
			-- force a rebuild every time so the WRITE paths, not just the cache, are exercised
			h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
			expect(harness.invoke(ACTION, a, nil)):toBeOk()
			expect(harness.invoke(ACTION, b, nil)):toBeOk()
		end
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
		expect(deepEqual((h.raw:get(a) :: any).value, beforeA)):toBe(true)
		expect(deepEqual((h.raw:get(b) :: any).value, beforeB)):toBe(true)
	end)

	it("the board never MINTS lifetime for a player sitting on zero", function()
		local h = newServer()
		local pauper = h:seat(1, 0, "Aaa")
		h.raw:update(pauper, function(d: any): any
			d.currencies.Credits = 999999 -- a fat balance the board must NOT convert into lifetime
			return d
		end)
		local harness = h:wire()
		for _ = 1, 5 do
			h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
			harness.invoke(ACTION, pauper, nil)
		end
		expect((h.raw:get(pauper) :: any).value.stats.lifetimeCredits):toBe(0)
		expect((h.raw:get(pauper) :: any).value.currencies.Credits):toBe(999999)
	end)

	it("the board never ERASES lifetime for a player who has spent down", function()
		local h = newServer()
		local spender = h:seat(1, 8000, "Aaa")
		h.raw:update(spender, function(d: any): any
			d.currencies.Credits = 0
			return d
		end)
		local harness = h:wire()
		for _ = 1, 5 do
			h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS + 1)
			harness.invoke(ACTION, spender, nil)
		end
		expect((h.raw:get(spender) :: any).value.stats.lifetimeCredits):toBe(8000)
		expect((h.raw:get(spender) :: any).value.currencies.Credits):toBe(0)
	end)

	it("earn then SPEND through the REAL EconomyService: the board keeps the lifetime", function()
		-- The slice's central negative — "must not compute it from a balance" — driven through the
		-- real earn AND the real spend path. The spender-vs-hoarder case hand-seeds both fields, so a
		-- board that healed lifetime from currencies.Credits is only caught there by a value that was
		-- never produced by a spend; here the balance is spent to ZERO by EconomyService:spend, which
		-- is the exact state a "healing" board would misreport.
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 0)
		local economy = EconomyService.new()
		local harness = h:wire()

		h.raw:update(p, function(d: any): any
			economy:earn(d, "Credits", 500, "smelt")
			return d
		end)
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local afterEarn = boardOf(harness.invoke(ACTION, p, nil))
		expect(afterEarn.entries[1].lifetimeCredits):toBe(500)
		expect((h.raw:get(p) :: any).value.currencies.Credits):toBe(500)

		h:resetWrites()
		local spent: any = nil
		h.raw:update(p, function(d: any): any
			spent = economy:spend(d, "Credits", 500, "structure.smelter")
			return d
		end)
		expect(spent):toBeOk()
		expect((h.raw:get(p) :: any).value.currencies.Credits):toBe(0)
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(500)

		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local afterSpend = boardOf(harness.invoke(ACTION, p, nil))
		expect(afterSpend.entries[1].lifetimeCredits):toBe(500)
		expect(afterSpend.you.lifetimeCredits):toBe(500)
		expect(afterSpend.you.rank):toBe(1)
		expect(afterSpend.builtAtUnix).never:toBe(afterEarn.builtAtUnix) -- a genuine rebuild, not cache
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
	end)

	it("a REFUSED fetch (bad payload, rate limit) also writes nothing", function()
		local h = newServer()
		local p = h:seat(1, 100)
		local harness = h:wire({ rate = true })
		h:resetWrites()
		expect(harness.invoke(ACTION, p, { limit = 500 })):toBeErr(Result.Codes.BadPayload)
		local policy = LeaderboardService:fetchAction().rate
		for _ = 1, policy.maxPerWindow + 3 do
			harness.invoke(ACTION, p, nil)
		end
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
	end)

	it("the periodic PUSH writes nothing either", function()
		local h = newServer()
		h:seat(1, 400)
		h:seat(2, 200)
		local pushed = 0
		local context: any = {
			clock = h.clock,
			data = h.data,
			net = {
				fireClient = function(_self: any, _player: any, _event: string, _board: any): ()
					pushed += 1
				end,
			},
		}
		h:resetWrites()
		expect(LeaderboardService:pushAll(context)):toBe(2)
		expect(pushed):toBe(2)
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
	end)
end)

-- ── no dependency on any other feature's service ─────────────────────────────────────────────────

describe("leaderboard depends on the data layer and nothing else", function()
	it("fetch succeeds with EVERY feature seam absent (economy/plot/salvage/depth nil)", function()
		local h = newServer()
		local p = h:seat(1, 250)
		local harness = h:wire() -- all seams deliberately nil
		local result = harness.invoke(ACTION, p, nil)
		expect(result):toBeOk()
		expect(boardOf(result).entries[1].lifetimeCredits):toBe(250)
	end)

	it("a direct fetch works off a bare ctx of { player, clock, data }", function()
		local h = newServer()
		local p = h:seat(1, 77)
		local result = LeaderboardService:fetch(h:ctx(p))
		expect(result):toBeOk()
		expect(boardOf(result).you.lifetimeCredits):toBe(77)
	end)

	it("the CALLER's own unloaded session surfaces Err(NoData) — the JoinRetry signal", function()
		-- The client guard re-issues on the on-load data push; a board that answered "you: unranked"
		-- here would be indistinguishable from a genuinely unranked player and never self-correct.
		local h = newServer()
		h:seat(1, 500)
		local joining = h:seatUnloaded(2)
		local harness = h:wire()
		local result = harness.invoke(ACTION, joining, nil)
		expect(result):toBeErr(Result.Codes.NoData)
		expect(h.writes.update):toBe(0)
	end)

	it("the CALLER's dead session surfaces Err(LockStolen), never stale standings", function()
		local h = newServer()
		local p = h:seat(1, 500)
		h.raw:markDead(p.UserId, Result.Codes.LockStolen)
		local harness = h:wire()
		expect(harness.invoke(ACTION, p, nil)):toBeErr(Result.Codes.LockStolen)
	end)

	it("a fabricated player with no numeric UserId -> Err, never a crash or a board", function()
		local h = newServer()
		h:seat(1, 100)
		local harness = h:wire()
		local fake: any = { UserId = "1 or 1=1", Name = "Exploiter" }
		local result = harness.invoke(ACTION, fake, nil)
		expect(result):toBeErr()
		expect((result :: any).value):toBe(nil)
	end)

	it("a missing data/clock on the context is refused, not silently answered", function()
		local h = newServer()
		local p = h:seat(1, 100)
		expect(LeaderboardService:fetch({ player = p, clock = h.clock })):toBeErr()
		expect(LeaderboardService:fetch({ player = p, data = h.data })):toBeErr()
	end)
end)

-- ── names: Roblox-provided only (CLAUDE.md rule 9) ───────────────────────────────────────────────

describe("leaderboard renders only Roblox-provided names", function()
	it("the entry's name is the Player.Name, not any string from the blob", function()
		local h = newServer()
		local p = h:seat(1, 100, "RealRobloxName")
		-- Plant player-authored-looking text on the blob. Nothing on the board may pick it up.
		h.raw:update(p, function(d: any): any
			d.name = "<b>PWNED</b>"
			d.displayName = "<b>PWNED</b>"
			d.stats.name = "<b>PWNED</b>"
			return d
		end)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.entries[1].name):toBe("RealRobloxName")
		expect(board.entries[1].displayName):toBe("RealRobloxName")
		expect(board.entries[1].name).never:toBe("<b>PWNED</b>")
		expect(board.entries[1].displayName).never:toBe("<b>PWNED</b>")
	end)

	it("Player.DisplayName is used when Roblox supplies one", function()
		local h = newServer()
		local p = h:seat(1, 100, "AccountName")
		p.DisplayName = "Shown Name"
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.entries[1].name):toBe("AccountName")
		expect(board.entries[1].displayName):toBe("Shown Name")
	end)

	it("a non-string Name degrades to a server label — no non-string crosses the wire", function()
		local h = newServer()
		local p = h:seat(1, 100, "Aaa")
		local weird: any = p
		weird.Name = 12345
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(type(board.entries[1].name)):toBe("string")
		expect(type(board.entries[1].displayName)):toBe("string")
		-- "a string" is satisfied by tostring(12345) = "12345", which is the SAME non-Roblox value
		-- wearing a string's clothes. The label must be SERVER-GENERATED: not the stringified garbage,
		-- and not empty.
		expect(board.entries[1].name).never:toBe(tostring(weird.Name))
		expect(board.entries[1].displayName).never:toBe(tostring(weird.Name))
		expect(board.entries[1].name ~= ""):toBe(true)
		expect(board.entries[1].displayName ~= ""):toBe(true)
		-- and the caller's own standing is the same row, so nothing routes around the label
		expect(board.you.rank):toBe(board.entries[1].rank)
	end)
end)

-- ── the cadence is on the SERVER clock (CLAUDE.md §7) ────────────────────────────────────────────

describe("leaderboard cadence — rebuilt on the injected server clock", function()
	it("builtAtUnix is the INJECTED clock's unix, not os.time", function()
		-- A hard falsifier for "server time, injectable clock": a real os.time is ~1.7e9 and can
		-- never equal the fake clock's 1000.
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 10)
		local harness = h:wire()
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.builtAtUnix):toBe(1000)
		expect(board.nextRebuildUnix):toBe(1000 + LeaderboardService.REBUILD_INTERVAL_SECONDS)
	end)

	it("inside the interval the SAME snapshot is served (the cost bound)", function()
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 100)
		local harness = h:wire()
		local first = boardOf(harness.invoke(ACTION, p, nil))
		-- the value changes underneath, but the cadence has not elapsed
		h.raw:update(p, function(d: any): any
			d.stats.lifetimeCredits = 999
			return d
		end)
		local interval = LeaderboardService.REBUILD_INTERVAL_SECONDS
		for _ = 1, interval - 1 do
			h.clock:advance(1)
			local again = boardOf(harness.invoke(ACTION, p, nil))
			expect(again.builtAtUnix):toBe(first.builtAtUnix)
			expect(again.entries[1].lifetimeCredits):toBe(100)
		end
	end)

	it("past the interval the board REBUILDS and shows the delta", function()
		-- The written-never-read guard, as a DELTA: an earn through the real EconomyService must
		-- become visible on the board. A board that never re-read would stay at 100 forever.
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 100)
		local harness = h:wire()
		expect(boardOf(harness.invoke(ACTION, p, nil)).entries[1].lifetimeCredits):toBe(100)
		local economy = EconomyService.new()
		h.raw:update(p, function(d: any): any
			economy:earn(d, "Credits", 250, "smelt")
			return d
		end)
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.builtAtUnix):toBe(1000 + LeaderboardService.REBUILD_INTERVAL_SECONDS)
		expect(board.entries[1].lifetimeCredits):toBe(350)
		expect(board.you.lifetimeCredits):toBe(350)
	end)

	it("a burst of fetches inside one interval costs exactly ONE build", function()
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 100)
		local harness = h:wire()
		-- the FIRST fetch is what builds the snapshot; everything after it must be served from cache.
		expect(boardOf(harness.invoke(ACTION, p, nil)).entries[1].lifetimeCredits):toBe(100)
		-- BUILDS ARE COUNTED, not inferred. The clock is frozen for this whole case, so builtAtUnix is
		-- 1000 whether the board rebuilt once or thirty times — the stamp loop below cannot see the
		-- claim in the title. A build reads every rostered player's blob through the counting proxy, so
		-- with ONE player on the roster a cache-served fetch costs exactly 1 get (the caller's own
		-- ownership read) and a rebuilding one costs 2.
		h:resetWrites()
		local stamps: { number } = {}
		for index = 1, 30 do
			-- mutate every time; a per-request rebuild would show it
			h.raw:update(p, function(d: any): any
				d.stats.lifetimeCredits = 100 + index
				return d
			end)
			local board = boardOf(harness.invoke(ACTION, p, nil))
			table.insert(stamps, board.builtAtUnix)
			expect(board.entries[1].lifetimeCredits):toBe(100)
		end
		for _, stamp in stamps do
			expect(stamp):toBe(1000)
		end
		-- 30 fetches, 30 ownership reads, ZERO rebuilds.
		expect(h.writes.get):toBe(30)
		expect(h.writes.update):toBe(0)
		-- CALIBRATION of the build counter itself: past the cadence, the very next fetch DOES rebuild
		-- and costs the extra roster read. Without this, "get == 30" could be a dead instrument.
		h:resetWrites()
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local rebuilt = boardOf(harness.invoke(ACTION, p, nil))
		expect(h.writes.get):toBe(2)
		expect(rebuilt.entries[1].lifetimeCredits):toBe(130)
	end)

	it("a clock that jumps BACKWARDS rebuilds rather than freezing the board forever", function()
		local h = newServer({ startUnix = 5000 })
		local p = h:seat(1, 100)
		local harness = h:wire()
		expect(boardOf(harness.invoke(ACTION, p, nil)).builtAtUnix):toBe(5000)
		h.raw:update(p, function(d: any): any
			d.stats.lifetimeCredits = 4242
			return d
		end)
		h.clock:advance(-2000) -- the snapshot is now stamped in the "future"
		local board = boardOf(harness.invoke(ACTION, p, nil))
		expect(board.builtAtUnix):toBe(3000)
		expect(board.entries[1].lifetimeCredits):toBe(4242)
	end)

	it("a fresh Start clears the previous server's cached board", function()
		local h = newServer({ startUnix = 1000 })
		h:seat(1, 777)
		local harness = h:wire()
		expect(boardOf(harness.invoke(ACTION, h.roster[1], nil)).playerCount):toBe(1)

		-- START ITSELF must do the clearing. `newServer` nils the module-level cache BEFORE calling
		-- Start, so a test that only ever looks at a fresh harness proves the FIXTURE cleared it and
		-- would stay green with `self._snapshot = nil` deleted from Start. So Start is called here
		-- directly, against the LIVE cache this server just built.
		expect(LeaderboardService._snapshot).never:toBe(nil)
		local reregistered: { [string]: any } = {}
		LeaderboardService:Start({
			clock = h.clock,
			data = h.data,
			net = {
				register = function(_self: any, action: any): ()
					reregistered[action.name] = action
				end,
			},
		})
		expect(LeaderboardService._snapshot):toBe(nil)
		expect(reregistered[ACTION]).never:toBe(nil)

		-- a new server (new roster, new store) must not inherit the old snapshot
		local fresh = newServer({ startUnix = 1000 })
		local solo = fresh:seat(2, 5)
		local freshHarness = fresh:wire()
		local board = boardOf(freshHarness.invoke(ACTION, solo, nil))
		expect(board.playerCount):toBe(1)
		expect(board.entries[1].userId):toBe(2)
	end)
end)

-- ── the served board cannot reach the cache ──────────────────────────────────────────────────────

describe("leaderboard hands out copies, never the cache", function()
	it("mutating a returned entry does not change what the next fetch serves", function()
		local h = newServer()
		local p = h:seat(1, 100, "Aaa")
		h:seat(2, 50, "Bbb")
		local harness = h:wire()
		local first = boardOf(harness.invoke(ACTION, p, nil))
		first.entries[1].lifetimeCredits = 88888888
		first.entries[1].name = "Tampered"
		table.remove(first.entries, 2)
		local second = boardOf(harness.invoke(ACTION, p, nil))
		expect(#second.entries):toBe(2)
		expect(second.entries[1].lifetimeCredits):toBe(100)
		expect(second.entries[1].name):toBe("Aaa")
	end)

	it("one player's board object is not another player's", function()
		local h = newServer()
		local a = h:seat(1, 100, "Aaa")
		local b = h:seat(2, 50, "Bbb")
		local harness = h:wire()
		local boardA = boardOf(harness.invoke(ACTION, a, nil))
		boardA.you.rank = 999
		local boardB = boardOf(harness.invoke(ACTION, b, nil))
		expect(boardB.you.rank):toBe(2)
		expect(boardA.entries).never:toBe(boardB.entries)
	end)
end)

-- ── concurrency: the economy is never disturbed by a read (CLAUDE.md §4) ─────────────────────────

describe("leaderboard under interleaved / spam-duplicated traffic", function()
	it("a fetch interleaved between two earns leaves the EXACT sum (no loss, no dupe)", function()
		local h = newServer()
		local p = h:seat(1, 0)
		local harness = h:wire()
		h:resetWrites()
		h:enableYield() -- forced yield INSIDE the update critical section
		local fetched: any = nil
		local cos = {
			coroutine.create(function()
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits += 100
					d.currencies.Credits += 100
					return d
				end)
			end),
			coroutine.create(function()
				fetched = harness.invoke(ACTION, p, nil)
			end),
			coroutine.create(function()
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits += 50
					d.currencies.Credits += 50
					return d
				end)
			end),
		}
		drain(cos)
		expect(fetched):toBeOk()
		local after: any = (h.raw:get(p) :: any).value
		expect(after.stats.lifetimeCredits):toBe(150)
		expect(after.currencies.Credits):toBe(150)
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
		-- WHAT THE BOARD ACTUALLY REPORTED. The exact totals above are DataService's FIFO guarantee
		-- (this feature writes nothing, so "no dupe" is vacuous for it); the leaderboard-specific claim
		-- is that the instant it published EXISTED. The fetch lands between the first earn's
		-- acquire-and-yield and its write-back, so the only legal reading is the pre-write 0 — never a
		-- half-applied blob, and never a number larger than the committed total.
		local observed = boardOf(fetched)
		expect(#observed.entries):toBe(1)
		expect(observed.entries[1].lifetimeCredits):toBe(0)
		expect(observed.entries[1].lifetimeCredits <= 150):toBe(true)
		-- and the caller's own block agrees with their own row (both are read inside the same fetch)
		expect(observed.you.ranked):toBe(true)
		expect(observed.you.lifetimeCredits):toBe(observed.entries[1].lifetimeCredits)
	end)

	it("FALSIFICATION: the store's in-critical-section yield is ARMED", function()
		-- The whole race block rests on `h:enableYield()` flipping storeOptions.yieldOnUpdate AFTER the
		-- store was constructed, which only works because MockStore reads the flag lazily inside
		-- session.update. If a refactor ever snapshotted the options table in MockStore.new, the flag
		-- would silently die and the interleave would degenerate into "the action called twice in a
		-- row" — green, and meaningless. So the instrument is calibrated directly: with the yield
		-- armed, ONE resume must leave the writer parked INSIDE the critical section with its write not
		-- yet applied.
		local h = newServer()
		local p = h:seat(1, 0)
		h:enableYield()
		local co = coroutine.create(function()
			h.raw:update(p, function(d: any): any
				d.stats.lifetimeCredits += 500
				return d
			end)
		end)
		local resumed = coroutine.resume(co)
		expect(resumed):toBe(true)
		expect(coroutine.status(co)):toBe("suspended")
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(0)
		drain({ co })
		expect(coroutine.status(co)):toBe("dead")
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(500)
	end)

	it("FALSIFICATION: a board that READ-THEN-WROTE the ranking key DOES lose the earn", function()
		-- The counter-case that makes the test above meaningful rather than trivially green: the
		-- SAME schedule, with a "healing" board (read the key, then write back what it read), lands on
		-- the WRONG total. Its write-back is driven through the STORE'S forced yield — not through a
		-- `coroutine.yield()` in this test body, which would prove only that the drain driver
		-- interleaves coroutines (a thing nothing doubted) and would keep passing with enableYield
		-- dead. And the wrong total is PINNED: `never:toBe(150)` passes on any number at all, including
		-- the 150 the schedule produces when the forced yield is a no-op... which is exactly the
		-- failure this counter-case exists to detect. 50 is the value the lost update lands on.
		local h = newServer()
		local p = h:seat(1, 0)
		h:enableYield()
		local cos = {
			coroutine.create(function()
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits += 100
					return d
				end)
			end),
			coroutine.create(function()
				local got: any = h.raw:get(p)
				local seen = got.value.stats.lifetimeCredits
				-- the read-then-write ANY "healing" board would do: the interleave point is the store's
				-- own yield inside this update's critical section.
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits = seen
					return d
				end)
			end),
			coroutine.create(function()
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits += 50
					return d
				end)
			end),
		}
		drain(cos)
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits).never:toBe(150)
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(50)
	end)

	it("SPAM-DUPLICATED fetches interleaved with earns: the total is still exact", function()
		local h = newServer()
		local p = h:seat(1, 0)
		local harness = h:wire()
		h:resetWrites()
		h:enableYield()
		local results: { any } = {}
		local cos: { thread } = {}
		for _ = 1, 3 do
			table.insert(
				cos,
				coroutine.create(function()
					h.raw:update(p, function(d: any): any
						d.stats.lifetimeCredits += 7
						return d
					end)
				end)
			)
		end
		for _ = 1, 6 do
			-- the SAME request fired six times, interleaved with the earns
			table.insert(
				cos,
				coroutine.create(function()
					table.insert(results, harness.invoke(ACTION, p, nil))
				end)
			)
		end
		drain(cos)
		expect(#results):toBe(6)
		-- EVERY BOARD'S CONTENT, not just its Ok-ness. A board that returned an empty list, a stale
		-- snapshot or a display-minted total under interleaving passes a toBeOk-only check. The only
		-- mint vector a read-only service has is REPORTING a number nobody ever had, so every reading
		-- must be one of the instants the three earns actually pass through — and never above the
		-- committed total.
		local legal: { [number]: boolean } = { [0] = true, [7] = true, [14] = true, [21] = true }
		for _, result in results do
			expect(result):toBeOk()
			local board = boardOf(result)
			expect(#board.entries):toBe(1)
			local reported = board.entries[1].lifetimeCredits
			expect(legal[reported]):toBe(true)
			expect(reported <= 21):toBe(true)
			expect(board.you.ranked):toBe(true)
			expect(board.you.lifetimeCredits):toBe(reported)
		end
		expect((h.raw:get(p) :: any).value.stats.lifetimeCredits):toBe(21)
		expect(h.writes.update):toBe(0)
	end)

	it("a fetch landing MID-UPDATE sees ONE whole instant, never a half-applied blob", function()
		-- A snapshot that yielded mid-build could rank one player's pre-earn total against another's
		-- post-earn one. Driven at the forced yield inside the critical section: the value the board
		-- reports must be an instant that actually existed (the pre-write one), and the post-drain
		-- rebuild must show the committed one.
		local h = newServer({ startUnix = 1000 })
		local p = h:seat(1, 100)
		local harness = h:wire()
		h:enableYield()
		local midFlight: any = nil
		local cos = {
			coroutine.create(function()
				h.raw:update(p, function(d: any): any
					d.stats.lifetimeCredits += 900
					return d
				end)
			end),
			coroutine.create(function()
				midFlight = harness.invoke(ACTION, p, nil)
			end),
		}
		drain(cos)
		expect(midFlight):toBeOk()
		expect(boardOf(midFlight).entries[1].lifetimeCredits):toBe(100)
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		expect(boardOf(harness.invoke(ACTION, p, nil)).entries[1].lifetimeCredits):toBe(1000)
	end)

	it("a MULTI-PLAYER snapshot describes ONE instant, not two players' different ones", function()
		-- The service's headline concurrency claim is that the WHOLE snapshot describes one instant,
		-- because the build cannot yield: "a snapshot that yielded mid-build could rank one player's
		-- pre-collect total against another's post-collect one". ONE player structurally cannot exhibit
		-- that defect, so the single-player MID-UPDATE case cannot test it. Two players can: A's earn is
		-- parked inside the store's critical section while B fetches, and the board that comes back must
		-- pair A's PRE-write total with B's committed one — one instant, and an ORDERING that belongs to
		-- the same instant as the values.
		local h = newServer({ startUnix = 1000 })
		local a = h:seat(1, 100, "Aaa")
		local b = h:seat(2, 500, "Bbb")
		local harness = h:wire()
		h:resetWrites()
		h:enableYield()
		local mid: any = nil
		local cos = {
			coroutine.create(function()
				h.raw:update(a, function(d: any): any
					d.stats.lifetimeCredits += 900 -- would take A from 100 to 1000: past B
					return d
				end)
			end),
			coroutine.create(function()
				mid = harness.invoke(ACTION, b, nil)
			end),
		}
		drain(cos)
		expect(mid):toBeOk()
		local board = boardOf(mid)
		expect(board.playerCount):toBe(2)
		local byUserId: { [number]: any } = {}
		for _, standing in board.entries do
			byUserId[standing.userId] = standing
		end
		expect(byUserId[a.UserId].lifetimeCredits):toBe(100)
		expect(byUserId[b.UserId].lifetimeCredits):toBe(500)
		-- and the ORDER matches those values: B leads at this instant. A board that read A after the
		-- earn committed and B before it would rank A first while still reporting 100 for A.
		expect(board.entries[1].userId):toBe(b.UserId)
		expect(board.entries[2].userId):toBe(a.UserId)
		expect(board.you.ranked):toBe(true)
		expect(board.you.rank):toBe(byUserId[b.UserId].rank)
		expect(board.you.lifetimeCredits):toBe(byUserId[b.UserId].lifetimeCredits)
		expect(h.writes.update):toBe(0)

		-- and the OTHER instant, once committed, is served whole
		h.clock:advance(LeaderboardService.REBUILD_INTERVAL_SECONDS)
		local after = boardOf(harness.invoke(ACTION, b, nil))
		expect(after.entries[1].userId):toBe(a.UserId)
		expect(after.entries[1].lifetimeCredits):toBe(1000)
		expect(after.entries[2].lifetimeCredits):toBe(500)
	end)

	it("the periodic PUSH driven across an IN-FLIGHT update publishes one instant", function()
		-- pushAll force-builds a fresh snapshot every interval, so in production it is the reader MOST
		-- likely to land mid-update — and it is otherwise only ever tested single-threaded.
		local h = newServer({ startUnix = 1000 })
		local a = h:seat(1, 100, "Aaa")
		h:seat(2, 500, "Bbb")
		local pushed: { [number]: any } = {}
		local context: any = {
			clock = h.clock,
			data = h.data,
			net = {
				fireClient = function(_self: any, player: any, _event: string, board: any): ()
					pushed[player.UserId] = board
				end,
			},
		}
		h:resetWrites()
		h:enableYield()
		local sent = 0
		local cos = {
			coroutine.create(function()
				h.raw:update(a, function(d: any): any
					d.stats.lifetimeCredits += 900
					return d
				end)
			end),
			coroutine.create(function()
				sent = LeaderboardService:pushAll(context)
			end),
		}
		drain(cos)
		expect(sent):toBe(2)
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)
		-- both pushed boards describe the SAME pre-write instant, and each carries its own `you`
		for _, userId in { 1, 2 } do
			local board = pushed[userId]
			expect(board).never:toBe(nil)
			expect(board.playerCount):toBe(2)
			expect(board.entries[1].userId):toBe(2)
			expect(board.entries[1].lifetimeCredits):toBe(500)
			expect(board.entries[2].userId):toBe(1)
			expect(board.entries[2].lifetimeCredits):toBe(100)
			expect(board.you.ranked):toBe(true)
			expect(board.you.rank):toBe(if userId == 2 then 1 else 2)
		end
	end)

	it("two players earning and fetching at once each keep their EXACT total", function()
		local h = newServer()
		local a = h:seat(1, 0, "Aaa")
		local b = h:seat(2, 0, "Bbb")
		local harness = h:wire()
		h:resetWrites()
		h:enableYield()
		-- Both replies are CAPTURED. Discarded, the two fetches are pure noise generators: every other
		-- assertion in this case is a DataService FIFO guarantee, so the test passed unchanged if
		-- leaderboard.fetch had returned Err on every call or a board full of minted numbers.
		local boardForB: any = nil
		local boardForA: any = nil
		local cos = {
			coroutine.create(function()
				h.raw:update(a, function(d: any): any
					d.stats.lifetimeCredits += 30
					return d
				end)
			end),
			coroutine.create(function()
				boardForB = harness.invoke(ACTION, b, nil)
			end),
			coroutine.create(function()
				h.raw:update(b, function(d: any): any
					d.stats.lifetimeCredits += 40
					return d
				end)
			end),
			coroutine.create(function()
				boardForA = harness.invoke(ACTION, a, nil)
			end),
			coroutine.create(function()
				h.raw:update(a, function(d: any): any
					d.stats.lifetimeCredits += 5
					return d
				end)
			end),
		}
		drain(cos)
		expect((h.raw:get(a) :: any).value.stats.lifetimeCredits):toBe(35)
		expect((h.raw:get(b) :: any).value.stats.lifetimeCredits):toBe(40)
		expect(h.writes.update):toBe(0)

		-- Each caller's OWN standing, under the race: `you` belongs to the caller, agrees with the
		-- caller's own row in the same board, and reports an instant that existed (never above that
		-- player's committed total).
		local ceilings: { [number]: number } = { [a.UserId] = 35, [b.UserId] = 40 }
		for _, pair in { { boardForA, a }, { boardForB, b } } do
			local result: any, caller: any = pair[1], pair[2]
			expect(result):toBeOk()
			local board = boardOf(result)
			expect(#board.entries):toBe(2)
			local mine: any = nil
			for _, standing in board.entries do
				if standing.userId == caller.UserId then
					mine = standing
				end
			end
			expect(mine).never:toBe(nil)
			expect(board.you.ranked):toBe(true)
			expect(board.you.rank):toBe(mine.rank)
			expect(board.you.lifetimeCredits):toBe(mine.lifetimeCredits)
			expect(mine.lifetimeCredits <= ceilings[caller.UserId]):toBe(true)
			expect(mine.lifetimeCredits >= 0):toBe(true)
		end
	end)
end)

-- ── the periodic push ────────────────────────────────────────────────────────────────────────────

describe("leaderboard periodic push", function()
	local function pushHarness(h: any, fireClient: any): any
		return {
			clock = h.clock,
			data = h.data,
			net = { fireClient = fireClient },
		}
	end

	it("pushes ONE board per rostered player, each carrying THEIR own standing", function()
		local h = newServer()
		local a = h:seat(1, 900, "Aaa")
		local b = h:seat(2, 100, "Bbb")
		local byUserId: { [number]: any } = {}
		local context = pushHarness(h, function(_self: any, player: any, event: string, board: any)
			byUserId[player.UserId] = { event = event, board = board }
		end)
		expect(LeaderboardService:pushAll(context)):toBe(2)
		expect(byUserId[a.UserId].event):toBe(LeaderboardService.PUSH_EVENT)
		expect(byUserId[a.UserId].board.you.rank):toBe(1)
		expect(byUserId[b.UserId].board.you.rank):toBe(2)
		expect(byUserId[b.UserId].board.you.lifetimeCredits):toBe(100)
	end)

	it("one client's failing push does not stop the rest of the server's", function()
		local h = newServer()
		h:seat(1, 900, "Aaa")
		h:seat(2, 100, "Bbb")
		h:seat(3, 50, "Ccc")
		local delivered = 0
		local context = pushHarness(
			h,
			function(_self: any, player: any, _event: string, _board: any)
				if player.UserId == 2 then
					error("this client's remote blew up")
				end
				delivered += 1
			end
		)
		expect(LeaderboardService:pushAll(context)):toBe(2)
		expect(delivered):toBe(2)
	end)

	it("a context with no net / no data pushes nothing and does not throw", function()
		local h = newServer()
		h:seat(1, 100)
		expect(LeaderboardService:pushAll(nil)):toBe(0)
		expect(LeaderboardService:pushAll({ clock = h.clock, data = h.data })):toBe(0)
		expect(
			LeaderboardService:pushAll({ clock = h.clock, net = { fireClient = function() end } })
		):toBe(0)
	end)

	it("the push carries the same top-N cap the fetch does", function()
		local h = newServer()
		local topN = LeaderboardService.TOP_N
		for userId = 1, topN + 3 do
			h:seat(userId, userId * 10)
		end
		local seen: { any } = {}
		local context = pushHarness(
			h,
			function(_self: any, _player: any, _event: string, board: any)
				table.insert(seen, board)
			end
		)
		expect(LeaderboardService:pushAll(context)):toBe(topN + 3)
		for _, board in seen do
			expect(#board.entries):toBe(topN)
			expect(board.playerCount):toBe(topN + 3)
		end
	end)

	it("a roster holding an UNLOADED and a DEAD session still pushes, and ranks neither", function()
		-- Every other push case uses fully seated players. The runtime loop fires every interval, so it
		-- runs straight through the join window and through a session whose lock was stolen — the loop
		-- must not skip the rest of the server on either, and neither of those sessions may be
		-- PUBLISHED as a standing (a mid-load blob is not a real total; a dead one is superseded).
		local h = newServer()
		h:seat(1, 900, "Aaa")
		h:seatUnloaded(2, "Bbb")
		local dead = h:seat(3, 400, "Ccc")
		h.raw:markDead(dead.UserId, Result.Codes.LockStolen)
		local pushed: { [number]: any } = {}
		local context: any = {
			clock = h.clock,
			data = h.data,
			net = {
				fireClient = function(_self: any, player: any, event: string, board: any): ()
					pushed[player.UserId] = { event = event, board = board }
				end,
			},
		}
		h:resetWrites()
		-- nobody on the roster is silently dropped by the push loop
		expect(LeaderboardService:pushAll(context)):toBe(3)
		expect(h.writes.update):toBe(0)
		expect(h.writes.save):toBe(0)

		-- only the LOADED player is ranked
		local mine = pushed[1].board
		expect(mine.playerCount):toBe(1)
		expect(#mine.entries):toBe(1)
		expect(mine.entries[1].userId):toBe(1)
		expect(mine.you.ranked):toBe(true)
		expect(mine.you.rank):toBe(1)
		expect(mine.you.lifetimeCredits):toBe(900)

		-- the joining and the dead recipient are told they are UNRANKED — never handed a standing that
		-- is not theirs, and never a total the server has already superseded.
		for _, userId in { 2, 3 } do
			expect(pushed[userId].event):toBe(LeaderboardService.PUSH_EVENT)
			expect(pushed[userId].board.you.ranked):toBe(false)
			expect(pushed[userId].board.you.rank):toBe(0)
			expect(pushed[userId].board.you.lifetimeCredits):toBe(0)
			expect(#pushed[userId].board.entries):toBe(1)
			expect(pushed[userId].board.entries[1].userId):toBe(1)
		end
	end)

	it("Stop clears the cache and stops the runtime loop", function()
		local h = newServer()
		h:seat(1, 100)
		local harness = h:wire()
		expect(harness.invoke(ACTION, h.roster[1], nil)):toBeOk()
		expect(LeaderboardService._snapshot).never:toBe(nil)
		expect(LeaderboardService._context).never:toBe(nil)
		-- ARM THE FLAG THE LOOP READS. `startRuntime` returns early under Lune (`game`/`task` are nil
		-- globals), so `_running` is false for the whole run and an unarmed `toBe(false)` asserts
		-- nothing — it is green with `self._running = false` deleted from Stop. The runtime loop is
		-- `while self._running do`, so flipping that flag IS "stops the loop" at this rung; that a real
		-- task loop then exits is a T2 in-engine claim.
		LeaderboardService._running = true
		LeaderboardService:Stop(h.startContext)
		expect(LeaderboardService._snapshot):toBe(nil)
		expect(LeaderboardService._running):toBe(false)
		-- and the captured server context is released with it: a retained context would keep the old
		-- server's data layer alive behind the next Start.
		expect(LeaderboardService._context):toBe(nil)
	end)
end)

-- ── the two halves of the slice are BOUND (source-level, the selene_guard.spec idiom) ────────────

-- LeaderboardController.luau is a LocalScript: `game:GetService` runs at module scope, so it is not
-- requirable under Lune and NO runtime assertion about it is possible at this rung (its rendering
-- and its pixels are a T2.7 concern and are declined as such). But the constants that BIND the two
-- halves are plain literals in BOTH files, and a drift between them is SILENT: the periodic push
-- would fire on an event nobody subscribed to and the board would freeze at whatever the join-time
-- fetch returned, with no error anywhere. That is a defect this repo's ladder says only T2.7 can
-- see — and a source-level equality assertion catches it here, for free. selene_guard.spec is the
-- in-repo precedent for reading a source file and asserting on it.
local CONTROLLER_CANDIDATES = {
	"src/client/controllers/leaderboard/LeaderboardController.luau",
	"games/deep-reach/src/client/controllers/leaderboard/LeaderboardController.luau",
	"../src/client/controllers/leaderboard/LeaderboardController.luau",
}
local SERVICE_CANDIDATES = {
	"src/server/services/leaderboard/LeaderboardService.luau",
	"games/deep-reach/src/server/services/leaderboard/LeaderboardService.luau",
	"../src/server/services/leaderboard/LeaderboardService.luau",
}

local function readFirst(candidates: { string }): string
	for _, path in candidates do
		if fs.isFile(path) then
			return fs.readFile(path)
		end
	end
	error(
		`leaderboard.spec: none of these paths exist from this cwd: {table.concat(candidates, ", ")}`
	)
end

-- Strip comments so an assertion about the CODE is never satisfied (or broken) by prose: this
-- service's header discusses EconomyService and OrderedDataStore at length precisely because it must
-- not touch either.
local function codeOnly(source: string): string
	local out: { string } = {}
	for line in string.gmatch(source, "[^\n]*") do
		if string.match(line, "^%s*%-%-") == nil then
			table.insert(out, (string.gsub(line, "%s%-%-.*$", "")))
		end
	end
	return table.concat(out, "\n")
end

describe("leaderboard: the server and the client agree on the push contract", function()
	it("the client subscribes to EXACTLY the event the server pushes on", function()
		local controller = readFirst(CONTROLLER_CANDIDATES)
		local clientEvent = string.match(controller, 'local PUSH_EVENT = "([^"]*)"')
		expect(clientEvent).never:toBe(nil)
		expect(clientEvent):toBe(LeaderboardService.PUSH_EVENT)
		-- and the literal is genuinely the one the subscription uses, not a dead constant
		expect(string.find(controller, "net:on(PUSH_EVENT", 1, true)).never:toBe(nil)
		-- the inbound half is bound through the shared registry rather than a second literal
		expect(string.find(controller, "Net.Actions.FetchLeaderboard", 1, true)).never:toBe(nil)
	end)

	it("the client has room for every row the server ranks", function()
		local controller = readFirst(CONTROLLER_CANDIDATES)
		local rows = tonumber(string.match(controller, "local ROW_COUNT = (%d+)"))
		expect(rows).never:toBe(nil)
		-- fewer display rows than the server's top-N silently truncates the board the slice promises
		expect((rows :: number) >= LeaderboardService.TOP_N):toBe(true)
	end)

	it("the HUD slot the client mounts into is a slot HudRoot actually declares", function()
		-- buildPanel() is called OUTSIDE the pcall in Start, and HudRoot.mount refuses an unknown slot
		-- loudly — so an unknown slot name throws, Bootstrap re-raises it, and EVERY other controller's
		-- HUD goes down with it. HudRoot is Lune-requirable, so this one is checkable here.
		local controller = readFirst(CONTROLLER_CANDIDATES)
		local slot = string.match(controller, 'local HUD_SLOT = "([^"]*)"')
		expect(slot).never:toBe(nil)
		expect(HudRoot.isSlot(slot)):toBe(true)
	end)
end)

describe("leaderboard SCOPE FENCE (asserted, not assumed)", function()
	it("the service makes no DataStore call of its own", function()
		-- "v1 is SERVER-LOCAL ranking … do not add DataStore calls outside src/server/data/". The
		-- seams-absent test proves the ctx seams are unread; it says nothing about a direct
		-- DataStoreService call, which would pass it unchanged.
		local code = codeOnly(readFirst(SERVICE_CANDIDATES))
		for _, banned in { "DataStoreService", "GetDataStore", "GetOrderedDataStore" } do
			expect(string.find(code, banned, 1, true)):toBe(nil)
		end
	end)

	it("the service requires no other feature's service", function()
		-- "must not require or depend on any other feature's service". A require is not a seam: a
		-- top-of-file require("../economy/EconomyService") passes every runtime test in this file.
		local code = codeOnly(readFirst(SERVICE_CANDIDATES))
		for argument in string.gmatch(code, "require%(([^)\n]*)") do
			local literal = string.match(argument, '"([^"]*)"')
			if literal ~= nil then
				-- every filesystem require this module makes crosses into src/shared and nowhere else
				expect(string.find(literal, "shared/", 1, true)).never:toBe(nil)
				expect(string.find(literal, "services/", 1, true)):toBe(nil)
			end
		end
		for _, sibling in
			{
				"EconomyService",
				"PlotService",
				"SalvageService",
				"DepthService",
				"DailyService",
				"OfflineService",
				"MonetizationService",
			}
		do
			expect(string.find(code, sibling, 1, true)):toBe(nil)
		end
	end)
end)
