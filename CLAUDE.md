# CLAUDE.md

## What this is

A single Bash script (`statusline.sh`) that renders the Claude Code CLI status line. Claude Code pipes a JSON blob to the script on stdin; the script prints one line of ANSI-colored text. `test-statusline.sh` is a self-contained test runner. `.github/workflows/test.yml` runs the tests on ubuntu-latest and macos-latest.

## Commands

```bash
# Run the full test suite against the script
bash test-statusline.sh ./statusline.sh

# Manually exercise the script with a stdin payload (see test file for the JSON shape)
echo '{"model":{"display_name":"X"},...}' | bash statusline.sh
```

There is no build, lint, or package step. The only single-test workflow is editing/commenting the relevant `assert_*` calls in `test-statusline.sh` — the runner has no test-name filter.

## Architecture

`statusline.sh` runs top-to-bottom each invocation:

1. **Parse** — reads stdin once, extracts ~9 fields in a single `jq … | @tsv` call into tab-separated vars, then sanitizes (jq emits empty strings for nulls).
2. **Monthly usage (Enterprise only)** — the stdin JSON has no monthly limit, so it's fetched from the undocumented `https://api.anthropic.com/api/oauth/usage` endpoint (`extra_usage` field). The OAuth token comes from the macOS Keychain or `~/.claude/.credentials.json` on Linux/WSL. The response is **cached to a file** (`CLAUDE_STATUSLINE_CACHE`, 60s TTL) to stay within the status line's ~300ms latency budget and the endpoint's own rate limit — see the README "Caveats" before touching this.
3. **Build output** — segments are pushed into a `parts=()` array and joined with a separator. Segments append conditionally, so account types that lack data (e.g. no 5h/7d window) simply omit those segments.

Helper functions at the top encapsulate the pure formatting logic: `color_by_pct` (green/yellow/red thresholds at 50/80), `make_bar` (10-block Unicode progress bar), `format_duration` (seconds → `2h15m`), and `add_window_segment` (renders 5h/7d windows; the 7d "rich" form with bar + daily pace is selected by passing the period as a 4th arg).

## Conventions and gotchas to preserve

- **Target bash 3.2** (macOS default). No `mapfile`/`readarray`, no associative arrays. The monthly-fields read uses a `while read` loop specifically because `read -r ... <<< ` with tab IFS collapses empty fields.
- **macOS vs Linux divergence** is handled inline by branching on `[ "$(uname)" = "Darwin" ]` — `stat`, `date`, and credential storage all differ. Keep both branches in sync when editing.
- **Cents, not dollars**: `extra_usage.monthly_limit`/`used_credits` are in cents despite a `currency: "USD"` field; the script divides by 100.
- **Placeholder state**: right after Claude Code starts, rate-limit windows arrive as `pct=0, reset≈now`. The script shows `?` rather than a misleading `0%`. Don't "fix" this into 0%.
- **Worktree display**: a worktree is detected by `absolute-git-dir != git-common-dir`; the dir segment then shows the *main repo* name, and the branch segment is prefixed with the worktree name (`basename` of the per-worktree git dir, i.e. `.git/worktrees/<name>`) as `wt-name@branch` / `wt-name@<sha>`. This is what makes a detached HEAD in a worktree distinguishable from one in the main repo (plain `@<sha>`). The `@`-prefix is gated on the `is_detached` flag, not on whether the ref string starts with `@`.
- **Numeric math in `awk`**, not bash, for any non-integer (dollar pace, percentages).
- **`export LC_NUMERIC=C` at the top is load-bearing**: a comma-decimal locale (cs_CZ, de_DE, …) makes bash `printf '%.0f' "42.5"` fail with "invalid number" (→ `ctx 0%`) and awk emit commas (→ `s: $0,00`). Set in-script so it holds regardless of the launch command. Don't remove it. Section 8 of the test suite guards this (skips if no comma locale is installed).
- **Test env overrides**: `CLAUDE_STATUSLINE_TODAY` and `CLAUDE_STATUSLINE_MONTH_DAYS` exist only so date-dependent output is deterministic in tests; production reads from `date`.

## Testing model

Tests are fully isolated and network-free: each run gets its own `mktemp -d` sandbox, a fake `$HOME`, a throwaway git repo, and a cache path. The OAuth endpoint is **never** called — the cache file is seeded directly via `set_cache` to simulate any account state. Output is compared with ANSI codes stripped. When adding a feature, add assertions in the matching numbered section of `test-statusline.sh`.