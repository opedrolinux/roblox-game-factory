--!strict
-- games/collect-sim/src/server/services/daily/DailyStreakService.luau   [daily-streak]
-- CONTRACT-PASS STUB. The action name is reserved (Net.Actions.Daily = "daily.claim"), the persisted
-- `daily` field exists (Types v2 + Migrations.default + the v1->v2 migration step), and this service
-- is registered in init.server, so the tree compiles and wires. The build-features builder REPLACES
-- this body with the real SERVER-CLOCK-GATED claim logic: read ctx.clock:unix() (never client time),
-- gate on the claim window, then update streak + lastClaimUnix + grant Stardust ATOMICALLY inside ONE
-- ctx.data:update transform (no read-then-write across a yield — no double-claim).
local DailyStreakService = { name = "DailyStreakService" }

function DailyStreakService:Start(_context: any): ()
	-- stub: registers no action yet. Replaced by the build-features builder.
end

return DailyStreakService
