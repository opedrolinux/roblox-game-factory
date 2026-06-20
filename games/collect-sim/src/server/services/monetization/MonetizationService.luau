--!strict
-- games/collect-sim/src/server/services/monetization/MonetizationService.luau   [monetization — CONTRACT-PASS STUB]
-- STUB: stands up the monetization seam so the contract is complete before fan-out. It registers
-- NO client action (contract.stubs[monetization].actions is empty — ProcessReceipt is server-driven,
-- not a client action) and implements NO feature LOGIC. It ONLY publishes the identity-default
-- ctx.monetization seam the consolidated Sell formula consumes. The real builder REPLACES this with
-- the receipt-processing path + a real stardustMultiplier (e.g. a 2x-Stardust gamepass).
--
-- SEAM (contract.stubs[monetization].seam): ctx.monetization:stardustMultiplier(userId) -> 1
-- (identity default). Set on context in Start so the Sell formula's stardustMult is exactly 1
-- (behavior-identical to pre-feature Sell). hasUI = false: no client controller.
--
-- Lune-clean: relative requires only; no Roblox global touched.
local MonetizationService = { name = "MonetizationService" }

-- Identity-default seam: every player's Stardust multiplier is 1 until the real feature lands.
-- Pure, no I/O. `_userId` is the player whose multiplier the Sell formula wants; the stub ignores it.
local MonetizationSeam = {}
function MonetizationSeam.stardustMultiplier(_self: any, _userId: number): number
	return 1
end

-- Start: publish the identity-default seam onto the shared context so every handler's ActionContext
-- (built per-request by NetServer) sees ctx.monetization from now on. No actions to register.
function MonetizationService:Start(context: any): ()
	context.monetization = MonetizationSeam
end

return MonetizationService
