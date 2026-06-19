--!strict
-- merge_spec.luau — corpus for the merge classifier: path-sets that MUST merge vs MUST park.
-- Same discipline as the fence corpus — a "merge" row that parks blocks real work; a "park" row
-- that merges lets a feature corrupt the shared contract. Driven by tests/run.luau.

local merge = require("../merge")

return function(): (number, { string })
	local failures: { string } = {}
	local checks = 0
	local function expect(paths: { string }, want: merge.Action, note: string)
		checks += 1
		local got = merge.classify(paths).action
		if got ~= want then
			table.insert(failures, string.format("%s: classify -> %s, want %s", note, got, want))
		end
	end

	-- ── MERGE: only disjoint feature files ───────────────────────────────────
	expect({ "src/server/services/shop/ShopService.luau" }, "merge", "a server service")
	expect({
		"src/server/services/shop/ShopService.luau",
		"src/server/services/shop/ShopAction.luau",
		"src/client/controllers/shop/ShopController.luau",
		"tests/unit/shop.spec.luau",
	}, "merge", "service + action + controller + spec (a whole feature)")
	expect(
		{ "src/client/controllers/rebirth/RebirthController.luau" },
		"merge",
		"a client controller"
	)
	expect({ "tests/unit/offline.spec.luau" }, "merge", "a feature spec only")
	expect(
		{ "src\\server\\services\\shop\\ShopService.luau" },
		"merge",
		"backslash path normalizes"
	)

	-- ── PARK: any touch of the shared contract / spine / config ──────────────
	expect({ "src/shared/Net.luau" }, "park", "the action registry")
	expect({ "src/shared/Types.luau" }, "park", "the player-data shape")
	expect({ "src/shared/Config.luau" }, "park", "config")
	expect({ "src/shared/Migrations.luau" }, "park", "sequenced migrations (un-unionable)")
	expect({ "tests/run.luau" }, "park", "the test registry")
	expect({ "tests/lib/testkit.luau" }, "park", "shared test infra")
	expect({ "default.project.json" }, "park", "the rojo project")
	expect({ "wally.toml" }, "park", "the package manifest")
	expect({ "selene.toml" }, "park", "lint config")
	expect({ "src/server/framework/Service.luau" }, "park", "the service framework (spine)")
	expect({ "src/server/data/DataService.luau" }, "park", "the data layer (spine)")
	expect({ "src/server/net/NetServer.luau" }, "park", "the net gateway (spine)")
	expect({ "src/server/security/Gate.luau" }, "park", "security (spine)")
	expect({ "src/server/init.server.luau" }, "park", "the server bootstrap")
	expect({ "src/server/Context.luau" }, "park", "the server context (spine)")
	expect({ "CLAUDE.md" }, "park", "the engineering contract")

	-- ── PARK: mixed (one bad path among good ones) + empty ───────────────────
	expect({
		"src/server/services/shop/ShopService.luau",
		"src/shared/Types.luau",
	}, "park", "feature file + a shared edit still parks")
	expect({}, "park", "no changes")

	return checks, failures
end
