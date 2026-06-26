--!strict
-- games/collect-sim/src/client/controllers/hud/HudController.luau   [hud — UI]
-- THIN controller that MOUNTS the HUD singleton (Client.hud.Hud) and drives the currency / rebirth
-- readouts from the server's "data" push. It owns NO authority and computes NO numbers — it mirrors
-- exactly what the server replicates in the client-safe PlayerView. The backpack count is fed
-- separately by CollectionController (it comes from Collect/Sell action replies, NOT the data push —
-- presentation-plan R4), so this controller never touches it beyond the initial 0.
--
-- ROBLOX-ONLY (uses the client Net via context + the Hud singleton). Mirrors the sibling controllers:
-- it never requires another controller — it reaches the shared HUD through the Hud helper module.
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

local HudController = { name = "HudController" }

function HudController:Start(context: any): ()
	local net = context.net

	-- Build the HUD now so it exists before the first data push lands, and seed the backpack readout.
	Hud.ensure()
	Hud.setBackpack(0)

	-- Mirror the client-safe view on every push (load + after relevant writes). Read-only display: we
	-- only ever render fields the server chose to replicate; a missing field leaves its label as-is.
	net:on("data", function(view: any): ()
		if view == nil then
			return
		end
		local currencies = view.currencies
		if currencies ~= nil then
			if currencies.Stardust ~= nil then
				Hud.setStardust(currencies.Stardust)
			end
			if currencies.Prisms ~= nil then
				Hud.setPrisms(currencies.Prisms)
			end
		end
		if view.rebirths ~= nil then
			Hud.setRebirths(view.rebirths)
		end
		if view.daily ~= nil and view.daily.streak ~= nil then
			Hud.setDailyStreak(view.daily.streak)
		end
	end)

	-- Gap #2: the daily-claim button has no controller of its own — HudController owns the call. The
	-- client sends ONLY the empty intent; the server is the sole authority over the cooldown, the
	-- streak, and the server-derived reward. We just render the authoritative reply. The call yields,
	-- so it runs on its own task off the button click.
	Hud.onDailyClaim(function(): ()
		task.spawn(function(): ()
			local result = net:call(Net.Actions.Daily, {})
			if result.ok then
				Hud.setStardust(result.value.balance)
				Hud.setDailyStreak(result.value.streak)
				Hud.flash(
					`Daily reward: +{result.value.reward} Stardust (streak {result.value.streak})`
				)
			elseif result.code == Result.Codes.OnCooldown then
				Hud.flash("Daily already claimed — come back tomorrow")
			else
				Hud.flash("Daily claim failed")
			end
		end)
	end)
end

return HudController
