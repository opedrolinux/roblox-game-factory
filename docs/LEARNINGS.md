# LEARNINGS.md — the factory's hard-won failure modes (read before you build)

The self-improving flywheel (`LOOP-ENGINEERING.md` §4 upgrade 6, `FACTORY.md` §2): every real bug the
factory's gates have caught is distilled here as an **up-front checklist item**, so the next builder
sees it as a guardrail instead of re-discovering it. These are not hypotheticals — each one **shipped or
nearly shipped** and was caught by a specific gate (the independent test gate, the integration gate, the
adversarial review, the require gate, or a human/Studio pass). Read this before writing a feature; the
independent gate that grades your code is *looking for these*.

Format: **the trap** · *why it's dangerous* · the shape to watch for · the fix pattern · who caught it.

---

## 0. THE ROOT PATTERN — written here, read nowhere

> **A value the player pays for is written to the save file, and the rule that governs play is a
> hardcoded constant sitting right next to it, reading nothing.**

*Why it's dangerous:* it is **the single largest failure mode this factory has ever had** — one pattern
behind **26 of 66 confirmed defects** in one game — and it is **invisible to a passing test suite by
construction.** A human playtested `collect-sim` and said *"lots and lots of things are not working."*
He was right. At that moment: **361 green Tier-1 tests** and an automated playtest lane reporting **all
green**.

**The shape to watch for** — this is what it looked like in the real tree:

```
CAPACITY = 50      sat beside   d.upgrades.backpack
ABSORB_RADIUS = 6  sat beside   d.upgrades.magnet
TICK = 0.06        sat beside   d.upgrades["collect-speed"]
"WalkSpeed"        was absent from src/ entirely, while a walk-speed upgrade was on sale
Prisms             granted by rebirth, persisted, shown in the HUD, decremented by nothing
boostExpiresUnix / lastClaimUnix / resetsAtUnix / dayNumber   replicated, zero client readers
```

Maxing all four shop upgrades cost **9,625 Stardust and changed nothing.** Rebirth was a **pay cut** —
it cleared the island flags, so income fell up to 93%, and the Prisms it paid out bought nothing.

