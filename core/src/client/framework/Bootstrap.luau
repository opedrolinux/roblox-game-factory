--!strict
-- core/src/client/framework/Bootstrap.luau
-- The client bootstrap driver — the SAME logic as src/server/framework/Bootstrap.luau,
-- duplicated under src/client so the two sides have no cross-tree require (they are tiny and
-- identical; duplication is cheaper than a require crossing the Server/Client boundary). §2.5.
local Bootstrap = {}

export type Startable = {
	name: string,
	Start: (self: any, context: any) -> (),
	Stop: ((self: any, context: any) -> ())?,
}

-- Drives Start(context) over `controllers` IN THE GIVEN ORDER. Deterministic.
function Bootstrap.start(controllers: { Startable }, context: any): { Startable }
	for _, controller in controllers do
		local ok, err = pcall(function()
			controller:Start(context)
		end)
		if not ok then
			error(
				`Bootstrap.start: controller "{controller.name}" failed to Start: {tostring(err)}`
			)
		end
	end
	return controllers
end

-- Stops in REVERSE order; missing Stop is a no-op.
function Bootstrap.stop(started: { Startable }, context: any): ()
	for i = #started, 1, -1 do
		local controller = started[i]
		if controller.Stop ~= nil then
			local ok, err = pcall(function()
				(controller :: any):Stop(context)
			end)
			if not ok then
				warn(`Bootstrap.stop: controller "{controller.name}" Stop errored: {tostring(err)}`)
			end
		end
	end
end

return Bootstrap
