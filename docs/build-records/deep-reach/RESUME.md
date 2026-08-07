# Deep Reach — resume here

State as of the end of the first build session. Everything needed to continue is committed; nothing
lives only in a chat log.

**Branch:** `staging/deep-reach` (not pushed — `git push` is the human's).
**Where we are:** ALL 9 FEATURES BUILT AND MERGED. Gauntlet 6/6 green, 922/922 lune, reachability
0 FAIL. `tier-status` = `verified-local-T1`. **Read `HANDOFF.md` next** — it leads with what is not
done. Two things are OWED before the human gate, both cut short by the account's monthly spend
limit: **re-run the adversarial review** (its "No open exploit" criterion is unproven, not passed)
and **run `grade.js`**. See `docs/USAGE-BUDGET.md` for the spend problem and the per-phase-budget
discussion it opened.

## Done

| Step | Result |
|---|---|
| scaffold (`new-game`) | `games/deep-reach`, gauntlet-green 105/105 · commit `dd3c4bb` |
| workflows made game-agnostic | 75 collect-sim references across 9 scripts · commit `29331ae` |
| decompose + skeptic | 9 features, 6 batches · `decompose-raw.json` |
| orchestrator adjudication | 11 amendments A1–A11 · `amend.js`, `plan.json` |
| contract pass | schema v1→v7, infra, 9 stubs · commit `723534c` |
| **HUMAN GATE** | approved: commit as-produced, then fix findings as a separate commit |
| verifier findings fixed | all 4, each with a recorded RED · commit `439985d` · **194/194 lune** |
| batch 0 — plot, daily, leaderboard | `dea420b`, `a853836` · dome leak + unguarded rollback + 17 false-green tests fixed |
| batch 1 — salvage | `c0343ba` · its mint was fixed at the shared `EconomyService` seam, not per-caller |
| batch 2 — structures | `85ebf38` · `hull` was a live Credits sink with no reader; its own audit could not see it |
| batch 3 — depth, offline | `dc57664` · **714/714 lune** · 4 open gate findings, see below |
| gate-aggregation defect + backlog | `224e11c` · 26 dropped findings recovered into `backlog/*.md` |

**Gauntlet right now:** ALL SIX STAGES GREEN, `ok: true` — stylua · selene · rojo · require ·
reachability (**0 FAIL**) · lune (**922/922**). Reachability was 28 at the contract pass; each merged
feature cleared exactly the subjects it owned, and A13 removed the last 3, which belonged to no
slice (fields replicated to every client that no client read). **That count, not the test count, was
the real progress signal throughout.**

## Next: fan-out, batch by batch

Batches, in order. A later batch depends on an earlier one's REAL implementation, so the orchestrator
adjudicates and union-merges between them — never all at once.

```
0: plot, daily, leaderboard   MERGED
1: salvage                    MERGED
2: structures                 MERGED
3: depth, offline             MERGED
4: monetization               MERGED
5: resurface                  MERGED   <- fan-out COMPLETE
```

Fan-out is done. `allowGauntletRedStages` is no longer needed — reachability is green, so a builder
that reports `gauntletOk: false` now means something real. What remains is in `HANDOFF.md`: re-run
`adversarial-review.js` (it was cut short by the spend limit, and its "No open exploit" criterion is
UNPROVEN), then `grade.js`, then the engine rungs T2 → T2.5 → T2.7.

Per batch: `fanout.js` (nests `build-features`: independent builder → independent gate of author + 3
adversarial critics → bounded N=2 falsify-first auto-fix) → orchestrator adjudicates → `merge.luau`
classify → union-merge → re-gauntlet.

**You MUST pass `allowGauntletRedStages: ["reachability"]` + a `gauntletRedReason` to `fanout.js`,
every batch, until the last feature lands.** Without it a builder that is green on stylua / selene /
rojo / require / lune is still recorded `build-failed` — because reachability is red by construction
— and `build-failed` **skips the independent test gate**. That is the most expensive failure in this
pipeline: nine ungated services, each reported as a failed build. Fixed in `39222cd`; the flag is the
orchestrator's to set because only the orchestrator can run the gauntlet and see WHICH stage is red.
Write the reason from a gauntlet run you actually did — it is quoted into the agents' prompts.

`mode: "gate-only"` gates whatever is already on disk, skipping the builder. Use it when a control-flow
fix would otherwise force a verified build to be rebuilt (trading a checked implementation for an
unchecked one), not as a way to skip building.

Then: `integration-gate.js` → `adversarial-review.js` → finalization (`gate-sample.luau`,
`tier-status.luau`, `grade.js`) → portfolio note → the human FFs `main` and pushes.

**Feature slices live in `plan.json`** (`features[].specSlice`), already carrying the A1–A11
amendments inline. Each slice is the ONLY context its builder and gate receive, so pass it verbatim.

## Things that will bite, learned the hard way this session

1. **`reachability` cannot be green until fan-out lands.** 18 of its failures are `PlayerView` fields
   no controller reads yet. This is honest, not a defect. Do NOT waive it, do NOT game the maturity
   probe, do NOT write a read that exists only to quiet a rule. It goes green when the game is
   actually assembled — treat that as the real progress signal, not a test count.
2. **Workflow output schemas must stay terse.** An over-large one is rejected upstream
   (`output schema too large to classify safely`), the agent never runs, and the workflow returns the
   same shape a clean no-op returns. Put the semantics in the prompt; the prompt has no size limit.
3. **A workflow script has no filesystem.** Passing `contractFile` without `outline` used to make the
   pass write nothing and return green; it now throws. Agents CAN read files — the script cannot.
4. **Resume busts the cache on any prompt change.** `resumeFromRunId` replays by `(prompt, opts)`
   hash, so editing a shared prompt constant re-runs the phases that already succeeded. Append notes
   to the LATER phase prompts only.
5. **`run-in-roblox` on `PATH` is the wrong binary** — an aftman shim that errors against this
   rokit-pinned repo. Use `~/.rokit/bin/run-in-roblox`.
6. **The Studio MCP bridge needs a `/mcp` reconnect**, not just Studio being open. MCP enumerates a
   server's tools at connection time; enabling the bridge afterwards does not backfill a live session.
   Verified working — see `games/deep-reach/tests/engine-pass/ENGINE-FACTS.md`.
7. **Never take a `build-failed` at face value — run the gauntlet yourself.** The first plot run came
   back `build-failed` with a build that was green on every stage it could affect. An agent's
   `gauntletOk` is one boolean over six stages; it cannot say WHICH failed, and the workflow script
   has no filesystem to go look. Verify before adjudicating: the whole maker≠checker structure is
   pointless if the orchestrator forwards an agent's self-report instead of checking it.
8. **The feature slices are FILES, not prompt text** — `docs/build-records/deep-reach/slices/*.md`,
   generated from `plan.json` (all 9 verified to round-trip verbatim). Pass the path plus the feature
   headline as `specSlice`; do not retype 4KB of contract into a workflow call and hope it matches.
   Regenerate rather than hand-edit if the plan changes.
9. **`realBugs: 0` was a lie for four batches.** `build-features.js` aggregated real bugs from the
   bug-hunter critic ONLY, though all three critics carry `realBugsFound`. Coverage's and quality's
   findings were dropped, so features with genuine defects landed on `needs-review` (a park) instead
   of `bug-found` (the auto-fix loop) — including two defects each found INDEPENDENTLY by two critics.
   Fixed in `dc57664`; the recovered backlog is `backlog/*.md`, swept by `backlog-sweep.js`. The
   general rule: **every field an agent can populate must have a path into the verdict.** Check the
   aggregation expression against the schema, not just the verdict string — and read one full gate
   transcript per batch, because the summary is produced by the same code that might be dropping things.
10. **A critic that DIES reads as a critic that found gaps.** depth's bug-hunter failed mid-stream;
   `anyCriticGap` folded the `null` in with the real "gaps" verdicts, so a gate resting on 2 of 3
   critics was indistinguishable from a complete one. `criticsMissing` now names it. Re-run the
   missing critic before adjudicating — "found nothing" and "never looked" are not the same evidence.

## Decisions — the human delegated these; they are DECIDED, do not re-open

**D1 — `gate-reachability`'s maturity probe stays as it is. Do NOT add a third state.**
The tempting fix is a "contract pass done, features not built" state that reports not-applicable.
Rejected: that state would mask a genuine written-never-read defect *introduced by the contract pass
itself*, which is exactly the class the gate exists to catch, and it would do so at the moment the
schema is being written — the highest-blast-radius edit in the whole build. The scoped
`allowGauntletRedAt` override is the permanent answer for this boundary instead: it is explicit,
logged at the point of use, owned by the orchestrator (who can actually run the gauntlet and see
which stages are red — the script cannot), and it defaults to off. The final gate is unchanged and
still bites: **handoff requires a genuinely green gauntlet**, so fan-out has to earn it. A red
reachability during Workflow A is a status, not a waiver.

**D2 — pacing (A8) stays a coarse order-of-magnitude band, and the handoff note says so.**
No tuned assertion. Time-to-first-Credits and time-to-afford-Depth-2 get a generous band at the
integration gate purely to catch a composition that is 10x off — three numeric tables built in three
batches multiplying into something absurd. That is the only pacing failure an offline rung can
honestly detect. The handoff note must state plainly that pacing is **unverified by machine** and is
a human judgment at the playtest; it must not imply any rung tuned it. Do not let a green band read
as "the pacing is right".

## Open questions still for the human

- (RESOLVED as D1 above — kept for the reasoning) **`gate-reachability`'s maturity probe has two states**, sample-only and mature, and flips on ANY
  non-`sample` directory under `src/server/services/`. A contract pass MUST create those, so every
  game will sit in an unrepresented third state — "contract pass done, features not built" — at this
  exact boundary. Worked around this run with a scoped, logged, orchestrator-owned override
  (`allowGauntletRedAt`). The probe itself still wants a real fix, and that is a factory-wide change
  with its own corpus tests.
- (RESOLVED as D2 above — kept for the reasoning) **Pacing (amendment A8)** — ~90s to first Credits, 10–15 min to first Depth unlock — is assigned to
  the integration gate as a coarse order-of-magnitude band only. The real numbers are a human tuning
  judgment at the playtest. The handoff note must say so rather than implying an offline rung tuned
  them.
- **Automating the Studio place setup** (create/save the place, enable the bridge) — parked by the
  human until after this game's T2.7 run, so it is attacked with real evidence rather than guesses.

## Verification tier

`verified-local-T1` is NOT yet reachable — the gauntlet is red on reachability by construction.
T2/T2.5 unrun, T2.7 unrun (bridge proven, no evidence artifact). Ask
`lune run .claude/skills/lib/tier-status.luau games/deep-reach` — never a test count.
