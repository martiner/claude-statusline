#!/bin/bash
# Claude Code custom status line — see README.md for output format and features.

# Force a C numeric locale so the decimal separator is always '.'. Without this,
# a comma-decimal locale (e.g. cs_CZ, de_DE) makes `printf '%.0f' "42.5"` fail
# with "invalid number" (it expects "42,5") and makes awk emit "$0,00" — a wrong
# context % and cost. Set in-script so it works regardless of the launch command.
export LC_NUMERIC=C

input=$(cat)

# === Color by usage percentage ===
YELLOW_PCT=70
RED_PCT=85
color_by_pct() {
    local pct_int=${1%.*}; [ -z "$pct_int" ] && pct_int=0
    local text=$2
    if   [ "$pct_int" -ge "$RED_PCT" ];    then printf '\033[31m%s\033[0m' "$text"
    elif [ "$pct_int" -ge "$YELLOW_PCT" ]; then printf '\033[33m%s\033[0m' "$text"
    else                                       printf '\033[32m%s\033[0m' "$text"
    fi
}

# === Progress bar — 10 Unicode blocks (█/░), rounded to nearest tenth ===
make_bar() {
    local pct="$1" width=10 i bar=""
    local filled=$(( (pct * width + 50) / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 0 ))     && filled=0
    for ((i=0; i<filled;       i++)); do bar+="█"; done
    for ((i=0; i<width-filled; i++)); do bar+="░"; done
    printf '%s' "$bar"
}

# === Seconds → "2h15m" / "45m" / "4d12h" ===
format_duration() {
    local secs=$1
    if [ "$secs" -le 0 ]; then echo "now"; return; fi
    local days=$((  secs / 86400 ))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$((  (secs % 3600) / 60 ))
    if   [ "$days"  -gt 0 ]; then printf '%dd%dh'   "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then printf '%dh%02dm' "$hours" "$mins"
    else                          printf '%dm'      "$mins"
    fi
}

# === Epoch → local "09:35" ===
format_clock() {
    if [ "$(uname)" = "Darwin" ]; then date -r "$1" +%H:%M
    else                                date -d "@$1" +%H:%M
    fi
}

