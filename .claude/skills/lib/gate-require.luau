--!strict
-- gate-require.luau — T0.5 static require-resolution gate (the rung BETWEEN `rojo build` and Lune).
--
-- WHY THIS EXISTS. The gauntlet's four stages (stylua · selene · rojo build · lune) prove the game
-- formats, lints, compiles to a place, and passes its logic UNDER LUNE — but none of them resolve a
-- require against the Roblox DataModel. `rojo build` only serializes src/ to a .rbxlx; it never runs a
-- require. The Lune tests always take the `script == nil` branch of every D1 shim, so the Roblox
-- INSTANCE-require branch — the branch that actually runs in production — is the dead branch no gate
-- executes. A bare relative require that CROSSES a Rojo service boundary (src/shared → ReplicatedStorage,
-- src/server → ServerScriptService — different top-level services, no common ../ ancestor) therefore
-- resolves on Lune's filesystem yet THROWS at the first require in Roblox, killing the server before any
-- Start. collect-sim shipped 313/313 Lune-green and did not boot in Roblox for exactly this reason.
--
-- WHAT IT DOES. Reads default.project.json into a filesystem→DataModel mount table, maps every src/
-- module to its DataModel path (with the init.luau folder-collapse + the init `./<folder>/<Name>`
-- quirk), and for every STATIC STRING-LITERAL require: resolves it, FAILs when it crosses a service
-- boundary WITHOUT a `if script == nil` shim (the showstopper), and FAILs when it resolves to a module
-- that does not exist. It also pairs the two branches of each D1 shim by variable name and FAILs on a
-- leaf-name mismatch (branch drift — the Roblox branch naming a different module than the Lune branch,
-- which no test can catch because the instance branch never runs under Lune). Dynamic / non-relative
-- requires are a WARN, never a hard fail — static analysis cannot follow them.
--
-- HOW IT PARSES (hardened after an adversarial review found the naive line-scan full of holes):
--  • a STRING/COMMENT MASKER blanks the contents of every string literal (', ", and [[ ]] long
--    brackets) and every comment (-- line and --[[ ]] block) to spaces, preserving newlines and the
--    literal delimiters. So a `require(...)` that appears INSIDE a string or comment is never scanned
--    as live code, and a `--` inside a string never truncates the line. The real string content is
--    kept in a side table so static paths are still recoverable.
--  • require calls are found on the MASKED text: the parenthesized `require(...)` form via balanced
--    parens (so a require whose argument stylua wrapped onto the next line is still seen), AND the
--    paren-less Luau call forms `require "..."` / `require [[...]]`. The previous line-by-line scan
--    missed the wrapped form, and a paren-only scan missed the paren-less form.
--  • shim regions are found with a NESTING-AWARE keyword-depth scan: the `then`-branch of an
--    `if script == nil then` ends at its matching `else`/`elseif`/`end` at depth 0, so a one-line or
--    self-closing shim does not leak "in-shim" to the rest of the file, a nested if/for/do inside the
--    branch does not prematurely close it, and an `elseif` (a live Roblox branch) is NOT treated as the
--    Lune branch.
--
-- KNOWN LIMITS (documented, low-risk): drift pairing reads the single variable immediately before
-- `=`, so a multi-target line `a, b = require(...), require(...)` may mis-label which leaf drifted
-- (the per-require cross-service check is unaffected); drift only pairs a Roblox branch that is a real
-- `require(...)` call (the production idiom), not a bare field-access assignment `M = X.Y`; a require
-- with a `..` chain that climbs above src/ reports "no module" rather than "crosses boundary" (still a
-- FAIL); the "Lune-clean comment" smell WARN from docs/VERIFICATION-LADDER.md §3.3 step 8 is deferred
-- (the bare-cross-service FAIL already covers the load-bearing case).
--
-- Pure static analysis: no Roblox, no Studio, no network, milliseconds. Invoked IN-PROCESS by
-- gauntlet.luau as a fifth Stage (it returns the same {name,ok,output} shape). Standalone for testing:
--   GATE_REQUIRE_CLI=1 lune run .claude/skills/lib/gate-require.luau <gameDir>

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")

export type Stage = { name: string, ok: boolean, output: string }

type Mount = { fsDir: string, dmSegs: { string }, serviceRoot: string }
type Finding = { level: string, file: string, line: number, msg: string }
type Span = { a: number, b: number, content: string }

