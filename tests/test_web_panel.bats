#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "web/server.py compiles with Python stdlib" {
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -m py_compile "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "installer deploys awg-web.service and token store" {
    grep -qF 'awg-web.service' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'Authorization' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'validate_bind_addr "$AWG_WEB_BIND"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'allow_web_panel_ufw()' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'Веб-панель привязана публично' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -qF 'ufw allow "${p2p_from}:${p2p_to}/tcp"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "installer must not open the full P2P range globally"
    fi
}

@test "installer writes root-only INSTALL_SUMMARY with URLs credentials options and backups" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local tmp server_conf summary backup_count
    tmp=$(mktemp -d)
    server_conf="$tmp/awg0.conf"
    mkdir -p "$tmp/awg/web"
    printf '#_Name = my_phone\n[Peer]\n#_Name = my_laptop\n[Peer]\n' > "$server_conf"
    AWG_DIR="$tmp/awg" SERVER_CONF_FILE="$server_conf" bash -c '
        source <(sed -n "/^route_mode_label() {$/,/^step99_finish() {$/p" "$0" | head -n -1)
        SCRIPT_VERSION="5.13.0"
        AWG_REPO="Basil-AS/amneziawg-installer"
        AWG_SERVER_NAME="sunny-sweden"
        AWG_ENDPOINT="64.112.125.125"
        AWG_PORT="50729"
        AWG_TUNNEL_SUBNET="10.9.9.1/24"
        ALLOWED_IPS_MODE="1"
        ALLOWED_IPS="0.0.0.0/0"
        AWG_IPV6_ENABLED="1"
        AWG_IPV6_MODE="routed"
        AWG_IPV6_SUBNET="2a13:7c82:101f:30::/64"
        AWG_WEB_ENABLED="1"
        AWG_WEB_BIND="0.0.0.0"
        AWG_WEB_PORT="8443"
        AWG_WEB_SUPER_TOKEN_ONCE="raw-super-token"
        AWG_ADGUARD_ENABLED="1"
        AWG_ADGUARD_PORT="3000"
        AWG_ADGUARD_DIR="/root/awg/adguard"
        AG_USERNAME="admin"
        AG_PASSWORD="adguard-pass"
        AWG_PRESET="mobile"
        AWG_Jc="3"; AWG_Jmin="30"; AWG_Jmax="90"; AWG_S1="1"; AWG_S2="2"; AWG_S3="3"; AWG_S4="4"
        AWG_H1="1-2"; AWG_H2="3-4"; AWG_H3="5-6"; AWG_H4="7-8"; AWG_I1="1:2"
        AWG_P2P_BASE_PORT="20000"; AWG_P2P_PORTS_PER_CLIENT="3"; AWG_FULLCONE_NAT="0"
        MANAGE_SCRIPT_PATH="/root/awg/manage_amneziawg.sh"
        COMMON_SCRIPT_PATH="/root/awg/awg_common.sh"
        LOG_FILE="/root/awg/install_amneziawg.log"
        STATE_FILE="/root/awg/.install_state"
        write_install_summary
        write_install_summary
    ' "$installer"
    summary="$tmp/awg/INSTALL_SUMMARY.txt"
    [ -f "$summary" ]
    [ "$(stat -c '%a' "$summary")" = "600" ]
    backup_count=$(find "$tmp/awg" -maxdepth 1 -name 'INSTALL_SUMMARY.txt.bak.*' | wc -l)
    [ "$backup_count" -eq 1 ]
    grep -qF 'Public URL: https://64.112.125.125:8443' "$summary"
    grep -qF 'WARNING: Web Panel is publicly exposed' "$summary"
    grep -qF 'Super token: raw-super-token' "$summary"
    grep -qF 'Token file:' "$summary"
    grep -qF '[AdGuard Home]' "$summary"
    grep -qF 'Admin password: adguard-pass' "$summary"
    grep -qF 'Endpoint: 64.112.125.125' "$summary"
    grep -qF 'Route mode: route-all' "$summary"
    grep -qF 'Preset: mobile' "$summary"
    grep -qF 'IPv6 mode: routed' "$summary"
    grep -qF 'IPv6 client subnet: 2a13:7c82:101f:30::/64' "$summary"
    grep -qF 'Config directory:' "$summary"
    grep -qF '[Useful commands]' "$summary"
    grep -qF '[WG Tunnel URL Import]' "$summary"
    grep -qF '/import/my_phone/<token>' "$summary"
    rm -rf "$tmp"
}

