#!/bin/bash
# Claude Code Statusline — @waelsaid/claude-statusline
# Two-line display:
#   Line 1: session info (from stdin JSON)
#   Line 2: quota bars (from Anthropic OAuth API)

# ── ANSI colors ──
R='\033[0m'
GRAY='\033[90m'
BLUE='\033[94m'
GREEN='\033[92m'
YELLOW='\033[93m'
ORANGE='\033[38;5;208m'
RED='\033[91m'
CYAN='\033[96m'
WHITE='\033[97m'
DIM='\033[2m'

# ── Read stdin JSON ──
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
ctx_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // "0"')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // "0"')

# ── Helpers ──
format_duration() {
  local ms="$1"
  [ -z "$ms" ] && return
  local total_sec=$((ms / 1000))
  local h=$((total_sec / 3600))
  local m=$(( (total_sec % 3600) / 60 ))
  local s=$((total_sec % 60))
  if [ "$h" -gt 0 ]; then
    printf '%dh %dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm %ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

color_for_pct() {
  local pct="$1"
  if [ "$pct" -lt 50 ]; then
    echo "$GREEN"
  elif [ "$pct" -lt 70 ]; then
    echo "$YELLOW"
  elif [ "$pct" -lt 90 ]; then
    echo "$ORANGE"
  else
    echo "$RED"
  fi
}

progress_bar() {
  local pct="$1"
  local color="$2"
  local filled=$(( (pct + 5) / 10 ))
  [ "$filled" -gt 10 ] && filled=10
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((10 - filled))
  local bar=""
  local i
  for i in $(seq 1 "$filled"); do bar="${bar}●"; done
  for i in $(seq 1 "$empty"); do bar="${bar}○"; done
  printf '%b%s%b' "$color" "$bar" "$R"
}

time_until() {
  local iso="$1"
  [ -z "$iso" ] && return
  local now reset_epoch diff
  now=$(date +%s)
  # macOS date
  reset_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%%.*}" +%s 2>/dev/null)
  # Linux fallback
  if [ -z "$reset_epoch" ]; then
    reset_epoch=$(date -d "$iso" +%s 2>/dev/null)
  fi
  [ -z "$reset_epoch" ] && return
  diff=$((reset_epoch - now))
  [ "$diff" -le 0 ] && { printf 'now'; return; }
  local h=$((diff / 3600))
  local m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 24 ]; then
    local d=$((h / 24))
    h=$((h % 24))
    printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# ── Resolve OAuth token ──
