#!/usr/bin/env bash
# Self-test harness for scripts/fleet-health-check.sh. Spins up a local mock
# of the platform fleet endpoint + Discord (via scripts/self-test/mock_server.py),
# drives the real script against it with REAL envelope-shaped fixtures
# ({ok, data: {channels, machines}}), and asserts the outcome for each
# scenario. Callable standalone:
#
#   ./scripts/fleet-health-check.self-test.sh
#
# No network access required beyond binding a loopback port. Requires
# python3, curl, jq — the same runtime the workflow already assumes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
target_script="${repo_root}/scripts/fleet-health-check.sh"
mock_server="${script_dir}/self-test/mock_server.py"

work_dir="$(mktemp -d)"
trap 'cleanup' EXIT

server_pid=""

cleanup() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}

pass_count=0
fail_count=0

assert_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "    FAIL: expected ${what} to contain: ${needle}" >&2
    echo "    --- actual ${what} ---" >&2
    echo "$haystack" >&2
    echo "    ----------------------" >&2
    return 1
  fi
  return 0
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "    FAIL: expected ${what} to NOT contain: ${needle}" >&2
    return 1
  fi
  return 0
}

assert_eq() {
  local actual="$1" expected="$2" what="$3"
  if [ "$actual" != "$expected" ]; then
    echo "    FAIL: expected ${what} = ${expected}, got ${actual}" >&2
    return 1
  fi
  return 0
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

epoch_to_iso() {
  local epoch="$1"
  if date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ
  fi
}

start_mock_server() {
  local config_path="$1" port="$2" log_file="$3"
  python3 "$mock_server" "$config_path" "$port" "$log_file" &
  server_pid=$!
  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://127.0.0.1:${port}/__probe" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
}

stop_mock_server() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

# Builds a real-envelope-shaped fleet fixture: {ok, data: {channels, machines}}.
# `machines` takes a pre-built JSON array so each scenario can shape exactly
# the updatePhase/updateTarget/updateError/lastUpdateAt telemetry it needs.
fleet_envelope_with_machines() {
  local machines_json="$1"
  jq -n --argjson machines "$machines_json" '{
    ok: true,
    data: {
      channels: [{channel: "dev", headVersion: "1.4.2"}, {channel: "stable", headVersion: "1.0.0"}],
      machines: $machines
    }
  }'
}

run_scenario() {
  local name="$1"
  echo "--- scenario: ${name} ---"
}

run_check() {
  local port="$1" config="$2" log_file="$3" state_file="$4" run_label="$5"
  local out
  set +e
  out=$(cd "$work_dir" && \
    FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
    DISCORD_API_BASE="http://127.0.0.1:${port}" \
    FLEET_KEY="test-fleet-key" \
    DISCORD_BOT_TOKEN="test-bot-token" DISCORD_CHANNEL_ID="999" \
    STATE_FILE="$state_file" RUN_URL="http://example.invalid/run/${run_label}" \
    STUCK_PHASE_MINUTES=30 SECURITY_REALERT_HOURS=6 STUCK_REALERT_HOURS=6 \
    "$target_script" 2>&1)
  local code=$?
  set -e
  printf '%s\x1e%s' "$code" "$out"
}

now_epoch="$(date -u +%s)"

echo "== fleet-health-check.sh self-test (real envelope-shaped fixtures) =="

