# Claude Code custom statusline

A custom statusline for the Claude Code CLI that shows your working directory, git branch, model, context usage, session cost, and — most importantly — your **rate-limit budgets** at a glance.

It supports both personal Pro/Max accounts (5h and 7d rolling windows) and Enterprise accounts (monthly limit).

## Examples

**Personal Pro/Max account:**

```
myproject • feature/billing | Claude Sonnet 4.6 • high | ctx 12% • s: $0.47 | 5h: 42% • 2h15m | 7d: 3d6h used 25% ███░░░░░░░ 3d18h left | avg 7.7%/d • 20%/d left
```

**Enterprise account:**

```
myproject • feature/billing | Claude Opus 4.7 • xhigh | ctx 22% • s: $1.20 | M: $67 17d used 22% ██░░░░░░░░ $233 14d left | avg $3.94/d • $16.64/d left
```

## Features

- **Directory & branch** — basename of the working directory (`$HOME` shown as `~`), plus the current git branch. Inside a git worktree the main repo's name is shown as the directory, and the branch is prefixed with the worktree name so it's distinguishable from the main repo: `wt-name@branch`, or `wt-name@<sha>` when detached. Detached HEAD in the main repo shows as `@<sha>`; outside a repo the branch is omitted.
- **Model & effort** — model name, optionally followed by the effort level (`model • high`, `model • xhigh`, …) when available.
- **Context & cost** — current context window usage and session cost. `/clear` empties the context but does **not** reset the session cost, which keeps accumulating until you start a new session.
- **5h window** (Pro/Max) — `5h: N% • TIME` showing percent used and time until reset.
- **7d window** (Pro/Max) — a rich indicator over the rolling 7-day window: `7d: ELAPSED used N% █████░░░░░ REMAINING left`.
- **Monthly limit** (Enterprise) — `M: $spent Nd used PCT% █████░░░░░ $remaining Md left`, sourced from the OAuth usage endpoint (see [caveats](#caveats)).
- **Progress bar** — 10 Unicode blocks that split *used* from *left*, visually representing the percentage (shown in the 7d and monthly segments).
- **Daily pace** — answers "how much do I have per day" for the current billing window: `avg` is your current burn rate; `%/d left` (or `$/d left`) is the daily ceiling you can stay under to make it to the reset. The `avg` segment is colored by pace, not by fill: green while `avg` stays under the ceiling, yellow up to 1.5× over it, red beyond that (or once the budget is spent).
- **Color coding** — green below 70%, yellow 70–84%, red at 85%+ on context, 5h, 7d, and monthly values (the 7d `avg` pace uses the pace rule above instead).
- **Graceful degradation** — segments that don't apply to your account type are hidden. After Claude Code starts, before real data arrives, windows show `?` instead of a misleading `0%`.

## Installation

Both options end with `~/.claude/statusline.sh` in place and the same `settings.json` entry; pick based on whether you want to track upstream updates.

### Option A — clone and symlink (recommended, keeps the script updatable)

Clone the repo and symlink the script into `~/.claude/`:

```bash
git clone https://github.com/martiner/claude-statusline.git
ln -s "$(pwd)/claude-statusline/statusline.sh" ~/.claude/statusline.sh
```

To update later, just `git pull` in the clone — the symlink picks up the new version automatically:

```bash
git -C claude-statusline pull
```

### Option B — copy the file

Copy `statusline.sh` to `~/.claude/statusline.sh`. Simpler, but updates mean re-copying the file by hand.

### Wire it up

With either option, add the following to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### Requirements

- `jq`, `curl`, `git`, `date`
- Claude Code **v1.2.80+** (needed for the `rate_limits` field in the stdin JSON)
- macOS, Linux/WSL, or Windows. On macOS the OAuth token is read from the Keychain (`security find-generic-password -s "Claude Code-credentials"`); on Linux/WSL/Windows from `~/.claude/.credentials.json`.
- On native Windows the script runs under the Git Bash that ships with Git for Windows, and `jq` (e.g. installed via `winget`) must be on `PATH`.

## Configuration

Behavior can be tuned with environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_STATUSLINE_CACHE` | `$HOME/.claude/statusline-usage.json` | Cache file for the monthly usage lookup |
| `CLAUDE_STATUSLINE_CACHE_TTL` | `60` | Cache lifetime in seconds |
| `CLAUDE_STATUSLINE_TODAY` | — | Override the day-of-month (tests only) |
| `CLAUDE_STATUSLINE_MONTH_DAYS` | — | Override days-in-month (tests only) |

If you have a Nerd Font installed, you can add a branch icon () before the branch name in the script (it was removed by default because it renders as a blank glyph without the font).

## Tests

`test-statusline.sh` contains 71 fully isolated tests across 12 sections (own sandbox via `mktemp -d`, fake `HOME`, no network calls):

```bash
bash test-statusline.sh ~/.claude/statusline.sh
```

Coverage includes personal and Enterprise layouts, the post-startup placeholder state, color thresholds, git detached/worktree handling, time formatting, and robustness against empty or malformed input.

## Caveats

1. **The monthly usage endpoint is undocumented.** The `M:` segment reads from `https://api.anthropic.com/api/oauth/usage` (field `extra_usage`), an endpoint the community reverse-engineered from the Claude Code binary. Anthropic may change it at any time. There is a feature request ([issue #29300](https://github.com/anthropics/claude-code/issues/29300)) to expose monthly usage officially in the stdin JSON — switch to that once available.

2. **Values are in cents, not USD.** `extra_usage.monthly_limit` and `used_credits` are in cents despite an adjacent `currency: "USD"` field; the script divides by 100. A $300/month Enterprise limit therefore appears as `30000`.

3. **The statusline has a ~300ms budget in Claude Code.** Hence the 60s cache and 2s curl timeout — the endpoint is actually called at most once per minute, otherwise the value is served from cache.

4. **`/api/oauth/usage` is itself rate-limited** (HTTP 429 with `retry-after` ~60s when called too often). The 60s cache keeps calls under that limit in addition to saving latency.

