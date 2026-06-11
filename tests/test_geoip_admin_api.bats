#!/usr/bin/env bats
# Tests for the GeoIP admin API:
#   - GET/PUT /api/geoip/providers (super-only, masked tokens, keep-on-mask)
#   - POST /api/geoip/providers/test
#   - GET /api/geoip/databases/status
#   - POST /api/geoip/databases/update (calls `manage geoip update-dbs`)
#   - POST /api/geoip/auto-update (calls `manage geoip auto-update enable|disable`)

bats_require_minimum_version 1.5.0

load test_helper

@test "web panel: geoip_providers_config_for_admin masks tokens and write_geoip_providers_config preserves them on mask" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." AWG_DIR="$TEST_DIR" python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# Seed a provider with a real token
server.write_geoip_providers_config({
    "providers": {"2ip": {"enabled": True, "token": "real-secret-token"}},
})

admin_view = server.geoip_providers_config_for_admin()
assert admin_view["providers"]["2ip"]["token"] == server.GEOIP_TOKEN_MASK
assert admin_view["providers"]["2ip"]["has_token"] is True

# Saving with the masked placeholder must keep the real token
server.write_geoip_providers_config({
    "providers": {"2ip": {"enabled": False, "token": server.GEOIP_TOKEN_MASK}},
})
raw = server.load_geoip_providers_config()
assert raw["providers"]["2ip"]["token"] == "real-secret-token"
assert raw["providers"]["2ip"]["enabled"] is False

# Unknown provider names and fields are dropped
server.write_geoip_providers_config({
    "providers": {"evil": {"enabled": True}, "2ip": {"enabled": True, "not_a_field": "x"}},
    "databases": {"evil_db": {"url": "http://x"}, "maxmind_city": {"url": "https://example/City.mmdb"}},
})
raw2 = server.load_geoip_providers_config()
assert "evil" not in raw2["providers"]
assert "not_a_field" not in raw2["providers"]["2ip"]
assert "evil_db" not in raw2["databases"]
assert raw2["databases"]["maxmind_city"]["url"] == "https://example/City.mmdb"
PY
}

@test "web panel: GET/PUT /api/geoip/providers is super-only" {
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

super_token = "super-secret-geoip"
user_token = "user-secret-geoip"
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

# GET forbidden for non-super
server.RATE.clear()
handler = make_handler("GET", "/api/geoip/providers", token=user_token)
handler.do_GET()
assert handler.responses[0] in (401, 403), handler.responses

# GET ok for super
server.RATE.clear()
handler = make_handler("GET", "/api/geoip/providers", token=super_token)
handler.do_GET()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert "providers" in payload and "databases" in payload

# PUT forbidden for non-super
server.RATE.clear()
handler = make_handler("PUT", "/api/geoip/providers", token=user_token, body={"providers": {}})
handler.do_PUT()
assert handler.responses[0] in (401, 403), handler.responses

# PUT ok for super, persists config
server.RATE.clear()
handler = make_handler("PUT", "/api/geoip/providers", token=super_token, body={
    "providers": {"ipinfo": {"enabled": True, "token": "tok123"}},
})
handler.do_PUT()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["ok"] is True
assert payload["providers"]["ipinfo"]["enabled"] is True
assert payload["providers"]["ipinfo"]["token"] == server.GEOIP_TOKEN_MASK

raw = server.load_geoip_providers_config()
assert raw["providers"]["ipinfo"]["token"] == "tok123"
PY
}