@test "installer summary handles local-only web bind without public URL" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local tmp summary
    tmp=$(mktemp -d)
    mkdir -p "$tmp/awg"
    AWG_DIR="$tmp/awg" SERVER_CONF_FILE="$tmp/missing.conf" bash -c '
        source <(sed -n "/^route_mode_label() {$/,/^step99_finish() {$/p" "$0" | head -n -1)
        SCRIPT_VERSION="5.13.0"; AWG_REPO="Basil-AS/amneziawg-installer"; AWG_ENDPOINT="203.0.113.10"
        AWG_PORT="51820"; AWG_TUNNEL_SUBNET="10.9.9.1/24"; ALLOWED_IPS_MODE="2"; ALLOWED_IPS="0.0.0.0/5"
        AWG_IPV6_ENABLED="0"; AWG_IPV6_MODE="legacy"; AWG_WEB_ENABLED="1"; AWG_WEB_BIND="127.0.0.1"; AWG_WEB_PORT="8443"
        AWG_ADGUARD_ENABLED="0"; AWG_ADGUARD_PORT="3000"; AWG_Jc="3"; AWG_Jmin="30"; AWG_Jmax="90"
        AWG_S1="1"; AWG_S2="2"; AWG_S3="3"; AWG_S4="4"; AWG_H1="1-2"; AWG_H2="3-4"; AWG_H3="5-6"; AWG_H4="7-8"
        AWG_P2P_BASE_PORT="20000"; AWG_P2P_PORTS_PER_CLIENT="3"; AWG_FULLCONE_NAT="0"
        MANAGE_SCRIPT_PATH="/root/awg/manage_amneziawg.sh"; COMMON_SCRIPT_PATH="/root/awg/awg_common.sh"; LOG_FILE="/root/awg/install_amneziawg.log"; STATE_FILE="/root/awg/.install_state"
        write_install_summary
    ' "$installer"
    summary="$tmp/awg/INSTALL_SUMMARY.txt"
    grep -qF 'Public URL: not exposed' "$summary"
    grep -qF 'Local URL: https://127.0.0.1:8443' "$summary"
    grep -qF 'SSH tunnel: ssh -L 8443:127.0.0.1:8443 root@203.0.113.10' "$summary"
    grep -qF 'Enabled: no' "$summary"
    if grep -qF 'Public URL: https://' "$summary"; then
        fail "local-only bind must not advertise a public URL"
    fi
    rm -rf "$tmp"
}

