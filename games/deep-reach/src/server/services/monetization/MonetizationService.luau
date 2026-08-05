--!strict
-- games/deep-reach/src/server/services/monetization/MonetizationService.luau   [contract pass — STUB]
--
-- THIS IS A STUB, and it is the one stub with NO action to register: contract.stubs.monetization
-- declares `actions: []`, because monetization adds no client action AT ALL. Gamepass prompts are
-- client-initiated MarketplaceService calls, and product grants are server-driven through
-- ProcessReceipt — never a client request crossing the gateway. Registering an action here would
-- invent wire surface the contract deliberately does not name, and it would be a client-callable
-- path into a real-money grant.
--
-- It exists as a registered service anyway so the SLOT is real before fan-out: the monetization
-- builder REPLACES this file with the authoritative ProcessReceipt (idempotent through the receipts
-- ledger, refusing to acknowledge under ctx.persistenceDegraded), the gamepass flag grants, the 2x
-- boost expiry write and the `purchase` emits — and does so without having to touch the bootstrap
-- registry that eight other builders are also appending to.
--
-- Provides NO ctx seam (contract.stubs.monetization.seamProvided is null). In particular it does NOT
-- assign context.monetization: that is the pre-existing [B2] seam, and the contract's newCtxSeams are
-- exactly economy / plot / salvage / depth.
--
-- Requires NOTHING: with no action to register there is no Net or Result to reach, so this file
-- needs no D1 cross-mount shim at all.

local MonetizationService = {}
MonetizationService.name = "MonetizationService"

-- Start: intentionally a no-op. No action, no seam, no event connection — the real service hooks
-- MarketplaceService.ProcessReceipt and the gamepass signals here.
function MonetizationService.Start(_self: any, _context: any): () end

return MonetizationService
