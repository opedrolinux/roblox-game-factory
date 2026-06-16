# `.claude/hooks` — the factory safety hooks

Two Claude Code hooks that make the autonomy fence (FACTORY.md §4) and the self-healing
loop (§3) real instead of just doctrine. Both are pure Lune (Luau) — one pinned runtime,
unit-testable like the rest of the project, never loaded inside Roblox.

## The two layers of the fence

The fence is **defense-in-depth**. Neither layer trusts the other:

1. **Layer 1 — `permissions.deny` globs** in `../settings.json`. Claude Code evaluates
   these first and authoritatively; a hook can never override a deny. They catch the
   naive forms (`git push*`, `rm -rf*`, `rbxcloud *`, …).
2. **Layer 2 — the PreToolUse guard hook** (`guard.luau` → `lib/Fence.luau`). It *parses*
   each command — chaining (`;`, `&&`, `|`), substitution (`$(…)`, backticks), shell
   wrappers (`bash -c`, `cmd /c`, `eval`/`iex`), env-assignment prefixes, `git -C <dir>`,
   `xargs`, PowerShell aliases — to catch what prefix-globs miss, while *not*
   false-positiving on forbidden words that appear as data (a commit message, a branch
   name). It is a strict **superset** of layer 1.

If layer 2 ever fails to parse its input it **fails open** (exit 0) — layer 1 remains the
backstop, so a bug in the hook can never brick the agent's ability to run safe commands.

## Files

| File | Role |
|---|---|
| `lib/Fence.luau` | Pure matcher. `evaluateCommand(cmd, shell)` and `evaluatePath(path, root)` → a `Decision`. No I/O. The whole policy lives here as an auditable rule table. |
| `guard.luau` | **PreToolUse** adapter. Reads the tool call as JSON on stdin, routes `Bash`/`PowerShell` → `evaluateCommand` and `Edit`/`Write` → `evaluatePath`. Block = **exit 2 + structured stderr** (the canonical, version-stable PreToolUse block); allow = exit 0. |
| `format-lint.luau` | **PostToolUse** adapter (§3 self-healing). After an edit to a `.luau` file under a `stylua.toml` tree, runs `stylua --check` + `selene` on it and feeds findings back (exit 2 → stderr) so the model fixes them in the same turn. Never blocks; fails open. |
| `tests/corpus.luau` | The fence truth table — every command/path that MUST block or MUST allow, including obfuscations and false-positive guards. The red-team adds rows here. |
| `tests/run.luau` | Drives the corpus through `Fence` and exits non-zero on any mismatch (bypass, false positive, or wrong category). Part of the gauntlet. |
| `stylua.toml` | Mirrors `core/stylua.toml` so the hooks are formatted consistently. (No `selene.toml` here on purpose — the Lune infra uses `process`/`stdio`, which the core's roblox-fenced selene std rightly rejects for game code.) |

## Verify (gate-zero)

```sh
lune run .claude/hooks/tests/run.luau     # the corpus must be all-green
```

To exercise an adapter exactly as Claude Code does — pipe a hook payload to it:

```sh
echo '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | lune run .claude/hooks/guard.luau ; echo "exit=$?"   # → exit=2 (blocked)
echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | lune run .claude/hooks/guard.luau ; echo "exit=$?"   # → exit=0 (allowed)
```

## Honest limits

- **Out-of-workspace** is airtight for `Edit`/`Write` file targets (path containment) but
  only **best-effort** for arbitrary shell commands — a command can touch the filesystem
  in countless ways. The guard blocks obvious reaches into system paths; Claude Code's own
  workspace model and layer-1 denies are the primary control there.
- The matcher defends against an LLM that *naively or via injection* tries a fenced action,
  plus a wide class of obfuscations — not against an unrestricted human adversary with
  shell access (e.g. a custom interpreter built at runtime, or fetching by raw IP). That is
  an accepted boundary: the operator is on-the-loop and the deny list is the hard floor.
- The `@lune/*` requires show as "unknown" under `luau-lsp analyze` because the project
  ships no Lune type defs (true for all its Lune scripts). The hooks are verified by
  running them, the corpus, and `stylua`.
