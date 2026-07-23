#!/usr/bin/env bash
# Reads the live agent fleet endpoint (the same platform-fleet feed
# staleness-check.sh reads) and alarms on three per-machine signals that lane
# staleness + convergence don't cover:
#
#   1. SECURITY — a machine's updateError indicates a genuinely tampered or
#      corrupt manifest (bad-signature / a signature mismatch — the signer's
#      key IS in our embedded set but the bytes don't verify against it, or
#      the signature can't even be parsed; plan §2.3.6, saw-agent
#      internal/update/verify.go VerdictBadSignature, agents-api
#      IManifestVerifier.cs ManifestVerifyResult.BadSignature). This posts a
#      DISTINCT, high-priority Discord message, separate from the routine
#      staleness alarm.
#   2. OPS (stale key set) — a machine's updateError is untrusted-key: the
#      signature is well-formed but signed by a key ID our embedded set
#      doesn't carry — the routine, EXPECTED shape of a machine that hasn't
#      picked up a key-rotation yet (plan §2.3.6/§2.11, verify.go
#      VerdictUntrustedKey, IManifestVerifier.cs
#      ManifestVerifyResult.UntrustedKey: "an ops alert, not a security
#      page"). During a scheduled key rotation EVERY lagging machine reports
#      this on every beat — folding it into the security page would page a
#      security incident per machine and bury/desensitize a real
#      bad-signature compromise. Posts a separate, lower-priority, distinctly
#      worded Discord message.
#   3. STUCK — a machine sits in a non-terminal update phase (staged,
#      draining, swapping, confirming) with lastUpdateAt older than the
#      stuck threshold — it started an update and never finished.
#
# Callable standalone (curl+jq only) or from a cron workflow.
#
# Dedup: alerts are tracked in STATE_FILE keyed by machineId. The SAME
# machine + condition (same error string, or same stuck phase) re-alerts
# only after REALERT_HOURS has passed, so a persisting condition doesn't
# re-page every single run — but a state file is a best-effort cache (see
# workflow comments); if it's ever unavailable, this degrades to paging
# every run, which is the documented, acceptable fallback (a live problem
# repeated in the channel is still far better than a silent one).
set -euo pipefail

FLEET_ENDPOINT="${FLEET_ENDPOINT:-https://agents.dev.sawrun.com/api/v1/platform/agent-fleet}"
STATE_FILE="${STATE_FILE:-./fleet-health-state.json}"
RUN_URL="${RUN_URL:-}"
STUCK_PHASE_MINUTES="${STUCK_PHASE_MINUTES:-30}"
SECURITY_REALERT_HOURS="${SECURITY_REALERT_HOURS:-6}"
OPS_REALERT_HOURS="${OPS_REALERT_HOURS:-6}"
STUCK_REALERT_HOURS="${STUCK_REALERT_HOURS:-6}"
DISCORD_API_BASE="${DISCORD_API_BASE:-https://discord.com/api/v10}"
# Case-insensitive; genuine tamper/corruption only (verify.go
# VerdictBadSignature / IManifestVerifier.cs BadSignature) — the manifest's
# signer key IS in our embedded set but the bytes fail Ed25519 verification,
# or the signature couldn't be parsed at all. Does NOT match untrusted-key
# (see OPS_ERROR_PATTERN below) — that is a stale key set, not a compromise.
SECURITY_ERROR_PATTERN="${SECURITY_ERROR_PATTERN:-bad-signature|signature mismatch|signature verification failed}"
# Case-insensitive; matches ONLY the stale-key-set verdict (verify.go
# VerdictUntrustedKey / IManifestVerifier.cs UntrustedKey) — a well-formed
# signature from a key ID outside our embedded set. Routine ops event
# (rotation lag), never a security page.
OPS_ERROR_PATTERN="${OPS_ERROR_PATTERN:-untrusted-key}"
STUCK_PHASES="staged draining swapping confirming"

# --- Self-failure notice (mirrors staleness-check.sh) ----------------------
notified_self_failure=false

notify_self_failure() {
  local reason="$1"
  [ "$notified_self_failure" = true ] && return 0
  notified_self_failure=true

  if [ -z "${DISCORD_BOT_TOKEN:-}" ] || [ -z "${DISCORD_CHANNEL_ID:-}" ]; then
    echo "NOTE: cannot post a self-failure notice — DISCORD_BOT_TOKEN/DISCORD_CHANNEL_ID not set" >&2
    return 0
  fi

  local text="**fleet-health-check itself failed**: ${reason}"
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

post_discord() {
  local message="$1"
  require_env DISCORD_BOT_TOKEN SAW_OPS_DISCORD_BOT_TOKEN
  require_env DISCORD_CHANNEL_ID SAW_OPS_DISCORD_CHANNEL_ID

  local payload response_file status
  payload=$(jq -n --arg content "$message" '{content: $content}')
  response_file=$(mktemp)
  status=$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    "${DISCORD_API_BASE}/channels/${DISCORD_CHANNEL_ID}/messages")
  if [ "$status" -ge 300 ]; then
    fail "discord alert POST failed with HTTP ${status}: $(cat "$response_file")"
  fi
  rm -f "$response_file"
}