@test "web panel defaults to VPN gateway instead of public bind" {
    grep -qF 'AWG_WEB_BIND="10.9.9.1"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AWG_WEB_BIND="10.9.9.1"' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF '10.9.9.1", int(os.environ.get("AWG_WEB_PORT", "8443"))' "$BATS_TEST_DIRNAME/../web/server.py"
    if sed -n '/# Инициализация переменных/,/# Загрузка конфига/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -qF 'AWG_WEB_BIND="0.0.0.0"'; then
        fail "web panel must not default to public bind"
    fi
    grep -qF 'After=network-online.target' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -qF 'Requires=awg-quick@awg0.service' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "web panel service must not hard-require awg-quick"
    fi
    grep -qF 'RestartSec=3' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "installer summary handles VPN-only web bind without public URL" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local tmp summary
    tmp=$(mktemp -d)
    run bash -c "
        set -e
        source <(sed -n '/^route_mode_label()/,/^}/p; /^server_ipv6_addr_for_summary()/,/^}/p; /^write_install_summary()/,/^}/p' '$installer')
        AWG_DIR='$tmp/awg'; mkdir -p \"\$AWG_DIR\"
        AWG_ENDPOINT='198.51.100.10'; AWG_PORT='51820'; AWG_TUNNEL_SUBNET='10.9.9.1/24'
        ALLOWED_IPS_MODE='2'; ALLOWED_IPS='0.0.0.0/0'; AWG_SERVER_NAME='vpn-only'
        AWG_IPV6_ENABLED='0'; AWG_IPV6_MODE='legacy'; AWG_WEB_ENABLED='1'; AWG_WEB_BIND='10.9.9.1'; AWG_WEB_PORT='8443'
        AWG_ADGUARD_ENABLED='0'; AWG_ADGUARD_PORT='3000'; AWG_Jc='3'; AWG_Jmin='30'; AWG_Jmax='90'; AWG_PRESET='default'
        AWG_P2P_BASE_PORT='20000'; AWG_P2P_PORTS_PER_CLIENT='3'; AWG_FULLCONE_NAT='0'
        SERVER_CONF_FILE='$tmp/missing.conf'; MANAGE_SCRIPT_PATH='/root/awg/manage_amneziawg.sh'; COMMON_SCRIPT_PATH='/root/awg/awg_common.sh'; LOG_FILE='/root/awg/install_amneziawg.log'; STATE_FILE='/root/awg/.install_state'
        write_install_summary
    "
    [ "$status" -eq 0 ]
    summary="$tmp/awg/INSTALL_SUMMARY.txt"
    grep -qF 'Public URL: not exposed' "$summary"
    grep -qF 'VPN URL: https://10.9.9.1:8443' "$summary"
    grep -qF 'Exposure warning: none' "$summary"
    rm -rf "$tmp"
}

@test "English installer deploys repository web assets instead of legacy inline panel" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    if grep -qF 'TOKEN_FILE = WEB_DIR / "auth_token"' "$installer"; then
        fail "EN installer must not deploy legacy inline token file panel"
    fi
    if grep -qF 'cat > "$web_dir/server.py"' "$installer"; then
        fail "EN installer must deploy repository web assets, not inline server.py"
    fi
    grep -qF 'tokens.json' "$installer"
    for asset in server.py index.html style.css app.js favicon.svg; do
        grep -qF "for asset in server.py index.html style.css app.js favicon.svg" "$installer"
        [ -f "$BATS_TEST_DIRNAME/../web/$asset" ]
    done
}

@test "web index uses only local assets" {
    if grep -qE 'cdn\\.tailwindcss\\.com|cdn\\.jsdelivr\\.net|unpkg\\.com|cdnjs\\.cloudflare\\.com|https?://' "$BATS_TEST_DIRNAME/../web/index.html"; then
        fail "web index must use local assets only"
    fi
    grep -q 'style.css' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -q 'vendor/tailwindcss.js' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -q 'vendor/apexcharts.min.js' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -q 'app.js' "$BATS_TEST_DIRNAME/../web/index.html"
    [ -s "$BATS_TEST_DIRNAME/../web/vendor/tailwindcss.js" ]
    [ -s "$BATS_TEST_DIRNAME/../web/vendor/apexcharts.min.js" ]
}

@test "web panel exposes RBAC and token controls" {
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens/([^/]+)/name' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'super_token_hash' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -A4 -qF 'if u.path == "/api/clients":' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -A4 'if u.path == "/api/clients":' "$BATS_TEST_DIRNAME/../web/server.py" | grep -qF 'require_super'
}

@test "web server hardening keeps bounded rate, body, logs, and token storage" {
    grep -qF 'RATE_LOCK = threading.Lock()' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'RATE_CLEANUP_INTERVAL = 60' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'MAX_JSON_BODY = 64 * 1024' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'TOKENS_LOCK = threading.RLock()' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'def tail_lines(' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Content-Security-Policy' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF "default-src 'self'" "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF "object-src 'none'" "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF "frame-ancestors 'none'" "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'sys_version = ""' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'class LimitedThreadingHTTPServer' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'threading.BoundedSemaphore' "$BATS_TEST_DIRNAME/../web/server.py"
    if grep -qF 'httpd = ThreadingHTTPServer(' "$BATS_TEST_DIRNAME/../web/server.py"; then
        fail "web server must use the bounded threading server"
    fi
    if grep -qF 'f.read_text(errors="ignore").splitlines()[-100:]' "$BATS_TEST_DIRNAME/../web/server.py"; then
        fail "web logs must use bounded tail helper"
    fi
}

