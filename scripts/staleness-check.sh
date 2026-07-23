#!/usr/bin/env bash
# Compares this repo's own newest non-yanked dev-v* release against the live
# agent fleet endpoint and alerts to Discord when the dev lane looks stalled
# or the fleet isn't converging to it. Callable standalone (curl+jq only) or
# from the staleness-cron workflow.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-LenderCom/saw-agent-releases}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
FLEET_ENDPOINT="${FLEET_ENDPOINT:-https://agents.dev.sawrun.com/api/v1/platform/agent-fleet}"
STATE_FILE="${STATE_FILE:-./staleness-state.json}"
RUN_URL="${RUN_URL:-}"
STALE_LANE_HOURS="${STALE_LANE_HOURS:-26}"
CONVERGENCE_WINDOW_HOURS="${CONVERGENCE_WINDOW_HOURS:-24}"
DISCORD_API_BASE="${DISCORD_API_BASE:-https://discord.com/api/v10}"

# --- Self-failure notice ---------------------------------------------------
# The whole point of this script is to be the thing that notices problems. If
# IT crashes (bad HTTP status, a malformed response, anything under set -e),
# that failure must not be invisible — post a distinct, low-noise "the alarm
# itself is broken" message using the same Discord secrets, then still exit
# non-zero so Actions shows red. If the Discord secrets are themselves what's
# missing, there's nothing to post with — a plain loud exit 1 is acceptable.
notified_self_failure=false

notify_self_failure() {
  local reason="$1"
  [ "$notified_self_failure" = true ] && return 0
  notified_self_failure=true

  if [ -z "${DISCORD_BOT_TOKEN:-}" ] || [ -z "${DISCORD_CHANNEL_ID:-}" ]; then
    echo "NOTE: cannot post a self-failure notice — DISCORD_BOT_TOKEN/DISCORD_CHANNEL_ID not set" >&2
    return 0
  fi

  local text="**staleness-check itself failed**: ${reason}"
  [ -n "${RUN_URL:-}" ] && text="${text}
Run: ${RUN_URL}"

  local payload notice_status
  payload=$(jq -n --arg content "$text" '{content: $content}' 2>/dev/null) || return 0
  notice_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    "${DISCORD_API_BASE}/channels/${DISCORD_CHANNEL_ID}/messages" 2>/dev/null) || true
  if [ "${notice_status:-}" != "" ] && [ "${notice_status}" -ge 300 ] 2>/dev/null; then
    echo "NOTE: self-failure Discord notice itself got HTTP ${notice_status} — giving up, exiting red anyway" >&2
  fi
}

fail() {
  echo "ERROR: $*" >&2
  notify_self_failure "$*"
  exit 1
}

# Catches anything that dies via `set -e` without going through fail() (an
# unhandled curl/jq failure, a bad substitution, etc.) so a crash is never
# silently red with no trace of *why* the alarm mechanism itself went dark.
on_unexpected_error() {
  local lineno="$1" cmd="$2"
  echo "ERROR: unexpected failure at line ${lineno}: ${cmd}" >&2
  notify_self_failure "unexpected failure at line ${lineno} running: ${cmd}"
  exit 1
}
trap 'on_unexpected_error "$LINENO" "$BASH_COMMAND"' ERR

require_env() {
  local var_name="$1" secret_name="$2"
  if [ -z "${!var_name:-}" ]; then
    fail "missing required env var ${var_name} (repo secret ${secret_name} is not set — provision it before this workflow can run)"
  fi
}

# GitHub Actions runners are GNU/Linux; macOS (BSD date) is supported too so
# the script runs unmodified for local testing.
iso_to_epoch() {
  local iso="$1"
  if date -u -d "$iso" +%s >/dev/null 2>&1; then
    date -u -d "$iso" +%s
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s
  fi
}

gh_curl() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sSf -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$url"
  else
    curl -sSf -H "Accept: application/vnd.github+json" "$url"
  fi
}

require_env FLEET_KEY SAW_FLEET_STATS_KEY

now_epoch=$(date -u +%s)

# --- Step 1: this repo's own newest non-yanked dev-v* release -------------

releases_json=$(gh_curl "${GITHUB_API_BASE}/repos/${REPO}/releases?per_page=30")
dev_releases=$(echo "$releases_json" | jq -c '[.[] | select(.tag_name | startswith("dev-v"))]')

head_version=""
head_published_at=""

while IFS= read -r release; do
  [ -z "$release" ] && continue
  published_at=$(echo "$release" | jq -r '.published_at')
  manifest_url=$(echo "$release" | jq -r '(.assets // []) | .[] | select(.name == "manifest.json") | .browser_download_url')
  [ -z "$manifest_url" ] || [ "$manifest_url" = "null" ] && continue
  manifest=$(curl -sSf "$manifest_url") || continue
  yanked=$(echo "$manifest" | jq -r '.yanked // false')
  [ "$yanked" = "true" ] && continue
  head_version=$(echo "$manifest" | jq -r '.version')
  head_published_at="$published_at"
  break
done < <(echo "$dev_releases" | jq -c '.[]')

lane_stale=false
lane_reason=""
if [ -z "$head_version" ]; then
  lane_stale=true
  lane_reason="no non-yanked dev-v* release found in ${REPO}"
else
  head_epoch=$(iso_to_epoch "$head_published_at")
  age_hours=$(( (now_epoch - head_epoch) / 3600 ))
  if [ "$age_hours" -ge "$STALE_LANE_HOURS" ]; then
    lane_stale=true
    lane_reason="newest dev release ${head_version} published ${age_hours}h ago (threshold ${STALE_LANE_HOURS}h)"
  fi
