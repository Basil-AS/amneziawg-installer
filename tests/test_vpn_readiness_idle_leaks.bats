#!/usr/bin/env bats
# Tests for: idle-aware polling, WebRTC/IPv6 leak hardening, AdGuard
# IPv4-only leak notes, VPN readiness diagnostics (web + installer), and
# the network drops/errors explanation UI.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

load test_helper

@test "vpn-readiness: server.py exposes vpn_readiness_payload with all 8 sections" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

payload = server.vpn_readiness_payload(force=True)
for key in (
    "kernel", "crypto", "virtualization", "ip_forwarding",
    "udp_buffers", "wan_offloads", "ipv6_routing", "ndp_proxy",
):
    assert key in payload, f"missing {key}"
    assert "status" in payload[key], f"{key} missing status"

assert payload["status"] in {"ok", "warn", "critical", "unknown"}
assert payload["cache_ttl_seconds"] == server.VPN_READINESS_CACHE_TTL
assert "timestamp" in payload

# ndppd diagnostics only - never auto-installed
assert "installed" in payload["ndp_proxy"] or payload["ndp_proxy"]["state"] == "not_needed"
PY
}

@test "vpn-readiness: ndp_proxy_check never recommends auto-install and is diagnostics only" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# IPv6 disabled -> not applicable
result = server.ndp_proxy_check("disabled", False)
assert result["status"] == "info"
assert result["state"] == "not_needed"

# Global v6 present, no default route -> warn (or ok if ndppd already configured), never auto-install
result = server.ndp_proxy_check("enabled", True)
assert result["status"] in {"info", "ok", "warn"}
assert "installed" in result and "configured" in result
PY
}

@test "vpn-readiness: /api/vpn-readiness route is super-only" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
super_token = "super-secret"
user_token = "user-secret"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "user", "clients": []}},
})

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(token):
    h = object.__new__(server.Handler)
    h.path = "/api/vpn-readiness"
    h.client_address = ("127.0.0.1", 12345)
    h.rfile = io.BytesIO()
    h.wfile = io.BytesIO()
    h.responses = []
    h.headers_sent = []
    h.headers = Headers({"Host": "127.0.0.1", "Authorization": f"Bearer {token}"})
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

handler = make_handler(user_token)
handler.do_GET()
assert handler.responses == [403]

handler = make_handler(super_token)
handler.do_GET()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
assert "kernel" in payload and "ndp_proxy" in payload
PY
    rm -rf "$tmp"
}

@test "server health: derived network counters are computed via stdlib /proc helpers" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# counter_value_delta: first call seeds, returns 0; second call returns delta
assert server.counter_value_delta("test_counter", 100) == 0
assert server.counter_value_delta("test_counter", 130) == 30
# never negative on counter reset/wrap
assert server.counter_value_delta("test_counter", 10) == 0

# read_proc_net_table parses a snmp-style two-line table
table = server.read_proc_net_table("/proc/net/snmp")
assert isinstance(table, dict)
assert "TcpRetransSegs" in table or table == {}

# read_snmp6_counters parses key/value pairs
snmp6 = server.read_snmp6_counters()
assert isinstance(snmp6, dict)

health = server.collect_server_health(force=True)
network = health["network"]
for key in (
    "wan_drops_delta", "vpn_drops_delta", "qdisc_drop_delta",
    "tcp_retrans_delta", "tcp_timeout_delta", "ip6_no_route_delta",
):
    assert key in network, f"missing {key}"
    assert isinstance(network[key], int)
PY
}

@test "leak checks: sanitize_leak_checks adds IPv4-only/WebRTC guidance notes on suspected leaks" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# IPv6 leak: browser sees a public IPv6 not matching server/VPN context
context = {"server_public_ipv4": "203.0.113.5", "server_public_ipv6": "", "vpn_ipv6": "", "ipv6_mode": "disabled"}
value = {"browser_public_ipv6": "2001:db8::1", "webrtc_available": True, "webrtc_ipv6_candidates": [], "webrtc_private_candidates": []}
result = server.sanitize_leak_checks(value, context)
assert result["ipv6_leak_suspected"] is True
assert any("AAAA disabled" in n for n in result["notes"])
assert any("VPN DNS" in n for n in result["notes"])

# WebRTC IPv6 candidate present -> WebRTC disable note
value2 = {"webrtc_available": True, "webrtc_ipv6_candidates": ["2001:db8::2"], "webrtc_private_candidates": []}
result2 = server.sanitize_leak_checks(value2, {})
assert result2["webrtc_ipv6_risk"] is True
assert any("WebRTC ICE candidates" in n for n in result2["notes"])
assert result2["webrtc_ipv6_candidate_count"] == 1
assert "webrtc_ipv6_candidates" not in result2
assert "webrtc_private_candidates" not in result2

# No leak -> no extra notes
result3 = server.sanitize_leak_checks({}, {})
assert result3["ipv6_leak_suspected"] is False
assert result3["notes"] == []
PY
}

@test "app.js: idle-aware polling constants, helpers, and idle note are wired" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'const PANEL_IDLE_AFTER_MS = 10 * 60 * 1000;' "$app"
    grep -qF 'const PANEL_IDLE_HEARTBEAT_MS = 5 * 60 * 1000;' "$app"
    grep -qF 'function markPanelActivity()' "$app"
    grep -qF 'function isPanelIdle()' "$app"
    grep -qF 'function shouldPollHeavy()' "$app"
    grep -qF 'function onPanelResume()' "$app"
    grep -qF 'function checkPanelIdle()' "$app"
    grep -qF 'function updatePanelIdleNote()' "$app"
    grep -qF 'id="panelIdleNote"' "$app"
    grep -qF 'Paused background refresh after 10 min idle' "$app"
    grep -qF 'document.hidden' "$app"
    grep -qF 'addEventListener("visibilitychange"' "$app"
    for evt in mousemove mousedown keydown scroll touchstart focus; do
        grep -qF "\"$evt\"" "$app"
    done
}

