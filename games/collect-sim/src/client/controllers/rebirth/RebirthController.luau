--!strict
-- games/collect-sim/src/client/controllers/rebirth/RebirthController.luau   [rebirth — UI]
-- THIN client controller for the rebirth feature. ALL authority stays server-side: this controller
-- sends ONLY an empty intent and renders the server's authoritative reply. It NEVER computes the
-- threshold, the Prisms grant, the rebirth count, or the multiplier — it asks the server and shows the
-- result. The permanent multiplier shown is whatever the server returns (derived server-side at
-- read), never fabricated here.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context + the Hud singleton + the Pads helper).
-- No spec requires it; mirrors the sample/islands controller pattern: subscribe to the pushed data
-- view for the live rebirth/Prisms count, expose a typed rebirth() the UI calls, and (Slice 4) bind
-- the in-world rebirth pad's ProximityPrompt to it. Never requires another controller.
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Pads = require(Client.world.Pads)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

local RebirthController = { name = "RebirthController" }

function RebirthController:Start(context: any): ()
	local net = context.net

	-- Latest server-authoritative prestige snapshot for the UI to read. Server-owned; the client never
	-- fabricates these numbers. Seeded from the pushed data view below.
	self._rebirths = 0
	self._prisms = 0

	-- Mirror the pushed client-safe view so the HUD shows the live rebirth count + Prisms balance. The
	-- server is the sole authority; we only display what it replicates.
	net:on("data", function(view: any): ()
		if view == nil then
			return
		end
		self._rebirths = (view.rebirths ~= nil) and view.rebirths or self._rebirths
		local currencies = view.currencies
		if currencies ~= nil and currencies.Prisms ~= nil then
			self._prisms = currencies.Prisms
		end
	end)

	-- Ask the server to rebirth. The client sends ONLY an empty intent — never a threshold, never a
	-- Prisms amount, never a multiplier. The server validates the Stardust threshold, performs the full
	-- atomic reset, grants Prisms, and is the sole authority. On success the server's pushed data view
	-- refreshes the HUD; we also stash the authoritative reply for an immediate UI update.
	function self.rebirth(): any
		local result = net:call(Net.Actions.Rebirth, {})
		if result.ok then
			self._rebirths = result.value.rebirths
			self._prisms = result.value.prisms
		else
			warn(`[RebirthController] rebirth failed: {tostring(result.code)}`)
		end
		return result
	end

	-- ----- THE ALTAR: state its price, then make you mean it -----
	-- The most destructive action in the game used to fire on ONE keypress, with no on-screen cost,
	-- no reward, and no confirmation anywhere. The pad now carries the live threshold (server-derived,
	-- read through the shop projection) and requires a HOLD, which is Roblox's own built-in
	-- are-you-sure and costs nothing to implement.
	local HOLD_SECONDS = 1.5

	local function altarLabel(preview: any): string
		if preview == nil then
			return "Rebirth Altar"
		end
		if preview.capped then
			return "Rebirth Altar — maxed out"
		end
		local nextMult = string.format("%.1f", preview.multiplierNext)
		if preview.ready then
			return `Rebirth Altar — READY\nHold E: lose ★ {preview.threshold}, keep your islands, gain ◆ {preview.prismsPreview} and x{nextMult} forever`
		end
		local held = math.floor(preview.stardust)
		return `Rebirth Altar — needs ★ {preview.threshold}\nYou have ★ {held} · keeps your islands`
	end

	-- Refresh the altar's own billboard from the server's prestige preview. It rides the shop
	-- projection because that is where the server already derives the threshold and the reward.
	local function refreshAltar(): ()
		local result = net:call(Net.Actions.FetchUpgrades, {})
		if not result.ok then
			return
		end
		local preview = result.value.rebirth
		self._preview = preview
		Pads.setLabelAll("rebirth", altarLabel(preview))
		for _, pad in Pads.findAll("rebirth") do
			local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt")
			if prompt ~= nil then
				prompt.HoldDuration = HOLD_SECONDS
				prompt.ActionText = if preview ~= nil and preview.ready
					then "Hold to Rebirth"
					else "Not ready"
				prompt.Enabled = preview == nil or (preview.ready and not preview.capped)
			end
		end
	end
	self.refreshAltar = refreshAltar
	task.spawn(refreshAltar)
	net:on("data", function(_view: any): ()
		task.spawn(refreshAltar)
	end)

	Pads.onTrigger("rebirth", nil, LocalPlayer, function(_pad: any): ()
		local result = self.rebirth()
		if result.ok then
			-- Update the HUD prestige readouts straight from the authoritative reply (snappy); the
			-- post-write "data" push reconciles Stardust (rebirth zeroes it).
			Hud.setRebirths(result.value.rebirths)
			Hud.setPrisms(result.value.prisms)
			local multiplier = string.format("%.1f", result.value.multiplier)
			Hud.flash(
				`REBIRTH {result.value.rebirths} — every mote is now worth x{multiplier}, and you kept your islands`
			)
			task.spawn(refreshAltar)
		elseif result.code == Result.Codes.Insufficient then
			local preview = self._preview
			if preview ~= nil then
				local held = math.floor(preview.stardust)
				Hud.flash(`Rebirth needs ★ {preview.threshold} — you have ★ {held}`)
			else
				Hud.flash("Not enough Stardust to rebirth yet")
			end
		elseif result.code == Result.Codes.OutOfRange then
			Hud.flash("You have rebirthed as far as this game goes")
		else
			Hud.flash("Rebirth failed")
		end
	end)
end

return RebirthController
