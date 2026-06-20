--!strict
-- games/collect-sim/src/server/services/rebirth/RebirthService.luau   [rebirth — prestige loop completion]
-- Feature: rebirth/prestige. The player FULLY PRESTIGE-RESETS their run for permanent power. A rebirth
-- requires a SERVER-OWNED Stardust threshold; on success it ATOMICALLY, in ONE ctx.data:update
-- transform on the lock-held re-read snapshot:
--   1. zeroes currencies.Stardust (the prestige spend — NOT an earn, so stats.lifetimeStardust is
--      NEVER touched),
--   2. RESETS upgrades to {} (clears every bought shop level),
--   3. CLEARS the island unlock flags (every flags['island.*']; the starting island carries no flag,
--      so it stays unlocked — the IslandsService convention),
--   4. increments the persisted top-level `rebirths` COUNT by 1,
--   5. grants currencies.Prisms += a SERVER-DERIVED amount (the client supplies NO number).
-- PRESERVED across the rebirth: the rebirths count (it increments), currencies.Prisms (accumulates
-- over rebirths), stats.lifetimeStardust (the lifetime earn aggregate — a rebirth is a spend/zero,
-- never an earn), and the gamepass flags (flags['gamepass.*'] — purchases persist).
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
-- Lune-clean: relative requires only; no Roblox global touched. The action is plain data + pure-ish
-- functions over injected ctx, so a spec can drive it through Mocks.net -> Net.dispatch.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

-- ----- SERVER-OWNED CONSTANTS (authoritative; the client never sees or supplies any of this) -----
-- The minimum Stardust a player must hold to rebirth. Below this the action returns Insufficient.
local REBIRTH_THRESHOLD = 1000

-- The Prisms granted per rebirth: a flat base plus a small bonus that scales with how far past the
-- threshold the player pushed (rewarding a bigger run). Server-derived; integer. Trust ZERO client
-- numbers — this is computed from the lock-held Stardust snapshot only.
local PRISM_BASE = 1
local PRISM_PER_THRESHOLD = 1 -- one extra Prism per full REBIRTH_THRESHOLD of Stardust held

-- Mirror of CollectionService's REBIRTH_STEP, kept ONLY to document the derived multiplier
-- (1 + rebirths*REBIRTH_STEP). The multiplier is applied at Sell, NOT here, and is NEVER persisted.
-- Sell owns the authoritative value; this is not read by any write path.
local REBIRTH_STEP = 0.1

-- The flag-key prefixes. Island unlock flags ALL share 'island.' (IslandsService convention) and are
-- CLEARED by a rebirth. Gamepass flags share 'gamepass.' and are PRESERVED (purchases persist). We
-- match on the prefix so a new island id added to the catalog is cleared automatically.
local ISLAND_FLAG_PREFIX = "island."

-- Server-derived Prisms grant from the Stardust held at the moment of rebirth. PURE over a number
-- (read from the lock-held snapshot): base + floor(stardust / threshold) * perThreshold. With exactly
-- the threshold this is PRISM_BASE + PRISM_PER_THRESHOLD; it rises as the run goes deeper. Integer.
local function prismsFor(stardust: number): number
	local bonus = math.floor(stardust / REBIRTH_THRESHOLD) * PRISM_PER_THRESHOLD
	return PRISM_BASE + bonus
end

local RebirthService = { name = "RebirthService" }

-- Build the Rebirth action. No closed-over feature state is needed: every operand is persisted
-- PlayerData, mutated atomically inside the single update transform on the lock-held snapshot.
local function makeRebirthAction(): Net.Action<
	{},
	{ rebirths: number, prismsEarned: number, prisms: number, multiplier: number }
>
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
		): Result.Result<{ rebirths: number, prismsEarned: number, prisms: number, multiplier: number }>
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

			local updated = ctx.data:update(ctx.player, function(d)
				-- Re-read the CURRENT Stardust from the snapshot the lock handed us.
				local stardust = (d.currencies and d.currencies.Stardust) or 0
				if stardust < REBIRTH_THRESHOLD then
					-- Below the server-owned threshold: NO reset, NO grant. (Reuse Insufficient — the
					-- player cannot afford the rebirth.) This is ALSO the spam-duplicate guard: a second
					-- rebirth re-reads the just-zeroed Stardust and lands here.
					rejectCode = Result.Codes.Insufficient
					rejectMessage = "below rebirth Stardust threshold"
					return d
				end

				-- Derive the Prisms grant from the lock-held Stardust BEFORE zeroing it (server-side only).
				local prismsEarned = prismsFor(stardust)

				-- 1. ZERO the prestige currency (a spend, NOT an earn -> lifetimeStardust untouched below).
				d.currencies.Stardust = 0

				-- 5. GRANT Prisms (accumulates across rebirths). Prisms is a persisted currency-map key
				--    (seeded 0 by Migrations.default); guard the map defensively for a minimal test fake.
				if d.currencies == nil then
					d.currencies = {}
				end
				d.currencies.Prisms = (d.currencies.Prisms or 0) + prismsEarned

				-- 2. RESET upgrades to an EMPTY table (clears every bought shop level).
				d.upgrades = {}

				-- 3. CLEAR the island unlock flags (every flags['island.*']). PRESERVE gamepass.* (and any
				--    other non-island flag): purchases persist. The starting island carries no flag, so it
				--    stays unlocked. Match on the prefix so a future island id is cleared automatically.
				if d.flags ~= nil then
					for key in d.flags do
						if string.sub(key, 1, #ISLAND_FLAG_PREFIX) == ISLAND_FLAG_PREFIX then
							d.flags[key] = nil
						end
					end
				end

				-- 4. INCREMENT the persisted rebirths COUNT by 1 (preserved + bumped; drives the derived
				--    Sell multiplier 1 + rebirths*REBIRTH_STEP, which is computed at read, never stored).
				local newRebirths = (d.rebirths or 0) + 1
				d.rebirths = newRebirths

				-- stats.lifetimeStardust is DELIBERATELY NOT touched: a rebirth is a spend/zero, never an
				-- earn. The lifetime aggregate is monotonic across rebirths.

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
				multiplier = 1 + outRebirths * REBIRTH_STEP,
			})
		end,
	}
end

-- Start: register the single Rebirth action on the gateway. No closed-over mutable feature state —
-- every operand lives in the persisted data layer and is mutated atomically inside the transform.
function RebirthService:Start(context: any): ()
	context.net:register(makeRebirthAction())
end

return RebirthService
