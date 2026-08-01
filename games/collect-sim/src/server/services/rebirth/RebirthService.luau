--!strict
-- games/collect-sim/src/server/services/rebirth/RebirthService.luau   [rebirth — prestige loop completion]
-- Feature: rebirth/prestige. The player FULLY PRESTIGE-RESETS their run for permanent power. A rebirth
-- requires a SERVER-OWNED Stardust threshold; on success it ATOMICALLY, in ONE ctx.data:update
-- transform on the lock-held re-read snapshot:
--   1. zeroes currencies.Stardust (the prestige spend — NOT an earn, so stats.lifetimeStardust is
--      NEVER touched),
--   2. clears every NON-PERMANENT upgrade level (the `prism-` tier survives — see below),
--   3. increments the persisted top-level `rebirths` COUNT by 1,
--   4. grants currencies.Prisms += a SERVER-DERIVED amount (the client supplies NO number).
-- PRESERVED across the rebirth: the ISLAND UNLOCK FLAGS (this is the fix — see the block below),
-- the rebirths count (it increments), currencies.Prisms (accumulates over rebirths), every
-- `prism-` upgrade, stats.lifetimeStardust (a rebirth is a spend/zero, never an earn), and the
-- gamepass flags (flags['gamepass.*'] — purchases persist).
--
-- DERIVED MULTIPLIER (NEVER persisted): the permanent rebirth multiplier is 1 + rebirths*REBIRTH_STEP,
-- computed at READ by the consolidated Sell formula in CollectionService (REBIRTH_STEP = 0.1). This
-- service stores ONLY the rebirths COUNT; it never stores a multiplier. (The mirror constant below is
-- documentation/derivation-only — Sell owns the authoritative step.)
--
-- AUTHORITY (CLAUDE.md §3): the rebirth THRESHOLD and the Prisms GRANT FORMULA are SERVER-OWNED and
-- SERVER-AUTHORITATIVE. The client sends an EMPTY intent {} — no rebirth count, no Prisms amount, no
-- multiplier. Below the threshold the action returns Insufficient.
--
-- CONCURRENCY-SAFE (CLAUDE.md §4, the economy red-team target): every operand the rebirth reads or
-- writes (Stardust, upgrades, island flags, rebirths, Prisms) lives in PERSISTED PlayerData, so the
-- ENTIRE threshold-check + full reset + Prisms grant happens INSIDE ONE ctx.data:update transform.
-- That transform runs under the per-player FIFO lock on a FRESH re-read snapshot (DataService.update /
-- MockStore), so it is atomic: an interleaved or spam-duplicated Rebirth (or an interleaved
-- Sell/BuyUpgrade/UnlockIsland) re-reads the POST-write snapshot — where Stardust is already zeroed
-- below the threshold — and stops at the threshold check. It therefore can NEVER dupe Prisms, NEVER
-- double-increment the count, and NEVER double-reset. There is NO read-then-write across the yield:
-- the transform body is synchronous and reads ONLY the snapshot it is handed; the Prisms amount is
-- derived INSIDE the transform from that same lock-held snapshot.
--
-- Dual-runtime require [D1 shim]: under Lune (script == nil) these resolve via the filesystem and touch
-- no Roblox global, so a spec drives the action through Mocks.net -> Net.dispatch. In Roblox, src/shared
-- maps to ReplicatedStorage.Shared (a DIFFERENT service than this ServerScriptService module), so the
-- relative string can't reach it — the script ~= nil branch requires it by instance.
local Net, Result
if script == nil then
	Net = require("../../../shared/Net")
	Result = require("../../../shared/Result")
else
	local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	Net = require((Shared :: any).Net)
	Result = require((Shared :: any).Result)
end

