# LEARNINGS.md — the factory's hard-won failure modes (read before you build)

The self-improving flywheel (`LOOP-ENGINEERING.md` §4 upgrade 6, `FACTORY.md` §2): every real bug the
factory's gates have caught is distilled here as an **up-front checklist item**, so the next builder
sees it as a guardrail instead of re-discovering it. These are not hypotheticals — each one **shipped or
nearly shipped** and was caught by a specific gate (the independent test gate, the integration gate, the
adversarial review, the require gate, or a human/Studio pass). Read this before writing a feature; the
independent gate that grades your code is *looking for these*.

Format: **the trap** · *why it's dangerous* · the shape to watch for · the fix pattern · who caught it.

---

## 1. Economy / concurrency (the most-caught class)

- **Capacity-cap bypass on a failure-restore path.** *A player sells over the cap → free money.* When a
  mutation captures a balance, yields (a `ctx.data:update`), and **restores** on failure, the restore can
  exceed the invariant: `backpacks[uid] = captured + count` is **unclamped**, so if auto-collects refilled
  during the yield, the restored value exceeds `CAPACITY`. **Fix:** clamp every restore to its invariant
  (`math.min(CAPACITY, …)`). *(Collection core — the economy red-team caught it; the builder + 2 other
  critics missed it. Latent on MockStore, reachable on a real Store whose `update` can fail.)*
- **Read-check-write across a yield without the lock.** *Double-spend / currency dupe under interleaved or
  spam-duplicated requests.* The defense is to keep the ENTIRE read-check-write inside ONE lock-held
  `ctx.data:update` transform — never capture a balance, yield, then write. Where both operands persist,
  the whole decision lives in one transform (shop's double-spend, daily's double-claim are defended this
  way). **Always** write the `economy_race` test: interleave/spam-duplicate the action against the ONE
  shared balance and assert no double-spend / no Prism dupe.
- **A multiplier seam read OUTSIDE the transform.** *The bonus silently never applies.* Calling
  `multiplierFor(nil)` (or reading a seam from a stale snapshot) outside the lock-held `d` leaves
  island/restock/boost multipliers dormant. **Fix:** read every seam from the lock-held `d` INSIDE the
  transform, nil-safe (default 1 so the spine behaves identically when the seam is absent). *(Sell-retrofit
  amendment; integration gate caught the dormant multipliers.)*

## 2. Persistence / server-time (silent data loss)

- **Re-stamping the offline base on JOIN.** *Offline earnings never pay (every away-window collapses to
  0).* `loadSession` stamping `timestamps.lastSeenUnix = now` on join overwrites the away-window start.
  The previous-release value IS the offline base — write it on save/release, never on join. *(Integration
  gate; invisible to per-feature tests that pin a single clock.)*
- **Non-monotonic time advance.** *A clock that can go backwards corrupts streaks/offline.* Guard
  monotonicity: `lastSeenUnix = math.max(lastSeenUnix, now)`. *(The N=2 auto-fix loop's first real fire.)*
- **All time from the server clock, never the client or `os.time()` sprinkled around.** Offline, daily
  streak, restock, boost expiry all read `ctx.clock` (injectable for tests). A client-supplied time is a
  forgery surface. *(Standing rule; adversarial review checks offline-time forgery.)*
- **Class-B migration that infinite-loops.** *A version bump with an unstamped step hangs `migrate()` /
  loses data.* Any new persisted field needs: a `steps[i]` that **stamps the new `schemaVersion`** (an
  unstamped step loops forever), a `default()` seed, AND a **self-verifying v(i)→v(i+1) round-trip test**
  written in the contract pass — because no existing version-agnostic spec runs a new step, so a broken
  one ships latent. *(Daily streak, the first class-B migration.)*
- **In-memory store loses the receipt ledger on restart.** *A real-money receipt is re-granted on
  redelivery.* Idempotency requires the processed-receipt ledger to PERSIST (and the grant + the ledger
  write to be atomic in one transform). The runtime `MockStore` is in-memory — this is a real B2 gap until
  `SessionStore` is built. *(Tier-2-only finding.)*

## 3. Monetization (real money — idempotency is non-negotiable)

- **`ProcessReceipt` must be idempotent.** Record processed receipt IDs in the data layer and return
  `NotProcessedYet` on any failure, so a purchase is **never** double-granted or lost. The grant and the
  ledger commit happen in ONE transform; a replay arms no second effect (`math.max` never shortens an
  expiry). *(Standing rule; boost-persistence change stamps the expiry inside the receipt transform.)*
- **Gamepass flags set server-side ONLY.** Ownership is GRANTED via `UserOwnsGamePassAsync` on join +
  `PromptGamePassPurchaseFinished` on purchase into persisted `flags['gamepass.*']` — never from a client
  action. The effect-application reads the persisted flag; nothing client-supplied flips it. *(Adversarial
  review checks the server-authority spoof surface.)*

## 4. Boot / requires (Lune-green ≠ Roblox-runs)

- **A cross-service `require` with a bare relative string.** *Passes every Lune check, then throws at the
  FIRST require in Roblox — the server never boots.* `src/shared`/`src/server`/`src/client` map to
  DIFFERENT DataModel services with no common `../` ancestor, so `require("../../shared/Net")` resolves on
  the filesystem (Lune) but not the instance tree (Roblox). **Fix:** the dual-runtime **D1 shim** for any
  cross-mount require (`if script == nil then <string> else require((Shared :: any).Net) end`); a bare
  relative string is permitted ONLY for same-mount siblings. The **T0.5 require gate** (`gate-require.luau`)
  now catches this class statically with no engine — but author it right, don't lean on the gate. See
  `docs/VERIFICATION-LADDER.md`. *(Shipped a non-booting game past 313 green tests + every gate; caught
  only at a human Studio pass.)*
- **`-- Lune-clean` / `[D1 shim]` comments are risk-markers, not badges.** They mark a file whose Roblox
  branch Lune never exercises — a reason to VERIFY the instance branch (require gate / in-engine smoke),
  never to trust it.

## 5. Verification process (the gate itself can lie)

- **Trusting an exit code over a real result.** *A green signal that isn't.* A bare main-thread yield
  against a yielding store makes Lune **exit 0 mid-run**, before the test summary prints — masking every
  failure after it. The gauntlet now requires a real `{"passed":N,"failed":0,"total":>0}` summary, not
  just exit 0. **Lesson:** a "couldn't check" must read as FAIL, never as pass (fail-closed). *(Found when
  the gauntlet reported ok while a test was RED.)*
- **Gate ↔ bootstrap parity divergence.** *The gate is green while the live registry ships a bug.* A
  per-feature gate harness that omits a service (e.g. the deletable `sample`) can pass while the real
  `init.server` still registers it. The deletable `sample` scaffold shipped a **client-callable mint**
  (`SampleAction` credited a client `{amount}` straight to Stardust) because the pipeline never removed it
  after real features existed. **Fix:** remove the sample scaffold once real features replace it; keep the
  gate's world matching the real bootstrap. *(Adversarial review — the per-feature gates couldn't see it.)*