# === Parse stdin JSON ===
IFS=$'\t' read -r model effort cwd ctx_pct cost five_pct five_reset week_pct week_reset < <(
    echo "$input" | jq -r '
        [
            .model.display_name                       // "?",
            (.effort.level                            // "-"),
            .workspace.current_dir                    // "-",
            (.context_window.used_percentage          // 0),
            (.cost.total_cost_usd                     // 0),
            (.rate_limits.five_hour.used_percentage   // 0),
            (.rate_limits.five_hour.resets_at         // 0),
            (.rate_limits.seven_day.used_percentage   // 0),
            (.rate_limits.seven_day.resets_at         // 0)
        ] | @tsv
    ' | tr -d '\r'
)

# Sanitize numeric fields — jq sometimes emits empty strings for null
[ -z "$five_reset" ] && five_reset=0
[ -z "$week_reset" ] && week_reset=0
[ -z "$ctx_pct" ]    && ctx_pct=0
[ -z "$cost" ]       && cost=0
[ -z "$five_pct" ]   && five_pct=0
[ -z "$week_pct" ]   && week_pct=0

# === Monthly limit from /api/oauth/usage (Enterprise) ===
# Cached for 60s to stay within the status line's latency budget and the
# endpoint's own rate limit.
USAGE_CACHE="${CLAUDE_STATUSLINE_CACHE:-$HOME/.claude/statusline-usage.json}"
USAGE_CACHE_TTL="${CLAUDE_STATUSLINE_CACHE_TTL:-60}"

fetch_usage() {
    local creds token response
    # macOS: keychain; Linux/WSL: plain file
    if [ "$(uname)" = "Darwin" ]; then
        creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
    else
        [ -r "$HOME/.claude/.credentials.json" ] || return 1
        creds=$(<"$HOME/.claude/.credentials.json")
    fi
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null | tr -d '\r')
    [ -z "$token" ] && return 1

    response=$(curl -s --max-time 2 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" 2>/dev/null) || return 1

    # Validate response — must contain at least one expected field
    echo "$response" | jq -e '.five_hour or .extra_usage' >/dev/null 2>&1 || return 1
    echo "$response" > "$USAGE_CACHE"
}

# stat has different flags on macOS vs Linux
cache_age() {
    local mtime
    if [ "$(uname)" = "Darwin" ]; then
        mtime=$(stat -f %m "$USAGE_CACHE" 2>/dev/null) || return 1
    else
        mtime=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null) || return 1
    fi
    echo $(( $(date +%s) - mtime ))
}

# Refresh cache if missing or older than TTL
if [ ! -f "$USAGE_CACHE" ] || [ "$(cache_age)" -gt "$USAGE_CACHE_TTL" ]; then
    fetch_usage 2>/dev/null
fi

# Read extra_usage (monthly) — only if is_enabled. monthly_limit and
# used_credits are in cents, converted to USD below.
month_pct=""; money_used=""; money_left=""; month_daily=""; month_daily_code=""
day_now=""; days_remaining=""
spent_pct=""
if [ -f "$USAGE_CACHE" ]; then
    # Can't use `read` with IFS=$'\t': bash collapses adjacent tabs (tab is a
    # whitespace IFS char) so an empty field gets lost. `mapfile` would be
    # cleaner but isn't in bash 3.2 (macOS default), so read field-per-line.
    m_fields=()
    while IFS= read -r line; do
        m_fields+=("$line")
    done < <(
        jq -r '
            (.extra_usage.is_enabled    // false),
            (.extra_usage.utilization   // ""),
            (.extra_usage.monthly_limit // ""),
            (.extra_usage.used_credits  // ""),
            (.extra_usage.currency      // "USD"),
            (.five_hour != null or .seven_day != null)
        ' "$USAGE_CACHE" 2>/dev/null | tr -d '\r'
    )
    m_enabled="${m_fields[0]:-}"
    m_util="${m_fields[1]:-}"
    m_limit="${m_fields[2]:-}"
    m_used="${m_fields[3]:-}"
    m_windows="${m_fields[5]:-false}"
    # Amounts are billed in the account's currency, not always USD.
    case "${m_fields[4]:-USD}" in
        USD|"") cur="$"  ;;
        EUR)    cur="€"  ;;
        GBP)    cur="£"  ;;
        *)      cur="${m_fields[4]} " ;;  # unknown code as prefix: "CZK 250"
    esac
    if [ "$m_enabled" = "true" ]; then
        # Rolling windows mean a subscription plan: extra_usage is then just the
        # pay-as-you-go credit cap that kicks in past the plan limits, so only
        # "$X left" is shown. Enterprise has no windows — the monthly budget is
        # the whole budget, and gets the full form with bar and pace.
        [ "$m_windows" = "false" ] && month_pct=${m_util%.*}

        # Money amounts (cents → whole units, rounded).
        if [ -n "$m_limit" ] && [ -n "$m_used" ] \
           && [ "$m_limit" != "null" ] && [ "$m_used" != "null" ]; then
            money_used=$(awk -v c="$cur" -v u="$m_used" 'BEGIN{printf "%s%.0f", c, u/100}')
            money_left=$(awk -v c="$cur" -v u="$m_used" -v l="$m_limit" \
                'BEGIN{r = (l - u) / 100; if (r < 0) r = 0; printf "%s%.0f", c, r}')
            spent_pct=$(awk -v u="$m_used" -v l="$m_limit" \
                'BEGIN{printf "%d", (l > 0 ? u * 100 / l : 0)}')
        fi

        if [ -n "$month_pct" ]; then
            # Calendar days: elapsed = day_now, remaining = month_days - day_now.
            # Env overrides exist for deterministic tests; normally read from `date`.
            day_now="${CLAUDE_STATUSLINE_TODAY:-$(date +%-d)}"
            if [ -n "${CLAUDE_STATUSLINE_MONTH_DAYS:-}" ]; then
                month_days="$CLAUDE_STATUSLINE_MONTH_DAYS"
            elif [ "$(uname)" = "Darwin" ]; then
                month_days=$(date -v1d -v+1m -v-1d +%-d 2>/dev/null)
            else
                month_days=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%-d 2>/dev/null)
            fi
            days_remaining=$(( month_days - day_now ))
            [ "$days_remaining" -lt 0 ] && days_remaining=0

            # Daily pace, only with both money amounts. Colored like the 7d
            # pace: by burn rate vs. the sustainable "left" rate (green <1.0,
            # yellow <1.5, red ≥1.5). awk emits the ANSI code as a leading
            # tab-separated field; the short form (month end or budget gone)
            # has no "left" rate, so the code is empty and the color falls
            # back to the month fill.
            if [ -n "$money_used" ]; then
                month_daily_raw=$(awk -v c="$cur" -v u="$m_used" -v l="$m_limit" \
                                  -v e="$day_now" -v r="$days_remaining" \
                    'BEGIN{
                        if (e <= 0) e = 1
                        spent = u / 100 / e
                        if (l > u && r > 0) {
                            left = (l - u) / 100 / r
                            ratio = spent / left
                            code = 32
                            if      (ratio >= 1.5) code = 31
                            else if (ratio >= 1.0) code = 33
                            printf "%d\tavg %s%.2f/d • %s%.2f/d left", code, c, spent, c, left
                        } else {
                            printf "\tavg %s%.2f/d", c, spent
                        }
                    }')
                month_daily_code="${month_daily_raw%%$'\t'*}"
                month_daily="${month_daily_raw#*$'\t'}"
            fi
        fi
    fi
fi

# === Working directory ===
# In a git worktree (e.g. .claude/worktrees/worktree-X) basename(cwd) is just
# the worktree slug, not the project. Detect via git_dir != common_dir and use
# basename(dirname(common_dir)) = the main repo's name.
if [ -z "$cwd" ] || [ "$cwd" = "-" ]; then
    dir_display="?"
elif [ "$cwd" = "$HOME" ]; then
    dir_display="~"
else
    dir_display=$(basename "$cwd")
    if [ -d "$cwd" ]; then
        git_dir=$(git -C "$cwd" --no-optional-locks rev-parse --absolute-git-dir 2>/dev/null)
        common_raw=$(git -C "$cwd" --no-optional-locks rev-parse --git-common-dir 2>/dev/null)
        if [ -n "$git_dir" ] && [ -n "$common_raw" ]; then
            common_abs=$(cd "$cwd" 2>/dev/null && cd "$common_raw" 2>/dev/null && pwd)
            if [ -n "$common_abs" ] && [ "$git_dir" != "$common_abs" ]; then
                dir_display=$(basename "$(dirname "$common_abs")")
                is_worktree=1
                # git keeps the worktree under .git/worktrees/<name>; basename of
                # the per-worktree git dir is that name (robust even if cwd is a subdir).
                worktree_name=$(basename "$git_dir")
            fi
        fi
    fi
fi

# === Git branch ===
# branch holds the bare ref (branch name, or short SHA when detached); is_detached
# distinguishes the two so the @-prefix convention only marks a real detached HEAD.
branch=""
is_detached=""
if [ -n "$cwd" ] && [ "$cwd" != "-" ] && [ -d "$cwd" ]; then
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
        [ -n "$branch" ] && is_detached=1
    fi
fi
# In a worktree, prefix the worktree name so it's distinguishable from the main
# repo: wt-name@branch, or wt-name@<sha> when detached. Outside a worktree, a
# detached HEAD keeps the plain @<sha> form.
if [ -n "$is_worktree" ] && [ -n "$worktree_name" ]; then
    if [ -n "$branch" ]; then
        branch="${worktree_name}@${branch}"
    else
        branch="$worktree_name"
    fi
elif [ -n "$is_detached" ]; then
    branch="@${branch}"
fi

# === Build output — segments are appended conditionally ===
now=$(date +%s)
ctx_pct_int=$(printf '%.0f' "$ctx_pct")
cost_fmt=$(printf 's: $%.2f' "$cost")
sep=$(printf '\033[90m | \033[0m')

parts=()
bullet=$(printf '\033[90m • \033[0m')
dir_part=$(printf '\033[1;36m%s\033[0m' "$dir_display")
if [ -n "$branch" ]; then
    dir_part="${dir_part}${bullet}$(printf '\033[35m%s\033[0m' "$branch")"
fi
parts+=("$dir_part")
if [ -n "$effort" ] && [ "$effort" != "-" ]; then
    parts+=("$(printf '\033[90m%s • %s\033[0m' "$model" "$effort")")
else
    parts+=("$(printf '\033[90m%s\033[0m' "$model")")
fi
# group ctx (context fill, cleared by /clear) and session cost (cumulative, survives /clear) with a bullet
session_part="$(color_by_pct "$ctx_pct" "ctx ${ctx_pct_int}%")${bullet}$(printf '\033[36m%s\033[0m' "$cost_fmt")"
parts+=("$session_part")

# 5h/7d windows — only if resets_at is in the future (else Enterprise or inactive).
# Right after CC starts the server often sends a placeholder (pct=0, reset≈now);
# show "?" instead of a misleading "0%", and drop the time too if reset is <60s away.
#
# The 4th arg `period_secs` (7d only) switches to the rich form. The function
# pushes 1-2 segments straight into parts[] (rich form adds pace as a 2nd segment).
add_window_segment() {
    local prefix="$1" pct="$2" reset="$3" period="${4:-}"
    [ "$reset" -gt "$now" ] 2>/dev/null || return
    local secs=$(( reset - now ))
    local pct_int
    pct_int=$(printf '%.0f' "$pct" 2>/dev/null) || pct_int=0
    if [ "$pct_int" -eq 0 ]; then
        local label="$prefix: ?"
        [ "$secs" -ge 60 ] && label="$label • $(format_duration "$secs")"
        parts+=("$(printf '\033[90m%s\033[0m' "$label")")
        return
    fi
    if [ -n "$period" ]; then
        # Rich form: bar in the middle visually separates used (left) / left (right).
        local elapsed=$(( period - secs ))
        [ "$elapsed" -lt 0 ] && elapsed=0
        local pct_left=$(( 100 - pct_int ))
        [ "$pct_left" -lt 0 ] && pct_left=0
        local bar; bar=$(make_bar "$pct_int")
        local label="$prefix: $(format_duration "$elapsed") used ${pct_int}% ${bar} $(format_duration "$secs") left"
        parts+=("$(color_by_pct "$pct" "$label")")

        # Daily pace as a separate segment (split by the main `sep`, not a bullet).
        # When less than ~a day remains, dividing the remaining budget by a tiny
        # sliver of time overflows past 100%/d (sub-day rate degenerates) → clamp.
        # The pace is colored by burn rate vs. the sustainable "left" rate, not by
        # window fill: green when avg < left (under pace), yellow up to 1.5× over,
        # red at ≥1.5× or when the window is full (no budget left). awk emits the
        # ANSI code as a leading tab-separated field so the float ratio math stays
        # out of bash.
        local pace_raw pace_code pace
        pace_raw=$(awk -v u="$pct_int" -v l="$pct_left" -v e="$elapsed" -v r="$secs" \
            'BEGIN{
                ed = e / 86400
                rd = r / 86400
                shown = 0
                pace = ""
                if (ed >= 0.05) { pace = sprintf("avg %.1f%%/d", u/ed); shown = 1 }
                if (rd > 0 && l > 0) {
                    if (shown) pace = pace " • "
                    lr = l / rd
                    if (lr > 100) pace = pace ">100%/d left"
                    else          pace = pace sprintf("%.1f%%/d left", lr)
                }
                code = 32
                if (shown) {
                    if (l <= 0) code = 31
                    else {
                        ratio = (u / ed) / (l / rd)
                        if      (ratio >= 1.5) code = 31
                        else if (ratio >= 1.0) code = 33
                    }
                }
                printf "%d\t%s", code, pace
            }')
        pace_code="${pace_raw%%$'\t'*}"
        pace="${pace_raw#*$'\t'}"
        # Trim ".0%" to "%": 20.0%/d → 20%/d, 7.7%/d stays.
        pace="${pace//.0%/%}"
        [ -n "$pace" ] && parts+=("$(printf '\033[%sm%s\033[0m' "$pace_code" "$pace")")
        return
    fi
    # Simple form (5h): pct + time remaining, plus the wall-clock reset time
    # once the window is in the red.
    local label="$prefix: ${pct_int}% • $(format_duration "$secs")"
    [ "${pct%.*}" -ge "$RED_PCT" ] 2>/dev/null && label="$label • $(format_clock "$reset")"
    parts+=("$(color_by_pct "$pct" "$label")")
}
add_window_segment "5h" "$five_pct" "$five_reset"
add_window_segment "7d" "$week_pct" "$week_reset" 604800

# Monthly limit. Enterprise (utilization present) gets the full form; $ amounts
# and daily pace only if the cache has both monthly_limit and used_credits.
# Pro (no utilization) gets just the extra-usage credits left.
if [ -n "$month_pct" ]; then
    bar=$(make_bar "$month_pct")
    label="M:"
    [ -n "$money_used" ] && label="${label} ${money_used}"
    label="${label} ${day_now}d used ${month_pct}% ${bar}"
    [ -n "$money_left" ] && label="${label} ${money_left}"
    label="${label} ${days_remaining}d left"
    parts+=("$(color_by_pct "$month_pct" "$label")")
    if [ -n "$month_daily" ]; then
        if [ -n "$month_daily_code" ]; then
            parts+=("$(printf '\033[%sm%s\033[0m' "$month_daily_code" "$month_daily")")
        else
            parts+=("$(color_by_pct "$month_pct" "$month_daily")")
        fi
    fi
elif [ -n "$money_left" ]; then
    parts+=("$(color_by_pct "$spent_pct" "M: ${money_left} left")")
fi

# Join segments with the separator
output="${parts[0]}"
for ((i=1; i<${#parts[@]}; i++)); do
    output="${output}${sep}${parts[i]}"
done
printf '%s\n' "$output"
