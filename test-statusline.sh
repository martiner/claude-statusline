#!/bin/bash
# Tests for Claude Code statusline.sh
#
# Usage:
#   bash test-statusline.sh                            # run all tests
#   bash test-statusline.sh ~/.claude/statusline.sh    # custom script path
#
# Requires: bash, jq, git, date, mktemp. No network — the OAuth endpoint is
# never called; the cache is seeded directly. Tests use their own cache path
# and HOME, so they never touch your real statusline cache or credentials.

set -u

SCRIPT="${1:-./statusline.sh}"
if [ ! -f "$SCRIPT" ]; then
    echo "ERROR: script '$SCRIPT' not found. Pass the path as an argument." >&2
    exit 2
fi

# ── Sandbox ──────────────────────────────────────────────────────────────────
SANDBOX=$(mktemp -d -t statusline-test.XXXXXX)
export CLAUDE_STATUSLINE_CACHE="$SANDBOX/cache.json"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME"

# Temp git repo with a predictable branch name
REPO="$SANDBOX/myproject"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b feature/billing
    echo "x" > a.txt
    git add a.txt
    git commit -q -m "init"
) >/dev/null

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

strip_ansi() { sed 's/\x1B\[[0-9;]*[a-zA-Z]//g'; }

# Run the script with the given stdin, return output with ANSI codes stripped
run_script() {
    local stdin_json="$1"
    echo "$stdin_json" | HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null | strip_ansi
}

# Like run_script but with a fixed day-of-month / days-in-month (for the M segment)
run_with_date() {
    local day="$1" mdays="$2" stdin_json="$3"
    echo "$stdin_json" \
        | CLAUDE_STATUSLINE_TODAY="$day" CLAUDE_STATUSLINE_MONTH_DAYS="$mdays" \
          HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null | strip_ansi
}

# Seed the cache (simulated OAuth response). Empty string → delete the cache
# (simulates first run or a failed endpoint call).
set_cache() {
    if [ -z "$1" ]; then
        rm -f "$CLAUDE_STATUSLINE_CACHE"
    else
        echo "$1" > "$CLAUDE_STATUSLINE_CACHE"
        # Touch into the future so the script won't refresh (curl has no network)
        touch -d "+1 hour" "$CLAUDE_STATUSLINE_CACHE" 2>/dev/null \
            || touch -t "$(date -v +1H +%Y%m%d%H%M 2>/dev/null)" "$CLAUDE_STATUSLINE_CACHE" 2>/dev/null \
            || true
    fi
}

# assert_contains "test name" "expected substring" "actual output"
assert_contains() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        PASS=$((PASS+1))
        printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAIL=$((FAIL+1))
        printf '  %s✗%s %s\n' "$RED" "$RESET" "$name"
        printf '    %sexpected to contain:%s %s\n' "$DIM" "$RESET" "$expected"
        printf '    %sactual:%s              %s\n' "$DIM" "$RESET" "$actual"
    fi
}

# assert_matches "name" "regex (ERE)" "actual output"
# Use instead of assert_contains when the output has time-sensitive values that
# may drift by ±1 unit between setup and run (e.g. "2h15m" → "2h14m" on slow CI).
assert_matches() {
    local name="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS+1))
        printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAIL=$((FAIL+1))
        printf '  %s✗%s %s\n' "$RED" "$RESET" "$name"
        printf '    %spattern:%s %s\n' "$DIM" "$RESET" "$pattern"
        printf '    %sactual:%s  %s\n' "$DIM" "$RESET" "$actual"
    fi
}