-- ----- SERVER-OWNED CONSTANTS (authoritative; the client never sees or supplies any of this) -----
--
-- ----- WHY THIS FILE CHANGED: REBIRTH WAS A PAY CUT -----
-- It used to CLEAR the island unlock flags. Island 3 turns a 150-mote backpack worth 600 into 165
-- (`floor(150 * 1 * 1.1)`) — a 72.5% cut, and 93% from island 5. It deleted a multiplicative bonus
-- worth up to 16x and handed back an additive +0.1x. Worse, the flat 1000 threshold never scaled
-- while `rebirths` was uncapped, so once a player noticed islands were a trap the optimal play was
-- rebirth-spam, each one faster than the last. And the Prisms it granted were persisted, displayed,
-- and decremented by NOTHING — there was no Prism shop, pad or action anywhere in the codebase.
--
-- What a rebirth costs now: Stardust and the four Stardust upgrades. What it PRESERVES: the islands
-- you unlocked (that is earned progression, not a run resource), the gamepass flags, and every
-- PERMANENT `prism-` upgrade. What it PAYS: a rising permanent multiplier plus Prisms, which the
-- shop now actually spends. Post-rebirth earn-per-mote therefore strictly EXCEEDS pre-rebirth.
--
-- The Stardust threshold for the NEXT rebirth: base * (rebirths + 1)^exponent. A rising curve, so
-- each prestige is a longer run than the last instead of a faster one.
local REBIRTH_BASE_THRESHOLD = 1000
local REBIRTH_THRESHOLD_EXPONENT = 1.6
-- Cap the count so the derived multiplier and the threshold curve both stay finite and sane
-- (1 + 50*0.1 = 6x at the cap).
local MAX_REBIRTHS = 50

-- The Prisms granted per rebirth: a flat base plus a bonus scaling with how far past the threshold
-- the run was pushed. Server-derived; integer. Trust ZERO client numbers.
local PRISM_BASE = 1
local PRISM_PER_THRESHOLD = 1

-- Mirror of CollectionService's REBIRTH_STEP, kept ONLY to document the derived multiplier
-- (1 + rebirths*REBIRTH_STEP). The multiplier is applied at Sell, NOT here, and is NEVER persisted.
local REBIRTH_STEP = 0.1

-- Upgrade ids with this prefix are PERMANENT and survive the reset (the Prism tier). Mirrors
-- UpgradesShopService's convention; the seam is consulted first and this is the fallback for when
-- no shop service is wired.
local PERMANENT_UPGRADE_PREFIX = "prism-"

-- PURE: the Stardust needed for the rebirth AFTER `rebirths` completed ones.
local function thresholdFor(rebirths: number): number
	local count = math.max(0, math.floor(rebirths or 0))
	return math.floor(REBIRTH_BASE_THRESHOLD * (count + 1) ^ REBIRTH_THRESHOLD_EXPONENT)
end

-- Server-derived Prisms grant from the Stardust held at the moment of rebirth, measured against
-- THIS rebirth's threshold so a deeper run on a harder curve still pays more.
local function prismsFor(stardust: number, threshold: number): number
	local safeThreshold = math.max(1, threshold)
	return PRISM_BASE + math.floor(stardust / safeThreshold) * PRISM_PER_THRESHOLD
end

