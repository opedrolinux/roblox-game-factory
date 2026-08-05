--!strict
-- games/deep-reach/src/client/framework/JoinRetry.luau   [contract pass — infra]
-- The join-race guard for client controllers. This scaffold shipped without one.
--
-- THE RACE: DataService.loadSession YIELDS on join (several DataStore round trips, plus up to
-- sessionLockedWaitSeconds of lock waiting), while client controllers Start the moment the player's
-- scripts load. So a server call issued from Start() can arrive before the session is installed and
-- come back Err(NoData, "session not loaded") — DataService:get / :update return exactly that.
-- Every Deep Reach controller does this: plot.fetch, salvage.fetch, offline.peek, offline.claim,
-- daily.claim are all join-time reads of state that only exists after the yield completes.
--
-- WHY IT IS NOT MERELY COSMETIC: for a GRANT-shaped action the loss is PERMANENT, not deferred.
-- autosaveTick rewrites `timestamps.lastSeenUnix` to now on every flush (every
-- Config.autosaveIntervalSeconds), so within one interval the unclaimed away-window is erased from
-- persistence and the next join computes elapsed from the new base. The player is silently not paid
-- — and worst for exactly the players it is meant to serve, because a long absence means a long
-- load, which is the same yield that loses the race. This exact defect shipped in this factory's
-- previous game and was invisible to every offline rung; it took a live Studio session to see it.
--
-- WHY NOT JUST `net:on("data", call)`: for a claim-shaped action that is an unbounded self-feeding
-- remote loop. A claim transform ALWAYS writes (it advances the away-window base on every path),
-- DataService pushes the client view on EVERY successful write with no dirty check, and the push
-- would re-enter the handler — forever, with no player action needed to sustain it. This module
-- therefore retries AT MOST ONCE, and only when the join attempt actually lost the race.
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
			return -- spent, or never needed: every later push (collect, buy, descend) is a no-op
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

-- ───────────────────────────────────────────────────────────────────────────────────────────────
-- INSTALL — why the guard is not something a controller opts into.
--
-- The mechanism above was correct and REACHED BY NOTHING: no file under src/ required this module,
-- so every controller written during fan-out would have called context.net:call(...) straight from
-- Start and lost the race, exactly as the previous game did. "Every join-time fetch MUST go through
-- JoinRetry" written in a comment is the same class of promise as the PlayerRemoving order that was
-- also only a comment — it holds until the first author who has not read it.
--
-- So the guard is installed ON THE NET ITSELF, in src/client/Context.luau, before the context is
-- handed to Bootstrap. A controller resolves its collaborators from `context` and never requires a
-- sibling module (framework/Controller.luau §2.1), so `context.net` IS the only wire out of the
-- client — and the FIRST call it ever makes for a given action is wrapped whether the author knew
-- about this module or not. There is nothing to remember and nothing to opt into.
--
-- SCOPE: first call PER ACTION, not per client. `plot.fetch` and `offline.claim` are issued from
-- two different controllers' Start and each can lose the race independently. Every later call of an
-- action (a player-driven collect, buy, descend) is passed straight through: those are not join
-- reads, they cannot be "too early", and re-issuing them on a data push is the unbounded
-- self-feeding remote loop `once` exists to avoid.
function JoinRetry.install(net: any): any
	if net == nil then
		return net
	end
	if net._joinGuarded then
		return net -- idempotent: a second install would wrap the wrapper and retry twice
	end
	net._joinGuarded = true

	-- Resolve through the instance so the metatable's NetClient.call is captured ONCE; the field we
	-- assign below shadows it for every later lookup, so `raw` can never become the wrapper itself.
	local raw = net.call
	local guarded: { [string]: boolean } = {}

	net.call = function(self: any, actionName: string, payload: any): any
		local function issue(): any
			return raw(self, actionName, payload)
		end
		if guarded[actionName] then
			return issue()
		end
		guarded[actionName] = true
		return JoinRetry.once(self, actionName, issue)
	end

	return net
end

return JoinRetry