# assert_not_contains "name" "forbidden substring" "output"
assert_not_contains() {
    local name="$1" forbidden="$2" actual="$3"
    if [[ "$actual" != *"$forbidden"* ]]; then
        PASS=$((PASS+1))
        printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAIL=$((FAIL+1))
        printf '  %s✗%s %s\n' "$RED" "$RESET" "$name"
        printf '    %sforbidden:%s %s\n' "$DIM" "$RESET" "$forbidden"
        printf '    %sactual:%s    %s\n' "$DIM" "$RESET" "$actual"
    fi
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
NOW=$(date +%s)
FIVE_RESET=$((NOW + 7200 + 900))      # 2h 15m
WEEK_RESET=$((NOW + 86400*4 + 3600*12)) # 4d 12h

# Cross-platform ISO timestamp formatting
iso_in_days() {
    local secs=$((NOW + $1 * 86400))
    date -u -d "@$secs" '+%Y-%m-%dT%H:%M:%S.000000+00:00' 2>/dev/null \
        || date -u -r "$secs" '+%Y-%m-%dT%H:%M:%S.000000+00:00'
}
MONTH_ISO=$(iso_in_days 12)

# ── Tests ────────────────────────────────────────────────────────────────────
echo "Statusline test suite"
echo "Script:  $SCRIPT"
echo "Sandbox: $SANDBOX"
echo ""

# ─── 1. Personal Max account ─────────────────────────────────────────────────
echo "[1] Personal Pro/Max account"
set_cache '{"five_hour":{"utilization":42.0},"seven_day":{"utilization":18.0},"extra_usage":{"is_enabled":false}}'
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":12.4},
  \"cost\":{\"total_cost_usd\":0.47},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":42,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":18,\"resets_at\":$WEEK_RESET}
  }
}")

assert_contains    "shows dir basename"              "myproject"               "$OUT"
assert_contains    "shows branch"                    "feature/billing"          "$OUT"
assert_contains    "shows model"                     "Claude Sonnet 4.6"        "$OUT"
assert_not_contains "no .effort: no bullet after model" "Claude Sonnet 4.6 • "  "$OUT"
assert_contains    "rounds ctx percentage"           "ctx 12%"                  "$OUT"
assert_contains    "shows cost"                      "s: \$0.47"                "$OUT"
assert_matches     "shows 5h window with time"       "5h: 42% • 2h1[45]m"       "$OUT"
assert_matches     "7d: elapsed + used + pct (rich)" "7d: 2d1[23]h used 18%"    "$OUT"
assert_matches     "7d: progress bar"                "█+░+"                     "$OUT"
assert_matches     "7d: remaining + left"            "4d1[12]h left"            "$OUT"
assert_matches     "7d: pace avg"                    "avg 7\\.[12]%/d"          "$OUT"
assert_matches     "7d: pace cap (%/d left)"         "1[78]\\.[1-4]%/d left"    "$OUT"
assert_not_contains "hides M segment (personal)"     "M:"                       "$OUT"

# ─── 1b. Pro after startup — placeholder rate_limits ─────────────────────────
echo ""
echo "[1b] Pro after startup (placeholder rate_limits → '?')"
set_cache ""  # no Enterprise cache

# Placeholder: pct=0, reset almost now → "5h ?" without time
NEAR_RESET=$((NOW + 5))
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":0},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":0,\"resets_at\":$NEAR_RESET},
    \"seven_day\":{\"used_percentage\":0,\"resets_at\":$NEAR_RESET}
  }
}")
assert_contains     "placeholder: '5h: ?'"        "5h: ?"   "$OUT"
assert_not_contains "placeholder: no '5h: 0%'"    "5h: 0%"  "$OUT"
assert_not_contains "placeholder: no '• now'"     "• now"   "$OUT"
assert_not_contains "placeholder: no '• 0m'"      "• 0m"    "$OUT"
assert_contains     "placeholder: '7d: ?'"        "7d: ?"   "$OUT"
assert_not_contains "placeholder: no '7d: 0%'"    "7d: 0%"  "$OUT"

# Real 0% in an active window (reset far off) → "5h ? • TIME" (mark, time kept)
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":0},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":0,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":0,\"resets_at\":$WEEK_RESET}
  }
}")
assert_matches      "0% active window: '5h: ? • 2h1[45]m'" "5h: \? • 2h1[45]m" "$OUT"
assert_matches      "0% active window: '7d: ? • 4d1[12]h'" "7d: \? • 4d1[12]h" "$OUT"
assert_not_contains "0% active window: no '5h: 0%'"        "5h: 0%"            "$OUT"

# ─── 1c. 7d rich form — edge cases ──────────────────────────────────────────
echo ""
echo "[1c] 7d rich form: edge cases"
set_cache ""

