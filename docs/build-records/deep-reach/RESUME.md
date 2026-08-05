# Deep Reach — resume here

State as of the end of the first build session. Everything needed to continue is committed; nothing
lives only in a chat log.

**Branch:** `staging/deep-reach` (not pushed — `git push` is the human's).
**Where we are:** Workflow A is done and through the human gate. Fan-out has not started.

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

**Gauntlet right now:** stylua · selene · rojo · require · lune all GREEN (194/194).
`reachability` RED with 28 FAIL — `view-field-read` 19, `seam-read` 6, `currency-sink` 2,
`catalog-id-read` 1. Every one is waiting on fan-out. The count went UP from 24 when the seam
convention was fixed, because the gate went from blind (`seams:0`) to seeing (`seams:8`) — a higher
number in a more honest state. Do not read it as a regression.

## Next: fan-out, batch by batch

Batches, in order. A later batch depends on an earlier one's REAL implementation, so the orchestrator
adjudicates and union-merges between them — never all at once.

```
0: plot, daily, leaderboard
1: salvage
2: structures
3: depth, offline
4: monetization
5: resurface
```

Per batch: `fanout.js` (nests `build-features`: independent builder → independent gate of author + 3
adversarial critics → bounded N=2 falsify-first auto-fix) → orchestrator adjudicates → `merge.luau`
classify → union-merge → re-gauntlet.

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

## Open questions for the human — not decided, deliberately

- **`gate-reachability`'s maturity probe has two states**, sample-only and mature, and flips on ANY
  non-`sample` directory under `src/server/services/`. A contract pass MUST create those, so every
  game will sit in an unrepresented third state — "contract pass done, features not built" — at this
  exact boundary. Worked around this run with a scoped, logged, orchestrator-owned override
  (`allowGauntletRedAt`). The probe itself still wants a real fix, and that is a factory-wide change
  with its own corpus tests.
- **Pacing (amendment A8)** — ~90s to first Credits, 10–15 min to first Depth unlock — is assigned to
  the integration gate as a coarse order-of-magnitude band only. The real numbers are a human tuning
  judgment at the playtest. The handoff note must say so rather than implying an offline rung tuned
  them.
- **Automating the Studio place setup** (create/save the place, enable the bridge) — parked by the
  human until after this game's T2.7 run, so it is attacked with real evidence rather than guesses.

## Verification tier

`verified-local-T1` is NOT yet reachable — the gauntlet is red on reachability by construction.
T2/T2.5 unrun, T2.7 unrun (bridge proven, no evidence artifact). Ask
`lune run .claude/skills/lib/tier-status.luau games/deep-reach` — never a test count.
