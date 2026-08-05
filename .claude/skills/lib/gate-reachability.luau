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

-- ── FILE REACHABILITY (added 2026-08-05 — hole A3) ────────────────────────────
-- THE HOLE. The corpus is "every .luau under a Rojo mount", which is a set of FILES, not a set of
-- LIVE code. An adversarial pass added a brand-new `PearlAltarService.luau` that nothing requires,
-- nothing registers in the bootstrap's service list and nothing calls — and R4's shape (4) certified
-- Pearls sunk off it. A DEAD FILE CERTIFIED A LIVE CURRENCY: "written here, read nowhere" hiding
-- inside the gate built to catch it, exactly as the homonym hole did to R1.
--
-- This answers "which files does the running game actually reach". It is a REDUCED PORT of
-- gate-require.luau's resolver (:186-240 resolveStringRequire/exprLeaf, :101-127 buildMounts):
-- the same relative-string resolution with the same init.luau folder-collapse quirk, and the same
-- last-dotted-identifier leaf for an instance require. PORTED rather than required from a private
-- local for the same reason the masker is (see the header at :218): the two gates are separately
-- runnable stages and neither may break the other by refactoring a helper. It answers a WEAKER
-- question than gate-require does (which asks whether a target EXISTS on disk), so it needs no
-- filesystem at all — membership is decided against the corpus's own path set, which is what keeps
-- `M.classify` pure and the RED corpus handwritten.
--
-- ROOTS are what Roblox itself runs, with no require anywhere: `init.server.luau` /
-- `init.client.luau` (Rojo turns the containing folder into a Script/LocalScript) and any
-- `*.server.luau` / `*.client.luau`. Everything else must be REQUIRED, transitively, by something
-- reachable — which is how the bootstrap's `require(Server.services.structures.StructuresShopService)`
-- registration line becomes the edge that makes a service live.
--
-- WHICH WAY IT FAILS. Unreachability is NOT reported as a finding of its own: an unreachable module
-- is not necessarily a defect (a Tier-1 test double, a feature landing next batch), and a rule that
-- red-lit every one of them would be the false alarm that gets a gate switched off. It is used only
-- to REFUSE EVIDENCE — a file this walker cannot prove reachable may not certify a currency. That is
-- the fail-closed direction: the cost is an investigation, never a silent green.
local function segsOf(p: string): { string }
	local out: { string } = {}
	for s in string.gmatch(p, "[^/]+") do
		table.insert(out, s)
	end
	return out
end

local function stripLuau(name: string): string
	return (string.gsub(name, "%.luau$", ""))
end

local function isInitLeaf(noExt: string): boolean
	return noExt == "init" or noExt == "init.server" or noExt == "init.client"
end

