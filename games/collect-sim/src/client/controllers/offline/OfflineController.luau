--!strict
-- games/collect-sim/src/client/controllers/offline/OfflineController.luau   [offline — UI]
-- THIN client controller for the offline-earnings feature. ALL authority stays server-side: this
-- controller sends ONLY the empty claim intent and renders the server's authoritative reply. It never
-- computes elapsed time, a rate, a multiplier, or a grant — it asks the server (which derives everything
-- from the persisted lastSeenUnix + the server clock) and shows the result.
--
-- ROBLOX-ONLY (uses the client Net via the bootstrap context + the Hud singleton). No spec requires
-- it; mirrors the sample/islands controller pattern: claim once on join, expose a typed claim() the UI
-- can call, and (Slice 5) show the server-reported grant in the HUD's welcome-back popup. Never
-- requires a sibling controller — it reaches the HUD through the shared Hud module.
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local JoinRetry = require(Client.framework.JoinRetry)
local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Net)

local OfflineController = { name = "OfflineController" }

function OfflineController:Start(context: any): ()
	local net = context.net

	-- Keep the latest server-authoritative offline result for the UI to read (the "welcome back" popup).
	-- Server-owned; the client never fabricates these numbers.
	self._lastClaim = nil :: any

	-- Ask the server to claim offline earnings. The client sends ONLY the empty intent — never a time,
	-- never an elapsed duration, never an amount. The server reads lastSeenUnix, derives elapsed on its
	-- own clock, caps the grant, and is the sole authority. A re-claim in the same session grants nothing
	-- (the server advanced the base), so the button is safe to press repeatedly.
	local function claim(): any
		local result = net:call(Net.Actions.ClaimOffline, {})
		if result.ok then
			self._lastClaim = result.value
			if result.value.granted > 0 then
				print(
					`[OfflineController] claimed {tostring(result.value.granted)} offline Stardust `
						.. `(balance {tostring(result.value.balance)})`
				)
				-- Rendered HERE rather than after the join-time call, so the JoinRetry path renders
				-- too: for a player whose session was still loading, the RETRY is the claim that
				-- grants, and a popup wired to the join attempt alone would never fire for them.
				Hud.setStardust(result.value.balance) -- reflect the grant in the persistent readout
				Hud.showWelcomeBack(result.value.granted, result.value.balance)
			end
		else
			warn(`[OfflineController] claim failed: {tostring(result.code)}`)
		end
		return result
	end
	self.claim = claim

	-- Claim-on-join, race-safely. loadSession YIELDS, so this call can land before the session is
	-- installed and come back Err(NoData) — observed in 2 of 2 real Play sessions. That used to be
	-- terminal: nothing retried, and autosave rewrites lastSeenUnix within 60s, so the away-window
	-- was erased and the grant lost for good. JoinRetry re-issues EXACTLY ONCE on the server's
	-- on-load "data" push, and never again — a plain net:on("data", claim) would self-feed forever
	-- here, because this action always writes and every write pushes. See JoinRetry.luau.
	JoinRetry.once(net, "OfflineController.claim", claim)
end

return OfflineController