# ---------------------------------------------------------------------------
# Scenario 1: all healthy — no security errors, no stuck phases (idle/good
# machines only). Expect silent success, no Discord POST.
# ---------------------------------------------------------------------------
run_scenario "all healthy / silent"
port=$(free_port)
config="${work_dir}/healthy.json"
log_file="${work_dir}/healthy.discord.log"
machines=$(jq -n '[
  {machineId: "m-good-1", orgId: "org-a", channel: "dev", agentVersion: "1.4.2", online: true, updatePhase: null, updateTarget: null, updateError: null, lastUpdateAt: null},
  {machineId: "m-good-2", orgId: "org-a", channel: "dev", agentVersion: "1.4.2", online: true, updatePhase: "good", updateTarget: "1.4.2", updateError: null, lastUpdateAt: "2026-07-20T00:00:00Z"}
]')
fleet=$(fleet_envelope_with_machines "$machines")
jq -n --argjson fleet "$fleet" '{
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "1"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "${work_dir}/healthy.state.json" "1")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "no security or stuck-phase issues detected" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "0" "discord POSTs received" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 2: a machine reports a bad-signature updateError → the distinct
# high-priority security alert fires with the required format.
# ---------------------------------------------------------------------------
run_scenario "bad-signature machine / security alert"
port=$(free_port)
config="${work_dir}/security.json"
log_file="${work_dir}/security.discord.log"
machines=$(jq -n '[
  {machineId: "m-compromised", orgId: "org-b", channel: "dev", agentVersion: "1.4.1", online: true, updatePhase: "failed", updateTarget: "1.4.2", updateError: "verify_failed: bad-signature (minisign verification failed)", lastUpdateAt: "2026-07-22T12:00:00Z"}
]')
fleet=$(fleet_envelope_with_machines "$machines")
jq -n --argjson fleet "$fleet" '{
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "2"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "${work_dir}/security.state.json" "2")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "security alarm posted to discord (1 machine(s))" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "SAW fleet SECURITY alert" "posted discord content" || scenario_ok=false
assert_contains "$posted_content" "⚠️ SECURITY: agent m-compromised reported verify_failed: bad-signature (minisign verification failed) for 1.4.2" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 3: a machine has been stuck in `draining` for well over the
# stuck-phase threshold → the stuck alert fires naming machine + phase + age.
# ---------------------------------------------------------------------------
run_scenario "stuck draining machine / stuck alert"
port=$(free_port)
config="${work_dir}/stuck.json"
log_file="${work_dir}/stuck.discord.log"
stuck_since_iso=$(epoch_to_iso $((now_epoch - 90 * 60)))
machines=$(jq -n --arg at "$stuck_since_iso" '[
  {machineId: "m-stuck", orgId: "org-c", channel: "dev", agentVersion: "1.4.1", online: true, updatePhase: "draining", updateTarget: "1.4.2", updateError: null, lastUpdateAt: $at}
]')
fleet=$(fleet_envelope_with_machines "$machines")
jq -n --argjson fleet "$fleet" '{
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "3"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "${work_dir}/stuck.state.json" "3")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "stuck-phase alarm posted to discord (1 machine(s))" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "SAW fleet stuck-phase alert" "posted discord content" || scenario_ok=false
assert_contains "$posted_content" "stuck: agent m-stuck in phase draining for 90m (threshold 30m)" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 4: a machine in `confirming` for LESS than the stuck threshold is
# NOT flagged — a normal in-flight update must not page.
# ---------------------------------------------------------------------------
run_scenario "in-flight confirming under threshold / silent"
port=$(free_port)
config="${work_dir}/inflight.json"
log_file="${work_dir}/inflight.discord.log"
recent_iso=$(epoch_to_iso $((now_epoch - 5 * 60)))
machines=$(jq -n --arg at "$recent_iso" '[
  {machineId: "m-updating", orgId: "org-d", channel: "dev", agentVersion: "1.4.1", online: true, updatePhase: "confirming", updateTarget: "1.4.2", updateError: null, lastUpdateAt: $at}
]')
fleet=$(fleet_envelope_with_machines "$machines")
jq -n --argjson fleet "$fleet" '{
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "4"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "${work_dir}/inflight.state.json" "4")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "no security or stuck-phase issues detected" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "0" "discord POSTs received" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 5: dedup — the SAME machine + SAME stuck phase alerted last run
# (state file already has a recent alertedAt) does not re-page inside the
# realert window; a NEW distinct machine in the same run still does.
# ---------------------------------------------------------------------------
run_scenario "dedup / no re-page inside realert window"
port=$(free_port)
config="${work_dir}/dedup.json"
log_file="${work_dir}/dedup.discord.log"
state_file="${work_dir}/dedup.state.json"
stuck_since_iso=$(epoch_to_iso $((now_epoch - 90 * 60)))
jq -n --arg at "$((now_epoch - 3600))" '{
  security: {},
  stuck: {"m-already-alerted": {phase: "draining", alertedAt: ($at | tonumber)}}
}' > "$state_file"
machines=$(jq -n --arg at "$stuck_since_iso" '[
  {machineId: "m-already-alerted", orgId: "org-e", channel: "dev", agentVersion: "1.4.1", online: true, updatePhase: "draining", updateTarget: "1.4.2", updateError: null, lastUpdateAt: $at},
  {machineId: "m-newly-stuck", orgId: "org-e", channel: "dev", agentVersion: "1.4.1", online: true, updatePhase: "swapping", updateTarget: "1.4.2", updateError: null, lastUpdateAt: $at}
]')
fleet=$(fleet_envelope_with_machines "$machines")
jq -n --argjson fleet "$fleet" '{
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "5"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "$state_file" "5")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "stuck-phase alarm posted to discord (1 machine(s))" "stdout" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "m-newly-stuck" "posted discord content" || scenario_ok=false
assert_not_contains "$posted_content" "m-already-alerted" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 6: fleet endpoint returns HTTP 500 → the self-failure notice still
# reaches Discord and the run exits non-zero (reuses staleness-check.sh's
# self-failure mechanism).
# ---------------------------------------------------------------------------
run_scenario "fleet endpoint 500 / failure notice"
port=$(free_port)
config="${work_dir}/endpoint500.json"
log_file="${work_dir}/endpoint500.discord.log"
jq -n '{
  "GET /api/v1/platform/agent-fleet": {status: 500, body: {error: "internal server error"}},
  "POST /channels/999/messages": {status: 200, body: {id: "6"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

result=$(run_check "$port" "$config" "$log_file" "${work_dir}/endpoint500.state.json" "6")
exit_code="${result%%$'\x1e'*}"
output="${result#*$'\x1e'}"
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "1" "exit code" || scenario_ok=false
assert_contains "$output" "returned HTTP 500" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "fleet-health-check itself failed" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

echo "== ${pass_count} passed, ${fail_count} failed =="
[ "$fail_count" -eq 0 ]
