--!strict
-- Fence.luau — the factory autonomy fence, as a pure, side-effect-free matcher.
--
-- This is LAYER 2 of the fence (FACTORY.md §4). Layer 1 is the `permissions.deny`
-- glob list in `.claude/settings.json`, which Claude Code evaluates authoritatively
-- and which a hook can never override. This module is the defense-in-depth layer that
-- catches what prefix-globs miss: command chaining, substitution, wrapper indirection,
-- path-qualified executables, quoting tricks, the `git -C <dir>` global option, and
-- PowerShell aliases — across BOTH shells — while NOT false-positiving on forbidden
-- words that appear as data (a commit message, a branch name, a URL path).
--
-- Design contract:
--   * PURE. No I/O, no `os`, no `process`. Strings in, a Decision out. This is what
--     makes it unit-testable like the rest of the project (see ../tests/run.luau).
--   * Mostly a SUPERSET of the settings.json deny list (one deliberate exception: the
--     lune publish/upload/deploy naming convention, see rulePublish + docs/FENCE.md).
--   * LOW false-positive. Legit work must pass: `git commit -m "fix git push race"`,
--     `git checkout feature/cleanup`, `rojo build`, `cp /usr/share/x ./vendor/x`.
--   * FAIL-OPEN is the adapter's job. Here we only decide blocked-or-not; the adapter
--     (guard.luau) decides what to do when it cannot parse the input. Layer 1 backstops.
--
-- Categories mirror FACTORY.md §4:
--   destructive-git · destructive-fs · publish-deploy · out-of-workspace
--
-- Hardened against an adversarial red-team (see docs/FENCE.md). Lune-only module; never
-- loaded inside Roblox, so it uses plain Lune relative requires and Lune string APIs.

local Fence = {}

export type Shell = "bash" | "powershell"

export type Decision = {
	blocked: boolean,
	category: string?, -- "destructive-git" | "destructive-fs" | "publish-deploy" | "out-of-workspace"
	ruleId: string?, -- stable id, e.g. "git-push"
	reason: string?, -- human-readable, references FACTORY.md §4
	matched: string?, -- the offending fragment (a single segment), for the message
}

local ALLOWED: Decision = { blocked = false }

local function lower(s: string): string
	return string.lower(s)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tokenizer. A token carries whether it was quoted, because quoting is how legit
-- commands carry forbidden *words as data*. Rules only look at UNQUOTED tokens when
-- deciding what a command is doing. `\r` is treated as whitespace (CRLF tolerance).
-- ─────────────────────────────────────────────────────────────────────────────

type Token = { text: string, quoted: boolean }

local function tokenize(segment: string): { Token }
	local tokens: { Token } = {}
	local buf = {}
	local hasContent = false
	local tokenQuoted = false
	local i = 1
	local n = #segment

	local function flush()
		if hasContent then
			table.insert(tokens, { text = table.concat(buf), quoted = tokenQuoted })
		end
		buf = {}
		hasContent = false
		tokenQuoted = false
	end

	while i <= n do
		local c = string.sub(segment, i, i)
		if c == "'" then
			hasContent = true
			tokenQuoted = true
			local j = string.find(segment, "'", i + 1, true)
			if not j then
				table.insert(buf, string.sub(segment, i + 1))
				i = n + 1
			else
				table.insert(buf, string.sub(segment, i + 1, j - 1))
				i = j + 1
			end
		elseif c == '"' then
			hasContent = true
			tokenQuoted = true
			local j = i + 1
			local inner = {}
			while j <= n do
				local d = string.sub(segment, j, j)
				if d == "\\" and j < n then
					table.insert(inner, string.sub(segment, j + 1, j + 1))
					j = j + 2
				elseif d == '"' then
					break
				else
					table.insert(inner, d)
					j = j + 1
				end
			end
			table.insert(buf, table.concat(inner))
			i = j + 1
		elseif c == " " or c == "\t" or c == "\r" then
			flush()
			i = i + 1
		else
			hasContent = true
			table.insert(buf, c)
			i = i + 1
		end
	end
	flush()
	return tokens
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Segmentation: split on shell operators outside quotes: ; && || | & newline (+CR).
-- ─────────────────────────────────────────────────────────────────────────────

