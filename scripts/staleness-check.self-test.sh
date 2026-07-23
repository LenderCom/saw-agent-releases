#!/usr/bin/env bash
# Self-test harness for scripts/staleness-check.sh. Spins up a local mock of
# the GitHub releases API + the platform fleet endpoint + Discord (via
# scripts/self-test/mock_server.py), drives the real script against it with
# REAL envelope-shaped fixtures ({ok, data: {channels, machines}}), and
# asserts the outcome for each scenario. Callable standalone:
#
#   ./scripts/staleness-check.self-test.sh
#
# No network access required beyond binding a loopback port. Requires
# python3, curl, jq — the same runtime the workflow already assumes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
target_script="${repo_root}/scripts/staleness-check.sh"
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

# Builds a real-envelope-shaped fleet fixture: {ok, data: {channels, machines}}
fleet_envelope() {
  local head_version="$1" machine_version="$2" online="$3"
  jq -n --arg hv "$head_version" --arg mv "$machine_version" --argjson online "$online" '{
    ok: true,
    data: {
      channels: [{channel: "dev", headVersion: $hv}, {channel: "stable", headVersion: "1.0.0"}],
      machines: [{machineId: "m-aaa", agentVersion: $mv, online: $online, channel: "dev"}]
    }
  }'
}

release_list() {
  local version="$1" published_iso="$2" manifest_url="$3"
  jq -n --arg v "$version" --arg pub "$published_iso" --arg url "$manifest_url" '[{
    tag_name: ("dev-v" + $v),
    published_at: $pub,
    assets: [{name: "manifest.json", browser_download_url: $url}]
  }]'
}

manifest_body() {
  local version="$1"
  jq -n --arg v "$version" '{version: $v, channel: "dev", yanked: false}'
}

run_scenario() {
  local name="$1"
  echo "--- scenario: ${name} ---"
}

now_epoch="$(date -u +%s)"

echo "== staleness-check.sh self-test (real envelope-shaped fixtures) =="

# ---------------------------------------------------------------------------
# Scenario 1: healthy — fresh dev release, fleet head matches the online
# machine. Expect silent success, no Discord POST.
# ---------------------------------------------------------------------------
run_scenario "healthy / silent"
port=$(free_port)
config="${work_dir}/healthy.json"
log_file="${work_dir}/healthy.discord.log"
manifest_url="http://127.0.0.1:${port}/manifest/dev-v0.9.1.json"
releases=$(release_list "0.9.1" "$(epoch_to_iso $((now_epoch - 3600)))" "$manifest_url")
manifest=$(manifest_body "0.9.1")
fleet=$(fleet_envelope "0.9.1" "0.9.1" true)
jq -n --argjson releases "$releases" --argjson manifest "$manifest" --argjson fleet "$fleet" '{
  "GET /repos/LenderCom/saw-agent-releases/releases": {status: 200, body: $releases},
  "GET /manifest/dev-v0.9.1.json": {status: 200, body: $manifest},
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "1"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

set +e
output=$(cd "$work_dir" && GITHUB_API_BASE="http://127.0.0.1:${port}" \
  FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
  DISCORD_API_BASE="http://127.0.0.1:${port}" \
  FLEET_KEY="test-fleet-key" \
  DISCORD_BOT_TOKEN="test-bot-token" DISCORD_CHANNEL_ID="999" \
  STATE_FILE="${work_dir}/healthy.state.json" RUN_URL="http://example.invalid/run/1" \
  "$target_script" 2>&1)