-- Whether an upgrade id survives the reset. Asks the shop seam first so the two can never disagree
-- about what a rebirth costs; falls back to the prefix convention when no shop service is wired.
local function isPermanentUpgrade(ctx: any, upgradeId: string): boolean
	local seam = ctx ~= nil and ctx.upgrades or nil
	if seam ~= nil and type(seam.isPermanent) == "function" then
		local ok, value = pcall(seam.isPermanent, seam, upgradeId)
		if ok then
			return value == true
		end
	end
	return type(upgradeId) == "string"
		and string.sub(upgradeId, 1, #PERMANENT_UPGRADE_PREFIX) == PERMANENT_UPGRADE_PREFIX
end

local RebirthService = { name = "RebirthService" }

-- Build the Rebirth action. No closed-over feature state is needed: every operand is persisted
-- PlayerData, mutated atomically inside the single update transform on the lock-held snapshot.
local function makeRebirthAction(): Net.Action<{}, {
	rebirths: number,
	prismsEarned: number,
	prisms: number,
	multiplier: number,
	threshold: number,
	nextThreshold: number,
}>
	return {
		name = Net.Actions.Rebirth, -- "rebirth.do"
		-- Deliberate, high-stakes action (a full reset): a tight bucket so spam-duplicated rebirths are
		-- also rate-shed. The concurrency guarantee does NOT rely on this — it is defence in depth; the
		-- single-transform threshold re-read is what actually prevents a dupe.
		rate = { maxPerWindow = 3, windowSeconds = 1 },
		validate = function(raw): Result.Result<{}>
			-- Untrusted payload: accept ONLY an empty intent. The client supplies NO rebirth count, NO
			-- Prisms amount, NO multiplier — any field it sends is ignored by never being read.
			if typeof(raw) ~= "table" then
				return Result.err(Result.Codes.BadPayload)
			end
			return Result.ok({})
		end,
		handler = function(
			ctx,
			_payload
		): Result.Result<{
			rebirths: number,
			prismsEarned: number,
			prisms: number,
			multiplier: number,
			threshold: number,
			nextThreshold: number,
		}>
			-- ----- CONCURRENCY-SAFE PRESTIGE RESET (the economy red-team target) -----
			-- The ENTIRE decision — threshold check, full reset, and Prisms grant — is made INSIDE the
			-- transform, on the lock-held re-read snapshot. We capture the OUTCOME (or a rejection code)
			-- into locals the transform closes over; the transform mutates `d` ONLY on success and returns
			-- `d` unchanged on a rejection. Because it runs under the per-player FIFO lock on the FRESHEST
			-- value, two interleaved/spam-duplicated rebirths serialise: the second re-reads the
			-- already-zeroed Stardust (now below the threshold) and stops at the check — so Prisms are
			-- never duped, the count never double-increments, and the reset never runs twice.
			local rejectCode: string? = nil
			local rejectMessage: string? = nil
			local outRebirths = 0
			local outPrismsEarned = 0
			local outPrisms = 0
			local outThreshold = thresholdFor(0)

			local updated = ctx.data:update(ctx.player, function(d)
				-- Re-read the CURRENT Stardust and rebirth count from the lock-held snapshot. The
				-- threshold RISES with the count, so each prestige is a longer run than the last
				-- rather than a faster one (the flat 1000 made rebirth-spam optimal).
				local stardust = (d.currencies and d.currencies.Stardust) or 0
				local rebirths = math.max(0, math.floor(d.rebirths or 0))
				local threshold = thresholdFor(rebirths)
				outThreshold = threshold

				if rebirths >= MAX_REBIRTHS then
					rejectCode = Result.Codes.OutOfRange
					rejectMessage = "rebirth cap reached"
					return d
				end
				if stardust < threshold then
					-- Below the server-owned threshold: NO reset, NO grant. This is ALSO the
					-- spam-duplicate guard: a second rebirth re-reads the just-zeroed Stardust.
					rejectCode = Result.Codes.Insufficient
					rejectMessage = "below rebirth Stardust threshold"
					return d
				end

				-- Derive the Prisms grant from the lock-held Stardust BEFORE zeroing it.
				local prismsEarned = prismsFor(stardust, threshold)

				-- 1. ZERO the run currency (a spend, NOT an earn -> lifetimeStardust untouched).
				d.currencies.Stardust = 0

				-- 2. GRANT Prisms (accumulates across rebirths, and now BUYS something).
				if d.currencies == nil then
					d.currencies = {}
				end
				d.currencies.Prisms = (d.currencies.Prisms or 0) + prismsEarned

				-- 3. RESET the RUN upgrades only. PERMANENT `prism-` levels survive — they were
				--    bought with the prestige currency, so wiping them would make the reward pay
				--    for something the reset then destroys. (The old code assigned `d.upgrades = {}`
				--    wholesale, which was theatre anyway: nothing read d.upgrades at all.)
				if type(d.upgrades) == "table" then
					for upgradeId in d.upgrades do
						if not isPermanentUpgrade(ctx, upgradeId) then
							d.upgrades[upgradeId] = nil
						end
					end
				else
					d.upgrades = {}
				end

				-- 4. ISLAND FLAGS ARE PRESERVED. This single deletion is what made rebirth a pay
				--    cut: it removed a multiplicative bonus worth up to 16x in exchange for an
				--    additive +0.1x, so a player who prestiged earned up to 93% LESS per mote
				--    afterwards. Islands are earned progression, not a run resource.

				-- 5. INCREMENT the persisted rebirths COUNT (drives the derived Sell multiplier
				--    1 + rebirths*REBIRTH_STEP, computed at read and never stored).
				local newRebirths = rebirths + 1
				d.rebirths = newRebirths

				-- stats.lifetimeStardust is DELIBERATELY NOT touched: a rebirth is a spend/zero,
				-- never an earn. The lifetime aggregate is monotonic across rebirths.

				outRebirths = newRebirths
				outPrismsEarned = prismsEarned
				outPrisms = d.currencies.Prisms
				return d
			end)

			if not updated.ok then
				-- The data write itself failed (NoData / transient). Surface it; the transform returns `d`
				-- whole on every path, so there is no partial change to undo.
				return updated
			end

			-- A server-side rejection decided INSIDE the transform (snapshot-based). No mutation happened,
			-- so Stardust / upgrades / flags / rebirths / Prisms are unchanged and persisted as-is.
			if rejectCode ~= nil then
				return Result.err(rejectCode :: string, rejectMessage)
			end

			-- Emit AFTER a successful rebirth, THROUGH ctx.analytics (NIL-SAFE — a no-op when analytics is
			-- absent, e.g. focused tests). Rebirth is the LOOP-COMPLETION point, so we emit BOTH:
			--   * loop_completed (the integration loop ended in a rebirth that granted Prisms), and
			--   * progression (the permanent rebirth advanced).
			if ctx.analytics ~= nil then
				(ctx.analytics :: any):emit("loop_completed", {
					userId = ctx.player.UserId,
					loop = "rebirth",
					rebirths = outRebirths,
					prismsEarned = outPrismsEarned,
				});
				(ctx.analytics :: any):emit("progression", {
					userId = ctx.player.UserId,
					kind = "rebirth",
					rebirths = outRebirths,
					prismsEarned = outPrismsEarned,
					prisms = outPrisms,
				})
			end

			-- Return the new authoritative state. `multiplier` is the DERIVED read-time value
			-- (1 + rebirths*REBIRTH_STEP) the HUD shows — computed here for the reply, NEVER persisted.
			return Result.ok({
				rebirths = outRebirths,
				prismsEarned = outPrismsEarned,
				prisms = outPrisms,
				-- What this rebirth cost, and what the next one will. The altar used to fire on a
				-- single keypress with no on-screen cost or reward anywhere in the game.
				threshold = outThreshold,
				nextThreshold = thresholdFor(outRebirths),
				multiplier = 1 + outRebirths * REBIRTH_STEP,
			})
		end,
	}
end

-- ----- THE REBIRTH SEAM (ctx.rebirth) -----
-- Pure reads over a snapshot, published so the shop panel and the altar pad can state the price
-- and the reward BEFORE the player commits. The most destructive action in the game used to fire
-- on one keypress with no on-screen cost and no confirmation anywhere.
local RebirthSeam = {}

function RebirthSeam.thresholdFor(_self: any, d: any): number
	local rebirths = if d ~= nil and type(d.rebirths) == "number" then d.rebirths else 0
	return thresholdFor(rebirths)
end

function RebirthSeam.multiplierFor(_self: any, d: any): number
	local rebirths = if d ~= nil and type(d.rebirths) == "number" then d.rebirths else 0
	return 1 + math.max(0, math.floor(rebirths)) * REBIRTH_STEP
end

-- The complete pre-commit picture: what it costs, what you have, what you would get, and the
-- multiplier before and after. Everything the player needs to decide, derived server-side.
function RebirthSeam.previewFor(
	_self: any,
	d: any
): {
	rebirths: number,
	threshold: number,
	stardust: number,
	ready: boolean,
	prismsPreview: number,
	multiplierNow: number,
	multiplierNext: number,
	capped: boolean,
}
	local rebirths =
		math.max(0, math.floor(if d ~= nil and type(d.rebirths) == "number" then d.rebirths else 0))
	local threshold = thresholdFor(rebirths)
	local stardust = 0
	if d ~= nil and type(d.currencies) == "table" then
		stardust = d.currencies.Stardust or 0
	end
	local capped = rebirths >= MAX_REBIRTHS
	return {
		rebirths = rebirths,
		threshold = threshold,
		stardust = stardust,
		ready = (not capped) and stardust >= threshold,
		prismsPreview = prismsFor(stardust, threshold),
		multiplierNow = 1 + rebirths * REBIRTH_STEP,
		multiplierNext = 1 + (rebirths + 1) * REBIRTH_STEP,
		capped = capped,
	}
end

-- Start: register the single Rebirth action on the gateway and publish the read seam. No
-- closed-over mutable feature state — every operand lives in the persisted data layer.
function RebirthService:Start(context: any): ()
	context.net:register(makeRebirthAction())
	context.rebirth = RebirthSeam
end

return RebirthService
