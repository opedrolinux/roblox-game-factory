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
-- JoinRetry (Client.framework.JoinRetry) is not a controller and is not started here: it is
-- INSTALLED ON context.net by Context.build, above, so the first call of each action — whoever
-- issues it — is already race-guarded. A controller therefore writes the ordinary
-- `context.net:call("offline.claim", …)` from Start and is safe; there is no wrapper to remember
-- and no way to opt out, because context.net is the only wire out of the client.
-- (loadSession yields on join, and an unguarded Start() call loses that race — permanently, for the
-- grant-shaped ones, because autosave re-stamps lastSeenUnix and erases the away window.)
local controllers = {
	context.net, -- NetClient (resolves the RemoteFunction/RemoteEvent)
	require(Client.framework.HudRoot), -- [contract pass] the one shared HUD root + slot layout
	-- (AMENDMENT A10a: the sample controller is DELETED along with its server action.)
	-- --- [features] one line per feature controller, appended at merge. Keep this block LAST. ---
	require(Client.controllers.plot.PlotController), -- [plot] dome highlight + label (zero authority)
	-- [salvage] the BottomLeft rate/stored/capacity readout + the BottomCenter collect button
	require(Client.controllers.salvage.SalvageController),
	require(Client.controllers.daily.DailyController), -- [daily] streak badge + claim (zero authority)
	-- [structures] the RightPanel shop catalog + the BottomRight opener (zero authority: every price,
	-- level and effect reading on it came off a structures.fetch / structures.buy reply)
	require(Client.controllers.structures.StructuresController),
	-- [leaderboard] the in-world greybox board + the LeftPanel standings list (zero authority)
	require(Client.controllers.leaderboard.LeaderboardController),
	-- [depth] the TopRight trench badge: current tier + multiplier, the next tier's Credits AND hull
	-- requirement against what the player has, today's rich-wreck tier, and the descend prompt itself
	-- (zero authority: the whole pressure gate is re-evaluated server-side inside one lock-held
	-- transform, and the descend payload carries nothing at all)
	require(Client.controllers.depth.DepthController),
	-- [offline] the Center-slot claim-on-join popup: the away-window amount, whether the smelter
	-- capacity capped it, and the claim button (zero authority: the amount is computed server-side at
	-- session load from timestamps.lastSeenUnix and held in server memory, and both offline actions
	-- take no arguments at all)
	require(Client.controllers.offline.OfflineController),
	-- [monetization] the TopRight boost/owned-pass badge + the BottomRight store opener and its
	-- Center-slot store panel (zero authority: this feature has NO net action at all — the only thing
	-- the controller does is ask Roblox to show a purchase prompt, and every grant is decided
	-- server-side from UserOwnsGamePassAsync / PromptGamePassPurchaseFinished / ProcessReceipt)
	require(Client.controllers.monetization.MonetizationController),
	-- [resurface] the BottomCenter prestige prompt (count + Pearl balance, read off the replicated
	-- view) and its Center-slot CONFIRM DIALOG: the Pearls that would be minted, the permanent
	-- multiplier before/after, and the running rate either side of the wipe (zero authority: every
	-- number came off a resurface.fetch / resurface.do reply the SERVER derived, and the resurface
	-- payload carries nothing at all)
	require(Client.controllers.resurface.ResurfaceController),
}

Bootstrap.start(controllers, context)
