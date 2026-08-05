--!strict
-- core/tests/lib/assert.luau
-- Pure assertion primitives used by testkit. No Roblox globals. Failures raise a Lua error with
-- a readable message; `it` catches it and records a failure so one bad assertion never aborts
-- the run. See docs/CORE-DESIGN.md §7.2.

local Assert = {}

-- Deep structural equality (tables compared recursively; other types by ==).
function Assert.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	-- every key in a matches b
	for key, valueA in a do
		if not Assert.deepEqual(valueA, b[key]) then
			return false
		end
	end
	-- every key in b exists in a (catch extra keys)
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function render(value: any): string
	if type(value) == "table" then
		local parts = {}
		for k, v in value do
			table.insert(parts, `{tostring(k)}={tostring(v)}`)
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(value)
end

function Assert.isResultOk(result: any): boolean
	return type(result) == "table" and result.ok == true
end

function Assert.isResultErr(result: any, code: string?): boolean
	if type(result) ~= "table" or result.ok ~= false then
		return false
	end
	if code ~= nil then
		return result.code == code
	end
	return true
end

function Assert.approx(a: number, b: number, epsilon: number?): boolean
	local e = epsilon or 1e-6
	return math.abs(a - b) <= e
end

-- raise(message): a single place to throw a readable assertion failure.
function Assert.fail(message: string): ()
	error(message, 0)
end

Assert.render = render

return Assert
