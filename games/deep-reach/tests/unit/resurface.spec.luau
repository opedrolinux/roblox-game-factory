--!strict
-- games/deep-reach/tests/unit/resurface.spec.luau
-- [INDEPENDENT TEST GATE — authored from docs/build-records/deep-reach/slices/resurface.md (the
--  FEATURE CONTRACT), NOT from ResurfaceService's control flow. The implementation was read ONLY to
--  learn its observable interface: the two action factories, the `resurface` / `fetch` entry points
--  and the field names on their replies. Every EXPECTATION below is derived from the slice, and every
--  economic number is DISCOVERED through the public surface (the preview's own `minDepthTier` /
--  `pearls`, the action's own declared RatePolicy, and the rate `salvage.fetch` reports) rather than
--  copied out of the module. A build that re-tunes the Pearl divisor, the tier bonus or the +10%
--  prestige step stays green here; a build that wipes a field the slice says SURVIVES, mints Pearls
--  outside ctx.economy, moves stats.lifetimeCredits on a prestige, ships the multiplier inert, or
--  dupes Pearls under an interleave goes RED.]
--
-- THE CONTRACT UNDER TEST (verbatim guarantees from the slice):
--   1. THE ONE TRANSFORM — "`resurface.do`: in ONE DataService:update — verify the minimum depth
--      requirement (Err(PrereqUnmet) below it), compute the Pearls to mint from the player's
--      progress, then atomically: mint Pearls via ctx.economy:earn (currency="Pearls" — note this
--      must NOT increment stats.lifetimeCredits, which counts Credits only), set currencies.Credits
--      to 0, wipe the structure levels (upgrades.drones/conveyor/smelter/hull), reset upgrades.depth
--      to 1, clear smelter.storedCredits, and increment `resurfaces`. Emit `progression` with the new
--      count."
--   2. THE SURVIVE LIST, stated verbatim "because getting it wrong is a silent economy bug" —
--      "`resurfaces`, `currencies.Pearls`, `upgrades.pearlDrones` (Pearl purchases are permanent),
--      `stats.lifetimeCredits` (it is the leaderboard's ranking key — resetting it would rank
--      prestiged players last), `daily`, `plot`, `flags` and `receipts` all SURVIVE untouched."
--      PLUS AMENDMENT A6: "`boostExpiresUnix` SURVIVES a resurface, untouched" — real money bought
--      that expiry, and "a voluntary prestige confiscating paid time the player has not yet spent is
--      a refund request, not a game mechanic."
--   3. THE PERMANENT MULTIPLIER — "a server-derived function of `data.resurfaces` that Salvage core's
--      `rateFor` already reads off the blob. Landing this feature must produce a MEASURABLE DELTA on
--      the running rate returned by `salvage.fetch` — the multiplier is not allowed to ship inert."
--   4. THE SERVER-TRUTHED PREVIEW — "`resurface.fetch`: preview the Pearls that would be minted, the
--      resulting multiplier, and whether the minimum depth is met — so the confirm UI is
--      server-truthed and never guesses."
--   5. CONCURRENCY — "two `resurface.do` calls in the same frame must mint exactly one batch of
--      Pearls. The requirement check, the mint and the wipe all happen in the same lock-held
--      transform — a Pearl dupe here is a named success-criterion failure."
--   6. PROGRESSION (verbatim) — "Long game: 5 depth tiers, then resurface → Pearls → permanent income
--      multipliers", which is where the minimum-depth number comes from.
--   NOT THIS SLICE (so NOT asserted here): the Pearl-only drone catalog entry or its price
--      (Structures shop), the depth tier table / pressure gate / restock (Depth tiers — this feature
--      only RESETS upgrades.depth to 1), the income tick and the rate FORMULA (Salvage core).
--   Plus games/deep-reach/CLAUDE.md §3 (validate type + range + ownership + rate on EVERY inbound
--   client request) and §4 (concurrency-safe economy: no double-spend, no dupes).
--
-- WHY THE SURVIVE-LIST CASE IS A WHOLE-BLOB DIFF, NOT A LIST OF SPOT CHECKS. The slice says the exact
-- thing this feature is "most likely to get silently wrong" is the survive-vs-wipe boundary, and a
-- spot check can only catch the fields somebody thought to name. §4 below snapshots the ENTIRE blob,
-- resurfaces, and asserts the set of leaf paths that CHANGED is a subset of the nine the slice
-- authorizes. A build that also clears `daily.streak`, re-stamps `smelter.lastTickUnix` or drops a
-- receipt fails on the path it touched, whether or not this file ever mentions that field.
--
-- WHY THE MULTIPLIER CASES COMPARE TWO PLAYERS. "Not allowed to ship inert" cannot be proven by
-- reading `data.resurfaces` back — that is the written-never-read pattern that produced 26 of
-- collect-sim's 66 defects. So §6 takes the reading THROUGH `salvage.fetch` (the observable the slice
-- names) on two blobs that have been made IDENTICAL in every other field, so the only surviving
-- difference is the prestige count, and asserts the delta.
--
-- WHY THE CONCURRENCY CASES LOOK LIKE THIS. The dupe this feature is one mistake away from: check the
-- tier and compute the Pearls OUTSIDE the transform, yield in ctx.data:update, then mint. Two
-- resurfaces in the same frame both price the same run and the player is paid twice. Sequential calls
-- cannot tell that implementation from a correct one. So §8 drives the economy_race.spec idiom — a
-- MockStore with `yieldOnUpdate` (a forced yield INSIDE the update critical section) plus a
-- round-robin coroutine driver — with a service-level in-flight PEAK witness proving the second
-- request really did start while the first was parked in the store, and a FALSIFICATION counter-case
-- (a naive check-outside-the-lock resurface driven at the same yield point) that DOES mint twice.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local EconomyService = require("../../src/server/services/economy/EconomyService")
local Net = require("../../src/shared/Net")
local ResurfaceService = require("../../src/server/services/resurface/ResurfaceService")
local Result = require("../../src/shared/Result")
local SalvageService = require("../../src/server/services/salvage/SalvageService")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

local START_UNIX = 1_700_000_000

-- The currency names are CONTRACT (the slice names both verbatim), so they are stated here rather
-- than read off the module: a build that minted "pearls" or "Pearl" would be self-consistent and
-- every test that borrowed its own constant from it would stay green while the wire broke.
local PEARLS = "Pearls"
local CREDITS = "Credits"

-- The four Credits-bought structure levels the slice says are wiped, plus the depth key it says is
-- reset to 1. Same reasoning: named by the contract, so named here.
local WIPED_UPGRADE_KEYS = { "drones", "conveyor", "smelter", "hull" }
local DEPTH_KEY = "depth"
local SURVIVING_UPGRADE_KEY = "pearlDrones"

-- THE COMPLETE SET OF LEAF PATHS A RESURFACE IS AUTHORIZED TO CHANGE, transcribed from the slice's
-- wipe list plus the mint. Anything else moving is a survive-list violation by construction.
local ALLOWED_CHANGE_PATHS: { [string]: boolean } = {
	["currencies.Credits"] = true, -- "set currencies.Credits to 0"
	["currencies.Pearls"] = true, -- "mint Pearls via ctx.economy:earn"
	["upgrades.drones"] = true, -- "wipe the structure levels"
	["upgrades.conveyor"] = true,
	["upgrades.smelter"] = true,
	["upgrades.hull"] = true,
	["upgrades.depth"] = true, -- "reset upgrades.depth to 1"
	["smelter.storedCredits"] = true, -- "clear smelter.storedCredits"
	["resurfaces"] = true, -- "increment `resurfaces`"
}

