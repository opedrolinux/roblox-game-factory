--!strict
-- core/src/server/services/sample/SampleService.luau   [SAMPLE — deletable; Lune-clean]
-- A thin Start() that only REGISTERS the sample action. Lune-clean: it touches no Roblox
-- global; `register` is called via context.net, never a sibling require. new-game deletes this.
-- See docs/CORE-DESIGN.md §8.
local SampleAction = require("./SampleAction")

local SampleService = { name = "SampleService" }

function SampleService:Start(context: any): ()
	context.net:register(SampleAction)
end

return SampleService
