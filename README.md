# Claude Code custom statusline

A custom statusline for the Claude Code CLI that shows your working directory, git branch, model, context usage, session cost, and — most importantly — your **rate-limit budgets** at a glance.

It supports both personal Pro/Max accounts (5h and 7d rolling windows) and Enterprise accounts (monthly limit). Pro/Max accounts with pay-as-you-go extra usage enabled also get the remaining credits.

## Examples

**Personal Pro/Max account:**

```
myproject • feature/billing | Claude Sonnet 4.6 • high | ctx 12% • cache 4m • s: $0.47 | 5h: 42% • 2h15m | 7d: 3d6h used 25% ███░░░░░░░ 3d18h left | avg 7.7%/d • 20%/d left
```

**Enterprise account:**

```
myproject • feature/billing | Claude Opus 4.7 • xhigh | ctx 22% • cache 52m • s: $1.20 | M: $67 17d used 22% ██░░░░░░░░ $233 14d left | avg $3.94/d • $16.64/d left
```

## Features

- **Directory & branch** — basename of the working directory (`$HOME` shown as `~`), plus the current git branch. Inside a git worktree the main repo's name is shown as the directory, and the branch is prefixed with the worktree name so it's distinguishable from the main repo: `wt-name@branch`, or `wt-name@<sha>` when detached. Detached HEAD in the main repo shows as `@<sha>`; outside a repo the branch is omitted.
- **Model & effort** — model name, optionally followed by the effort level (`model • high`, `model • xhigh`, …) when available.
- **Context & cost** — current context window usage, time until the prompt cache expires, and session cost. The cache expiry comes from `prompt_cache.expires_at` (Claude Code v2.1.251+); once it passes, `cache expired` means the next prompt re-writes the whole context at full price. Claude Code re-renders the status line by itself at that moment, but while the session is idle the minutes in between only count down if you set `refreshInterval` (e.g. `60`) in the `statusLine` settings. `/clear` empties the context but does **not** reset the session cost, which keeps accumulating until you start a new session.
- **5h window** (Pro/Max) — `5h: N% • TIME` showing percent used and time until reset. In the red (85%+) the reset clock time is appended too: `5h: 90% • 2h05m • 09:35`.
- **7d window** (Pro/Max) — a rich indicator over the rolling 7-day window: `7d: ELAPSED used N% █████░░░░░ REMAINING left`.
- **Monthly limit** (Enterprise) — `M: $spent Nd used PCT% █████░░░░░ $remaining Md left`, sourced from the OAuth usage endpoint (see [caveats](#caveats)).
- **Extra usage** (Pro/Max with pay-as-you-go credits) — same endpoint. Here the monthly amount is only the credit cap that applies once you're past the plan limits, so a bar and a daily pace over it would be misleading; only the remaining credits are shown: `M: $10 left`. Amounts follow the account's billing currency (`$`, `€`, `£`).
- **Progress bar** — 10 Unicode blocks that split *used* from *left*, visually representing the percentage (shown in the 7d and monthly segments).
- **Daily pace** — answers "how much do I have per day" for the current billing window: `avg` is your current burn rate; `%/d left` (or `$/d left`) is the daily ceiling you can stay under to make it to the reset. The `avg` segment is colored by pace, not by fill: green while `avg` stays under the ceiling, yellow up to 1.5× over it, red beyond that (or once the budget is spent).
- **Color coding** — green below 70%, yellow 70–84%, red at 85%+ on context, 5h, 7d, and monthly values, and on the prompt cache by the share of its TTL used up (on a 1h TTL: yellow from 18m left, red from 9m left and once expired). The `avg` pace segments use the pace rule above instead.
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
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 60
  }
}
```

`refreshInterval` is optional. Claude Code re-runs the script on events (a new assistant message, `/compact`, a rate-limit reset, the prompt cache expiring, …) but not while the session is idle; the interval adds a re-run every N seconds, so the time-based values (cache expiry, 5h/7d time left, pace) keep counting down and a branch switched in another terminal shows up. It doesn't refresh the stdin data itself (context %, cost, window %), which only changes with events. Everything is shown with minute precision, so a value below `60` gains nothing. See [caveats](#caveats) for its effect on the usage endpoint.

### Requirements

- `jq`, `curl`, `git`, `date`
- Claude Code **v1.2.80+** (needed for the `rate_limits` field in the stdin JSON); **v2.1.251+** for the prompt cache expiry (the `prompt_cache` field), older versions simply omit that segment
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

`test-statusline.sh` contains fully isolated tests (own sandbox via `mktemp -d`, fake `HOME`, no network calls):

```bash
bash test-statusline.sh ~/.claude/statusline.sh
```

Coverage includes personal and Enterprise layouts, the post-startup placeholder state, color thresholds, git detached/worktree handling, time formatting, and robustness against empty or malformed input.

## Caveats

1. **The monthly usage endpoint is undocumented.** The `M:` segment reads from `https://api.anthropic.com/api/oauth/usage` (field `extra_usage`), an endpoint the community reverse-engineered from the Claude Code binary. Anthropic may change it at any time. There is a feature request ([issue #29300](https://github.com/anthropics/claude-code/issues/29300)) to expose monthly usage officially in the stdin JSON — switch to that once available.

2. **Values are in cents.** `extra_usage.monthly_limit` and `used_credits` are in cents; the script divides by 100. A $300/month Enterprise limit therefore appears as `30000`. The unit is the account's `currency`, which is not always `USD` (a EUR-billed account reports `EUR`) — `USD`/`EUR`/`GBP` render as `$`/`€`/`£`, any other code is used as-is (`CZK 250`). The session cost (`s:`) comes from the stdin JSON's `total_cost_usd` and is always in dollars.

3. **The statusline has a ~300ms budget in Claude Code.** Hence the 60s cache and 2s curl timeout — the endpoint is actually called at most once per minute, otherwise the value is served from cache.

4. **`/api/oauth/usage` is itself rate-limited** (HTTP 429 with `retry-after` ~60s when called too often). The 60s cache keeps calls under that limit in addition to saving latency.

5. **`refreshInterval` keeps the endpoint busy while idle.** Without it the script only runs on events, so an idle session makes no calls. With `refreshInterval` ≤ 60 the cache expires between runs and the endpoint is called about once a minute for as long as Claude Code is open. Sessions share the cache file, so several open sessions don't multiply the calls. Use a longer interval (e.g. `300`) if that matters; the cache expiry still turns to `cache expired` on time, since Claude Code re-renders at that moment regardless.

