--!strict
-- gate_reachability_spec.luau — the RED corpus for the T1 static reachability gate.
--
-- FALSIFY FIRST (factory doctrine 3): a gate that has never been observed RED is not known to work.
-- collect-sim shipped 313 green tests beside four upgrades that did nothing, so "the suite is green"
-- proves nothing about the suite. Every one of gate-reachability's eight rules therefore has a
-- RECORDED RED here, produced by a SINGLE MUTATION of one green baseline corpus — so each fixture
-- isolates exactly the thing its rule claims to see, and a rule that stops working turns a fixture
-- green instead of failing quietly.
--
-- `M.classify` is pure (no filesystem, no os.time), which is what makes this affordable: the corpora
-- are handwritten Luau strings, not a fixture tree on disk. `M.readCorpus` (the only filesystem path)
-- is exercised once, against the real `core/` tree, at the bottom.
--
-- THE FIXTURES, and what each proves:
--   green-baseline                     the corpus is GREEN, so every RED below is caused by its mutation
--   dangling-seam                      R1 — a seam method referenced by no other file
--   comment-only-reference             R1 + THE MASKER — the same seam "referenced" only in prose.
--                                      RED with masking; the paired `code-reference-is-green` fixture
--                                      shows the identical corpus goes GREEN when it is real code, so
--                                      the masker is doing the work and not an accident of spelling.
--   seam-applied-in-own-module         R1 — a seam APPLIED where it is defined is read. Paired with
--   seam-called-nowhere-at-all         R1 — ...the same corpus with the application removed, so the
--                                      relaxation is proven not to be the rule going blind
--   homonym-masks-orphaned-seam        R1 — THE HOMONYM HOLE: two seams publish `multiplierFor`, one is
--                                      live, the other is called by nothing. The live one used to
--                                      certify the dead one. Paired with TWO positive controls, so the
--                                      fix is not "R1 started refusing homonyms":
--   homonym-both-wired-is-green        R1 — ...the same two seams, both actually called: GREEN
--   homonym-reached-by-dynamic-dispatch-is-green
--                                      R1 — ...the orphan reached ONLY by a quoted-literal dynamic
--                                      dispatch (`tuningFrom(ctx, d, "multiplierFor")`), the real idiom
--                                      in this factory: GREEN. A rule that red-lit this would be a
--                                      false alarm, and a false alarm gets a gate switched off
--   coverage-is-machine-readable       the `not-applicable` third state reaches the FIELD a machine
--                                      reads (Decision.coverage / Stage.coverage), not just the prose
--   uninstalled-seam                   R2 — a seam table never installed on `context`
--   catalog-id-read-nowhere            R3 — the 9,625-Stardust defect: an id in the catalog and the
--                                      order list and NOWHERE ELSE
--   catalog-id-read-only-in-comparison R3 — the SAME defect in its exact historical form: the curve
--                                      still compiles and still returns a number, it just stopped
--                                      reading the level. An `==` dispatch branch is not a read
--   currency-with-no-sink              R4 — the Prisms defect: granted, persisted, spendable nowhere
--   currency-echoed-but-never-spent    R4 — the Prisms defect as it ACTUALLY hid: the spending file
--                                      names the currency in a read-only balance echo. Paired with
--   currency-sunk-via-dynamic-catalog-index
--                                      R4 — ...the positive control, so the rule is not just refusing
--                                      every dynamic `currencies[entry.currency]` spend
--   seam-mediated-spend-is-green       R4 shape 4 — a SECOND green baseline (SEAM_BASE): the shop
--                                      writes NO balance, every debit goes through `ctx.economy:spend`.
--                                      R4's first three shapes made this — the architecture
--                                      games/deep-reach's contract REQUIRES — report both currencies
--                                      un-sunk. Its four refusals, each a different way in:
--   seam-spend-with-currency-declaration-deleted
--                                      R4 — THE PRISMS DEFECT in the seam shape: the only
--                                      Gems-denominated entry deleted, a read-only Gems echo left
--                                      behind (the form the defect actually hid in). The seam call
--                                      still debits Gold and must not certify Gems
--   seam-named-spend-that-adds-is-not-a-sink
--                                      R4 — THE ANTI-LAUNDERING CLAUSE: the seam is verified by
--                                      IMPLEMENTATION, not by name. Also proves the check is scoped to
--                                      the function BODY — `earn` still adds beside it
--   seam-earn-only-file-sinks-nothing  R4 — a file that only ever calls `earn` sinks nothing, even
--                                      with the receiver and the declarations intact
--   seam-spend-on-unattributable-receiver
--                                      R4 — an unresolvable receiver FAILS CLOSED here, the opposite
--                                      of R1's valve, because here it would MANUFACTURE a sink
--   seam-literal-spend-binds-only-that-currency
--                                      R4 — a literal at the call binds only itself; the declaration
--                                      fallback is for DYNAMIC calls only. Paired with
--   seam-literal-spend-per-currency-is-green
--                                      R4 — ...one literal call per currency: GREEN
--   scratch-table-is-not-the-balance-map
--                                      R4 hole A1 — a read-only affordability PREVIEW whose scratch
--                                      table happens to be called `currencies` enrolled as a debit
--                                      body. A token must trace to the function's blob PARAMETER
--   seam-subtraction-only-in-a-nested-block
--                                      R4 hole A8a — every purchase FREE (`local balance = before`),
--                                      the subtraction alive only inside a branch that cannot run.
--                                      The textual one-hop-back scan hopped straight into it
--   seam-spend-labelled-with-another-currency
--                                      R4 hole A4a — THE PRISMS DEFECT IN SEAM CLOTHING: spend Gold,
--                                      name Gems in a SINK LABEL. The key now binds only from the
--                                      argument position the seam's signature names
--   inert-declaration-does-not-certify R4 hole A4b — the whole-file `currency = "<Key>"` regex,
--                                      satisfied by a UI legend no purchase path reads. Also carries
--                                      the annotation-reach-forward defect that rerunning this attack
--                                      against the real games/deep-reach tree exposed in the FIX
--   dead-file-cannot-certify           R4 hole A3 — a brand-new service nothing requires, registers
--                                      or calls, satisfying every other clause. Paired with
--   wired-file-certifies               R4 — ...the identical file with the ONE bootstrap require line
--                                      restored: GREEN. So the rule is not refusing every new file
--   unread-toView-field                R5 — a replicated field no client file reads
--   playerview-count-mismatch          R5 — a field added to PlayerView and never projected. Also the
--                                      truncation guard: the baseline's toView contains a nested `if`,
--                                      which is exactly what silently truncated collect-sim's
--                                      `"function Types%.toView.-\nend"` parse
--   wholesale-copied-subfield-unread   R5 — `stats.joinCount` rides inside a wholesale-copied table;
--                                      without the one-level recursion this is invisible
--   player-type-table                  R6
--   legacy-global                      R7
--   expired-waiver                     S6 — an expired waiver suppresses nothing AND fails on its own
--   bare-subject-waiver                S6 — `capacityFor` (bare) is rejected; collect-sim's INTERNAL_ONLY
--                                      was keyed by bare name, so one exemption covered every homonym
--   over-long-waiver                   S6 — >30 days is a permanent waiver by another name
--   waiver-that-matched-nothing        S6 — a stale waiver for a fixed problem
--   valid-waiver-suppresses            S6 — the positive control: waivers must actually work
--   subject-count-dropped-vs-baseline  the monotonic baseline: 9 seams becoming 8 is the same lie as 0
--   immature-tree                      the maturity carve-out reports `not-applicable`, NEVER
--                                      green-by-zero — asserted as a distinct third state
--   readCorpus-on-disk                 the one filesystem exercise

local gate = require("../gate-reachability")