# 100% used — no cap rate (0% left / X days = 0%/d, hide that piece)
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":50,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":100,\"resets_at\":$WEEK_RESET}
  }
}")
assert_matches      "7d 100%: elapsed + used"            "7d: 2d1[23]h used 100%"  "$OUT"
assert_matches      "7d 100%: remaining + left"          "4d1[12]h left"           "$OUT"
assert_contains     "7d 100%: full bar"                  "██████████"              "$OUT"
assert_contains     "7d 100%: avg shown"                 "avg "                    "$OUT"
assert_not_contains "7d 100%: no '%/d left' (cap=0)"     "%/d left"                "$OUT"

# End of window (< 1 day left): cap = 91% / 0.7 day > 100%/d → clamp to ">100%/d"
WEEK_RESET_SOON=$((NOW + 3600*17))   # 17h left → elapsed 6d7h
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":50,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":9,\"resets_at\":$WEEK_RESET_SOON}
  }
}")
assert_contains     "7d end of window: avg shown"         "avg 1.4%/d"     "$OUT"
assert_contains     "7d end of window: cap clamped"       ">100%/d left"   "$OUT"
assert_not_contains "7d end of window: no rate >100"      "127"            "$OUT"

# 5h stays in simple form (pct + time, no used/left/pace)
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":42,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":18,\"resets_at\":$WEEK_RESET}
  }
}")
assert_matches      "5h: simple form"                    "5h: 42% • 2h1[45]m"      "$OUT"
assert_not_contains "5h: no 'used'"                      "5h: 42% used"            "$OUT"

# ─── 1d. Effort level (model • effort) ───────────────────────────────────────
echo ""
echo "[1d] Effort level in the model segment"
set_cache ""
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"effort\":{\"level\":\"xhigh\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains "effort shown after bullet"  "Opus 4.7 • xhigh"  "$OUT"

# ─── 2. Enterprise — monthly limit ───────────────────────────────────────────
echo ""
echo "[2] Enterprise (monthly limit only, no 5h/7d)"
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":34.0}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":22.0},
  \"cost\":{\"total_cost_usd\":1.20}
}")

assert_contains    "M: used days + pct"            "M: 17d used 34%"  "$OUT"
assert_contains    "M: progress bar"               "█"                "$OUT"
assert_contains    "M: left days"                  "14d left"         "$OUT"
assert_not_contains "hides 5h (Enterprise)"        "5h:"              "$OUT"
assert_not_contains "hides 7d (Enterprise)"        "7d:"              "$OUT"

# Dollar amounts — monthly_limit and used_credits are in cents.
# $63 spent + $237 left (of a $300 limit).
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":21.0,\"monthly_limit\":30000,\"used_credits\":6337}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains "M: \$ spent + days used + pct"  "M: \$63 17d used 21%"  "$OUT"
assert_contains "M: \$ left + days left"         "\$237 14d left"        "$OUT"

# No monthly_limit/used_credits → no $ amounts
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":21.0}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains    "no monthly_limit: days + pct"   "M: 17d used 21%"  "$OUT"
assert_not_contains "no monthly_limit: no \$ in M"  "M: \$"            "$OUT"

# ─── 2b. Daily averages in the M segment ─────────────────────────────────────
echo ""
echo "[2b] Daily averages (Enterprise)"

# Issue #3 example: May 17, 31 days, $67/$300 spent → avg $3.94/d, $16.64/d left
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":22.0,\"monthly_limit\":30000,\"used_credits\":6700,\"resets_at\":\"$MONTH_ISO\"}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains "average spent per day"           "avg \$3.94/d"     "$OUT"
assert_contains "average remaining per day"       "\$16.64/d left"   "$OUT"

