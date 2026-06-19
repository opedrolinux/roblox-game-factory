--!strict
-- games/collect-sim/src/server/services/shop/UpgradesShopService.luau   [upgrades-shop]
-- CONTRACT-PASS STUB. The shop's action name is reserved in Net.Actions (BuyUpgrade = "shop.buy")
-- and this service is registered in init.server, so the tree compiles and wires. The build-features
-- builder REPLACES this body with the real server-validated purchase logic: validate the upgradeId +
-- affordability + level cap, then deduct Stardust and bump upgrades[id] ATOMICALLY inside ONE
-- ctx.data:update transform (no read-then-write across a yield — no double-spend / overspend).
local UpgradesShopService = { name = "UpgradesShopService" }

function UpgradesShopService:Start(_context: any): ()
	-- stub: registers no action yet. Replaced by the build-features builder.
end

return UpgradesShopService
