--!strict
-- core/src/server/Context.luau
-- Builds + holds the server context table (the dependency-injection table passed to every
-- Start). CONSTRUCT phase only (§2.2): news up clock, config, data, net, gate so every core
-- context field is non-nil from t0. No I/O / event connections / RemoteEvent creation here —
-- that happens in each object's Start. ROBLOX-ONLY: uses script/game. Never required by a spec.
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared.Config)

local Clock = require(Server.data.Clock)
local MockStore = require(Server.data.MockStore)
local SessionStore = require(Server.data.SessionStore)
local DataService = require(Server.data.DataService)
local Gate = require(Server.security.Gate)
local NetServer = require(Server.net.NetServer)
local AnalyticsService = require(Server.services.analytics.AnalyticsService)

-- [B2 §6] Pick the store by REAL DataStore capability, never by `game ~= nil` (this module
-- already dereferences `game` at module scope, so that guard's else-branch is dead — L8) and
-- never by Studio-vs-live (Studio WITH API access should exercise the real store). The probe:
-- running (not edit mode) AND a real DataStore read succeeds. Without API access the pcall
-- fails -> MockStore fallback (in-memory, honest: a playtest sees data not persisting rather
-- than a hard error on every save).
-- The probe cannot tell "no API access" (permanent — the case §6 exists for) from "DataStores are
-- throttled/erroring this second" (transient). Getting that wrong is expensive: a single unlucky
-- boot-time error would run the ENTIRE server lifetime in memory, and every player on it would
-- play a full session that is silently never saved. So retry a few times before concluding, and
-- if we do fall back, say so LOUDLY — a silent downgrade to a non-persistent store is exactly the
-- kind of failure that looks fine until a day of player progress is already gone.
local PROBE_ATTEMPTS = 3

local function canPersist(): boolean
	if not RunService:IsRunning() then
		return false -- edit mode: no DataStores, and nothing to warn about
	end
	local lastErr: any = nil
	for attempt = 1, PROBE_ATTEMPTS do
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(Config.storeName):GetAsync("__capability_probe")
			-- ALSO probe MemoryStore: SessionStore needs BOTH services. Probing only DataStores
			-- would pass on a server whose MemoryStore is unavailable, install SessionStore, and
			-- then fail every session claim -> Internal -> the load budget exhausts -> EVERY
			-- player is kicked for the server's lifetime. That is worse than the non-persistent
			-- fallback this probe exists to avoid, so a missing MemoryStore must fail the probe.
			MemoryStoreService:GetHashMap(Config.storeName .. "_lock"):GetAsync("__probe")
		end)
		if ok then
			return true
		end
		lastErr = err
		if attempt < PROBE_ATTEMPTS then
			task.wait(attempt) -- 1s, then 2s — brief, bounded, before the server serves anyone
		end
	end
	warn(
		`[DataService] NO PERSISTENCE: DataStore probe failed {PROBE_ATTEMPTS}x — running on the `
			.. `in-memory MockStore. Player progress on this server will NOT be saved. `
			.. `Last error: {tostring(lastErr)}`
	)
	return false
end

local Context = {}

-- CONSTRUCT every core field. The same OBJECT references are later placed in the `services`
-- array (to receive Start); context.net IS services[1], context.data IS services[2] (§2.2).
function Context.build(): any
	-- Inject the monotonic Roblox `time` global as mono()'s source: `time()` returns seconds
	-- since the server started (high-resolution, monotonic wall clock), unlike os.clock() which
	-- is Lua-VM CPU time on Roblox. Clock.luau stays Lune-clean; the Roblox-only global is
	-- referenced HERE, in the Roblox-only bootstrap. See Clock.real / docs/CORE-DESIGN.md §5.
	local clock = Clock.real(time)
	local config = Config

	-- [B2 §6] The real session-locked SessionStore when DataStores are actually usable;
	-- MockStore otherwise (edit mode / no API access). Same Store interface — a drop-in.
	local durable = canPersist()
	local store
	if durable then
		store = SessionStore.new({ clock = clock, config = config })
	else
		store = MockStore.new({ clock = clock, config = config })
	end

	local data = DataService.new(store, clock, config)
	local gate = Gate.new(clock)
	local net = NetServer.new(gate)
	-- The single analytics emitter (contract pass). Constructed here so ctx.analytics is non-nil
	-- from t0 and EVERY handler's ActionContext projects the SAME object; its Start fires the
	-- session_start/session_end lifecycle. It is also placed in `services` to receive Start.
	local analytics = AnalyticsService.new(clock)

	local context = {
		isServer = true,
		clock = clock,
		config = config,
		data = data,
		-- [B2 §6/§10] TRUE when this server fell back to the in-memory store, i.e. nothing written
		-- here survives. Anything that must not acknowledge an irreversible external action
		-- (notably ProcessReceipt — real money) has to consult this: a successful save() from the
		-- fallback store is not durability. Never set on a healthy server.
		persistenceDegraded = not durable,
		net = net,
		gate = gate,
		-- deferred seams (nil in the spine; populated in B2):
		security = nil,
		flags = nil,
		-- the single analytics emitter (contract pass): non-nil from t0; ctx.analytics:emit(...).
		analytics = analytics,
		monetization = nil,
		-- contract pass (v4) feature seams (nil in the spine; populated by stub/feature services):
		islands = nil,
		restock = nil,
	}

	-- Let NetServer close over the full context so it can build each handler's ActionContext.
	net:bindContext(context)

	return context
end

return Context
