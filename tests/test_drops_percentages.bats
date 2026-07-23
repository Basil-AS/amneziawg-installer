#!/usr/bin/env bats
# Tests for network drops/errors percentage diagnostics:
#   - pct() helper
#   - collect_server_health() exposes *_drop_pct / *_error_pct and the
#     packet/segment/request totals they're computed from
#   - raw_drop_counters() / drops_sample_report() and the
#     /api/server-health/drops-sample endpoint (super-only, before/after)

bats_require_minimum_version 1.5.0

load test_helper

@test "web panel: pct() computes rounded percentages and handles edge cases" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

assert server.pct(1, 1000) == 0.1
assert server.pct(0, 1000) == 0.0
assert server.pct(5, 0) is None
assert server.pct(5, None) is None
assert server.pct(None, 1000) is None
assert server.pct(50, 200) == 25.0
assert server.pct(123, 1000, 4) == 12.3
PY
}

@test "web panel: health history counts incident starts, not every warning sample" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
spec = importlib.util.spec_from_file_location("server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
rows = [{"status": status, "cpu_usage_percent": 10, "memory_used_percent": 20, "load1": 0.1,
         "memory_available_bytes": 1, "disk_used_percent": 20, "disk_free_bytes": 1,
         "conntrack_used_percent": 1, "conntrack_count": 1,
         "wan_rx_dropped": 0, "wan_tx_dropped": 0, "vpn_rx_dropped": 0, "vpn_tx_dropped": 0,
         "wan_rx_errors": 0, "wan_tx_errors": 0, "vpn_rx_errors": 0, "vpn_tx_errors": 0,
         "python_rss_bytes": 1, "python_fd_count": 1, "python_threads": 1}
        for status in ["ok", "warn", "warn", "warn", "ok", "warn", "critical", "critical", "ok"]]
out = server.summarize_health_history(rows)
assert out["counts"] == {"samples": 9, "warn": 2, "critical": 1, "warn_samples": 4, "critical_samples": 2}
PY
}

@test "web panel: collect_server_health exposes drop/error percentages and totals" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# First call seeds the previous-counter state; second call yields real deltas.
server.collect_server_health(force=True)
health = server.collect_server_health(force=True)
network = health["network"]
for key in (
    "wan_packets_delta", "wan_drop_pct", "wan_errors_delta", "wan_error_pct",
    "vpn_packets_delta", "vpn_drop_pct", "vpn_errors_delta", "vpn_error_pct",
    "qdisc_sent_delta", "qdisc_drop_pct",
    "tcp_segs_out_delta", "tcp_retrans_pct", "tcp_timeout_pct",
    "ip6_out_requests_delta", "ip6_no_route_pct",
):
    assert key in network, f"missing {key}"
PY
}

@test "web panel: raw_drop_counters and drops_sample_report compute before/after deltas and percentages" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

before = {
    "timestamp": "t0", "wan_iface": "eth0", "vpn_iface": "awg0",
    "wan_rx_dropped": 10, "wan_tx_dropped": 5, "wan_rx_errors": 0, "wan_tx_errors": 0,
    "wan_rx_packets": 1000, "wan_tx_packets": 1000,
    "vpn_rx_dropped": 0, "vpn_tx_dropped": 0, "vpn_rx_errors": 0, "vpn_tx_errors": 0,
    "vpn_rx_packets": 500, "vpn_tx_packets": 500,
    "qdisc_dropped": 2, "qdisc_sent_packets": 2000,
    "tcp_retrans_segs": 1, "tcp_out_segs": 1000, "tcp_timeouts": 0,
    "ip6_out_no_routes": 0, "ip6_out_requests": 100,
}
after = dict(before)
after.update({
    "timestamp": "t1",
    "wan_rx_dropped": 11, "wan_tx_dropped": 6,  # +1 +1 = +2 drops
    "wan_rx_packets": 1100, "wan_tx_packets": 1100,  # +200 packets
    "qdisc_dropped": 4, "qdisc_sent_packets": 2200,  # +2 dropped, +200 sent
    "tcp_retrans_segs": 3, "tcp_out_segs": 1100,  # +2 retrans, +100 segs
    "ip6_out_no_routes": 1, "ip6_out_requests": 110,  # +1 no-route, +10 requests
})

report = server.drops_sample_report(before, after, 60)
assert report["duration_seconds"] == 60
assert report["wan"]["drops_delta"] == 2
assert report["wan"]["packets_delta"] == 200
assert report["wan"]["drop_pct"] == round(100.0 * 2 / 202, 2)
assert report["qdisc"]["drop_delta"] == 2
assert report["qdisc"]["sent_delta"] == 200
assert report["tcp"]["retrans_delta"] == 2
assert report["tcp"]["out_segs_delta"] == 100
assert report["tcp"]["retrans_pct"] == round(100.0 * 2 / 100, 2)
assert report["ipv6"]["no_route_delta"] == 1
assert report["ipv6"]["out_requests_delta"] == 10

# raw_drop_counters() returns a real, self-consistent snapshot
snap = server.raw_drop_counters()
for key in before:
    assert key in snap, f"missing {key}"
PY
}

@test "web panel: /api/server-health/drops-sample is super-only and returns a before/after report" {
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

super_token = "super-secret-drops"
user_token = "user-secret-drops"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(method, path, token=None, body=None):
    payload = b"" if body is None else json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = path
    h.client_address = ("127.0.0.1", 12345)
    h.rfile = io.BytesIO(payload)
    h.wfile = io.BytesIO()
    h.responses = []
    h.headers_sent = []
    headers = Headers({"Host": "127.0.0.1", "Content-Length": str(len(payload))})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    h.headers = headers
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

# user (non-super) is forbidden
server.RATE.clear()
handler = make_handler("POST", "/api/server-health/drops-sample", token=user_token, body={"duration_seconds": 1})
handler.do_POST()
assert handler.responses[0] in (401, 403), handler.responses

# super gets a 1-second before/after report (duration clamped to >=1)
server.RATE.clear()
handler = make_handler("POST", "/api/server-health/drops-sample", token=super_token, body={"duration_seconds": 1})
handler.do_POST()
assert handler.responses == [200], handler.responses
report = json.loads(handler.wfile.getvalue().decode())
assert report["duration_seconds"] == 1
for section in ("wan", "vpn", "qdisc", "tcp", "ipv6"):
    assert section in report
assert "before" in report and "after" in report
PY
    rm -rf "$tmp"
}
