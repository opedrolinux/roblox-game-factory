--!strict
-- core/src/shared/init.luau
-- Shared barrel: exposes Types, Net, Config, Result (+ Migrations) as one module so
-- ReplicatedStorage.Shared can be required directly. Uses the D1 require-shim so it loads
-- under both Lune and the Roblox runtime. See docs/CORE-DESIGN.md §1.

local Result, Types, Net, Config, Migrations
if script == nil then
	-- Lune: relative paths. NOTE (verified on lune 0.10.4): inside an `init.luau`, `./` resolves
	-- relative to the init dir's PARENT, so a sibling of this init file is `./shared/<Name>` (this
	-- folder IS `shared`). This barrel is exercised only at the Roblox runtime; the Lune branch is
	-- kept correct so a future Lune require of the barrel resolves rather than crashes.
	Result = require("./shared/Result")
	Types = require("./shared/Types")
	Net = require("./shared/Net")
	Config = require("./shared/Config")
	Migrations = require("./shared/Migrations")
else
	-- Roblox runtime: instance requires (the dead branch under Lune).
	local here = script :: any
	Result = require(here.Result)
	Types = require(here.Types)
	Net = require(here.Net)
	Config = require(here.Config)
	Migrations = require(here.Migrations)
end

return {
	Result = Result,
	Types = Types,
	Net = Net,
	Config = Config,
	Migrations = Migrations,
}