-- A fixed "now" so every waiver assertion is deterministic (2025-08-01T00:00:00Z-ish).
local NOW = 1754000000
local DAY = 86400

type Src = { path: string, src: string }

-- ── the GREEN baseline corpus ─────────────────────────────────────────────────
-- Small on purpose. It is not a model of a real game; it is the smallest tree in which all eight
-- rules have something to say, so that each mutation below changes exactly one verdict.

local TYPES_SRC = [==[
--!strict
export type PlayerData = {
	schemaVersion: number,
	currencies: { [string]: number },
	stats: { playtimeSeconds: number, joinCount: number },
}

export type PlayerView = {
	schemaVersion: number,
	currencies: { [string]: number },
	stats: { playtimeSeconds: number, joinCount: number },
}

local Types = {}

function Types.toView(data: PlayerData): PlayerView
	-- This nested block is the whole point of the balanced-`return {…}` parse: collect-sim matched
	-- `"function Types%.toView.-\nend"`, non-greedy to the FIRST `\nend`, so any `if`/`for` in the
	-- body silently truncated the field list and every assertion past it was vacuous.
	if data == nil then
		error("toView: nil data")
	end
	return {
		schemaVersion = data.schemaVersion,
		currencies = data.currencies,
		stats = data.stats,
	}
end

return Types
]==]

local MIGRATIONS_SRC = [==[
--!strict
local Migrations = {}

function Migrations.default(nowUnix: number): { [string]: any }
	return {
		schemaVersion = 1,
		currencies = { Gold = 0 },
		stats = { playtimeSeconds = 0, joinCount = 0 },
		upgrades = {},
	}
end

return Migrations
]==]

local SHOP_SRC = [==[
--!strict
local CATALOG: { [string]: any } = {
	["boots"] = { base = 10, currency = "Gold", label = "Boots" },
	["pack"] = { base = 20, currency = "Gold", label = "Pack" },
}

local CATALOG_ORDER: { string } = { "boots", "pack" }

local function levelOf(d: any, id: string): number
	return (d.upgrades[id] or 0)
end

local ShopSeam = {}

function ShopSeam.speedFor(_self: any, d: any): number
	return 16 + levelOf(d, "boots") * 2
end

function ShopSeam.capacityFor(_self: any, d: any): number
	return 50 + levelOf(d, "pack") * 10
end

local Service = {}

function Service.Start(context: any)
	context.upgrades = ShopSeam
	context.net:on("Buy", function(ctx: any, payload: any)
		local entry = CATALOG[payload.id]
		return ctx.data:update(ctx.player, function(d)
			local balance = d.currencies[entry.currency] or 0
			local cost = entry.base
			local newBalance = balance - cost
			d.currencies[entry.currency] = newBalance
			d.upgrades[payload.id] = 1
			return d
		end)
	end)
end

return Service
]==]

local PLAY_SRC = [==[
--!strict
local Play = {}

function Play.Start(context: any)
	task.spawn(function()
		local d = context.data:get()
		local speed = context.upgrades:speedFor(d)
		local cap = context.upgrades:capacityFor(d)
		context.character.Humanoid.WalkSpeed = speed
		context.backpackLimit = cap
	end)
end

return Play
]==]

local HUD_SRC = [==[
--!strict
local Hud = {}

function Hud.render(view: any)
	print(view.schemaVersion)
	local c = view.currencies
	local s = view.stats
	print(s.playtimeSeconds, s.joinCount, c.Gold)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
end

return Hud
]==]

-- THE ROBLOX ENTRY POINT (added 2026-08-05 — hole A3). Rojo makes `src/server` a Script, so this file
-- runs with nothing requiring it: it is the ROOT of the require graph R4 now walks before it will let
-- any file certify a currency. A brand-new service that nothing requires, registers or calls used to
-- certify a currency off a spend that never runs; the edge from THIS registry line is what makes a
-- service live. Without a root in the corpus nothing is reachable and no currency can be certified —
-- which is exactly the property `dead-file-cannot-certify` below asserts.
local ENTRY_SRC = [==[
--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

local PlayService = require(Server.services.play.PlayService)
local ShopService = require(Server.services.shop.ShopService)

local context = {}
PlayService.Start(context)
ShopService.Start(context)
]==]

local BASE: { Src } = {
	{ path = "src/client/controllers/hud/HudController.luau", src = HUD_SRC },
	{ path = "src/server/init.server.luau", src = ENTRY_SRC },
	{ path = "src/server/services/play/PlayService.luau", src = PLAY_SRC },
	{ path = "src/server/services/shop/ShopService.luau", src = SHOP_SRC },
	{ path = "src/shared/Migrations.luau", src = MIGRATIONS_SRC },
	{ path = "src/shared/Types.luau", src = TYPES_SRC },
}

-- ── the SEAM-MEDIATED baseline (R4 shape 4, added 2026-08-05) ─────────────────
-- A SECOND green baseline, because the difference is STRUCTURAL, not a one-token mutation of the
-- first: here the shop writes NO balance at all. games/deep-reach's engineering contract forbids
-- feature code from touching `data.currencies` — every debit goes through `ctx.economy:spend`, and
-- the seam writes the map through a local alias — so R4's first three shapes were unsatisfiable by
-- correct code and reported a game that demonstrably spends both its currencies as sink-less. This
-- corpus is that architecture in miniature: an economy seam, a context that installs it, and a shop
-- that only CALLS it. Two currencies, because the interesting refusals are per-currency.
local SEAM_MIGRATIONS_SRC = [==[
--!strict
local Migrations = {}

function Migrations.default(nowUnix: number): { [string]: any }
	return {
		schemaVersion = 1,
		currencies = { Gold = 0, Gems = 0 },
		stats = { playtimeSeconds = 0, joinCount = 0 },
		upgrades = {},
	}
end

return Migrations
]==]

-- THE seam. `earn` adds and `spend` subtracts, and both write through the SAME local alias — which
-- is what makes this corpus a real test of the anti-laundering clause: the two bodies are textually
-- near-identical and differ only in the operator, so a rule that scanned the MODULE instead of the
-- FUNCTION BODY would certify a spend that adds.
local SEAM_ECONOMY_SRC = [==[
--!strict
local EconomyService = {}

function EconomyService.new(): any
	return setmetatable({}, { __index = EconomyService })
end

function EconomyService.earn(
	_self: any,
	data: any,
	currency: string,
	amount: number,
	source: string
): number
	local currencies = data.currencies
	local map = currencies
	local before = map[currency] or 0
	local balance = before + amount
	map[currency] = balance
	return balance
end

function EconomyService.spend(
	_self: any,
	data: any,
	currency: string,
	amount: number,
	sink: string
): number?
	local currencies = data.currencies
	local map = currencies
	local before = map[currency] or 0
	if before < amount then
		return nil
	end
	local balance = before - amount
	map[currency] = balance
	return balance
end

return EconomyService
]==]

-- The install lives OUTSIDE src/server/services/, exactly as games/deep-reach's Context.luau does, so
-- the seam is reached as `ctx.economy` and the field name `economy` is the attribution token a call
-- site can be resolved by.
local SEAM_CONTEXT_SRC = [==[
--!strict
local EconomyService = require(script.Parent.services.economy.EconomyService)

local Context = {}

function Context.build(): any
	local economy = EconomyService.new()
	return {
		economy = economy,
	}
end

return Context
]==]

