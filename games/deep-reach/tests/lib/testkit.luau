--!strict
-- core/tests/lib/testkit.luau
-- describe/it/expect + the JSON reporter's data source. State is per-require: the runner
-- requires this ONCE per process, every spec requires the SAME instance (Lune caches modules),
-- registers its describe/it, then the runner calls run() and prints exactly one JSON line.
-- run() RETURNS the summary; it does NOT print (the runner prints). See §7.1.
local Assert = require("./assert")

-- --- registry state (per-require) ---
type Case = {
	name: string,
	body: () -> (),
}

local suites: { { name: string, cases: { Case } } } = {}
local currentSuite: { name: string, cases: { Case } }? = nil
local loadFailures: { { path: string, err: string } } = {}

local TestKit = {}

function TestKit.describe(name: string, body: () -> ()): ()
	local suite = { name = name, cases = {} }
	table.insert(suites, suite)
	local previous = currentSuite
	currentSuite = suite
	body()
	currentSuite = previous
end

function TestKit.it(name: string, body: () -> ()): ()
	local suite = currentSuite
	if suite == nil then
		-- it() outside a describe: attach to a synthetic top-level suite.
		suite = { name = "(top-level)", cases = {} }
		table.insert(suites, suite)
		currentSuite = suite
	end
	table.insert(suite.cases, { name = name, body = body })
end

-- The expectation object. Each method raises a readable error on mismatch (caught by run()).
export type Expectation = {
	toBe: (self: any, expected: any) -> (),
	toEqual: (self: any, expected: any) -> (),
	toBeOk: (self: any) -> (),
	toBeErr: (self: any, code: string?) -> (),
	toThrow: (self: any) -> (),
	never: any,
}

local function makeExpectation(value: any, negated: boolean): any
	local exp = {}

	local function check(condition: boolean, message: string): ()
		local pass = condition
		if negated then
			pass = not pass
		end
		if not pass then
			local prefix = negated and "expected NOT: " or "expected: "
			Assert.fail(prefix .. message)
		end
	end

	function exp.toBe(_: any, expected: any): ()
		check(value == expected, `{Assert.render(value)} === {Assert.render(expected)}`)
	end

	function exp.toEqual(_: any, expected: any): ()
		check(
			Assert.deepEqual(value, expected),
			`{Assert.render(value)} deepEquals {Assert.render(expected)}`
		)
	end

	function exp.toBeOk(_: any): ()
		check(Assert.isResultOk(value), `Result.ok, got {Assert.render(value)}`)
	end

	function exp.toBeErr(_: any, code: string?): ()
		check(
			Assert.isResultErr(value, code),
			`Result.err({tostring(code)}), got {Assert.render(value)}`
		)
	end

	function exp.toThrow(_: any): ()
		-- value is expected to be a function; calling it should error.
		local ok = pcall(value)
		check(not ok, `function to throw`)
	end

	exp.never = nil
	if not negated then
		exp.never = makeExpectation(value, true)
	end

	return exp
end

function TestKit.expect(value: any): any
	return makeExpectation(value, false)
end

-- Register a synthetic failing case for a require-time load error (runner calls this — §7.4).
function TestKit.recordLoadFailure(path: string, err: string): ()
	table.insert(loadFailures, { path = path, err = err })
end

-- Runs every registered case, collects results, RETURNS the summary. Each case body is pcall'd
-- so one failing assertion never aborts the run. Does NOT print.
function TestKit.run(): { passed: number, failed: number, total: number, failures: { string } }
	local passed = 0
	local failed = 0
	local failures: { string } = {}

	-- Surface require-time load failures first (as failing cases).
	for _, lf in loadFailures do
		failed += 1
		table.insert(failures, `LOAD {lf.path}: {lf.err}`)
	end

	for _, suite in suites do
		for _, case in suite.cases do
			local ok, err = pcall(case.body)
			if ok then
				passed += 1
			else
				failed += 1
				table.insert(failures, `{suite.name} > {case.name}: {tostring(err)}`)
			end
		end
	end

	return {
		passed = passed,
		failed = failed,
		total = passed + failed,
		failures = failures,
	}
end

return TestKit