@test "web static allowlist excludes private panel files" {
    grep -qF 'STATIC_FILES = {' "$BATS_TEST_DIRNAME/../web/server.py"
    if grep -qF 'super().do_GET()' "$BATS_TEST_DIRNAME/../web/server.py"; then
        fail "static file handling must stay allowlist-based"
    fi
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$(mktemp -d)" SERVER_CONF_FILE="/tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
assert set(server.STATIC_FILES) == {
    "/",
    "/index.html",
    "/style.css",
    "/app.js",
    "/favicon.svg",
    "/vendor/tailwindcss.js",
    "/vendor/apexcharts.min.js",
}
for private_path in {
    "/tokens.json",
    "/import_tokens.json",
    "/auth_token",
    "/key.pem",
    "/cert.pem",
    "/traffic_history.json",
    "/server.py",
}:
    assert private_path not in server.STATIC_FILES
PY
}

@test "WG Tunnel import links are authenticated, RBAC scoped, hashed, and raw no-store" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    printf '[Interface]\nPrivateKey = phone\n[Peer]\nEndpoint = vpn.example:51820\n' > "$tmp/phone.conf"
    printf '[Interface]\nPrivateKey = laptop\n[Peer]\nEndpoint = vpn.example:51820\n' > "$tmp/laptop.conf"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
import time
from pathlib import Path
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "Alice", "clients": ["phone"]}},
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
    headers = Headers({"Host": "panel.example:8443", "Content-Length": str(len(payload))})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    h.headers = headers
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

def response_json(handler):
    return json.loads(handler.wfile.getvalue().decode())

server.RATE.clear()
handler = make_handler("POST", "/api/clients/phone/import-link", body={})
handler.do_POST()
assert handler.responses == [401]

handler = make_handler("POST", "/api/clients/laptop/import-link", token=user_token, body={})
handler.do_POST()
assert handler.responses == [403]

handler = make_handler("POST", "/api/clients/bad%20name/import-link", token=super_token, body={})
handler.do_POST()
assert handler.responses == [400]

handler = make_handler("POST", "/api/clients/phone/import-link", token=user_token, body={"ttl": 3600})
handler.do_POST()
assert handler.responses == [200]
payload = response_json(handler)
assert "/import/phone/" in payload["url"]
raw_token = urlparse(payload["url"]).path.rsplit("/", 1)[1]
state = (Path(os.environ["AWG_DIR"]) / "web" / "import_tokens.json").read_text()
assert raw_token not in state
assert server.token_hash(raw_token) in state
assert oct((Path(os.environ["AWG_DIR"]) / "web" / "import_tokens.json").stat().st_mode & 0o777) == "0o600"

handler = make_handler("GET", f"/import/phone/{raw_token}")
handler.do_GET()
headers = dict(handler.headers_sent)
assert handler.responses == [200]
assert headers["Content-Type"] == "text/plain; charset=utf-8"
assert headers["Cache-Control"] == "no-store"
assert headers["X-Content-Type-Options"] == "nosniff"
assert handler.wfile.getvalue().decode().startswith("[Interface]")

handler = make_handler("GET", f"/import/laptop/{raw_token}")
handler.do_GET()
assert handler.responses == [404]

one_time = "one-time-import-token-abcdefghijklmnopqrstuvwxyz"
digest = server.token_hash(one_time)
server.write_import_tokens({"tokens": {digest: {
    "client": "phone",
    "expires_at": int(time.time()) + 3600,
    "one_time": True,
    "created_at": int(time.time()),
}}})
handler = make_handler("GET", f"/import/phone/{one_time}")
handler.do_GET()
assert handler.responses == [200]
handler = make_handler("GET", f"/import/phone/{one_time}")
handler.do_GET()
assert handler.responses == [404]

expired = "expired-import-token-abcdefghijklmnopqrstuvwxyz"
server.write_import_tokens({"tokens": {server.token_hash(expired): {
    "client": "phone",
    "expires_at": int(time.time()) - 1,
    "one_time": False,
    "created_at": int(time.time()) - 3600,
}}})
handler = make_handler("GET", f"/import/phone/{expired}")
handler.do_GET()
assert handler.responses == [404]