# Last day of month (days_remaining = 0) → only 'avg $X/d', no cap '$Y/d left'
OUT=$(run_with_date 31 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains    "last day: avg shown"              "avg \$2.16/d" "$OUT"
assert_not_contains "last day: no '\$/d left'"        "/d left"      "$OUT"

# 100% used (left = 0) → only 'avg $X/d'
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":100.0,\"monthly_limit\":30000,\"used_credits\":30000}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains    "100% used: avg shown"             "avg \$17.65/d" "$OUT"
assert_not_contains "100% used: no '\$/d left'"       "/d left"       "$OUT"

# No monthly_limit → no daily averages and no $ amounts
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":22.0}}"
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_not_contains "no monthly_limit: no 'avg'"       "avg "    "$OUT"
assert_not_contains "no monthly_limit: no '/d left'"   "/d left" "$OUT"

# ─── 2c. Progress bar — 10 cells by pct ──────────────────────────────────────
echo ""
echo "[2c] Progress bar in the M segment"

# 49% → 5 full + 5 empty
set_cache '{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"utilization":49.0,"monthly_limit":30000,"used_credits":14900}}'
OUT=$(run_with_date 22 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains "49%: 5 full blocks"   "█████░░░░░"  "$OUT"

# 0% → all empty
set_cache '{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"utilization":0.0}}'
OUT=$(run_with_date 1 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains "0%: no full block"    "░░░░░░░░░░"  "$OUT"

# 100% → all full
set_cache '{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"utilization":100.0,"monthly_limit":30000,"used_credits":30000}}'
OUT=$(run_with_date 22 31 "{
  \"model\":{\"display_name\":\"Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.5}
}")
assert_contains "100%: all full"       "██████████"  "$OUT"

# ─── 3. Coloring by percentage ───────────────────────────────────────────────
echo ""
echo "[3] Color by usage percentage"
set_cache "{\"five_hour\":null,\"seven_day\":null,\"extra_usage\":{\"is_enabled\":true,\"utilization\":87.0,\"resets_at\":\"$MONTH_ISO\"}}"
RAW=$(echo "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":87.0},
  \"cost\":{\"total_cost_usd\":2.0}
}" | HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null)

# 87% should be red (ANSI 31)
if [[ "$RAW" == *$'\033[31mctx 87%'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s ctx 87%% is red\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s ctx 87%% should be red (ANSI 31)\n' "$RED" "$RESET"
fi
if [[ "$RAW" == *$'\033[31mM:'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s M 87%% is red\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s M 87%% should be red (ANSI 31)\n' "$RED" "$RESET"
fi

# 18% should be green (ANSI 32)
set_cache '{"five_hour":{"utilization":18.0},"seven_day":{"utilization":18.0},"extra_usage":{"is_enabled":false}}'
RAW=$(echo "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":18},
  \"cost\":{\"total_cost_usd\":0.1},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":18,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":18,\"resets_at\":$WEEK_RESET}
  }
}" | HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null)

if [[ "$RAW" == *$'\033[32mctx 18%'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s ctx 18%% is green\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s ctx 18%% should be green (ANSI 32)\n' "$RED" "$RESET"
fi

# 75% should be yellow (ANSI 33)
set_cache '{"five_hour":{"utilization":75.0},"seven_day":{"utilization":75.0},"extra_usage":{"is_enabled":false}}'
RAW=$(echo "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":75},
  \"cost\":{\"total_cost_usd\":0.1},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":75,\"resets_at\":$FIVE_RESET},
    \"seven_day\":{\"used_percentage\":75,\"resets_at\":$WEEK_RESET}
  }
}" | HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null)

if [[ "$RAW" == *$'\033[33mctx 75%'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s ctx 75%% is yellow\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s ctx 75%% should be yellow (ANSI 33)\n' "$RED" "$RESET"
fi

# ─── 3b. avg pace colored by burn rate vs. sustainable "left" rate ────────────
# elapsed is fixed at 2.5 days (WEEK_RESET = NOW + 4d12h, rd = 4.5), so
# ratio = avg/left = 1.8·u/(100−u): green <1.0 (u<35.7), yellow 1.0–1.5
# (u 35.7–45.5), red ≥1.5 (u≥45.5).
echo ""
echo "[3b] avg pace color (ratio avg/left)"
set_cache ""
avg_raw() {  # $1 = seven_day used_percentage → raw (un-stripped) output
    echo "{
      \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
      \"workspace\":{\"current_dir\":\"$REPO\"},
      \"context_window\":{\"used_percentage\":10},
      \"cost\":{\"total_cost_usd\":0.1},
      \"rate_limits\":{
        \"five_hour\":{\"used_percentage\":10,\"resets_at\":$FIVE_RESET},
        \"seven_day\":{\"used_percentage\":$1,\"resets_at\":$WEEK_RESET}
      }
    }" | HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null
}

RAW=$(avg_raw 18)   # avg 7.2 < left 18.2 → green (ANSI 32)
if [[ "$RAW" == *$'\033[32mavg 7'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s avg under pace is green\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s avg under pace should be green (ANSI 32)\n' "$RED" "$RESET"
fi

RAW=$(avg_raw 40)   # ratio 1.2 → yellow (ANSI 33)
if [[ "$RAW" == *$'\033[33mavg 16'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s avg slightly over pace is yellow\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s avg slightly over pace should be yellow (ANSI 33)\n' "$RED" "$RESET"
fi

RAW=$(avg_raw 70)   # ratio 4.2 → red (ANSI 31)
if [[ "$RAW" == *$'\033[31mavg 28'* ]]; then
    PASS=$((PASS+1)); printf '  %s✓%s avg far over pace is red\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s avg far over pace should be red (ANSI 31)\n' "$RED" "$RESET"
fi

# ─── 4. Git states ───────────────────────────────────────────────────────────
echo ""
echo "[4] Git detection"
set_cache ""  # no cache, so M doesn't bleed into these tests

# Detached HEAD → @<sha>
(cd "$REPO" && git checkout -q $(git rev-parse HEAD))
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains "detached HEAD → @<sha>" "@" "$OUT"

# Restore branch for the remaining tests
(cd "$REPO" && git checkout -q feature/billing)

# Outside a git repo
OUT=$(run_script '{
  "model":{"display_name":"Claude Sonnet 4.6"},
  "workspace":{"current_dir":"/tmp"},
  "context_window":{"used_percentage":5},
  "cost":{"total_cost_usd":0}
}')
assert_contains    "outside git repo: shows dir"   "tmp"             "$OUT"
assert_not_contains "outside git repo: no branch"  "feature/billing"  "$OUT"

# ─── 4b. Git worktree → project name instead of worktree slug ────────────────
echo ""
echo "[4b] Git worktree (issue #1)"
set_cache ""

# Setup: new git repo + worktree under .claude/worktrees/worktree-feat-X
WT_PROJ="$SANDBOX/parent-proj"
mkdir -p "$WT_PROJ"
(
    cd "$WT_PROJ"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git checkout -q -b main
    echo x > a.txt
    git add a.txt
    git commit -q -m "init"
    git worktree add -q -b feat-x ./.claude/worktrees/worktree-feat-x 2>/dev/null
) >/dev/null 2>&1

WT_DIR="$WT_PROJ/.claude/worktrees/worktree-feat-x"
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$WT_DIR\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains    "worktree: 1st item = project name" "parent-proj"          "$OUT"
assert_contains    "worktree: branch is 'worktree-feat-x@feat-x'" "worktree-feat-x@feat-x" "$OUT"

# Detached HEAD inside a worktree → wt-name@<sha> (distinguishable from a
# detached HEAD in the main repo, which is plain @<sha>)
(
    cd "$WT_PROJ"
    git worktree add -q --detach ./.claude/worktrees/worktree-det HEAD 2>/dev/null
) >/dev/null 2>&1
WT_DET="$WT_PROJ/.claude/worktrees/worktree-det"
DET_SHA=$(git -C "$WT_DET" rev-parse --short HEAD)
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$WT_DET\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains "detached worktree → wt-name@<sha>" "worktree-det@${DET_SHA}" "$OUT"

# Main repo (not a worktree) — basename(cwd) stays, no worktree prefix
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$WT_PROJ\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains "main repo: dir = basename(cwd)" "parent-proj" "$OUT"

# ─── 5. Working directory variants ───────────────────────────────────────────
echo ""
echo "[5] Working directory"

OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$FAKE_HOME\"},
  \"context_window\":{\"used_percentage\":0},
  \"cost\":{\"total_cost_usd\":0}
}")
assert_contains '$HOME → ~' "~ " "$OUT"

OUT=$(run_script '{"model":{"display_name":"x"},"context_window":{"used_percentage":0},"cost":{"total_cost_usd":0}}')
assert_contains "missing workspace → ?" "?" "$OUT"

# ─── 6. Time formatting ──────────────────────────────────────────────────────
echo ""
echo "[6] Remaining-time formatting"
set_cache ""

# Less than an hour → "Xm"
SHORT=$((NOW + 30*60))
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":0},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":50,\"resets_at\":$SHORT},
    \"seven_day\":{\"used_percentage\":10,\"resets_at\":$WEEK_RESET}
  }
}")
if echo "$OUT" | grep -qE '5h: 50% • (29|30)m'; then
    PASS=$((PASS+1)); printf '  %s✓%s under an hour: minutes only\n' "$GREEN" "$RESET"
else
    FAIL=$((FAIL+1)); printf '  %s✗%s under an hour: expected 29m/30m, output: %s\n' "$RED" "$RESET" "$OUT"
fi

# Reset in the past → segment hidden
PAST=$((NOW - 100))
OUT=$(run_script "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":0},
  \"cost\":{\"total_cost_usd\":0},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":50,\"resets_at\":$PAST},
    \"seven_day\":{\"used_percentage\":10,\"resets_at\":$WEEK_RESET}
  }
}")
assert_not_contains "reset in past: 5h hidden" "5h:" "$OUT"
assert_matches     "reset in future: 7d shown" "7d: 2d1[23]h used 10%" "$OUT"

# ─── 7. Resilience ───────────────────────────────────────────────────────────
echo ""
echo "[7] Resilience to missing data"

# Script must not crash on minimal JSON
OUT=$(run_script '{}')
assert_contains "empty JSON: shows fallback model" "?" "$OUT"

# Script must not crash when the cache is missing (Enterprise with broken OAuth)
set_cache ""
OUT=$(run_script "{
  \"model\":{\"display_name\":\"Claude Sonnet 4.6\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.10}
}")
assert_contains    "no cache: shows model"   "Claude Sonnet 4.6" "$OUT"
assert_not_contains "no cache: M hidden"     "M:"                 "$OUT"

# Cache with extra_usage but no resets_at → calendar days still computed from `date`
set_cache '{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"utilization":12.0}}'
OUT=$(run_with_date 17 31 "{
  \"model\":{\"display_name\":\"x\"},
  \"workspace\":{\"current_dir\":\"$REPO\"},
  \"context_window\":{\"used_percentage\":5},
  \"cost\":{\"total_cost_usd\":0.10}
}")
assert_contains "no resets_at: used days from calendar" "M: 17d used 12%"  "$OUT"
assert_contains "no resets_at: left days from calendar" "14d left"         "$OUT"

# ─── 8. Locale independence (comma decimal separator) ───────────────────────
echo ""
echo "[8] Comma-decimal locale (issue: ctx 0%, \$0,00)"
set_cache ""

# Find a locale whose decimal separator is a comma (cs_CZ, de_DE, …). Without
# the in-script LC_NUMERIC=C, such a locale makes `printf '%.0f' 42.5` fail
# ("invalid number") and awk emit commas. If none is installed (some minimal CI
# images), skip — we can't reproduce the bug, and asserting under a C locale
# would pass even on a regressed script (false green).
COMMA_LOCALE=""
for loc in cs_CZ.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 nl_NL.UTF-8 pt_BR.UTF-8; do
    if [ "$(LC_ALL= LC_NUMERIC="$loc" locale decimal_point 2>/dev/null)" = "," ]; then
        COMMA_LOCALE="$loc"; break
    fi
done

if [ -z "$COMMA_LOCALE" ]; then
    printf '  %s· skipped: no comma-decimal locale installed%s\n' "$DIM" "$RESET"
else
    OUT=$(echo "{
      \"model\":{\"display_name\":\"x\"},
      \"workspace\":{\"current_dir\":\"$REPO\"},
      \"context_window\":{\"used_percentage\":42.5},
      \"cost\":{\"total_cost_usd\":1.23}
    }" | LC_ALL= LC_NUMERIC="$COMMA_LOCALE" HOME="$FAKE_HOME" bash "$SCRIPT" 2>/dev/null | strip_ansi)
    assert_contains    "comma locale: ctx % still correct" "ctx 42%"  "$OUT"
    assert_contains    "comma locale: cost uses '.'"       "s: \$1.23" "$OUT"
    assert_not_contains "comma locale: no 'ctx 0%'"        "ctx 0%"   "$OUT"
    assert_not_contains "comma locale: no comma in cost"   "\$1,"     "$OUT"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '%s%d/%d tests passed%s\n' "$GREEN" "$PASS" "$TOTAL" "$RESET"
    exit 0
else
    printf '%s%d/%d tests failed%s\n' "$RED" "$FAIL" "$TOTAL" "$RESET"
    exit 1
fi
