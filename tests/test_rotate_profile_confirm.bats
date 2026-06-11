#!/usr/bin/env bats
# Tests for the hardened "Rotate profile" confirmation modal in web/app.js:
#   - checkbox acknowledgement + typed "ROTATE" confirmation
#   - confirm button disabled until both match
#   - backend /api/profile/rotate (and legacy /api/server/rotate-profile)
#     still require confirm == "ROTATE" (server-wide rotation)

bats_require_minimum_version 1.5.0

load test_helper

@test "app.js: rotateProfileModal requires an acknowledgement checkbox and typed ROTATE confirmation" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    block=$(awk '/^function rotateProfileModal/,/^}/' "$app")
    grep -qF 'id="rotateProfileAck"' <<<"$block"
    grep -qF 'type="checkbox"' <<<"$block"
    grep -qF 'id="rotateProfileConfirmText"' <<<"$block"
    grep -qF 'id="rotateProfileConfirmButton"' <<<"$block"
    grep -qF 'disabled' <<<"$block"
    grep -qF '"ROTATE"' <<<"$block"
    grep -qF 'all clients' <<<"$block"

    # Confirm button only enabled when both the checkbox and typed text match
    grep -qF 'confirmButton.disabled = !(ack.checked && confirmText.value === "ROTATE")' <<<"$block"
    grep -qF "ack.addEventListener(\"change\", updateEnabled)" <<<"$block"
    grep -qF "confirmText.addEventListener(\"input\", updateEnabled)" <<<"$block"
}

@test "web panel: /api/profile/rotate and /api/server/rotate-profile require confirm == ROTATE (server-wide)" {
    local server="$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '"/api/server/rotate-profile", "/api/profile/rotate"' "$server"
    grep -qF 'body.get("confirm") != "ROTATE"' "$server"
    grep -qF 'raise ValueError("confirmation required")' "$server"
    grep -qF 'run_manage("server", "rotate-profile"' "$server"
}

@test "web panel: POST /api/profile/rotate is super-only and rejects missing/incorrect confirm" {
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

super_token = "super-secret-rotate"
user_token = "user-secret-rotate"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(token, body):
    payload = json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = "/api/profile/rotate"
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
handler = make_handler(user_token, {"preset": "default", "confirm": "ROTATE"})
handler.do_POST()
assert handler.responses[0] in (401, 403), handler.responses

# Missing confirm -> 400
server.RATE.clear()
handler = make_handler(super_token, {"preset": "default"})
handler.do_POST()
assert handler.responses == [400], handler.responses

# Wrong confirm -> 400
server.RATE.clear()
handler = make_handler(super_token, {"preset": "default", "confirm": "rotate"})
handler.do_POST()
assert handler.responses == [400], handler.responses
PY
}
