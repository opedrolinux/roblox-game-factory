--!strict
-- guard.luau — PreToolUse adapter for the factory autonomy fence (FACTORY.md §4).
--
-- Claude Code pipes the tool call as JSON on stdin. We decode it, route the command
-- (Bash/PowerShell) or file target (Edit/Write) through the pure Fence matcher, and:
--   * BLOCK  → write a structured reason to stderr and exit 2. For PreToolUse, exit 2
--              is the canonical, version-stable block: the tool never runs and the
--              reason is shown to the model.
--   * ALLOW  → exit 0 silently and let Claude Code's normal permission flow proceed
--              (where the settings.json deny-globs — layer 1 — still apply).
--
-- FAIL-OPEN by design: if stdin is missing/malformed or the tool is one we don't scan,
-- we exit 0. This hook is layer 2 (defense-in-depth); the authoritative layer-1 deny
-- list in settings.json is the backstop, so a parse failure here must never brick the
-- agent's ability to run safe commands. Every fail-open path notes itself on stderr.
--
-- Registered in .claude/settings.json under hooks.PreToolUse with matcher
-- "Bash|PowerShell|Edit|Write". Lune-only; never loaded in Roblox.

local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Fence = require("./lib/Fence")
local Log = require("./lib/Log")

-- Keep log lines bounded; a command can be arbitrarily long.
local function truncate(s: string, n: number): string
	if #s > n then
		return string.sub(s, 1, n) .. "...(+" .. tostring(#s - n) .. " chars)"
	end
	return s
end

local function allow(note: string?)
	if note then
		stdio.ewrite("[fence:guard] allow — " .. note .. "\n")
	end
	process.exit(0)
end

local function deny(decision: Fence.Decision)
	-- Structured, greppable, and human-readable. Shown to the model on exit 2.
	local msg = string.format(
		"[FENCE BLOCK] category=%s rule=%s\n%s\nOffending: %s\nThis action requires a human (see FACTORY.md §4). The factory queues it; it does not do it.\n",
		tostring(decision.category),
		tostring(decision.ruleId),
		tostring(decision.reason),
		tostring(decision.matched)
	)
	stdio.ewrite(msg)
	process.exit(2)
end

-- ── read + decode stdin (fail-open on any problem) ───────────────────────────
local raw = stdio.readToEnd()
if not string.match(raw, "%S") then
	allow("empty stdin")
	return
end

local ok, payload = pcall(serde.decode, "json", raw)
if not ok or type(payload) ~= "table" then
	allow("unparseable hook payload")
	return
end

local toolName = payload.tool_name
local toolInput = payload.tool_input
local cwd = payload.cwd

if type(toolInput) ~= "table" then
	allow("no tool_input")
	return
end

-- ── route by tool ────────────────────────────────────────────────────────────
local root = if type(cwd) == "string" then cwd else ""

if toolName == "Bash" or toolName == "PowerShell" then
	local command = toolInput.command
	if type(command) ~= "string" then
		allow("no command string")
		return
	end
	local shell: Fence.Shell = if toolName == "PowerShell" then "powershell" else "bash"
	local decision = Fence.evaluateCommand(command, shell, root)
	Log.event({
		source = "guard",
		tool = toolName,
		shell = shell,
		decision = if decision.blocked then "block" else "allow",
		category = decision.category,
		rule = decision.ruleId,
		cmd = truncate(command, 600),
		cwd = root,
	}, root)
	if decision.blocked then
		deny(decision)
	end
	allow()
elseif
	toolName == "Edit"
	or toolName == "Write"
	or toolName == "MultiEdit"
	or toolName == "NotebookEdit"
then
	local filePath = toolInput.file_path or toolInput.notebook_path
	if type(filePath) ~= "string" then
		allow("no file_path")
		return
	end
	local decision = Fence.evaluatePath(filePath, root)
	Log.event({
		source = "guard",
		tool = toolName,
		decision = if decision.blocked then "block" else "allow",
		category = decision.category,
		rule = decision.ruleId,
		path = filePath,
		cwd = root,
	}, root)
	if decision.blocked then
		deny(decision)
	end
	allow()
else
	-- not a tool this hook scans
	allow()
end
