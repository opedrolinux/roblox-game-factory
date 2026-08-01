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

	-- Register the "data" subscription FIRST: the HUD build (ensure -> PlayerGui) yields, and NetClient
	-- drops a "data" event that arrives with no handler (there is no replay). Registering before any
	-- yield means a join push landing mid-build is still applied (the setters lazily build the HUD).
	-- The daily reward opens 20h after the last claim (server-owned window). We mirror the SERVER's
	-- lastClaimUnix against a SERVER-derived now, never os.time(): a client clock is not a clock.
	local DAILY_WINDOW_SECONDS = 20 * 3600
	local lastClaimUnix = 0
	local serverNow = 0
	local boostExpiresUnix = 0

	local function paintTimeDrivenBits(): ()
		if serverNow <= 0 then
			return
		end
		-- The Claim button used to look identical whether the reward was ready or 19 hours away.
		if lastClaimUnix <= 0 then
			Hud.setDailyReady(true)
		else
			local readyAt = lastClaimUnix + DAILY_WINDOW_SECONDS
			Hud.setDailyReady(serverNow >= readyAt, math.max(0, readyAt - serverNow))
		end
		-- boostExpiresUnix has been replicated to every client since v5 and read by nothing.
		Hud.setBoost(boostExpiresUnix, serverNow)
	end

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
		-- `stats` and `flags` have been replicated since v4 and read by no client code at all.
		if view.stats ~= nil and view.stats.lifetimeStardust ~= nil then
			Hud.setLifetime(view.stats.lifetimeStardust)
		end
		if view.flags ~= nil then
			Hud.setPerks(view.flags)
		end
		if view.daily ~= nil then
			if view.daily.streak ~= nil then
				Hud.setDailyStreak(view.daily.streak)
			end
			if view.daily.lastClaimUnix ~= nil then
				lastClaimUnix = view.daily.lastClaimUnix
			end
		end
		if view.boostExpiresUnix ~= nil then
			boostExpiresUnix = view.boostExpiresUnix
		end
		paintTimeDrivenBits()
	end)

	-- Build the HUD now (so it exists for the first setter) and seed the backpack readout.
	Hud.ensure()
	Hud.setBackpack(0)

	-- ----- SERVER TIME, RESAMPLED -----
	-- Both countdowns are anchored to the SERVER's unix clock, which arrives on the shop projection.
	-- Between samples we advance our copy by real elapsed seconds so the numbers tick smoothly, and
	-- resample regularly so drift can never accumulate. We never read os.time() as an authority.
	task.spawn(function(): ()
		local lastSample = 0
		while true do
			local result = net:call(Net.Actions.FetchUpgrades, {})
			if result.ok and type(result.value.now) == "number" then
				serverNow = result.value.now
				lastSample = os.clock()
				paintTimeDrivenBits()
			end
			-- Tick locally for 15s, then resample.
			for _ = 1, 15 do
				task.wait(1)
				if serverNow > 0 then
					serverNow += os.clock() - lastSample
					lastSample = os.clock()
					paintTimeDrivenBits()
				end
			end
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
