--!strict
-- merge.luau — decide whether a built feature branch may auto-merge or must be PARKED for review.
-- Pure: the git operations (the actual merge onto staging) live in the build-features workflow; this
-- module is the deterministic *policy* behind that decision, unit-tested like the fence.
--
-- How the factory stays collision-free: the serial contract pass writes ALL shared deltas up front —
-- Net actions, Types fields, Migrations, and the test registry (tests/run.luau) — so a well-behaved
-- feature only ADDS its own disjoint files: a server service, an optional client controller, and its
-- test. This classifier enforces that boundary. A branch whose diff stays inside feature territory
-- MERGEs; a branch that touched the shared contract, the spine, or any config (the serial owner's
-- territory — including the un-unionable Migrations/schema-version) is PARKED for a human, never
-- silently merged. "Allowlist what's safe, park the rest" — the same discipline as the fence.

local M = {}

export type Action = "merge" | "park"
export type Decision = { action: Action, offending: { string }, reason: string }

-- The ONLY paths a feature branch may add/modify (game-relative). Everything else parks.
local MERGE_PREFIXES = {
	"src/server/services/",
	"src/client/controllers/",
	"tests/unit/",
}

local function isMergeable(path: string): boolean
	local p = string.gsub(path, "\\", "/")
	for _, prefix in MERGE_PREFIXES do
		if string.sub(p, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- `changedPaths` are the branch's changed files RELATIVE TO THE GAME ROOT (the caller strips the
-- `games/<slug>/` prefix from `git diff --name-only`).
function M.classify(changedPaths: { string }): Decision
	if #changedPaths == 0 then
		return {
			action = "park",
			offending = {},
			reason = "branch has no changes — nothing was built",
		}
	end
	local offending: { string } = {}
	for _, path in changedPaths do
		if not isMergeable(path) then
			table.insert(offending, path)
		end
	end
	if #offending > 0 then
		return {
			action = "park",
			offending = offending,
			reason = "branch touched shared-contract / spine / config files (serial-owner territory); "
				.. "a feature may only add under src/server/services/, src/client/controllers/, tests/unit/",
		}
	end
	return { action = "merge", offending = {}, reason = "all changes are disjoint feature files" }
end

return M