require_env FLEET_KEY SAW_FLEET_STATS_KEY

now_epoch=$(date -u +%s)

# --- Fetch the fleet endpoint (same pinned Envelope contract as staleness-check.sh) ---

fleet_response=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${FLEET_KEY}" "$FLEET_ENDPOINT")
fleet_status="${fleet_response##*$'\n'}"
fleet_body="${fleet_response%$'\n'*}"
if [ "$fleet_status" != "200" ]; then
  fail "fleet endpoint ${FLEET_ENDPOINT} returned HTTP ${fleet_status}: ${fleet_body}"
fi

fleet_ok=$(echo "$fleet_body" | jq -r 'if has("ok") then (.ok | tostring) else "true" end' 2>/dev/null) || fail "fleet endpoint ${FLEET_ENDPOINT} returned non-JSON body: ${fleet_body}"
if [ "$fleet_ok" != "true" ]; then
  fleet_error=$(echo "$fleet_body" | jq -r '.error // .message // "no error detail in envelope"')
  fail "fleet endpoint ${FLEET_ENDPOINT} returned ok=false: ${fleet_error}"
fi

fleet_data=$(echo "$fleet_body" | jq -c '.data // .')

# --- Load dedup state -------------------------------------------------------

if [ -f "$STATE_FILE" ]; then
  state=$(cat "$STATE_FILE")
else
  state='{"security":{},"ops":{},"stuck":{}}'
fi
# Tolerate a state file from before any of these keys existed.
new_state=$(echo "$state" | jq -c '{security: (.security // {}), ops: (.ops // {}), stuck: (.stuck // {})}')

security_offenders="[]"
ops_offenders="[]"
stuck_offenders="[]"

while IFS= read -r machine; do
  [ -z "$machine" ] && continue
  machine_id=$(echo "$machine" | jq -r '.machineId')
  update_error=$(echo "$machine" | jq -r '.updateError // empty')
  update_target=$(echo "$machine" | jq -r '.updateTarget // "unknown"')
  update_phase=$(echo "$machine" | jq -r '.updatePhase // empty')
  last_update_at=$(echo "$machine" | jq -r '.lastUpdateAt // empty')

  # --- Signal 1: security (genuine tamper/corruption — bad-signature) ---
  if [ -n "$update_error" ] && echo "$update_error" | grep -Eiq "$SECURITY_ERROR_PATTERN"; then
    prev_error=$(echo "$new_state" | jq -r --arg id "$machine_id" '.security[$id].error // empty')
    prev_at=$(echo "$new_state" | jq -r --arg id "$machine_id" '.security[$id].alertedAt // empty')
    should_alert=true
    if [ "$prev_error" = "$update_error" ] && [ -n "$prev_at" ]; then
      hours_since=$(( (now_epoch - prev_at) / 3600 ))
      [ "$hours_since" -lt "$SECURITY_REALERT_HOURS" ] && should_alert=false
    fi
    if [ "$should_alert" = true ]; then
      security_offenders=$(echo "$security_offenders" | jq --arg id "$machine_id" --arg err "$update_error" --arg tgt "$update_target" \
        '. + [{machineId: $id, error: $err, target: $tgt}]')
      new_state=$(echo "$new_state" | jq --arg id "$machine_id" --arg err "$update_error" --argjson now "$now_epoch" \
        '.security[$id] = {error: $err, alertedAt: $now}')
    fi
    new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.ops[$id])')
  # --- Signal 1b: ops (stale key set — untrusted-key). Routine and expected
  # during a key rotation window; never a security page. ---
  elif [ -n "$update_error" ] && echo "$update_error" | grep -Eiq "$OPS_ERROR_PATTERN"; then
    prev_error=$(echo "$new_state" | jq -r --arg id "$machine_id" '.ops[$id].error // empty')
    prev_at=$(echo "$new_state" | jq -r --arg id "$machine_id" '.ops[$id].alertedAt // empty')
    should_alert=true
    if [ "$prev_error" = "$update_error" ] && [ -n "$prev_at" ]; then
      hours_since=$(( (now_epoch - prev_at) / 3600 ))
      [ "$hours_since" -lt "$OPS_REALERT_HOURS" ] && should_alert=false
    fi
    if [ "$should_alert" = true ]; then
      ops_offenders=$(echo "$ops_offenders" | jq --arg id "$machine_id" --arg err "$update_error" --arg tgt "$update_target" \
        '. + [{machineId: $id, error: $err, target: $tgt}]')
      new_state=$(echo "$new_state" | jq --arg id "$machine_id" --arg err "$update_error" --argjson now "$now_epoch" \
        '.ops[$id] = {error: $err, alertedAt: $now}')
    fi
    new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.security[$id])')
  else
    new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.security[$id]) | del(.ops[$id])')
  fi

  # --- Signal 2: stuck (non-terminal phase, aged past the stuck threshold) ---
  is_stuck_phase=false
  for p in $STUCK_PHASES; do
    [ "$update_phase" = "$p" ] && is_stuck_phase=true && break
  done

  if [ "$is_stuck_phase" = true ] && [ -n "$last_update_at" ]; then
    last_epoch=$(iso_to_epoch "$last_update_at")
    age_minutes=$(( (now_epoch - last_epoch) / 60 ))
    if [ "$age_minutes" -ge "$STUCK_PHASE_MINUTES" ]; then
      prev_phase=$(echo "$new_state" | jq -r --arg id "$machine_id" '.stuck[$id].phase // empty')
      prev_at=$(echo "$new_state" | jq -r --arg id "$machine_id" '.stuck[$id].alertedAt // empty')
      should_alert=true
      if [ "$prev_phase" = "$update_phase" ] && [ -n "$prev_at" ]; then
        hours_since=$(( (now_epoch - prev_at) / 3600 ))
        [ "$hours_since" -lt "$STUCK_REALERT_HOURS" ] && should_alert=false
      fi
      if [ "$should_alert" = true ]; then
        stuck_offenders=$(echo "$stuck_offenders" | jq --arg id "$machine_id" --arg ph "$update_phase" --argjson age "$age_minutes" \
          '. + [{machineId: $id, phase: $ph, ageMinutes: $age}]')
        new_state=$(echo "$new_state" | jq --arg id "$machine_id" --arg ph "$update_phase" --argjson now "$now_epoch" \
          '.stuck[$id] = {phase: $ph, alertedAt: $now}')
      fi
    else
      new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.stuck[$id])')
    fi
  else
    new_state=$(echo "$new_state" | jq --arg id "$machine_id" 'del(.stuck[$id])')
  fi