@test "web panel: POST /api/geoip/providers/test rejects unknown providers and reports fetch results" {
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

super_token = "super-secret-geoiptest"
server.write_tokens({"super_token_hash": server.token_hash(super_token), "users": {}})

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(path, body):
    payload = json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = path
    h.client_address = ("127.0.0.1", 12345)
    h.rfile = io.BytesIO(payload)
    h.wfile = io.BytesIO()
    h.responses = []
    h.headers_sent = []
    h.headers = Headers({"Host": "127.0.0.1", "Content-Length": str(len(payload)), "Authorization": f"Bearer {super_token}"})
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

# Unknown provider -> 400
server.RATE.clear()
handler = make_handler("/api/geoip/providers/test", {"provider": "not-a-provider"})
handler.do_POST()
assert handler.responses == [400], handler.responses

# Disabled provider (default config) -> 200 with ok: False
server.RATE.clear()
handler = make_handler("/api/geoip/providers/test", {"provider": "2ip"})
handler.do_POST()
assert handler.responses == [200], handler.responses
result = json.loads(handler.wfile.getvalue().decode())
assert result["ok"] is False
assert "error" in result

# ip-api is always enabled (no token needed) -> ok: True with a result dict
server.RATE.clear()
handler = make_handler("/api/geoip/providers/test", {"provider": "ip-api"})
handler.do_POST()
assert handler.responses == [200], handler.responses
result2 = json.loads(handler.wfile.getvalue().decode())
assert "ok" in result2
PY
}

@test "web panel: GET /api/geoip/databases/status returns per-db file info and auto-update timer state" {
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

super_token = "super-secret-geoipdb"
user_token = "user-secret-geoipdb"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

# Create a fake mmdb file on disk
geoip_dir = Path(os.environ["AWG_DIR"]) / "geoip"
geoip_dir.mkdir(parents=True, exist_ok=True)
(geoip_dir / "GeoLite2-City.mmdb").write_bytes(b"fake")
(geoip_dir / "geoip_db_versions.json").write_text(json.dumps({
    "maxmind_city": {"sha256": "abc123", "status": "ok"}
}), encoding="utf-8")

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(path, token):
    h = object.__new__(server.Handler)
    h.path = path
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

server.RATE.clear()
handler = make_handler("/api/geoip/databases/status", user_token)
handler.do_GET()
assert handler.responses[0] in (401, 403), handler.responses

server.RATE.clear()
handler = make_handler("/api/geoip/databases/status", super_token)
handler.do_GET()
assert handler.responses == [200], handler.responses
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["databases"]["maxmind_city"]["present"] is True
assert payload["databases"]["maxmind_city"]["sha256"] == "abc123"
assert payload["databases"]["maxmind_asn"]["present"] is False
assert "auto_update" in payload
for key in ("enabled", "active", "enabled_state", "active_state"):
    assert key in payload["auto_update"]
PY
}

@test "web panel: POST /api/geoip/databases/update and /api/geoip/auto-update call manage geoip subcommands" {
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

super_token = "super-secret-geoipupdate"
server.write_tokens({"super_token_hash": server.token_hash(super_token), "users": {}})

calls = []
class Result:
    returncode = 0
    stdout = "ok"
    stderr = ""

def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append(args)
    return Result()
server.run_manage = fake_run_manage

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(path, body=None):
    payload = b"" if body is None else json.dumps(body).encode()
    h = object.__new__(server.Handler)
    h.path = path
    h.client_address = ("127.0.0.1", 12345)
    h.rfile = io.BytesIO(payload)
    h.wfile = io.BytesIO()
    h.responses = []
    h.headers_sent = []
    h.headers = Headers({"Host": "127.0.0.1", "Content-Length": str(len(payload)), "Authorization": f"Bearer {super_token}"})
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

server.RATE.clear()
handler = make_handler("/api/geoip/databases/update", {})
handler.do_POST()
assert handler.responses == [200], handler.responses
assert calls[-1] == ("geoip", "update-dbs")

server.RATE.clear()
handler = make_handler("/api/geoip/auto-update", {"enabled": True})
handler.do_POST()
assert handler.responses == [200], handler.responses
assert calls[-1] == ("geoip", "auto-update", "enable")

server.RATE.clear()
handler = make_handler("/api/geoip/auto-update", {"enabled": False})
handler.do_POST()
assert handler.responses == [200], handler.responses
assert calls[-1] == ("geoip", "auto-update", "disable")
PY
}
