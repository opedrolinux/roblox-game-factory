--!strict
-- core/src/server/framework/Bootstrap.luau
-- The bootstrap driver: pure + testable. Takes an ORDERED list of services + a context and
-- drives Start in order, then Stop in reverse. It does not know about Roblox — just a
-- sequencer — so framework.spec can drive it under Lune with fake services. Lune-clean.
-- See docs/CORE-DESIGN.md §2.2. (The client mirror is identical.)

local Bootstrap = {}

export type Startable = {
	name: string,
	Start: (self: any, context: any) -> (),
	Stop: ((self: any, context: any) -> ())?,
}

-- Drives Start(context) over `services` IN THE GIVEN ORDER. Deterministic.
-- Returns the started list so Stop can run in reverse. Raises (with the service name) if a
-- Start errors, so a bad service fails the run loudly, not silently.
function Bootstrap.start(services: { Startable }, context: any): { Startable }
	for _, service in services do
		local ok, err = pcall(function()
			service:Start(context)
		end)
		if not ok then
			error(`Bootstrap.start: service "{service.name}" failed to Start: {tostring(err)}`)
		end
	end
	return services
end

-- Stops in REVERSE order; missing Stop is a no-op. Used by BindToClose. A Stop that errors
-- is logged (not re-raised) so one failing Stop never blocks the rest of the shutdown flush.
function Bootstrap.stop(started: { Startable }, context: any): ()
	for i = #started, 1, -1 do
		local service = started[i]
		if service.Stop ~= nil then
			local ok, err = pcall(function()
				(service :: any):Stop(context)
			end)
			if not ok then
				warn(`Bootstrap.stop: service "{service.name}" Stop errored: {tostring(err)}`)
			end
		end
	end
end

return Bootstrap