-- ── assertion helpers ───────────────────────────────────────────────────────────────────────────

local function expectTrue(condition: boolean, why: string): ()
	if not condition then
		error(why, 0)
	end
end

local function expectFinite(value: any, why: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error(`{why}: expected a finite number, got {tostring(value)}`, 0)
	end
end

-- Relative-tolerance comparison: the rate is a PRODUCT of tuned steps, so exact binary equality is
-- not available for composed readings — but "this reading reached that number" is about magnitude.
local function expectClose(actual: number, expected: number, why: string): ()
	local tolerance = 1e-9 * math.max(1, math.abs(actual), math.abs(expected))
	if math.abs(actual - expected) > tolerance then
		error(`{why}: got {actual}, want {expected}`, 0)
	end
end

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

-- Flatten a blob to `path -> scalar`. Empty tables contribute no leaf, which is what we want: an
-- empty `receipts` map and an absent one are the same observable state to every reader.
local function leaves(value: any, prefix: string, out: { [string]: any }): ()
	if type(value) == "table" then
		for key, child in value do
			local path = if prefix == "" then tostring(key) else `{prefix}.{tostring(key)}`
			leaves(child, path, out)
		end
	elseif prefix ~= "" then
		out[prefix] = value
	end
end

-- Every leaf path whose value differs between two blobs (in either direction, including a key that
-- appeared or vanished), sorted for a stable failure message.
local function changedPaths(before: any, after: any): { string }
	local a: { [string]: any } = {}
	local b: { [string]: any } = {}
	leaves(before, "", a)
	leaves(after, "", b)
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for path, value in a do
		if b[path] ~= value then
			seen[path] = true
			table.insert(out, path)
		end
	end
	for path, value in b do
		if a[path] ~= value and not seen[path] then
			table.insert(out, path)
		end
	end
	table.sort(out)
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
			error("resurface race driver did not converge (possible deadlock)")
		end
		local still: { thread } = {}
		for _, co in live do
			if coroutine.status(co) == "suspended" then
				local ok, err = coroutine.resume(co)
				if not ok then
					error(`resurface race coroutine errored: {tostring(err)}`)
				end
			end
			if coroutine.status(co) ~= "dead" then
				table.insert(still, co)
			end
		end
		live = still
	end
end

-- THE INTERLEAVE WITNESS. `updates` alone cannot distinguish a real interleave from two sequential
-- calls, so a race case whose forced yield stopped being armed would silently degrade to two
-- sequential resurfaces and stay green. This wrapper counts how many calls were inside the service's
-- entry point AT THE SAME TIME: a peak of 2 is only reachable if the second request started while the
-- first was parked inside ctx.data:update.
local function inFlightCounter(): any
	local counter: any = { inFlight = 0, peak = 0, calls = 0 }
	function counter.wrap(self: any, body: () -> any): any
		self.calls += 1
		self.inFlight += 1
		if self.inFlight > self.peak then
			self.peak = self.inFlight
		end
		local result = body()
		self.inFlight -= 1
		return result
	end
	return counter
end

-- A SEPARATE SERVICE INSTANCE over the SAME data layer. The slice's concurrency guarantee is that
-- "the requirement check, the mint and the wipe all happen in the same lock-held transform" — a
-- guarantee about the TRANSFORM, not about any per-server memo a build might also keep. This clone
-- has its own service-local state, so a race driven through it exercises the transform directly and
-- an in-memory short-circuit cannot stand in for the lock.
local function separateInstance(): any
	local clone: any = table.clone(ResurfaceService :: any)
	clone._resurfacing = {}
	return clone
end

-- ── the world ───────────────────────────────────────────────────────────────────────────────────

-- A fresh server: the real DataService over the real MockStore, the real EconomyService over a real
-- AnalyticsService, the real SalvageService Started (so ctx.salvage is the SAME derived rate function
-- `salvage.fetch` runs on — the observable this slice's multiplier is graded against), and the
-- resurface service Started against a recording `net`.
--
-- NO ctx.depth seam is installed. It is optional to the rate function and belongs to another slice;
-- leaving it out keeps every rate reading below a pure function of the fields THIS feature writes.
local function newServer(options: any?): any
	local opts: any = options or {}
	local clock = Mocks.clock(opts.startUnix or START_UNIX)
	-- MockStore reads `yieldOnUpdate` off this LIVE table on every update, so the forced yield is
	-- armed only for the racing part of a case: it parks the CALLING coroutine, and a spec's setup
	-- writes run on the main thread, which nothing would resume.
	local storeOptions: any = { clock = clock, config = Config, yieldOnUpdate = false }
	local store = Mocks.store(storeOptions)
	local data = DataService.new(store, clock, Config, Mocks.logWarn)
	local analytics = AnalyticsService.new(clock)
	local economy = EconomyService.new(analytics)

	local registered: { [string]: any } = {}
	local pushes: { any } = {}
	local net: any = {}
	function net.register(_self: any, action: any): ()
		registered[action.name] = action
	end
	function net.fireClient(_self: any, player: any, channel: string, payload: any): ()
		table.insert(pushes, { player = player, channel = channel, payload = payload })
	end

	local startContext: any = {
		clock = clock,
		data = data,
		net = net,
		economy = economy,
		analytics = analytics,
	}
	SalvageService:Start(startContext) -- installs startContext.salvage
	ResurfaceService:Start(startContext)

	-- The REAL inbound pipeline (Net.dispatch + the real Gate over the same clock), so the
	-- validation / rate / ownership cases run the wire a client actually reaches.
	local wire = Mocks.net({
		clock = clock,
		data = data,
		economy = economy,
		analytics = analytics,
		salvage = startContext.salvage,
	})
	wire.register(ResurfaceService:resurfaceAction())
	wire.register(ResurfaceService:fetchAction())

	local h: any = {
		clock = clock,
		store = store,
		storeOptions = storeOptions,
		data = data,
		economy = economy,
		analytics = analytics,
		seam = startContext.salvage,
		registered = registered,
		pushes = pushes,
		startContext = startContext,
		wire = wire,
	}

	function h.setYield(self: any, on: boolean): ()
		self.storeOptions.yieldOnUpdate = on
	end

	-- The ActionContext a direct resurface/fetch call receives. `overrides` swaps one seam without
	-- rebuilding the world.
	function h.ctx(self: any, player: any, overrides: any?): any
		local o: any = overrides or {}
		return {
			player = player,
			clock = if o.clock ~= nil then o.clock else self.clock,
			data = if o.data ~= nil then o.data else self.data,
			economy = if o.noEconomy == true
				then nil
				else (if o.economy ~= nil then o.economy else self.economy),
			salvage = if o.noSalvage == true
				then nil
				else (if o.salvage ~= nil then o.salvage else self.seam),
			analytics = if o.noAnalytics == true
				then nil
				else (if o.analytics ~= nil then o.analytics else self.analytics),
		}
	end

	function h.join(self: any, userId: number): any
		local player = Mocks.player(userId)
		expect(self.data:loadSession(player)):toBeOk()
		return player
	end

	function h.leave(self: any, player: any): ()
		self.data:onPlayerRemoving(player)
	end

	function h.blob(self: any, player: any): any
		local got = self.data:get(player)
		expect(got):toBeOk()
		return (got :: any).value
	end

	function h.snapshot(self: any, player: any): any
		return deepCopy(self:blob(player))
	end

	-- Seed persisted state THROUGH the data layer (never by poking the live table), so every case
	-- starts from a blob the game could actually have written.
	function h.write(self: any, player: any, mutate: (any) -> ()): ()
		local written = self.data:update(player, function(d: any): any
			mutate(d)
			return d
		end)
		expect(written):toBeOk()
	end

	function h.resurface(self: any, player: any, overrides: any?): any
		return ResurfaceService:resurface(self:ctx(player, overrides))
	end

	function h.preview(self: any, player: any, overrides: any?): any
		local got = ResurfaceService:fetch(self:ctx(player, overrides))
		expect(got):toBeOk()
		return (got :: any).value
	end

	function h.previewResult(self: any, player: any, overrides: any?): any
		return ResurfaceService:fetch(self:ctx(player, overrides))
	end

	-- THE OBSERVABLE THE MULTIPLIER IS GRADED AGAINST: the running income rate `salvage.fetch`
	-- reports for this player, right now, through the real SalvageService read surface.
	function h.rate(self: any, player: any): number
		local got = SalvageService:fetch(self:ctx(player))
		expect(got):toBeOk()
		return (got :: any).value.rate
	end

	function h.pearls(self: any, player: any): number
		local currencies = self:blob(player).currencies
		local value = if type(currencies) == "table" then currencies[PEARLS] else nil
		return if type(value) == "number" then value else 0
	end

	function h.credits(self: any, player: any): number
		local currencies = self:blob(player).currencies
		local value = if type(currencies) == "table" then currencies[CREDITS] else nil
		return if type(value) == "number" then value else 0
	end

	function h.level(self: any, player: any, key: string): number
		local upgrades = self:blob(player).upgrades
		local value = if type(upgrades) == "table" then upgrades[key] else nil
		return if type(value) == "number" then value else 0
	end

	function h.count(self: any, player: any): number
		local value = self:blob(player).resurfaces
		return if type(value) == "number" then value else 0
	end

	function h.lifetime(self: any, player: any): number
		local stats = self:blob(player).stats
		local value = if type(stats) == "table" then stats.lifetimeCredits else nil
		return if type(value) == "number" then value else 0
	end

	function h.eventCount(self: any, name: string): number
		return #self.analytics:eventsOfType(name)
	end

	function h.lastEvent(self: any, name: string): any
		local events = self.analytics:eventsOfType(name)
		return events[#events]
	end

	-- Put this player at a depth tier without going through the Depth slice (not this feature's
	-- concern — the slice only RESETS the key).
	function h.setTier(self: any, player: any, tier: any): ()
		self:write(player, function(d: any): ()
			d.upgrades[DEPTH_KEY] = tier
		end)
	end

	return h
end

-- A full, RICHLY POPULATED end-of-run blob: every survive-list field carries a distinctive value, so
-- a build that clears one is caught by the value it landed on and not merely by a nil check.
local function seedRun(h: any, player: any, overrides: any?): ()
	local o: any = overrides or {}
	h:write(player, function(d: any): ()
		d.currencies[CREDITS] = if o.credits ~= nil then o.credits else 12_345
		d.currencies[PEARLS] = if o.pearls ~= nil then o.pearls else 137
		d.stats.lifetimeCredits = if o.lifetime ~= nil then o.lifetime else 600_000
		d.stats.joinCount = 9
		d.stats.playtimeSeconds = 4_321
		d.upgrades.drones = 7
		d.upgrades.conveyor = 4
		d.upgrades.smelter = 3
		d.upgrades.hull = 5
		d.upgrades[SURVIVING_UPGRADE_KEY] = 2
		d.upgrades[DEPTH_KEY] = if o.tier ~= nil then o.tier else 5
		d.smelter.storedCredits = 900
		d.smelter.lastTickUnix = START_UNIX - 30
		d.daily.streak = 6
		d.daily.lastClaimUnix = START_UNIX - 100_000
		d.plot.plotId = "dome-3"
		d.plot.claimedAtUnix = START_UNIX - 5_000
		d.flags["gamepass.autoCollect"] = true
		d.receipts["receipt-abc"] = START_UNIX - 77
		d.boostExpiresUnix = if o.boostExpires ~= nil then o.boostExpires else 0
		d.timestamps.firstJoinUnix = START_UNIX - 999
		d.timestamps.lastSeenUnix = START_UNIX - 12
	end)
end

-- THE MINIMUM DEPTH TIER, discovered through the server-truthed preview rather than restated from the
-- module: the confirm UI reads `minDepthTier` off exactly this reply, so if it is wrong the player is
-- told the wrong thing too.
local function discoverMinTier(): number
	local h = newServer()
	local player = h:join(1)
	local tier = h:preview(player).minDepthTier
	expectTrue(
		type(tier) == "number" and tier >= 1,
		`the preview must publish a numeric minimum depth tier, got {tostring(tier)}`
	)
	return tier
end

local MIN_TIER = discoverMinTier()

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 1. THE WIRE SURFACE — §3: validate type + range + ownership + rate on EVERY inbound request
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — the wire surface (CLAUDE.md §3)", function()
	it("both actions are registered on the gateway, each with a real rate policy", function()
		local h = newServer()
		for _, name in { Net.Actions.Resurface, Net.Actions.FetchResurface } do
			local action = h.registered[name]
			expectTrue(action ~= nil, `action "{name}" was never registered on the gateway`)
			expectTrue(type(action.validate) == "function", `"{name}" has no validator`)
			expectTrue(type(action.handler) == "function", `"{name}" has no handler`)
			expectTrue(type(action.rate) == "table", `"{name}" declares no rate policy`)
			expectTrue(
				type(action.rate.maxPerWindow) == "number" and action.rate.maxPerWindow >= 1,
				`"{name}" has a nonsensical maxPerWindow`
			)
			expectTrue(
				type(action.rate.windowSeconds) == "number" and action.rate.windowSeconds > 0,
				`"{name}" has a nonsensical windowSeconds`
			)
		end
	end)

	it("an empty payload is accepted — the SERVER derives everything", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h.wire.invoke(Net.Actions.Resurface, player, nil)):toBeOk()
		expect(h:count(player)):toBe(1)
	end)

	it("a NON-TABLE payload is refused and nothing is minted or wiped", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local before = h:snapshot(player)
		for _, bogus in { "resurface me", 42, true } do
			-- The Gate runs BEFORE the validator (it is the cheaper refusal), and this action's
			-- bucket is deliberately tiny — so the probe pays for its own window each time rather
			-- than reading a RateLimited as if it were a validation verdict.
			h.clock:advance(h.registered[Net.Actions.Resurface].rate.windowSeconds)
			local result = h.wire.invoke(Net.Actions.Resurface, player, bogus)
			expect(result):toBeErr()
			local code = (result :: any).code
			expectTrue(
				code == Result.Codes.BadType or code == Result.Codes.BadPayload,
				`a {type(bogus)} payload must be refused as BadType/BadPayload, got {tostring(code)}`
			)
		end
		expect(changedPaths(before, h:snapshot(player))):toEqual({})
	end)

	it("a payload that names its OWN Pearl amount is REFUSED (BadPayload), never obeyed", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local before = h:snapshot(player)
		-- The forged-mint probe: a client asserting the payout it wants.
		for _, forged in
			{
				{ pearls = 1_000_000_000 },
				{ amount = 99_999 },
				{ multiplier = 1_000 },
				{ resurfaces = 500 },
				{ tier = 6 },
				{ lifetimeCredits = 1e18 },
			}
		do
			-- Same reason as the non-table probe: refill the tiny bucket so each probe is answered
			-- by the VALIDATOR and not by the Gate.
			h.clock:advance(h.registered[Net.Actions.Resurface].rate.windowSeconds)
			expect(h.wire.invoke(Net.Actions.Resurface, player, forged)):toBeErr(
				Result.Codes.BadPayload
			)
		end
		-- THE ECONOMIC INVARIANT, independent of the code: no forged number reached the balance.
		expect(changedPaths(before, h:snapshot(player))):toEqual({})
		expect(h:pearls(player)):toBe(137)
	end)

	it("the FETCH refuses the same forged payloads rather than previewing them", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h.wire.invoke(Net.Actions.FetchResurface, player, { pearls = 1e9 })):toBeErr(
			Result.Codes.BadPayload
		)
		expect(h.wire.invoke(Net.Actions.FetchResurface, player, nil)):toBeOk()
	end)

	it("OWNERSHIP: one player's resurface never touches another player's record", function()
		local h = newServer()
		local mine = h:join(1)
		local theirs = h:join(2)
		seedRun(h, mine)
		seedRun(h, theirs)
		local theirsBefore = h:snapshot(theirs)

		-- A payload naming the OTHER player is refused outright...
		expect(h.wire.invoke(Net.Actions.Resurface, mine, { userId = 2 })):toBeErr(
			Result.Codes.BadPayload
		)
		-- ...and a perfectly legitimate resurface still only ever writes the CALLER's blob.
		expect(h.wire.invoke(Net.Actions.Resurface, mine, nil)):toBeOk()

		expect(changedPaths(theirsBefore, h:snapshot(theirs))):toEqual({})
		expect(h:count(theirs)):toBe(0)
		expect(h:count(mine)):toBe(1)
	end)

	it("RATE: the declared bucket refuses the burst, and refills on the SERVER clock", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local policy = h.registered[Net.Actions.Resurface].rate

		-- Drain exactly the declared bucket. The FIRST call resurfaces; the rest are refused by the
		-- HANDLER (the wipe reset the depth), which is a different refusal from the Gate's.
		for _ = 1, policy.maxPerWindow do
			local result = h.wire.invoke(Net.Actions.Resurface, player, nil)
			expectTrue(
				(result :: any).ok == true or (result :: any).code ~= Result.Codes.RateLimited,
				"the Gate refused a call INSIDE the declared bucket"
			)
		end
		-- One past the bucket: RateLimited, and distinguishably NOT the handler's PrereqUnmet.
		expect(h.wire.invoke(Net.Actions.Resurface, player, nil)):toBeErr(Result.Codes.RateLimited)
		-- A rate-limited call must never have reached the economy.
		expect(h:count(player)):toBe(1)

		-- The window is measured on the SERVER clock (§7): advancing it refills the bucket, and the
		-- next call gets the HANDLER's refusal, not the Gate's.
		h.clock:advance(policy.windowSeconds * 2)
		expect(h.wire.invoke(Net.Actions.Resurface, player, nil)):toBeErr(Result.Codes.PrereqUnmet)
	end)

	it("RATE: the preview action has its own bucket and it is enforced too", function()
		local h = newServer()
		local player = h:join(1)
		local policy = h.registered[Net.Actions.FetchResurface].rate
		for _ = 1, policy.maxPerWindow do
			expect(h.wire.invoke(Net.Actions.FetchResurface, player, nil)):toBeOk()
		end
		expect(h.wire.invoke(Net.Actions.FetchResurface, player, nil)):toBeErr(
			Result.Codes.RateLimited
		)
		h.clock:advance(policy.windowSeconds * 2)
		expect(h.wire.invoke(Net.Actions.FetchResurface, player, nil)):toBeOk()
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 2. THE MINIMUM DEPTH REQUIREMENT — "Err(PrereqUnmet) below it"
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — the minimum depth requirement", function()
	it(
		"the requirement is the bottom of the five-tier trench (spec: '5 depth tiers, then resurface')",
		function()
			expect(MIN_TIER):toBe(5)
		end
	)

	it("BELOW the minimum: Err(PrereqUnmet), and the blob is byte-identical", function()
		for tier = 1, MIN_TIER - 1 do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { tier = tier })
			local before = h:snapshot(player)
			expect(h:resurface(player)):toBeErr(Result.Codes.PrereqUnmet)
			-- NOT a partial wipe, NOT a partial mint: nothing at all moved.
			expect(changedPaths(before, h:snapshot(player))):toEqual({})
			expect(h:count(player)):toBe(0)
		end
	end)

	it("PrereqUnmet is NOT Insufficient — a rich player at tier 1 is still refused", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { tier = 1, credits = 10_000_000, lifetime = 10_000_000 })
		expect(h:resurface(player)):toBeErr(Result.Codes.PrereqUnmet)
	end)

	it("AT and ABOVE the minimum: the resurface is granted", function()
		for _, tier in { MIN_TIER, MIN_TIER + 1 } do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { tier = tier })
			expect(h:resurface(player)):toBeOk()
			expect(h:count(player)):toBe(1)
		end
	end)

	it("a GARBAGE or OUT-OF-RANGE depth value never clears the requirement", function()
		-- Degrading UP would let a corrupted or rolled-back record mint Pearls it never earned.
		local bogusTiers: { any } = { 99, 1e308, -3, 0, "5", true, {}, 0 / 0 }
		for _, tier in bogusTiers do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { tier = 1 })
			h:setTier(player, tier)
			expect(h:resurface(player)):toBeErr(Result.Codes.PrereqUnmet)
			expect(h:count(player)):toBe(0)
			expect(h:pearls(player)):toBe(137)
		end
	end)

	it("a SECOND resurface is refused until the ladder has been re-descended", function()
		-- The wipe put upgrades.depth back to 1, so the requirement is genuinely re-armed. This is
		-- the same guarantee the concurrency cases lean on, asserted sequentially first.
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h:resurface(player)):toBeOk()
		local afterFirst = h:snapshot(player)
		expect(h:resurface(player)):toBeErr(Result.Codes.PrereqUnmet)
		expect(changedPaths(afterFirst, h:snapshot(player))):toEqual({})
		expect(h:count(player)):toBe(1)

		-- Re-descend, and it is available again.
		h:setTier(player, MIN_TIER)
		expect(h:resurface(player)):toBeOk()
		expect(h:count(player)):toBe(2)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 3. THE WIPE — everything the slice says the one transform clears
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — the wipe", function()
	it(
		"Credits, the four structure levels, the depth tier and the stored output all clear",
		function()
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player)
			expect(h:resurface(player)):toBeOk()

			expect(h:credits(player)):toBe(0)
			for _, key in WIPED_UPGRADE_KEYS do
				expect(h:level(player, key)):toBe(0)
			end
			-- "reset upgrades.depth to 1" — the literal 1, not 0 and not absent.
			expect(h:blob(player).upgrades[DEPTH_KEY]):toBe(1)
			expect(h:blob(player).smelter.storedCredits):toBe(0)
		end
	)

	it("`resurfaces` is INCREMENTED, never reset — three runs count to three", function()
		local h = newServer()
		local player = h:join(1)
		for expected = 1, 3 do
			seedRun(h, player, { tier = MIN_TIER })
			expect(h:resurface(player)):toBeOk()
			expect(h:count(player)):toBe(expected)
		end
	end)

	it(
		"the wipe is reported honestly: creditsCleared / storedCleared match what was there",
		function()
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { credits = 4_242 })
			local info = (h:resurface(player) :: any).value
			expect(info.creditsCleared):toBe(4_242)
			expect(info.storedCleared):toBe(900)
			expect(info.depthTier):toBe(MIN_TIER)
		end
	)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 4. THE SURVIVE LIST — the thing the slice says this feature is most likely to get silently wrong
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — WHAT SURVIVES (the whole-blob diff)", function()
	it("NOTHING outside the slice's wipe list is written", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { boostExpires = START_UNIX + 1_800 })
		local before = h:snapshot(player)
		expect(h:resurface(player)):toBeOk()

		local changed = changedPaths(before, h:snapshot(player))
		local illegal: { string } = {}
		for _, path in changed do
			if not ALLOWED_CHANGE_PATHS[path] then
				table.insert(illegal, path)
			end
		end
		expectTrue(
			#illegal == 0,
			"a resurface wrote fields the slice says SURVIVE untouched: "
				.. table.concat(illegal, ", ")
		)
		-- ...and it really did do the work (an implementation that changed NOTHING would also have
		-- an empty illegal list).
		expectTrue(#changed >= 5, `a resurface changed only {#changed} leaves — it did not run`)
	end)

	it("every named survivor keeps its exact value", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { boostExpires = START_UNIX + 1_800 })
		local before = h:snapshot(player)
		expect(h:resurface(player)):toBeOk()
		local after = h:blob(player)

		-- upgrades.pearlDrones — "Pearl purchases are permanent".
		expect(after.upgrades[SURVIVING_UPGRADE_KEY]):toBe(before.upgrades[SURVIVING_UPGRADE_KEY])
		-- stats.lifetimeCredits — the leaderboard's ranking key.
		expect(after.stats.lifetimeCredits):toBe(before.stats.lifetimeCredits)
		expect(after.stats.joinCount):toBe(before.stats.joinCount)
		expect(after.stats.playtimeSeconds):toBe(before.stats.playtimeSeconds)
		-- daily · plot · flags · receipts, whole records.
		expect(after.daily):toEqual(before.daily)
		expect(after.plot):toEqual(before.plot)
		expect(after.flags):toEqual(before.flags)
		expect(after.receipts):toEqual(before.receipts)
		-- AMENDMENT A6 — paid time is not confiscated by a voluntary prestige.
		expect(after.boostExpiresUnix):toBe(before.boostExpiresUnix)
		-- The accrual base is NOT on the wipe list either: moving it would re-credit or skip a span.
		expect(after.smelter.lastTickUnix):toBe(before.smelter.lastTickUnix)
		expect(after.timestamps):toEqual(before.timestamps)
		expect(after.schemaVersion):toBe(before.schemaVersion)
	end)

	it(
		"AMENDMENT A6: a LIVE paid 2x boost survives AND is still worth 2x after the prestige",
		function()
			-- The survive-list check above proves the FIELD is intact. This proves the paid time is
			-- still doing what the player bought it for: the post-resurface rate is exactly double
			-- the rate the same blob reports once the boost has expired.
			local h = newServer()
			local player = h:join(1)
			local expiry = START_UNIX + 1_800
			seedRun(h, player, { boostExpires = expiry })
			expect(h:resurface(player)):toBeOk()
			expect(h:blob(player).boostExpiresUnix):toBe(expiry)

			local boosted = h:rate(player)
			h.clock:advance(3_600) -- the paid window closes; nothing else about the blob changes
			local plain = h:rate(player)
			expectTrue(plain > 0, "the post-resurface rate must be positive")
			expectClose(boosted, plain * 2, "a surviving live boost must still double the rate")
		end
	)

	it("the Pearl mint ADDS to an existing balance, it never replaces it", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { pearls = 137 })
		local minted = h:preview(player).pearls
		expectTrue(minted > 0, "the preview must promise a positive Pearl mint at the requirement")
		expect(h:resurface(player)):toBeOk()
		expect(h:pearls(player)):toBe(137 + minted)
	end)

	it("stats.lifetimeCredits is neither reset NOR incremented by the Pearl mint", function()
		-- Both halves matter: resetting it ranks prestiged players last on the leaderboard, and
		-- incrementing it would count Pearls as Credits in the ranking key.
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { lifetime = 750_000 })
		expect(h:resurface(player)):toBeOk()
		expect(h:lifetime(player)):toBe(750_000)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 5. THE MINT GOES THROUGH ctx.economy — the single writer for every balance in this game
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — the Pearl mint", function()
	it("currency_earned fires ONCE for Pearls, and no Credits are earned", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local minted = h:preview(player).pearls
		expect(h:resurface(player)):toBeOk()

		local earns = h.analytics:eventsOfType("currency_earned")
		local pearlEarns = 0
		for _, event in earns do
			if event.payload.currency == PEARLS then
				pearlEarns += 1
				expect(event.payload.amount):toBe(minted)
				expect(event.payload.balance):toBe(137 + minted)
			end
			expectTrue(
				event.payload.currency ~= CREDITS,
				"a resurface must never emit a Credits earn — the reset is a RESET, not an earn"
			)
		end
		expect(pearlEarns):toBe(1)
	end)

	it("the reply's pearlBalance is the balance ctx.economy actually computed", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { pearls = 40 })
		local info = (h:resurface(player) :: any).value
		expect(info.pearlBalance):toBe(h:pearls(player))
		expect(info.pearlBalance):toBe(40 + info.pearls)
	end)

	it(
		"with NO ctx.economy the resurface REFUSES rather than writing the balance itself",
		function()
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player)
			local before = h:snapshot(player)
			expect(h:resurface(player, { noEconomy = true })):toBeErr()
			-- No mint AND no wipe: an unaudited direct write is exactly what the seam exists to prevent.
			expect(changedPaths(before, h:snapshot(player))):toEqual({})
			expect(h:pearls(player)):toBe(137)
		end
	)

	it(
		"a REFUSED mint rolls the whole wipe back — never a destroyed run with nothing paid",
		function()
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player)
			local before = h:snapshot(player)
			local refusing: any = {}
			function refusing.earn(
				_self: any,
				_data: any,
				_currency: any,
				_amount: any,
				_source: any
			): any
				return Result.err(Result.Codes.Internal, "the mint is on fire")
			end
			expect(h:resurface(player, { economy = refusing })):toBeErr()
			expect(changedPaths(before, h:snapshot(player))):toEqual({})
		end
	)

	it(
		"a REFUSED mint restores an ABSENT structure level as ABSENT, not as the 0 the wipe invented",
		function()
			-- THE ROLLBACK IS DOCUMENTED AS BYTE-FOR-BYTE, "including absent keys". Every other
			-- rollback case seeds all four structure levels explicitly, so none of them can see the
			-- one shape where that claim is testable: a blob that reached the depth requirement
			-- WITHOUT ever holding one of the four Credits-bought keys (an untouched structure is
			-- absent, not 0 — every server reader normalizes absence to 0, so nothing ever writes it).
			-- The wipe sets those keys to 0; if the undo cannot visit a key it captured as nil, the
			-- wipe's 0 SURVIVES a refused mint and the record is not the one the transform found.
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player)
			h:write(player, function(d: any): ()
				d.upgrades.drones = nil
				d.upgrades.conveyor = nil
			end)
			local before = h:snapshot(player)
			expectTrue(
				before.upgrades.drones == nil and before.upgrades.conveyor == nil,
				"setup: both structure levels must be ABSENT before the refused resurface"
			)
			expectTrue(
				before.upgrades[DEPTH_KEY] == 5,
				"setup: the blob must still stand at the depth requirement"
			)

			local refusing: any = {}
			function refusing.earn(
				_self: any,
				_data: any,
				_currency: any,
				_amount: any,
				_source: any
			): any
				return Result.err(Result.Codes.Internal, "the mint is on fire")
			end
			expect(h:resurface(player, { economy = refusing })):toBeErr()

			local after = h:snapshot(player)
			expect(changedPaths(before, after)):toEqual({})
			expectTrue(
				after.upgrades.drones == nil,
				`a rolled-back wipe must leave upgrades.drones ABSENT, got {tostring(
					after.upgrades.drones
				)}`
			)
			expectTrue(
				after.upgrades.conveyor == nil,
				`a rolled-back wipe must leave upgrades.conveyor ABSENT, got {tostring(
					after.upgrades.conveyor
				)}`
			)
			expectTrue(
				after.upgrades[DEPTH_KEY] == 5,
				`a rolled-back wipe must leave the depth tier at 5, got {tostring(
					after.upgrades[DEPTH_KEY]
				)}`
			)
		end
	)

	it(
		"a resurface at the requirement ALWAYS mints at least one Pearl, even at zero progress",
		function()
			-- ctx.economy:earn refuses a non-positive amount, so a formula that could compute 0 would make
			-- the whole action permanently unavailable for that player. The requirement is the gate; a
			-- resurface it allows must not then fail on arithmetic.
			for _, lifetime in { 0, 1, 999 } do
				local h = newServer()
				local player = h:join(1)
				seedRun(h, player, { lifetime = lifetime, pearls = 0 })
				local result = h:resurface(player)
				expect(result):toBeOk()
				expectTrue(
					(result :: any).value.pearls >= 1,
					`lifetime {lifetime}: a granted resurface must mint at least one Pearl`
				)
				expect(h:pearls(player)):toBe((result :: any).value.pearls)
			end
		end
	)

	it("MONOTONE: more progress is never worth fewer Pearls", function()
		local previous = -1
		for _, lifetime in { 0, 1_000, 50_000, 600_000, 5_000_000, 900_000_000 } do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { lifetime = lifetime })
			local pearls = h:preview(player).pearls
			expectFinite(pearls, `lifetime {lifetime}: the Pearl preview`)
			expectTrue(
				pearls >= previous,
				`lifetime {lifetime} minted {pearls}, less than the previous rung's {previous}`
			)
			previous = pearls
		end
	end)

	it("OVERFLOW: a poisoned lifetimeCredits cannot mint an infinite or NaN balance", function()
		-- A number read off a DataStore is data, not a fact.
		for _, lifetime in { 1e308, math.huge, -1, 0 / 0 } do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { lifetime = lifetime, pearls = 0 })
			local result = h:resurface(player)
			if (result :: any).ok then
				local balance = h:pearls(player)
				expectFinite(balance, `lifetime {tostring(lifetime)}: the Pearl balance`)
				expectTrue(
					balance > 0,
					`lifetime {tostring(lifetime)}: a granted mint must be positive`
				)
			else
				-- A refusal is acceptable; a HALF-APPLIED refusal is not.
				expect(h:pearls(player)):toBe(0)
			end
		end
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 6. THE PERMANENT MULTIPLIER — "not allowed to ship inert"
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- Force a blob into the exact post-wipe shape, so two players differ in NOTHING but `resurfaces`.
local function normalizeToPostWipe(h: any, player: any): ()
	h:write(player, function(d: any): ()
		d.currencies[CREDITS] = 0
		for _, key in WIPED_UPGRADE_KEYS do
			d.upgrades[key] = 0
		end
		d.upgrades[DEPTH_KEY] = 1
		d.upgrades[SURVIVING_UPGRADE_KEY] = 0
		d.smelter.storedCredits = 0
		d.boostExpiresUnix = 0
		d.flags = {}
	end)