handler = make_handler("GET", f"/import/../{raw_token}")
handler.do_GET()
assert handler.responses == [404]

handler = make_handler("POST", "/api/clients/laptop/import-link", token=super_token, body={"one_time": True})
handler.do_POST()
assert handler.responses == [200]
assert response_json(handler)["one_time"] is True
PY
    rm -rf "$tmp"
}

@test "app.js contains new UI elements (charts, speed, rbac)" {
    grep -qF 'ApexCharts' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'timeAgo' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'speedBps' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'role === "super"' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Top Clients' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'traffic_total' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'data-rotate' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'data-edit-name' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'tokenTraffic' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '/rotate' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "web app exposes safe config download and copy actions" {
    local app="$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'data-action="download-config"' "$app"
    grep -qF 'data-action="copy-config"' "$app"
    grep -qF 'data-action="copy-vpnuri"' "$app"
    grep -qF 'Download .conf' "$app"
    grep -qF 'Copy config' "$app"
    grep -qF 'Show QR' "$app"
    grep -qF 'Copy vpn://' "$app"
    grep -qF 'aria-label' "$app"
    grep -qF 'navigator.clipboard?.writeText' "$app"
    grep -qF 'document.execCommand("copy")' "$app"
    if grep -qE 'console\.log.*(config|token)|localStorage.*config' "$BATS_TEST_DIRNAME/../web/"*; then
        fail "web assets must not log configs/tokens or store config text in localStorage"
    fi
}

@test "config download endpoint is authenticated, RBAC protected, and no-store" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    printf 'private config\n' > "$tmp/phone.conf"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

handler = object.__new__(server.Handler)
handler.wfile = io.BytesIO()
handler.responses = []
handler.headers_sent = []
handler.send_response = lambda code: handler.responses.append(code)
handler.send_header = lambda key, value: handler.headers_sent.append((key, value))
handler.end_headers = lambda: None
handler.send_error = lambda code: handler.responses.append(code)

assert handler.can_access_client({"role": "super", "clients": None}, "phone")
assert handler.can_access_client({"role": "user", "clients": ["phone"]}, "phone")
assert not handler.can_access_client({"role": "user", "clients": ["laptop"]}, "phone")

try:
    server.safe_name("../shadow")
    raise AssertionError("path traversal accepted")
except ValueError:
    pass

handler.send_config_download("phone")
headers = dict(handler.headers_sent)
assert handler.responses == [200]
assert headers["Content-Disposition"] == 'attachment; filename="phone.conf"'
assert headers["Cache-Control"] == "no-store"
assert headers["Content-Type"] == "application/octet-stream"
assert handler.wfile.getvalue() == b"private config\n"
PY
    rm -rf "$tmp"
}

@test "traffic history keeps persistent totals across counter resets" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import json
import os
from datetime import date
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

server.update_traffic_history([{"name": "alpha", "rx": 1000, "tx": 500}])
history = server.load_traffic_history()
assert history["totals"]["alpha"] == {"rx": 0, "tx": 0}

server.update_traffic_history([{"name": "alpha", "rx": 1200, "tx": 700}])
history = server.load_traffic_history()
assert history["totals"]["alpha"] == {"rx": 200, "tx": 200}

server.update_traffic_history([{"name": "alpha", "rx": 50, "tx": 25}])
history = server.load_traffic_history()
assert history["totals"]["alpha"] == {"rx": 250, "tx": 225}

summary = server.traffic_summary(
    {"role": "super"},
    stats={"alpha": {"name": "alpha", "rx": 50, "tx": 25}},
    names=["alpha"],
)
assert summary["total"] == {"rx": 250, "tx": 225, "total": 475}
assert summary["current"] == summary["total"]
assert summary["current_live"] == {"rx": 50, "tx": 25, "total": 75}
assert server.client_traffic_total("alpha", history) == {"rx": 250, "tx": 225, "total": 475}

server.TRAFFIC_FILE.write_text(json.dumps({"last": {"beta": {"rx": 1000, "tx": 100}}, "days": {}}))
server.update_traffic_history([{"name": "beta", "rx": 1200, "tx": 120}])
history = server.load_traffic_history()
assert history["totals"]["beta"] == {"rx": 1200, "tx": 120}

