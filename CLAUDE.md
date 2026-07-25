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
2. **Monthly usage** — the stdin JSON has no monthly limit, so it's fetched from the undocumented `https://api.anthropic.com/api/oauth/usage` endpoint (`extra_usage` field). The OAuth token comes from the macOS Keychain or `~/.claude/.credentials.json` on Linux/WSL. The response is **cached to a file** (`CLAUDE_STATUSLINE_CACHE`, 60s TTL) to stay within the status line's ~300ms latency budget and the endpoint's own rate limit — see the README "Caveats" before touching this.
3. **Build output** — segments are pushed into a `parts=()` array and joined with a separator. Segments append conditionally, so account types that lack data (e.g. no 5h/7d window) simply omit those segments.

Helper functions at the top encapsulate the pure formatting logic: `color_by_pct` (green/yellow/red thresholds at 70/85), `make_bar` (10-block Unicode progress bar), `format_duration` (seconds → `2h15m`), and `add_window_segment` (renders 5h/7d windows; the 7d "rich" form with bar + daily pace is selected by passing the period as a 4th arg).

## Conventions and gotchas to preserve

- **Target bash 3.2** (macOS default). No `mapfile`/`readarray`, no associative arrays. The monthly-fields read uses a `while read` loop specifically because `read -r ... <<< ` with tab IFS collapses empty fields.
- **macOS vs Linux divergence** is handled inline by branching on `[ "$(uname)" = "Darwin" ]` — `stat`, `date`, and credential storage all differ. Keep both branches in sync when editing.
- **Cents, not dollars**: `extra_usage.monthly_limit`/`used_credits` are in cents; the script divides by 100. The unit comes from `extra_usage.currency`, which is not always `USD` (EUR-billed accounts report `EUR`): `USD`/`EUR`/`GBP` map to `$`/`€`/`£`, anything else is prefixed with the raw code (`CZK 250`). The symbol is passed into the awk formatters as `-v c=`; don't hardcode `$` back into them. The session cost segment is unrelated — it's `total_cost_usd` from stdin and stays `$`.
- **`extra_usage` is not Enterprise-only**: Pro/Max accounts with pay-as-you-go credits also report `is_enabled: true`. The two M-segment forms are told apart by **whether the cached response has 5h/7d windows** (`.five_hour`/`.seven_day` non-null → subscription plan): with windows, `extra_usage` is only the credit cap that applies past the plan limits, so the segment is just `M: $X left`; without them (Enterprise) the monthly budget is the whole budget and gets `$spent Nd used PCT% bar $left Md left` + pace. `month_pct` is only set in the Enterprise case, which is why the calendar-day and pace computation sits inside the `[ -n "$month_pct" ]` branch; the short form is colored by `used_credits/monthly_limit`.
- **`extra_usage.utilization` is not a plan marker**: it is plain `used_credits/monthly_limit*100` and is `null` only while nothing has been spent. Don't reintroduce it as the Pro/Enterprise discriminator (that bug shipped once — it looked right at zero usage and turned into the full Enterprise form the moment credits were spent). Keep `utilization // ""` in the jq read anyway: a `// 0` default would render the Enterprise form with a fake 0%.
- **Placeholder state**: right after Claude Code starts, rate-limit windows arrive as `pct=0, reset≈now`. The script shows `?` rather than a misleading `0%`. Don't "fix" this into 0%.
- **The 7d `avg` pace is colored by pace, not fill**: `add_window_segment` colors the daily-pace segment by the `avg/left` ratio (green <1.0, yellow <1.5, red ≥1.5 or window full), computed in the same awk that formats the pace, *not* by `color_by_pct` on the window %. This is deliberate — don't "unify" it with the 7d segment's color. The monthly `avg` (line ~342) still uses `color_by_pct`; leave it, since at month-end (`days_remaining=0`) there's no sustainable rate to compare against.
- **Worktree display**: a worktree is detected by `absolute-git-dir != git-common-dir`; the dir segment then shows the *main repo* name, and the branch segment is prefixed with the worktree name (`basename` of the per-worktree git dir, i.e. `.git/worktrees/<name>`) as `wt-name@branch` / `wt-name@<sha>`. This is what makes a detached HEAD in a worktree distinguishable from one in the main repo (plain `@<sha>`). The `@`-prefix is gated on the `is_detached` flag, not on whether the ref string starts with `@`.
- **`tr -d '\r'` on every `jq` output read into a variable** (main parse, OAuth token, monthly fields): native Windows `jq` (winget) emits CRLF, so the last field of each line carries a trailing `\r`. That breaks `[ "$reset" -gt "$now" ]` (arithmetic error → 7d segment vanishes) and `[ "$m_enabled" = "true" ]` (compares against `true\r` → monthly block silently dropped). No-op on Linux/macOS. The `jq -e` validation call needs no `tr` — it only tests the exit code.
- **Numeric math in `awk`**, not bash, for any non-integer (dollar pace, percentages).
- **`export LC_NUMERIC=C` at the top is load-bearing**: a comma-decimal locale (cs_CZ, de_DE, …) makes bash `printf '%.0f' "42.5"` fail with "invalid number" (→ `ctx 0%`) and awk emit commas (→ `s: $0,00`). Set in-script so it holds regardless of the launch command. Don't remove it. Section 8 of the test suite guards this (skips if no comma locale is installed).
- **Test env overrides**: `CLAUDE_STATUSLINE_TODAY` and `CLAUDE_STATUSLINE_MONTH_DAYS` exist only so date-dependent output is deterministic in tests; production reads from `date`.

## Testing model

Tests are fully isolated and network-free: each run gets its own `mktemp -d` sandbox, a fake `$HOME`, a throwaway git repo, and a cache path. The OAuth endpoint is **never** called — the cache file is seeded directly via `set_cache` to simulate any account state. Output is compared with ANSI codes stripped. When adding a feature, add assertions in the matching numbered section of `test-statusline.sh`.