# FENCE.md — the autonomy fence, made real (B3 / gate-zero)

`FACTORY.md` §4 declares what the factory may **never** do autonomously. This document is
how that declaration becomes *enforced code you can test* — the "gate-zero" requirement:
**an untested fence is not a fence.** It covers the two enforcement layers, the guard
hook's rule catalog, how it resists obfuscation without breaking real work, and the
adversarial verification behind it.

Built in Phase B3. Lives in `.claude/hooks/` (see that folder's `README.md` for the file map).

---

## 1. Two layers, defense-in-depth

The fence is enforced twice, and neither layer trusts the other.

| | Layer 1 — deny globs | Layer 2 — guard hook |
|---|---|---|
| **Where** | `.claude/settings.json` → `permissions.deny` | `.claude/hooks/guard.luau` → `lib/Fence.luau` |
| **How** | Claude Code matches the command against glob patterns | A Lune program *parses* the command and runs a rule table |
| **Strength** | Authoritative — a hook can **never** override a `deny`; evaluated regardless of what the hook returns | Understands chaining, substitution, wrappers, path-qualified executables, quoting, aliases |
| **Weakness** | Prefix globs miss `x && git push`, `git -C .. push`, `/bin/rm -rf`, `bash -c "…"` | If it can't parse the input it **fails open** — but layer 1 still stands |

Layer 2 is a near-**superset** of layer 1: everything the globs catch, the hook also
catches — plus the large class of obfuscations globs can't express. The one deliberate
exception is the lune-publish naming convention (§5).

Why both? A glob list is simple and authoritative but blunt. A parser is precise but more
code (and code has bugs). Running them together means a gap or bug in either is covered by
the other. The hook fails *open* on purpose: a crash in layer 2 must never strand the agent
unable to run safe commands — and when it does fail open, the layer-1 deny list is still the
hard floor.

## 2. How the guard hook works

Claude Code fires a **PreToolUse** hook before every `Bash`, `PowerShell`, `Edit`, and
`Write` tool call, piping the call to the hook as JSON on stdin. `guard.luau`:

1. decodes it (fails open on anything malformed),
2. routes `Bash`/`PowerShell` commands → `Fence.evaluateCommand`, and `Edit`/`Write` file
   targets → `Fence.evaluatePath`,
3. on a block: writes a structured reason to stderr and **exits 2** — the canonical,
   version-stable way to stop a PreToolUse call. The tool never runs; the model sees the
   reason and queues the action for the human instead.

```
[FENCE BLOCK] category=destructive-git rule=git-push
`git push` is outside the autonomy fence (FACTORY.md §4). A human runs all pushes.
Offending: git push origin main
This action requires a human (see FACTORY.md §4). The factory queues it; it does not do it.
```

`Fence.luau` itself is **pure** — strings in, a `Decision` out, no I/O — which is what makes
the whole policy unit-testable like the rest of the project.

## 3. The rule catalog

Four categories, mirroring `FACTORY.md` §4:

**`destructive-git`** — `push` (any form, incl. `--force`/`--force-with-lease`), `reset
--hard`, `clean`, `rebase`, `filter-branch`/`filter-repo`, `reflog expire`, `gc --prune`,
`branch -D`, `update-ref -d`, and force-anything on a working-tree-mutating subcommand
(`switch -f`, `checkout -f`). Catches the dashed plumbing form (`git-push`), aliased pushes
(`-c alias.x=push`), and `git -C <dir>` / global-option ordering. **Allows** `status`,
`log`, `diff`, `add`, `commit` (even with forbidden words in the message), `checkout`/
`switch` (even branch names like `push-notifications`), `merge`, `worktree`, `stash`,
`restore`, `reset --soft/--mixed`, `branch -d`, and `--help`.

**`destructive-fs`** — `rm -r`/`-f`, `find -delete`, `find -exec rm/shred/truncate` (incl.
`find -exec sh -c "rm -rf …"`), `shred`, `dd of=`, `truncate -s0`, bare `>`/`: >`
truncation, `/dev/null` truncation, PowerShell `Remove-Item -Recurse/-Force` and aliases
(`ri`/`rm`/`del`/`rd`), `rd /s`/`del /s`, `Clear-Content`, `[IO.Directory]::Delete`, and
encoded PowerShell (`-EncodedCommand`, unauditable → fenced). **Allows** single-file
`rm file`/`Remove-Item file`, reads (`ls`, `cat`, `Get-Content`, `Get-ChildItem -Recurse`),
`mkdir`, growing a file (`truncate -s +1G`), `-WhatIf`/`-Recurse:$false` dry-runs, and
in-workspace redirect writes (`echo x > src/y`).

**`publish-deploy`** — `rbxcloud`, `rojo upload`, `tarmac upload/sync`, `mantle deploy`,
`curl`/`wget`/`Invoke-RestMethod`/`Invoke-WebRequest` to a Roblox/Open-Cloud **host**,
opening a Roblox publish URL (`Start-Process`/`xdg-open`/`cmd start`), `iex` of a publish
script, and lune publish/upload/deploy scripts. **Allows** `rojo build/serve/sourcemap` and
network calls to non-Roblox hosts — host-parsed, so a roblox domain in a URL *path* or
*query string* (`example.com/?ref=create.roblox.com`) does **not** trip it.

**`out-of-workspace`** — writing outside the workspace root: redirects (`echo x >
C:\Windows\…`), write-commands whose **destination** escapes the root (`cp … ../../exfil`,
`mv … ~/x`, `Set-Content`/`Out-File`/`Add-Content`/`New-Item` to an outside path), the home
dir (`~`), UNC paths (`\\server\share`), and system paths (`C:\Windows`, `/etc`, `/usr`).
For `Edit`/`Write`, the file target is checked directly (airtight path containment).
**Allows** reading *from* a system path into the workspace (`cp /usr/share/x ./vendor/x`) —
only writes are fenced.

## 4. How it resists obfuscation (without breaking real work)

The hard part is catching tricks while *not* false-positiving on forbidden words that appear
as **data**. The matcher does this by actually understanding command structure:

- **Quote-aware tokenizing.** `git commit -m "fix git push race"` is safe because `push`
  there is inside a quoted argument — data, not a subcommand. Rules only consult *unquoted*
  tokens when deciding what a command *does* (the exception: subcommand words like
  `rojo "upload"`, where quoting is pure obfuscation, are matched quoted or not).
- **Segmentation + indirection expansion.** Splits on `;`/`&&`/`||`/`|`/`&`/newline, and
  surfaces the contents of `$( … )`, backticks, `${ … }`, `( … )` subshells, `<( … )`
  process substitution, and `{ … }` scriptblocks for scanning.
- **Wrapper recursion.** `bash -c "…"`, `sh -c`, `pwsh -Command`/`-Comm`, `cmd /c "…"`,
  `eval`, `iex`, `Start-Process -ArgumentList`, and `xargs` all have their inner command
  pulled out and scanned too — including nested forms.
- **Head normalization.** `/bin/rm`, `.\rbxcloud.exe`, `C:\tools\rbxcloud.exe`, `\rm` all
  reduce to the bare program name before matching.
- **Variable resolution.** Simple `X=push; git $X` / `$u='…roblox…'; irm $u` assignments are
  resolved so the real command is seen.
- **Host & destination parsing.** Roblox detection matches the URL **host**, not a
  substring; out-of-workspace detection checks the **write destination**, not the source.

## 5. Convention: lune script naming

The lune-publish rule blocks `lune run <path>` when the path contains `publish`, `upload`,
or `deploy` — matching the layer-1 glob (`lune run *publish*`). Consequence: **do not name
test files with those words** (use `monetization_spec.luau`, `receipt_spec.luau`, etc., not
`publish_spec.luau`). A genuinely-needed exception would require relaxing *both* layers
together.

## 6. Verification — gate-zero evidence

The fence is proven three ways, not by assertion.

- **A machine-checkable truth table** — `.claude/hooks/tests/corpus.luau` holds **274 cases**:
  every command/path that MUST block or MUST allow, across both shells, with obfuscations and
  false-positive guards. A `block` row that *allows* is a bypass; an `allow` row that *blocks*
  is a false positive; category is asserted too. `lune run .claude/hooks/tests/run.luau` exits
  non-zero on any miss and is part of the gauntlet.
- **Three adversarial red-team rounds** (multi-agent: independent attacker lenses propose
  bypasses + false positives; a *separate* referee adjudicates the authoritative verdict —
  maker/checker separated). Round 1 surfaced 88 disagreements against the first draft. Round 2
  caught a real regression — the `(…)`/`{…}` extraction was scanning *quoted* commit-message and
  awk-program data — which drove the quote-aware rewrite. Round 3 found two more classes (heredoc
  *bodies* are data, not commands; `find -exec <wrapper> <destroyer>`) plus a batch of edge cases,
  then re-ran clean. Every real finding was fixed and folded into the corpus.
- **A live, in-session block.** With the hook wired into `settings.json`, Claude Code itself
  refused `true && rm -rf …` (a chained form the layer-1 globs miss) inside the session that
  built it — while `echo "git push … rm -rf … as data"` and `git status` ran normally.

Run the corpus, and exercise an adapter exactly as Claude Code does:

```sh
lune run .claude/hooks/tests/run.luau
echo '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | lune run .claude/hooks/guard.luau ; echo "exit=$?"
```

## 7. Honest limits

- **Out-of-workspace** is airtight for `Edit`/`Write` targets (path containment) but
  **best-effort** for arbitrary shell commands — a command can touch the filesystem in
  countless ways. The guard covers the common and obvious ones; Claude Code's own workspace
  model and the layer-1 denies are the primary control there. One deliberate carve-out: the
  agent's own Claude Code memory directory (`.claude/projects/*/memory/`) is *allowed* — it
  lives outside the repo but is where the agent persists facts. General `.claude/` writes stay
  blocked, so the fence's own `settings.json` can't be edited out from under it.
- The matcher defends against an LLM that *naively or via injection* attempts a fenced action,
  plus a wide class of obfuscations — **not** an unrestricted human adversary with shell access.
  Known, accepted residuals (caught by the red-team, judged out-of-scope for a naive/injected
  threat model and still partly covered by layer-1): **string-reassembly** of a program name
  (`& ('rbx'+'cloud')`, `-join`), **ANSI-C `$'…'` hex-escape** decoding, **raw-IP** Roblox
  endpoints (indistinguishable from any IP without DNS), and **homoglyph** separators. The
  operator is on-the-loop and the deny list is the floor.
- `-EncodedCommand` PowerShell is blocked outright rather than decoded — the factory never
  legitimately needs it, and an unauditable command is treated as hostile.

## 8. The other safety hook: PostToolUse format-lint

`.claude/hooks/format-lint.luau` is the self-healing half of §3: after an edit to a `.luau`
file under a `stylua.toml` tree, it runs `stylua --check` + `selene` on that file and feeds
any findings straight back so the model fixes them in the same turn. It never blocks (the
edit already happened) and fails open on any tooling problem.

## 9. Run/audit log — observability for unattended runs

A fence that runs unattended must leave a trace, or it's undebuggable by construction. Both hooks
append **one JSON line per decision/event** to `logs/factory.jsonl` (gitignored) via the pure
`lib/Log.luau` helper — every block/allow the guard makes and every `clean`/`issues` outcome
format-lint reports. It's the durable record a human-on-the-loop reads to answer *"what did the
agent do, and why was that refused?"* after the fact, and the file the **B4** build pipeline will
write its per-run journal into (one `source` field per producer).

```sh
grep '"decision":"block"' logs/factory.jsonl     # everything the fence refused, with category + rule
```

By contract logging is **totally non-fatal**: every write is `pcall`-guarded, so a missing or
unwritable log silently no-ops and can never change a fence decision or brick a hook — the same
fail-open discipline as the rest of layer 2. (Lune has no `O_APPEND`; writes are read-modify-write,
so a rare concurrent-write line-drop under heavy fan-out is an accepted trade for an audit trail.)
Verified by `tests/log_spec.luau` (driven by the corpus runner) and confirmed live: the active hook
logged its own session's decisions, including a `git push` block, end-to-end.