local GateRequire = {}

-- ── small helpers ─────────────────────────────────────────────────────────────
local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) :: string
end

local function isBlank(s: string): boolean
	return string.match(s, "^%s*$") ~= nil
end

local function segsOf(p: string): { string }
	local out: { string } = {}
	for s in string.gmatch(p, "[^/]+") do
		table.insert(out, s)
	end
	return out
end

local function joinSegs(s: { string }): string
	return table.concat(s, "/")
end

local function stripExt(name: string): string
	return (string.gsub(name, "%.luau$", ""))
end

local function isInitName(noExt: string): boolean
	return noExt == "init" or noExt == "init.server" or noExt == "init.client"
end

local function baseNameNoExt(fileRel: string): string
	local s = segsOf(fileRel)
	return stripExt(s[#s])
end

-- ── mount table from default.project.json ─────────────────────────────────────
-- Walk the Rojo `tree`, tracking the DataModel ancestry (keys, skipping `$`-prefixed). Any node with
-- a string `$path` is a filesystem mount; its serviceRoot is the FIRST DataModel segment (the
-- top-level service the boundary test compares).
local function buildMounts(project: any): { Mount }
	local mounts: { Mount } = {}
	local function walk(node: any, path: { string })
		if type(node) ~= "table" then
			return
		end
		local pathVal = node["$path"]
		if type(pathVal) == "string" and #path > 0 then
			table.insert(mounts, {
				fsDir = (string.gsub(pathVal, "\\", "/")),
				dmSegs = table.clone(path),
				serviceRoot = path[1],
			})
		end
		for k, v in node do
			if type(k) == "string" and string.sub(k, 1, 1) ~= "$" then
				local nextPath = table.clone(path)
				table.insert(nextPath, k)
				walk(v, nextPath)
			end
		end
	end
	if type(project) == "table" then
		walk(project.tree, {})
	end
	return mounts
end

-- The mount whose fsDir is the LONGEST segment-prefix of fileRel (most specific wins).
local function mountFor(mounts: { Mount }, fileRel: string): Mount?
	local fseg = segsOf(fileRel)
	local best: Mount? = nil
	local bestLen = -1
	for _, m in mounts do
		local mseg = segsOf(m.fsDir)
		if #mseg <= #fseg and #mseg > bestLen then
			local match = true
			for i = 1, #mseg do
				if mseg[i] ~= fseg[i] then
					match = false
					break
				end
			end
			if match then
				best = m
				bestLen = #mseg
			end
		end
	end
	return best
end

local function serviceRootOf(mounts: { Mount }, fileRel: string): string?
	local m = mountFor(mounts, fileRel)
	return if m ~= nil then m.serviceRoot else nil
end

-- file (relative to gameDir) → DataModel segments, applying the init.luau folder-collapse:
-- src/shared/init.luau → ReplicatedStorage.Shared ; src/server/data/init.luau → …Server.data.
local function fileToDm(mounts: { Mount }, fileRel: string): { string }?
	local m = mountFor(mounts, fileRel)
	if m == nil then
		return nil
	end
	local fseg = segsOf(fileRel)
	local mseg = segsOf(m.fsDir)
	local suffix: { string } = {}
	for i = #mseg + 1, #fseg do
		table.insert(suffix, fseg[i])
	end
	if #suffix == 0 then
		return table.clone(m.dmSegs)
	end
	local fname = stripExt(suffix[#suffix])
	suffix[#suffix] = fname
	if isInitName(fname) then
		table.remove(suffix) -- the folder collapses INTO the init module; drop the `init` leaf
	end
	local dm = table.clone(m.dmSegs)
	for _, s in suffix do
		table.insert(dm, s)
	end
	return dm
end

-- ── string-require resolution ─────────────────────────────────────────────────
-- Resolve a relative string require to a target path (no extension), relative to gameDir. Encodes the
-- init quirk: inside an init.luau, `./` resolves against the init dir's PARENT, so a sibling of the
-- init file is `./<folder>/<Name>`.
local function resolveStringRequire(sourceRel: string, req: string): string?
	local dir = segsOf(sourceRel)
	table.remove(dir) -- drop the filename → the source directory
	if isInitName(baseNameNoExt(sourceRel)) then
		table.remove(dir) -- init: base is the PARENT of the init directory
	end
	local cur = table.clone(dir)
	for _, part in segsOf(req) do
		if part == "." then
			-- same directory; no-op
		elseif part == ".." then
			if #cur > 0 then
				table.remove(cur)
			end
		else
			table.insert(cur, part)
		end
	end
	if #cur == 0 then
		return nil
	end
	return joinSegs(cur)
end

-- A resolved target (no ext) is a real module if <t>.luau or <t>/init*.luau exists.
local function targetExists(gameDir: string, targetNoExt: string): boolean
	local b = gameDir .. "/" .. targetNoExt
	return fs.isFile(b .. ".luau")
		or fs.isFile(b .. "/init.luau")
		or fs.isFile(b .. "/init.server.luau")
		or fs.isFile(b .. "/init.client.luau")
end

-- The required-module leaf of a relative path ("../shared/Net" → "Net").
local function pathLeaf(req: string): string?
	local s = segsOf(req)
	return s[#s]
end

-- The leaf of an instance-require expression: the last dotted identifier
-- (`(s :: any).Parent.Net` → Net, `here.Result` → Result), else the trailing bare identifier.
local function exprLeaf(expr: string): string?
	local leaf: string? = nil
	for id in string.gmatch(expr, "%.([%a_][%w_]*)") do
		leaf = id
	end
	if leaf == nil then
		leaf = string.match(expr, "([%a_][%w_]*)%s*$")
	end
	return leaf
end

-- ── recursive glob of src/**/*.luau (relative to gameDir) ─────────────────────
local function listLuau(gameDir: string, relDir: string, acc: { string })
	local full = gameDir .. "/" .. relDir
	if not fs.isDir(full) then
		return
	end
	for _, entry in fs.readDir(full) do
		local childRel = relDir .. "/" .. entry
		if fs.isDir(gameDir .. "/" .. childRel) then
			listLuau(gameDir, childRel, acc)
		elseif string.match(entry, "%.luau$") then
			table.insert(acc, childRel)
		end
	end
end

-- ── string/comment masker ─────────────────────────────────────────────────────
-- Returns (masked, spans): `masked` is `text` with the CONTENT of every string literal and comment
-- replaced by spaces (newlines + string delimiters preserved), so live code is what's left; `spans`
-- lists each string literal's char range + decoded content (for recovering static require paths).
local function maskAndSpans(text: string): (string, { Span })
	local n = #text
	local chars: { string } = {}
	for i = 1, n do
		chars[i] = string.sub(text, i, i)
	end
	local spans: { Span } = {}

	-- If text[pos] opens a long bracket ([[ or [=*[), return (eqCount, posAfterOpen); else nil.
	local function longOpenAt(pos: number): (number?, number?)
		if string.sub(text, pos, pos) ~= "[" then
			return nil, nil
		end
		local j = pos + 1
		local eq = 0
		while string.sub(text, j, j) == "=" do
			eq += 1
			j += 1
		end
		if string.sub(text, j, j) == "[" then
			return eq, j + 1
		end
		return nil, nil
	end

	local function blankRange(a: number, b: number)
		for k = a, b do
			if chars[k] ~= "\n" then
				chars[k] = " "
			end
		end
	end

	local i = 1
	while i <= n do
		local c = chars[i]
		local nxt = string.sub(text, i + 1, i + 1)
		if c == "-" and nxt == "-" then
			local eq, after = longOpenAt(i + 2)
			if eq ~= nil then
				-- block comment --[=*[ … ]=*]
				local close = "]" .. string.rep("=", eq) .. "]"
				local endStart = string.find(text, close, after :: number, true)
				local stop = if endStart ~= nil then endStart + #close - 1 else n
				blankRange(i, stop)
				i = stop + 1
			else
				-- line comment to EOL
				local k = i
				while k <= n and chars[k] ~= "\n" do
					chars[k] = " "
					k += 1
				end
				i = k
			end
		elseif c == '"' or c == "'" then
			-- quoted string (keep delimiters, blank content)
			local startPos = i
			local content: { string } = {}
			local k = i + 1
			while k <= n do
				local ck = string.sub(text, k, k)
				if ck == "\\" then
					chars[k] = " "
					if k + 1 <= n then
						chars[k + 1] = if string.sub(text, k + 1, k + 1) == "\n" then "\n" else " "
						table.insert(content, string.sub(text, k + 1, k + 1))
					end
					k += 2
				elseif ck == c or ck == "\n" then
					break
				else
					chars[k] = " "
					table.insert(content, ck)
					k += 1
				end
			end
			table.insert(spans, { a = startPos, b = k, content = table.concat(content) })
			i = k + 1
		else
			local eq, after = longOpenAt(i)
			if eq ~= nil then
				local close = "]" .. string.rep("=", eq) .. "]"
				local endStart = string.find(text, close, after :: number, true)
				local contentEnd = if endStart ~= nil then endStart - 1 else n
				local content = string.sub(text, after :: number, contentEnd)
				blankRange(after :: number, contentEnd)
				local stop = if endStart ~= nil then endStart + #close - 1 else n
				table.insert(spans, { a = i, b = stop, content = content })
				i = stop + 1
			else
				i += 1
			end
		end
	end

	return table.concat(chars), spans
end

-- ── per-file scan ─────────────────────────────────────────────────────────────
local function scanFile(gameDir: string, mounts: { Mount }, fileRel: string, findings: { Finding })
	local ok, rawText = pcall(fs.readFile, gameDir .. "/" .. fileRel)
	if not ok or type(rawText) ~= "string" then
		return
	end
	local text = rawText :: string
	local srcRoot = serviceRootOf(mounts, fileRel)
	local masked, spans = maskAndSpans(text)
	local n = #masked

	-- line-start char positions (for line numbers + the variable-before-require lookup)
	local lineStarts: { number } = { 1 }
	for i = 1, n do
		if string.sub(masked, i, i) == "\n" then
			table.insert(lineStarts, i + 1)
		end
	end
	local function lineOf(pos: number): number
		local found = 1
		for i = #lineStarts, 1, -1 do
			if lineStarts[i] <= pos then
				found = i
				break
			end
		end
		return found
	end

	-- Lune-branch char regions: the `then`-branch of each `if script == nil then`, ending at its
	-- matching else/elseif/end at depth 0 (nesting-aware, computed on the masked text).
	type Region = { a: number, b: number }
	local regions: { Region } = {}
	do
		local from = 1
		while true do
			local s, e = string.find(masked, "if%s+script%s*==%s*nil%s+then", from)
			if s == nil then
				break
			end
			local afterThen = (e :: number) + 1
			local depth = 0
			local expectDo = false
			local regionEnd = n + 1
			local p = afterThen
			while true do
				local ws, we, word = string.find(masked, "([%a_][%w_]+)", p)
				if ws == nil then
					break
				end
				p = (we :: number) + 1
				if word == "for" or word == "while" then
					depth += 1
					expectDo = true
				elseif word == "do" then
					if expectDo then
						expectDo = false
					else
						depth += 1
					end
				elseif word == "if" or word == "function" or word == "repeat" then
					depth += 1
				elseif word == "end" or word == "until" then
					if depth == 0 then
						regionEnd = ws :: number
						break
					end
					depth -= 1
				elseif word == "else" or word == "elseif" then
					if depth == 0 then
						regionEnd = ws :: number
						break
					end
				end
			end
			table.insert(regions, { a = afterThen, b = regionEnd })
			from = (e :: number) + 1
		end
	end
	local function inLune(pos: number): boolean
		for _, r in regions do
			if pos >= r.a and pos < r.b then
				return true
			end
		end
		return false
	end

	-- drift bookkeeping (variable → required-module leaf, per branch)
	local luneLeaf: { [string]: string } = {}
	local robloxLeaf: { [string]: string } = {}
	local luneLine: { [string]: number } = {}

	-- iterate every live require call on the masked text: parenthesized `require(...)` (balanced
	-- parens, multi-line aware) AND the paren-less call forms `require "..."` / `require [[...]]`
	-- (valid Luau — a call with a single string-literal argument and no parens).
	local p = 1
	while true do
		local rs, re = string.find(masked, "require", p, true)
		if rs == nil then
			break
		end
		p = (re :: number) + 1
		-- `require` must be its own identifier (not `myrequire` / `requireFoo`).
		local beforeCh = if (rs :: number) > 1
			then string.sub(masked, (rs :: number) - 1, (rs :: number) - 1)
			else " "
		local afterCh = string.sub(masked, (re :: number) + 1, (re :: number) + 1)
		if string.match(beforeCh, "[%w_]") or string.match(afterCh, "[%w_]") then
			continue
		end
		-- first non-space token after `require`
		local q = (re :: number) + 1
		while q <= n and string.match(string.sub(masked, q, q), "%s") do
			q += 1
		end
		local nextc = string.sub(masked, q, q)
		local innerA, innerB = 0, 0
		if nextc == "(" then
			local ps, pe = string.find(masked, "%b()", q)
			if ps == nil then
				continue -- unbalanced; not a resolvable call
			end
			innerA = (ps :: number) + 1
			innerB = (pe :: number) - 1
			p = (pe :: number) + 1
		else
			-- paren-less: the argument must be a single string literal whose span starts at q.
			local sp: Span? = nil
			for _, candidate in spans do
				if candidate.a == q then
					sp = candidate
					break
				end
			end
			if sp == nil then
				continue -- `require` used as a value, or a non-string paren-less argument
			end
			innerA = (sp :: Span).a
			innerB = (sp :: Span).b
			p = (sp :: Span).b + 1
		end

		local s = rs :: number -- the `require` keyword position (for line + shim-region checks)
		local line = lineOf(s)
		local beforeText = string.sub(text, lineStarts[line], s - 1)
		local var = string.match(beforeText, "([%a_][%w_]*)%s*=%s*$")

		-- string literals fully inside the require parens
		local contained: { Span } = {}
		for _, sp in spans do
			if sp.a >= innerA and sp.b <= innerB then
				table.insert(contained, sp)
			end
		end

		-- Does the argument EXPRESSION begin with a string literal? Only then is a non-pure string a
		-- dynamic path concat (e.g. `"../x/" .. name`). A string that is merely a nested CALL argument
		-- (e.g. `game:GetService("ReplicatedStorage")…`) starts with an identifier → it is an instance
		-- require, not a dynamic string require, and must NOT be warned.
		local firstNB: number? = nil
		for k = innerA, innerB do
			if string.match(string.sub(masked, k, k), "%S") then
				firstNB = k
				break
			end
		end
		local startsWithString = false
		for _, sp in contained do
			if sp.a == firstNB then
				startsWithString = true
				break
			end
		end

		local pureStr: string? = nil
		if #contained == 1 then
			local sp = contained[1]
			if
				isBlank(string.sub(masked, innerA, sp.a - 1))
				and isBlank(string.sub(masked, sp.b + 1, innerB))
			then
				pureStr = sp.content
			end
		end

		if pureStr ~= nil then
			local path = pureStr :: string
			local head = string.sub(path, 1, 1)
			if head == "@" then
				-- Lune builtin alias (@lune/…); never shipped to Roblox. Ignore.
			elseif head ~= "." then
				findings[#findings + 1] = {
					level = "WARN",
					file = fileRel,
					line = line,
					msg = string.format(
						"non-relative string require %q — cannot resolve statically.",
						path
					),
				}
			else
				local target = resolveStringRequire(fileRel, path)
				if target == nil then
					findings[#findings + 1] = {
						level = "WARN",
						file = fileRel,
						line = line,
						msg = string.format("could not resolve require %q.", path),
					}
				elseif not targetExists(gameDir, target) then
					findings[#findings + 1] = {
						level = "FAIL",
						file = fileRel,
						line = line,
						msg = string.format(
							"require %q resolves to %q which has no module (.luau / init.luau).",
							path,
							target .. ".luau"
						),
					}
				else
					local tgtRoot = serviceRootOf(mounts, target)
					if var ~= nil and inLune(s :: number) then
						luneLeaf[var] = pathLeaf(path) or path
						luneLine[var] = line
					end
					if tgtRoot == nil then
						findings[#findings + 1] = {
							level = "WARN",
							file = fileRel,
							line = line,
							msg = string.format(
								"require %q resolves outside any Rojo mount (%q).",
								path,
								target
							),
						}
					elseif srcRoot ~= nil and tgtRoot ~= srcRoot and not inLune(s :: number) then
						findings[#findings + 1] = {
							level = "FAIL",
							file = fileRel,
							line = line,
							msg = string.format(
								"require %q crosses %s → %s but is NOT inside an `if script == nil` shim — "
									.. "resolves under Lune, THROWS at Roblox boot. Use the D1 shim (Lune string "
									.. "branch + Roblox instance require from %s).",
								path,
								srcRoot,
								tgtRoot,
								joinSegs((fileToDm(mounts, target) or {}))
							),
						}
					end
				end
			end
		elseif startsWithString then
			-- the expression BEGINS with a string literal but is not a pure literal → dynamic path
			-- concat (e.g. `"../x/" .. name`); cannot resolve statically.
			findings[#findings + 1] = {
				level = "WARN",
				file = fileRel,
				line = line,
				msg = "dynamic require (string literal is part of a larger expression) — cannot resolve statically.",
			}
		else
			-- instance / identifier require → only used to pair the Roblox branch for the drift check.
			local leaf = exprLeaf(trim(string.sub(text, innerA, innerB)))
			if var ~= nil and leaf ~= nil and leaf ~= "any" then
				robloxLeaf[var] = leaf
			end
		end
	end

	-- drift: a variable whose Lune (string) branch and Roblox (instance) branch name DIFFERENT modules.
	for var, lLeaf in luneLeaf do
		local rLeaf = robloxLeaf[var]
		if rLeaf ~= nil and rLeaf ~= lLeaf then
			findings[#findings + 1] = {
				level = "FAIL",
				file = fileRel,
				line = luneLine[var] or 0,
				msg = string.format(
					"D1 shim drift: `%s` requires %q under Lune but the Roblox branch requires `…%s` — "
						.. "the branches name different modules; the Roblox (production) branch is untested.",
					var,
					lLeaf,
					rLeaf
				),
			}
		end
	end
end

-- ── public entry ──────────────────────────────────────────────────────────────
function GateRequire.run(gameDir: string): Stage
	local out: { string } = {}
	local function emit(s: string)
		table.insert(out, s)
	end

	local projPath = gameDir .. "/default.project.json"
	if not fs.isFile(projPath) then
		return {
			name = "require",
			ok = false,
			output = string.format(
				"[require-resolve] no default.project.json in %q — cannot map requires.",
				gameDir
			),
		}
	end
	local decodeOk, project = pcall(function()
		return serde.decode("json", fs.readFile(projPath))
	end)
	if not decodeOk then
		return {
			name = "require",
			ok = false,
			output = "[require-resolve] could not parse default.project.json: "
				.. tostring(project),
		}
	end

	local mounts = buildMounts(project)
	if #mounts == 0 then
		return {
			name = "require",
			ok = false,
			output = "[require-resolve] default.project.json declares no $path mounts — nothing to check.",
		}
	end

	local files: { string } = {}
	listLuau(gameDir, "src", files)
	table.sort(files)

	local findings: { Finding } = {}
	for _, fileRel in files do
		scanFile(gameDir, mounts, fileRel, findings)
	end

	local mountList: { string } = {}
	for _, m in mounts do
		table.insert(mountList, joinSegs(m.dmSegs))
	end
	table.sort(mountList)
	emit(
		string.format(
			"[require-resolve] %d modules scanned in src/ · mounts: %s",
			#files,
			table.concat(mountList, ", ")
		)
	)

	local fails, warns = 0, 0
	for _, f in findings do
		if f.level == "FAIL" then
			fails += 1
		else
			warns += 1
		end
	end

	table.sort(findings, function(a, b)
		if a.level ~= b.level then
			return a.level == "FAIL"
		end
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)
	for _, f in findings do
		emit(string.format("%s  %s:%d", f.level, f.file, f.line))
		emit("      " .. f.msg)
	end

	if fails == 0 and warns == 0 then
		emit("require-resolve: 0 FAIL, 0 WARN — every require resolves in the DataModel.")
	else
		emit(string.format("require-resolve: %d FAIL, %d WARN.", fails, warns))
	end

	return { name = "require", ok = fails == 0, output = table.concat(out, "\n") }
end

-- ── standalone CLI (testing only; never fires when required by gauntlet.luau) ──
if process.env.GATE_REQUIRE_CLI ~= nil then
	local dir: string? = nil
	for _, a in process.args do
		if a ~= "--" and a ~= "" then
			dir = a
			break
		end
	end
	local stage = GateRequire.run(dir or ".")
	print(stage.output)
	process.exit(if stage.ok then 0 else 1)
end

return GateRequire
