#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG_FILE="$TMP_DIR/config.ini"
LOG_FILE="$TMP_DIR/servmon.log"
PID_FILE="$TMP_DIR/servmon.pid"
METRICS_DIR="$TMP_DIR/metrics"

# shellcheck source=../sermos.sh
source "$ROOT_DIR/sermos.sh"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

test_send_to_api_requires_endpoint_and_key() {
    API_ENDPOINT=""
    API_KEY=""

    assert_eq "NO_ENDPOINT" "$(send_to_api '{}')" "send_to_api should skip when endpoint/key are missing"
}

test_send_to_api_posts_bearer_token_and_payload() {
    API_ENDPOINT="https://metrics.example.test/api/metrics"
    API_KEY="secret-key"
    local curl_args="$TMP_DIR/curl.args"

    curl() {
        printf '%s\n' "$@" > "$curl_args"
        echo "200"
    }

    local payload='{"cpu":{"usage_percent":12.5}}'
    assert_eq "200" "$(send_to_api "$payload")" "send_to_api should return API HTTP code"

    grep -Fxq "Authorization: Bearer secret-key" "$curl_args" || fail "Authorization Bearer header was not sent"
    grep -Fxq "Content-Type: application/json" "$curl_args" || fail "JSON content type was not sent"
    grep -Fxq "$payload" "$curl_args" || fail "metric payload was not posted"
    grep -Fxq "$API_ENDPOINT" "$curl_args" || fail "API endpoint was not called"
}

test_collect_metrics_outputs_required_json_sections() {
    get_system_info() { echo '{"hostname":"linux-test","os":"TestOS","kernel":"1.0","arch":"x86_64"}'; }
    get_ips() { echo '{"public":"203.0.113.10","private":"10.0.0.15"}'; }
    get_cpu_usage() { echo '12.5'; }
    get_cpu_info() { echo '{"model":"Test CPU","cores":4,"load_avg":0.5}'; }
    get_memory() { echo '{"total_mb":8192,"used_mb":2048,"free_mb":6144,"usage_percent":25}'; }
    get_disk() { echo '{"total_mb":102400,"used_mb":51200,"available_mb":51200,"usage_percent":50}'; }
    get_all_disks() { echo '[{"mount":"/","size":"100G","used":"50G","available":"50G","percent":50}]'; }
    get_saturation() { echo '{"load_1min":0.5,"load_5min":0.4,"load_15min":0.3,"cores":4,"saturation_percent":12.5}'; }
    get_heavy_files() {
        assert_eq "250" "$1" "collect_metrics should use configured heavy file threshold"
        echo '[{"path":"/tmp/large.bin","size":"300M"}]'
    }
    get_uptime_days() { echo '5'; }
    get_open_ports() { echo '[{"port":22,"protocol":"tcp","service":"tcp"}]'; }
    get_top_processes() { echo '[{"pid":123,"user":"root","cpu":1.5,"mem":2.5,"command":"node"}]'; }

    HEAVY_FILE_THRESHOLD=250
    collect_metrics > "$TMP_DIR/metrics.json"

    python3 - "$TMP_DIR/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

assert data["system"]["hostname"] == "linux-test"
assert data["cpu"]["usage_percent"] == 12.5
assert data["memory"]["usage_percent"] == 25
assert data["disk"]["root"]["usage_percent"] == 50
assert data["heavy_files"][0]["path"] == "/tmp/large.bin"
assert data["open_ports"][0]["port"] == 22
assert data["top_processes"][0]["command"] == "node"
PY
}

test_get_open_ports_returns_valid_json() {
    # Reload original functions because the collect_metrics test stubs collectors.
    # shellcheck source=../sermos.sh
    source "$ROOT_DIR/sermos.sh"

    ss() {
        cat <<'EOF'
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
tcp   LISTEN 0      128    0.0.0.0:22        0.0.0.0:*
tcp   LISTEN 0      511    [::]:3000         [::]:*
udp   UNCONN 0      0      127.0.0.53:53     0.0.0.0:*
EOF
    }

    get_open_ports > "$TMP_DIR/ports.json"

    python3 - "$TMP_DIR/ports.json" <<'PY'
import json
import sys

ports = json.load(open(sys.argv[1], encoding="utf-8"))
assert ports == [
    {"port": 22, "protocol": "tcp", "service": "tcp"},
    {"port": 3000, "protocol": "tcp", "service": "tcp"},
    {"port": 53, "protocol": "udp", "service": "udp"},
]
PY
}

test_save_local_writes_metrics_to_configured_directory() {
    save_local '{"ok":true}'

    local output_file
    output_file="$(find "$METRICS_DIR" -type f -name 'servmon-metrics-*.json' | head -1)"
    [[ -n "$output_file" ]] || fail "save_local did not create a metrics file"
    grep -Fxq '{"ok":true}' "$output_file" || fail "save_local did not persist the metric payload"
}

test_send_to_api_requires_endpoint_and_key
test_send_to_api_posts_bearer_token_and_payload
test_collect_metrics_outputs_required_json_sections
test_get_open_ports_returns_valid_json
test_save_local_writes_metrics_to_configured_directory

echo "ok - agent tests passed"
