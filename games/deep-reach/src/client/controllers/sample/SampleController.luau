--!strict
-- core/src/client/controllers/sample/SampleController.luau   [SAMPLE — deletable]
-- Calls the sample Net action once on start and logs the Result; also subscribes to the data
-- view push so it can read the balance. ROBLOX-ONLY (uses script/game via the bootstrap).
-- No spec requires it. new-game deletes this. See docs/CORE-DESIGN.md §8.
local SampleController = { name = "SampleController" }

function SampleController:Start(context: any): ()
	-- Show the server-pushed client-safe view (PlayerView) when it arrives.
	context.net:on("data", function(view: any): ()
		local stardust = view and view.currencies and view.currencies.Stardust
		print(`[SampleController] data view received; Stardust = {tostring(stardust)}`)
	end)

	-- Fire the sample action once and log the Result (server is authoritative).
	local result = context.net:call("sample.ping", { amount = 10 })
	if result.ok then
		print(`[SampleController] sample.ping ok; balance = {tostring(result.value.balance)}`)
	else
		warn(`[SampleController] sample.ping failed: {tostring(result.code)}`)
	end
end

return SampleController
