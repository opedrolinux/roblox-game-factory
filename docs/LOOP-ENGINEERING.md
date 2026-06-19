# LOOP-ENGINEERING.md — the discipline this factory is an instance of

Research note + roadmap. It records what "loop engineering" (the mid-2026 meta) actually is,
honestly separates the signal from the hype, maps it onto this factory, and turns the gaps into a
prioritized upgrade list. `FACTORY.md` owns *policy*; this file owns *why the factory is shaped the
way it is* and *what to sharpen next*. Researched 2026-06-15 from primary sources (listed at the end).

---

## 1. What it is

> **"Replacing yourself as the person who prompts the agent. You design the system that does it
> instead."** — Addy Osmani

**Loop engineering** is building the *system that prompts your coding agents* instead of prompting
them turn-by-turn yourself. You construct a small control loop that:

1. **discovers** what work needs doing (a schedule, an event, or a written goal — not a human prompt),
2. **hands it to a sub-agent** (or several), with the writer kept structurally separate from the checker,
3. **independently verifies** the result is actually done — tests, type/lint, build exit codes, and/or
   a *separate judge model*; never the worker grading its own work,
4. **persists progress** somewhere durable that outlives a single conversation, then
5. **decides the next move** — running on a schedule or until a written goal condition is graded true.

The human stops being the per-keystroke prompter and becomes the **loop designer** and the
**on-the-loop supervisor** who reads what landed and steers.

**Lineage (the verified part):** prompt engineering → *context engineering / agent orchestration*
(Anthropic's own terms — "curating the optimal set of tokens" across an agent's trajectory, plus
fanning work to sub-agents) → **loop engineering** (designing the cross-turn control flow *around*
those steps). It crystallized in early June 2026: Boris Cherny (Claude Code, Anthropic) on the
Acquired interview — *"I have loops running… my job is to write loops"* — and Peter Steinberger
(OpenClaw) — *"you shouldn't be prompting coding agents anymore."*

## 2. Signal vs. hype (the honest cut)

**Load-bearing and real:**

- **The separate grader.** The best-substantiated idea in the whole discipline: the agent that wrote
  the work is a *structural* poor judge of it, so a *different* model/agent must check it. Now ships
  natively as Claude Code's `/goal` — a fresh fast model grades your written condition after every turn.
- **Verification, not autonomy, is the hard part.** Deterministic checks + an LLM-judge rubric +
  occasional human review, with the maker separated from the checker. (Anthropic's eval guidance —
  per-dimension isolated judges, an "Unknown" escape valve, grade the final *end state* — is the most
  rigorous primary source.)
- **Durable external memory + fresh context each iteration**, and **stopping conditions / budgets** as
  first-class design concerns. (Cautionary tale: a large company reportedly burned its annual AI budget
  in ~4 months and had to impose per-seat caps.)

**Froth (discount these):**

- *"You shouldn't be prompting coding agents anymore"* is a deliberately absolutist provocation that
  the primary record itself shows was contested (*"it's a cron job wearing a hat"*). A still-debated
  meme, not a settled discipline.
- The tidy dated genealogy *"prompt eng (2023) → orchestration (2024) → loop eng (2026)"* traces to **no
  primary source** — retrospective storytelling.