-- The shop NEVER touches `data.currencies`. Its only debit is the seam call, and the only thing
-- binding that dynamic call to a concrete currency is the catalog's `currency = "<Key>"` declaration
-- — the same binding shape (3) uses for a dynamic index, and the thing the Prisms defect deletes.
local SEAM_SHOP_SRC = [==[
--!strict
local CATALOG: { [string]: any } = {
	["boots"] = { base = 10, currency = "Gold", label = "Boots" },
	["pack"] = { base = 20, currency = "Gems", label = "Pack" },
}

local CATALOG_ORDER: { string } = { "boots", "pack" }

local function levelOf(d: any, id: string): number
	return (d.upgrades[id] or 0)
end

local ShopSeam = {}

function ShopSeam.speedFor(_self: any, d: any): number
	return 16 + levelOf(d, "boots") * 2
end

function ShopSeam.capacityFor(_self: any, d: any): number
	return 50 + levelOf(d, "pack") * 10
end

local Service = {}

function Service.Start(context: any)
	context.upgrades = ShopSeam
	context.net:on("Buy", function(ctx: any, payload: any)
		local entry = CATALOG[payload.id]
		local economy = ctx.economy
		return ctx.data:update(ctx.player, function(d)
			local cost = entry.base
			local paid = economy:spend(d, entry.currency, cost, "shop." .. payload.id)
			if paid == nil then
				return d
			end
			d.upgrades[payload.id] = 1
			return d
		end)
	end)
end

return Service
]==]

-- The seam corpus's own entry point. `Server.Context` is what pulls EconomyService into the live set
-- (Context requires it), and the two service lines are what make the shop live — the same two edges
-- games/deep-reach's init.server.luau provides for StructuresShopService and EconomyService.
local SEAM_ENTRY_SRC = [==[
--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")

local Context = require(Server.Context)
local PlayService = require(Server.services.play.PlayService)
local ShopService = require(Server.services.shop.ShopService)

local context = Context.build()
PlayService.Start(context)
ShopService.Start(context)
]==]

local SEAM_BASE: { Src } = {
	{ path = "src/client/controllers/hud/HudController.luau", src = HUD_SRC },
	{ path = "src/server/Context.luau", src = SEAM_CONTEXT_SRC },
	{ path = "src/server/init.server.luau", src = SEAM_ENTRY_SRC },
	{ path = "src/server/services/economy/EconomyService.luau", src = SEAM_ECONOMY_SRC },
	{ path = "src/server/services/play/PlayService.luau", src = PLAY_SRC },
	{ path = "src/server/services/shop/ShopService.luau", src = SEAM_SHOP_SRC },
	{ path = "src/shared/Migrations.luau", src = SEAM_MIGRATIONS_SRC },
	{ path = "src/shared/Types.luau", src = TYPES_SRC },
}

local function corpusOf(
	files: { Src },
	mature: boolean,
	baseline: { [string]: number }?
): gate.Corpus
	local out: { gate.CorpusFile } = {}
	for _, f in files do
		table.insert(out, { path = f.path, raw = f.src, masked = gate.mask(f.src) })
	end
	return {
		gameDir = "(fixture)",
		mounts = { "src/client", "src/server", "src/shared" },
		files = out,
		mature = mature,
		baseline = baseline,
	}
end

-- Copy the baseline, replacing `find` with `replace` in exactly one file. A mutation that matches
-- nothing would silently produce the GREEN baseline and a false pass, so `mutate` reports that.
local function mutate(path: string, find: string, replace: string): ({ Src }, string?)
	local out: { Src } = {}
	local hit = false
	for _, f in BASE do
		if f.path == path then
			local newSrc, n = string.gsub(f.src, find, replace, 1)
			if n == 0 then
				return BASE, string.format("mutation %q did not match anything in %s", find, path)
			end
			hit = true
			table.insert(out, { path = path, src = newSrc })
		else
			table.insert(out, f)
		end
	end
	if not hit then
		return BASE, string.format("mutation target file %s is not in the baseline corpus", path)
	end
	return out, nil
end

-- The same single-mutation discipline, against SEAM_BASE.
local function seamMutate(path: string, find: string, replace: string): ({ Src }, string?)
	local out: { Src } = {}
	local hit = false
	for _, f in SEAM_BASE do
		if f.path == path then
			local newSrc, n = string.gsub(f.src, find, replace, 1)
			if n == 0 then
				return SEAM_BASE,
					string.format("mutation %q did not match anything in %s", find, path)
			end
			hit = true
			table.insert(out, { path = path, src = newSrc })
		else
			table.insert(out, f)
		end
	end
	if not hit then
		return SEAM_BASE,
			string.format("mutation target file %s is not in the seam baseline corpus", path)
	end
	return out, nil
end

local function allowOf(entries: { gate.AllowEntry }): gate.Allowlist
	return { entries = entries }
end

local NO_WAIVERS = allowOf({})