end

describe("resurface — the permanent multiplier, measured through salvage.fetch", function()
	it(
		"a resurfaced player's running rate is STRICTLY HIGHER than an identical un-resurfaced one",
		function()
			local h = newServer()
			local prestiged = h:join(1)
			local control = h:join(2)
			seedRun(h, prestiged)
			expect(h:resurface(prestiged)):toBeOk()

			-- Make the control byte-identical in every rate input except the prestige count.
			normalizeToPostWipe(h, prestiged)
			normalizeToPostWipe(h, control)
			expect(h:count(prestiged)):toBe(1)
			expect(h:count(control)):toBe(0)

			local prestigedRate = h:rate(prestiged)
			local controlRate = h:rate(control)
			expectTrue(
				controlRate > 0,
				"the baseline rate must be positive or the delta is vacuous"
			)
			expectTrue(
				prestigedRate > controlRate,
				`the permanent multiplier shipped INERT: resurfaced rate {prestigedRate} is not `
					.. `above the un-resurfaced {controlRate}`
			)
		end
	)

	it("the rate keeps climbing with the COUNT — 0 < 1 < 2 < 3 resurfaces", function()
		local h = newServer()
		local player = h:join(1)
		normalizeToPostWipe(h, player)
		local rates: { number } = { h:rate(player) }
		for _ = 1, 3 do
			h:setTier(player, MIN_TIER)
			expect(h:resurface(player)):toBeOk()
			normalizeToPostWipe(h, player) -- strip everything the run changed except the count
			table.insert(rates, h:rate(player))
		end
		for index = 2, #rates do
			expectTrue(
				rates[index] > rates[index - 1],
				`the multiplier stopped moving at {index - 1} resurfaces: `
					.. `{rates[index]} is not above {rates[index - 1]}`
			)
		end
	end)

	it(
		"the multiplier is the COUNT, not the Pearl BALANCE — spending Pearls never shrinks it",
		function()
			-- If a build derived the multiplier from currencies.Pearls, prestige would get WORSE the
			-- moment the player spent what they earned. That is the defect this case exists for.
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player)
			expect(h:resurface(player)):toBeOk()
			normalizeToPostWipe(h, player)
			local before = h:rate(player)

			local balance = h:pearls(player)
			expectTrue(balance > 0, "the resurface must have left Pearls to spend")
			h:write(player, function(d: any): ()
				d.currencies[PEARLS] = 0
			end)
			expectClose(
				h:rate(player),
				before,
				"spending Pearls must not move the permanent multiplier"
			)
		end
	)

	it("the prestige gain is PERMANENT: it survives a save, a leave and a rejoin", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h:resurface(player)):toBeOk()
		normalizeToPostWipe(h, player)
		local liveRate = h:rate(player)
		local liveCount = h:count(player)
		local livePearls = h:pearls(player)

		h:leave(player)
		local rejoined = h:join(1)

		-- "count persisted" — verbatim from the feature line.
		expect(h:count(rejoined)):toBe(liveCount)
		expect(h:pearls(rejoined)):toBe(livePearls)
		expectClose(
			h:rate(rejoined),
			liveRate,
			"the permanent multiplier did not survive the reload"
		)

		local fresh = h:join(2)
		normalizeToPostWipe(h, fresh)
		expectTrue(
			h:rate(rejoined) > h:rate(fresh),
			"a reloaded prestiged record must still out-earn a fresh one"
		)
	end)

	it("the reply MEASURES the multiplier rather than restating it, and it went UP", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local info = (h:resurface(player) :: any).value
		expectTrue(
			info.multiplierMeasured == true,
			"the reply must report the multiplier as MEASURED when ctx.salvage is wired"
		)
		expectFinite(info.multiplier, "the post-resurface multiplier")
		expectFinite(info.previousMultiplier, "the pre-resurface multiplier")
		expectTrue(
			info.multiplier > info.previousMultiplier,
			`the permanent multiplier did not rise: {info.multiplier} vs {info.previousMultiplier}`
		)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 7. THE SERVER-TRUTHED PREVIEW — "so the confirm UI is server-truthed and never guesses"
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — the preview (resurface.fetch)", function()
	it("the previewed Pearl number is EXACTLY what the resurface mints", function()
		for _, lifetime in { 0, 25_000, 600_000, 12_000_000 } do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { lifetime = lifetime, pearls = 0 })
			local promised = h:preview(player).pearls
			local info = (h:resurface(player) :: any).value
			expect(info.pearls):toBe(promised)
			expect(h:pearls(player)):toBe(promised)
		end
	end)

	it("depthMet / canResurface track the requirement across the whole ladder", function()
		for tier = 1, MIN_TIER + 1 do
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { tier = tier })
			local preview = h:preview(player)
			expect(preview.depthTier):toBe(tier)
			expect(preview.minDepthTier):toBe(MIN_TIER)
			expect(preview.depthMet):toBe(tier >= MIN_TIER)
			expect(preview.canResurface):toBe(tier >= MIN_TIER)
			-- ...and the preview's verdict agrees with what the action actually does.
			local granted = (h:resurface(player) :: any).ok == true
			expect(granted):toBe(tier >= MIN_TIER)
		end
	end)

	it("the previewed NEXT multiplier is the multiplier the player lands on", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local before = h:preview(player)
		expectTrue(before.multiplierMeasured == true, "the preview must measure the multiplier")
		expectTrue(
			before.nextMultiplier > before.multiplier,
			`the preview promises no gain: {before.nextMultiplier} vs {before.multiplier}`
		)
		expect(h:resurface(player)):toBeOk()
		expectClose(
			h:preview(player).multiplier,
			before.nextMultiplier,
			"the preview promised a multiplier the resurface did not deliver"
		)
	end)

	it("the previewed post-resurface RATE is the rate the player actually lands on", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local preview = h:preview(player)
		expectTrue(preview.rateMeasured == true, "the preview must measure the rate")
		expectClose(preview.rateNow, h:rate(player), "rateNow disagreed with salvage.fetch")
		expect(h:resurface(player)):toBeOk()
		expectClose(
			h:rate(player),
			preview.rateAfter,
			"the confirm dialog promised a post-resurface rate the player did not land on"
		)
	end)

	it("the preview states the COST as well as the prize", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { credits = 8_888 })
		local preview = h:preview(player)
		expect(preview.credits):toBe(8_888)
		expect(preview.storedCredits):toBe(900)
		expect(preview.resurfaces):toBe(0)
		expect(preview.nextResurfaces):toBe(1)
		expect(preview.pearlBalance):toBe(137)
		expect(preview.lifetimeCredits):toBe(600_000)
		expect(preview.pearlDrones):toBe(2)
	end)

	it("the preview is STRICTLY side-effect free — even called twenty times", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local before = h:snapshot(player)
		local eventsBefore = #h.analytics:events()
		for _ = 1, 20 do
			expect(h:previewResult(player)):toBeOk()
		end
		expect(changedPaths(before, h:snapshot(player))):toEqual({})
		expect(#h.analytics:events()):toBe(eventsBefore)
		expect(h:count(player)):toBe(0)
		expect(h:pearls(player)):toBe(137)
	end)

	it("the preview REFUSES before the session is loaded rather than guessing", function()
		local h = newServer()
		local stranger = Mocks.player(99) -- never loadSession'd
		expect(ResurfaceService:fetch(h:ctx(stranger))):toBeErr(Result.Codes.NoData)
	end)

	it("the preview answers honestly when ctx.salvage is not wired (measured = false)", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local preview = h:preview(player, { noSalvage = true })
		expectTrue(
			preview.multiplierMeasured == false,
			"an unmeasurable multiplier must SAY so, not report a silent neutral 1x"
		)
		-- The rest of the preview is still truthful.
		expect(preview.depthMet):toBe(true)
		expectTrue(preview.pearls >= 1, "the Pearl preview does not depend on the salvage seam")
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 8. CONCURRENCY — "two resurface.do calls in the same frame must mint exactly one batch of Pearls"
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — concurrency (CLAUDE.md §4)", function()
	it("TWO interleaved resurfaces mint EXACTLY ONE batch of Pearls", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { pearls = 0 })
		local promised = h:preview(player).pearls
		local witness = inFlightCounter()

		h:setYield(true)
		local results: { any } = {}
		local cos = {
			coroutine.create(function()
				results[1] = witness:wrap(function(): any
					return h.wire.invoke(Net.Actions.Resurface, player, nil)
				end)
			end),
			coroutine.create(function()
				results[2] = witness:wrap(function(): any
					return h.wire.invoke(Net.Actions.Resurface, player, nil)
				end)
			end),
		}
		drain(cos)
		h:setYield(false)

		-- THE INTERLEAVE IS REAL: the second request entered while the first was parked in the store.
		expect(witness.peak):toBe(2)

		local granted = 0
		for _, result in results do
			if (result :: any).ok == true then
				granted += 1
			end
		end
		expect(granted):toBe(1)
		expect(h:count(player)):toBe(1)
		expect(h:pearls(player)):toBe(promised)
		expect(h:credits(player)):toBe(0)
		expect(h.analytics:eventsOfType("progression")):toEqual(
			{ h:lastEvent("progression") } :: any
		)
	end)

	it("FOUR spam-duplicated resurfaces still mint exactly one batch", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { pearls = 0 })
		local promised = h:preview(player).pearls
		local witness = inFlightCounter()

		h:setYield(true)
		local results: { any } = {}
		local cos: { thread } = {}
		for index = 1, 4 do
			table.insert(
				cos,
				coroutine.create(function()
					results[index] = witness:wrap(function(): any
						return h:resurface(player)
					end)
				end)
			)
		end
		drain(cos)
		h:setYield(false)

		expectTrue(witness.peak >= 2, "the spam burst never actually interleaved")
		local granted = 0
		for _, result in results do
			if (result :: any).ok == true then
				granted += 1
			end
		end
		expect(granted):toBe(1)
		expect(h:count(player)):toBe(1)
		expect(h:pearls(player)):toBe(promised)
	end)

	it(
		"the LOCK-HELD TRANSFORM alone holds the line — a race that defeats any in-memory memo",
		function()
			-- The slice's guarantee is about the transform: "the requirement check, the mint and the
			-- wipe all happen in the same lock-held transform". A per-server memo is belt-and-braces
			-- and says nothing about the same player on another server, so this case drives two
			-- SEPARATE service instances at the same data layer and still demands one batch.
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { pearls = 0 })
			local promised = h:preview(player).pearls
			local first = separateInstance()
			local second = separateInstance()
			local witness = inFlightCounter()

			h:setYield(true)
			local results: { any } = {}
			local cos = {
				coroutine.create(function()
					results[1] = witness:wrap(function(): any
						return first:resurface(h:ctx(player))
					end)
				end),
				coroutine.create(function()
					results[2] = witness:wrap(function(): any
						return second:resurface(h:ctx(player))
					end)
				end),
			}
			drain(cos)
			h:setYield(false)

			expect(witness.peak):toBe(2)
			local granted = 0
			for _, result in results do
				if (result :: any).ok == true then
					granted += 1
				end
			end
			expect(granted):toBe(1)
			expect(h:count(player)):toBe(1)
			expect(h:pearls(player)):toBe(promised)
		end
	)

	it("a resurface interleaved with a Credits earn never loses or duplicates either", function()
		-- The shared-balance case from the success criteria: the wipe and an unrelated earn racing on
		-- the same record. Both orderings are legal; what is NOT legal is a lost earn, a double mint,
		-- or a Credits balance that reflects a write nobody made.
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { pearls = 0, lifetime = 600_000 })
		local promised = h:preview(player).pearls

		h:setYield(true)
		local cos = {
			coroutine.create(function()
				h:resurface(player)
			end),
			coroutine.create(function()
				h.data:update(player, function(d: any): any
					h.economy:earn(d, CREDITS, 500, "test.smelt")
					return d
				end)
			end),
		}
		drain(cos)
		h:setYield(false)

		expect(h:count(player)):toBe(1)
		expect(h:pearls(player)):toBe(promised)
		-- The Credits earn landed exactly once, on whichever side of the wipe it was ordered.
		local credits = h:credits(player)
		expectTrue(
			credits == 0 or credits == 500,
			`Credits landed at {credits}: neither the wiped 0 nor the single earn of 500`
		)
		-- lifetimeCredits counts Credits ONLY, and it counted this earn exactly once.
		expect(h:lifetime(player)):toBe(600_500)
	end)

	it(
		"FALSIFIABILITY: a naive check-outside-the-lock resurface DOES dupe at the same yield point",
		function()
			-- The counter-case that proves the cases above are meaningful rather than trivially green.
			-- This resurface reads the tier and prices the run BEFORE ctx.data:update can yield — the
			-- exact mistake the slice's "same lock-held transform" clause forbids — and is driven
			-- through the SAME store, the SAME forced yield and the SAME coroutine driver.
			local h = newServer()
			local player = h:join(1)
			seedRun(h, player, { pearls = 0 })

			local function naiveResurface(): any
				local blob = (h.data:get(player) :: any).value
				local tier = blob.upgrades[DEPTH_KEY] -- READ OUTSIDE THE TRANSFORM
				if type(tier) ~= "number" or tier < MIN_TIER then
					return Result.err(Result.Codes.PrereqUnmet, "naive: too shallow")
				end
				local pearls = 24 -- PRICED OUTSIDE THE TRANSFORM
				return h.data:update(player, function(d: any): any
					d.currencies[CREDITS] = 0
					d.upgrades[DEPTH_KEY] = 1
					d.resurfaces = (d.resurfaces or 0) + 1
					h.economy:earn(d, PEARLS, pearls, "naive")
					return d
				end)
			end

			h:setYield(true)
			local cos = {
				coroutine.create(function()
					naiveResurface()
				end),
				coroutine.create(function()
					naiveResurface()
				end),
			}
			drain(cos)
			h:setYield(false)

			-- The naive build pays TWICE for one run. If this ever landed on one batch, the driver
			-- would not be able to distinguish a correct implementation from a duping one.
			expect(h:count(player)):toBe(2)
			expect(h:pearls(player)):toBe(48)
		end
	)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 9. ANALYTICS — "Emit `progression` with the new count"
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — analytics", function()
	it("`progression` is part of the declared taxonomy", function()
		local h = newServer()
		expect(h.analytics:isKnownEvent("progression")):toBe(true)
	end)

	it("progression fires ONCE on a granted resurface, carrying the NEW count", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h:eventCount("progression")):toBe(0)
		expect(h:resurface(player)):toBeOk()
		expect(h:eventCount("progression")):toBe(1)
		local event = h:lastEvent("progression")
		expect(event.payload.resurfaces):toBe(1)
		expect(event.payload.resurfaces):toBe(h:count(player))
	end)

	it("progression NEVER fires on a refusal", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player, { tier = 1 })
		expect(h:resurface(player)):toBeErr(Result.Codes.PrereqUnmet)
		expect(h:eventCount("progression")):toBe(0)
		expect(h:eventCount("currency_earned")):toBe(0)
	end)

	it("a THROWING analytics seam never turns a committed resurface into an error", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local exploding: any = {}
		function exploding.emit(_self: any, _event: string, _payload: any): ()
			error("analytics is on fire")
		end
		expect(h:resurface(player, { analytics = exploding })):toBeOk()
		expect(h:count(player)):toBe(1)
		expect(h:credits(player)):toBe(0)
	end)

	it("an UNWIRED analytics seam is a no-op, never a refusal", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h:resurface(player, { noAnalytics = true })):toBeOk()
		expect(h:count(player)):toBe(1)
	end)
