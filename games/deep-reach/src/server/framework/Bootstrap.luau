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
	-- QUIESCE FIRST, over EVERY service, before any Stop runs.
	--
	-- Reverse-order Stop is right for dependencies and wrong for the wire. The gateway starts near the
	-- FRONT of the boot order (NetServer must bind before anything registers), so reverse order stops
	-- it near the END — after every service whose handlers it is still carrying clients into. For the
	-- whole of that window a stopped service is reachable from the network with its in-RAM guards
	-- already cleared. That is not hypothetical: OfflineService.Stop drops `_pending`, the only
	-- one-shot guard on the away window, and DataService.Stop persists afterwards, so a claim landing
	-- in the window re-pays the entire session durably.
	--
	-- Quiesce is therefore a SEPARATE, EARLIER pass and not just another Stop — no ordering of a
	-- single pass can put a service both first (to close its wire) and last (to flush its state).
	for _, service in started do
		if (service :: any).Quiesce ~= nil then
			local ok, err = pcall(function()
				(service :: any):Quiesce(context)
			end)
			if not ok then
				-- Never abort the teardown. A shutdown that stops halfway leaves live sessions
				-- unpersisted, which costs more than the window Quiesce is closing.
				warn(`Bootstrap.stop: service "{service.name}" Quiesce errored: {tostring(err)}`)
			end
		end
	end

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