-- A file Roblox runs on its own. `init.server`/`init.client` collapse their folder into a
-- Script/LocalScript; a `Foo.server.luau` is a Script wherever it sits.
local function isEntryPoint(path: string): boolean
	local leaf = segsOf(path)
	local name = leaf[#leaf] or ""
	return string.match(name, "%.server%.luau$") ~= nil
		or string.match(name, "%.client%.luau$") ~= nil
end

-- Port of gate-require.luau:190. Inside an `init.luau`, `./` resolves against the init dir's PARENT.
local function resolveRelativeRequire(sourceRel: string, req: string): string?
	local dir = segsOf(sourceRel)
	local fileLeaf = stripLuau(dir[#dir] or "")
	table.remove(dir)
	if isInitLeaf(fileLeaf) then
		table.remove(dir)
	end
	local cur = table.clone(dir)
	for _, part in segsOf(req) do
		if part == "." then
			-- same directory
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
	return table.concat(cur, "/")
end

-- The dotted identifier segments of an instance-require expression: `Server.services.economy.Economy
-- Service` -> {Server, services, economy, EconomyService}. Strings are already blanked on `masked`,
-- so `WaitForChild(…)` contributes nothing.
local function dottedSegments(expr: string): { string }
	local out: { string } = {}
	for id in string.gmatch(expr, "%.([%a_][%w_]*)") do
		table.insert(out, id)
	end
	if #out == 0 then
		local bare = string.match(expr, "([%a_][%w_]*)%s*$")
		if bare ~= nil then
			table.insert(out, bare)
		end
	end
	return out
end

-- Which corpus files does this instance-require name? The LEAF must match the module's basename, and
-- among the files that match, the ones matching the MOST trailing segments win — case-insensitively,
-- because Rojo's DataModel names (`Server`, `Client`) are the capitalised form of the directory
-- (`src/server`). That tie-break is load-bearing: every fork has BOTH `src/server/Context.luau` and
-- `src/client/Context.luau`, and `require(Server.Context)` must reach exactly one of them.
-- A remaining tie marks every tied candidate reachable — an over-approximation, stated here rather
-- than hidden: to exploit it a dead file would have to be named exactly like a live required module
-- AND sit at the same depth under a sibling directory.
local function instanceRequireTargets(paths: { string }, expr: string): { string }
	local segs = dottedSegments(expr)
	if #segs == 0 then
		return {}
	end
	local leaf = segs[#segs]
	local best: { string } = {}
	local bestScore = 0
	for _, p in paths do
		local fseg = segsOf(p)
		fseg[#fseg] = stripLuau(fseg[#fseg])
		if isInitLeaf(fseg[#fseg]) then
			table.remove(fseg)
		end
		if #fseg > 0 and string.lower(fseg[#fseg]) == string.lower(leaf) then
			local score = 0
			local i, j = #fseg, #segs
			while i >= 1 and j >= 1 and string.lower(fseg[i]) == string.lower(segs[j]) do
				score += 1
				i -= 1
				j -= 1
			end
			if score > bestScore then
				best = { p }
				bestScore = score
			elseif score == bestScore then
				table.insert(best, p)
			end
		end
	end
	return best
end

-- Every file this one requires, resolved against the corpus's own path set.
local function requireTargetsOf(
	fv: FileView,
	paths: { string },
	pathSet: { [string]: boolean }
): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(p: string)
		if not seen[p] then
			seen[p] = true
			table.insert(out, p)
		end
	end
	local n = #fv.masked
	local p = 1
	while true do
		local rs, re = string.find(fv.masked, "require", p, true)
		if rs == nil or re == nil then
			break
		end
		p = (re :: number) + 1
		local before = if (rs :: number) > 1
			then string.sub(fv.masked, (rs :: number) - 1, (rs :: number) - 1)
			else " "
		local after = string.sub(fv.masked, (re :: number) + 1, (re :: number) + 1)
		if string.match(before, "[%w_]") ~= nil or string.match(after, "[%w_]") ~= nil then
			continue -- `myrequire` / `requireFoo`, not the builtin
		end
		local q = (re :: number) + 1
		while q <= n and string.match(string.sub(fv.masked, q, q), "%s") ~= nil do
			q += 1
		end
		if string.sub(fv.masked, q, q) ~= "(" then
			continue -- paren-less `require "…"` is not used in this factory; not resolving it can
			-- only LOSE an edge, which fails closed (a file looks unreachable, so it cannot certify).
		end
		local ps, pe = string.find(fv.masked, "%b()", q)
		if ps == nil or pe == nil then
			continue
		end
		p = (pe :: number) + 1
		-- Offsets are preserved by the masker, so the SAME span of `code` carries the literal.
		local innerRaw = string.sub(fv.code, (ps :: number) + 1, (pe :: number) - 1)
		local literal = string.match(innerRaw, '^%s*"(.-)"%s*$')
			or string.match(innerRaw, "^%s*'(.-)'%s*$")
		if literal ~= nil then
			if string.sub(literal, 1, 1) == "." then
				local target = resolveRelativeRequire(fv.path, literal)
				if target ~= nil then
					for _, cand in
						{
							target .. ".luau",
							target .. "/init.luau",
							target .. "/init.server.luau",
							target .. "/init.client.luau",
						}
					do
						if pathSet[cand] then
							add(cand)
						end
					end
				end
			end
			-- `@lune/…` and other non-relative strings reach nothing in this corpus.
		else
			for _, cand in
				instanceRequireTargets(
					paths,
					string.sub(fv.masked, (ps :: number) + 1, (pe :: number) - 1)
				)
			do
				add(cand)
			end
		end
	end
	return out
end

-- The transitive closure from the entry points. Files with no entry point in the corpus reach
-- nothing — which is the honest answer for a fixture tree that contains no bootstrap, and the reason
-- the spec's seam corpus grew one.
local function reachableFiles(views: { FileView }): { [string]: boolean }
	local paths: { string } = {}
	local pathSet: { [string]: boolean } = {}
	local byPath: { [string]: FileView } = {}
	for _, fv in views do
		table.insert(paths, fv.path)
		pathSet[fv.path] = true
		byPath[fv.path] = fv
	end
	local reached: { [string]: boolean } = {}
	local queue: { string } = {}
	for _, fv in views do
		if isEntryPoint(fv.path) then
			reached[fv.path] = true
			table.insert(queue, fv.path)
		end
	end
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		local fv = byPath[cur]
		if fv ~= nil then
			for _, target in requireTargetsOf(fv, paths, pathSet) do
				if not reached[target] then
					reached[target] = true
					table.insert(queue, target)
				end
			end
		end
	end
	return reached
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

		-- ── SHAPE (4): THE SEAM-MEDIATED SPEND (added 2026-08-05) ─────────────
		--
		-- ‼ WHAT SHAPE (4) PROVES, AND WHAT IT DOES NOT. Read this before trusting a green here, and
		-- before "improving" the clauses below.
		--   PROVES:      a REACHABLE file contains a call to a seam method whose own body debits the
		--                persisted balance map, and THIS currency is bound to THAT call.
		--   DOES NOT:    that the debit actually runs, or that the seam genuinely lowers a balance at
		--                RUNTIME. Those are dataflow questions and this is a regex gate.
		--
		-- This boundary was established by two rounds of adversarial attack, not assumed. Round 1 found
		-- 6 laundering routes; all 6 were closed (see A1/A3/A4a/A4b/A8a below). Round 2 then found 8
		-- MORE against the hardened rule, and three of them are worse than the Prisms defect this rule
		-- exists to catch, because the game LOOKS like it has a sink:
		--   N3  the subtraction is at the right depth but its value is overwritten before the write
		--       (`balance = before - amount` then `balance = math.max(before, 0)`) -> every purchase FREE
		--   N4  negation instead of subtraction (`local delta = -amount; balance = before - delta`)
		--       -> `spend` MINTS, and `-` is a token to this rule, never a direction
		--   N6  the debit writes into `table.clone(...)` that is never stored back -> nothing persists
		--   N2  a dead CALL SITE inside a live registered file — A3 gates dead FILES, nothing gates
		--       dead FUNCTIONS
		-- Each round of pattern-hardening closed holes and opened new ones, which is the signature of
		-- the wrong tool: proving "this code genuinely debits persisted state" is dataflow analysis.
		--
		-- SO THE GUARANTEE IS SPLIT, DELIBERATELY, AND THE OTHER HALF IS ALREADY LOAD-BEARING:
		--   this rule       -> "a reachable spend site names this currency"   (static, cheap, here)
		--   the Tier-1 spec -> "the seam genuinely lowers the persisted balance" (behavioural, tests/)
		-- MEASURED, not hoped for: applying N4 to games/deep-reach reds 20 Lune tests while this rule
		-- stays green; applying N6 reds 19. Both name the debit directly
		-- ("spend > debits the balance and leaves lifetimeCredits alone: expected: 700 === 300").
		-- So a game can pass this rule and fail its economy — and it will be caught, one rung over.
		--
		-- THE CONSEQUENCE FOR ANYONE MAINTAINING THIS: do NOT delete an economy spec's balance-delta
		-- assertions on the grounds that "the reachability gate covers the sink". It does not. And do
		-- NOT try to close N3/N4/N6 with more patterns here — that path was tried twice and measured.
		-- If this must become airtight, the right move is a required behavioural assertion (the seam's
		-- own spec proving a debit lowers a persisted balance), enforced as its own rule, not a
		-- cleverer regex.
		--
		-- WHY A FOURTH SHAPE. Shapes (1)-(3) all require THE SPEND SITE ITSELF to write the balance
		-- map. games/deep-reach's engineering contract FORBIDS exactly that: its CLAUDE.md §4 and its
		-- contract pass route EVERY debit through `ctx.economy:spend(data, currency, cost, sink)`, and
		-- EconomyService writes the balance through a LOCAL ALIAS —
		-- `local map = currencies.value; map[currency] = before - amount` — which matches none of the
		-- three shapes. R4 was therefore UNSATISFIABLE BY CORRECTLY-ARCHITECTED CODE in this factory:
		-- StructuresShopService.luau genuinely spends both Credits and Pearls (proven end-to-end — a
		-- Credits buy moved 100000 -> 99950, a Pearls buy moved 50 -> 49, 7 currency_spent events) and
		-- R4 still reported both currencies un-sunk. Two independent feature agents hit this and BOTH
		-- refused to hand-roll a direct `data.currencies[k] = balance - cost` write purely to satisfy
		-- the regex, because that write IS the §4 violation this rule exists to protect. They were
		-- right; the rule was wrong. A gate satisfiable only by breaking the architecture teaches
		-- authors to break the architecture — the header's "a false alarm gets a gate switched off",
		-- one level up.
		--
		-- THE BINDING THIS SHAPE KEEPS. R4 was REBUILT after a falsification run restored the Prisms
		-- defect verbatim and the first version reported 0 FAIL: "does this file name the currency" and
		-- "does this file spend" were evaluated INDEPENDENTLY, so a shop that spent Stardust certified
		-- Prisms from a read-only balance echo 200 lines away. Shape (4) binds three things at once, and
		-- every one of them is load-bearing:
		--   (a) THE CALL. A reference-shaped `[.:]<method>(…)` on MASKED source — never a substring of
		--       raw source (header, vacuity trap) — whose RECEIVER is attributable to the seam that
		--       DEFINES that method: the seam's ident, a name assigned directly from it anywhere in the
		--       tree (`local economy = EconomyService.new(analytics)`, then `economy = economy` in the
		--       context literal — which is how this factory installs it), or a one-hop local alias of
		--       either in the calling file (`local economy = ctx.economy`). An UNRESOLVED receiver does
		--       NOT certify. R1 lets an unresolvable receiver SUPPRESS a failure because there the risk
		--       is a false alarm; here an unresolvable receiver would MANUFACTURE a sink, so this half
		--       fails CLOSED. The two directions are deliberately opposite.
		--   (b) THE CURRENCY, BOUND TO THAT CALL — not merely present in the file, and not merely
		--       present in the call. The key must arrive in THE CURRENCY ARGUMENT POSITION, which is
		--       read off the seam method's own signature (holes A4a/A4b below). Either that argument
		--       IS the string literal `"<Key>"`, or — when it is dynamic
		--       (`economy:spend(data, entry.currency, cost, …)`) — the expression must resolve to a
		--       TABLE LITERAL in the calling file that declares `<field> = "<Key>"`. A call that names
		--       its currency literally binds ONLY that currency, so a file that literally spends
		--       Credits can never certify a Pearls declaration sitting elsewhere in it. Deleting the
		--       last Pearls-denominated catalog row — which IS the Prisms defect, and is the
		--       falsification recorded for this shape — removes the sink.
		--   (c) THE ANTI-LAUNDERING CLAUSE (`isDebitBody`): THE SEAM MUST ITSELF SUBTRACT FROM A
		--       BALANCE. Without it, "define a function named `spend` that adds" would certify every
		--       currency in the game. So the method name carries NO authority here — the set of
		--       spendable seam methods is discovered BY IMPLEMENTATION. A `(ident, method)` pair counts
		--       only when, INSIDE ITS OWN BODY, a table that is the persisted balance map (`currencies`,
		--       or a local aliased from it in that body) is written with a value that traces to a
		--       SUBTRACTION: `-=`, a same-statement `-`, or one hop back to a local assigned in that
		--       body from a subtraction. `spend` earns its place by debiting; `earn` (`local balance =
		--       before + amount`) never enters the set. The scan is scoped to THE FUNCTION BODY on
		--       purpose: a whole-module scan would let a service's `earn` launder its `spend`, which is
		--       the same "a whole-file scan cannot tell a charge from a label" hole that forced the
		--       subtraction-to-write binding above.
		--
		-- Body bounds are taken CONSERVATIVELY — from the definition to the next column-0 `function`,
		-- `local` or `return` — never by scanning for a closing `end`. R5's header records what the
		-- `.-\nend` parse cost: any nested block silently TRUNCATES the body, and a truncated body here
		-- would drop the debit and report a live sink as dangling. Over-inclusion can only reach blanked
		-- comments and blank lines between two top-level statements; truncation loses real code.
		--
		-- ── SECOND HARDENING PASS (2026-08-05): FIVE HOLES AN ADVERSARY WALKED THROUGH ────────
		-- An INDEPENDENT adversary ran twelve laundering attacks at the shape above and got SIX past
		-- it. Five are closed, each at the clause that let it through, each with its attack rerun
		-- against the REAL games/deep-reach tree and a fixture added to gate_reachability_spec.luau:
		--   A1  a scratch table called `currencies` in a read-only PREVIEW enrolled as a debit body
		--       -> a token must trace to the function's own blob PARAMETER  (see `seedsBalanceMap`)
		--   A4a the key bound from ANY argument, so a SINK LABEL certified a currency nobody spends
		--       -> the currency argument POSITION comes from the seam's signature  (see `currencyArg`)
		--   A4b a whole-file `currency = "<Key>"` regex, satisfied by a UI legend or a config stub
		--       -> the declaration must live in the table the dynamic expression indexes
		--         (see `dynamicArgBinds`)
		--   A8a the seam's subtraction moved into a branch that never runs, and still certified
		--       -> the subtraction must sit at the write's own block depth  (see `depthProfile`)
		--   A3  a brand-new service NOTHING requires certified a currency off a spend that never runs
		--       -> the certifying file must be REACHABLE from an entry point  (see `reachableFiles`)
		--
		-- A3's fix is applied to ALL FOUR SHAPES, not just this one: a dead file that hand-writes
		-- `currencies.Pearls -= cost` is the same lie as a dead file that calls a seam, and gating only
		-- the shape the adversary happened to attack would leave the identical hole one shape over.
		-- Measured on every tree in this repo before it was kept: collect-sim (direct-write shape),
		-- deep-reach (seam shape) and core (below maturity) are byte-identical with it in place.
		--
		-- WHAT IS STILL OPEN, stated rather than discovered later. Both fail toward CERTIFYING, which
		-- is the direction that costs a green, so they are named here on purpose:
		--   * SHADOWING. Tokens are matched by NAME, not by scope. A function that legitimately aliases
		--     the balance map and then SHADOWS that name with a scratch table (`local currencies =
		--     currenciesOf(data)` … later `local currencies = {}`) still certifies. Closing it needs
		--     scope tracking — a real parse, not a text walk. The A1 fix covers the shape the adversary
		--     used (a preview with no legitimate alias at all); this narrower one survives.
		--   * BACKTICK STRINGS. `M.mask` blanks `"` and `'` literals only; Luau's interpolated
		--     `` `structure.{key}` `` is left intact, so a COMMA inside one would shift the argument
		--     split and bind the wrong position. In practice that lands on a non-literal argument and
		--     fails closed, but it is not proven to, and the masker is shared with the other seven
		--     rules — widening it belongs in its own change, with its own falsification.
		local BODY_STOPS = { "\nfunction%f[^%w_]", "\nlocal%f[^%w_]", "\nreturn%f[^%w_]" }

		-- Which files the running game actually reaches (see the REACHABILITY block at the top of this
		-- file). Computed ONCE, and read only as a REFUSAL: a file that cannot be shown to run is not
		-- evidence that anything is spent.
		local reachable = reachableFiles(views)

		local function trimText(s: string): string
			return (string.match(s, "^%s*(.-)%s*$")) :: string
		end

		-- Strip wrapping parens and `:: any` casts, so `(currencies :: any)` and `currencies` are the
		-- same expression to every binder below.
		local function bareExpr(text: string): string
			local t = trimText(text)
			for _ = 1, 4 do
				local stripped = string.match(t, "^(.-)%s*::%s*[%w_%.%s<>{}%[%]|%?]+$")
				if stripped ~= nil and stripped ~= "" then
					t = trimText(stripped)
				end
				local inner = string.match(t, "^%b()$")
				if inner ~= nil then
					t = trimText(string.sub(t, 2, #t - 1))
				else
					break
				end
			end
			return t
		end

		-- Split a parenthesised span's INTERIOR on depth-0 commas, returning offsets. Runs on MASKED
		-- text, where string CONTENT is blanked, so a comma inside a string literal cannot split an
		-- argument — and because the masker preserves offsets, the same offsets read the literals back
		-- out of `code`.
		local function splitTopLevel(masked: string, a: number, b: number): { Span }
			local out: { Span } = {}
			if b < a then
				return out
			end
			local depth = 0
			local start = a
			for i = a, b do
				local c = string.sub(masked, i, i)
				if c == "(" or c == "{" or c == "[" then
					depth += 1
				elseif c == ")" or c == "}" or c == "]" then
					depth -= 1
				elseif c == "," and depth == 0 then
					table.insert(out, { a = start, b = i - 1 })
					start = i + 1
				end
			end
			table.insert(out, { a = start, b = b })
			return out
		end

		-- HOLE A1 (2026-08-05): A SCRATCH TABLE IS NOT THE BALANCE MAP.
		-- This seeded its token list with the BARE NAME `currencies`, unconditionally — so a READ-ONLY
		-- affordability preview containing `local currencies = {}` … `currencies[k] = before - cost`
		-- enrolled as a debit body and certified a currency that nothing in the game spends. The name
		-- of a local proves nothing; an attacker picks it.
		--
		-- A token now has to TRACE TO THE FUNCTION'S OWN BLOB PARAMETER. A seed is a local whose
		-- right-hand side is either `<param>.currencies` (the direct form) or a call to a helper whose
		-- NAME names the map and whose arguments name the blob (`currenciesOf(data)` — the shape the
		-- real EconomyService uses, because it normalises a missing map into a Result first). Each
		-- parameter also contributes the pseudo-token `<param>.currencies`, so a seam that writes the
		-- blob's map without aliasing it still counts. Alias hops off those seeds are unchanged: the
		-- seam is REQUIRED to write through one (`local map = (currencies :: any).value`).
		-- `local currencies = {}` names no parameter, so it seeds nothing — and a preview that assigns
		-- into a table it just created certifies nothing.
		local function seedsBalanceMap(rhs: string, params: { string }): boolean
			local t = bareExpr(rhs)
			for _, p in params do
				if
					t == p .. ".currencies"
					or t == p .. '["currencies"]'
					or t == p .. "['currencies']"
				then
					return true
				end
				local name, args = string.match(t, "^([%w_%.:]+)%s*(%b())$")
				if
					name ~= nil
					and args ~= nil
					and string.find(string.lower(name), "currencies", 1, true) ~= nil
					and namesToken(args, p)
				then
					return true
				end
			end
			return false
		end

		-- Names that denote the persisted balance map inside ONE function body, each traced to a
		-- parameter of THAT function (see HOLE A1 above), then extended by alias hops.
		local function balanceMapTokens(body: string, params: { string }): { string }
			local tokens: { string } = {}
			for _, p in params do
				table.insert(tokens, p .. ".currencies")
			end
			type LocalDecl = { ident: string, rhs: string }
			local decls: { LocalDecl } = {}
			for ident, rhs in string.gmatch(body, "local%s+([%w_]+)%s*=([^=%c][^%c]*)") do
				table.insert(decls, { ident = ident, rhs = rhs })
				if seedsBalanceMap(rhs, params) then
					table.insert(tokens, ident)
				end
			end
			for _ = 1, 3 do
				local grew = false
				for _, d in decls do
					local known = false
					for _, t in tokens do
						if t == d.ident then
							known = true
							break
						end
					end
					if not known then
						for _, t in tokens do
							if namesToken(d.rhs, t) then
								table.insert(tokens, d.ident)
								grew = true
								break
							end
						end
					end
				end
				if not grew then
					break
				end
			end
			return tokens
		end

		-- HOLE A8a (2026-08-05): THE SEAM'S SUBTRACTION CAN BE DEAD.
		-- The one-hop-back search below scanned the body TEXTUALLY, so rewriting EconomyService.spend's
		-- debit to `local balance = before` plus `if amount < 0 then balance = before - amount end`
		-- still certified both currencies: the write stores `balance`, and the hop cheerfully found the
		-- assignment inside the dead branch. That reopens ONE LEVEL UP the exact hole the whole
		-- "bind the subtraction to the write" paragraph above was written to close — a whole-file scan
		-- cannot tell a charge from a label, and a whole-BODY scan cannot tell a charge from a branch
		-- that never runs.
		--
		-- A full reachability analysis of a Luau function is out of scope for a static text gate, so
		-- the rule is CONSERVATIVE instead: the subtraction that feeds the stored value must sit at the
		-- SAME BLOCK DEPTH as the write, BEFORE it, with the depth never dipping below that in between
		-- (which is what "and in the same block" means when all you have is a depth profile). A
		-- subtraction found only inside a nested block does NOT establish a debit. That fails closed —
		-- a conditional debit reads as no debit, which costs an investigation, never a silent green —
		-- and it keeps the real EconomyService certified, whose `local balance = before - amount` and
		-- `map[currency] = balance` are consecutive statements at the same level.
		--
		-- DEPTH is counted on statement keywords. `if` opens a block ONLY when it is not preceded by
		-- `=`, `(`, `,`, `{`, `return`, `and`, `or` or `not` — that is Luau's `if … then … else`
		-- EXPRESSION (`local existing = if type(data.stats) == "table" then … else nil`, three lines
		-- from the real spend), which has no `end` and would otherwise open a block that never closes.
		local BLOCK_OPEN_WORDS = { ["function"] = true, ["repeat"] = true }
		local EXPR_IF_PREV_WORDS =
			{ ["return"] = true, ["and"] = true, ["or"] = true, ["not"] = true, ["elseif"] = true }

		local function ifOpensBlock(body: string, at: number): boolean
			local i = at - 1
			while i >= 1 and string.match(string.sub(body, i, i), "%s") ~= nil do
				i -= 1
			end
			if i < 1 then
				return true
			end
			local c = string.sub(body, i, i)
			if c == "=" or c == "(" or c == "," or c == "{" or c == "[" then
				return false
			end
			local word = string.match(string.sub(body, math.max(1, i - 9), i), "([%a_][%w_]*)$")
			if word ~= nil and EXPR_IF_PREV_WORDS[word] then
				return false
			end
			return true
		end

		-- Block depth at every character offset of `body`.
		local function depthProfile(body: string): { number }
			local prof: { number } = {}
			local depth = 0
			local expectDo = false
			local cursor = 1
			local p = 1
			local function fill(upto: number, d: number)
				local stop = math.min(upto, #body)
				for i = cursor, stop do
					prof[i] = d
				end
				if stop + 1 > cursor then
					cursor = stop + 1
				end
			end
			while true do
				local ws, we, word = string.find(body, "([%a_][%w_]*)", p)
				if ws == nil or we == nil then
					break
				end
				p = (we :: number) + 1
				if word == "end" or word == "until" then
					depth = math.max(0, depth - 1)
					fill(we :: number, depth)
				else
					fill(we :: number, depth)
					if BLOCK_OPEN_WORDS[word :: string] then
						depth += 1
					elseif word == "for" or word == "while" then
						depth += 1
						expectDo = true
					elseif word == "do" then
						if expectDo then
							expectDo = false
						else
							depth += 1
						end
					elseif word == "if" and ifOpensBlock(body, ws :: number) then
						depth += 1
					end
				end
			end
			fill(#body, depth)
			return prof
		end

		local function depthAt(prof: { number }, pos: number): number
			return prof[pos] or 0
		end

		-- One hop back, WITHIN THIS BODY and WITHIN THIS BLOCK. Same follow-the-stored-value logic as
		-- identFromSubtraction, but never leaving the function — that scoping is the anti-laundering
		-- clause's teeth — and never entering a nested block (HOLE A8a).
		local function bodyIdentFromSubtraction(
			body: string,
			prof: { number },
			ident: string,
			writeAt: number,
			writeDepth: number
		): boolean
			local pat = "%f[%w_]" .. esc(ident) .. "%s*=[^=%c][^%c]*"
			local from = 1
			while true do
				local s, e = string.find(body, pat, from)
				if s == nil or e == nil then
					return false
				end
				from = (e :: number) + 1
				if
					string.find(string.sub(body, s :: number, e :: number), "%-") ~= nil
					and (s :: number) < writeAt
					and depthAt(prof, s :: number) == writeDepth
				then
					local sameBlock = true
					for i = e :: number, writeAt do
						if depthAt(prof, i) < writeDepth then
							sameBlock = false
							break
						end
					end
					if sameBlock then
						return true
					end
				end
			end
		end

		-- (c) Does THIS body actually lower a balance?
		local function isDebitBody(body: string, params: { string }): boolean
			local prof = depthProfile(body)
			for _, token in balanceMapTokens(body, params) do
				local t = esc(token)
				for _, target in { t .. "%b[]", t .. "%.[%w_]+" } do
					if string.find(body, target .. "[ \t]*%-=") ~= nil then
						return true
					end
					local from = 1
					while true do
						local s, e = string.find(body, target .. "[ \t]*=", from)
						if s == nil or e == nil then
							break
						end
						-- `==` is a comparison, not a write.
						if string.sub(body, (e :: number) + 1, (e :: number) + 1) ~= "=" then
							local lineEnd = string.find(body, string.char(10), e :: number, true)
								or (#body + 1)
							local rhs = string.sub(body, (e :: number) + 1, lineEnd - 1)
							if string.find(rhs, "%-") ~= nil then
								-- The subtraction IS the write: one statement, one block, no branch.
								return true
							end
							local ident = string.match(rhs, "^%s*([%w_]+)%s*$")
							if
								ident ~= nil
								and bodyIdentFromSubtraction(
									body,
									prof,
									ident,
									s :: number,
									depthAt(prof, s :: number)
								)
							then
								return true
							end
						end
						from = (e :: number) + 1
					end
				end
			end
			return false
		end

		-- Every `(ident, method)` in the tree whose body debits, plus the tokens a call site may name it
		-- by. Computed ONCE, not per currency.
		-- HOLE A4a (2026-08-05): THE CURRENCY MUST BIND FROM THE CURRENCY ARGUMENT POSITION.
		-- `seamSpend` used to take the whole parenthesised span and ask only whether the quoted key
		-- appeared ANYWHERE in it, so `economy:spend(data, "Credits", cost, "structure.pearls.discount")`
		-- certified PEARLS off a SINK LABEL. That is the Prisms defect in seam clothing — spend A, name
		-- B — and it is the one this shape was built to make impossible.
		--
		-- The position is read off the SEAM METHOD'S OWN SIGNATURE: the parameter whose name names a
		-- currency. Never a hardcoded index — `spend(data, currency, amount, sink)` is this factory's
		-- shape, not a law, and an index frozen here would silently bind the wrong argument the first
		-- time a game orders its parameters differently. EXACTLY ONE such parameter must be found: zero
		-- (no currency parameter at all) or two (ambiguous) means the position CANNOT BE DETERMINED,
		-- and this seam then certifies nothing, ever. A `:` call site drops one for the implicit
		-- `self`; a `.` call site does not.
		type DebitSeam = {
			ident: string,
			method: string,
			path: string,
			tokens: { string },
			currencyArg: number?,
		}
		local debitSeams: { DebitSeam } = {}
		for _, fv in views do
			local from = 1
			while true do
				local s, e, ident, method =
					string.find(fv.code, "function%s+([%w_]+)[%.:]([%w_]+)%s*%(", from)
				if s == nil or e == nil then
					break
				end
				from = (e :: number) + 1
				-- `e` is the `(` of the parameter list; the body starts after its match.
				local ps, pe = string.find(fv.masked, "%b()", e :: number)
				if ps == e and pe ~= nil then
					local params: { string } = {}
					local currencyArg: number? = nil
					local ambiguous = false
					local frags = splitTopLevel(fv.masked, (ps :: number) + 1, (pe :: number) - 1)
					for i, frag in frags do
						local name =
							string.match(string.sub(fv.masked, frag.a, frag.b), "^%s*([%w_]+)")
						table.insert(params, name or "")
						if
							name ~= nil
							and string.find(string.lower(name), "currency", 1, true) ~= nil
						then
							if currencyArg ~= nil then
								ambiguous = true
							end
							currencyArg = i
						end
					end
					local stop = #fv.code
					for _, pat in BODY_STOPS do
						local bs = string.find(fv.code, pat, (pe :: number) + 1)
						if bs ~= nil and bs < stop then
							stop = bs
						end
					end
					if isDebitBody(string.sub(fv.code, (pe :: number) + 1, stop), params) then
						table.insert(debitSeams, {
							ident = ident :: string,
							method = method :: string,
							path = fv.path,
							tokens = {},
							currencyArg = if ambiguous then nil else currencyArg,
						})
					end
				end
			end
		end
		-- Attribution tokens. Only a DIRECT reference counts as an install (`= EconomyService`,
		-- `= EconomyService.new(…)`, `= require(….EconomyService)`) — `setmetatable({}, EconomyService)`
		-- must NOT make `self` a token for every service in the game. Dunder/underscore names are
		-- skipped for the same reason (`EconomyService.__index = EconomyService`).
		for _, seam in debitSeams do
			local tokens: { string } = { seam.ident }
			for _ = 1, 2 do
				for _, fv in views do
					for name, rhs in string.gmatch(fv.masked, "([%w_]+)%s*=([^=%c][^%c]*)") do
						if string.sub(name, 1, 1) ~= "_" then
							local trimmed = string.match(rhs, "^%s*(.-)%s*$") or ""
							local known = false
							for _, t in tokens do
								if t == name then
									known = true
									break
								end
							end
							if not known then
								for _, t in tokens do
									local direct = string.find(trimmed, "^" .. esc(t) .. "%f[^%w_]")
										~= nil
									local required = string.sub(trimmed, 1, 8) == "require("
										and namesToken(trimmed, t)
									if direct or required then
										table.insert(tokens, name)
										break
									end
								end
							end
						end
					end
				end
			end
			seam.tokens = tokens
		end

		-- Definition separators for ANY owner of `method`, so a `function X.spend(` header is never
		-- mistaken for a call site. Same exact-offset trick as definitionSeparators.
		local function anyDefinitionSeparators(fv: FileView, method: string): { [number]: boolean }
			local out: { [number]: boolean } = {}
			local e = esc(method)
			for _, sep in { "%.", ":" } do
				local from = 1
				while true do
					local ds, de = string.find(
						fv.masked,
						"function%s+[%w_]+%s*" .. sep .. e .. "%f[^%w_]",
						from
					)
					if ds == nil or de == nil then
						break
					end
					out[(de :: number) - #method] = true
					from = (de :: number) + 1
				end
			end
			return out
		end

		-- An argument that is EXACTLY one string literal, else nil (it is dynamic).
		local function literalArg(text: string): string?
			local t = trimText(text)
			return string.match(t, '^"([^"]*)"$') or string.match(t, "^'([^']*)'$")
		end

		-- Every table literal assigned to `ident` in this file, as offset spans of `code`. The
		-- occurrence has to be a DECLARATION or a plain assignment, and the test is deliberately
		-- narrow on BOTH sides: `local` (or the start of a line) immediately before the name, and
		-- between the name and its `=` nothing but whitespace or a SINGLE-LINE type annotation. It is
		-- the same "find the assignment `=` first, then the literal" parse R3 uses for
		-- `local CATALOG: { [string]: CatalogEntry } = { … }`.
		--
		-- THE NARROWING IS NOT COSMETIC — it was falsified. A first version accepted any `: …` between
		-- the name and the next `=`, which let a PARAMETER ANNOTATION (`nextCostOf(entry: CatalogEntry,
		-- …)`) reach forward past the end of its own statement and adopt some later `local X = { … }`
		-- as `entry`'s table. Rerunning hole A4b against the real games/deep-reach tree caught it: a UI
		-- legend appended at the bottom of StructuresShopService.luau certified Pearls again, through
		-- the very clause written to stop it. A fixture corpus small enough to read by eye would never
		-- have shown it.
		local function tableLiteralSpans(fv: FileView, ident: string): { Span }
			local out: { Span } = {}
			local from = 1
			local pat = "%f[%w_]" .. esc(ident) .. "%f[^%w_]"
			while true do
				local s, e = string.find(fv.code, pat, from)
				if s == nil or e == nil then
					break
				end
				from = (e :: number) + 1
				local before =
					string.sub(fv.code, math.max(1, (s :: number) - 10), (s :: number) - 1)
				local declared = string.match(before, "%f[%w_]local[ \t]+$") ~= nil
					or string.match(before, "[\r\n][ \t]*$") ~= nil
				local eqAt = string.find(fv.code, "=", (e :: number) + 1, true)
				if declared and eqAt ~= nil then
					local between = string.sub(fv.code, (e :: number) + 1, (eqAt :: number) - 1)
					if
						string.match(between, "^[ \t]*$") ~= nil
						or string.match(between, "^[ \t]*:[^=\r\n]*$") ~= nil
					then
						local braceAt = string.find(fv.code, "{", (eqAt :: number) + 1, true)
						if
							braceAt ~= nil
							and string.match(
									string.sub(
										fv.code,
										(eqAt :: number) + 1,
										(braceAt :: number) - 1
									),
									"^%s*$"
								)
								~= nil
						then
							local a, b = string.find(fv.code, "%b{}", braceAt :: number)
							if a ~= nil and b ~= nil then
								table.insert(out, { a = a :: number, b = b :: number })
							end
						end
					end
				end
			end
			return out
		end

		-- `entry` <- `CATALOG[key]` <- the CATALOG literal: the idents a value could have come out of,
		-- up to three hops. Only the HEAD identifier of each right-hand side is followed, so this walks
		-- table origins and nothing else.
		local function originIdents(fv: FileView, ident: string): { string }
			local out: { string } = { ident }
			local seen: { [string]: boolean } = { [ident] = true }
			for _ = 1, 3 do
				local grew = false
				for _, name in table.clone(out) do
					local rhs =
						string.match(fv.code, "local%s+" .. esc(name) .. "%f[^%w_][^=%c]*=([^%c]*)")
					if rhs ~= nil then
						local head = string.match(bareExpr(rhs), "^([%w_]+)")
						if head ~= nil and not seen[head] then
							seen[head] = true
							table.insert(out, head)
							grew = true
						end
					end
				end
				if not grew then
					break
				end
			end
			return out
		end

		-- HOLE A4b (2026-08-05): AN INERT DECLARATION MUST NOT CERTIFY.
		-- When the call passes a DYNAMIC currency, shape (4)(b) used to fall back to `declaresCurrency`
		-- — a WHOLE-FILE regex for `currency = "<Key>"`. A UI legend, a localisation table, a config
		-- stub or a commented-out catalog row satisfied it, so a currency could be certified sunk by a
		-- string that no purchase path ever reads. The declaration is now bound to THE DATA THAT
		-- ACTUALLY REACHES THE CALL: the dynamic argument must be `<base>.<field>` (or
		-- `<base>["<field>"]`), `<base>` must resolve to a TABLE LITERAL in this file, and THAT literal
		-- must contain `<field> = "<Key>"`. `economy:spend(data, entry.currency, …)` with
		-- `local entry = CATALOG[key]` therefore binds exactly the currencies the catalog is
		-- denominated in — deleting the last Pearls row removes the sink, which is the Prisms defect
		-- and the falsification recorded for this shape. An argument this walker cannot resolve to a
		-- table binds NOTHING: fail closed.
		local function dynamicArgBinds(fv: FileView, argText: string, key: string): boolean
			local expr = bareExpr(argText)
			for _ = 1, 3 do
				local base, field = string.match(expr, "^([%w_]+)%s*%.%s*([%w_]+)$")
				if base == nil then
					base, field = string.match(expr, '^([%w_]+)%s*%[%s*"([%w_]+)"%s*%]$')
				end
				if base ~= nil and field ~= nil then
					local f = esc(field :: string)
					local k = esc(key)
					for _, owner in originIdents(fv, base :: string) do
						for _, span in tableLiteralSpans(fv, owner) do
							local body = string.sub(fv.code, span.a, span.b)
							if
								string.find(body, f .. '%s*=%s*"' .. k .. '"') ~= nil
								or string.find(body, '%["' .. f .. '"%]%s*=%s*"' .. k .. '"')
									~= nil
							then
								return true
							end
						end
					end
					return false
				end
				-- a bare local (`local currency = entry.currency`): one hop and try again.
				local bare = string.match(expr, "^([%w_]+)$")
				if bare == nil then
					return false
				end
				local rhs =
					string.match(fv.code, "local%s+" .. esc(bare) .. "%f[^%w_][^=%c]*=([^%c]*)")
				if rhs == nil then
					return false
				end
				expr = bareExpr(rhs)
			end
			return false
		end

		local function seamSpend(fv: FileView, key: string): boolean
			-- HOLE A3: a file the running game never reaches may not certify anything. Both halves of
			-- the evidence have to be live — the CALL SITE and the SEAM that debits.
			if not reachable[fv.path] then
				return false
			end
			for _, seam in debitSeams do
				-- `currencyArg == nil` is "the currency position could not be determined" (HOLE A4a);
				-- such a seam certifies nothing rather than guessing.
				if seam.currencyArg ~= nil and reachable[seam.path] then
					local tokens = withAliases(fv, seam.tokens)
					local defSeps = anyDefinitionSeparators(fv, seam.method)
					local pat = "[%.:]" .. esc(seam.method) .. "%s*(%b())"
					local from = 1
					while true do
						local s, e, span = string.find(fv.masked, pat, from)
						if s == nil or e == nil or span == nil then
							break
						end
						from = (e :: number) + 1
						if not defSeps[s :: number] then
							local recv = receiverTextBefore(fv.masked, s :: number)
							local attributed = false
							for _, t in tokens do
								if namesToken(recv, t) then
									attributed = true
									break
								end
							end
							if attributed then
								local isColon = string.sub(fv.masked, s :: number, s :: number)
									== ":"
								local argIndex = (seam.currencyArg :: number)
									- (if isColon then 1 else 0)
								local innerA = (e :: number) - #(span :: string) + 2
								local innerB = (e :: number) - 1
								local args = splitTopLevel(fv.masked, innerA, innerB)
								local arg = if argIndex >= 1 then args[argIndex] else nil
								if arg ~= nil then
									-- Offsets are preserved by the masker, so the SAME span of `code`
									-- carries this argument's string literal.
									local text = string.sub(fv.code, arg.a, arg.b)
									local literal = literalArg(text)
									if literal ~= nil then
										-- A literal binds ONLY itself. A file that literally spends
										-- Credits can never certify Pearls off a label elsewhere in the
										-- same call — that was hole A4a.
										if literal == key then
											return true
										end
									elseif dynamicArgBinds(fv, text, key) then
										return true
									end
								end
							end
						end
					end
				end
			end
			return false
		end

		for _, key in currencies do
			local subject = string.format("Migrations.luau::currencies.%s", key)
			local granted, sunk = false, false
			for _, fv in views do
				local isContract = string.find(fv.path, "shared/Migrations.luau", 1, true) ~= nil
					or string.find(fv.path, "shared/Types.luau", 1, true) ~= nil
				if not isContract and namesCurrency(fv, key) then
					granted = true
					-- REACHABILITY GATES EVERY SHAPE (hole A3). `granted` deliberately does NOT check
					-- it: a currency named only by dead files is still seeded into the save file, and
					-- "granted but no sink" is the more useful diagnosis than silence.
					if
						reachable[fv.path]
						and (literalSpend(fv, key) or dynamicSpend(fv, key) or seamSpend(fv, key))
					then
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
						"currency %q is GRANTED but has NO SINK — no REACHABLE file that names it also decrements "
							.. "a balance against a cost/price. The player accumulates a number that buys nothing (the "
							.. "Prisms defect: granted, persisted, displayed, decremented by nothing). A sink is a "
							.. "`currencies.%s -=` / `currencies.%s = …-…` write, a dynamic "
							.. "`currencies[expr] = …` write in a file declaring `currency = %q`, or a call to a "
							.. "seam whose own body debits the balance map (`ctx.economy:spend(data, …)`) with "
							.. "%q bound to THE CURRENCY ARGUMENT of that call — as a string literal there, or, when "
							.. "that argument is dynamic (`entry.currency`), by the `currency = %q` declaration "
							.. "inside the very table it indexes. FOUR THINGS EACH FAIL CLOSED HERE, so check them "
							.. "before assuming the gate is wrong: the file must be reached from an entry point "
							.. "(`init.server.luau` / `*.server.luau` and the require graph from it); the seam's own "
							.. "body must lower a balance map traced to ITS OWN blob parameter; that subtraction must "
							.. "sit at the same block depth as the write it feeds (a debit inside an `if` reads as no "
							.. "debit); and the currency must arrive in the argument position the seam's signature "
							.. "names — a sink label carrying the key binds nothing.",
						key,
						key,
						key,
						key,
						key,
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
