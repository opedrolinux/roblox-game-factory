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

## What the skeptic verified as already correct

Worth recording, because it is the part that needed no intervention: seam-vs-migration was right on
every one of the 9 features (no needless migration, no missing one); the migration chain v1→v7 is
contiguous; all four proposed new Result codes are genuinely absent from this scaffold; the
`earnPaths` list correctly **excludes** the accrual tick, the Pearls mint, the restock multiplier and
both spend paths from the lifetime counter; and the `leaderboard` slice correctly resists a false
dependency on the earn paths.