get_oauth_token() {
  # 1. Environment variable
  if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "$CLAUDE_CODE_OAUTH_TOKEN"
    return
  fi
  # 2. macOS Keychain
  local keychain_json
  keychain_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [ -n "$keychain_json" ]; then
    local token
    token=$(echo "$keychain_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      echo "$token"
      return
    fi
  fi
  # 3. Credentials file
  local creds_file="$HOME/.claude/.credentials.json"
  if [ -f "$creds_file" ]; then
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    if [ -n "$token" ]; then
      echo "$token"
      return
    fi
  fi
  # 4. Linux secret-tool
  local secret_json
  secret_json=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
  if [ -n "$secret_json" ]; then
    local token
    token=$(echo "$secret_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      echo "$token"
      return
    fi
  fi
}

# ── Fetch usage with caching (60s TTL) ──
CACHE_DIR="/tmp/claude"
CACHE_FILE="$CACHE_DIR/statusline-usage-cache.json"
CACHE_TTL=60

fetch_usage() {
  mkdir -p "$CACHE_DIR"

  # Check cache freshness
  if [ -f "$CACHE_FILE" ]; then
    local now file_age mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null)
    [ -z "$mtime" ] && mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null)
    if [ -n "$mtime" ]; then
      file_age=$((now - mtime))
      if [ "$file_age" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        return
      fi
    fi
  fi

  local token
  token=$(get_oauth_token)
  [ -z "$token" ] && return

  local response
  response=$(curl -s --max-time 3 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.1.34" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  if echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
    echo "$response" > "$CACHE_FILE"
    echo "$response"
  fi
}

# ══════════════════════════════════════
#  LINE 1: Session Info
# ══════════════════════════════════════

dir_name=$(basename "$cwd")

# Git branch + dirty state
branch=""
dirty=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    if ! git -C "$cwd" --no-optional-locks diff --quiet HEAD 2>/dev/null; then
      dirty="*"
    fi
  fi
fi

line1=""

# Directory
line1="${line1}$(printf '%b📁 %s%b' "$BLUE" "$dir_name" "$R")"

# Model
if [ -n "$model" ]; then
  line1="${line1}$(printf ' %b│%b %b🤖 %s%b' "$GRAY" "$R" "$CYAN" "$model" "$R")"
fi

# Git branch
if [ -n "$branch" ]; then
  local_dirty=""
  [ -n "$dirty" ] && local_dirty="$(printf '%b%s%b' "$RED" "*" "$R")"
  line1="${line1}$(printf ' %b│%b %b🌿 %s%b%s' "$GRAY" "$R" "$GREEN" "$branch" "$R" "$local_dirty")"
fi

# Session cost
if [ -n "$cost" ] && [ "$cost" != "0" ]; then
  cost_fmt=$(printf '$%.2f' "$cost")
  line1="${line1}$(printf ' %b│%b %b💰 %s%b' "$GRAY" "$R" "$YELLOW" "$cost_fmt" "$R")"
fi

# Session duration
if [ -n "$duration_ms" ] && [ "$duration_ms" != "0" ]; then
  dur=$(format_duration "$duration_ms")
  line1="${line1}$(printf ' %b│%b %b⏱  %s%b' "$GRAY" "$R" "$WHITE" "$dur" "$R")"
fi

# Context usage
if [ -n "$ctx_used" ]; then
  ctx_int=$(printf '%.0f' "$ctx_used")
  ctx_color=$(color_for_pct "$ctx_int")
  line1="${line1}$(printf ' %b│%b %b📊 %s%%%b ctx' "$GRAY" "$R" "$ctx_color" "$ctx_int" "$R")"
fi

# Lines changed
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
  line1="${line1}$(printf ' %b│%b %b+%s%b%b/-%s%b' "$GRAY" "$R" "$GREEN" "$lines_added" "$R" "$RED" "$lines_removed" "$R")"
fi

printf '%b\n' "$line1"

# ══════════════════════════════════════
#  LINE 2: Quota Bars (from API)
# ══════════════════════════════════════

usage_json=$(fetch_usage)

if [ -n "$usage_json" ]; then
  five_pct=$(echo "$usage_json" | jq -r '.five_hour.utilization // empty')
  five_reset=$(echo "$usage_json" | jq -r '.five_hour.resets_at // empty')
  seven_pct=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty')
  seven_reset=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty')
  extra_enabled=$(echo "$usage_json" | jq -r '.extra_usage.is_enabled // "false"')
  extra_used=$(echo "$usage_json" | jq -r '.extra_usage.used_credits // empty')
  extra_limit=$(echo "$usage_json" | jq -r '.extra_usage.monthly_limit // empty')

  line2=""

  # 5-hour bar
  if [ -n "$five_pct" ]; then
    five_int=$(printf '%.0f' "$five_pct")
    five_color=$(color_for_pct "$five_int")
    five_bar=$(progress_bar "$five_int" "$five_color")
    five_time=$(time_until "$five_reset")
    line2="${line2}$(printf '%b⏳ 5h:%b %s %b%s%%%b' "$DIM" "$R" "$five_bar" "$five_color" "$five_int" "$R")"
    [ -n "$five_time" ] && line2="${line2}$(printf ' %b(%s)%b' "$DIM" "$five_time" "$R")"
  fi

  # 7-day bar
  if [ -n "$seven_pct" ]; then
    seven_int=$(printf '%.0f' "$seven_pct")
    seven_color=$(color_for_pct "$seven_int")
    seven_bar=$(progress_bar "$seven_int" "$seven_color")
    seven_time=$(time_until "$seven_reset")
    line2="${line2}$(printf ' %b│%b %b📅 7d:%b %s %b%s%%%b' "$GRAY" "$R" "$DIM" "$R" "$seven_bar" "$seven_color" "$seven_int" "$R")"
    [ -n "$seven_time" ] && line2="${line2}$(printf ' %b(%s)%b' "$DIM" "$seven_time" "$R")"
  fi

  # Extra usage (API returns credits in cents)
  if [ "$extra_enabled" = "true" ] && [ -n "$extra_used" ] && [ -n "$extra_limit" ]; then
    extra_util=$(echo "$usage_json" | jq -r '.extra_usage.utilization // empty')
    if [ -n "$extra_util" ]; then
      extra_pct=$(printf '%.0f' "$extra_util")
    else
      extra_pct=0
    fi
    extra_color=$(color_for_pct "$extra_pct")
    extra_bar=$(progress_bar "$extra_pct" "$extra_color")
    extra_used_fmt=$(printf '$%.2f' "$(echo "scale=2; $extra_used / 100" | bc 2>/dev/null)")
    extra_limit_fmt=$(printf '$%.0f' "$(echo "scale=0; $extra_limit / 100" | bc 2>/dev/null)")
    line2="${line2}$(printf ' %b│%b 💳 %s %b%s%b/%b%s%b' "$GRAY" "$R" "$extra_bar" "$extra_color" "$extra_used_fmt" "$R" "$DIM" "$extra_limit_fmt" "$R")"
  fi

  [ -n "$line2" ] && printf '%b\n' "$line2"
fi
