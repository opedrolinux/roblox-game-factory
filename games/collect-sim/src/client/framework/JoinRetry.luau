--!strict
-- games/collect-sim/src/client/framework/JoinRetry.luau
-- The join-race guard for client controllers.
--
-- THE RACE: DataService.loadSession YIELDS on join (several DataStore round trips), while client
-- controllers Start the moment the player's scripts load. So a server call issued from Start() can
-- arrive before the session is installed and come back Err(NoData, "session not loaded")
-- (DataService.luau §get/§update). Observed in 2 of 2 real Studio Play sessions.
--
-- WHY IT IS NOT MERELY COSMETIC: for a grant-shaped action the loss is PERMANENT, not deferred.
-- autosaveTick rewrites `timestamps.lastSeenUnix` to now on every flush (every
-- Config.autosaveIntervalSeconds = 60s), so within a minute the unclaimed away-window is erased from
-- persistence and the next join computes elapsed from the new base. The player is silently not paid,
-- and worst for exactly the players it is meant to serve: a long absence means a long load, which is
-- the same yield that loses the race.
--
-- WHY NOT JUST `net:on("data", call)` (the shape IslandsController uses): for ClaimOffline that is an
-- unbounded self-feeding remote loop. Its transform ALWAYS writes (it advances lastSeenUnix on every
-- path), DataService pushes the view on EVERY successful write with no dirty check, and the push
-- would re-enter the handler — forever, with no player action needed to sustain it. Islands gets
-- away with the identical shape only because its fetch is a read that writes nothing, so it emits no
-- push. This module therefore retries AT MOST ONCE, and only when the join attempt actually lost.
--
-- PURE BY CONSTRUCTION: no `game`, no LocalPlayer, no require of Shared — so Tier-1 can drive it
-- under Lune with a fake net, exactly as framework.spec drives the pure Bootstrap. That matters
-- because every other rung is blind here: client controllers touch Players.LocalPlayer at module
-- scope (unrequirable under Lune), the T2 smoke drives only the server, and T2.5 runs in edit mode
-- with no LocalPlayer at all.
local JoinRetry = {}

-- The literal, rather than require(Shared.Result), is what keeps this module Lune-requirable.
-- joinretry.spec asserts this equals Result.Codes.NoData so the string cannot silently drift.
JoinRetry.SESSION_NOT_LOADED = "NoData"

-- Run a join-time server call race-safely.
--
-- Returns the join-time attempt's Result UNCHANGED, so adopting this at a call site does not change
-- the caller's shape. `label` appears in the diagnostic print, which is the only externally visible
-- signal that the retry fired — deliberately, because a re-run seconds later has elapsed ~= 0 and so
-- grants 0, leaving the success path silent. An empty console is not a pass.
function JoinRetry.once(net: any, label: string, call: () -> any): any
	local pending = true -- the join-time attempt is still in flight
	local armed = true -- the single retry has not been spent
	local sawPush = false -- a "data" push landed DURING the attempt

	local function retry(): ()
		armed = false
		print(`[JoinRetry] {label}: session was not loaded at join; re-issued on the data push`)
		call()
	end

	-- SUBSCRIBE BEFORE CALLING. net:call yields inside InvokeServer and the server's on-load push can
	-- land inside that yield; NetClient.on has no replay buffer, so a handler registered AFTER the
	-- failed call can miss the very push it is waiting for — the same race, one layer up.
	-- Self-latching rather than disconnecting: NetClient.on returns nothing and offers no unsubscribe.
	net:on("data", function(_view: any): ()
		if not armed then
			return -- spent, or never needed: every later push (Sell, unlock, daily) is a no-op
		end
		if pending then
			sawPush = true -- attempt still in flight; decide once it returns
			return
		end
		retry()
	end)

	local result = call()
	pending = false

	if result == nil or result.ok then
		armed = false -- the join attempt won (or returned nothing to judge); never re-issue
		return result
	end
	if result.code ~= JoinRetry.SESSION_NOT_LOADED then
		armed = false -- Insufficient / RateLimited / NotOwner are real rejections, not a load race
		return result
	end
	if sawPush then
		retry() -- the push we needed already landed mid-flight; consume it now
	end
	return result
end

return JoinRetry
