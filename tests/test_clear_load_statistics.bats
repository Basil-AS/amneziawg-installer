#!/usr/bin/env bats
# Tests for clearing server load/health history statistics:
#   - DELETE /api/server-health/history (super-only, requires confirm phrase)
#   - clear_health_history() helper
#   - app.js: "Clear load statistics" button with typed confirmation

bats_require_minimum_version 1.5.0

load test_helper

@test "web panel: clear_health_history removes sample files and resets the history cache" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$TEST_DIR" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

server.HEALTH_HISTORY_DIR.mkdir(parents=True, exist_ok=True)
for i in range(2):
    (server.HEALTH_HISTORY_DIR / f"samples-2026010{i}.jsonl").write_text('{"ts": 1}\n', encoding="utf-8")
keep = server.HEALTH_HISTORY_DIR / "not-a-sample.txt"
keep.write_text("keep", encoding="utf-8")

server.SERVER_HEALTH_HISTORY_CACHE["1h"] = {"ts": 0, "value": {}}

count = server.clear_health_history()
assert count == 2, count
assert keep.exists()
assert list(server.HEALTH_HISTORY_DIR.glob("samples-*.jsonl")) == []
assert server.SERVER_HEALTH_HISTORY_CACHE == {}
PY
}

@test "web panel: DELETE /api/server-health/history is super-only and requires the confirm phrase" {
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

super_token = "super-secret-clearload"
user_token = "user-secret-clearload"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

server.HEALTH_HISTORY_DIR.mkdir(parents=True, exist_ok=True)
sample = server.HEALTH_HISTORY_DIR / "samples-20260101.jsonl"
sample.write_text('{"ts": 1}\n', encoding="utf-8")

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(token, body):
    payload = json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = "/api/server-health/history"
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
handler = make_handler(user_token, {"confirm": "CLEAR LOAD STATISTICS"})
handler.do_DELETE()
assert handler.responses[0] in (401, 403), handler.responses
assert sample.exists()

# Wrong confirm phrase -> 400, file kept
server.RATE.clear()
handler = make_handler(super_token, {"confirm": "nope"})
handler.do_DELETE()
assert handler.responses == [400], handler.responses
assert sample.exists()

# Correct confirm phrase -> deletes history
server.RATE.clear()
handler = make_handler(super_token, {"confirm": "CLEAR LOAD STATISTICS"})
handler.do_DELETE()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["ok"] is True
assert payload["deleted"] == 1
assert not sample.exists()
PY
}

@test "app.js: 'Clear load statistics' button uses typed confirmation and DELETEs server-health history" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'id="clearHealthHistory"' "$app"
    grep -qF 'async function clearLoadStatistics()' "$app"

    block=$(awk '/^async function clearLoadStatistics/,/^}/' "$app")
    grep -qF 'confirmTypedModal(' <<<"$block"
    grep -qF 'CLEAR LOAD STATISTICS' <<<"$block"
    grep -qF '/api/server-health/history' <<<"$block"
    grep -qF '"DELETE"' <<<"$block"

    grep -qF 'clearButton.onclick = clearLoadStatistics;' "$app"
}