- **Tautological tests pass a broken impl.** *Coverage theatre.* A "concurrency" test on a PURE READER
  (e.g. a leaderboard fetch) has no FIFO-lock race to exercise — it passes vacuously. Write falsifiable
  assertions: prove the test RED on the unfixed code before trusting it GREEN. *(Anti-tautology critic
  replaced 2 tautological leaderboard concurrency tests.)*
- **A recorded higher-tier FAILURE must block, not be swallowed.** When the engine-smoke (T2) was actually
  run and FAILED, the handoff must refuse — even if the automated lane is otherwise "down". A known
  non-booting game is never relabeled "ready". *(Found dogfooding the verification-ladder handoff guard.)*
- **An "Unknown" is never a "pass".** In any grader/judge, an undetermined verdict (criterion or quality)
  is surfaced as needs-resolution, NOT counted toward done; and a DETERMINISTIC signal must be parsed in
  code, never read via a model's interpretation. *(Caught self-testing the `/goal` grader's compose block:
  a quality verdict of `unknown` with a high score was laundering to `done`.)*

## 6. Client / presentation (server stays authoritative)

- **Never smuggle trust into a payload.** The client sends only the documented action payloads — never a
  cost, level, balance, mote id/position, multiplier, or time. `Collect` is "add one to the caller's
  backpack, capacity-capped server-side"; the mote is cosmetic. Sending mote identity invents trust the
  server refuses and opens a spoof surface. *(Presentation-layer constraint; review confirmed zero
  authority leaks.)*
- **`ProximityPrompt.Triggered` fires on BOTH server and client.** Connect each prompt in exactly ONE
  place (the client controller that owns the UI update) — never also server-side — or the action fires
  twice. The server stays authoritative because the action is validated regardless of who triggered it.
- **A push only fires where you wrote the push.** After a server write, push the client-safe view from the
  write path (`update()`), not only on join — else the HUD goes stale after rebirth/unlock/offline. *(The
  presentation review caught the missing post-write `"data"` push.)*

## 7. Toolchain gotchas (cost real time)

- **CRLF vs `stylua --check`.** `core.autocrlf=true` + no `.gitattributes` → `git checkout` rewrites
  tracked `.luau` to CRLF and breaks `stylua --check` (Unix LF) even though `git diff` shows nothing. Fix:
  `.gitattributes` with `* text=auto eol=lf` (committed). Debugging note: `grep -c $'\r'` is a BROKEN CRLF
  test (`$'\r'` collapses to the letter `r`); use `stylua --check` or `od -c`.
- **selene `std="roblox"` does NOT ban `wait`/`spawn`/`delay`.** A `roblox-fenced` overlay does — use
  `task.*` always. **rojo 7.6.1:** omit the `Packages` node. **stylua:** `syntax="Luau"` for generics.

---

*Add to this file whenever a gate catches a real bug class — that is the flywheel. Per-game specifics live
in the game's own `CLAUDE.md`; design rationale in `docs/CORE-DESIGN.md`; the verification tiers in
`docs/VERIFICATION-LADDER.md`.*
