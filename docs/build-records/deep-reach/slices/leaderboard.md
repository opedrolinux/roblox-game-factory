# Spec slice — leaderboard (LeaderboardService)

Generated from plan.json features[name="leaderboard"]. This file is the FEATURE CONTRACT.
Do not edit by hand — regenerate from plan.json.

## Slice (verbatim)

FEATURE (verbatim): "**Leaderboard** — top players by lifetime Credits (in-world GUI)."

WHAT THIS SLICE OWNS
- A ranked snapshot of the players currently on this server, ordered by `stats.lifetimeCredits` descending, top-N (N a server constant), rebuilt on a server-clock cadence and pushed/served to clients.
- The `leaderboard.fetch` action returning that snapshot.
- The in-world GUI board: a greybox Part with a SurfaceGui listing rank, player name and lifetime Credits. Greybox-in-code, no external assets.
- Names: use only the Roblox-provided Name/DisplayName. Do NOT render any player-authored free text — this feature has no text input and must not add one (rule 9).
- Client controller: renders the board and refreshes it; fetches through the shared JoinRetry guard.

CRITICAL — YOU ONLY READ. `stats.lifetimeCredits` is provided by the SERIAL contract pass and is incremented by EconomyService on every earn path, all of which live in other features (salvage, offline, daily, monetization). You must not increment it, must not compute it from a balance, and must not require or depend on any other feature's service. Read the field off the loaded player data through the data layer.

SCOPE FENCE: v1 is SERVER-LOCAL ranking. A cross-server global board (OrderedDataStore) is explicitly OUT of v1 scope — do not add DataStore calls outside `src/server/data/`.

NOT THIS SLICE: producing, incrementing or resetting lifetimeCredits; any currency mutation; any purchase.

PERSISTENCE: none of your own. Append-only: one Net action, zero schema change.

## Success criteria this slice is graded against

- **Gauntlet green** — stylua · selene · rojo · lune + reachability; per-feature + integration gates green.
