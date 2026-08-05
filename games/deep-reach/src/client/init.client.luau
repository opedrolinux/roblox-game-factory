--!strict
-- core/src/client/init.client.luau   [Roblox-only — never required by a spec]
-- THE client bootstrap. Per Rojo, init.client.luau under src/client makes the `Client` folder
-- a LocalScript. See docs/CORE-DESIGN.md §2.5.
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local Client = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
-- -- TODO(verify): StarterPlayerScripts replicate into Players.LocalPlayer.PlayerScripts at runtime.

local Context = require(Client.Context)
local Bootstrap = require(Client.framework.Bootstrap)

local context = Context.build() -- builds NetClient (waits for the server's remotes) + config

-- DETERMINISTIC ORDER, same rule as the server list: earlier = depended-upon-by-later.
-- HudRoot is the ONE shared ScreenGui + slot layout (AMENDMENT A10d); it Starts before any feature
-- controller so the root exists before the first panel mounts. (Controllers do not depend on that
-- ordering — HudRoot.ensure is idempotent and mount() calls it — but no controller may ever create
-- its own ScreenGui; nine of those is a pile of overlapping full-screen GUIs.)
--
-- JoinRetry (Client.framework.JoinRetry) is a PURE helper, not a controller, so it is not started
-- here — a controller requires it directly and wraps its join-time server call:
--   JoinRetry.once(context.net, "offline.claim", function() return context.net:call(...) end)
-- Every join-time fetch/claim MUST go through it: loadSession yields, and an unguarded Start() call
-- loses that race — permanently, for the grant-shaped ones.
local controllers = {
	context.net, -- NetClient (resolves the RemoteFunction/RemoteEvent)
	require(Client.framework.HudRoot), -- [contract pass] the one shared HUD root + slot layout
	-- (AMENDMENT A10a: the sample controller is DELETED along with its server action.)
	-- --- [features] one line per feature controller, appended at merge. Keep this block LAST. ---
}

Bootstrap.start(controllers, context)