return function(): (number, { string })
	local failures: { string } = {}
	local checks = 0

	local function note(msg: string)
		table.insert(failures, msg)
	end

	-- Does the decision carry a FAIL for `rule` whose subject contains `subjectPart`?
	local function hasFail(decision: gate.Decision, rule: string, subjectPart: string): boolean
		for _, f in decision.findings do
			if
				f.level == "FAIL"
				and f.rule == rule
				and string.find(f.subject, subjectPart, 1, true) ~= nil
			then
				return true
			end
		end
		return false
	end

	local function decide(
		files: { Src },
		allow: gate.Allowlist,
		mature: boolean,
		baseline: { [string]: number }?
	): gate.Decision
		return gate.classify(corpusOf(files, mature, baseline), allow, NOW)
	end

	-- A fixture asserting a specific RED. `mutErr` carries a mutation that matched nothing, which is
	-- itself a failure — a fixture that silently degrades into the green baseline proves nothing.
	local function expectRed(
		name: string,
		files: { Src },
		mutErr: string?,
		allow: gate.Allowlist,
		rule: string,
		subjectPart: string
	)
		checks += 1
		if mutErr ~= nil then
			note(name .. ": " .. mutErr)
			return
		end
		local d = decide(files, allow, true, nil)
		if d.ok then
			note(name .. ": expected the gate to go RED, but it reported ok = true")
		elseif not hasFail(d, rule, subjectPart) then
			local seen: { string } = {}
			for _, f in d.findings do
				if f.level == "FAIL" then
					table.insert(seen, f.rule .. "/" .. f.subject)
				end
			end
			note(
				string.format(
					"%s: red, but not for %s on a subject containing %q. Saw: %s",
					name,
					rule,
					subjectPart,
					table.concat(seen, ", ")
				)
			)
		end
	end

	local function expectGreen(name: string, files: { Src }, mutErr: string?, allow: gate.Allowlist)
		checks += 1
		if mutErr ~= nil then
			note(name .. ": " .. mutErr)
			return
		end
		local d = decide(files, allow, true, nil)
		if not d.ok then
			local seen: { string } = {}
			for _, f in d.findings do
				if f.level == "FAIL" then
					table.insert(seen, f.rule .. "/" .. f.subject .. " — " .. f.msg)
				end
			end
			note(name .. ": expected GREEN, got FAILs: " .. table.concat(seen, " | "))
		end
	end

	-- ── 0. the baseline must be GREEN, or every RED below is unattributable ────
	expectGreen("green-baseline", BASE, nil, NO_WAIVERS)

	-- the baseline is green for the RIGHT reason: it actually discovered subjects to check.
	do
		checks += 1
		local d = decide(BASE, NO_WAIVERS, true, nil)
		local want = {
			["seam-read"] = 2,
			["seam-installed"] = 1,
			["catalog-id-read"] = 2,
			["currency-sink"] = 1,
			["view-field-read"] = 5, -- 3 projected + stats.playtimeSeconds + stats.joinCount
		}
		for _, c in d.counts do
			local w = want[c.rule]
			if w ~= nil then
				if c.subjects ~= w then
					note(
						string.format(
							"green-baseline subject count: %s discovered %d, expected %d — a green run with the "
								.. "wrong subject count is vacuity, not a pass",
							c.rule,
							c.subjects,
							w
						)
					)
				end
				want[c.rule] = nil
			end
		end
		for rule in want do
			note("green-baseline: rule " .. rule .. " reported no subject count at all")
		end
	end

	-- ── R1 seam-read ──────────────────────────────────────────────────────────
	do
		local files, err = mutate(
			"src/server/services/play/PlayService.luau",
			"local cap = context%.upgrades:capacityFor%(d%)",
			"local cap = 50"
		)
		expectRed("dangling-seam", files, err, NO_WAIVERS, "seam-read", "ShopSeam.capacityFor")
	end

	-- THE MASKER, falsified both ways. The same seam, "referenced" only inside a comment in the other
	-- file, must stay RED — collect-sim's bare `string.find(source, method, 1, true)` reported exactly
	-- this shape as CONNECTED, which is how a dangling seam passes a reachability gate.
	do
		local files, err = mutate(
			"src/server/services/play/PlayService.luau",
			"local cap = context%.upgrades:capacityFor%(d%)",
			"local cap = 50 -- TODO: call context.upgrades:capacityFor(d) here"
		)
		expectRed(
			"comment-only-reference",
			files,
			err,
			NO_WAIVERS,
			"seam-read",
			"ShopSeam.capacityFor"
		)
	end
	do
		-- The paired positive control: identical text as real CODE is GREEN. Without this pair, the
		-- fixture above could be passing because the gate is broken rather than because it masks.
		local files, err = mutate(
			"src/server/services/play/PlayService.luau",
			"local cap = context%.upgrades:capacityFor%(d%)",
			"local cap = 50\n\t\tlocal c2 = context.upgrades:capacityFor(d)"
		)
		expectGreen("code-reference-is-green", files, err, NO_WAIVERS)
	end

	-- R1 REGRESSION (review, 2026-08-02). A seam method APPLIED IN ITS OWN MODULE is read. R1 first
	-- shipped demanding an OTHER file and so reported collect-sim's
	-- `humanoid.WalkSpeed = UpgradesSeam:walkSpeedFor(d)` — the single correctly-wired upgrade, the one
	-- that previously had no implementation at all — as a dangling seam. Flagging correct code teaches
	-- authors to reach for a waiver, which is how a gate dies. Here `speedFor` loses its only external
	-- caller and gains an in-module application: that must be GREEN.
	do
		local files: { Src } = {}
		for _, f in BASE do
			if f.path == "src/server/services/play/PlayService.luau" then
				table.insert(files, {
					path = f.path,
					src = (string.gsub(f.src, "context%.upgrades:speedFor%(d%)", "0", 1)),
				})
			elseif f.path == "src/server/services/shop/ShopService.luau" then
				table.insert(files, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"local Service = {}",
						"local function applySpeed(plr: any, d: any)\n"
							.. "\tplr.Humanoid.WalkSpeed = ShopSeam:speedFor(d)\n"
							.. "end\n\nlocal Service = {}",
						1
					)),
				})
			else
				table.insert(files, f)
			end
		end
		expectGreen("seam-applied-in-own-module", files, nil, NO_WAIVERS)
	end

	-- ...and the paired RED, so the relaxation above is not the rule going blind: strip the in-module
	-- application too and `speedFor` is called from nowhere at all, which must still fail.
	do
		local files: { Src } = {}
		for _, f in BASE do
			if f.path == "src/server/services/play/PlayService.luau" then
				table.insert(files, {
					path = f.path,
					src = (string.gsub(f.src, "context%.upgrades:speedFor%(d%)", "0", 1)),
				})
			else
				table.insert(files, f)
			end
		end
		expectRed(
			"seam-called-nowhere-at-all",
			files,
			nil,
			NO_WAIVERS,
			"seam-read",
			"ShopSeam.speedFor"
		)
	end

	-- ── R1 ATTRIBUTION — THE HOMONYM HOLE (review, 2026-08-02) ────────────────
	-- R1 shipped asking only whether the BARE METHOD NAME appeared, reference-shaped, in some other
	-- file. games/collect-sim publishes `multiplierFor` on THREE seams (IslandsSeam, RestockSeam,
	-- RebirthSeam), so orphaning any ONE of them stayed GREEN: the other two matched the name. A
	-- collision MASKED a real orphan — the "written here, read nowhere" defect hiding inside the gate
	-- built to catch it. (Not hypothetical: RebirthSeam.multiplierFor was dangling at collect-sim HEAD
	-- and this gate reported 0 FAIL.) The fixture below reproduces that shape exactly, down to the
	-- `(context.islands :: any):multiplierFor(d)` cast the live caller actually uses.
	local ISLANDS_SRC = [==[
--!strict
local IslandsSeam = {}

function IslandsSeam.multiplierFor(_self: any, d: any): number
	return 1 + (d.islandsUnlocked or 0)
end

local Service = {}

function Service.Start(context: any)
	context.islands = IslandsSeam
end

return Service
]==]

	local REBIRTH_SRC = [==[
--!strict
local REBIRTH_STEP = 0.1

local RebirthSeam = {}

function RebirthSeam.multiplierFor(_self: any, d: any): number
	return 1 + (d.rebirths or 0) * REBIRTH_STEP
end

local Service = {}

function Service.Start(context: any)
	context.rebirth = RebirthSeam
end

return Service
]==]

	-- BASE plus the two homonym seams, with `playExtra` spliced into PlayService — the only thing that
	-- differs between the RED fixture and its two positive controls.
	local function homonymCorpus(playExtra: string): { Src }
		local out: { Src } = {}
		for _, f in BASE do
			if f.path == "src/server/services/play/PlayService.luau" then
				table.insert(out, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"local d = context%.data:get%(%)",
						"local d = context.data:get()\n" .. playExtra,
						1
					)),
				})
			else
				table.insert(out, f)
			end
		end
		table.insert(
			out,
			{ path = "src/server/services/islands/IslandsService.luau", src = ISLANDS_SRC }
		)
		table.insert(
			out,
			{ path = "src/server/services/rebirth/RebirthService.luau", src = REBIRTH_SRC }
		)
		return out
	end

	-- Only the ISLANDS multiplier is ever called. The rebirth one is dead — and before the fix, green.
	local ISLANDS_CALL = "\t\tlocal im = (context.islands :: any):multiplierFor(d)\n\t\tprint(im)"
	do
		expectRed(
			"homonym-masks-orphaned-seam",
			homonymCorpus(ISLANDS_CALL),
			nil,
			NO_WAIVERS,
			"seam-read",
			"RebirthSeam.multiplierFor"
		)
	end

	-- POSITIVE CONTROL 1. The same two seams with the SAME colliding name, both actually called: GREEN.
	-- Without this, the fixture above could be passing because R1 now refuses homonyms outright, which
	-- would red-line every correct game that names two seams' methods alike.
	do
		expectGreen(
			"homonym-both-wired-is-green",
			homonymCorpus(
				ISLANDS_CALL .. "\n\t\tlocal rm = context.rebirth:multiplierFor(d)\n\t\tprint(rm)"
			),
			nil,
			NO_WAIVERS
		)
	end

	-- POSITIVE CONTROL 2, and the one the attribution walker could most easily have broken. Real
	-- dispatch in this factory is sometimes DYNAMIC (`tuningFrom(ctx, d, "magnetRadiusFor", …)`) — there
	-- is no receiver to attribute, so the quoted-literal valve must still count. A gate that reported
	-- this live seam as dangling is a FALSE ALARM, and a false alarm gets a gate switched off, which is
	-- worse than no gate.
	do
		expectGreen(
			"homonym-reached-by-dynamic-dispatch-is-green",
			homonymCorpus(
				ISLANDS_CALL
					.. '\n\t\tlocal rm = tuningFrom(context, d, "multiplierFor")\n\t\tprint(rm)'
			),
			nil,
			NO_WAIVERS
		)
	end

	-- ── R2 seam-installed ─────────────────────────────────────────────────────
	do
		local files, err = mutate(
			"src/server/services/shop/ShopService.luau",
			"context%.upgrades = ShopSeam",
			"local unusedInstall = ShopSeam"
		)
		expectRed("uninstalled-seam", files, err, NO_WAIVERS, "seam-installed", "ShopSeam")
	end

	-- ── R3 catalog-id-read — THE 9,625-Stardust defect ────────────────────────
	-- "pack" now appears exactly twice: once in the catalog, once in the order list. Never in a rule.
	do
		local files, err =
			mutate("src/server/services/shop/ShopService.luau", 'levelOf%(d, "pack"%)', "0")
		expectRed("catalog-id-read-nowhere", files, err, NO_WAIVERS, "catalog-id-read", "pack")
	end

	-- R3 REGRESSION (review, 2026-08-02). AN `==` BRANCH IS NOT A READ. R3 first shipped counting any
	-- quoted occurrence outside the catalog/order spans, and a falsification run restored the
	-- 9,625-Stardust defect in its EXACT historical form — the tuning curve kept, still compiling, still
	-- returning a radius, with only `levelOf(d, "magnet")` swapped for the bare constant — and the gate
	-- reported 0 FAIL, because the shop's own effect-PREVIEW dispatcher still said
	-- `elseif upgradeId == "magnet"`. That branch is the UI label; it governs nothing. Here "boots"
	-- keeps a comparison and loses its level read: RED, and for R3, not by accident of some other rule.
	do
		local files, err = mutate(
			"src/server/services/shop/ShopService.luau",
			'return 16 %+ levelOf%(d, "boots"%) %* 2',
			'if d.id == "boots" then\n\t\treturn 18\n\tend\n\treturn 16'
		)
		expectRed(
			"catalog-id-read-only-in-comparison",
			files,
			err,
			NO_WAIVERS,
			"catalog-id-read",
			"boots"
		)
	end

	-- ── R4 currency-sink — THE Prisms defect ──────────────────────────────────
	-- Gems is seeded into the save file and granted by a service, and nothing anywhere decrements it.
	do
		local withGems: { Src } = {}
		for _, f in BASE do
			if f.path == "src/shared/Migrations.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"currencies = { Gold = 0 }",
						"currencies = { Gold = 0, Gems = 0 }",
						1
					)),
				})
			elseif f.path == "src/server/services/play/PlayService.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"local d = context%.data:get%(%)",
						'local d = context.data:get()\n\t\tcontext.data:grant(d, "Gems", 5)',
						1
					)),
				})
			else
				table.insert(withGems, f)
			end
		end
		expectRed(
			"currency-with-no-sink",
			withGems,
			nil,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- R4 REGRESSION (review, 2026-08-02). THE SPEND SITE MUST NAME THE CURRENCY IT SPENDS. R4 first
	-- shipped evaluating "this file names the currency" and "this file can spend" INDEPENDENTLY over the
	-- same file, so a falsification run that deleted collect-sim's only Prism-denominated purchase — the
	-- Prisms defect restored verbatim — reported 0 FAIL: UpgradesShopService named Prisms in a READ-ONLY
	-- balance echo while spending Stardust two hundred lines away. Here the shop echoes a Gems balance
	-- it never spends, and no catalog entry is denominated in Gems. That must be RED, or a currency is
	-- certified sunk by a file that only ever ADDED it.
	do
		local withGems: { Src } = {}
		for _, f in BASE do
			if f.path == "src/shared/Migrations.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"currencies = { Gold = 0 }",
						"currencies = { Gold = 0, Gems = 0 }",
						1
					)),
				})
			elseif f.path == "src/server/services/shop/ShopService.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"local cost = entry%.base",
						"local cost = entry.base\n\t\t\tlocal gemEcho = d.currencies.Gems or 0\n"
							.. "\t\t\tctx.net:push({ gems = gemEcho })",
						1
					)),
				})
			else
				table.insert(withGems, f)
			end
		end
		expectRed(
			"currency-echoed-but-never-spent",
			withGems,
			nil,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- ...and the positive control, so the rule above is not simply refusing every dynamic spend: give
	-- the catalog a Gems-denominated entry and the SAME dynamic `currencies[entry.currency] = …` write
	-- now binds to Gems, which is a real sink. GREEN.
	do
		local withGems: { Src } = {}
		for _, f in BASE do
			if f.path == "src/shared/Migrations.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						"currencies = { Gold = 0 }",
						"currencies = { Gold = 0, Gems = 0 }",
						1
					)),
				})
			elseif f.path == "src/server/services/shop/ShopService.luau" then
				table.insert(withGems, {
					path = f.path,
					src = (string.gsub(
						f.src,
						'%["pack"%] = { base = 20, currency = "Gold", label = "Pack" },',
						'["pack"] = { base = 20, currency = "Gems", label = "Pack" },',
						1
					)),
				})
			else
				table.insert(withGems, f)
			end
		end
		expectGreen("currency-sunk-via-dynamic-catalog-index", withGems, nil, NO_WAIVERS)
	end

	-- ── R4 SHAPE (4): THE SEAM-MEDIATED SPEND (added 2026-08-05) ──────────────
	-- R4's first three shapes all demanded that the SPEND SITE ITSELF write the balance map.
	-- games/deep-reach's contract forbids exactly that (every debit goes through `ctx.economy:spend`,
	-- and the seam writes through a local alias), so R4 was UNSATISFIABLE BY CORRECTLY-ARCHITECTED
	-- CODE and reported both of a game's currencies un-sunk while the game demonstrably spent both.
	-- Two independent agents refused to hand-roll a direct balance write to satisfy the regex. They
	-- were right, so the rule grew a fourth shape — and the shape has to be falsified against THE
	-- ORIGINAL DEFECT, not a convenient mutation, which is what the four REDs below are for.
	expectGreen("seam-mediated-spend-is-green", SEAM_BASE, nil, NO_WAIVERS)

	-- ...green for the RIGHT reason: it discovered both currencies to check.
	do
		checks += 1
		local d = decide(SEAM_BASE, NO_WAIVERS, true, nil)
		local found = false
		for _, c in d.counts do
			if c.rule == "currency-sink" then
				found = true
				if c.subjects ~= 2 then
					note(
						string.format(
							"seam-mediated-spend-is-green: currency-sink discovered %d subjects, expected 2 — "
								.. "a green run with the wrong subject count is vacuity, not a pass",
							c.subjects
						)
					)
				end
			end
		end
		if not found then
			note("seam-mediated-spend-is-green: currency-sink reported no subject count at all")
		end
	end

	-- (1) THE PRISMS DEFECT, restored in the seam shape. Delete the ONLY Gems-denominated catalog
	-- entry — nothing in the game can spend Gems any more — but leave a read-only Gems balance echo
	-- behind, which is the exact form the defect ACTUALLY hid in on collect-sim. The seam call is
	-- still there and still debits Gold; it must no longer certify Gems.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			'%["pack"%] = { base = 20, currency = "Gems", label = "Pack" },',
			'["pack"] = { base = 20, currency = "Gold", label = "Pack" },\n'
				.. "\t-- a read-only echo, the shape the defect hid in\n"
				.. "\tgemEcho = 0,"
		)
		expectRed(
			"seam-spend-with-currency-declaration-deleted",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- (2) THE ANTI-LAUNDERING CLAUSE. A function NAMED `spend` that ADDS is not a sink. The two seam
	-- bodies are textually near-identical and differ only in the operator, so this also proves the
	-- verification is scoped to the FUNCTION BODY: `earn` still contains a `+`, `spend` no longer
	-- contains a `-`, and a module-wide scan would happily certify both currencies anyway.
	do
		local files, err = seamMutate(
			"src/server/services/economy/EconomyService.luau",
			"local balance = before %- amount",
			"local balance = before + amount"
		)
		expectRed(
			"seam-named-spend-that-adds-is-not-a-sink",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gold"
		)
	end

	-- (3) AN EARN-ONLY FILE MUST NOT CERTIFY. The shop keeps its seam receiver, its catalog and its
	-- currency declarations, and calls `earn` with a LITERAL currency instead of `spend`. `earn`'s
	-- body adds, so it is not in the debiting set and nothing here is a sink.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			"economy:spend%(d, entry%.currency, cost,",
			'economy:earn(d, "Gold", cost,'
		)
		expectRed(
			"seam-earn-only-file-sinks-nothing",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gold"
		)
	end

	-- (4) AN UNATTRIBUTABLE RECEIVER FAILS CLOSED. The call shape and the declarations are untouched;
	-- only the receiver changes to something no walker can resolve to the debiting seam. R1 lets an
	-- unresolvable receiver SUPPRESS a failure because there the risk is a false alarm; here it would
	-- MANUFACTURE a sink, so the two rules deliberately fail in opposite directions.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			"local economy = ctx%.economy\n",
			"local ledger = ctx.ledger\n"
		)
		local files2: { Src } = {}
		for _, f in files do
			if f.path == "src/server/services/shop/ShopService.luau" then
				table.insert(files2, {
					path = f.path,
					src = (string.gsub(f.src, "economy:spend%(", "ledger:spend(", 1)),
				})
			else
				table.insert(files2, f)
			end
		end
		expectRed(
			"seam-spend-on-unattributable-receiver",
			files2,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gold"
		)
	end

	-- (5) A LITERAL AT THE CALL BINDS ONLY ITSELF. The declaration fallback exists for DYNAMIC calls
	-- (`spend(d, entry.currency, …)`); a call that names its currency outright must not drag every
	-- other `currency = "<Key>"` in the file along with it. Gold stays sunk, Gems does not.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			"economy:spend%(d, entry%.currency, cost,",
			'economy:spend(d, "Gold", cost,'
		)
		expectRed(
			"seam-literal-spend-binds-only-that-currency",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- ...and the positive control for the literal form, so (5) is not the rule simply refusing every
	-- literal spend: give each currency its own literal call and BOTH are sunk. GREEN.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			'local paid = economy:spend%(d, entry%.currency, cost, "shop%." %.%. payload%.id%)',
			'local paid = economy:spend(d, "Gold", cost, "shop.gold")\n'
				.. '\t\t\tlocal paid2 = economy:spend(d, "Gems", cost, "shop.gems")\n'
				.. "\t\t\tif paid2 == nil then\n\t\t\t\treturn d\n\t\t\tend"
		)
		expectGreen("seam-literal-spend-per-currency-is-green", files, err, NO_WAIVERS)
	end

	-- ── SHAPE (4), SECOND HARDENING PASS (2026-08-05) ─────────────────────────
	-- An INDEPENDENT ADVERSARY ran twelve laundering attacks against the shape above and got SIX of
	-- them past it. Five are closed below, each with the attack reconstructed as a single mutation of
	-- SEAM_BASE — and each one was verified GREEN (i.e. laundered) against the rule as it stood before
	-- the fix, which is the only thing that makes these fixtures evidence rather than decoration.

	-- (6) HOLE A1 — A SCRATCH TABLE IS NOT THE BALANCE MAP. `balanceMapTokens` seeded its token list
	-- with the BARE NAME `currencies`, so a read-only affordability PREVIEW that happens to build a
	-- local table of that name enrolled as a debit body: `local currencies = {}` …
	-- `currencies[k] = before - cost` writes nothing a player owns, and certified both currencies of a
	-- game that now spends neither. The seam is otherwise untouched — same name, same receiver, same
	-- call site — so the ONLY thing under test is whether a token has to trace to the function's own
	-- blob parameter.
	do
		local files, err = seamMutate(
			"src/server/services/economy/EconomyService.luau",
			"function EconomyService%.spend%(.-\nend",
			"function EconomyService.spend(\n"
				.. "\t_self: any,\n\tdata: any,\n\tcurrency: string,\n\tamount: number,\n\tsink: string\n"
				.. "): number?\n"
				.. "\t-- A PREVIEW: it answers 'could you afford this', and writes nothing anyone owns.\n"
				.. "\tlocal currencies = {}\n"
				.. "\tlocal before = data.currencies[currency] or 0\n"
				.. "\tif before < amount then\n\t\treturn nil\n\tend\n"
				.. "\tcurrencies[currency] = before - amount\n"
				.. "\treturn currencies[currency]\n"
				.. "end"
		)
		expectRed(
			"scratch-table-is-not-the-balance-map",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gold"
		)
	end

	-- (7) HOLE A8a — THE SEAM'S SUBTRACTION CAN BE DEAD. Every purchase is now FREE: the stored value
	-- is `before`, and the subtraction survives only inside a branch that cannot be taken (`amount` is
	-- guarded > 0 by every caller shape this factory writes). The textual one-hop-back scan hopped
	-- straight into the dead assignment and certified both currencies — reopening, one level up, the
	-- exact hole the "bind the subtraction to the write" clause was written to close.
	do
		local files, err = seamMutate(
			"src/server/services/economy/EconomyService.luau",
			"\tlocal balance = before %- amount\n\tmap%[currency%] = balance\n\treturn balance",
			"\tlocal balance = before\n"
				.. "\tif amount < 0 then\n\t\tbalance = before - amount\n\tend\n"
				.. "\tmap[currency] = balance\n\treturn balance"
		)
		expectRed(
			"seam-subtraction-only-in-a-nested-block",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gold"
		)
	end

	-- (8) HOLE A4a — THE CURRENCY BINDS ONLY FROM THE CURRENCY ARGUMENT POSITION. THIS IS THE PRISMS
	-- DEFECT IN SEAM CLOTHING: spend A, name B. The shop debits GOLD outright and mentions Gems in a
	-- SINK LABEL, and the old test — "is the quoted key anywhere inside the parenthesised span" —
	-- certified Gems off that label. The position now comes from the seam's own signature (the
	-- parameter named like a currency), so the label argument binds nothing.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			'economy:spend%(d, entry%.currency, cost, "shop%." %.%. payload%.id%)',
			'economy:spend(d, "Gold", cost, { sink = "shop", currency = "Gems" })'
		)
		expectRed(
			"seam-spend-labelled-with-another-currency",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- (9) HOLE A4b — AN INERT DECLARATION MUST NOT CERTIFY. Nothing is denominated in Gems any more
	-- (the `pack` row is Gold), and the only `currency = "Gems"` left is a UI LEGEND — a table no
	-- purchase path reads. The whole-file `declaresCurrency` regex could not tell that from a price,
	-- so the dynamic `economy:spend(d, entry.currency, …)` certified Gems off a label table. The
	-- declaration is now required INSIDE the catalog the dynamic expression actually indexes.
	--
	-- The legend sits BELOW a helper whose PARAMETER is annotated `entry: any`, and that is not
	-- decoration: the first version of this fix accepted any `: …` between a name and the next `=`, so
	-- the ANNOTATION reached forward past its own statement and adopted the legend as `entry`'s table
	-- — certifying Gems again through the very clause written to stop it. Rerunning this hole against
	-- the real games/deep-reach tree is what exposed that; this fixture is that finding, made
	-- permanent.
	do
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			'%["pack"%] = { base = 20, currency = "Gems", label = "Pack" },',
			'["pack"] = { base = 20, currency = "Gold", label = "Pack" },\n'
				.. "}\n\nlocal function costOf(entry: any, level: number): number\n"
				.. "\treturn entry.base * (level + 1)\nend\n\n"
				.. "-- A UI legend: rendered, never priced against, never spent.\n"
				.. "local LEGEND: { [string]: any } = {\n"
				.. '\t["gems"] = { currency = "Gems", label = "Gems", icon = "rbxassetid://0" },'
		)
		expectRed(
			"inert-declaration-does-not-certify",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- (10) HOLE A3 — A DEAD FILE MUST NOT CERTIFY. `PearlAltarService.luau` is brand new and nothing
	-- requires it, registers it or calls it: it is not in the bootstrap's list and no module names it.
	-- It satisfies every OTHER clause of shape (4) — attributable receiver, debiting seam, the key as a
	-- literal in the currency argument position — and it still must not certify Gems, because the code
	-- never runs. (The corpus is every .luau under a Rojo mount; being a file is not being alive.)
	local ALTAR_SRC = [==[
--!strict
local PearlAltarService = {}

function PearlAltarService.Start(ctx: any)
	ctx.net:on("Altar", function(c: any, payload: any)
		local economy = c.economy
		return c.data:update(c.player, function(d)
			local paid = economy:spend(d, "Gems", 5, "altar.offering")
			if paid == nil then
				return d
			end
			d.upgrades.altar = 1
			return d
		end)
	end)
end

return PearlAltarService
]==]

	-- SEAM_BASE with nothing denominated in Gems any more, plus the altar file. `wired` splices the
	-- altar into the bootstrap, which is the ONLY difference between the RED and its positive control.
	local function altarCorpus(wired: boolean): ({ Src }, string?)
		local files, err = seamMutate(
			"src/server/services/shop/ShopService.luau",
			'%["pack"%] = { base = 20, currency = "Gems", label = "Pack" },',
			'["pack"] = { base = 20, currency = "Gold", label = "Pack" },'
		)
		if err ~= nil then
			return files, err
		end
		local out: { Src } = {}
		for _, f in files do
			if wired and f.path == "src/server/init.server.luau" then
				local src, n = string.gsub(
					f.src,
					"local ShopService = require%(Server%.services%.shop%.ShopService%)",
					"local ShopService = require(Server.services.shop.ShopService)\n"
						.. "local PearlAltarService = require(Server.services.altar.PearlAltarService)",
					1
				)
				if n == 0 then
					return files, "altarCorpus: the bootstrap mutation matched nothing"
				end
				src = src .. "PearlAltarService.Start(context)\n"
				table.insert(out, { path = f.path, src = src })
			else
				table.insert(out, f)
			end
		end
		table.insert(
			out,
			{ path = "src/server/services/altar/PearlAltarService.luau", src = ALTAR_SRC }
		)
		return out, nil
	end

	do
		local files, err = altarCorpus(false)
		expectRed(
			"dead-file-cannot-certify",
			files,
			err,
			NO_WAIVERS,
			"currency-sink",
			"currencies.Gems"
		)
	end

	-- ...and the paired positive control, so the rule above is not "R4 refuses every new file": add
	-- the ONE require line the bootstrap was missing and the identical altar certifies Gems. GREEN.
	do
		local files, err = altarCorpus(true)
		expectGreen("wired-file-certifies", files, err, NO_WAIVERS)
	end

	-- ── R5 view-field-read ────────────────────────────────────────────────────
	do
		local files, err = mutate(
			"src/client/controllers/hud/HudController.luau",
			"print%(view%.schemaVersion%)",
			""
		)
		expectRed(
			"unread-toView-field",
			files,
			err,
			NO_WAIVERS,
			"view-field-read",
			"PlayerView.schemaVersion"
		)
	end

	-- A field added to PlayerView and never projected: the client sees nil forever. The same
	-- cross-check is what makes the projection parse non-vacuous.
	do
		local files, err = mutate(
			"src/shared/Types.luau",
			"export type PlayerView = {\n\tschemaVersion: number,",
			"export type PlayerView = {\n\tschemaVersion: number,\n\trebirths: number,"
		)
		expectRed(
			"playerview-count-mismatch",
			files,
			err,
			NO_WAIVERS,
			"view-field-read",
			"Types.luau::PlayerView"
		)
	end

	-- The one-level recursion. `stats` is copied WHOLESALE, so without recursing the gate checks the
	-- table name `stats`, finds it read, and calls itself complete while joinCount rides along unread.
	do
		local files, err = mutate(
			"src/client/controllers/hud/HudController.luau",
			"print%(s%.playtimeSeconds, s%.joinCount, c%.Gold%)",
			"print(s.playtimeSeconds, c.Gold)"
		)
		expectRed(
			"wholesale-copied-subfield-unread",
			files,
			err,
			NO_WAIVERS,
			"view-field-read",
			"PlayerView.stats.joinCount"
		)
	end

	-- ── R6 banned-player-type ─────────────────────────────────────────────────
	do
		local files, err = mutate(
			"src/server/services/play/PlayService.luau",
			"local d = context%.data:get%(%)",
			'local d = context.data:get()\n\t\tif type(player) == "table" then\n\t\t\treturn\n\t\tend'
		)
		expectRed("player-type-table", files, err, NO_WAIVERS, "banned-player-type", "PlayService")
	end

	-- ── R7 legacy-globals ─────────────────────────────────────────────────────
	do
		local files, err = mutate(
			"src/server/services/play/PlayService.luau",
			"local d = context%.data:get%(%)",
			"wait(1)\n\t\tlocal d = context.data:get()"
		)
		expectRed("legacy-global", files, err, NO_WAIVERS, "legacy-globals", "PlayService")
	end

	-- ── S6 the dated allowlist ────────────────────────────────────────────────
	local DANGLING_SUBJECT = "ShopService.luau::ShopSeam.capacityFor"
	local danglingFiles, danglingErr = mutate(
		"src/server/services/play/PlayService.luau",
		"local cap = context%.upgrades:capacityFor%(d%)",
		"local cap = 50"
	)

	-- Positive control: a VALID waiver must actually suppress, or authors will (correctly) conclude
	-- the mechanism is decorative and start deleting rules instead.
	do
		local allow = allowOf({
			{
				rule = "seam-read",
				subject = DANGLING_SUBJECT,
				reason = "fixture: composed internally; its output is what crosses the boundary",
				addedUnix = NOW - 1000,
				addedBy = "human",
				expiresUnix = NOW + 10 * DAY,
			},
		})
		expectGreen("valid-waiver-suppresses", danglingFiles, danglingErr, allow)
		checks += 1
		local d = decide(danglingFiles, allow, true, nil)
		if #d.waivers ~= 1 then
			note("valid-waiver-suppresses: the active waiver was not echoed into the decision")
		end
	end

	-- An expired waiver suppresses NOTHING. A date in a comment expires nothing; a date in the file
	-- does, and it must bite.
	do
		local allow = allowOf({
			{
				rule = "seam-read",
				subject = DANGLING_SUBJECT,
				reason = "fixture: stale",
				addedUnix = NOW - 40 * DAY,
				addedBy = "human",
				expiresUnix = NOW - DAY,
			},
		})
		expectRed("expired-waiver", danglingFiles, danglingErr, allow, "seam-read", "capacityFor")
	end

	-- A BARE subject. collect-sim's INTERNAL_ONLY was keyed by bare method name, so exempting
	-- `tuningFor` exempted every `tuningFor` in the game.
	do
		local allow = allowOf({
			{
				rule = "seam-read",
				subject = "capacityFor",
				reason = "fixture: bare name",
				addedUnix = NOW - 1000,
				addedBy = "human",
				expiresUnix = NOW + 10 * DAY,
			},
		})
		expectRed(
			"bare-subject-waiver",
			danglingFiles,
			danglingErr,
			allow,
			"seam-read",
			"capacityFor"
		)
	end

	-- >30 days is a permanent waiver wearing a date.
	do
		local allow = allowOf({
			{
				rule = "seam-read",
				subject = DANGLING_SUBJECT,
				reason = "fixture: too long",
				addedUnix = NOW - 1000,
				addedBy = "human",
				expiresUnix = NOW + 365 * DAY,
			},
		})
		expectRed("over-long-waiver", danglingFiles, danglingErr, allow, "allowlist", "capacityFor")
	end

	-- A waiver that matched nothing: the problem was fixed and the suppression stayed behind.
	do
		local allow = allowOf({
			{
				rule = "seam-read",
				subject = "ShopService.luau::ShopSeam.longGoneMethod",
				reason = "fixture: for a method that no longer exists",
				addedUnix = NOW - 1000,
				addedBy = "human",
				expiresUnix = NOW + 10 * DAY,
			},
		})
		expectRed("waiver-that-matched-nothing", BASE, nil, allow, "allowlist", "longGoneMethod")
	end

	-- ── the monotonic baseline ────────────────────────────────────────────────
	-- 9 seams becoming 8 passes every `> 0` check ever written, and 16 becoming 2 is the same lie as 0.
	do
		checks += 1
		local d = decide(BASE, NO_WAIVERS, true, { ["seam-read"] = 9 })
		if d.ok or not hasFail(d, "seam-read", "reachability-baseline") then
			note("subject-count-dropped-vs-baseline: a DROP in discovered subjects did not fail")
		end
	end
	do
		checks += 1
		-- and a baseline that is met does not fire
		local d = decide(BASE, NO_WAIVERS, true, { ["seam-read"] = 2 })
		if not d.ok then
			note("baseline-met: a met baseline must not fail the gate")
		end
	end

	-- A tree that populates every declared mount but contains no seams, no catalog, no currencies and
	-- no toView — i.e. a scaffold. Used for both maturity states below.
	local EMPTY_TREE: { Src } = {
		{
			path = "src/client/controllers/sample/SampleController.luau",
			src = "--!strict\nreturn {}\n",
		},
		{ path = "src/server/services/sample/SampleService.luau", src = "--!strict\nreturn {}\n" },
		{ path = "src/shared/Config.luau", src = "--!strict\nreturn {}\n" },
	}

	-- ── the maturity carve-out: a THIRD state, never green-by-zero ────────────
	do
		checks += 1
		local d = gate.classify(corpusOf(EMPTY_TREE, false, nil), NO_WAIVERS, NOW)
		if not d.ok then
			note("immature-tree: a fresh scaffold must PASS, or new-game is broken for every game")
		end
		local sawNotApplicable = 0
		for _, c in d.counts do
			if
				not c.applicable
				and (
					c.rule == "seam-read"
					or c.rule == "seam-installed"
					or c.rule == "catalog-id-read"
					or c.rule == "currency-sink"
					or c.rule == "view-field-read"
				)
			then
				sawNotApplicable += 1
			end
		end
		if sawNotApplicable ~= 5 then
			note(
				string.format(
					"immature-tree: expected all 5 subject rules reported as not-applicable, saw %d — a rule "
						.. "silently reported as an APPLICABLE zero would be green-by-vacuity",
					sawNotApplicable
				)
			)
		end
	end

	-- ── the third state must reach the FIELD A MACHINE READS (review, 2026-08-02) ──
	-- The carve-out above was scrupulously honest in PROSE and silent in DATA: a fresh scaffold ran to
	-- `0 FAIL, EXIT 0` with all five subject rules `not-applicable` and the STAGE BOOLEAN `true`, and the
	-- gauntlet reads only that boolean. So a game below maturity recorded a plain green — a silent
	-- zero-coverage pass, doctrine 2 failing at the one place a machine looks. The scaffold must still
	-- PASS (or `new-game` is broken for every future game), so the distinction rides beside `ok`.
	do
		checks += 1
		local d = gate.classify(corpusOf(EMPTY_TREE, false, nil), NO_WAIVERS, NOW)
		if d.coverage ~= "not-applicable" then
			note(
				string.format(
					"coverage-is-machine-readable: a below-maturity tree reported coverage %q — a consumer "
						.. "reading only `ok` cannot tell 'nothing failed' from 'nothing was checked'",
					tostring(d.coverage)
				)
			)
		end
		if not d.ok then
			note("coverage-is-machine-readable: the scaffold must still PASS, not fail")
		end
	end
	do
		-- ...and the paired positive control: a MATURE corpus that really did check things must say so,
		-- or the new field is just a constant and proves nothing.
		checks += 1
		local d = decide(BASE, NO_WAIVERS, true, nil)
		if d.coverage ~= "verified" then
			note(
				string.format(
					'coverage-verified: a mature corpus with subjects reported coverage %q, expected "verified"',
					tostring(d.coverage)
				)
			)
		end
	end
	do
		-- The STAGE is what the gauntlet actually consumes, so assert it there too: `core/` is the fork
		-- base, below maturity by construction, and it must hand out `ok = true` WITH `not-applicable`.
		checks += 1
		local stage = gate.run("core")
		if not stage.ok then
			note("coverage-on-stage: core/ must pass through the maturity carve-out")
		end
		if stage.coverage ~= "not-applicable" then
			note(
				string.format(
					"coverage-on-stage: core/ Stage carried coverage %q — the gauntlet reads the Stage, so a "
						.. "third state that never reaches it is a third state that does not exist",
					tostring(stage.coverage)
				)
			)
		end
	end

	-- Above maturity, the same near-empty tree is a HARD FAIL: zero subjects is never a pass.
	do
		checks += 1
		local d = gate.classify(corpusOf(EMPTY_TREE, true, nil), NO_WAIVERS, NOW)
		if d.ok then
			note(
				"zero-subjects-at-maturity: a mature tree with no discoverable subjects reported GREEN"
			)
		end
	end

	-- ── presence: a mount with no files is vacuous ────────────────────────────
	do
		checks += 1
		local c = corpusOf(BASE, true, nil)
		table.insert(c.mounts, "src/plugin")
		local d = gate.classify(c, NO_WAIVERS, NOW)
		if d.ok or not hasFail(d, "presence", "src/plugin") then
			note("empty-mount: a Rojo mount with no .luau file must fail as vacuous")
		end
	end

	-- ── the one filesystem exercise: M.readCorpus against the real core/ tree ──
	-- `core/` is the fork base every game starts from, so this also pins the fresh-scaffold promise:
	-- the factory's own foundation must be GREEN through the maturity carve-out, not through luck.
	do
		checks += 1
		local corpus = gate.readCorpus("core")
		if #corpus.files == 0 then
			note(
				"readCorpus-on-disk: read zero .luau files from core/ — the filesystem path is broken"
			)
		elseif #corpus.mounts == 0 then
			note("readCorpus-on-disk: read zero Rojo mounts from core/default.project.json")
		elseif corpus.mature then
			note("readCorpus-on-disk: core/ reported MATURE, but it ships only services/sample")
		else
			local d = gate.classify(corpus, NO_WAIVERS, NOW)
			if not d.ok then
				note("readCorpus-on-disk: the core/ fork base must pass via the maturity carve-out")
			end
		end
	end

	-- ── M.run never throws, whatever it is pointed at (gauntlet.luau:120 has no pcall) ──
	do
		checks += 1
		local ok, stage = pcall(gate.run, "no/such/directory/at/all")
		if not ok then
			note("run-never-throws: M.run threw instead of returning a red Stage")
		elseif (stage :: gate.Stage).name ~= "reachability" then
			note("run-never-throws: the Stage name must be exactly `reachability`")
		end
	end

	return checks, failures
end