local function splitSegments(command: string): { string }
	local segments: { string } = {}
	local buf = {}
	local i = 1
	local n = #command
	local quote: string? = nil

	local function flush()
		local s = table.concat(buf)
		if string.match(s, "%S") then
			table.insert(segments, s)
		end
		buf = {}
	end

	while i <= n do
		local c = string.sub(command, i, i)
		if quote then
			table.insert(buf, c)
			if c == quote then
				quote = nil
			end
			i = i + 1
		elseif c == "'" or c == '"' then
			quote = c
			table.insert(buf, c)
			i = i + 1
		elseif c == "\n" or c == "\r" or c == ";" then
			flush()
			i = i + 1
		elseif c == "|" and buf[#buf] == ">" then
			-- `>|` is a force-clobber redirect operator, not a pipe — keep it in the segment
			table.insert(buf, c)
			i = i + 1
		elseif c == "&" or c == "|" then
			flush()
			if string.sub(command, i + 1, i + 1) == c then
				i = i + 2
			else
				i = i + 1
			end
		else
			table.insert(buf, c)
			i = i + 1
		end
	end
	flush()
	return segments
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Indirection expansion. Surface command texts hidden inside delimiters so they are
-- scanned too: $( … )  ` … `  ${ … }  ( … ) subshell/subexpr  { … } group/scriptblock.
-- Bounded so a pathological input always halts.
-- ─────────────────────────────────────────────────────────────────────────────

-- find the matching closer for an opener, honoring nesting and skipping quoted regions
local function findClose(text: string, startIdx: number, openCh: string, closeCh: string): number?
	local depth = 1
	local i = startIdx
	local n = #text
	local q: string? = nil
	while i <= n do
		local c = string.sub(text, i, i)
		if q then
			if c == q then
				q = nil
			end
		elseif c == "'" or c == '"' then
			q = c
		elseif c == openCh then
			depth += 1
		elseif c == closeCh then
			depth -= 1
			if depth == 0 then
				return i
			end
		end
		i += 1
	end
	return nil
end

-- Quote-aware indirection expansion. Surfaces command texts hidden in delimiters so they
-- are scanned too — but ONLY where they would actually execute:
--   * $( … )  ` … `  ${ … }  — expand unquoted OR inside double quotes (bash semantics)
--   * ( … ) subshell, { … } group/scriptblock — only when UNQUOTED
-- Crucially, a bare ( … ) or { … } inside a quoted string (a commit message, an awk
-- program) is DATA, not a command, and is left alone. Bounded so it always halts.
local function expandIndirections(command: string): { string }
	local results: { string } = { command }
	local queue: { string } = { command }
	local seen: { [string]: boolean } = { [command] = true }
	local budget = 96

	local function add(inner: string)
		budget -= 1
		if not seen[inner] and string.match(inner, "%S") then
			seen[inner] = true
			table.insert(results, inner)
			table.insert(queue, inner)
		end
	end

	while #queue > 0 and budget > 0 do
		local cur = table.remove(queue, 1) :: string
		local n = #cur
		local i = 1
		local q: string? = nil
		while i <= n and budget > 0 do
			local c = string.sub(cur, i, i)
			local c2 = string.sub(cur, i + 1, i + 1)
			if q then
				if c == q then
					q = nil
					i += 1
				elseif q == '"' and c == "$" and c2 == "(" then
					local close = findClose(cur, i + 2, "(", ")")
					if close then
						add(string.sub(cur, i + 2, close - 1))
						i = close + 1
					else
						i += 1
					end
				elseif q == '"' and c == "$" and c2 == "{" then
					local close = findClose(cur, i + 2, "{", "}")
					if close then
						add(string.sub(cur, i + 2, close - 1))
						i = close + 1
					else
						i += 1
					end
				elseif q == '"' and c == "`" then
					local close = string.find(cur, "`", i + 1, true)
					if close then
						add(string.sub(cur, i + 1, close - 1))
						i = close + 1
					else
						i += 1
					end
				else
					i += 1
				end
			elseif c == "'" or c == '"' then
				q = c
				i += 1
			elseif c == "$" and c2 == "(" then
				local close = findClose(cur, i + 2, "(", ")")
				if close then
					add(string.sub(cur, i + 2, close - 1))
					i = close + 1
				else
					i += 1
				end
			elseif c == "$" and c2 == "{" then
				local close = findClose(cur, i + 2, "{", "}")
				if close then
					add(string.sub(cur, i + 2, close - 1))
					i = close + 1
				else
					i += 1
				end
			elseif c == "`" then
				local close = string.find(cur, "`", i + 1, true)
				if close then
					add(string.sub(cur, i + 1, close - 1))
					i = close + 1
				else
					i += 1
				end
			elseif c == "(" then
				local close = findClose(cur, i + 1, "(", ")")
				if close then
					add(string.sub(cur, i + 1, close - 1))
					i = close + 1
				else
					i += 1
				end
			elseif c == "{" then
				local close = findClose(cur, i + 1, "{", "}")
				if close then
					add(string.sub(cur, i + 1, close - 1))
					i = close + 1
				else
					i += 1
				end
			else
				i += 1
			end
		end
	end
	return results
end

-- A copy of the segment with all quoted spans blanked to spaces — so redirect / path
-- scanning never trips on a `>` or a path that is really quoted data (awk programs,
-- commit messages). Quote-aware where the token rules can't reach (they see whole tokens).
local function unquotedView(segment: string): string
	local out: { string } = {}
	local i = 1
	local n = #segment
	local q: string? = nil
	while i <= n do
		local c = string.sub(segment, i, i)
		if q then
			out[i] = " "
			if c == q then
				q = nil
			end
		elseif c == "'" or c == '"' then
			out[i] = " "
			q = c
		else
			out[i] = c
		end
		i += 1
	end
	return table.concat(out)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lightweight variable resolution. Catches `X=push; git $X`, `URL=…roblox…; curl $URL`,
-- `$c='Remove-Item -Recurse'; iex $c`. We collect simple literal assignments (bash
-- NAME=value and PowerShell $name = value) and substitute $NAME / ${NAME} occurrences,
-- returning an expanded copy of the command for ADDITIONAL scanning (never replacing the
-- original). Expansion only ever surfaces more to scan, so it can't hide anything.
-- ─────────────────────────────────────────────────────────────────────────────

local function stripQuotes(v: string): string
	local inner = string.match(v, "^'(.*)'$") or string.match(v, '^"(.*)"$')
	return inner or v
end

local function expandVariables(command: string): string?
	local vars: { [string]: string } = {}
	for _, seg in splitSegments(command) do
		local trimmed = string.match(seg, "^%s*(.-)%s*$") or seg
		-- bash:  NAME=value     powershell:  $name = value  /  $name=value
		local name, value = string.match(trimmed, "^%$?([%w_]+)%s*=%s*(.+)$")
		if name and value then
			-- powershell array literal `@('a','b')` → space-joined for splatting (@a)
			local arr = string.match(value, "^@%((.+)%)$")
			if arr then
				local parts: { string } = {}
				for elem in string.gmatch(arr, "[^,]+") do
					table.insert(parts, stripQuotes(string.match(elem, "^%s*(.-)%s*$") or elem))
				end
				vars[lower(name)] = table.concat(parts, " ")
			else
				vars[lower(name)] = stripQuotes(value)
			end
		end
	end
	if next(vars) == nil then
		return nil
	end
	-- substitute $NAME / ${NAME} (bash, powershell) and @NAME (powershell splat)
	local expanded = string.gsub(command, "[%$@]{?([%w_]+)}?", function(n: string): string
		return vars[lower(n)] or ("$" .. n)
	end)
	if expanded == command then
		return nil
	end
	return expanded
end

-- Resolve shell escapes/line-continuations that would otherwise hide a command:
--   bash `git \<newline> push` / `git pus\h` / `\rm`   (backslash escape, outside quotes)
--   powershell `git `<newline> push`                   (backtick continuation/escape)
-- Returns an additional command variant for scanning (or nil if nothing changed). Only
-- touches UNQUOTED regions, so quoted data is preserved verbatim.
local function preprocess(command: string, shell: Shell): string?
	local esc = if shell == "powershell" then "`" else "\\"
	local out: { string } = {}
	local i = 1
	local n = #command
	local q: string? = nil
	local changed = false
	while i <= n do
		local c = string.sub(command, i, i)
		if q then
			table.insert(out, c)
			if c == q then
				q = nil
			end
			i += 1
		elseif c == "'" or c == '"' then
			q = c
			table.insert(out, c)
			i += 1
		elseif c == esc then
			local nx = string.sub(command, i + 1, i + 1)
			if nx == "" then
				i += 1
				changed = true
			elseif nx == "\n" or nx == "\r" then
				table.insert(out, " ") -- line continuation → space
				i += 2
				if nx == "\r" and string.sub(command, i, i) == "\n" then
					i += 1
				end
				changed = true
			else
				table.insert(out, nx) -- drop the escape char, keep what it escaped
				i += 2
				changed = true
			end
		else
			table.insert(out, c)
			i += 1
		end
	end
	if not changed then
		return nil
	end
	return table.concat(out)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Head normalization: strip directory and a known executable extension so that
-- `/bin/rm`, `.\rbxcloud.exe`, `C:\tools\rbxcloud.exe`, `\rm` all reduce to the bare
-- program name. Lowercased.
-- ─────────────────────────────────────────────────────────────────────────────

local EXE_EXT: { [string]: boolean } =
	{ exe = true, cmd = true, bat = true, com = true, ps1 = true }

local function normalizeHead(raw: string): string
	local base = string.match(raw, "[^/\\]+$") or raw
	local stem, ext = string.match(base, "^(.+)%.([%w]+)$")
	if stem and ext and EXE_EXT[lower(ext)] then
		base = stem
	end
	return lower(base)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Parsing
-- ─────────────────────────────────────────────────────────────────────────────

-- Prefixes that simply hand off to the next token as the real command (no value-flags),
-- so parseSegment can skip them and make the following token the head.
local TRANSPARENT_PREFIX: { [string]: boolean } = {
	["command"] = true,
	["builtin"] = true,
	["exec"] = true,
	["then"] = true,
	["do"] = true,
}

-- Command-runner wrappers that take their OWN options/positionals before the real command
-- (`timeout 60 git push`, `env -u X git push`, `flock lock git push`). We can't reliably
-- find the head by skipping (their flags take values), so extractWrapperInners scans each
-- argument SUFFIX — the real command is one of them. Quote-preserving, so a quoted arg that
-- merely contains a forbidden word is not mistaken for a command.
local RUNNER_WRAPPERS: { [string]: boolean } = {
	sudo = true,
	doas = true,
	env = true,
	time = true,
	nice = true,
	nohup = true,
	ionice = true,
	chrt = true,
	timeout = true,
	watch = true,
	flock = true,
	stdbuf = true,
	setsid = true,
	unbuffer = true,
	proxychains = true,
	proxychains4 = true,
	torsocks = true,
	xargs = true, -- `xargs [flags] CMD` — the real command is a suffix
	parallel = true, -- GNU parallel `parallel CMD ::: args`
	npx = true, -- `npx <tool> …` runs an installed/fetched tool
	bunx = true,
}

local SHELL_DASH_C: { [string]: boolean } = {
	sh = true,
	bash = true,
	dash = true,
	zsh = true,
	ksh = true,
	su = true, -- `su -c '<cmd>'` runs a command as another user
	pwsh = true,
	powershell = true,
}
local CMD_HEADS: { [string]: boolean } = { cmd = true }
local EVAL_HEADS: { [string]: boolean } = { eval = true, iex = true, ["invoke-expression"] = true }
local STARTPROC_HEADS: { [string]: boolean } =
	{ ["start-process"] = true, saps = true, start = true }

local function isAssignment(text: string): boolean
	return string.match(text, "^[%a_][%w_]*=") ~= nil
end

type Parsed = {
	head: string,
	headRaw: string,
	args: { Token },
	unquoted: { string },
	all: { Token },
}

local function parseSegment(segment: string): Parsed
	local tokens = tokenize(segment)
	local idx = 1
	while idx <= #tokens do
		local t = tokens[idx]
		if not t.quoted and isAssignment(t.text) then
			idx += 1
		elseif not t.quoted and TRANSPARENT_PREFIX[normalizeHead(t.text)] then
			idx += 1
		else
			break
		end
	end

	local headRaw = if tokens[idx] then tokens[idx].text else ""
	local head = normalizeHead(headRaw)
	local args: { Token } = {}
	local unquoted: { string } = {}
	for j = idx + 1, #tokens do
		table.insert(args, tokens[j])
		if not tokens[j].quoted then
			table.insert(unquoted, lower(tokens[j].text))
		end
	end
	return { head = head, headRaw = headRaw, args = args, unquoted = unquoted, all = tokens }
end

local function hasUnquotedWord(p: Parsed, words: { string }): boolean
	local set: { [string]: boolean } = {}
	for _, w in words do
		set[w] = true
	end
	for _, u in p.unquoted do
		if set[u] then
			return true
		end
	end
	return false
end

local function anyUnquotedContains(p: Parsed, needle: string): boolean
	for _, u in p.unquoted do
		if string.find(u, needle, 1, true) then
			return true
		end
	end
	return false
end

-- like hasUnquotedWord but also matches QUOTED tokens — for subcommands where quoting
-- the word (`rojo "upload"`) is pure obfuscation, not data.
local function hasWord(p: Parsed, words: { string }): boolean
	local set: { [string]: boolean } = {}
	for _, w in words do
		set[w] = true
	end
	for _, tok in p.all do
		if set[lower(tok.text)] then
			return true
		end
	end
	return false
end

local function flagBody(token: string): string?
	local body = string.match(token, "^%-%-?(.+)$")
	return if body then lower(body) else nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Wrapper extraction → inner command texts to scan as well (returns a list).
-- ─────────────────────────────────────────────────────────────────────────────

-- a flag that is `-c` or any abbreviation of `-command` (PowerShell -Comm, -Com, …)
local function isCommandFlag(b: string): boolean
	if b == "-c" then
		return true
	end
	if string.sub(b, 1, 2) == "-c" and string.sub("-command", 1, #b) == b then
		return true
	end
	return false
end

local function extractWrapperInners(p: Parsed): { string }
	local inners: { string } = {}

	if SHELL_DASH_C[p.head] then
		for idx, tok in p.args do
			if not tok.quoted and isCommandFlag(lower(tok.text)) then
				local nxt = p.args[idx + 1]
				if nxt then
					table.insert(inners, nxt.text)
				end
			end
		end
		return inners
	end

	if CMD_HEADS[p.head] then
		for idx, tok in p.args do
			if not tok.quoted then
				local b = lower(tok.text)
				if b == "/c" or b == "/k" then
					local parts: { string } = {}
					for j = idx + 1, #p.args do
						table.insert(parts, p.args[j].text)
					end
					table.insert(inners, table.concat(parts, " "))
				end
			end
		end
		return inners
	end

	if EVAL_HEADS[p.head] then
		local parts: { string } = {}
		for _, tok in p.args do
			table.insert(parts, tok.text)
		end
		table.insert(inners, table.concat(parts, " "))
		return inners
	end

	if STARTPROC_HEADS[p.head] then
		-- Start-Process <prog> -ArgumentList '<args>': scan the launched prog as a head,
		-- and the argument list as its own command (covers both publish-prog and the
		-- shell-runs-a-script case).
		local prog: string? = nil
		for idx, tok in p.args do
			local b = lower(tok.text)
			if not tok.quoted and (b == "-argumentlist" or b == "-args" or b == "-a") then
				local nxt = p.args[idx + 1]
				if nxt then
					table.insert(inners, nxt.text)
				end
			elseif not prog and string.sub(tok.text, 1, 1) ~= "-" then
				prog = tok.text
			end
		end
		if prog then
			table.insert(inners, prog)
		end
		return inners
	end

	-- runner wrappers (timeout/env/flock/setsid/…) take their own options/positionals before
	-- the real command; scan each argument suffix — the real command is one of them.
	-- Quote-preserving so a quoted arg holding a forbidden word isn't read as a command.
	if RUNNER_WRAPPERS[p.head] then
		local function recon(tok: Token): string
			if tok.quoted then
				if string.find(tok.text, "'", 1, true) then
					return '"' .. tok.text .. '"'
				end
				return "'" .. tok.text .. "'"
			end
			return tok.text
		end
		local maxStart = math.min(#p.args, 8)
		for k = 1, maxStart do
			local parts: { string } = {}
			for j = k, #p.args do
				table.insert(parts, recon(p.args[j]))
			end
			if #parts > 0 then
				table.insert(inners, table.concat(parts, " "))
			end
		end
	end

	-- find -exec/-execdir <cmd> … ;|+  → scan the exec'd command (quote-preserving) so a
	-- destroyer hidden behind a wrapper (`find -exec env rm -rf {}`) is still caught.
	if p.head == "find" then
		for idx, tok in p.args do
			if not tok.quoted and (tok.text == "-exec" or tok.text == "-execdir") then
				local parts: { string } = {}
				for j = idx + 1, #p.args do
					local a = p.args[j]
					if not a.quoted and (a.text == ";" or a.text == "+" or a.text == "\\;") then
						break
					end
					if a.quoted then
						table.insert(parts, "'" .. a.text .. "'")
					else
						table.insert(parts, a.text)
					end
				end
				if #parts > 0 then
					table.insert(inners, table.concat(parts, " "))
				end
			end
		end
	end

	-- general: a shell wrapper appearing mid-command (`find -exec sh -c '…'`, etc.)
	-- scan for `<shell> … -c <value>` anywhere in the token stream.
	for idx, tok in p.all do
		if not tok.quoted and SHELL_DASH_C[normalizeHead(tok.text)] then
			for j = idx + 1, #p.all do
				local f = p.all[j]
				if not f.quoted and isCommandFlag(lower(f.text)) then
					local val = p.all[j + 1]
					if val then
						table.insert(inners, val.text)
					end
					break
				end
			end
		end
	end

	-- xargs [flags] CMD …  → scan CMD onward (skip xargs option flags + their values)
	if p.head == "xargs" then
		local VALUE_FLAGS: { [string]: boolean } = {
			["-i"] = true,
			["-I"] = true,
			["-n"] = true,
			["-l"] = true,
			["-p"] = true,
			["-s"] = true,
			["-e"] = true,
			["-d"] = true,
			["-a"] = true,
		}
		local i = 1
		while i <= #p.args do
			local t = p.args[i].text
			if string.sub(t, 1, 2) == "--" then
				i += 1
			elseif string.sub(t, 1, 1) == "-" then
				if VALUE_FLAGS[t] then
					i += 2
				else
					i += 1
				end
			else
				break
			end
		end
		local parts: { string } = {}
		for j = i, #p.args do
			table.insert(parts, p.args[j].text)
		end
		if #parts > 0 then
			table.insert(inners, table.concat(parts, " "))
		end
		return inners
	end

	return inners
end

-- ─────────────────────────────────────────────────────────────────────────────
-- git subcommand resolution (skips global options that may take a value)
-- ─────────────────────────────────────────────────────────────────────────────

local GIT_VALUE_OPTS: { [string]: boolean } = {
	["-C"] = true,
	["-c"] = true,
	["--git-dir"] = true,
	["--work-tree"] = true,
	["--namespace"] = true,
	["--exec-path"] = true,
}

local function gitSubcommand(p: Parsed): string?
	-- dashed plumbing form: `git-push` parses as head "git-push"
	local dashed = string.match(p.head, "^git%-(.+)$")
	if dashed then
		return dashed
	end
	if p.head ~= "git" then
		return nil
	end
	local i = 1
	while i <= #p.args do
		local tok = p.args[i]
		local t = tok.text
		if tok.quoted then
			return lower(t)
		end
		if GIT_VALUE_OPTS[t] then
			i += 2
		elseif string.match(t, "^%-%-[%w%-]+=") then
			i += 1
		elseif string.sub(t, 1, 1) == "-" then
			i += 1
		else
			return lower(t)
		end
	end
	return nil
end

-- alias arming: `git -c alias.up=push …` → the aliased subcommand
local function gitAliasBody(p: Parsed): string?
	for _, tok in p.args do
		if not tok.quoted then
			local body = string.match(tok.text, "^alias%.[%w_%-]+=(.+)$")
			if body then
				return lower(string.match(body, "^%s*([%w%-]+)") or body)
			end
		end
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- URL host detection for Roblox / Open Cloud (host, not substring, to avoid blocking
-- non-Roblox URLs that merely mention a roblox domain in a path or query string)
-- ─────────────────────────────────────────────────────────────────────────────

local ROBLOX_HOSTS = { "roblox.com", "rbxcdn.com", "rbxgcdn.com", "open.cloud" }

local function hostIsRoblox(host: string): boolean
	host = lower(host)
	host = string.gsub(host, "%.$", "") -- drop a trailing-dot FQDN (apis.roblox.com.)
	for _, d in ROBLOX_HOSTS do
		if host == d or (#host > #d and string.sub(host, #host - #d) == "." .. d) then
			return true
		end
	end
	return false
end

-- flags whose value is an OUTPUT FILE (not a URL) — a roblox-looking filename there is data
local OUTPUT_FLAGS: { [string]: boolean } =
	{ ["-o"] = true, ["-O"] = true, ["--output"] = true, ["--out"] = true, ["-outfile"] = true }

local function mentionsRobloxHost(p: Parsed): boolean
	for idx, tok in p.all do
		local t = tok.text
		-- scheme://[user[:pw]@]host[:port]/…  — the real host is AFTER any userinfo `@`.
		-- This both catches `user@apis.roblox.com` and refuses `apis.roblox.com@example.com`.
		local authority = string.match(t, "://([^/?#%s]+)")
		if authority then
			local host = string.match(authority, "@([^@]+)$") or authority
			host = string.match(host, "^([^:]+)") or host
			if hostIsRoblox(host) then
				return true
			end
		end
		-- a bare host (curl roblox.com / wget user:pw@create.roblox.com) — but NOT when it's
		-- the value of an output-file flag. Strip any `userinfo@` first.
		local prev = if idx > 1 then lower(p.all[idx - 1].text) else ""
		if not OUTPUT_FLAGS[prev] then
			local hostPart = string.match(t, "@([^@]+)$") or t
			local bare = string.match(hostPart, "^([%w%.%-]+%.%a%a+%.?)[/:]")
				or string.match(hostPart, "^([%w%.%-]+%.%a%a+%.?)$")
			if bare and hostIsRoblox(bare) then
				return true
			end
		end
	end
	return false
end

local NET_HEADS: { [string]: boolean } = {
	curl = true,
	wget = true,
	["invoke-restmethod"] = true,
	["invoke-webrequest"] = true,
	irm = true,
	iwr = true,
	["start-bitstransfer"] = true,
	httpie = true,
	http = true,
	https = true, -- HTTPie also installs an `https` alias
	xh = true,
	curlie = true,
}
local OPEN_HEADS: { [string]: boolean } = {
	start = true,
	["start-process"] = true,
	saps = true,
	["xdg-open"] = true,
	open = true,
	["explorer"] = true,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Path containment (pure string work — no disk access)
-- ─────────────────────────────────────────────────────────────────────────────

local function normalizePath(path: string): string
	local s = string.gsub(path, "\\", "/")
	s = string.gsub(s, "^(%a):", function(d)
		return lower(d) .. ":"
	end)
	local parts: { string } = {}
	for part in string.gmatch(s, "[^/]+") do
		if part == "." then
		elseif part == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			else
				table.insert(parts, "..")
			end
		else
			table.insert(parts, part)
		end
	end
	local prefix = if string.sub(s, 1, 1) == "/" then "/" else ""
	return prefix .. table.concat(parts, "/")
end

local function isInside(path: string, root: string): boolean
	local np = normalizePath(path)
	local nr = normalizePath(root)
	if nr == "" then
		return true
	end
	if np == nr then
		return true
	end
	return string.sub(np, 1, #nr + 1) == nr .. "/"
end

local SENSITIVE_ABS = {
	"/etc/",
	"/usr/",
	"/bin/",
	"/sbin/",
	"/boot/",
	"/dev/",
	"/sys/",
	"/proc/",
	"/var/",
	"/root/",
	"c:/windows",
	"c:/program files",
	"/system32",
}

local function isSensitiveSystemPath(path: string): boolean
	local p = lower((string.gsub(path, "\\", "/")))
	for _, abs in SENSITIVE_ABS do
		if string.sub(p, 1, #abs) == abs or string.find(p, abs, 1, true) == 1 then
			return true
		end
	end
	-- also catch a leading occurrence anywhere of an absolute system root
	for _, abs in SENSITIVE_ABS do
		if string.find(p, "^" .. string.gsub(abs, "([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")) then
			return true
		end
	end
	return false
end

-- Standard discard sinks — never a real write, always allowed as a redirect/copy target.
local function isDiscardSink(path: string): boolean
	local p = lower((string.gsub(path, "\\", "/")))
	return p == "/dev/null"
		or p == "/dev/zero"
		or p == "/dev/stdout"
		or p == "/dev/stderr"
		or p == "/dev/tty"
		or string.match(p, "^/dev/fd/%d+$") ~= nil
		or p == "nul"
		or p == "nul:"
		or p == "$null"
		or p == "con"
end

-- A path that points at the home directory (across shells) — outside the workspace.
local function isHomePath(path: string): boolean
	local p = lower(path)
	return string.find(p, "^~") ~= nil
		or string.find(p, "^%$home") ~= nil -- $HOME, ${HOME?}, $HOMEPATH
		or string.find(p, "^%${home}") ~= nil
		or string.find(p, "^%$homepath") ~= nil
		or string.find(p, "^%$env:userprofile") ~= nil
		or string.find(p, "^%$env:home") ~= nil
		or string.find(p, "^%%userprofile%%") ~= nil
		or string.find(p, "^%%homepath%%") ~= nil
end

-- Is writing to `path` out of bounds? home, UNC (\\), sensitive system paths, or
-- (when a workspace root is known) anything that escapes it. Discard sinks are exempt.
local function isOutOfWorkspaceWrite(path: string, root: string?): boolean
	if path == "" or isDiscardSink(path) then
		return false
	end
	if isHomePath(path) then
		return true
	end
	if string.sub(path, 1, 2) == "\\\\" or string.sub(path, 1, 2) == "//" then
		return true
	end
	if isSensitiveSystemPath(path) then
		return true
	end
	local isAbsolute = string.match(path, "^/") ~= nil or string.match(path, "^%a:[/\\]") ~= nil
	if root and root ~= "" then
		if isAbsolute then
			return not isInside(path, root)
		end
		return not isInside(root .. "/" .. path, root)
	end
	-- no root known: only the unambiguous escapes above are caught
	return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Rules
-- ─────────────────────────────────────────────────────────────────────────────

type Rule = (p: Parsed, shell: Shell, segment: string, root: string?) -> Decision?

local function block(category: string, ruleId: string, reason: string, segment: string): Decision
	return {
		blocked = true,
		category = category,
		ruleId = ruleId,
		reason = reason,
		matched = segment,
	}
end

-- ── destructive-git ──────────────────────────────────────────────────────────
local function ruleGit(p: Parsed, _shell: Shell, segment: string): Decision?
	local isGit = p.head == "git" or string.match(p.head, "^git%-") ~= nil
	if not isGit then
		return nil
	end
	-- reading help is not destructive
	if hasUnquotedWord(p, { "--help", "-h" }) then
		return nil
	end

	local alias = gitAliasBody(p)
	if alias and (alias == "push" or alias == "clean" or alias == "rebase" or alias == "reset") then
		return block(
			"destructive-git",
			"git-alias",
			"a git alias that arms a fenced command (e.g. push) is itself fenced (FACTORY.md §4).",
			segment
		)
	end

	local sub = gitSubcommand(p)
	if sub == nil then
		return nil
	end

	if sub == "push" then
		return block(
			"destructive-git",
			"git-push",
			"`git push` is outside the autonomy fence (FACTORY.md §4). A human runs all pushes.",
			segment
		)
	end
	if sub == "clean" then
		return block(
			"destructive-git",
			"git-clean",
			"`git clean` deletes untracked files — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "rebase" then
		return block(
			"destructive-git",
			"git-rebase",
			"`git rebase` rewrites history — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "filter-branch" or sub == "filter-repo" then
		return block(
			"destructive-git",
			"git-filter",
			"`git " .. sub .. "` rewrites history — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "reflog" and hasUnquotedWord(p, { "expire", "delete" }) then
		return block(
			"destructive-git",
			"git-reflog-expire",
			"`git reflog expire/delete` destroys recovery history — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "gc" and (anyUnquotedContains(p, "--prune") or hasUnquotedWord(p, { "--prune" })) then
		return block(
			"destructive-git",
			"git-gc-prune",
			"`git gc --prune` purges unreachable objects — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "reset" then
		for _, u in p.unquoted do
			if string.sub(u, 1, 6) == "--hard" then
				return block(
					"destructive-git",
					"git-reset-hard",
					"`git reset --hard` discards working-tree changes — fenced (FACTORY.md §4).",
					segment
				)
			end
		end
	end
	if sub == "tag" and hasUnquotedWord(p, { "-d", "--delete", "-D" }) then
		return block(
			"destructive-git",
			"git-tag-delete",
			"`git tag -d` deletes a ref — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "symbolic-ref" and hasUnquotedWord(p, { "-d", "--delete" }) then
		return block(
			"destructive-git",
			"git-symbolic-ref-delete",
			"`git symbolic-ref -d` deletes a ref — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "update-ref" and hasUnquotedWord(p, { "-d" }) then
		return block(
			"destructive-git",
			"git-update-ref-delete",
			"`git update-ref -d` deletes refs — fenced (FACTORY.md §4).",
			segment
		)
	end
	if sub == "branch" then
		for _, tok in p.args do
			if
				not tok.quoted
				and (
					tok.text == "-D"
					or (tok.text == "--delete" and hasUnquotedWord(p, { "--force", "-f" }))
				)
			then
				return block(
					"destructive-git",
					"git-branch-force-delete",
					"`git branch -D` force-deletes a branch — fenced (FACTORY.md §4).",
					segment
				)
			end
		end
	end
	-- force-anything on a working-tree-mutating subcommand
	if
		hasUnquotedWord(p, { "--force", "--force-with-lease", "-f" })
		and (sub == "push" or sub == "checkout" or sub == "switch" or sub == "branch")
	then
		return block(
			"destructive-git",
			"git-force",
			"forced git operations discard work — fenced (FACTORY.md §4).",
			segment
		)
	end
	return nil
end

-- a truncate size argument that means "zero bytes" (0, 0K, 0G, …) — destructive.
-- A leading + (grow) or any non-zero magnitude is NOT.
local function isZeroSize(v: string): boolean
	return string.match(lower(v), "^0[kmgtpb]?$") ~= nil
end

-- ── destructive-fs: rm / find / shred / dd / truncate (bash-leaning) ──────────
local function ruleRm(p: Parsed, _shell: Shell, segment: string): Decision?
	if p.head == "rm" then
		for _, tok in p.args do
			if not tok.quoted then
				if tok.text == "--" then
					break -- end of options; the rest are filenames
				end
				local body = flagBody(tok.text)
				if body and string.sub(tok.text, 1, 2) ~= "--" then
					if string.find(body, "[rRf]") then
						return block(
							"destructive-fs",
							"rm-recursive-force",
							"recursive/forced `rm` is fenced (FACTORY.md §4).",
							segment
						)
					end
				elseif body == "recursive" or body == "force" or body == "no-preserve-root" then
					return block(
						"destructive-fs",
						"rm-recursive-force",
						"recursive/forced `rm` is fenced (FACTORY.md §4).",
						segment
					)
				end
			end
		end
		return nil
	end
	if p.head == "shred" then
		return block(
			"destructive-fs",
			"shred",
			"`shred` destroys file contents — fenced (FACTORY.md §4).",
			segment
		)
	end
	if p.head == "truncate" then
		-- only zero-truncation is destructive; growing a file (-s +N, -s 2G) is fine
		for idx, tok in p.args do
			if not tok.quoted then
				local v = string.match(tok.text, "^%-%-size=(.+)$")
					or string.match(tok.text, "^%-s(.+)$")
				if v and isZeroSize(v) then
					return block(
						"destructive-fs",
						"truncate-zero",
						"truncating a file to zero is fenced (FACTORY.md §4).",
						segment
					)
				end
				if tok.text == "-s" or tok.text == "--size" then
					local nxt = p.args[idx + 1]
					if nxt and not nxt.quoted and isZeroSize(nxt.text) then
						return block(
							"destructive-fs",
							"truncate-zero",
							"truncating a file to zero is fenced (FACTORY.md §4).",
							segment
						)
					end
				end
			end
		end
		return nil
	end
	if p.head == "dd" then
		if anyUnquotedContains(p, "of=") then
			return block(
				"destructive-fs",
				"dd-overwrite",
				"`dd of=…` overwrites a file — fenced (FACTORY.md §4).",
				segment
			)
		end
		return nil
	end
	if p.head == "find" then
		if hasUnquotedWord(p, { "-delete" }) then
			return block(
				"destructive-fs",
				"find-delete",
				"`find … -delete` is fenced (FACTORY.md §4).",
				segment
			)
		end
		-- inspect the command run by -exec / -execdir
		for idx, tok in p.args do
			if not tok.quoted and (tok.text == "-exec" or tok.text == "-execdir") then
				local cmd = p.args[idx + 1]
				if cmd then
					local h = normalizeHead(cmd.text)
					if h == "rm" or h == "shred" or h == "unlink" or h == "dd" then
						return block(
							"destructive-fs",
							"find-exec-destroy",
							"`find -exec "
								.. h
								.. "` mass-destroys files — fenced (FACTORY.md §4).",
							segment
						)
					end
					if h == "truncate" then
						-- only zero-truncation; growing matched files is allowed
						for j = idx + 2, #p.args do
							local a = p.args[j]
							if a.text == ";" or a.text == "+" or a.text == "\\;" then
								break
							end
							if not a.quoted then
								local v = string.match(a.text, "^%-%-size=(.+)$")
									or string.match(a.text, "^%-s(.+)$")
								if v and isZeroSize(v) then
									return block(
										"destructive-fs",
										"find-exec-destroy",
										"`find -exec truncate -s0` zero-truncates files — fenced (FACTORY.md §4).",
										segment
									)
								end
								if
									(a.text == "-s" or a.text == "--size")
									and p.args[j + 1]
									and isZeroSize(p.args[j + 1].text)
								then
									return block(
										"destructive-fs",
										"find-exec-destroy",
										"`find -exec truncate -s0` zero-truncates files — fenced (FACTORY.md §4).",
										segment
									)
								end
							end
						end
					end
				end
			end
		end
		return nil
	end
	return nil
end

-- ── destructive-fs: PowerShell Remove-Item + aliases ─────────────────────────
local PS_REMOVE_HEADS: { [string]: boolean } = {
	["remove-item"] = true,
	["ri"] = true,
	["rm"] = true,
	["del"] = true,
	["erase"] = true,
	["rd"] = true,
	["rmdir"] = true,
}

local function rulePsRemove(p: Parsed, shell: Shell, segment: string): Decision?
	if shell ~= "powershell" then
		return nil
	end
	if PS_REMOVE_HEADS[p.head] then
		-- explicit dry-run / disabled-switch escape hatches
		if hasUnquotedWord(p, { "-whatif" }) then
			return nil
		end
		for _, tok in p.args do
			if not tok.quoted then
				local b = flagBody(tok.text)
				if b then
					b = lower(b)
					if string.find(b, ":%$false") or string.find(b, ":false") then
						-- e.g. -Recurse:$false explicitly disables it
					elseif
						string.find(b, "^rec")
						or b == "r"
						or string.find(b, "^fo")
						or b == "f"
					then
						return block(
							"destructive-fs",
							"ps-remove-recurse-force",
							"recursive/forced delete (`Remove-Item -Recurse/-Force`) is fenced (FACTORY.md §4).",
							segment
						)
					end
				end
			end
		end
		return nil
	end
	local low = lower(segment)
	if string.find(low, "::delete(", 1, true) and string.find(low, "directory", 1, true) then
		return block(
			"destructive-fs",
			"dotnet-directory-delete",
			"`[IO.Directory]::Delete` is fenced (FACTORY.md §4).",
			segment
		)
	end
	return nil
end

-- ── destructive-fs: Clear-Content / cmd rd /s, del /s ────────────────────────
local CMD_DELETE_HEADS: { [string]: boolean } =
	{ rd = true, rmdir = true, del = true, erase = true }

local function ruleCmdDelete(p: Parsed, _shell: Shell, segment: string): Decision?
	if p.head == "clear-content" or p.head == "clc" then
		return block(
			"destructive-fs",
			"clear-content",
			"`Clear-Content` empties a file — fenced (FACTORY.md §4).",
			segment
		)
	end
	if not CMD_DELETE_HEADS[p.head] then
		return nil
	end
	-- only /s (recursive) is fenced; /q (quiet) alone on a single file is allowed
	for _, tok in p.args do
		if not tok.quoted and lower(tok.text) == "/s" then
			return block(
				"destructive-fs",
				"cmd-recursive-delete",
				"recursive cmd delete (`rd /s`, `del /s`) is fenced (FACTORY.md §4).",
				segment
			)
		end
	end
	return nil
end

-- ── publish-deploy ───────────────────────────────────────────────────────────
local function rulePublish(p: Parsed, _shell: Shell, segment: string): Decision?
	if p.head == "rbxcloud" then
		return block(
			"publish-deploy",
			"rbxcloud",
			"`rbxcloud` talks to Roblox Open Cloud — fenced (FACTORY.md §4).",
			segment
		)
	end
	if p.head == "rojo" and hasWord(p, { "upload" }) then
		return block(
			"publish-deploy",
			"rojo-upload",
			"`rojo upload` publishes to Roblox — fenced (FACTORY.md §4).",
			segment
		)
	end
	if p.head == "tarmac" and hasWord(p, { "upload", "sync" }) then
		return block(
			"publish-deploy",
			"tarmac-upload",
			"`tarmac upload/sync` pushes assets to Roblox — fenced (FACTORY.md §4).",
			segment
		)
	end
	if p.head == "mantle" and hasWord(p, { "deploy", "publish" }) then
		return block(
			"publish-deploy",
			"mantle-deploy",
			"`mantle deploy` ships to Roblox — fenced (FACTORY.md §4).",
			segment
		)
	end
	if NET_HEADS[p.head] and mentionsRobloxHost(p) then
		return block(
			"publish-deploy",
			"net-roblox",
			"network calls to Roblox endpoints are fenced (FACTORY.md §4) — publishing/account is human-gated.",
			segment
		)
	end
	if OPEN_HEADS[p.head] and mentionsRobloxHost(p) then
		return block(
			"publish-deploy",
			"open-roblox",
			"opening a Roblox publish/create surface is fenced (FACTORY.md §4).",
			segment
		)
	end
	-- executing a publish/upload/deploy script via Invoke-Expression / iex
	if p.head == "iex" or p.head == "invoke-expression" then
		local low = lower(segment)
		local hasScriptExt = string.find(low, ".ps1", 1, true)
			or string.find(low, ".psm1", 1, true)
			or string.find(low, ".psd1", 1, true)
			or string.find(low, ".luau", 1, true)
			or string.find(low, ".sh", 1, true)
		for _, w in { "publish", "upload", "deploy" } do
			if string.find(low, w, 1, true) and hasScriptExt then
				return block(
					"publish-deploy",
					"iex-publish-script",
					"executing a publish/upload/deploy script via Invoke-Expression is fenced (FACTORY.md §4).",
					segment
				)
			end
		end
	end
	if p.head == "lune" and hasUnquotedWord(p, { "run" }) then
		-- Block any lune script whose path mentions publish/upload/deploy. This mirrors the
		-- layer-1 glob (`lune run *publish*`/`*upload*`) for consistency. Quoted paths count
		-- (quoting is obfuscation). CONVENTION: test files must not be named with
		-- publish/upload/deploy — see docs/FENCE.md.
		for _, tok in p.args do
			local t = lower(tok.text)
			if
				string.find(t, "publish", 1, true)
				or string.find(t, "upload", 1, true)
				or string.find(t, "deploy", 1, true)
			then
				return block(
					"publish-deploy",
					"lune-publish",
					"running a publish/upload/deploy Lune script is fenced (FACTORY.md §4).",
					segment
				)
			end
		end
	end
	return nil
end

-- ── publish-deploy: encoded PowerShell (unauditable → fenced outright) ────────
local function ruleEncodedPs(p: Parsed, _shell: Shell, segment: string): Decision?
	if p.head ~= "powershell" and p.head ~= "pwsh" then
		return nil
	end
	for idx, tok in p.args do
		if not tok.quoted then
			local b = lower(tok.text)
			-- any unambiguous abbreviation of -encodedcommand (-enc, -encod, …) or -ec
			local isEnc = b == "-ec"
				or (
					string.sub(b, 1, 2) == "-e"
					and #b >= 3
					and string.sub("-encodedcommand", 1, #b) == b
				)
			if isEnc then
				return block(
					"destructive-fs",
					"ps-encoded",
					"encoded PowerShell commands can't be audited and are fenced (FACTORY.md §4).",
					segment
				)
			end
			if b == "-e" then
				local nxt = p.args[idx + 1]
				if nxt and string.match(nxt.text, "^[%w+/=]+$") and #nxt.text >= 12 then
					return block(
						"destructive-fs",
						"ps-encoded",
						"encoded PowerShell commands can't be audited and are fenced (FACTORY.md §4).",
						segment
					)
				end
			end
		end
	end
	return nil
end

-- ── out-of-workspace writes (redirects + write-command destinations) ─────────
local WRITE_LAST_POSITIONAL: { [string]: boolean } = {
	cp = true,
	mv = true,
	install = true,
	copy = true,
	move = true,
	["copy-item"] = true,
	["move-item"] = true,
	cpi = true,
	mi = true,
	rsync = true,
	scp = true,
	robocopy = true,
}
local WRITE_FIRST_POSITIONAL: { [string]: boolean } = {
	["set-content"] = true,
	["add-content"] = true,
	["out-file"] = true,
	["new-item"] = true,
	["export-csv"] = true,
	["export-clixml"] = true,
	sc = true,
	ac = true,
	ni = true,
}
local WRITE_ALL_POSITIONAL: { [string]: boolean } = { tee = true }

-- Extract the WRITE DESTINATION(s) of a command. Head-aware, because for copy/move the
-- destination is `-Destination`/`-t`/the LAST positional and `-Path`/`-LiteralPath` are
-- SOURCES (reading a system file into the workspace is fine); for content-writers the
-- destination IS `-Path`/`-FilePath`/the first positional.
local function writeDestinations(p: Parsed): { string }
	local out: { string } = {}
	local positionals: { string } = {}
	local isCopyMove = WRITE_LAST_POSITIONAL[p.head]
	local sawTargetDir = false
	local i = 1
	while i <= #p.args do
		local tok = p.args[i]
		local t = tok.text
		local lt = lower(t)
		if tok.quoted then
			table.insert(positionals, t)
			i += 1
		elseif isCopyMove and (lt == "-destination" or lt == "-dest") then
			if p.args[i + 1] then
				table.insert(out, p.args[i + 1].text)
			end
			i += 2
		elseif
			isCopyMove and (lt == "-t" or lt == "--target-directory" or lt == "--target-dir")
		then
			if p.args[i + 1] then
				table.insert(out, p.args[i + 1].text)
				sawTargetDir = true
			end
			i += 2
		elseif isCopyMove and (lt == "-path" or lt == "-literalpath") then
			i += 2 -- a SOURCE flag for copy/move — consume its value, ignore
		elseif
			not isCopyMove
			and (
				lt == "-path"
				or lt == "-filepath"
				or lt == "-literalpath"
				or lt == "-destination"
				or lt == "-dest"
			)
		then
			if p.args[i + 1] then
				table.insert(out, p.args[i + 1].text)
			end
			i += 2
		elseif string.match(t, "^of=") then
			table.insert(out, string.sub(t, 4))
			i += 1
		elseif string.sub(t, 1, 1) == "-" then
			i += 1
		else
			table.insert(positionals, t)
			i += 1
		end
	end
	if WRITE_ALL_POSITIONAL[p.head] then
		for _, x in positionals do
			table.insert(out, x)
		end
	elseif isCopyMove and not sawTargetDir then
		if #positionals >= 1 then
			table.insert(out, positionals[#positionals]) -- dest is the last positional
		end
	elseif WRITE_FIRST_POSITIONAL[p.head] then
		if #out == 0 and #positionals >= 1 then
			table.insert(out, positionals[1])
		end
	end
	return out
end

local function ruleOutOfWorkspace(
	p: Parsed,
	_shell: Shell,
	segment: string,
	root: string?
): Decision?
	-- Scan a quote-blanked view so a `>` or path inside an awk program / commit message
	-- (quoted data) is never mistaken for a real shell redirect.
	local view = unquotedView(segment)

	-- 1) redirect targets:  > path  /  >> path  /  >| path  /  2> path
	for tgt in string.gmatch(view, ">[>|]?%s*([^%s>|&;]+)") do
		local clean = stripQuotes(tgt)
		if not isDiscardSink(clean) and isOutOfWorkspaceWrite(clean, root) then
			return block(
				"out-of-workspace",
				"redirect-escape",
				"redirecting output outside the workspace is fenced (FACTORY.md §4).",
				segment
			)
		end
	end
	-- bare truncation:  > file  /  : > file  /  >| file  (zeroes a file, no command before >)
	local op, tgt = string.match(view, "^%s*:?%s*(>[>|]?)%s*([^%s>|&;]+)")
	if op and tgt and op ~= ">>" and not isDiscardSink(stripQuotes(tgt)) then
		return block(
			"destructive-fs",
			"truncate-redirect",
			"`> file` / `: > file` truncates a file to zero — fenced (FACTORY.md §4).",
			segment
		)
	end
	-- /dev/null redirected OVER a file (cat /dev/null > f) truncates it
	if string.find(lower(view), "/dev/null%s*>%s*[^%s>|&;]") then
		return block(
			"destructive-fs",
			"truncate-devnull",
			"redirecting /dev/null over a file truncates it — fenced (FACTORY.md §4).",
			segment
		)
	end

	-- 2) write-command destinations
	if
		WRITE_LAST_POSITIONAL[p.head]
		or WRITE_FIRST_POSITIONAL[p.head]
		or WRITE_ALL_POSITIONAL[p.head]
		or p.head == "dd"
	then
		for _, dest in writeDestinations(p) do
			if isOutOfWorkspaceWrite(dest, root) then
				return block(
					"out-of-workspace",
					"write-escape",
					"writing `" .. dest .. "` outside the workspace is fenced (FACTORY.md §4).",
					segment
				)
			end
		end
	end
	return nil
end

local RULES: { Rule } = {
	ruleGit,
	ruleRm,
	rulePsRemove,
	ruleCmdDelete,
	rulePublish,
	ruleEncodedPs,
	ruleOutOfWorkspace,
}

-- Remove here-document BODIES from a command. A heredoc body is DATA being written to a
-- file (`cat <<'EOF' > runbook.md … EOF`), never executed — so a fenced command mentioned
-- in it must NOT trip the matcher. Returns the command with bodies stripped, plus, for
-- UNQUOTED heredocs only, any `$(…)`/backtick substitutions found in the body (those DO
-- execute in bash) for separate scanning.
local function stripHeredocs(command: string): (string, { string })
	local extras: { string } = {}
	if not string.find(command, "<<", 1, true) or not string.find(command, "\n", 1, true) then
		return command, extras
	end
	local result = command
	local guard = 0
	while guard < 12 do
		guard += 1
		local _, e, _dash, q, delim = string.find(result, "<<(%-?)(['\"\\]?)([%w_]+)")
		if not e or not delim then
			break
		end
		local nl = string.find(result, "\n", e + 1, true)
		if not nl then
			break
		end
		local bodyText: string
		local removeTo: number
		local ds, de = string.find(result, "\n%s*" .. delim .. "%s*\r?\n", nl)
		if ds and de then
			bodyText = string.sub(result, nl + 1, ds)
			removeTo = de
		else
			local ds2, de2 = string.find(result, "\n%s*" .. delim .. "%s*$", nl)
			if ds2 and de2 then
				bodyText = string.sub(result, nl + 1, ds2)
				removeTo = de2
			else
				bodyText = string.sub(result, nl + 1)
				removeTo = #result
			end
		end
		if q == "" then
			for _, inner in expandIndirections(bodyText) do
				if inner ~= bodyText then
					table.insert(extras, inner)
				end
			end
		end
		result = string.sub(result, 1, nl) .. string.sub(result, removeTo + 1)
	end
	return result, extras
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function Fence.evaluateCommand(command: string, shell: Shell, workspaceRoot: string?): Decision
	if type(command) ~= "string" or not string.match(command, "%S") then
		return ALLOWED
	end

	-- Strip here-document bodies (data, not commands) up front; keep any executing
	-- substitutions they contained for scanning.
	local base, heredocExtras = stripHeredocs(command)

	-- Scan the command plus extra variants that expose hidden forms: shell-escape /
	-- line-continuation resolution, and simple variable substitution.
	local variants: { string } = { base }
	local pp = preprocess(base, shell)
	if pp then
		table.insert(variants, pp)
	end
	local ev = expandVariables(base)
	if ev then
		table.insert(variants, ev)
	end
	for _, ex in heredocExtras do
		table.insert(variants, ex)
	end

	local queue: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, v in variants do
		for _, t in expandIndirections(v) do
			if not seen[t] then
				seen[t] = true
				table.insert(queue, t)
			end
		end
	end

	local i = 1
	local budget = 512
	while i <= #queue and budget > 0 do
		local text = queue[i]
		i += 1
		budget -= 1
		for _, segment in splitSegments(text) do
			local parsed = parseSegment(segment)
			if parsed.head ~= "" then
				for _, inner in extractWrapperInners(parsed) do
					if string.match(inner, "%S") and not seen[inner] then
						seen[inner] = true
						table.insert(queue, inner)
					end
				end
				for _, rule in RULES do
					local decision = rule(parsed, shell, segment, workspaceRoot)
					if decision then
						return decision
					end
				end
			end
		end
	end
	return ALLOWED
end

function Fence.evaluatePath(path: string, workspaceRoot: string): Decision
	if type(path) ~= "string" or path == "" then
		return ALLOWED
	end
	-- The agent's own Claude Code memory directory (.claude/projects/<proj>/memory/) is a
	-- legitimate write target — it lives outside the repo but IS the designated place for the
	-- agent to persist facts. Narrowly allowed; general .claude/ writes are NOT (that would
	-- expose settings.json — the fence's own config).
	local norm = lower(normalizePath(path))
	if
		string.find(norm, "/.claude/projects/", 1, true) and string.find(norm, "/memory/", 1, true)
	then
		return ALLOWED
	end
	if string.sub(path, 1, 1) == "~" then
		return block(
			"out-of-workspace",
			"edit-home",
			"editing a path under the home directory is outside the workspace (FACTORY.md §4).",
			path
		)
	end
	if string.sub(path, 1, 2) == "\\\\" then
		return block(
			"out-of-workspace",
			"edit-unc",
			"editing a UNC/network path is outside the workspace (FACTORY.md §4).",
			path
		)
	end
	local isAbsolute = string.match(path, "^/") ~= nil or string.match(path, "^%a:[/\\]") ~= nil
	if not isAbsolute then
		if not isInside(workspaceRoot .. "/" .. path, workspaceRoot) then
			return block(
				"out-of-workspace",
				"edit-escape-root",
				"editing a path outside the workspace is fenced (FACTORY.md §4).",
				path
			)
		end
		return ALLOWED
	end
	if not isInside(path, workspaceRoot) then
		return block(
			"out-of-workspace",
			"edit-outside-workspace",
			"editing `" .. path .. "` outside the workspace root is fenced (FACTORY.md §4).",
			path
		)
	end
	return ALLOWED
end

Fence._internal = {
	tokenize = tokenize,
	splitSegments = splitSegments,
	expandIndirections = expandIndirections,
	expandVariables = expandVariables,
	parseSegment = parseSegment,
	normalizeHead = normalizeHead,
	normalizePath = normalizePath,
	isInside = isInside,
}

return Fence