today = date.today().isoformat()
server.TRAFFIC_FILE.write_text(json.dumps({
    "last": {"gone": {"rx": 10, "tx": 20}, "_internal": {"rx": 1, "tx": 1}},
    "days": {today: {"gone": {"rx": 5, "tx": 7}, "alpha": {"rx": 2, "tx": 3}}},
    "totals": {"gone": {"rx": 300, "tx": 400}, "alpha": {"rx": 1, "tx": 2}},
}))
server.update_traffic_history([{"name": "alpha", "rx": 1, "tx": 2}])
history = server.load_traffic_history()
assert history["totals"]["_deleted_clients_total"] == {"rx": 300, "tx": 400}
assert "gone" not in history["totals"]
assert "gone" not in history["last"]
assert today in history["days"]
assert "gone" not in history["days"][today]
assert history["days"][today]["alpha"] == {"rx": 2, "tx": 3}
assert history["totals"]["alpha"] == {"rx": 1, "tx": 2}
PY
    rm -rf "$tmp"
}

@test "web token loading migrates legacy lists and rotation preserves user records" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

old_token = "old-user-token"
old_hash = server.token_hash(old_token)
server.write_tokens({
    "super_token_hash": server.token_hash("super-token"),
    "users": {old_hash: ["my_phone", "my_laptop"]},
})
data = server.load_tokens()
assert data["users"][old_hash] == {"name": "", "clients": ["my_phone", "my_laptop"]}

data["users"][old_hash]["name"] = "Alice"
server.write_tokens(data)
result = server.rotate_user_token(old_hash)
assert result is not None
assert result["name"] == "Alice"
assert result["clients"] == ["my_phone", "my_laptop"]
assert result["token_hash"] != old_hash
assert server.token_hash(result["token"]) == result["token_hash"]

data = server.load_tokens()
assert old_hash not in data["users"]
assert data["users"][result["token_hash"]] == {"name": "Alice", "clients": ["my_phone", "my_laptop"]}
assert server.rotate_user_token(old_hash) is None
PY
    rm -rf "$tmp"
}

@test "rate limiter cleanup removes stale IP buckets" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$(mktemp -d)" SERVER_CONF_FILE="/tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
server.RATE.clear()
server.RATE_LAST_CLEANUP = 0
server.RATE["stale"] = [1]
assert server.check_rate_limit("fresh", now=120)
assert "stale" not in server.RATE
assert "fresh" in server.RATE
for _ in range(server.RATE_LIMIT * 3):
    server.check_rate_limit("1.2.3.4", now=121)
assert len(server.RATE["1.2.3.4"]) <= server.RATE_LIMIT + 1
PY
}

@test "web boundary validators reject unsafe API values" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$(mktemp -d)" SERVER_CONF_FILE="/tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

for value in ["1d --bad", "$(id)", "0d", "999999999999d"]:
    try:
        server.require_expires(value)
        raise AssertionError(value)
    except ValueError:
        pass
for value in ({"foo": "bar"}, "1234", True):
    try:
        server.require_port(value)
        raise AssertionError(value)
    except ValueError:
        pass
for value in ("1.1.1.1;rm -rf /", "::::,,,", {"x": "y"}):
    try:
        server.require_dns_list(value)
        raise AssertionError(value)
    except ValueError:
        pass
for value in ("<script>alert(1)</script>", "<img src=x onerror=alert(1)>"):
    try:
        server.require_server_name(value)
        raise AssertionError(value)
    except ValueError:
        pass
assert server.require_expires("1d") == "1d"
assert server.require_expires("12h") == "12h"
assert server.require_expires("4w") == "4w"
assert server.require_dns_list("1.1.1.1,8.8.8.8") == "1.1.1.1,8.8.8.8"
assert server.require_dns_list("2001:4860:4860::8888") == "2001:4860:4860::8888"
assert server.require_server_name("My VPN Server-1") == "My VPN Server-1"
PY
}

@test "corrupt token store fails closed instead of silently rotating super token" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    printf '{broken' > "$tmp/web/tokens.json"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
try:
    server.load_tokens()
    raise AssertionError("corrupt tokens.json accepted")