- Recap-blog benchmark numbers (90.2% uplift, 3.6×, 15×/4× token multipliers) carry false precision;
  several "quotes" in circulation are paraphrases-dressed-as-verbatim, and at least one is a
  meaning-inverting **misquote** (the real line is *"a loop **with no real check** is the agent agreeing
  with itself"* — the conditional is load-bearing). A few arXiv figures are **misattributed** to papers
  that contain no such data.

**Takeaway:** the *engineering* is real; the *"new settled discipline"* packaging is marketing. Build to
the engineering.

## 3. The factory is already a loop-engineering system

Measured against the canonical checklist, `roblox-game-factory` is **ahead of most write-ups on the
hard parts** — it just has named gaps.

| Loop-engineering piece | Where this factory stands | The gap / upgrade |
|---|---|---|
| **Maker/checker split** | ✅ Strong — the test agent *never wrote the code*, authors tests from the spec; adversarial pass (`FACTORY.md` §3, `TESTING.md` §4) | Give checker agents **durable memory** across games |
| **Independent verification** | ✅✅ Very strong — the gauntlet + per-feature & integration test gates + loop-until-dry race hunt, machine-readable (`TESTING.md` §2–5) | Add an **LLM-judge quality layer**; add a **cross-turn grader** |
| **Stopping conditions** | ✅ Strong — stop conditions + runaway guard (`FACTORY.md` §9) | It's *doctrine*, not enforced code; add a **budget circuit-breaker** |
| **Self-healing retry** | ✅ Strong — gauntlet feedback, bounded fix-loop, parking (`FACTORY.md` §3) | ✅ Format-lint hook shipped (B3, `1dd78eb`) — now also writes a run log |
| **Human-on-the-loop** | ✅✅ Signature — the fence + human gates + push notifications (`FACTORY.md` §4–5, §9) | ✅ Guard hook built & gate-zero-verified (B3) — see `docs/FENCE.md` |
| **Worktree parallelism** | ✅ Strong — 3 nested levels + union-merge (`FACTORY.md` §7) | Designed, not yet *coded* (**B4**) |
| **Work discovery / trigger** | ❌ **Missing** — work is human-initiated (write a spec, run the pipeline) | Add scheduled/event re-entry — **portfolio as a work queue** |
| **Cross-turn outer loop** | ❌ **Missing** — "done" is decided in-session by the orchestrator | Wrap the build in a **`/goal`-style loop** graded by a fresh model |

> The factory was built from *lessons*, not from this meme — but it independently converged on the
> same hard-won shape. That convergence is the strongest evidence the shape is right.

## 4. Prioritized upgrades

Loop engineering **validates the existing Phase B roadmap and adds three sharpeners.** In order:

1. **[B3 — ✅ DONE] Build & adversarially test the PreToolUse guard hook (fence gate-zero).** Shipped in
   `1dd78eb`: a pure parsing guard (`.claude/hooks/lib/Fence.luau`) behind a two-layer fence, a 281-case
   truth table, three adversarial red-team rounds, and a **live** in-session block of a fenced `rm -rf`.
   A follow-up added a durable run/audit log (`logs/factory.jsonl`) so every fence decision and self-heal
   event is persisted for debugging. See `docs/FENCE.md`. *(was medium)*
2. **[B4 — planned] Build the `build-game` / `build-features` pipeline (the loop body).** Feature
   fan-out, worktree isolation, union-merge, the two gates wired together, the adversarial pass —
   currently doctrine and diagrams, not code. Without it there is no loop to engineer. *(large)*
3. **[NEW] Wrap the build in a `/goal` cross-turn outer loop with a fresh-model grader.** Highest-leverage
   new idea. Make the definition-of-done (`FACTORY.md` §8) a written condition — *"gauntlet green AND both
   test gates pass AND the adversarial pass found no open exploit"* — graded each turn by a *separate*
   model, instead of the orchestrator deciding "done" in-session. This is the core loop-engineering
   insight, made machine-enforced. *(medium)*
4. **[NEW] Add an LLM-as-judge quality layer atop the deterministic gates.** The gates prove *"the logic
   is correct"* (`TESTING.md` §9 is honest that this is necessary-not-sufficient). A single-call rubric
   judge (0.0–1.0 + pass/fail, with an "Unknown" escape valve) adds *"is it good / does it match the
   spec?"* — catching spec-drift and narrowing the human visual gate to genuine taste calls. *(medium)*
5. **[NEW] Portfolio-as-work-queue + scheduled re-entry** — the funnel table is already a de-facto queue;
   poll it to pick up the next `spec`-stage game or a freed parked feature, re-entering within the fence.
   *Do this only after upgrade 1 is proven.* *(medium)*
6. **[NEW] Durable sub-agent memory + a cross-game `learnings.md`** — persist recurring Roblox failure
   modes (economy-dupe shapes, clock-rollback exploits, DataStore-budget misuse) so the builder sees them
   as up-front checklist items. The self-improving (context-level, not model-level) flywheel that compounds
   the factory's reuse thesis (`FACTORY.md` §2). *(medium)*
7. **[NEW] Budget circuit-breaker** — turn *"watch `/usage`"* (`FACTORY.md` §6) into an automated breaker
   that downgrades autonomy / pauses-and-pings at a $/token or parked-failure threshold (traffic-light:
   green reversible / yellow bounded / red human). *(small)*

## 5. Sources (primary-weighted)

- Addy Osmani — *Loop Engineering*: https://addyosmani.com/blog/loop-engineering/
- Boris Cherny on Claude Code (Acquired interview, recap): https://workos.com/blog/boris-cherny-claude-code-acquired-interview-takeaways
- Claude Code `/goal` docs: https://code.claude.com/docs/en/goal
- Claude Code sub-agents docs: https://code.claude.com/docs/en/sub-agents
- Anthropic — *Effective context engineering for AI agents*: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic — *Effective harnesses for long-running agents*: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Anthropic — *Demystifying evals for AI agents*: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- Anthropic — *Multi-agent research system*: https://www.anthropic.com/engineering/multi-agent-research-system
- Thoughtworks — *Cybernetics and the human-on-the-loop in agentic coding*: https://www.thoughtworks.com/insights/blog/generative-ai/cybernetics-and-human-on-the-loop-in-agentic-coding
- Cobus Greyling — *Loop Engineering*: https://cobusgreyling.substack.com/p/loop-engineering
- Baker et al. — *Monitoring reward hacking* (arXiv 2503.11926): https://arxiv.org/abs/2503.11926
- *awesome-harness-engineering*: https://github.com/ai-boost/awesome-harness-engineering
