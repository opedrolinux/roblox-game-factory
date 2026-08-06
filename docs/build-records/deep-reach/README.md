# Deep Reach — build record (Workflow A)

The plan half of `build-game` for `specs/deep-reach.md`, kept so the human gate has something to
review and so a re-run is reproducible. These files are inputs and decisions, not code.

| File | What it is |
|---|---|
| `decompose-raw.json` | The **unedited** decompose output: the planner's 9-feature plan, the pure-JS mechanical validation, and the independent skeptic's findings. Kept raw so the amendments below can be checked against what was actually returned. |
| `plan.json` | The **amended** plan — `decompose-raw.json`'s plan with the orchestrator's adjudication of the skeptic's findings applied (A1–A11). This is what the build runs from. |
| `amend.js` | The amendments as executable code, one block per skeptic finding, each naming the finding it answers. Re-runnable: `node docs/build-records/deep-reach/amend.js` (expects the raw decompose at `logs/deep-reach/decompose.json`). |
| `contract.json` | What the serial contract pass was told to write — deltas, infra, retrofits, stubs, and the precision notes. Derived from `plan.json`. |
| `revalidate.js` | Re-runs `decompose.js`'s **own** mechanical rules against the amended plan by slicing them live out of the workflow, so the check cannot drift from the thing it checks. Observed RED under two deliberate mutations before being trusted. |

## The amendments (A1–A11)

The decompose skeptic returned `coverageVerdict: gaps` with 2 overlaps, 4 missing contract deltas,
5 uncovered spec items and 4 dependency issues. Rather than re-planning (which would have discarded
those findings), the orchestrator adjudicated each one. Every amendment is traceable to a finding:

| # | Skeptic finding | Resolution |
|---|---|---|
| A1 | `plot` and `depth` both wrote the dome's world position, and **neither** owned placing it at the persisted tier on a rejoin — so "the dome visibly descends" was right on descend and wrong on every rejoin. | `plot` places the dome at claim time at `ctx.depth:tierYFor(data)` (nil-safe, defaults to tier 1); `depth` only *moves* it on descend. |
| A2 | The auto-collect grant could be written twice — and a second copy is exactly where the lifetime counter and the earn emit get skipped. | `salvage` implements ONE grant path both triggers call; `monetization` only sets the flag and asserts the effect. |
| A3 | A second plot claim returned `Rejected` — but this spine **already** uses `Rejected` as the panic flag (`Net.luau:152`), so "a second claim is refused" would be byte-indistinguishable from "the server is panicked". Verified against the real scaffold. | New Result code `AlreadyClaimed`. |
| A4 | `stats.lifetimeCredits` was marked client-facing, but `PlayerView.stats` is a **narrow fixed record** (`Types.luau:48`). `toView` copies `stats` wholesale so the value arrives — the *type* does not. | The contract pass widens `PlayerView.stats` too. Without this the leaderboard cannot read its own ranking key. |
| A5 | The claim-on-join popup must show the pending offline amount **before** claiming, but that amount is server memory (not persisted, so not in `PlayerView`) and only `offline.claim` existed. There was no read surface at all. | New action `offline.peek`, side-effect free. |
| A6 | `boostExpiresUnix` — a **real-money** field — appeared in neither resurface's survive-list nor its wipe-list, and the two owning features were scheduled in the **same parallel batch**, mutually blind. | Decided: it **survives** a resurface. Written into both slices, and the declared dependency splits them into separate batches. |
| A7 | The restock was reduced to an integer multiplier, but the spec says the rich wreck **spawns**. An integer flipping is the written-never-read shape this game is graded against. | `depth` builds and re-places a real greybox wreck Part on the day rollover. |
| A8 | The pacing targets (~90s to first Credits, 10–15 min to first Depth unlock) compose three numeric tables built in three different batches, and **nothing** checked the composed result. | Assigned to the integration gate as a coarse order-of-magnitude band. The exact numbers are a human tuning judgment at the playtest, and the handoff note must say so. |
| A9 | `offline` and `monetization` under-declared their dependency on `structures`. Batch order happened to cover it, but a feature gate can be authored against a capacity that never moves. | Dependencies corrected. |
| A10 | Six obligations no feature slice can own: the inherited `sample` mint, PlayerRemoving hook ordering, two different definitions of "day", `structures.fetch` enumerating the blob, static vs closure handlers, and seven controllers with no shared HUD root. | All six moved into the contract pass. |
| A11 | The two whole-game success criteria (the end-to-end traversal, the adversarial pass) had **no stated owner** — and an unstated owner is how a criterion goes unrun. | Named: `integration-gate.js` and `adversarial-review.js`. |

## A12 — added mid-build, from a finding the gate raised and a fixer correctly refused

Unlike A1–A11 this one was not found at decompose time. It surfaced during the backlog sweep, and it
is recorded here because a builder implemented the contract **faithfully** and the result was still
wrong.

| # | Finding | Resolution |
|---|---|---|
| A12 | `daily`'s escalating streak ladder is **unreachable**. The slice fixes the claim as opening at 20h and the streak as lapsing at 22h, so continuing a streak needs every claim to land in a 2-hour window that walks backward 2–4h per day. A player with an ordinary daily cadence has a 24h gap, lapses every time, and is pinned at streak 1 / reward 100 forever — six of seven rungs, the cap, and the whole re-entry hook are dead content, and the HUD badge reads 1 for the life of the account. | The lapse bound moves so a 24h cadence *climbs*. `CLAIM_OPENS_AFTER_SECONDS` stays at 20h (the `Err(OnCooldown)` contract and every other daily test lean on it). |

**Why this is an amendment and not a bug fix.** The code is faithful to `slices/daily.md` and to
`specs/deep-reach.md:41` — the contradiction is between two sentences of the spec itself: *"escalating
reward"* and *"20-22h claim window"*. Both cannot hold. The fixer that found it declined to touch the
constant and said so plainly rather than manufacturing a proof, which is the correct behaviour: a
falsify-first fixer that moves a bound the slice fixes is amending the contract unilaterally, and the
regression test it would write would assert a contract that does not exist yet.

**Why this reading.** The feature's stated *purpose* is escalation, and it is named as a success
criterion (`specs/deep-reach.md:63`, "streak counter"). Read as "the claim becomes available after
about a day", the 20–22h phrasing is a cooldown; read as "you must claim inside a 2-hour slot", it
makes the feature's own headline unachievable. The first reading costs a constant; the second costs
the feature. **This is reversible in one constant** — if the punishing window was the intent, revert
the bound and instead drop the word "escalating" from the spec and surface `lapsesAtUnix` (already
computed) on the badge so the player can see the streak is about to die.

The suite pins the *current* behaviour deliberately (`daily.spec.luau:301` asserts the 22h constant,
and a case named "a REAL 24h cadence lapses every day" loops five claims asserting streak 1 each
time, commented "any move of the lapse bound past 24h goes red here"). That case is the falsification
target: it must be seen RED before, and rewritten to assert the ladder *climbs*, after.

## What the skeptic verified as already correct

Worth recording, because it is the part that needed no intervention: seam-vs-migration was right on
every one of the 9 features (no needless migration, no missing one); the migration chain v1→v7 is
contiguous; all four proposed new Result codes are genuinely absent from this scaffold; the
`earnPaths` list correctly **excludes** the accrual tick, the Pearls mint, the restock multiplier and
both spend paths from the lifetime counter; and the `leaderboard` slice correctly resists a false
dependency on the earn paths.