exit_code=$?
set -e
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "no staleness detected" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "0" "discord POSTs received" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 2: stale dev lane → alarm posted to Discord. Fleet itself is
# healthy/converged so only the lane-age path fires.
# ---------------------------------------------------------------------------
run_scenario "stale dev lane / alarm"
port=$(free_port)
config="${work_dir}/stale.json"
log_file="${work_dir}/stale.discord.log"
manifest_url="http://127.0.0.1:${port}/manifest/dev-v0.9.0.json"
releases=$(release_list "0.9.0" "$(epoch_to_iso $((now_epoch - 30 * 3600)))" "$manifest_url")
manifest=$(manifest_body "0.9.0")
fleet=$(fleet_envelope "0.9.0" "0.9.0" true)
jq -n --argjson releases "$releases" --argjson manifest "$manifest" --argjson fleet "$fleet" '{
  "GET /repos/LenderCom/saw-agent-releases/releases": {status: 200, body: $releases},
  "GET /manifest/dev-v0.9.0.json": {status: 200, body: $manifest},
  "GET /api/v1/platform/agent-fleet": {status: 200, body: $fleet},
  "POST /channels/999/messages": {status: 200, body: {id: "2"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

set +e
output=$(cd "$work_dir" && GITHUB_API_BASE="http://127.0.0.1:${port}" \
  FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
  DISCORD_API_BASE="http://127.0.0.1:${port}" \
  FLEET_KEY="test-fleet-key" \
  DISCORD_BOT_TOKEN="test-bot-token" DISCORD_CHANNEL_ID="999" \
  STATE_FILE="${work_dir}/stale.state.json" RUN_URL="http://example.invalid/run/2" \
  "$target_script" 2>&1)
exit_code=$?
set -e
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "0" "exit code" || scenario_ok=false
assert_contains "$output" "alarm posted to discord" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "SAW agent staleness alarm" "posted discord content" || scenario_ok=false
assert_contains "$posted_content" "Dev lane:" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 3: fleet endpoint returns HTTP 500 → the check itself fails, but
# a distinct "staleness-check itself failed" notice still reaches Discord,
# and the run still exits non-zero.
# ---------------------------------------------------------------------------
run_scenario "fleet endpoint 500 / failure notice"
port=$(free_port)
config="${work_dir}/endpoint500.json"
log_file="${work_dir}/endpoint500.discord.log"
manifest_url="http://127.0.0.1:${port}/manifest/dev-v0.9.1.json"
releases=$(release_list "0.9.1" "$(epoch_to_iso $((now_epoch - 3600)))" "$manifest_url")
manifest=$(manifest_body "0.9.1")
jq -n --argjson releases "$releases" --argjson manifest "$manifest" '{
  "GET /repos/LenderCom/saw-agent-releases/releases": {status: 200, body: $releases},
  "GET /manifest/dev-v0.9.1.json": {status: 200, body: $manifest},
  "GET /api/v1/platform/agent-fleet": {status: 500, body: {error: "internal server error"}},
  "POST /channels/999/messages": {status: 200, body: {id: "3"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

set +e
output=$(cd "$work_dir" && GITHUB_API_BASE="http://127.0.0.1:${port}" \
  FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
  DISCORD_API_BASE="http://127.0.0.1:${port}" \
  FLEET_KEY="test-fleet-key" \
  DISCORD_BOT_TOKEN="test-bot-token" DISCORD_CHANNEL_ID="999" \
  STATE_FILE="${work_dir}/endpoint500.state.json" RUN_URL="http://example.invalid/run/3" \
  "$target_script" 2>&1)
exit_code=$?
set -e
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "1" "exit code" || scenario_ok=false
assert_contains "$output" "returned HTTP 500" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
posted_content=$(jq -r '.body.content' "$log_file")
assert_contains "$posted_content" "staleness-check itself failed" "posted discord content" || scenario_ok=false
assert_contains "$posted_content" "HTTP 500" "posted discord content" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Bonus scenario 4: envelope is HTTP 200 but ok:false — the shape-assertion
# must catch it rather than silently iterating an absent .channels/.machines.
# ---------------------------------------------------------------------------
run_scenario "envelope ok:false / shape assertion"
port=$(free_port)
config="${work_dir}/okfalse.json"
log_file="${work_dir}/okfalse.discord.log"
manifest_url="http://127.0.0.1:${port}/manifest/dev-v0.9.1.json"
releases=$(release_list "0.9.1" "$(epoch_to_iso $((now_epoch - 3600)))" "$manifest_url")
manifest=$(manifest_body "0.9.1")
jq -n --argjson releases "$releases" --argjson manifest "$manifest" '{
  "GET /repos/LenderCom/saw-agent-releases/releases": {status: 200, body: $releases},
  "GET /manifest/dev-v0.9.1.json": {status: 200, body: $manifest},
  "GET /api/v1/platform/agent-fleet": {status: 200, body: {ok: false, error: "fleet snapshot under maintenance"}},
  "POST /channels/999/messages": {status: 200, body: {id: "4"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

set +e
output=$(cd "$work_dir" && GITHUB_API_BASE="http://127.0.0.1:${port}" \
  FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
  DISCORD_API_BASE="http://127.0.0.1:${port}" \
  FLEET_KEY="test-fleet-key" \
  DISCORD_BOT_TOKEN="test-bot-token" DISCORD_CHANNEL_ID="999" \
  STATE_FILE="${work_dir}/okfalse.state.json" RUN_URL="http://example.invalid/run/4" \
  "$target_script" 2>&1)
exit_code=$?
set -e
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "1" "exit code" || scenario_ok=false
assert_contains "$output" "returned ok=false: fleet snapshot under maintenance" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "1" "discord POSTs received" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# Bonus scenario 5: failure with the Discord secrets themselves missing —
# plain exit 1, no attempted POST (nothing to post with).
# ---------------------------------------------------------------------------
run_scenario "failure with no Discord secrets / plain exit 1"
port=$(free_port)
config="${work_dir}/nodiscord.json"
log_file="${work_dir}/nodiscord.discord.log"
manifest_url="http://127.0.0.1:${port}/manifest/dev-v0.9.1.json"
releases=$(release_list "0.9.1" "$(epoch_to_iso $((now_epoch - 3600)))" "$manifest_url")
manifest=$(manifest_body "0.9.1")
jq -n --argjson releases "$releases" --argjson manifest "$manifest" '{
  "GET /repos/LenderCom/saw-agent-releases/releases": {status: 200, body: $releases},
  "GET /manifest/dev-v0.9.1.json": {status: 200, body: $manifest},
  "GET /api/v1/platform/agent-fleet": {status: 500, body: {error: "internal server error"}}
}' > "$config"
start_mock_server "$config" "$port" "$log_file"

set +e
output=$(cd "$work_dir" && GITHUB_API_BASE="http://127.0.0.1:${port}" \
  FLEET_ENDPOINT="http://127.0.0.1:${port}/api/v1/platform/agent-fleet" \
  DISCORD_API_BASE="http://127.0.0.1:${port}" \
  FLEET_KEY="test-fleet-key" \
  STATE_FILE="${work_dir}/nodiscord.state.json" RUN_URL="http://example.invalid/run/5" \
  "$target_script" 2>&1)
exit_code=$?
set -e
stop_mock_server

scenario_ok=true
assert_eq "$exit_code" "1" "exit code" || scenario_ok=false
assert_contains "$output" "cannot post a self-failure notice" "stdout" || scenario_ok=false
assert_eq "$(wc -l < "$log_file" | tr -d ' ')" "0" "discord POSTs received" || scenario_ok=false
if [ "$scenario_ok" = true ]; then
  echo "    PASS"
  pass_count=$((pass_count + 1))
else
  fail_count=$((fail_count + 1))
fi

echo "== ${pass_count} passed, ${fail_count} failed =="
[ "$fail_count" -eq 0 ]
