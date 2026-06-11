#!/usr/bin/env bats
# Tests for deleting saved network test reports:
#   - DELETE /api/nettest/reports/<filename> (super-only, single report)
#   - DELETE /api/nettest/reports (super-only, requires confirm phrase, deletes all)
#   - delete_nettest_report / delete_all_nettest_reports helpers
#   - app.js: delete buttons, "Clear all reports" with typed confirmation

bats_require_minimum_version 1.5.0

load test_helper

@test "web panel: delete_nettest_report rejects bad filenames and removes a real report" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$TEST_DIR" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

server.NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
report = server.NETTEST_REPORT_DIR / "nettest_wifi_20260101-000000_abcd1234.json"
report.write_text("{}", encoding="utf-8")

# Path traversal / invalid names rejected
for bad in ("../etc/passwd", "nettest_../x.json", "not-a-report.json", "nettest_x.txt"):
    try:
        server.delete_nettest_report(bad)
        raise AssertionError(f"expected ValueError for {bad!r}")
    except ValueError:
        pass

# Missing-but-valid filename returns False
assert server.delete_nettest_report("nettest_wifi_20260101-999999_zzzzzzzz.json") is False

# Real file is deleted
assert server.delete_nettest_report(report.name) is True
assert not report.exists()
PY
}

@test "web panel: delete_all_nettest_reports removes only nettest_*.json files" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$TEST_DIR" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

server.NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
for i in range(3):
    (server.NETTEST_REPORT_DIR / f"nettest_wifi_2026010{i}-000000_abcd{i}.json").write_text("{}", encoding="utf-8")
keep = server.NETTEST_REPORT_DIR / "not_a_report.json"
keep.write_text("{}", encoding="utf-8")

count = server.delete_all_nettest_reports()
assert count == 3, count
assert keep.exists()
assert list(server.NETTEST_REPORT_DIR.glob("nettest_*.json")) == []
PY
}

@test "web panel: DELETE /api/nettest/reports/<id> is super-only and removes the file" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$TEST_DIR" SERVER_CONF_FILE="$TEST_DIR/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-secret-nettestdel"
user_token = "user-secret-nettestdel"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

server.NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
report = server.NETTEST_REPORT_DIR / "nettest_wifi_20260101-000000_abcd1234.json"
report.write_text("{}", encoding="utf-8")

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(path, token, body=None):
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

# Non-super forbidden
server.RATE.clear()
handler = make_handler(f"/api/nettest/reports/{report.name}", user_token)
handler.do_DELETE()
assert handler.responses[0] in (401, 403), handler.responses
assert report.exists()

# Unknown filename -> 404
server.RATE.clear()
handler = make_handler("/api/nettest/reports/nettest_wifi_20260101-000000_missing0.json", super_token)
handler.do_DELETE()
assert handler.responses == [404], handler.responses

# Invalid filename -> 400
server.RATE.clear()
handler = make_handler("/api/nettest/reports/not-a-report.json", super_token)
handler.do_DELETE()
assert handler.responses == [400], handler.responses

# Super deletes the real report
server.RATE.clear()
handler = make_handler(f"/api/nettest/reports/{report.name}", super_token)
handler.do_DELETE()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["ok"] is True
assert not report.exists()
PY
}

@test "web panel: DELETE /api/nettest/reports requires the confirm phrase and clears all reports" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$TEST_DIR" SERVER_CONF_FILE="$TEST_DIR/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-secret-nettestclear"
user_token = "user-secret-nettestclear"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

server.NETTEST_REPORT_DIR.mkdir(parents=True, exist_ok=True)
for i in range(2):
    (server.NETTEST_REPORT_DIR / f"nettest_wifi_2026010{i}-000000_abcd{i}.json").write_text("{}", encoding="utf-8")

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(token, body):
    payload = json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = "/api/nettest/reports"
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

# Non-super forbidden
server.RATE.clear()
handler = make_handler(user_token, {"confirm": "DELETE ALL NETTEST REPORTS"})
handler.do_DELETE()
assert handler.responses[0] in (401, 403), handler.responses

# Wrong confirm phrase -> 400, nothing deleted
server.RATE.clear()
handler = make_handler(super_token, {"confirm": "nope"})
handler.do_DELETE()
assert handler.responses == [400], handler.responses
assert len(list(server.NETTEST_REPORT_DIR.glob("nettest_*.json"))) == 2

# Correct confirm phrase -> deletes all
server.RATE.clear()
handler = make_handler(super_token, {"confirm": "DELETE ALL NETTEST REPORTS"})
handler.do_DELETE()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["ok"] is True
assert payload["deleted"] == 2
assert list(server.NETTEST_REPORT_DIR.glob("nettest_*.json")) == []
PY
}

@test "app.js: per-report Delete button and 'Clear all reports' wiring" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'id="clearNettestReports"' "$app"
    grep -qF 'async function deleteNettestReport(filename)' "$app"
    grep -qF 'async function clearAllNettestReports()' "$app"
    grep -qF 'class="delete-nettest-report' "$app"
    grep -qF 'data-report-filename' "$app"

    block=$(awk '/^async function deleteNettestReport/,/^}/' "$app")
    grep -qF '/api/nettest/reports/' <<<"$block"
    grep -qF '"DELETE"' <<<"$block"

    block2=$(awk '/^async function clearAllNettestReports/,/^}/' "$app")
    grep -qF 'confirmTypedModal(' <<<"$block2"
    grep -qF 'DELETE ALL NETTEST REPORTS' <<<"$block2"
    grep -qF '/api/nettest/reports' <<<"$block2"
    grep -qF '"DELETE"' <<<"$block2"

    grep -qF 'function confirmTypedModal(title, message, requiredText, confirmLabel' "$app"
    grep -qF 'document.querySelector("#clearNettestReports").onclick = clearAllNettestReports;' "$app"
}
