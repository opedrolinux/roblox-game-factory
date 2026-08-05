--!strict
-- core/src/client/framework/Controller.luau
-- A controller is the client mirror of Service: a module returning a table with a single
-- Start(context). It resolves collaborators from `context`, never require()s a sibling
-- controller. Thin type + identity helper. Lune-clean (no requires). See §2.1.

export type Controller = {
	name: string,
	Start: (self: any, context: any) -> (),
	Stop: ((self: any, context: any) -> ())?,
}

local Controller = {}

function Controller.define(def: Controller): Controller
	return def
end

return Controller