**The transferable half — the tests had the same shape.** Every test asserted the **WRITE** ("the level
persisted", "the balance fell by the cost") and none asserted the **READ**. Worse, `Mocks.net` never
projected `islands`/`restock`/`upgrades` into the `ActionContext`, so every seam was tested in
**isolation** while the **composition** — a handler consuming a seam through `ctx` — was exercised by
nothing at all.

**The fix pattern — ASSERT THE DELTA.** Capture state `S`, perform action `A`, capture `S′`, assert
`S′ − S` is the delta the spec promised. And its four corollaries, each of which cost the factory
something:

1. **A return code is not a delta.** `Ok` means the handler replied. The T2.5 lane accepted **any typed
   `Err`** as a pass, so *"island 2 refuses to unlock"* was indistinguishable from working.
2. **A registered action is not a delta.** "7 pad dispatches" was counted as 7 proofs; it was one empty
   `Sell` plus six `Err(Insufficient)` refusals against a zero balance — the earn formula was never
   entered once.
3. **A module that requires is not a delta.** Resolution is not execution.
4. **"I could not check this" must never serialize as green.** It needs a **third verdict state**
   (`green`/`parked`/`red`), *not* a second reporting channel. The assertion that actually found the
   backpack bug printed `capacityBefore: 50, capacityAfter: 50` — into a `knownRed` list emitted
   **beside** the verdict. The run published `"ok": true`. *"I found something broken"* and *"everything
   is fine"* were both true of the same run.

**Who catches it now:** the **T1 static reachability gate** (`gate-reachability.luau`, gauntlet stage 5)
offline in about a second, and the **T2.5** playtest lane by measured before/after. **Author it right;
do not lean on the gates** — three of `gate-reachability`'s eight rules have measured blind spots and
nine of eleven adversarial attacks on the T2.5 harness came back green
(`docs/VERIFICATION-LADDER.md` §6.5, §7.6). *(Found by an 81-agent audit after the human playtest; 70
findings raised, 66 confirmed by verifiers whose default was to refute.)*

Full method: **`docs/AI-PLAYTEST-METHOD.md`.**

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
  gate's world matching the real bootstrap. The **sample-removal finalization gate** (`gate-sample.luau`)
  now fails a game that still carries the sample alongside real features. *(Adversarial review — the
  per-feature gates couldn't see it.)*
- **Tautological tests pass a broken impl.** *Coverage theatre.* A "concurrency" test on a PURE READER
  (e.g. a leaderboard fetch) has no FIFO-lock race to exercise — it passes vacuously. Write falsifiable
  assertions: prove the test RED on the unfixed code before trusting it GREEN. *(Anti-tautology critic
  replaced 2 tautological leaderboard concurrency tests.)*
- **A recorded higher-tier FAILURE must block, not be swallowed.** When the engine-smoke (T2) was actually
  run and FAILED, the handoff must refuse — even if the automated lane is otherwise "down". A known
  non-booting game is never relabeled "ready". *(Found dogfooding the verification-ladder handoff guard.)*
- **A vacuous gate is worse than no gate.** *A check that quietly stops finding subjects reports green
  forever.* Real instances, all shipped: `spawn-safety` raycast downward and hit **the spawn pad itself**
  — it would have passed with every island in the game deleted. `traversal` computed a `worstDrop` and
  compared it to nothing. And the T2 boot smoke omitted `WorldService` from its hand-mirrored bootstrap
  list, so for **weeks** every world assertion ran against a Workspace containing **zero parts** and
  passed. **Fix:** every gate emits its **subject count numerically**, zero subjects on an applicable
  rule is a **FAIL**, and a *drop* in subject count against a committed baseline is a FAIL too (16 seams
  → 2 is the same lie as zero). Before trusting a new gate, **aim it at nothing** — a missing directory,
  an empty tree — and confirm it goes red.
- **Numeric thresholds fail by being relaxed.** *`checked >= 8` becomes `> 0`, which is vacuity wearing
  a counter.* A threshold tuned to one game's current *size* is a near-miss away from being loosened by
  the next agent. **Fix:** presence checks with no numbers, plus a monotonic baseline. `gate-reachability`
  ships with **zero** magic constants for exactly this reason.
- **A waiver added in the same turn as the RED defeats the gate.** *An agent trips a check and exempts
  itself.* **Fix (all three, together):** waivers are dated and expire (≤ 30 days — a date in a *comment*
  expires nothing); a waiver that **matched nothing this run is a FAIL** (that is how allowlists rot into
  blanket suppression); and the ingest refuses green if `git status --porcelain` on the allowlist file is
  dirty. Also key waivers `file::Table.method` — keying by **bare name** meant exempting `tuningFor`
  exempted *every* `tuningFor` in the game.
- **A harness that fabricates its subjects hides the bug that has the same shape as the fabrication.**
  `type(player) == "table"` emptied the leaderboard in every live server, forever, and was green in every
  test — **because the harness fabricates players as plain tables. The bug and the mock that hid it were
  the same shape.** Watch for any assertion whose truth depends on the mock's representation.
- **A false RED costs what a false green costs.** *It trains people to ignore reds exactly as surely as
  a false green trains them to trust greens.* A pacing rung measured 30 successes and 290 rate-shed of
  320 dispatches — **exactly the burst size**, because the edit-mode server clock is frozen and never
  refills the bucket. **That number described the harness, not the game.** It was deleted and replaced
  with a mechanism: a phase declaring a dependency on a lane limit measured as *absent* is **refused and
  recorded unmeasurable**, never run and never scored.
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
- **A controller that calls the server from `Start()` races `loadSession`'s yield.** *Offline earnings
  are lost PERMANENTLY, because autosave then erases the away window.* Same family: `CharacterAdded`
  fires **before** `loadSession` finishes, so a player who owned island 2 was assigned island 0's
  collision group and collided with every barrier. **Fix:** a bounded join retry that keeps the
  restrictive state (walls UP, access denied) while the session is *unknown* — never the permissive one.
  **No offline rung can see this**; Lune cannot even `require` a controller (`LocalPlayer` at module
  scope). It took driving the real `RemoteFunction` from the **client context** of a live Studio session.
  *(T2.7; fixed `e984d84`, verified RED→GREEN in-engine, 54 Stardust recovered.)*
- **Three presentation defects were invisible in every log and obvious in a picture.** A `Sky` with blank
  skybox textures renders **no stars** (`StarCount` only draws over Roblox's *own* sky, and a blank `Sky`
  replaces it), while an `Atmosphere` paints a lit haze *below* the horizon — washing the frame flat blue
  at density `0.36` and still filling three quarters of it at `0.04`. **The correct config was a deletion,
  and the version with more code in it looked worse.** Separately: `AlwaysOnTop` billboards at 110 studs
  drew labels from three islands away over the ones at the player's feet; and the world replicated *after*
  the mote controller started, giving `22 total, 0 visible, 22 parked` — a number no log flagged.
  **Fix pattern:** screenshots are a **verification instrument**, with the assertion written down *before*
  the capture and a per-image verdict of `pass`/`fail`/**`cannot-tell`** — and `cannot-tell` is not a pass.
- **A write that reports success and does nothing.** `Workspace.FallenPartsDestroyHeight` silently ignores
  assignment from a Script (stays `-500`). Generalized rule, needing no game knowledge: **after any
  property write a probe performs, READ IT BACK and assert it took.** And **never freeze, anchor or pause
  the thing you are about to measure** — anchoring a character to hold it still **stops position
  replication**, so the server keeps seeing the old spot and every position assertion silently passes.

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
`docs/VERIFICATION-LADDER.md`; and **how an AI verifies a game like a human — what each rung is blind to,
and why — in `docs/AI-PLAYTEST-METHOD.md`.***
