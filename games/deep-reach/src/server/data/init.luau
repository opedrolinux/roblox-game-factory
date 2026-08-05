--!strict
-- core/src/server/data/init.luau
-- Data folder barrel. Uses the D1 require-shim so it loads under both Lune and Roblox.
-- (At runtime this makes the `data` folder become this module; its siblings are children.)
-- See docs/CORE-DESIGN.md §1.

local Store, MockStore, Clock, DataService
if script == nil then
	-- Lune: inside an `init.luau`, `./` resolves relative to the init dir's PARENT, so a sibling
	-- of this init file is `./data/<Name>` (this folder IS `data`). Verified on lune 0.10.4. This
	-- barrel runs only at the Roblox runtime; the Lune branch is kept correct for safety.
	Store = require("./data/Store")
	MockStore = require("./data/MockStore")
	Clock = require("./data/Clock")
	DataService = require("./data/DataService")
else
	local here = script :: any
	Store = require(here.Store)
	MockStore = require(here.MockStore)
	Clock = require(here.Clock)
	DataService = require(here.DataService)
end

return {
	Store = Store,
	MockStore = MockStore,
	Clock = Clock,
	DataService = DataService,
}
