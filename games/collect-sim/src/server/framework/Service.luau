--!strict
-- core/src/server/framework/Service.luau
-- A service is a module returning a table with a single Start(context). It resolves every
-- collaborator from `context` and NEVER require()s a sibling service (that causes load-order
-- cycles). Thin type + identity helper, no runtime magic. Lune-clean (no requires).
-- See docs/CORE-DESIGN.md §2.1.

export type Service = {
	-- Stable name used for diagnostics and (optionally) context lookup. Required.
	name: string,
	-- Called once, in bootstrap order, with the fully-built context.
	-- May yield. MUST NOT require sibling services; pull them from `context`.
	Start: (self: any, context: any) -> (),
	-- Optional: cleanup on shutdown / BindToClose. Bootstrap calls in REVERSE order.
	Stop: ((self: any, context: any) -> ())?,
}

local Service = {}

-- Identity helper: lets a module assert its own shape at author time.
function Service.define(def: Service): Service
	return def
end

return Service
