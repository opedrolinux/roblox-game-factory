--!strict
-- gate-reachability.luau — the T1 STATIC REACHABILITY gate. "Written here, read nowhere."
--
-- WHY THIS EXISTS. An 81-agent audit of games/collect-sim found 66 confirmed defects, and 26 of them
-- were ONE pattern wearing different clothes:
--
--     A VALUE THE PLAYER PAYS FOR IS WRITTEN TO THE SAVE FILE, AND THE RULE THAT GOVERNS PLAY IS A
--     HARDCODED CONSTANT SITTING RIGHT NEXT TO IT, READING NOTHING.
--
-- `CAPACITY = 50` sat beside the persisted backpack level. `ABSORB_RADIUS = 6` sat beside the magnet
-- level. `WalkSpeed` appeared NOWHERE in the tree while the shop charged 50-500 Stardust a level for
-- it. Prisms were granted by rebirth, persisted, shown in the HUD, and decremented by nothing — the
-- entire prestige reward bought nothing. `boostExpiresUnix`/`lastClaimUnix`/`resetsAtUnix`/`dayNumber`
-- were replicated on every change and read by no client file. Maxing all four shop upgrades cost 9,625
-- Stardust and changed NOTHING measurable. 313 Lune tests were green through all of it, because the
-- tests asserted the WRITE and never the READ.
--
-- Every one of those is detectable WITHOUT AN ENGINE, WITHOUT RUNNING THE GAME, in milliseconds: they
-- are all "this identifier is written here and referenced nowhere". This gate walks the source and
-- asserts the reads exist. It is the cheapest gate in the factory and it covers the largest single
-- class of defect any game here has ever had. It is deliberately STRUCTURAL, not behavioural: other
-- specs prove the values are CORRECT, this one proves they are CONNECTED. A behavioural test can only
-- check the seams someone thought to wire; this one fails when a NEW seam is added and left dangling.
--
-- THE EIGHT RULES (ids are stable; readers key on them — never rename):
--   seam-read         a published seam method CALLED NOWHERE — not from another file, and not from its
--                     own module either (a dangling promise). Same-module calls count: applying a value
--                     where it is defined (`humanoid.WalkSpeed = Seam:walkSpeedFor(d)`) is the SUCCESS
--                     case, and an earlier "must be another file" version flagged it, which is exactly
--                     the false alarm that gets a gate switched off. A call counts only when it is
--                     ATTRIBUTABLE to THIS seam (its ident, or the `context.<field>` it is installed
--                     on): collect-sim publishes `multiplierFor` on three seams, and a bare-name match
--                     let two live ones certify the third — see the R1 ATTRIBUTION note below.
--   seam-installed    a `<X>Seam` table defined and never installed on `context` (dead code)
--   catalog-id-read   a shop/catalog id that appears only in the catalog + an order/validator list,
--                     never in a RULE. This is the 9,625-Stardust defect, stated structurally.
--   currency-sink     a currency that is granted but that nothing can SPEND (the Prisms defect)
--   view-field-read   a replicated PlayerView field (or a sub-field of a wholesale-copied table)
--                     that no client file reads — bandwidth paid for a value nobody looks at
--   banned-player-type  `type(player) == "table"` — a real Player is userdata. ONE such line kept the
--                     leaderboard empty in every live server forever WHILE PASSING EVERY TEST, because
--                     the harness fabricates players as plain tables: the bug and the mock that hid it
--                     were the same shape.
--   legacy-globals    bare wait/spawn/delay. DEFENCE IN DEPTH — it duplicates selene, and its
--                     greenness is NOT coverage; its only residual value is surviving a config drift.
--   presentation-floor  WARN-ONLY, reported in its own section: does the tree contain ANY lighting,
--                     sound, tween and leaderstats code at all. See the cautions on R8 below.
--
-- NON-VACUITY IS THE WHOLE POINT (FACTORY doctrine 1, 2, 5).
--   * There are NO numeric thresholds to relax. collect-sim's spec asserted `server > 10`,
--     `checked > 8`, `catalogIds >= 4` — those are collect-sim's current SIZE, not a contract, and the
--     first game that missed by one would get them relaxed to `> 0`, which is vacuity wearing a
--     counter. Presence is asserted as "at least one .luau under each Rojo mount", and every subject
--     count is EMITTED NUMERICALLY so a coverage collapse is visible instead of silent.
--   * At or above maturity, a rule that discovers ZERO subjects is a HARD FAIL, never a pass:
--     "discovery found no <subjects>: either the convention drifted or this gate is now blind."
--   * BELOW maturity (a freshly scaffolded game: no non-`sample` dir under src/server/services/, the
--     same probe gate-sample.luau uses — reused deliberately, not reinvented) the subject rules report
--     the third state `not-applicable`, tallied separately and NEVER counted as a pass. A fresh
--     scaffold MUST pass, or `new-game` is broken for every future game.
--   * A MONOTONIC BASELINE (tests/tier0/reachability-baseline.json) fails a DROP in subject count:
--     16 seams becoming 2 is the same lie as zero, and would otherwise pass silently. An ABSENT
--     baseline is a WARN plus the instruction to write one — never a FAIL, or every game is red on
--     day one. `M.run` NEVER writes anything.
--
-- THE VACUITY TRAP THIS GATE ITSELF HAD TO AVOID: substring matching on raw source. collect-sim's
-- version did `string.find(source, method, 1, true)` on a BARE method name, so a seam named `catalog`,
-- `apply`, `plan`, `get` or `emit` was "read" by a comment, a docstring, an unrelated field or a test
-- name — reporting a DANGLING SEAM AS CONNECTED. Avoided three ways:
--   (1) M.mask blanks the CONTENT of every string literal and every comment before any rule runs
--       (offsets preserved), so live code is what is left;
--   (2) every reference is REFERENCE-SHAPED — `[.:]name<boundary>` on masked source, or a quoted
--       literal `"name"` / `["name"]` on COMMENT-STRIPPED source. The quoted form is required because
--       real dispatch is sometimes dynamic (`tuningFrom(ctx, d, "magnetRadiusFor", …)`) and a
--       call-syntax-only rule reports a LIVE seam as dangling — a false alarm gets a gate switched
--       off, which is worse than no gate. Comments are stripped first, so a name in prose never counts;
--   (3) there is no `sourceRoot()` probing. collect-sim's spec fell back to a hardcoded
--       "games/collect-sim/src" candidate, which silently scans the WRONG TREE if some other `src`
--       exists at cwd. `gameDir` is an explicit, repo-root-relative argument and every path is built
--       from it.
--
-- WAIVERS. Per-game `<gameDir>/tests/verification-allow.json` (schema `verification-allow/1`). Every
-- entry needs `expiresUnix` (missing / non-numeric / past => the entry is INVALID and FAILS the rule it
-- names — a date in a comment expires nothing), a span of at most 30 days (no permanent waivers), and a
-- `file::Table.method` subject (BARE NAMES ARE REJECTED — collect-sim's INTERNAL_ONLY was keyed by bare
-- name, so exempting `tuningFor` exempted every `tuningFor` in the game). An entry that matched nothing
-- this run FAILS, because "stale waiver for a problem that was fixed" is how an allowlist rots into
-- blanket suppression. Every active waiver is echoed into the output; a waiver is never invisible.
--
--   GATE_REACHABILITY_CLI=1 lune run .claude/skills/lib/gate-reachability.luau <gameDir>
--   GATE_REACHABILITY_CLI=1 GATE_REACHABILITY_WRITE_BASELINE=1 lune run … <gameDir>   (writes baseline)
--
-- HANDOFF-1 (registration; NOT done by this file — gauntlet.luau/tier-ladder.luau are owned elsewhere):
--   .claude/skills/lib/gauntlet.luau  — add to the stages literal (~:116-122), beside the require stage:
--       local GateReachability = require("./gate-reachability")
--       …
--       GateReachability.run(dir),
--     The stage shape `{ name, ok, output }` already matches; the gauntlet ANDs every stage and exits 1
--     on any red, so nothing else changes.
--   .claude/skills/lib/tier-ladder.luau — this gate belongs to T1, NOT a new rung:
--       fromGauntlet's T1 mapping becomes statusOf({ "lune", "reachability" })
--     Reason: a reachability failure means the game's LOGIC is inert, which is exactly what T1 claims
--     to certify; T0.5's label is specifically require-resolution; and adding a rung reopens the RUNGS
--     contract and breaks tier_ladder_spec's label-prose assertions.
--   .claude/skills/lib/tests/run.luau — one line, to register the corpus:
--       local gateReachabilitySpec = require("./gate_reachability_spec")
--       runSpec("reachability gate", gateReachabilitySpec)
--
-- HANDOFF: propagate `coverage` (owner of gauntlet.luau / tier-status.luau — NOT done by this file).
--   WHY. This gate's Stage now carries a THIRD state beside `ok`. Below maturity (a fresh scaffold) the
--   five subject rules do not run, and the stage is `ok = true` with `coverage = "not-applicable"`. That
--   MUST keep passing — a fresh scaffold that goes red means `new-game` is broken for every future game
--   — but a consumer that reads only `ok` records "reachability: green" for a game where reachability
--   verified NOTHING. That is a silent zero-coverage pass, doctrine 2 failing at the one place a machine
--   looks. `ok` is unchanged; the new field is purely additive.
--   NOTE: `runGate` returns `result :: Stage`, a cast — so at RUNTIME the field already survives into
--   the encoded JSON line today. The diff below is what makes it TYPED and READ rather than incidental.
--
--   (1) .claude/skills/lib/gauntlet.luau:34 — widen the local Stage type (optional, so the four
--       subprocess stages and both in-process gates keep type-checking unchanged):
--     - type Stage = { name: string, ok: boolean, output: string }
--     + type Stage = { name: string, ok: boolean, output: string, coverage: string? }
--       …and in `runGate`'s throw branch (~:129-139) add `coverage = "not-applicable"` beside `ok =
--       false`, for the same reason this file does: a gate that threw verified nothing.
--
--   (2) .claude/skills/lib/tier-status.luau:59 — widen the parsed shape so the field is not dropped:
--     - local function runGauntlet(): { ok: boolean, stages: { { name: string, ok: boolean } } }?
--     + local function runGauntlet(): { ok: boolean, stages: { { name: string, ok: boolean, coverage: string? } } }?
--       and where a rung is decided from the reachability stage, treat
--       `stage.coverage == "not-applicable"` as NOT evidence: a rung must not be reported ready on the
--       strength of a stage that checked nothing. Degrade honestly — surface it as
--       "reachability: not-applicable (below maturity)" rather than folding it into green.
--
-- Pure static analysis: no Roblox, no Studio, no network. `M.classify` is PURE (no filesystem, no
-- os.time) so the RED fixtures in gate_reachability_spec.luau are cheap handwritten corpora — which is
-- how FALSIFY-FIRST is affordable here: every one of the eight rules has a recorded RED.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local gateSample = require("./gate-sample")

-- COVERAGE — the third state, made MACHINE-READABLE (review, 2026-08-02).
-- The maturity carve-out has always been honest in PROSE ("not-applicable is NOT a pass") and silent in
-- DATA: a freshly scaffolded game ran to `0 FAIL, EXIT 0` with all five subject rules `not-applicable`
-- and the stage boolean `true`, so the gauntlet — which reads only `ok` — recorded a plain green and a
-- game below maturity got a SILENT ZERO-COVERAGE PASS. That is doctrine 2 (non-vacuity) failing at the
-- one place a machine looks. The fix cannot be "fail the scaffold": a fresh scaffold MUST pass or
-- `new-game` is broken for every future game. So the distinction is carried alongside `ok` instead:
--   "verified"        the subject rules ran and had subjects to run against
--   "not-applicable"  they did not run — below maturity, or the gate itself could not run
-- `ok` keeps its meaning exactly (nothing regressed); a consumer that wants to know whether anything
-- was actually verified now has a field to read instead of a paragraph to parse. See HANDOFF below.
export type Coverage = "verified" | "not-applicable"
export type Stage = { name: string, ok: boolean, output: string, coverage: Coverage? }
export type Level = "FAIL" | "WARN"
export type Finding = {
	level: Level,
	rule: string,
	subject: string,
	file: string,
	line: number,
	msg: string,
}
export type RuleCount = { rule: string, subjects: number, applicable: boolean }
export type AllowEntry = {
	rule: string,
	subject: string,
	reason: string,
	addedUnix: number,
	addedBy: string,
	expiresUnix: number,
}
export type Allowlist = { entries: { AllowEntry } }
export type CorpusFile = { path: string, masked: string, raw: string }
export type Corpus = {
	gameDir: string,
	mounts: { string },
	files: { CorpusFile },
	mature: boolean,
	baseline: { [string]: number }?,
}
export type Decision = {
	ok: boolean,
	findings: { Finding },
	counts: { RuleCount },
	waivers: { AllowEntry },
	mature: boolean,
	coverage: Coverage,
}

local M = {}

-- Stable rule ids. Readers (the workflow lanes, the allowlist) key on these strings; never rename.
local RULE_SEAM_READ = "seam-read"
local RULE_SEAM_INSTALLED = "seam-installed"
local RULE_CATALOG_ID = "catalog-id-read"
local RULE_CURRENCY_SINK = "currency-sink"
local RULE_VIEW_FIELD = "view-field-read"
local RULE_BANNED_PLAYER = "banned-player-type"
local RULE_LEGACY_GLOBALS = "legacy-globals"
local RULE_PRESENTATION = "presentation-floor"
local RULE_ALLOWLIST = "allowlist"
local RULE_PRESENCE = "presence"

-- The five rules whose whole job is DISCOVERING subjects. Below maturity they are `not-applicable`;
-- at or above maturity, zero subjects is a hard FAIL.
local SUBJECT_RULES = {
	RULE_SEAM_READ,
	RULE_SEAM_INSTALLED,
	RULE_CATALOG_ID,
	RULE_CURRENCY_SINK,
	RULE_VIEW_FIELD,
}

local THIRTY_DAYS = 30 * 24 * 60 * 60

-- ── string/comment masker ─────────────────────────────────────────────────────
-- VERBATIM PORT of gate-require.luau:262-359's maskAndSpans, reduced to the masked string and given a
-- `blankStrings` switch. It is COPIED rather than required from a private local, deliberately: the two
-- gates are separately runnable stages and neither should be able to break the other by refactoring a
-- helper. If the two drift, the corpus in gate_reachability_spec.luau catches it (comment-only-reference
-- is RED only while masking works).
--
-- blankStrings = true  -> strings AND comments blanked  ("masked": live code only)
-- blankStrings = false -> comments blanked, strings KEPT ("code": needed for catalog ids, currency
--                         keys and dynamic-dispatch names, all of which ARE string literals)
-- Offsets and newlines are preserved in both modes, so a position in one maps to the other.
local function maskImpl(text: string, blankStrings: boolean): string
	local n = #text
	local chars: { string } = {}
	for i = 1, n do
		chars[i] = string.sub(text, i, i)
	end

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
				local close = "]" .. string.rep("=", eq) .. "]"
				local endStart = string.find(text, close, after :: number, true)
				local stop = if endStart ~= nil then endStart + #close - 1 else n
				blankRange(i, stop)
				i = stop + 1
			else
				local k = i
				while k <= n and chars[k] ~= "\n" do
					chars[k] = " "
					k += 1
				end
				i = k
			end
		elseif c == '"' or c == "'" then
			local k = i + 1
			while k <= n do
				local ck = string.sub(text, k, k)
				if ck == "\\" then
					if blankStrings then
						chars[k] = " "
						if k + 1 <= n and string.sub(text, k + 1, k + 1) ~= "\n" then
							chars[k + 1] = " "
						end
					end
					k += 2
				elseif ck == c or ck == "\n" then
					break
				else
					if blankStrings then
						chars[k] = " "
					end
					k += 1
				end
			end
			i = k + 1
		else
			local eq, after = longOpenAt(i)
			if eq ~= nil then
				local close = "]" .. string.rep("=", eq) .. "]"
				local endStart = string.find(text, close, after :: number, true)
				local contentEnd = if endStart ~= nil then endStart - 1 else n
				if blankStrings then
					blankRange(after :: number, contentEnd)
				end
				local stop = if endStart ~= nil then endStart + #close - 1 else n
				i = stop + 1
			else
				i += 1
			end
		end
	end

	return table.concat(chars)
end

-- Public: strings + comments blanked, OFFSETS PRESERVED.
function M.mask(source: string): string
	return maskImpl(source, true)
end

-- ── small helpers ─────────────────────────────────────────────────────────────
local function esc(s: string): string
	return (string.gsub(s, "([^%w])", "%%%1"))
end

local function baseName(path: string): string
	return (string.match(path, "([^/]+)$")) or path
end

type Span = { a: number, b: number }

-- A per-file working view. `code` (comments blanked, strings kept) is DERIVED here rather than stored
-- on Corpus, so a handwritten fixture corpus in the spec only has to supply {path, raw, masked}.
type FileView = {
	path: string,
	raw: string,
	masked: string,
	code: string,
	lineStarts: { number },
	isClient: boolean,
}

local function lineOf(fv: FileView, pos: number): number
	local found = 1
	for i = #fv.lineStarts, 1, -1 do
		if fv.lineStarts[i] <= pos then
			found = i
			break
		end
	end
	return found
end

-- Is `name` REFERENCE-SHAPED anywhere in this file? See the header's trap discussion: never a bare
-- substring. `[.:]name<boundary>` on masked code (a real field access / method call), or a quoted
-- literal on comment-stripped code (the dynamic-dispatch idiom, and table keys).
local function referencesName(fv: FileView, name: string): number?
	local e = esc(name)
	local s = string.find(fv.masked, "[%.:]" .. e .. "%f[^%w_]")
	if s ~= nil then
		return s
	end
	s = string.find(fv.code, '"' .. e .. '"', 1, false)
	if s ~= nil then
		return s
	end
	s = string.find(fv.code, "'" .. e .. "'", 1, false)
	return s
end

-- Exact offsets of every `.`/`:` that belongs to a DEFINITION of `ident.method`, so a definition can
-- be discounted as a "reference" without a fudge factor.
local function definitionSeparators(
	fv: FileView,
	ident: string,
	method: string
): { [number]: boolean }
	local e = esc(method)
	local defDots: { [number]: boolean } = {}
	for _, sep in { "%.", ":" } do
		local from = 1
		while true do
			local ds, de = string.find(
				fv.masked,
				"function%s+" .. esc(ident) .. "%s*" .. sep .. e .. "%f[^%w_]",
				from
			)
			if ds == nil or de == nil then
				break
			end
			defDots[de - #method] = true -- the separator char sits exactly #method back from the end
			from = de + 1
		end
	end
	return defDots
end

-- A seam method CALLED inside its own module is still a real read. collect-sim's
-- `humanoid.WalkSpeed = UpgradesSeam:walkSpeedFor(d)` applies the value to a real Humanoid in the very
-- file that defines it — that is the SUCCESS case for the defect this gate exists to catch, and the
-- first version of R1 reported it as dangling because it demanded an OTHER file. A gate that flags
-- correct code teaches authors to reach for a waiver, which is how a gate dies (see the caution at the
-- top of this file). So R1 also accepts a same-file reference, as long as it is not the definition
-- itself. Strength is unchanged for the real case: a method nothing calls ANYWHERE still fails, because
-- the definition site is excluded by exact offset, and a bare local `thresholdFor(x)` call is not
-- reference-shaped (no leading `.`/`:`) so it can never launder a dangling `Seam.thresholdFor`.
local function selfFileReferencesBesidesDefinition(
	fv: FileView,
	ident: string,
	method: string
): boolean
	local e = esc(method)
	local defDots = definitionSeparators(fv, ident, method)
	local from = 1
	while true do
		local s, fin = string.find(fv.masked, "[%.:]" .. e .. "%f[^%w_]", from)
		if s == nil or fin == nil then
			return false
		end
		if not defDots[s] then
			return true
		end
		from = fin + 1
	end
end

-- ── R1 ATTRIBUTION (review, 2026-08-02) ───────────────────────────────────────
-- THE HOMONYM HOLE. R1's reference test asked only whether the BARE METHOD NAME appeared, reference-
-- shaped, in some other file. games/collect-sim publishes `multiplierFor` on THREE separate seams
-- (IslandsSeam, RestockSeam, RebirthSeam). Orphaning any ONE of them stayed GREEN, because the other
-- two are live and the name matched somewhere. A name collision therefore MASKED a real orphan —
-- which is exactly the "written here, read nowhere" class this gate exists to catch, hiding inside the
-- gate that is supposed to catch it. (Falsified: this hole was real on collect-sim at HEAD.)
--
-- A reference now counts only when it can plausibly be to THIS seam. The seam's identity is two
-- tokens: its table ident (`RebirthSeam`) and the CONTEXT FIELD it is installed on (`context.rebirth =
-- RebirthSeam` -> `rebirth`) — discovery already anchored on that assignment and simply DISCARDED the
-- field. `ctx.islands:multiplierFor(d)` and `(ctx.rebirth :: any):previewFor(d)` are both attributable
-- by walking left from the `.`/`:` to the receiver expression and asking whether it names one of those
-- tokens.
--
-- TWO ESCAPE VALVES, both load-bearing, because a FALSE ALARM GETS A GATE SWITCHED OFF (header caution):
--   (a) A QUOTED LITERAL still counts, unattributed. Real dispatch here is sometimes DYNAMIC
--       (`tuningFrom(ctx, d, "magnetRadiusFor", …)`) and there is no receiver to attribute.
--   (b) A method published by exactly ONE seam keeps the OLD bare-name test. The false negative only
--       exists when a homonym is available to launder the match; with a unique name there is no other
--       seam the hit could belong to, so tightening there would buy nothing and could only manufacture
--       false alarms on receiver shapes this walker does not model (aliases, wrappers, `for _, s in
--       seams do s[name](…)`). The tightening is confined to exactly the collisions that caused it.
local function receiverTextBefore(masked: string, sepAt: number): string
	local i = sepAt - 1
	while i >= 1 and string.match(string.sub(masked, i, i), "%s") ~= nil do
		i -= 1
	end
	if i < 1 then
		return ""
	end
	local stop = i
	if string.sub(masked, i, i) == ")" then
		-- `(ctx.rebirth :: any):previewFor(d)` — the receiver is a parenthesised cast. Walk back to the
		-- MATCHING `(` so the whole cast expression is the receiver text; a naive "last identifier"
		-- would read `any` and attribute nothing.
		local depth = 0
		while i >= 1 do
			local c = string.sub(masked, i, i)
			if c == ")" then
				depth += 1
			elseif c == "(" then
				depth -= 1
				if depth == 0 then
					break
				end
			end
			i -= 1
		end
		return string.sub(masked, if i < 1 then 1 else i, stop)
	end
	while i >= 1 and string.match(string.sub(masked, i, i), "[%w_%.%[%]]") ~= nil do
		i -= 1
	end
	return string.sub(masked, i + 1, stop)
end

local function namesToken(text: string, token: string): boolean
	return string.find(text, "%f[%w_]" .. esc(token) .. "%f[^%w_]") ~= nil
end

-- ALIAS RESOLUTION (one hop). The walker above reads only the LITERAL receiver text, so
-- `local seamRef = ctx.restock :: any` followed by `seamRef:multiplierFor(d, ...)` -- correct code,
-- a live call site -- was reported as a DANGLING SEAM. That is a false alarm, and a false alarm gets
-- a gate switched off (header caution). So a local assigned from an expression naming one of a seam's
-- tokens becomes a token itself, for that file.
local function aliasTokensIn(fv: FileView, tokens: { string }): { string }
	local out: { string } = {}
	for ident, rhs in string.gmatch(fv.masked, "local%s+([%w_]+)%s*=([^%c]*)") do
		for _, token in tokens do
			if namesToken(rhs, token) then
				table.insert(out, ident)
				break
			end
		end
	end
	return out
end

local function withAliases(fv: FileView, tokens: { string }): { string }
	local out: { string } = {}
	for _, t in tokens do
		table.insert(out, t)
	end
	for _, a in aliasTokensIn(fv, tokens) do
		table.insert(out, a)
	end
	return out
end

-- Is there a call to `method` whose receiver this walker cannot resolve to ANY of `tokens`? A seam
-- arriving as a FUNCTION PARAMETER, or a loop over a table of seams, is correct code that no textual
-- walker can attribute. Failing an ambiguous method on that evidence would be a false alarm, so an
-- unresolved receiver SUPPRESSES the failure. The homonym catch is surrendered exactly where
-- attribution is impossible -- stated here, not hidden.
local function hasUnresolvedReceiver(all: { FileView }, method: string, tokens: { string }): boolean
	local pat = "([%w_]+)%s*[%.:]" .. esc(method) .. "%f[^%w_]"
	for _, fv in all do
		local known = withAliases(fv, tokens)
		local from = 1
		while true do
			local st, en, recv = string.find(fv.masked, pat, from)
			if st == nil or en == nil then
				break
			end
			local before =
				string.sub(fv.masked, math.max(1, (st :: number) - 12), (st :: number) - 1)
			if string.find(before, "function%s*$") == nil then
				local resolved = false
				for _, tok in known do
					if recv == tok then
						resolved = true
						break
					end
				end
				if not resolved then
					return true
				end
			end
			from = (en :: number) + 1
		end
	end
	return false
end

-- Is there a reference-shaped call to `method` in this file whose RECEIVER names one of `tokens`?
-- `skip` discounts the definition site itself (see selfFileReferencesBesidesDefinition).
local function attributedReference(
	fv: FileView,
	method: string,
	tokens: { string },
	skip: { [number]: boolean }?
): boolean
	local e = esc(method)
	local from = 1
	while true do
		local s, fin = string.find(fv.masked, "[%.:]" .. e .. "%f[^%w_]", from)
		if s == nil or fin == nil then
			return false
		end
		if skip == nil or not skip[s :: number] then
			local recv = receiverTextBefore(fv.masked, s :: number)
			for _, tok in tokens do
				if namesToken(recv, tok) then
					return true
				end
			end
		end
		from = fin + 1
	end
end

-- The dynamic-dispatch valve: `"magnetRadiusFor"` as a STRING LITERAL, on comment-stripped source so
-- prose never counts.
local function quotesName(fv: FileView, name: string): boolean
	local e = esc(name)
	return string.find(fv.code, '"' .. e .. '"', 1, false) ~= nil
		or string.find(fv.code, "'" .. e .. "'", 1, false) ~= nil
end

-- ── public: readByAnotherFile ─────────────────────────────────────────────────
-- The engine of the whole gate: "written here, read SOMEWHERE ELSE". Takes the Corpus so the pure
-- rules and the filesystem path share one implementation.
function M.readByAnotherFile(
	corpus: Corpus,
	needle: string,
	excludePath: string
): (boolean, string?)
	for _, f in corpus.files do
		if f.path ~= excludePath then
			local fv: FileView = {
				path = f.path,
				raw = f.raw,
				masked = f.masked,
				code = maskImpl(f.raw, false),
				lineStarts = { 1 },
				isClient = false,
			}
			if referencesName(fv, needle) ~= nil then
				return true, f.path
			end
		end
	end
	return false, nil
end

-- ── the pure classifier ───────────────────────────────────────────────────────
function M.classify(corpus: Corpus, allow: Allowlist, nowUnix: number): Decision
	local findings: { Finding } = {}
	local counts: { RuleCount } = {}
	local activeWaivers: { AllowEntry } = {}

	local function fail(rule: string, subject: string, file: string, line: number, msg: string)
		table.insert(
			findings,
			{ level = "FAIL", rule = rule, subject = subject, file = file, line = line, msg = msg }
		)
	end
	local function warn(rule: string, subject: string, file: string, line: number, msg: string)
		table.insert(
			findings,
			{ level = "WARN", rule = rule, subject = subject, file = file, line = line, msg = msg }
		)
	end

	-- ── file views ────────────────────────────────────────────────────────────
	local clientMounts: { string } = {}
	for _, m in corpus.mounts do
		if string.find(m, "client", 1, true) ~= nil then
			table.insert(clientMounts, m)
		end
	end
	local views: { FileView } = {}
	local byPath: { [string]: FileView } = {}
	for _, f in corpus.files do
		local starts: { number } = { 1 }
		for i = 1, #f.raw do
			if string.sub(f.raw, i, i) == "\n" then
				table.insert(starts, i + 1)
			end
		end
		local isClient = false
		for _, m in clientMounts do
			if string.sub(f.path, 1, #m) == m then
				isClient = true
			end
		end
		if not isClient and #clientMounts == 0 then
			isClient = string.find(f.path, "/client/", 1, true) ~= nil
		end
		local fv: FileView = {
			path = f.path,
			raw = f.raw,
			masked = f.masked,
			code = maskImpl(f.raw, false),
			lineStarts = starts,
			isClient = isClient,
		}
		table.insert(views, fv)
		byPath[f.path] = fv
	end
	table.sort(views, function(a, b)
		return a.path < b.path
	end)

	local function anyOtherFileReferences(name: string, excludePath: string): (boolean, string?)
		for _, fv in views do
			if fv.path ~= excludePath and referencesName(fv, name) ~= nil then
				return true, fv.path
			end
		end
		return false, nil
	end

	local function findBySuffix(suffix: string): FileView?
		for _, fv in views do
			if string.sub(fv.path, -#suffix) == suffix then
				return fv
			end
		end
		return nil
	end

	-- ── allowlist validation (S6) ─────────────────────────────────────────────
	-- Validated BEFORE the rules run, so an invalid entry cannot silently suppress a real FAIL. A
	-- waiver only suppresses if it is valid AND it matches something.
	type WaiverState = { entry: AllowEntry, valid: boolean, matched: boolean }
	local waiverStates: { WaiverState } = {}
	for _, raw in (allow.entries or {}) do
		local entry = raw
		local valid = true
		local why: string? = nil
		if type(entry.rule) ~= "string" or entry.rule == "" then
			valid, why = false, "missing `rule`"
		elseif
			type(entry.subject) ~= "string" or string.find(entry.subject, "::", 1, true) == nil
		then
			-- BARE NAMES ARE REJECTED. collect-sim's INTERNAL_ONLY was keyed by bare method name, so
			-- exempting `tuningFor` exempted EVERY `tuningFor` in the game.
			valid, why =
				false, "subject must be `file::Table.method` or `file::identifier`, not a bare name"
		elseif type(entry.expiresUnix) ~= "number" then
			-- A date in a comment expires nothing.
			valid, why = false, "missing or non-numeric `expiresUnix`"
		elseif entry.expiresUnix <= nowUnix then
			valid, why = false, "expired"
		elseif type(entry.addedUnix) ~= "number" then
			valid, why = false, "missing or non-numeric `addedUnix`"
		elseif entry.expiresUnix - entry.addedUnix > THIRTY_DAYS then
			valid, why = false, "spans more than 30 days — there are no permanent waivers"
		elseif type(entry.reason) ~= "string" or entry.reason == "" then
			valid, why = false, "missing `reason` prose"
		end
		if not valid then
			fail(
				RULE_ALLOWLIST,
				tostring(entry.subject),
				"tests/verification-allow.json",
				0,
				string.format(
					"waiver for rule %q subject %q is INVALID (%s) — it therefore FAILS the rule it names.",
					tostring(entry.rule),
					tostring(entry.subject),
					why or "?"
				)
			)
		end
		table.insert(waiverStates, { entry = entry, valid = valid, matched = false })
	end

	local function waived(rule: string, subject: string): boolean
		for _, w in waiverStates do
			if w.entry.rule == rule and w.entry.subject == subject then
				w.matched = true
				return w.valid
			end
		end
		return false
	end

	-- ── presence (non-vacuity by construction — NO numeric thresholds) ────────
	if #corpus.mounts == 0 then
		fail(
			RULE_PRESENCE,
			"default.project.json::tree",
			"default.project.json",
			0,
			"declares no $path mounts — there is no tree to scan, so nothing this gate reports means anything."
		)
	end
	for _, m in corpus.mounts do
		local found = false
		for _, fv in views do
			if string.sub(fv.path, 1, #m) == m then
				found = true
				break
			end
		end
		if not found then
			fail(
				RULE_PRESENCE,
				"mount::" .. m,
				"default.project.json",
				0,
				string.format(
					"Rojo mount %q contains no .luau file — the scan of that mount is vacuous.",
					m
				)
			)
		end
	end

	-- ── rule scaffolding ──────────────────────────────────────────────────────
	local subjectCount: { [string]: number } = {}
	local function countRule(rule: string, n: number, applicable: boolean)
		subjectCount[rule] = n
		table.insert(counts, { rule = rule, subjects = n, applicable = applicable })
		if applicable and n == 0 then
			fail(
				rule,
				rule .. "::discovery",
				"(corpus)",
				0,
				string.format(
					"discovery found no %s subjects: either the convention drifted or this gate is now blind. "
						.. "Zero subjects is a FAILURE, never a pass.",
					rule
				)
			)
		end
	end

	local mature = corpus.mature
	if not mature then
		-- The maturity carve-out. `not-applicable` is a THIRD state: reported, tallied, and never
		-- counted as a pass. A fresh scaffold MUST pass or `new-game` is broken for every future game
		-- with nothing in scaffold_spec to catch it (gate-sample.luau:11-15 doctrine).
		for _, rule in SUBJECT_RULES do
			table.insert(counts, { rule = rule, subjects = 0, applicable = false })
			subjectCount[rule] = 0
		end
	end

	-- ── R1/R2: seams ──────────────────────────────────────────────────────────
	-- Discovery anchors on a CORE-OWNED location (`context.<field> = <ident>` under
	-- src/server/services/), so it yields the installed table under ANY naming scheme — IslandsSeam,
	-- IslandsApi, plain M. `%w+Seam` is an ADDITIONAL matcher, never the definition: `Seam` has ZERO
	-- hits in core/src; it is a contract-pass convention, not a fork-base idiom.
	-- REJECTED: a per-game subject manifest. The defect class is "a value was added and never wired",
	-- and a manifest asks the same agent, in the same turn, from the same misunderstanding, to declare
	-- the thing they just forgot to wire. An empty manifest scores 100%.
	if mature then
		-- `fields` are the CONTEXT FIELDS this seam is installed on. Captured, not discarded: they are
		-- what makes `ctx.islands:multiplierFor(d)` attributable to IslandsSeam and NOT to the two other
		-- seams that publish the same method name (see the R1 ATTRIBUTION note above).
		type SeamTable = { ident: string, path: string, installed: boolean, fields: { string } }
		local seams: { SeamTable } = {}
		local seamIndex: { [string]: SeamTable } = {}

		local function noteSeam(ident: string, path: string): SeamTable
			local key = path .. "::" .. ident
			local existing = seamIndex[key]
			if existing ~= nil then
				return existing
			end
			local t: SeamTable = { ident = ident, path = path, installed = false, fields = {} }
			seamIndex[key] = t
			table.insert(seams, t)
			return t
		end

		local function noteField(t: SeamTable, field: string)
			for _, f in t.fields do
				if f == field then
					return
				end
			end
			table.insert(t.fields, field)
		end

		-- (a) install sites: the core-owned anchor. Both captures are used now — the FIELD is the seam's
		-- public name, the IDENT is its private one.
		for _, fv in views do
			if string.find(fv.path, "/server/services/", 1, true) ~= nil then
				for field, ident in
					string.gmatch(fv.masked, "context%.([%w_]+)%s*=%s*([%w_]+)%f[^%w_]")
				do
					local t = noteSeam(ident, fv.path)
					t.installed = true
					noteField(t, field)
				end
			end
		end
		-- (b) the `%w+Seam` convention, so an UNINSTALLED seam table is still discovered (R2).
		for _, fv in views do
			for ident in string.gmatch(fv.masked, "local%s+([%w_]*Seam)%s*=") do
				noteSeam(ident, fv.path)
			end
		end
		-- an ident installed in one file but declared in another still needs its methods enumerated —
		-- and its field captured, or a cross-file install would silently lose the attribution token.
		for _, t in seams do
			for _, fv in views do
				for field in
					string.gmatch(
						fv.masked,
						"context%.([%w_]+)%s*=%s*" .. esc(t.ident) .. "%f[^%w_]"
					)
				do
					t.installed = true
					noteField(t, field)
				end
			end
		end

		-- R1 seam-read. Methods are enumerated for EVERY seam first, so a HOMONYM — the same method
		-- name published by two or more seams — is visible before any of them is judged.
		type SeamMethod = { seam: SeamTable, method: string }
		local seamMethods: { SeamMethod } = {}
		local publishers: { [string]: number } = {}
		local publisherSeen: { [string]: boolean } = {}
		for _, t in seams do
			local fv = byPath[t.path]
			if fv ~= nil then
				for method in
					string.gmatch(fv.masked, "function%s+" .. esc(t.ident) .. "%.([%w_]+)%s*%(")
				do
					table.insert(seamMethods, { seam = t, method = method })
					local key = method .. "@" .. t.path .. "::" .. t.ident
					if not publisherSeen[key] then
						publisherSeen[key] = true
						publishers[method] = (publishers[method] or 0) + 1
					end
				end
			end
		end

		for _, sm in seamMethods do
			local t = sm.seam
			local fv = byPath[t.path] :: FileView
			local method = sm.method
			local subject = string.format("%s::%s.%s", baseName(t.path), t.ident, method)
			local tokens: { string } = { t.ident }
			for _, f in t.fields do
				table.insert(tokens, f)
			end
			local ambiguous = (publishers[method] or 0) > 1

			-- (1) the DYNAMIC-DISPATCH valve: a quoted literal counts, with no receiver to attribute.
			local found = false
			for _, other in views do
				if quotesName(other, method) then
					found = true
					break
				end
			end
			-- (2) an ATTRIBUTED call: the receiver names this seam's ident or one of its context fields.
			-- In the seam's OWN file the definition separator is discounted by exact offset, so a
			-- definition can never reference itself.
			if not found then
				local skip = definitionSeparators(fv, t.ident, method)
				for _, other in views do
					if
						attributedReference(
							other,
							method,
							withAliases(other, tokens),
							if other.path == fv.path then skip else nil
						)
					then
						found = true
						break
					end
				end
			end
			-- (3) UNIQUE-NAME fallback: with exactly one publisher there is no homonym to launder a
			-- match, so the original bare-name test still applies. See valve (b) above.
			if not found and not ambiguous then
				found = anyOtherFileReferences(method, t.path)
				if not found then
					found = selfFileReferencesBesidesDefinition(fv, t.ident, method)
				end
			end

			-- (4) CONSERVATIVE VALVE. Before failing an AMBIGUOUS method, ask whether any call to it has a
			-- receiver no walker could attribute (a parameter, a loop variable). If so this is not evidence
			-- of an orphan, and failing would be a false alarm on correct code.
			local unresolved = false
			if not found and ambiguous then
				unresolved = hasUnresolvedReceiver(views, method, tokens)
				if unresolved then
					found = true
					warn(
						RULE_SEAM_READ,
						subject,
						t.path,
						0,
						string.format(
							"seam method `%s.%s` shares its name with %d other publisher(s) and is called through a "
								.. "receiver this gate cannot attribute (a parameter or a loop variable), so it cannot be proven read OR unread. Not failed, because a false alarm gets a gate switched off — but it is NOT covered.",
							t.ident,
							method,
							(publishers[method] or 1) - 1
						)
					)
				end
			end
			if not found and not waived(RULE_SEAM_READ, subject) then
				local at =
					string.find(fv.masked, "function%s+" .. esc(t.ident) .. "%." .. esc(method))
				fail(
					RULE_SEAM_READ,
					subject,
					t.path,
					if at ~= nil then lineOf(fv, at) else 0,
					string.format(
						"seam method `%s.%s` is defined and CALLED NOWHERE — no call whose receiver names `%s` or "
							.. "`context.%s`, no dynamic dispatch by quoted name, and nothing inside its own module.%s "
							.. "A dangling seam is a promise that gameplay code will read what this feature writes, "
							.. "unkept. Delete it, wire it, or add a DATED waiver (rule `%s`, subject `%s`).",
						t.ident,
						method,
						t.ident,
						if #t.fields > 0
							then table.concat(t.fields, "`/`context.")
							else "<uninstalled>",
						if ambiguous
							then string.format(
								" NOTE: `%s` is published by %d different seams here, so a bare-name match on it proves "
									.. "nothing about THIS one — that homonym is precisely what used to hide this orphan.",
								method,
								publishers[method]
							)
							else "",
						RULE_SEAM_READ,
						subject
					)
				)
			end
		end
		countRule(RULE_SEAM_READ, #seamMethods, true)

		-- R2 seam-installed. Closes R1's blind spot: R1 can only see seams that WERE installed.
		-- Narrowed deliberately to the `%w+Seam` convention (documented, not silent): a table named
		-- for a Context field would need Context.luau parsing, and a false FAIL on a plain local table
		-- is exactly the noise that gets a gate switched off.
		local seamTables = 0
		for _, t in seams do
			if string.match(t.ident, "Seam$") ~= nil then
				seamTables += 1
				local subject = string.format("%s::%s", baseName(t.path), t.ident)
				if not t.installed and not waived(RULE_SEAM_INSTALLED, subject) then
					fail(
						RULE_SEAM_INSTALLED,
						subject,
						t.path,
						0,
						string.format(
							"seam table `%s` is defined but never installed on `context.<field>` — nothing can reach "
								.. "it, so every method on it is dead code no matter how well tested.",
							t.ident
						)
					)
				end
			end
		end
		countRule(RULE_SEAM_INSTALLED, seamTables, true)
	end

	-- ── R3: catalog-id-read ───────────────────────────────────────────────────
	-- THE 9,625-Stardust defect, stated structurally. Before the fix, each of `collect-speed`,
	-- `backpack`, `magnet`, `walk-speed` appeared EXACTLY TWICE in the whole codebase: once in the
	-- catalog and once in a validator/order list — never in a RULE. Discovery is by SHAPE, never by
	-- filename: `fileNamed("UpgradesShopService.luau")` is collect-sim's shop, not a core file. The
	-- core anchor is Types.luau's reserved `upgrades: { [string]: number }`, present in every fork.
	if mature then
		local ids: { string } = {}
		local idSet: { [string]: boolean } = {}
		local idHome: { [string]: FileView } = {}
		local excluded: { [string]: { Span } } = {}

		local function addId(id: string, fv: FileView)
			if not idSet[id] then
				idSet[id] = true
				idHome[id] = fv
				table.insert(ids, id)
			end
		end

		for _, fv in views do
			excluded[fv.path] = {}
			if string.find(fv.path, "/server/services/", 1, true) ~= nil then
				local from = 1
				while true do
					local s = string.find(fv.code, "local%s+CATALOG[%w_]*", from)
					if s == nil then
						break
					end
					-- Find the ASSIGNMENT `=` first, then the literal. `local CATALOG: { [string]:
					-- CatalogEntry } = { … }` carries a TYPE ANNOTATION whose braces come first; a
					-- naive "next {" scanned the annotation and reported ZERO catalog ids — which the
					-- zero-subjects FAIL caught immediately, exactly as designed.
					local eqAt = string.find(fv.code, "=", s :: number, true)
					if eqAt == nil then
						break
					end
					local braceAt = string.find(fv.code, "{", eqAt :: number, true)
					if braceAt == nil then
						break
					end
					local a, b = string.find(fv.code, "%b{}", braceAt :: number)
					if a == nil then
						break
					end
					table.insert(excluded[fv.path], { a = a :: number, b = b :: number })
					local body = string.sub(fv.code, a :: number, b :: number)
					for id in string.gmatch(body, '%["([%w%-_]+)"%]%s*=') do
						addId(id, fv)
					end
					from = (b :: number) + 1
				end
			end
			-- the core-owned second anchor: any persisted upgrade key, wherever it is read.
			for id in string.gmatch(fv.code, '%.upgrades%["([%w%-_]+)"%]') do
				addId(id, fv)
			end
		end

		-- Order lists and pure validator lists are NOT reads. `{ "collect-speed", "backpack", … }`
		-- renders rows / validates input; it never makes an upgrade DO anything.
		for _, fv in views do
			local pos = 1
			while true do
				local braceAt = string.find(fv.code, "{", pos, true)
				if braceAt == nil then
					break
				end
				local a, b = string.find(fv.code, "%b{}", braceAt :: number)
				if a == nil then
					break
				end
				local body = string.sub(fv.code, a :: number, b :: number)
				local total, known = 0, 0
				for lit in string.gmatch(body, '"([%w%-_]+)"') do
					total += 1
					if idSet[lit] then
						known += 1
					end
				end
				if total >= 2 and total == known then
					table.insert(excluded[fv.path], { a = a :: number, b = b :: number })
				end
				pos = (braceAt :: number) + 1
			end
		end

		local function inExcluded(fv: FileView, pos: number): boolean
			for _, sp in excluded[fv.path] do
				if pos >= sp.a and pos <= sp.b then
					return true
				end
			end
			return false
		end

		-- A COMPARISON IS NOT A READ. Falsification restored the 9,625 defect in its exact historical
		-- form — `magnetRadiusFor` kept, still compiling, still returning a radius, but with
		-- `levelOf(d, "magnet")` replaced by the bare constant — and this rule reported 0 FAIL, because
		-- `elseif upgradeId == "magnet"` in the shop's own effect-PREVIEW dispatcher counted as a read.
		-- That is the UI label branch: it tells the player what they would get. It governs nothing.
		-- The real read is a CALL ARGUMENT (`levelOf(d, "magnet")`) or an index of the core-owned
		-- persisted table (`d.upgrades["magnet"]`); an operand of `==`/`~=` is dispatch, not tuning.
		-- Deliberately NOT keyed on the name `levelOf`, which is collect-sim's invention and appears
		-- nowhere in core/src — the SHAPE generalises, the helper's name does not.
		local function isComparisonOperand(fv: FileView, quoteAt: number): boolean
			local i = quoteAt - 1
			while i >= 1 and string.match(string.sub(fv.code, i, i), "%s") ~= nil do
				i -= 1
			end
			if i < 2 then
				return false
			end
			local pair = string.sub(fv.code, i - 1, i)
			return pair == "==" or pair == "~="
		end

		for _, id in ids do
			local home = idHome[id]
			local subject = string.format("%s::catalog.%s", baseName(home.path), id)
			local read = false
			local comparisonOnly = false
			for _, fv in views do
				local from = 1
				while true do
					local s = string.find(fv.code, '"' .. esc(id) .. '"', from)
					if s == nil then
						break
					end
					if not inExcluded(fv, s :: number) then
						if isComparisonOperand(fv, s :: number) then
							comparisonOnly = true
						else
							read = true
							break
						end
					end
					from = (s :: number) + 1
				end
				if read then
					break
				end
			end
			if not read and not waived(RULE_CATALOG_ID, subject) then
				fail(
					RULE_CATALOG_ID,
					subject,
					home.path,
					0,
					string.format(
						"catalog id %q is never READ by a rule%s. The player can buy it and NOTHING changes. This "
							.. "is the defect that cost 9,625 Stardust for no measurable effect while 313 tests stayed "
							.. "green. A read is a call argument (`levelOf(d, %q)`) or an index of the persisted table "
							.. "(`d.upgrades[%q]`) — not a catalog entry, not an order/validator list, and not an "
							.. "`==` branch.",
						id,
						if comparisonOnly
							then " — it appears ONLY as an `==` dispatch operand, which is a UI/label branch, not tuning"
							else " — it appears only in the catalog literal and an order/validator list",
						id,
						id
					)
				)
			end
		end
		countRule(RULE_CATALOG_ID, #ids, true)
	end

	-- ── R4: currency-sink ─────────────────────────────────────────────────────
	-- Subject set is the `currencies = { … }` literal in Migrations.default — a CORE-OWNED location
	-- (core/src/shared/Migrations.luau:22), present in every fork the moment it is scaffolded.
	-- The defect: Prisms were granted by rebirth, persisted, and shown in the HUD, and NOTHING in the
	-- codebase ever decremented them. There was no Prism shop, no Prism pad, no action anywhere that
	-- lowered the balance — the entire prestige reward bought nothing.
	if mature then
		local currencies: { string } = {}
		local migrations = findBySuffix("shared/Migrations.luau")
		if migrations ~= nil then
			local a, b = string.find(migrations.code, "currencies%s*=%s*%b{}")
			if a ~= nil then
				local body = string.sub(migrations.code, a :: number, b :: number)
				for key in string.gmatch(body, "([%w_]+)%s*=") do
					if key ~= "currencies" then
						table.insert(currencies, key)
					end
				end
			end
		end

		-- REBUILT after a falsification run restored the Prisms defect VERBATIM — it deleted the game's
		-- only Prism-denominated purchase (`currency = "Prisms"` in the shop catalog) and this rule
		-- reported 0 FAIL. The hole: `namesCurrency` and `fileCanSpend` were evaluated INDEPENDENTLY over
		-- the same file, so UpgradesShopService.luau "sank" Prisms because it mentioned
		-- `d.currencies.Prisms` in a READ-ONLY balance echo while spending STARDUST two hundred lines
		-- away. A currency was certified sunk by a file that only ever ADDED it. The rule now requires
		-- THE SPEND SITE ITSELF TO NAME THE CURRENCY IT SPENDS.
		--
		-- Three accepted spend shapes, because the real idiom in this factory is DYNAMIC and a
		-- literal-only rule would report every live shop as sink-less (a false alarm gets a gate
		-- switched off, which is worse than no gate):
		--   (1) `currencies.<Key> -= …`             — unambiguous.
		--   (2) `currencies.<Key> = …-…` same line  — a literal write whose RHS subtracts.
		--   (3) `currencies[<expr>] = …` + a subtraction in the file + THE FILE DECLARING
		--       `currency = "<Key>"` — collect-sim's actual shape (`d.currencies[entry.currency] =
		--       newBalance`, the key resolved from the catalog entry). The declaration is what binds the
		--       dynamic index to a concrete currency, so deleting the declaration — which IS the Prisms
		--       defect — removes the sink, exactly as it should.
		-- A grant is NOT a spend: `d.currencies.Prisms = (d.currencies.Prisms or 0) + earned` carries no
		-- subtraction on its line, so the file that GRANTS a currency can no longer certify it sunk.
		local subtractPatterns = {
			"%-%s*[%w_%.]*[Cc]ost",
			"%-%s*[%w_%.]*[Pp]rice",
			"%-%s*[%w_%.]*[Aa]mount",
			"%-%s*[%w_%.]*[Ss]pend",
			"%-=%s*",
		}
		local function hasSubtraction(fv: FileView): boolean
			for _, p in subtractPatterns do
				if string.find(fv.code, p) ~= nil then
					return true
				end
			end
			return false
		end
		-- Shapes (1) and (2): the write target itself names the key.
		local function literalSpend(fv: FileView, key: string): boolean
			local k = esc(key)
			for _, idx in { "%." .. k, '%["' .. k .. '"%]' } do
				if string.find(fv.code, "currencies" .. idx .. "%s*%-=") ~= nil then
					return true
				end
				if string.find(fv.code, "currencies" .. idx .. "%s*=[^\r\n]*%-") ~= nil then
					return true
				end
			end
			return false
		end
		-- Shape (3): a dynamic balance write, plus a declaration binding that index to THIS key.
		local function declaresCurrency(fv: FileView, key: string): boolean
			local k = esc(key)
			return string.find(fv.code, 'currency%s*=%s*"' .. k .. '"') ~= nil
				or string.find(fv.code, '%["currency"%]%s*=%s*"' .. k .. '"') ~= nil
		end
		-- BIND THE SUBTRACTION TO THE WRITE. This rule first shipped asking only "does a subtraction
		-- appear ANYWHERE in this file", which an adversarial pass laundered: change the shop's
		-- `local newBalance = balance - cost` to `local newBalance = balance` -- every purchase now
		-- FREE -- and the file still contained an unrelated `- cost` on a display path, so the currency
		-- was still certified sunk. A whole-file scan cannot tell a charge from a label. So: follow the
		-- value that is actually STORED -- same-line subtraction, or ONE hop back to the local it came
		-- from.
		local function identFromSubtraction(fv: FileView, ident: string): boolean
			local from = 1
			local pat = "%f[%w_]" .. esc(ident) .. "%s*=[^=%c][^%c]*"
			while true do
				local s, e = string.find(fv.code, pat, from)
				if s == nil or e == nil then
					return false
				end
				if string.find(string.sub(fv.code, s, e), "%-") ~= nil then
					return true
				end
				from = e + 1
			end
		end
		local function dynamicSpend(fv: FileView, key: string): boolean
			if not declaresCurrency(fv, key) then
				return false
			end
			local from = 1
			while true do
				local s, e = string.find(fv.code, "currencies%b[]%s*=", from)
				if s == nil or e == nil then
					return false
				end
				local lineEnd = string.find(fv.code, string.char(10), e, true) or (#fv.code + 1)
				local rhs = string.sub(fv.code, e + 1, lineEnd - 1)
				if string.find(rhs, "%-") ~= nil then
					return true
				end
				local ident = string.match(rhs, "^%s*([%w_]+)%s*$")
				if ident ~= nil and identFromSubtraction(fv, ident) then
					return true
				end
				from = e + 1
			end
		end
		local function namesCurrency(fv: FileView, key: string): boolean
			if string.find(fv.code, '"' .. esc(key) .. '"') ~= nil then
				return true
			end
			return string.find(fv.masked, "currencies%." .. esc(key) .. "%f[^%w_]") ~= nil
		end

		for _, key in currencies do
			local subject = string.format("Migrations.luau::currencies.%s", key)
			local granted, sunk = false, false
			for _, fv in views do
				local isContract = string.find(fv.path, "shared/Migrations.luau", 1, true) ~= nil
					or string.find(fv.path, "shared/Types.luau", 1, true) ~= nil
				if not isContract and namesCurrency(fv, key) then
					granted = true
					if literalSpend(fv, key) or dynamicSpend(fv, key) then
						sunk = true
					end
				end
			end
			if not granted and not waived(RULE_CURRENCY_SINK, subject) then
				fail(
					RULE_CURRENCY_SINK,
					subject,
					"src/shared/Migrations.luau",
					0,
					string.format(
						"currency %q is seeded in the save file and named by no gameplay file at all — it is "
							.. "persisted dead weight.",
						key
					)
				)
			elseif granted and not sunk and not waived(RULE_CURRENCY_SINK, subject) then
				fail(
					RULE_CURRENCY_SINK,
					subject,
					"src/shared/Migrations.luau",
					0,
					string.format(
						"currency %q is GRANTED but has NO SINK — no file that names it also decrements a balance "
							.. "against a cost/price. The player accumulates a number that buys nothing (the Prisms "
							.. "defect: granted, persisted, displayed, decremented by nothing).",
						key
					)
				)
			end
		end
		countRule(RULE_CURRENCY_SINK, #currencies, true)
	end

	-- ── R5: view-field-read ───────────────────────────────────────────────────
	-- The client-facing half of the same pattern: the server pays the bandwidth to replicate a field
	-- every time it changes and no code on the receiving end ever looks at it. `boostExpiresUnix`,
	-- `lastClaimUnix`, `resetsAtUnix`, `dayNumber` were all in this state.
	--
	-- THREE HARDENINGS the collect-sim version lacked, each load-bearing:
	--  (1) It parsed the body with `"function Types%.toView.-\nend"` — NON-GREEDY to the FIRST `\nend`,
	--      so ANY `if`/`for` inside silently truncates the field list. We take the balanced `return {…}`
	--      instead, AND cross-check the field count against the exported PlayerView type. A mismatch is
	--      a FAIL — which also catches a field added to PlayerView and never projected.
	--      No magic `checked >= 6`.
	--  (2) `string.find(src, "." .. field, true)` means `.stats` is satisfied by `.statsPanel` and
	--      `.day` by `.dayNumber`. Reader matching is word-boundary, on masked source.
	--  (3) WHOLESALE-COPY BLINDNESS IS NEAR-TOTAL IN CORE: all five fields core's toView projects are
	--      copied TABLES, so a naive rule checks five table names, calls itself complete, and
	--      `stats.lifetimeStardust` rides along invisibly. We recurse EXACTLY ONE LEVEL into the
	--      PlayerData type for any projected field whose value is a table, and treat each sub-field as
	--      its own subject. Map types (`{ [string]: number }`) have no named sub-fields — nothing to
	--      recurse into, and saying so is honest, not a skip.
	local VIEW_RECURSION_DEPTH = 1
	if mature then
		local subjects = 0
		local types = findBySuffix("shared/Types.luau")
		if types == nil then
			countRule(RULE_VIEW_FIELD, 0, true)
		else
			local tv = types :: FileView
			-- top-level `name: <type>` entries of a `{ … }` type literal
			local function topLevelFields(body: string): ({ string }, { [string]: string })
				local order: { string } = {}
				local typeOf: { [string]: string } = {}
				local depth = 0
				local i = 1
				local n = #body
				local pendingName: string? = nil
				local valueStart = 0
				while i <= n do
					local c = string.sub(body, i, i)
					if c == "{" then
						depth += 1
					elseif c == "}" then
						depth -= 1
						if depth == 0 and pendingName ~= nil then
							typeOf[pendingName :: string] = string.sub(body, valueStart, i - 1)
							pendingName = nil
						end
					elseif depth == 1 then
						if c == "," and pendingName ~= nil then
							typeOf[pendingName :: string] = string.sub(body, valueStart, i - 1)
							pendingName = nil
						else
							local ns, ne, name = string.find(body, "^([%a_][%w_]*)%s*:", i)
							if ns ~= nil and pendingName == nil then
								table.insert(order, name :: string)
								pendingName = name :: string
								valueStart = (ne :: number) + 1
								i = ne :: number
							end
						end
					end
					i += 1
				end
				return order, typeOf
			end

			local function typeBody(name: string): string?
				local a, b = string.find(tv.code, "export%s+type%s+" .. name .. "%s*=%s*%b{}")
				if a == nil then
					return nil
				end
				local ba = string.find(tv.code, "{", a :: number, true)
				return string.sub(tv.code, ba :: number, b :: number)
			end

			local viewBody = typeBody("PlayerView")
			local dataBody = typeBody("PlayerData")

			-- the PROJECTION: the balanced `return { … }` inside Types.toView. Immune to nested blocks.
			local projected: { string } = {}
			local fnAt = string.find(tv.code, "function%s+[%w_]+%.toView")
			if fnAt ~= nil then
				local rs = string.find(tv.code, "return%s*{", fnAt :: number)
				if rs ~= nil then
					local ba = string.find(tv.code, "{", rs :: number, true)
					local a, b = string.find(tv.code, "%b{}", ba :: number)
					if a ~= nil then
						local body = string.sub(tv.code, a :: number, b :: number)
						for field in string.gmatch(body, "([%w_]+)%s*=%s*[%w_]+%.") do
							table.insert(projected, field)
						end
					end
				end
			end

			if #projected == 0 then
				fail(
					RULE_VIEW_FIELD,
					"Types.luau::toView",
					tv.path,
					0,
					"could not parse the `return { … }` projection out of Types.toView — a check that could not "
						.. "run is a FAILURE, never a skip."
				)
			end

			if viewBody ~= nil then
				local viewFields = topLevelFields(viewBody :: string)
				if #viewFields ~= #projected and #projected > 0 then
					fail(
						RULE_VIEW_FIELD,
						"Types.luau::PlayerView",
						tv.path,
						0,
						string.format(
							"the exported PlayerView type declares %d fields but Types.toView projects %d — either a "
								.. "field was added to the type and never projected (it will be nil on every client), "
								.. "or the projection parse is truncated and every assertion below it is vacuous.",
							#viewFields,
							#projected
						)
					)
				end
			else
				fail(
					RULE_VIEW_FIELD,
					"Types.luau::PlayerView",
					tv.path,
					0,
					"no exported `PlayerView` type found — the projection cannot be cross-checked, so this rule "
						.. "cannot know it is complete."
				)
			end

			-- one-level recursion into PlayerData for wholesale-copied tables
			local dataOrder, dataType = {}, {}
			if dataBody ~= nil then
				dataOrder, dataType = topLevelFields(dataBody :: string)
			end
			local _ = dataOrder

			type ViewSubject = { label: string, name: string }
			local checkList: { ViewSubject } = {}
			for _, field in projected do
				table.insert(checkList, { label = field, name = field })
				local t = dataType[field]
				if t ~= nil then
					local trimmed = (string.match(t, "^%s*(.-)%s*$")) :: string
					-- a TABLE type, but not a map (`{ [string]: … }` has no named sub-fields)
					if
						string.sub(trimmed, 1, 1) == "{"
						and string.match(trimmed, "^{%s*%[") == nil
					then
						local subOrder = topLevelFields(trimmed)
						for _, sub in subOrder do
							table.insert(checkList, { label = field .. "." .. sub, name = sub })
						end
					end
				end
			end

			for _, s in checkList do
				subjects += 1
				local subject = "Types.luau::PlayerView." .. s.label
				local read = false
				for _, fv in views do
					if fv.isClient and referencesName(fv, s.name) ~= nil then
						read = true
						break
					end
				end
				if not read and not waived(RULE_VIEW_FIELD, subject) then
					fail(
						RULE_VIEW_FIELD,
						subject,
						tv.path,
						0,
						string.format(
							"replicated field `%s` is read by NO client file — the server pays the bandwidth to push "
								.. "it on every change and nothing on the receiving end looks at it.",
							s.label
						)
					)
				end
			end
			countRule(RULE_VIEW_FIELD, subjects, true)
		end
	end

	-- ── R6: banned-player-type ────────────────────────────────────────────────
	-- ONE line kept the leaderboard empty in every live server, forever, while passing every test —
	-- because the harness fabricates players as plain tables, which is exactly the shape the broken
	-- guard accepts. The bug and the mock that hid it were the same shape. A real Player is userdata.
	do
		local offenders = 0
		for _, fv in views do
			local from = 1
			while true do
				-- On `code` (comments blanked, STRINGS KEPT), never on `masked`: masking blanks the
				-- content of `"table"` itself, so the pattern could never match its own literal.
				local s = string.find(
					fv.code,
					"type%s*%(%s*[%w_]*[Pp]layer[%w_]*%s*%)%s*==%s*[\"']table",
					from
				)
				if s == nil then
					break
				end
				offenders += 1
				local subject = string.format(
					'%s::type(player)=="table"@%d',
					baseName(fv.path),
					lineOf(fv, s :: number)
				)
				if not waived(RULE_BANNED_PLAYER, subject) then
					fail(
						RULE_BANNED_PLAYER,
						subject,
						fv.path,
						lineOf(fv, s :: number),
						'`type(player) == "table"` — a real Roblox Player is USERDATA, so this guard is false in '
							.. "every live server and true only in the test harness that mocks players as tables."
					)
				end
				from = (s :: number) + 1
			end
		end
		table.insert(counts, { rule = RULE_BANNED_PLAYER, subjects = #views, applicable = true })
	end

	-- ── R7: legacy-globals — DEFENCE IN DEPTH (duplicates selene) ─────────────
	-- Its greenness is NOT coverage. selene's roblox-fenced std already bans these; the only residual
	-- value of this rule is surviving a selene-config drift, and it is labelled that way in the output
	-- so nobody mistakes it for a signal it is not.
	do
		for _, fv in views do
			for _, pattern in { "\n%s*wait%s*%(", "\n%s*spawn%s*%(", "\n%s*delay%s*%(" } do
				local from = 1
				while true do
					local s = string.find(fv.masked, pattern, from)
					if s == nil then
						break
					end
					local subject = string.format(
						"%s::legacy-global@%d",
						baseName(fv.path),
						lineOf(fv, s :: number)
					)
					if not waived(RULE_LEGACY_GLOBALS, subject) then
						fail(
							RULE_LEGACY_GLOBALS,
							subject,
							fv.path,
							lineOf(fv, s :: number) + 1,
							"legacy global wait/spawn/delay at a statement boundary — use task.* (CLAUDE.md rule 2). "
								.. "defence-in-depth (duplicates selene)"
						)
					end
					from = (s :: number) + 1
				end
			end
		end
		table.insert(counts, { rule = RULE_LEGACY_GLOBALS, subjects = #views, applicable = true })
	end

	-- ── R8: presentation-floor — WARN ONLY, its own section ───────────────────
	-- Band C stated as reachability rather than as taste: whether it looks GOOD is a human call;
	-- whether the code that could make it look like anything at all EXISTS is not. All of Lighting /
	-- Atmosphere / Sky / BloomEffect returned ZERO hits across collect-sim's whole tree while the only
	-- glowing thing in the game was perceptually invisible under Roblox's default noon.
	--
	-- TWO CAUTIONS, and they are why this is a WARN and not a FAIL:
	--  (i) A PRESENCE CHECK IS SATISFIED BY THE CODE THAT DELETES THE THING. collect-sim's
	--      `Ambience.apply` REMOVES Sky and Atmosphere instances, and the substrings `child:IsA("Sky")`
	--      satisfy the presence assertion perfectly. The two specs are consistent only by accident.
	--  (ii) It proves a token is IN THE TREE. It never proves the token reaches a player's screen.
	-- Making it a factory-wide FAIL would block every build on the rule most likely to degrade into
	-- token-stuffing.
	do
		local floor = {
			{ token = "leaderstats", why = "the player list shows no progress at all" },
			{
				token = "Lighting",
				why = "nothing configures the lighting the whole game is seen through",
			},
			{ token = "Sound", why = "no sound is ever constructed — actions are silent" },
			{ token = "Tween", why = "nothing animates — every state change is an instant jump" },
		}
		for _, f in floor do
			local found = false
			for _, fv in views do
				if string.find(fv.code, f.token, 1, true) ~= nil then
					found = true
					break
				end
			end
			if not found then
				warn(
					RULE_PRESENTATION,
					"tree::" .. f.token,
					"(tree)",
					0,
					string.format("no `%s` anywhere in the tree — %s.", f.token, f.why)
				)
			end
		end
	end

	-- ── monotonic baseline ────────────────────────────────────────────────────
	-- A DROP is the same lie as zero: 16 seams becoming 2 passes every "> 0" check ever written.
	if corpus.baseline == nil then
		warn(
			RULE_PRESENCE,
			"tests/tier0/reachability-baseline.json::baseline",
			"tests/tier0/reachability-baseline.json",
			0,
			"no reachability baseline recorded — a future collapse in subject count would be invisible. Write "
				.. "one with GATE_REACHABILITY_CLI=1 GATE_REACHABILITY_WRITE_BASELINE=1."
		)
	else
		for rule, want in corpus.baseline :: { [string]: number } do
			local got = subjectCount[rule]
			if got ~= nil and got < want then
				local subject = "reachability-baseline::" .. rule
				if not waived(rule, subject) then
					fail(
						rule,
						subject,
						"tests/tier0/reachability-baseline.json",
						0,
						string.format(
							"subject count for %s DROPPED from %d to %d. A gate that suddenly has less to check is "
								.. "not a gate that got greener.",
							rule,
							want,
							got
						)
					)
				end
			end
		end
	end

	-- ── waiver bookkeeping ────────────────────────────────────────────────────
	for _, w in waiverStates do
		if w.valid and not w.matched then
			fail(
				RULE_ALLOWLIST,
				w.entry.subject,
				"tests/verification-allow.json",
				0,
				string.format(
					"waiver for rule %q subject %q MATCHED NOTHING this run — a stale waiver for a fixed problem "
						.. "is how an allowlist rots into blanket suppression. Delete it.",
					w.entry.rule,
					w.entry.subject
				)
			)
		elseif w.valid then
			table.insert(activeWaivers, w.entry)
		end
	end

	local fails = 0
	for _, f in findings do
		if f.level == "FAIL" then
			fails += 1
		end
	end

	table.insert(counts, {
		rule = "view-recursion-depth",
		subjects = VIEW_RECURSION_DEPTH,
		applicable = mature,
	})

	return {
		ok = fails == 0,
		findings = findings,
		counts = counts,
		waivers = activeWaivers,
		mature = mature,
		-- Derived from the SAME condition that gates the subject rules (`if mature then`), never
		-- re-derived from a second notion of maturity — two notions is how two gates come to disagree.
		coverage = if mature then "verified" else "not-applicable",
	}
end

-- ── filesystem side ───────────────────────────────────────────────────────────
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

local function mountsOf(project: any): { string }
	local mounts: { string } = {}
	local function walk(node: any)
		if type(node) ~= "table" then
			return
		end
		local p = node["$path"]
		if type(p) == "string" then
			table.insert(mounts, (string.gsub(p, "\\", "/")))
		end
		for k, v in node do
			if type(k) == "string" and string.sub(k, 1, 1) ~= "$" then
				walk(v)
			end
		end
	end
	if type(project) == "table" then
		walk(project.tree)
	end
	table.sort(mounts)
	return mounts
end

-- Build the corpus from disk. `gameDir` is REPO-ROOT RELATIVE and every path is built from it — there
-- is no cwd probing and no hardcoded fallback candidate (see the header's third trap).
function M.readCorpus(gameDir: string): Corpus
	local mounts: { string } = {}
	local projPath = gameDir .. "/default.project.json"
	if fs.isFile(projPath) then
		local ok, project = pcall(function()
			return serde.decode("json", fs.readFile(projPath))
		end)
		if ok then
			mounts = mountsOf(project)
		end
	end

	local rels: { string } = {}
	listLuau(gameDir, "src", rels)
	table.sort(rels)

	local files: { CorpusFile } = {}
	for _, rel in rels do
		local ok, raw = pcall(fs.readFile, gameDir .. "/" .. rel)
		if ok and type(raw) == "string" then
			table.insert(files, { path = rel, raw = raw :: string, masked = M.mask(raw :: string) })
		end
	end

	local baseline: { [string]: number }? = nil
	local baselinePath = gameDir .. "/tests/tier0/reachability-baseline.json"
	if fs.isFile(baselinePath) then
		local ok, decoded = pcall(function()
			return serde.decode("json", fs.readFile(baselinePath))
		end)
		if ok and type(decoded) == "table" then
			baseline = decoded :: { [string]: number }
		end
	end

	-- THE maturity probe is gate-sample's, reused deliberately: a non-`sample` directory under
	-- src/server/services/. Inventing a second maturity notion is how two gates come to disagree about
	-- whether a game is real.
	local mature = false
	local okDetect, detected = pcall(gateSample.detect, gameDir)
	if okDetect then
		mature = (detected :: any).hasRealFeatures == true
	end

	return {
		gameDir = gameDir,
		mounts = mounts,
		files = files,
		mature = mature,
		baseline = baseline,
	}
end

local function readAllowlist(gameDir: string): (Allowlist, string?)
	local path = gameDir .. "/tests/verification-allow.json"
	if not fs.isFile(path) then
		return { entries = {} }, nil
	end
	local ok, decoded = pcall(function()
		return serde.decode("json", fs.readFile(path))
	end)
	if not ok or type(decoded) ~= "table" then
		-- FAIL CLOSED: an unparseable allowlist is not "no waivers", it is an unknown.
		return { entries = {} }, "tests/verification-allow.json exists but could not be parsed"
	end
	local entries = (decoded :: any).entries
	if type(entries) ~= "table" then
		return { entries = {} }, "tests/verification-allow.json has no `entries` array"
	end
	return { entries = entries :: { AllowEntry } }, nil
end

-- ── public entry: the gauntlet Stage contract ─────────────────────────────────
-- NEVER THROWS. gauntlet.luau:120 has no pcall around the stage call, so a throw kills the JSON line
-- and the whole run reports nothing at all. Every failure path returns a red Stage with a diagnostic.
function M.run(gameDir: string): Stage
	local ok, result = pcall(function(): Stage
		local corpus = M.readCorpus(gameDir)
		local allow, allowErr = readAllowlist(gameDir)
		local decision = M.classify(corpus, allow, os.time())

		local out: { string } = {}
		local function emit(s: string)
			table.insert(out, s)
		end

		local function countOf(rule: string): string
			for _, c in decision.counts do
				if c.rule == rule then
					return if c.applicable then tostring(c.subjects) else "not-applicable"
				end
			end
			return "not-applicable"
		end

		emit(
			string.format(
				"[reachability] %d modules scanned · seams:%s catalog-ids:%s currencies:%s view-fields:%s "
					.. "· view-recursion-depth:1 · mature:%s · coverage:%s · waivers:%d",
				#corpus.files,
				countOf(RULE_SEAM_READ),
				countOf(RULE_CATALOG_ID),
				countOf(RULE_CURRENCY_SINK),
				countOf(RULE_VIEW_FIELD),
				tostring(decision.mature),
				decision.coverage,
				#decision.waivers
			)
		)
		if not decision.mature then
			emit(
				"  maturity carve-out: no non-`sample` directory under src/server/services/, so "
					.. "seam-read / seam-installed / catalog-id-read / currency-sink / view-field-read are "
					.. "not-applicable. not-applicable is NOT a pass — it is 'there is nothing here yet'. "
					.. 'The Stage carries `coverage = "not-applicable"` so a MACHINE sees that too: this '
					.. "stage's `ok = true` means 'nothing failed', not 'the game was checked'."
			)
		end

		local fails, warns = 0, 0
		local presentation: { Finding } = {}
		local main: { Finding } = {}
		for _, f in decision.findings do
			if f.rule == RULE_PRESENTATION then
				table.insert(presentation, f)
			else
				table.insert(main, f)
				if f.level == "FAIL" then
					fails += 1
				else
					warns += 1
				end
			end
		end

		table.sort(main, function(a, b)
			if a.level ~= b.level then
				return a.level == "FAIL"
			end
			if a.file ~= b.file then
				return a.file < b.file
			end
			if a.line ~= b.line then
				return a.line < b.line
			end
			return a.subject < b.subject
		end)
		for _, f in main do
			emit(string.format("%s  [%s] %s  %s:%d", f.level, f.rule, f.subject, f.file, f.line))
			emit("      " .. f.msg)
		end

		if #presentation > 0 then
			emit(
				"-- presentation-floor (WARN-only; a presence check is satisfied by the code that DELETES"
			)
			emit("   the thing, and it never proves a token reaches a player) --")
			for _, f in presentation do
				emit(string.format("WARN  [%s] %s", f.rule, f.msg))
			end
		end

		for _, w in decision.waivers do
			emit(
				string.format(
					"WAIVER active: rule=%s subject=%s expires=%d by=%s — %s",
					w.rule,
					w.subject,
					w.expiresUnix,
					tostring(w.addedBy),
					w.reason
				)
			)
		end

		local stageOk = decision.ok
		if allowErr ~= nil then
			emit(
				"FAIL  [allowlist] " .. allowErr .. " — a check that could not run is a FAILURE."
			)
			fails += 1
			stageOk = false
		end

		emit(
			string.format(
				"reachability: %d FAIL, %d WARN (+%d presentation WARN).",
				fails,
				warns,
				#presentation
			)
		)

		return {
			name = "reachability",
			ok = stageOk,
			output = table.concat(out, "\n"),
			coverage = decision.coverage,
		}
	end)

	if not ok then
		return {
			name = "reachability",
			ok = false,
			-- A gate that threw verified nothing. `ok = false` already fails the run; `coverage` says
			-- WHY there is no evidence, rather than leaving a consumer to infer it from a red boolean.
			coverage = "not-applicable",
			output = "[reachability] the gate itself threw: "
				.. tostring(result)
				.. "\n  A check that could not run is a FAILURE, never a skip.",
		}
	end
	return result :: Stage
end

-- ── standalone CLI (testing only; must NOT fire when required by gauntlet.luau) ──
-- `== "1"`, copying gate-sample.luau:103 and deliberately NOT gate-require.luau:749's `~= nil`, which
-- fires on `GATE_REACHABILITY_CLI=0` and would make this module process.exit the moment the gauntlet
-- merely required it — aborting the run before its JSON line.
if process.env.GATE_REACHABILITY_CLI == "1" then
	local stdio = require("@lune/stdio")
	local dir: string? = nil
	for _, a in process.args do
		if a ~= "--" and a ~= "" then
			dir = a
			break
		end
	end
	local gameDir = dir or "."
	local stage = M.run(gameDir)
	print(stage.output)

	-- M.run NEVER writes. The baseline is written only here, only on an explicit opt-in.
	if process.env.GATE_REACHABILITY_WRITE_BASELINE == "1" then
		local corpus = M.readCorpus(gameDir)
		local decision = M.classify(corpus, { entries = {} }, os.time())
		local baseline: { [string]: number } = {}
		for _, c in decision.counts do
			if c.applicable and c.rule ~= "view-recursion-depth" then
				baseline[c.rule] = c.subjects
			end
		end
		local dir0 = gameDir .. "/tests/tier0"
		if not fs.isDir(dir0) then
			fs.writeDir(dir0)
		end
		fs.writeFile(dir0 .. "/reachability-baseline.json", serde.encode("json", baseline, true))
		stdio.ewrite("[reachability] wrote " .. dir0 .. "/reachability-baseline.json\n")
	end

	process.exit(if stage.ok then 0 else 1)
end

return M