fi

# --- Step 2: the fleet endpoint (pinned contract) -------------------------

fleet_response=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${FLEET_KEY}" "$FLEET_ENDPOINT")
fleet_status="${fleet_response##*$'\n'}"
fleet_body="${fleet_response%$'\n'*}"
if [ "$fleet_status" != "200" ]; then
  fail "fleet endpoint ${FLEET_ENDPOINT} returned HTTP ${fleet_status}: ${fleet_body}"
fi

# The real endpoint wraps the payload in an Envelope: {ok, data: {channels,
# machines}}. Unwrap defensively (.data // .) so an eventual unwrapped shape
# still works, and assert `ok` up front — a well-formed-but-failed envelope
# (ok:false) must not silently look like an empty fleet.
fleet_ok=$(echo "$fleet_body" | jq -r 'if has("ok") then (.ok | tostring) else "true" end' 2>/dev/null) || fail "fleet endpoint ${FLEET_ENDPOINT} returned non-JSON body: ${fleet_body}"
if [ "$fleet_ok" != "true" ]; then
  fleet_error=$(echo "$fleet_body" | jq -r '.error // .message // "no error detail in envelope"')
  fail "fleet endpoint ${FLEET_ENDPOINT} returned ok=false: ${fleet_error}"
fi

fleet_data=$(echo "$fleet_body" | jq -c '.data // .')

fleet_head_version=$(echo "$fleet_data" | jq -r '[(.channels // [])[] | select(.channel == "dev")][0].headVersion // empty')

# --- Step 3: fleet-not-converging (machines stuck behind the fleet's own dev head) ---

stale_machines="[]"
if [ -n "$fleet_head_version" ]; then
  if [ -f "$STATE_FILE" ]; then
    state=$(cat "$STATE_FILE")
  else
    state='{}'
  fi
  new_state="$state"
  offending="[]"

  while IFS= read -r machine; do
    [ -z "$machine" ] && continue
    machine_id=$(echo "$machine" | jq -r '.machineId')
    agent_version=$(echo "$machine" | jq -r '.agentVersion // "unknown"')

    if [ "$agent_version" = "$fleet_head_version" ]; then
      new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.[$id])')
      continue
    fi

    first_behind=$(echo "$new_state" | jq -r --arg id "$machine_id" '.[$id].firstBehindAt // empty')
    if [ -z "$first_behind" ]; then
      new_state=$(echo "$new_state" | jq --arg id "$machine_id" --arg v "$agent_version" --argjson now "$now_epoch" \
        '.[$id] = {firstBehindAt: $now, version: $v}')
      first_behind="$now_epoch"
    fi

    behind_hours=$(( (now_epoch - first_behind) / 3600 ))
    if [ "$behind_hours" -ge "$CONVERGENCE_WINDOW_HOURS" ]; then
      offending=$(echo "$offending" | jq --arg id "$machine_id" --arg v "$agent_version" --argjson h "$behind_hours" \
        '. + [{machineId: $id, agentVersion: $v, behindHours: $h}]')
    fi
  done < <(echo "$fleet_data" | jq -c '(.machines // [])[] | select(.online == true and .channel == "dev")')

  present_ids=$(echo "$fleet_data" | jq -c '[(.machines // [])[].machineId]')
  new_state=$(echo "$new_state" | jq --argjson present "$present_ids" \
    'with_entries(select(.key as $k | $present | index($k) != null))')

  echo "$new_state" > "$STATE_FILE"
  stale_machines="$offending"
fi

fleet_not_converging=false
if [ "$(echo "$stale_machines" | jq 'length')" -gt 0 ]; then
  fleet_not_converging=true
fi

# --- Step 4: alert (Discord) or stay silent -------------------------------

if [ "$lane_stale" = true ] || [ "$fleet_not_converging" = true ]; then
  require_env DISCORD_BOT_TOKEN SAW_OPS_DISCORD_BOT_TOKEN
  require_env DISCORD_CHANNEL_ID SAW_OPS_DISCORD_CHANNEL_ID

  lines=("**SAW agent staleness alarm**")
  if [ "$lane_stale" = true ]; then
    lines+=("- Dev lane: ${lane_reason}")
  fi
  lines+=("- Fleet dev head (per fleet endpoint): ${fleet_head_version:-unknown}")
  if [ "$fleet_not_converging" = true ]; then
    lines+=("- Machines not converging to head (>= ${CONVERGENCE_WINDOW_HOURS}h behind):")
    while IFS= read -r line; do
      lines+=("$line")
    done < <(echo "$stale_machines" | jq -r '.[] | "  - \(.machineId) stuck on \(.agentVersion) for \(.behindHours)h"')
  fi
  if [ -n "$RUN_URL" ]; then
    lines+=("Run: ${RUN_URL}")
  fi
  message=$(printf '%s\n' "${lines[@]}")

  payload=$(jq -n --arg content "$message" '{content: $content}')
  discord_response_file=$(mktemp)
  discord_status=$(curl -sS -o "$discord_response_file" -w '%{http_code}' \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    "${DISCORD_API_BASE}/channels/${DISCORD_CHANNEL_ID}/messages")
  if [ "$discord_status" -ge 300 ]; then
    fail "discord alert POST failed with HTTP ${discord_status}: $(cat "$discord_response_file")"
  fi
  rm -f "$discord_response_file"
  echo "alarm posted to discord (lane_stale=${lane_stale} fleet_not_converging=${fleet_not_converging})"
else
  echo "no staleness detected — dev head ${head_version:-none}, fleet dev head ${fleet_head_version:-unknown}, all online dev machines converged"
fi