except RuntimeError as exc:
    assert "reset-super" in str(exc)
PY
    rm -rf "$tmp"
}

@test "CLI reset-super backs up token store, preserves valid users, and writes 0600" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp hash out token_file
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    token_file="$tmp/web/tokens.json"
    hash=$(printf old | sha256sum | awk '{print $1}')
    printf '{"super_token_hash":"%064d","users":{"%s":{"name":"Alice","clients":["phone"]}}}\n' 0 "$hash" > "$token_file"
    out=$(AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py reset-super")
    grep -qF 'Backup:' <<< "$out"
    grep -qF 'New super token:' <<< "$out"
    [ "$(find "$tmp/web" -maxdepth 1 -name 'tokens.json.bak.*' | wc -l)" -eq 1 ]
    [ "$(stat -c '%a' "$token_file")" = "600" ]
    python3 - "$token_file" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
assert re.fullmatch(r"[0-9a-f]{64}", data["super_token_hash"])
assert next(iter(data["users"].values())) == {"name": "Alice", "clients": ["phone"]}
PY
    rm -rf "$tmp"
}

@test "English manage exposes fork-specific commands used by the web panel" {
    local manage="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    grep -qF 'set-name)' "$manage"
    grep -qF 'web)' "$manage"
    grep -qF 'toggle)' "$manage"
    grep -qF 'validate_server_name()' "$manage"
    grep -qF 'set_server_name()' "$manage"
    grep -qF 'web_token_py()' "$manage"
    grep -qF 'p2p toggle <name>' "$manage"
}

@test "RU and EN common libraries normalize IPv6 aliases identically" {
    for common in awg_common.sh awg_common_en.sh; do
        grep -qF 'routed|ndp|nat66|legacy' "$BATS_TEST_DIRNAME/../$common"
        grep -qF 'native) echo "ndp"' "$BATS_TEST_DIRNAME/../$common"
        grep -qF 'ula) echo "nat66"' "$BATS_TEST_DIRNAME/../$common"
    done
}

@test "CLI web token helper preserves dict records and migrates legacy lists" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp hash
    tmp=$(mktemp -d)
    hash=$(printf old | sha256sum | awk '{print $1}')
    mkdir -p "$tmp/web"
    printf '{"super_token_hash":"%064d","users":{"%s":{"name":"Alice","clients":["phone"]}}}\n' 0 "$hash" > "$tmp/web/tokens.json"
    AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py rotate '$hash' >/dev/null"
    python3 - "$tmp/web/tokens.json" <<'PY'
import json, sys
users = json.load(open(sys.argv[1]))['users']
record = next(iter(users.values()))
assert record == {'name': 'Alice', 'clients': ['phone']}
PY
    hash=$(printf legacy | sha256sum | awk '{print $1}')
    printf '{"super_token_hash":"%064d","users":{"%s":["phone"]}}\n' 0 "$hash" > "$tmp/web/tokens.json"
    AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py list >/dev/null"
    python3 - "$tmp/web/tokens.json" <<'PY'
import json, sys
users = json.load(open(sys.argv[1]))['users']
record = next(iter(users.values()))
assert record == {'name': '', 'clients': ['phone']}
PY
    rm -rf "$tmp"
}

@test "backup tar excludes atomic temporary files" {
    for manage in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        grep -qF -- '--exclude="*.tmp"' "$manage"
        grep -qF -- '--exclude="*.tmp.*"' "$manage"
        grep -qF -- '--exclude=".*.tmp"' "$manage"
        grep -qF -- '--exclude="*.new"' "$manage"
    done
}

@test "web TLS assets keep key private and certificate idempotent" {
    for installer in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF 'if [[ ! -f "$web_dir/cert.pem" || ! -f "$web_dir/key.pem" ]]; then' "$installer"
        grep -qF 'chmod 600 "$web_dir/key.pem"' "$installer"
        grep -qF 'chmod 644 "$web_dir/cert.pem"' "$installer"
        if grep -qF 'openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$web_dir/key.pem"' "$installer"; then
            fail "installer must not unconditionally overwrite the web TLS key"
        fi
    done
}