end)

-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 10. NEGATIVE / ROBUSTNESS — refusals leave the record exactly as they found it
-- ════════════════════════════════════════════════════════════════════════════════════════════════

describe("resurface — refusals and damaged records", function()
	it("a resurface before the session is loaded is Err(NoData), and mints nothing", function()
		local h = newServer()
		local stranger = Mocks.player(77) -- never loadSession'd
		expect(ResurfaceService:resurface(h:ctx(stranger))):toBeErr(Result.Codes.NoData)
		expect(h:eventCount("currency_earned")):toBe(0)
		expect(h:eventCount("progression")):toBe(0)
	end)

	it("a blob with no currencies map is refused UP FRONT, never half-wiped", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		h:write(player, function(d: any): ()
			d.currencies = nil
		end)
		local before = h:snapshot(player)
		expect(h:resurface(player)):toBeErr()
		local after = h:snapshot(player)
		-- The structures the player paid for are still there: the refusal happened before any wipe.
		expect(after.upgrades.drones):toBe(before.upgrades.drones)
		expect(after.upgrades[DEPTH_KEY]):toBe(before.upgrades[DEPTH_KEY])
		expect(after.smelter.storedCredits):toBe(before.smelter.storedCredits)
		expect(after.resurfaces):toBe(before.resurfaces)
	end)

	it("a player object with no numeric UserId is refused, not resurfaced", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		local before = h:snapshot(player)
		local ctx = h:ctx(player)
		ctx.player = { UserId = "one", Name = "spoofed" }
		expect(ResurfaceService:resurface(ctx)):toBeErr()
		expect(changedPaths(before, h:snapshot(player))):toEqual({})
	end)

	it("a resurface never leaves a NEGATIVE balance or a negative level behind", function()
		local h = newServer()
		local player = h:join(1)
		seedRun(h, player)
		expect(h:resurface(player)):toBeOk()
		local blob = h:blob(player)
		for name, value in blob.currencies do
			expectTrue(
				type(value) == "number" and value >= 0,
				`currency {name} landed negative: {tostring(value)}`
			)
		end
		for name, value in blob.upgrades do
			expectTrue(
				type(value) == "number" and value >= 0,
				`upgrade {name} landed negative: {tostring(value)}`
			)
		end
		expectTrue(blob.resurfaces >= 1, "the prestige count landed below one after a granted run")
	end)
end)
