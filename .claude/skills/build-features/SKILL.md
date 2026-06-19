---
name: build-features
description: B4 piece 2 — the feature build + independent-gate engine. For each feature of a scaffolded game, an independent builder writes the authoritative server logic from its spec slice, then an independent test gate (a different agent authors spec-derived tests + 3 adversarial critics) verifies it. Use after a game is scaffolded (new-game) and its contract pass is written, to build + gate one or more features before they are union-merged onto the game's staging branch. The orchestrator runs the contract pass before and adjudicates/fixes/merges after.
---

# build-features

The middle of the build pipeline: **fan-out + per-feature gates**. It does NOT decompose a spec
(that is `build-game`'s job) and it does NOT touch `main` (the human pushes). It turns *one or more
feature slices whose contracts are already written* into *built, independently-gated services*.

Proven end-to-end on collect-sim **"Collection core"** (2026-06-19): the gate's economy red-team
caught a real CAPACITY-cap bypass that the builder and two other critics missed. That is the whole
point — **a builder's own green gauntlet is not a sufficient gate.**

## What it is

A **saved Dynamic Workflow**: `.claude/workflows/build-features.js`. Only the Workflow engine can
spawn the agents this needs (BUILD-PIPELINE-DESIGN.md §1); the deterministic steps it leans on are
Lune (`.claude/skills/lib/gauntlet.luau`, `merge.luau`).

Per feature, **serially** (v1):

1. **Build** — an independent builder agent reads the feature's spec slice + the game `CLAUDE.md`
   rules + the shared contract (already written) + the service pattern, writes
   `src/server/services/<name>/<Service>.luau` (+ a client controller if `hasUI`), and runs the
   gauntlet until green. It treats `src/shared` and `init.server` as **READ-ONLY** and does **not**
   commit.
2. **Gate** — an independent **test author** (≠ the builder) writes `tests/unit/<name>.spec.luau`
   from the **spec** (implementation frozen), registers it, runs the suite; then **3 critics in
   parallel** — *coverage* (is the required matrix covered?), *anti-tautology* (does the concurrency
   test actually interleave?), and an *economy red-team* (find a real double-spend / mint / invariant
   bypass). Findings come back structured.
3. **Suggest a verdict** — `green` (builder green + author green + all critics pass),
   `bug-found` (author or red-team named a real impl bug), `needs-review` (red suite or a critic gap),
   or `build-failed`.

It returns `{ gameDir, green: [...], flagged: [...], results: [...] }`. **It commits nothing.**

## The orchestrator's serial responsibilities (NOT in the workflow)

These are serial barriers requiring judgment (§5, §11.1), so they stay with the main session / human:

- **BEFORE** — the **contract pass**: on the game's `staging/<game>` branch, write every shared delta
  this batch needs **once** (the `Net.Actions` constants, any `Types` fields + a `Migrations` bump,
  and a *registered stub* service so `rojo` compiles and runtime wiring exists). Commit it. Builders
  then only fill their own disjoint files. Append-list deltas (actions/Types fields) union cleanly;
  `Migrations`/`CURRENT_SCHEMA_VERSION` are sequenced state only the contract pass writes.
- **AFTER** — for each `green` feature: review the diff, run `merge.luau` to confirm it only added
  feature files (`services/`/`controllers/`/`tests/unit/`) — PARK anything that touched shared/spine —
  then commit it on `staging/<game>` and re-run the gauntlet. For a `bug-found` feature: apply the
  fix **yourself** (the builder/author won't) and add a **falsify-first regression test** (prove it
  RED on the unfixed code, GREEN after), then re-gate. For `needs-review`/`build-failed`: park +
  surface. Finally fast-forward `main` only when staging is integration-green; **the human pushes**.

## How to invoke

```
Workflow({
  name: 'build-features',
  args: {
    gameDir: 'games/collect-sim',
    features: [
      {
        name: 'upgrades-shop',
        serviceName: 'UpgradesShopService',
        specSlice: '<the exact spec text for this feature + its success criteria, verbatim>',
        contractSummary: '<which Net.Actions / Types fields the contract pass already wrote>',
        hasUI: false
      }
    ]
  }
})
```

Pass `features` as a real JSON array (not a stringified list). `args.features: []` is a valid no-op
(parses + returns empty) — used to smoke-check the script is well-formed without spawning agents.

## v1 scope & limits (be honest)

- **Serial, not worktree-parallel.** Build and gate share the main working tree (exactly the proven
  manual flow), so features run one at a time. The §4 worktree fan-out — a builder's worktree branch
  handed to the gate so N features build in parallel — is **v2**; it needs cross-agent file-sharing
  this v1 deliberately avoids.
- **Run on the right branch.** Check out `staging/<game>` (with the contract pass committed) before
  invoking — the workflow writes into the current working tree.
- **Permissions.** The agents call `lune run .claude/skills/lib/*`. Under strict unattended perms
  that needs `Bash(lune run .claude/skills/**)` (+ PowerShell) allow-listed — a **human** edit to
  `.claude/settings.json` (it is `protected-config`; the fence blocks agent edits to it).

## Related

- `new-game` (B4 piece 1) — scaffolds the game this builds into.
- `build-game` (B4 piece 3, next) — wraps decompose → contract pass → **build-features** →
  integration gate → adversarial review → handoff.
- `docs/BUILD-PIPELINE-DESIGN.md` — the full design (§2 lifecycle, §5 shared seam, §6 gates,
  §11 locked decisions).
