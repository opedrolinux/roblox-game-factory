--!strict
-- games/deep-reach/tests/unit/lifecycle.spec.luau   [AMENDMENT A10b — the pinned leave order]
--
-- WHAT THIS SPEC IS FOR. A10b says the leave path must run
--     AnalyticsService session_end (still-loaded blob) -> PlotService release -> DataService release
-- and until PlayerLifecycle existed that order was ONLY a comment in src/server/init.server.luau,
-- while DataService and AnalyticsService each connected their own PlayerRemoving handler. Whichever
-- ran first won, and DataService connected first — so session_end read Err(NoData), fell back to the
-- join-time snapshot, and stamped `stale = true`. The analytics success criterion ("session_end
-- fires with the session's data") still passed, on a payload describing a session nobody played.
--
-- THE DISCRIMINATOR is deliberately not "an event fired": it is the CONTENT. The first test earns
-- 5000 Credits DURING the session, so the still-loaded blob and the join-time snapshot carry
-- different numbers, and the third test runs the release first to show exactly what the wrong order
-- produces (stale = true, the join-time value). A test that only asserted `#events == 1` would have
-- been green throughout the defect.
local testkit = require("../lib/testkit")
local Mocks = require("../lib/mocks")
local Config = require("../../src/shared/Config")
local DataService = require("../../src/server/data/DataService")
local AnalyticsService = require("../../src/server/services/analytics/AnalyticsService")
local PlayerLifecycle = require("../../src/server/framework/PlayerLifecycle")

local fs = require("@lune/fs")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- The REAL data layer over the real MockStore + the REAL emitter: the point of this spec is the
-- interaction between them, so faking either would fake the thing under test.
local function harness(): any
	local clock = Mocks.clock(1000)
	local store = Mocks.store({ clock = clock })
	local data = DataService.new(store, clock, Config, Mocks.logWarn)
	local analytics = AnalyticsService.new(clock)
	return {
		clock = clock,
		data = data,
		analytics = analytics,
		context = { clock = clock, data = data, analytics = analytics },
	}
end

-- Join a player for real: load the session and record the join-time snapshot the way
-- AnalyticsService.onPlayerAdded does.
local function join(h: any, player: any): any
	local loaded = h.data:loadSession(player)
	expect(loaded):toBeOk()
	h.analytics:sessionStart(player, (loaded :: any).value.data)
	return (loaded :: any).value.data
end

-- Read a source file from either cwd the runner is used from (the gauntlet runs the lune stage with
-- cwd = the game dir; a repo-root invocation is the fallback). Same technique as selene_guard.spec.
local function readSource(relative: string): string
	local candidates = { relative, "games/deep-reach/" .. relative, "../" .. relative }
	for _, path in candidates do
		if fs.isFile(path) then
			return fs.readFile(path)
		end
	end
	error(`lifecycle.spec: could not locate {relative} from this cwd`)
end

describe("server/framework/PlayerLifecycle (AMENDMENT A10b)", function()
	it("session_end carries the STILL-LOADED blob, not the join-time snapshot", function()
		local h = harness()
		local player = Mocks.player(1)
		join(h, player)

		-- The session actually happens: the player earns 4900 Credits and plays for two minutes.
		local updated = h.data:update(player, function(blob: any): any
			blob.currencies.Credits = 5000
			return blob
		end)
		expect(updated):toBeOk()
		h.clock:advance(120)

		PlayerLifecycle:onRemoving(h.context, player)

		local ends = h.analytics:eventsOfType("session_end")
		expect(#ends):toBe(1)
		local payload = ends[1].payload
		-- The assertions the wrong order breaks: it would report the JOIN value (0, the seed) instead
		-- of the 5000 the player earned, and flag itself stale.
		expect(payload.stale):toBe(false)
		expect(payload.credits):toBe(5000)
		expect(payload.userId):toBe(1)
		expect(payload.sessionSeconds):toBe(120)

		-- ...and the release still happened: the session is gone afterwards.
		expect(h.data:get(player)):toBeErr("NoData")
	end)

	it("runs analytics -> plot -> data release, in that exact order", function()
		local order: { string } = {}
		local blob = Mocks.playerData(1000)
		blob.currencies.Credits = 777

		local data: any = { released = false }
		function data.noteDeparture(_self: any, _player: any): () end
		function data.get(self: any, _player: any): any
			if self.released then
				return { ok = false, code = "NoData" }
			end
			return { ok = true, value = blob }
		end
		function data.onPlayerRemoving(self: any, _player: any): ()
			table.insert(order, "data")
			self.released = true
		end

		local plot: any = {}
		function plot.releaseFor(_self: any, _player: any): boolean
			table.insert(order, "plot")
			return true
		end

		local clock = Mocks.clock(1000)
		local analytics = AnalyticsService.new(clock)
		local player = Mocks.player(2)
		analytics:sessionStart(player, blob)
		-- Wrap emit so the ordering observation comes from the event itself, not from a spy that
		-- could be called somewhere the event is not.
		local realEmit = analytics.emit
		analytics.emit = function(self: any, event: string, payload: any): any
			if event == "session_end" then
				table.insert(order, "analytics")
			end
			return realEmit(self, event, payload)
		end

		PlayerLifecycle:onRemoving(
			{ clock = clock, data = data, analytics = analytics, plot = plot },
			player
		)

		expect(table.concat(order, ",")):toBe("analytics,plot,data")
		expect(analytics:eventsOfType("session_end")[1].payload.credits):toBe(777)
	end)

	it("FALSIFICATION: releasing first is what makes session_end stale and wrong", function()
		-- The defect, reproduced. This is the shape the old wiring produced whenever DataService's
		-- PlayerRemoving connection ran before AnalyticsService's — i.e. by default.
		local h = harness()
		local player = Mocks.player(3)
		join(h, player)
		local updated = h.data:update(player, function(blob: any): any
			blob.currencies.Credits = 5000
			return blob
		end)
		expect(updated):toBeOk()

		h.data:onPlayerRemoving(player) -- step 3 first — the bug
		h.analytics:onPlayerRemoving(h.data, player) -- step 1 last

		local payload = h.analytics:eventsOfType("session_end")[1].payload
		expect(payload.stale):toBe(true) -- the tell
		expect(payload.credits):toBe(0) -- the JOIN-time seed value, not the 5000 just earned
	end)

	it("still releases the session when the analytics step throws", function()
		local h = harness()
		local player = Mocks.player(4)
		join(h, player)
		h.analytics.onPlayerRemoving = function(): any
			error("emitter blew up")
		end
		local warned: { string } = {}
		local realLogWarn = PlayerLifecycle.logWarn
		PlayerLifecycle.logWarn = function(_self: any, message: string): ()
			table.insert(warned, message)
		end

		PlayerLifecycle:onRemoving(h.context, player)
		PlayerLifecycle.logWarn = realLogWarn -- never leak the stub into another test

		-- The player's final durable write is not hostage to the emitter.
		expect(h.data:get(player)):toBeErr("NoData")
		expect(#warned >= 1):toBe(true)
	end)

	it("tolerates a context with no plot seam and no analytics", function()
		local h = harness()
		local player = Mocks.player(5)
		join(h, player)
		PlayerLifecycle:onRemoving({ clock = h.clock, data = h.data }, player)
		expect(h.data:get(player)):toBeErr("NoData")
	end)

	it("the bootstrap gives PlayerLifecycle the connection, ahead of data and analytics", function()
		-- The module can be perfectly ordered and still never run. This is the other half: the
		-- sequence is only real if the bootstrap starts the owner BEFORE the two services that
		-- would otherwise connect PlayerRemoving themselves.
		local boot = readSource("src/server/init.server.luau")
		local requireAt = string.find(boot, "require(Server.framework.PlayerLifecycle)", 1, true)
		expect(requireAt ~= nil):toBe(true)

		local listAt = string.find(boot, "local services = {", 1, true)
		expect(listAt ~= nil):toBe(true)
		local lifecycleAt = string.find(boot, "PlayerLifecycle,", listAt :: number, true)
		local dataAt = string.find(boot, "context.data,", listAt :: number, true)
		local analyticsAt = string.find(boot, "context.analytics,", listAt :: number, true)
		expect(lifecycleAt ~= nil):toBe(true)
		expect(dataAt ~= nil and (lifecycleAt :: number) < (dataAt :: number)):toBe(true)
		expect(analyticsAt ~= nil and (lifecycleAt :: number) < (analyticsAt :: number)):toBe(true)
	end)

	it("data + analytics stand down from PlayerRemoving when the sequence is owned", function()
		-- If either ever connects unconditionally again, the release runs from a second handler in
		-- an uncontrolled order and A10b is silently dead. Their Start methods touch `game`, so this
		-- is asserted structurally — the guard must be there, in both files.
		for _, relative in
			{
				"src/server/data/DataService.luau",
				"src/server/services/analytics/AnalyticsService.luau",
			}
		do
			local source = readSource(relative)
			local connectAt = string.find(source, "Players.PlayerRemoving:Connect", 1, true)
			expect(connectAt ~= nil):toBe(true)
			local guardAt =
				string.find(source, "if context.playerRemovingOwner == nil then", 1, true)
			expect(guardAt ~= nil):toBe(true)
			expect((guardAt :: number) < (connectAt :: number)):toBe(true)
		end
	end)
end)