done < <(echo "$fleet_data" | jq -c '(.machines // [])[]')

# Drop dedup entries for machines the fleet no longer reports, so a
# decommissioned machine's old alert state can't linger forever.
present_ids=$(echo "$fleet_data" | jq -c '[(.machines // [])[].machineId]')
new_state=$(echo "$new_state" | jq --argjson present "$present_ids" \
  '.security |= with_entries(select(.key as $k | $present | index($k) != null))
   | .ops |= with_entries(select(.key as $k | $present | index($k) != null))
   | .stuck |= with_entries(select(.key as $k | $present | index($k) != null))')

echo "$new_state" > "$STATE_FILE"

security_count=$(echo "$security_offenders" | jq 'length')
ops_count=$(echo "$ops_offenders" | jq 'length')
stuck_count=$(echo "$stuck_offenders" | jq 'length')

# --- Alert (Discord) or stay silent -----------------------------------------

if [ "$security_count" -gt 0 ]; then
  lines=("**🚨 SAW fleet SECURITY alert**")
  while IFS= read -r line; do
    lines+=("$line")
  done < <(echo "$security_offenders" | jq -r '.[] | "⚠️ SECURITY: agent \(.machineId) reported \(.error) for \(.target)"')
  [ -n "$RUN_URL" ] && lines+=("Run: ${RUN_URL}")
  post_discord "$(printf '%s\n' "${lines[@]}")"
  echo "security alarm posted to discord (${security_count} machine(s))"
fi

if [ "$ops_count" -gt 0 ]; then
  lines=("**SAW fleet ops alert (key-rotation lag)**")
  while IFS= read -r line; do
    lines+=("$line")
  done < <(echo "$ops_offenders" | jq -r '.[] | "ℹ️ ops: agent \(.machineId) reported untrusted-key for \(.target) — likely a key-rotation lag; ensure it updates"')
  [ -n "$RUN_URL" ] && lines+=("Run: ${RUN_URL}")
  post_discord "$(printf '%s\n' "${lines[@]}")"
  echo "ops alarm posted to discord (${ops_count} machine(s))"
fi

if [ "$stuck_count" -gt 0 ]; then
  lines=("**SAW fleet stuck-phase alert**")
  while IFS= read -r line; do
    lines+=("$line")
  done < <(echo "$stuck_offenders" | jq -r '.[] | "- stuck: agent \(.machineId) in phase \(.phase) for \(.ageMinutes)m (threshold '"${STUCK_PHASE_MINUTES}"'m)"')
  [ -n "$RUN_URL" ] && lines+=("Run: ${RUN_URL}")
  post_discord "$(printf '%s\n' "${lines[@]}")"
  echo "stuck-phase alarm posted to discord (${stuck_count} machine(s))"
fi

if [ "$security_count" -eq 0 ] && [ "$ops_count" -eq 0 ] && [ "$stuck_count" -eq 0 ]; then
  echo "no security, ops, or stuck-phase issues detected"
fi