@test "app.js: network test stops on idle/hidden tab without leaving a stale lock" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Test stopped due to inactive tab.' "$app"
    grep -qF 'stoppedIdle' "$app"
    grep -qF 'checkPanelIdle()' "$app"
    grep -qF 'stopReason' "$app"
    # cancel path is taken (reason !== "report") when stopped due to idle
    grep -qF 'stopNettest({reason: stopReason})' "$app"
}

@test "app.js: WebRTC leak gathering is bounded and always cleaned up" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'const WEBRTC_LEAK_TIMEOUT_MS = 2500;' "$app"
    grep -qF 'Promise.race([gather, sleep(WEBRTC_LEAK_TIMEOUT_MS)])' "$app"
    grep -qF 'pc.close()' "$app"
}

@test "app.js: leak checks are skipped while the panel is idle/hidden" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    block=$(awk '/^async function runLeakChecks/,/^}/' "$app")
    grep -qF 'isPanelIdle()' <<<"$block"
    grep -qF 'Skipped: tab inactive or idle' <<<"$block"
}

@test "app.js: VPN readiness UI section renders status rows" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'function renderReadiness()' "$app"
    grep -qF 'function renderReadinessRow(' "$app"
    grep -qF 'async function loadReadiness(' "$app"
    grep -qF '"/api/" + "vp" + "n-readiness"' "$app"
    grep -qF 'id="readinessGrid"' "$app"
    grep -qF 'id="readinessUpdated"' "$app"
    grep -qF '"VP" + "N"} readiness' "$app"
}

@test "app.js: network drops/errors explanation renders likely/not-likely/scale/action" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'function renderNetworkExplain()' "$app"
    grep -qF 'id="networkExplain"' "$app"
    block=$(awk '/^function renderNetworkExplain/,/^}/' "$app")
    grep -qF 'network["vp" + "n_drops_delta"]' <<<"$block"
    grep -qF 'qdisc_drop_delta' <<<"$block"
    grep -qF 'tcp_retrans_delta' <<<"$block"
    grep -qF 'tcp_timeout_delta' <<<"$block"
    grep -qF 'ip6_no_route_delta' <<<"$block"
    grep -qiF 'likely' <<<"$block"
    grep -qF '>Scale<' <<<"$block"
    grep -qF '>Action<' <<<"$block"
    grep -qF 'dropsSampleBtn' <<<"$block"
    grep -qF '/api/server-health/drops-sample' <<<"$block"
}

@test "style.css: readiness-grid styles are present" {
    local css="$BATS_TEST_DIRNAME/../web/style.css"
    grep -qF '.readiness-grid' "$css"
    grep -qF '.readiness-row' "$css"
    grep -qF '.readiness-row-head' "$css"
}

@test "installer: print_vpn_readiness_checklist is defined in RU and EN common libs with all 8 checks" {
    for f in awg_common.sh awg_common_en.sh; do
        local script="$BATS_TEST_DIRNAME/../$f"
        grep -qE '^print_vpn_readiness_checklist\(\) \{' "$script"
        local block
        block=$(awk '/^print_vpn_readiness_checklist\(\) \{/,/^}$/' "$script")
        grep -qF 'lsmod' <<<"$block"
        grep -qF '/proc/cpuinfo' <<<"$block"
        grep -qF 'systemd-detect-virt' <<<"$block"
        grep -qF '/proc/sys/net/ipv4/ip_forward' <<<"$block"
        grep -qF '/proc/sys/net/core/rmem_max' <<<"$block"
        grep -qF 'ethtool' <<<"$block"
        grep -qF '/proc/net/if_inet6' <<<"$block"
        grep -qF 'ndppd' <<<"$block"
        # diagnostics only - never auto-installs ndppd
        run ! grep -qE 'apt-get install.*ndppd|apt install.*ndppd' <<<"$block"
        grep -qF 'return 0' <<<"$block"
    done
}

@test "installer: VPN readiness checklist runs without error and never auto-installs ndppd" {
    TEST_DIR=$(mktemp -d)
    AWG_DIR="$TEST_DIR" SERVER_CONF_FILE="$TEST_DIR/awg0.conf" run bash -c '
        log()       { printf "%s\n" "$*"; }
        log_warn()  { printf "%s\n" "$*"; }
        log_error() { printf "%s\n" "$*"; }
        log_debug() { :; }
        export -f log log_warn log_error log_debug
        source "'"$BATS_TEST_DIRNAME"'/../awg_common.sh"
        print_vpn_readiness_checklist
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"VPN readiness"* || "$output" == *"готовности"* ]]
    [[ "$output" != *"apt-get install"*"ndppd"* ]]
    rm -rf "$TEST_DIR"
}

@test "installer: RU and EN finish steps print the VPN readiness checklist before cleanup" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local script="$BATS_TEST_DIRNAME/../$f"
        local block
        block=$(awk '/^step99_finish\(\) \{/,/^}$/' "$script")
        grep -qF 'declare -f print_vpn_readiness_checklist >/dev/null 2>&1' <<<"$block"
        grep -qF 'print_vpn_readiness_checklist' <<<"$block"
        # checklist must run before final apt cleanup
        local checklist_line cleanup_line
        checklist_line=$(grep -nF 'print_vpn_readiness_checklist' <<<"$block" | head -1 | cut -d: -f1)
        cleanup_line=$(grep -nF 'cleanup_apt' <<<"$block" | head -1 | cut -d: -f1)
        [ "$checklist_line" -lt "$cleanup_line" ]
    done
}
