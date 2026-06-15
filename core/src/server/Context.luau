--!strict
-- core/src/server/Context.luau
-- Builds + holds the server context table (the dependency-injection table passed to every
-- Start). CONSTRUCT phase only (§2.2): news up clock, config, data, net, gate so every core
-- context field is non-nil from t0. No I/O / event connections / RemoteEvent creation here —
-- that happens in each object's Start. ROBLOX-ONLY: uses script/game. Never required by a spec.
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService:WaitForChild("Server")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared.Config)

local Clock = require(Server.data.Clock)
local MockStore = require(Server.data.MockStore)
local DataService = require(Server.data.DataService)
local Gate = require(Server.security.Gate)
local NetServer = require(Server.net.NetServer)

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

	-- Spine runtime default store is the in-memory MockStore (B2 swaps SessionStore behind the
	-- same Store interface — a drop-in, no DataService change).
	local store = MockStore.new({ clock = clock, config = config })

	local data = DataService.new(store, clock, config)
	local gate = Gate.new(clock)
	local net = NetServer.new(gate)

	local context = {
		isServer = true,
		clock = clock,
		config = config,
		data = data,
		net = net,
		gate = gate,
		-- deferred seams (nil in the spine; populated in B2):
		security = nil,
		flags = nil,
		analytics = nil,
		monetization = nil,
	}

	-- Let NetServer close over the full context so it can build each handler's ActionContext.
	net:bindContext(context)

	return context
end

return Context
