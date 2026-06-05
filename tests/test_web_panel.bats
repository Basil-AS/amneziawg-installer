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
    grep -qF 'Generated Web super token failed verification' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'Сгенерированный Web super token не проходит проверку' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'os.chmod(path, 0o600)' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
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
        source <(sed -n "/^format_https_url() {$/,/^step99_finish() {$/p" "$0" | head -n -1)
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
    grep -qF 'Public URL: https://64.112.125.125:8443/' "$summary"
    grep -qF 'IMPORTANT ACCESS INFO / SECRETS' "$summary"
    grep -qF '  Public URL: https://64.112.125.125:8443/' "$summary"
    grep -qF '  Domain-only access: no' "$summary"
    grep -qF 'Permissions: 0600' "$summary"
    grep -qF 'WARNING: Web Panel is publicly exposed' "$summary"
    grep -qF 'Super token: raw-super-token' "$summary"
    grep -qF 'not available here' "$summary" && fail "fresh install summary must not contain unavailable token placeholder"
    grep -qF 'Token file:' "$summary"
    grep -qF '[AdGuard Home]' "$summary"
    grep -qF 'Profile: curated' "$summary"
    grep -qF 'Service: AdGuardHome.service' "$summary"
    grep -qF 'Binary: /root/awg/adguard/AdGuardHome' "$summary"
    grep -qF 'Upstream mode: parallel' "$summary"
    grep -qF 'Yandex DNS: disabled/not used' "$summary"
    grep -qF 'AliDNS: enabled' "$summary"
    grep -qF 'IPv6 bootstrap DNS: enabled' "$summary"
    grep -qF 'AAAA disabled: false' "$summary"
    grep -qF 'DNSSEC: true' "$summary"
    grep -qF 'Cache: 80 MiB, optimistic enabled' "$summary"
    grep -qF 'NoADS_RU: present, disabled' "$summary"
    grep -qF 'Russian regional lists: present, disabled' "$summary"
    grep -qF 'Windows telemetry blocking: enabled' "$summary"
    grep -qF 'Allowed clients:' "$summary"
    grep -qF -- '- 10.9.9.0/24' "$summary"
    grep -qF -- '- 2a13:7c82:101f:30::/64' "$summary"
    grep -qF 'Admin password: adguard-pass' "$summary"
    grep -qF 'Endpoint: 64.112.125.125' "$summary"
    grep -qF 'Route mode: route-all' "$summary"
    grep -qF 'Preset: mobile' "$summary"
    grep -qF 'IPv6 mode: routed' "$summary"
    grep -qF 'IPv6 client subnet: 2a13:7c82:101f:30::/64' "$summary"
    grep -qF 'Config directory:' "$summary"
    grep -qF -- '- my_phone:' "$summary"
    grep -qF '    config: not generated' "$summary"
    grep -qF '    vpnuri qr: not generated' "$summary"
    grep -qF -- '- my_laptop:' "$summary"
    grep -qF '[Useful commands]' "$summary"
    grep -qF 'systemctl status AdGuardHome.service --no-pager' "$summary"
    grep -qF '[WG Tunnel URL Import]' "$summary"
    grep -qF '/import/my_phone/<token>' "$summary"
    rm -rf "$tmp"
}

@test "installer final output has no placeholder web URLs and prints grouped client files" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'print_client_files_console' "$installer"
    grep -qF 'Public URL: ${web_public_url}' "$installer"
    grep -qF 'VPN endpoint: ${AWG_ENDPOINT:-not set}:${AWG_PORT}' "$installer"
    if grep -qF 'https://<IP_' "$installer" || grep -qF 'https://<SERVER_IP>' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; then
        fail "final installer output must not contain placeholder web URLs"
    fi
}

@test "installer summary handles local-only web bind without public URL" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    local tmp summary
    tmp=$(mktemp -d)
    mkdir -p "$tmp/awg"
    AWG_DIR="$tmp/awg" SERVER_CONF_FILE="$tmp/missing.conf" bash -c '
        source <(sed -n "/^format_https_url() {$/,/^step99_finish() {$/p" "$0" | head -n -1)
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
    grep -qF 'bind_host = policy.get("bind_host") or os.environ.get("AWG_WEB_BIND") or "10.9.9.1"' "$BATS_TEST_DIRNAME/../web/server.py"
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
        source <(sed -n '/^format_https_url()/,/^}/p; /^compute_web_public_url()/,/^}/p; /^compute_web_vpn_url()/,/^}/p; /^compute_web_local_url()/,/^}/p; /^compute_trusted_https_status()/,/^}/p; /^compute_cert_summary()/,/^}/p; /^route_mode_label()/,/^}/p; /^server_ipv6_addr_for_summary()/,/^}/p; /^adguard_allowed_clients_for_summary()/,/^}/p; /^client_value_from_server_conf()/,/^}/p; /^client_ipv4_for_summary()/,/^}/p; /^client_ipv6_for_summary()/,/^}/p; /^client_file_status()/,/^}/p; /^write_client_files_summary()/,/^}/p; /^write_install_summary()/,/^}/p' '$installer')
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
    for asset in server.py index.html style.css app.js awg_i1.js favicon.svg; do
        grep -qF "for asset in server.py index.html style.css app.js awg_i1.js favicon.svg" "$installer"
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
    grep -qF 'clean_token_name(body.get("name", ""))' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Token name / alias (optional)' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'super_token_hash' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'assign_client_to_user_token(auth["hash"], name)' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'assigned_to_current_token' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'client assignment failed' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens/([^/]+)/clients' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Remove from my access' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Delete my config' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Delete client' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '?action=delete_owned' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '?action=remove_access' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'data-edit-clients' "$BATS_TEST_DIRNAME/../web/app.js"
}

@test "web clients disambiguate duplicate display names and expose token assignments" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    cat > "$tmp/awg0.conf" <<'CONF'
[Peer]
#_Name = phone
PublicKey = OLD
AllowedIPs = 10.9.9.2/32
CONF
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
user_hash = server.token_hash(user_token)
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {user_hash: {"name": "phone-token", "clients": []}},
})
server.secrets.token_hex = lambda _n: "a7f3"

calls = []
def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append(args)
    if args == ("add", "phone-a7f3"):
        with open(os.environ["SERVER_CONF_FILE"], "a", encoding="utf-8") as fh:
            fh.write("\n[Peer]\n#_Name = phone-a7f3\nPublicKey = NEW\nAllowedIPs = 10.9.9.3/32\n")
    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""
    return Result()
server.run_manage = fake_run_manage

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

server.RATE.clear()
handler = make_handler("POST", "/api/clients", token=user_token, body={"name": "phone"})
handler.do_POST()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["display_name"] == "phone"
assert payload["config_name"] == "phone-a7f3"
assert payload["is_duplicate_display_name"] is True
assert payload["assigned_to_current_token"] is True
assert calls[-1] == ("add", "phone-a7f3")
assert server.load_tokens()["users"][user_hash]["clients"] == ["phone-a7f3"]
metadata = server.load_client_metadata()["clients"]["phone-a7f3"]
assert metadata["display_name"] == "phone"
assert metadata["created_by_fp"] == user_hash[:8]
assert metadata["created_by_role"] == "user"

handler = make_handler("GET", "/api/clients", token=user_token)
handler.do_GET()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
assert [row["config_name"] for row in payload["clients"]] == ["phone-a7f3"]
assert payload["clients"][0]["assigned_tokens"] == []
assert payload["clients"][0]["is_unassigned"] is False

handler = make_handler("GET", "/api/clients", token=super_token)
handler.do_GET()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
rows = {row["config_name"]: row for row in payload["clients"]}
assert rows["phone"]["display_name"] == "phone"
assert rows["phone"]["is_unassigned"] is True
assert rows["phone-a7f3"]["display_name"] == "phone"
assert rows["phone-a7f3"]["is_duplicate_display_name"] is True
assert rows["phone-a7f3"]["assigned_tokens"] == [{"alias": "phone-token", "fingerprint": user_hash[:6], "role": "user"}]
PY
    rm -rf "$tmp"
}

@test "web app filters admin clients by token assignment owner" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
from pathlib import Path

source = Path(__import__("os").environ["REPO_ROOT"], "web", "app.js").read_text(encoding="utf-8")
for needle in [
    'let ownerFilter = {mode: "all", tokens: []};',
    'function canManageClientAssignments()',
    'function assignedUserTokens(client)',
    'function clientMatchesOwnerFilter(client, filter = ownerFilter)',
    'function ownerFilterOptions()',
    'function renderOwnerFilter()',
    'data-owner-filter',
    'Owner filter',
    'No clients match this owner filter',
    'client-filter-grid',
    'client-search-wrap',
    'client-search-icon',
    'client-search-input',
]:
    assert needle in source
style = Path(__import__("os").environ["REPO_ROOT"], "web", "style.css").read_text(encoding="utf-8")
for needle in [
    '.client-filter-grid{display:grid',
    '.client-search-wrap{position:relative',
    '.client-search-icon{position:absolute',
    '.client-search-input{width:100%;height:2.75rem',
    '.client-search-input:focus{border-color:var(--accent)}',
]:
    assert needle in style
assert '["super", "admin"].includes(statusState.role)' in source
assert 'if (!filter || filter.mode === "all") return true;' in source
assert 'if (filter.mode === "unassigned") return assigned.length === 0;' in source
assert 'if (filter.mode === "assigned") return assigned.length > 0;' in source
assert 'selected.has(ownerTokenKey(item))' in source
assert 'latestClients.filter(client => clientMatchesOwnerFilter(client))' in source
assert 'renderOwnerFilter();' in source
assert 'const ACTIVE_CLIENT_POLL_MS = 5000;' in source
assert 'const HIDDEN_CLIENT_POLL_MS = 30000;' in source
assert 'pollInFlight' in source
assert 'document.addEventListener("visibilitychange"' in source
advanced = source.index('Disruptive system operations.')
filters = source.index('id="clientFiltersPanel"')
search = source.index('id="searchInput"', filters)
owner = source.index('id="ownerFilter"', filters)
clients = source.index('id="clientsList"')
assert advanced < filters < search < owner < clients
PY
}

@test "web client create assignment and stats cache are hardened" {
    grep -qF 'def assign_client_to_user_token(user_hash, client_name):' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'rollback_created_client(name)' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Created web client ' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'requested_display={display_name} config_name={name}' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'STATS_CACHE_COND = threading.Condition(STATS_CACHE_LOCK)' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'STATS_CACHE_TTL = 3.0' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'STATS_CACHE_WAIT_TIMEOUT = 2.0' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'run_manage("--json", "stats", timeout=8)' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Stats cache stale served while refresh in-flight' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'if stats is None:' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "web user delete separates access removal from owned client deletion" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    cat > "$tmp/awg0.conf" <<'CONF'
[Peer]
#_Name = owned
PublicKey = OWNED
AllowedIPs = 10.9.9.2/32
[Peer]
#_Name = shared
PublicKey = SHARED
AllowedIPs = 10.9.9.3/32
[Peer]
#_Name = legacy
PublicKey = LEGACY
AllowedIPs = 10.9.9.4/32
CONF
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
other_token = "other-token"
user_hash = server.token_hash(user_token)
other_hash = server.token_hash(other_token)
auth = {"role": "user", "hash": user_hash, "clients": ["owned", "shared", "legacy"]}
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {
        user_hash: {"name": "owner", "clients": ["owned", "shared", "legacy"]},
        other_hash: {"name": "other", "clients": ["shared"]},
    },
})
server.set_client_metadata("owned", "owned", auth)
server.set_client_metadata("shared", "shared", auth)
server.set_client_display_name("legacy", "legacy")

assert server.can_user_delete_client("owned", auth) == (True, "ok")
assert server.can_user_delete_client("shared", auth) == (False, "shared")
assert server.can_user_delete_client("legacy", auth) == (False, "missing_metadata")

removed, remaining = server.remove_client_from_token("legacy", auth)
assert removed is True
assert remaining == 0
assert "legacy" not in server.load_tokens()["users"][user_hash]["clients"]
assert "last_unassigned_by_fp" in server.load_client_metadata()["clients"]["legacy"]

calls = []
def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append(args)
    class Result:
        returncode = 0
        stdout = "removed"
        stderr = ""
    return Result()
server.run_manage = fake_run_manage

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

handler = make_handler("/api/clients/shared?action=delete_owned", user_token)
handler.do_DELETE()
assert handler.responses == [403]
assert calls == []

handler = make_handler("/api/clients/owned?action=delete_owned", user_token)
handler.do_DELETE()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["deleted"] is True
assert calls == [("remove", "owned")]
assert "owned" not in server.load_tokens()["users"][user_hash]["clients"]
assert "owned" not in server.load_client_metadata()["clients"]
PY
    rm -rf "$tmp"
}

@test "web client audit reports active unassigned and orphan runtime refs" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web" "$tmp/keys"
    cat > "$tmp/awg0.conf" <<'CONF'
[Peer]
#_Name = active
#_P2PPorts = 20002,20258,20514
PublicKey = ACTIVE
AllowedIPs = 10.9.9.2/32
CONF
    printf 'Address = 10.9.9.3/32\n' > "$tmp/orphan_file.conf"
    printf 'png' > "$tmp/orphan_file.png"
    printf 'priv' > "$tmp/keys/orphan_file.private"
    cat > "$tmp/p2p_rules.sh" <<'P2P'
# Client: orphan_hook (10.9.9.4, P2P: 20004,20260,20516)
iptables -t nat -A PREROUTING -p tcp --dport 20004 -j DNAT --to-destination 10.9.9.4:20004
P2P
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
super_hash = server.token_hash(super_token)
user_hash = server.token_hash(user_token)
server.write_tokens({
    "super_token_hash": super_hash,
    "users": {user_hash: {"name": "user-token", "clients": ["active", "orphan_token"]}},
})
server.set_client_display_name("active", "active")
server.set_client_display_name("orphan_meta", "orphan_meta")
server.write_traffic_history({"last": {"history_only": {"rx": 1, "tx": 2}}, "days": {}, "totals": {}})

payload = server.audit_client_state()
rows = {row["config_name"]: row for row in payload["clients"]}
assert rows["active"]["server_peer_present"] is True
assert "active" in rows["active"]["status"]
assert rows["active"]["token_assignments"][0]["alias"] == "user-token"
assert rows["orphan_meta"]["status"] == ["orphan_metadata"]
assert "orphan_files" in rows["orphan_file"]["status"]
assert "key_private" in rows["orphan_file"]["files"]
assert "orphan_token_binding" in rows["orphan_token"]["status"]
assert "orphan_firewall_rule" in rows["orphan_hook"]["status"]
assert rows["history_only"]["status"] == ["history_only"]
assert payload["summary"]["orphan_token_bindings"] == 1

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(token):
    h = object.__new__(server.Handler)
    h.path = "/api/clients/audit"
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
api_payload = json.loads(handler.wfile.getvalue().decode())
assert api_payload["summary"]["total"] >= 5
PY
    rm -rf "$tmp"
}

@test "web stats cache reuses fresh value and serves clients on stats failure" {
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

calls = []
class Result:
    returncode = 0
    stdout = '[{"name":"phone","rx":7,"tx":9,"last_handshake":123}]'
    stderr = ""

def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append(args)
    return Result()

server.run_manage = fake_run_manage
server.STATS_CACHE_VALUE = None
server.STATS_CACHE_TS = 0.0
server.STATS_CACHE_INFLIGHT = False

first = server.client_stats_map()
second = server.client_stats_map()
assert first["phone"]["rx"] == 7
assert second["phone"]["tx"] == 9
assert calls == [("--json", "stats")]

class Failed:
    returncode = 1
    stdout = ""
    stderr = "failed"
server.run_manage = lambda *args, **kwargs: Failed()
server.STATS_CACHE_VALUE = None
server.STATS_CACHE_TS = 0.0
server.STATS_CACHE_INFLIGHT = False
assert server.client_stats_map(force=True) == {}
PY
    rm -rf "$tmp"
}

@test "web access policy validates hosts sources and lockout guard" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

policy = server.clean_access_policy({
    "bind_mode": "custom",
    "bind_host": "0.0.0.0",
    "allowed_hosts": ["194-180-189-244.sslip.io", "194.180.189.244"],
    "allowed_source_cidrs": ["10.66.66.0/24"],
    "host_check_enabled": True,
    "source_check_enabled": True,
})
assert server.host_allowed("194-180-189-244.sslip.io", "10.66.66.2", policy)
assert server.host_allowed("194-180-189-244.sslip.io:443", "10.66.66.2", policy)
assert server.host_allowed("194.180.189.244:443", "10.66.66.2", policy)
assert not server.host_allowed("example.invalid", "10.66.66.2", policy)
assert server.source_allowed("10.66.66.42", policy)
assert not server.source_allowed("10.66.67.42", policy)
assert server.request_allowed_by_policy("194-180-189-244.sslip.io:443", "10.66.66.42", policy)
assert not server.request_allowed_by_policy("194-180-189-244.sslip.io:443", "10.66.67.42", policy)
ctx = server.client_ip_context("127.0.0.1", {"X-Forwarded-For": "46.34.133.234, 10.0.0.2"}, policy)
assert ctx["client_ip"] == "46.34.133.234"
assert ctx["socket_remote_ip"] == "127.0.0.1"
assert ctx["trusted_proxy_used"] is True
spoofed = server.client_ip_context("198.51.100.9", {"X-Forwarded-For": "46.34.133.234"}, policy)
assert spoofed["client_ip"] == "198.51.100.9"
assert spoofed["trusted_proxy_used"] is False
proxy_policy = server.clean_access_policy({
    "bind_mode": "custom",
    "bind_host": "127.0.0.1",
    "allowed_hosts": ["194-180-189-244.sslip.io", "127.0.0.1"],
    "allowed_source_cidrs": ["46.34.133.0/24"],
    "trusted_proxy_cidrs": ["127.0.0.0/8", "::1/128"],
    "host_check_enabled": True,
    "source_check_enabled": True,
})
ctx = server.client_ip_context("127.0.0.1", {"X-Forwarded-For": "46.34.133.234"}, proxy_policy)
assert server.request_allowed_by_policy("194-180-189-244.sslip.io", "127.0.0.1", proxy_policy, ctx["client_ip"], ctx["trusted_proxy_used"])
blocked_ctx = server.client_ip_context("127.0.0.1", {"X-Forwarded-For": "82.197.73.253"}, proxy_policy)
assert not server.request_allowed_by_policy("194-180-189-244.sslip.io", "127.0.0.1", proxy_policy, blocked_ctx["client_ip"], blocked_ctx["trusted_proxy_used"])
assert server.clean_allowed_host("[::1]:443") == "::1"
try:
    server.clean_access_policy({
        "bind_mode": "custom",
        "bind_host": "0.0.0.0",
        "allowed_hosts": [],
        "allowed_source_cidrs": ["0.0.0.0/0"],
        "host_check_enabled": True,
        "source_check_enabled": False,
    })
except ValueError:
    pass
else:
    raise AssertionError("empty allowed_hosts with host check must fail")
assert not server.bind_allows_current_remote("127.0.0.1", "203.0.113.9")
vpn_policy = server.clean_access_policy({
    "bind_mode": "vpn_only",
    "bind_host": "0.0.0.0",
    "allowed_hosts": ["194-180-189-244.sslip.io", "localhost", "127.0.0.1"],
    "allowed_source_cidrs": ["0.0.0.0/0", "::/0"],
    "host_check_enabled": True,
    "source_check_enabled": False,
})
assert vpn_policy["bind_mode"] == "vpn_only"
assert vpn_policy["source_check_enabled"] is True
assert vpn_policy["allowed_source_cidrs"] == ["10.0.0.0/8", "127.0.0.0/8"]
local_policy = server.clean_access_policy({
    "bind_mode": "localhost_only",
    "bind_host": "0.0.0.0",
    "allowed_hosts": ["localhost"],
    "allowed_source_cidrs": ["0.0.0.0/0"],
    "host_check_enabled": True,
    "source_check_enabled": False,
})
assert local_policy["bind_host"] == "127.0.0.1"
assert local_policy["source_check_enabled"] is True
assert local_policy["allowed_source_cidrs"] == ["127.0.0.0/8", "::1/128"]
PY
}

@test "web access policy API and UI are super-admin only and lockout-safe" {
    grep -qF 'ACCESS_POLICY_FILE = WEB_DIR / "access_policy.json"' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/web-access-policy' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/web-access-policy/test' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/web-access-policy/restart' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'if not self.require_super(auth):' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'policy would block the current request' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'bind mode would block the current connection after restart' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '194-180-189-244.sslip.io' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'Web Access' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Allow current host' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Enable Host header check' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Enable source IP check' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Trusted proxy CIDRs' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Client IP:' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Proxy:' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'When source IP check is enabled, it is evaluated against Client IP.' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'applyWebAccessModeProfile' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'Unsaved changes' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF 'profile selected; test before saving' "$BATS_TEST_DIRNAME/../web/app.js"
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
    grep -qF 'def get_request(self):' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'request.settimeout(self.request_timeout)' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'def handle_one_request(self):' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'is_benign_disconnect_error' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'def handle_error(self, request, client_address):' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'finally:' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'self._sem.release()' "$BATS_TEST_DIRNAME/../web/server.py"
    if grep -qF 'httpd = ThreadingHTTPServer(' "$BATS_TEST_DIRNAME/../web/server.py"; then
        fail "web server must use the bounded threading server"
    fi
    if grep -qF 'f.read_text(errors="ignore").splitlines()[-100:]' "$BATS_TEST_DIRNAME/../web/server.py"; then
        fail "web logs must use bounded tail helper"
    fi
}

@test "advanced docs include nginx reverse proxy edge guidance" {
    for doc in "$BATS_TEST_DIRNAME/../ADVANCED.md" "$BATS_TEST_DIRNAME/../ADVANCED.en.md"; do
        grep -qF 'nginx listens' "$doc" || grep -qF 'nginx слушает' "$doc"
        grep -qF '127.0.0.1:8443' "$doc"
        grep -qF 'proxy_pass https://127.0.0.1:8443' "$doc"
        grep -qF 'proxy_ssl_verify off' "$doc"
        grep -qF 'proxy_set_header Host $host' "$doc"
        grep -qF 'limit_conn_zone $binary_remote_addr zone=awg_conn:10m' "$doc"
        grep -qF 'limit_req zone=awg_req burst=30 nodelay' "$doc"
    done
}

@test "web server suppresses benign disconnect tracebacks only" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$(mktemp -d)" SERVER_CONF_FILE="/tmp/missing-awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

assert server.is_benign_disconnect_error(ConnectionResetError())
assert server.is_benign_disconnect_error(BrokenPipeError())
assert server.is_benign_disconnect_error(TimeoutError())
assert not server.is_benign_disconnect_error(RuntimeError("backend bug"))

class BrokenWriter:
    def write(self, _data):
        raise BrokenPipeError()

class HeaderResetHandler:
    def __call__(self):
        raise ConnectionResetError()

handler = object.__new__(server.Handler)
handler.path = "/api/status"
handler.client_address = ("192.0.2.10", 12345)
handler.wfile = BrokenWriter()
handler.responses = []
handler.headers_sent = []
handler.close_connection = False
handler.send_response = lambda code: handler.responses.append(code)
handler.send_header = lambda key, value: handler.headers_sent.append((key, value))
handler.end_headers = lambda: None

logs = []
server.audit_log = logs.append
handler.send_json({"ok": True})
assert handler.responses == [200]
assert handler.close_connection is True
assert logs == ["Web client disconnected remote=192.0.2.10 path=/api/status error=BrokenPipeError"]

handler.wfile = type("Writer", (), {"write": lambda self, data: None})()
handler.responses = []
handler.headers_sent = []
handler.close_connection = False
handler.end_headers = HeaderResetHandler()
logs.clear()
handler.send_json({"ok": True})
assert handler.responses == [200]
assert handler.close_connection is True
assert logs == ["Web client disconnected remote=192.0.2.10 path=/api/status error=ConnectionResetError"]

source = Path(os.environ["REPO_ROOT"], "web", "server.py").read_text(encoding="utf-8")
assert "def handle_error(self, request, client_address):" in source
assert "super().handle_error(request, client_address)" in source
assert "def do_HEAD(self):" in source
PY
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
    "/i1.js",
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

handler = make_handler("POST", "/api/clients/phone/import-link", token=user_token, body={})
handler.do_POST()
assert handler.responses == [200]
payload = response_json(handler)
assert "/import/phone/" in payload["url"]
assert payload["ttl"] == 300
assert payload["one_time"] is True
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

handler = make_handler("GET", f"/import/phone/{raw_token}")
handler.do_GET()
assert handler.responses == [404]

handler = make_handler("GET", f"/import/laptop/{raw_token}")
handler.do_GET()
assert handler.responses == [404]

handler = make_handler("POST", "/api/clients/phone/import-link", token=user_token, body={"ttl": 59})
handler.do_POST()
assert handler.responses == [400]

handler = make_handler("POST", "/api/clients/phone/import-link", token=user_token, body={"ttl": 3601})
handler.do_POST()
assert handler.responses == [400]

handler = make_handler("POST", "/api/clients/phone/import-link", token=user_token, body={"ttl": True})
handler.do_POST()
assert handler.responses == [400]

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

handler = make_handler("POST", "/api/clients/laptop/import-link", token=super_token, body={"one_time": False, "ttl": 300})
handler.do_POST()
assert handler.responses == [200]
assert response_json(handler)["one_time"] is False
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
    grep -qF 'copy-access-link' "$app"
    grep -qF 'regenerate-config' "$app"
    grep -qF 'copy-uri' "$app"
    grep -qF 'Download .conf' "$app"
    grep -qF 'Copy profile' "$app"
    grep -qF 'Show QR' "$app"
    grep -qF 'Copy URI' "$app"
    grep -qF 'aria-label' "$app"
    grep -qF 'navigator.clipboard?.writeText' "$app"
    grep -qF 'document.execCommand("copy")' "$app"
    if grep -qE 'console\.log.*(config|token)|localStorage.*config' "$BATS_TEST_DIRNAME/../web/"*; then
        fail "web assets must not log configs/tokens or store config text in localStorage"
    fi
    grep -qF 'sessionStorage.getItem("panelToken")' "$app"
    grep -qF 'sessionStorage.setItem("panelToken", token)' "$app"
    grep -qF 'sessionStorage.removeItem("panelToken")' "$app"
    grep -qF 'localStorage.removeItem("panelToken")' "$app"
    if grep -qF 'localStorage.getItem("panelToken")' "$app"; then
        fail "panel bearer token must not be read from persistent localStorage"
    fi
    if grep -qF 'localStorage.setItem("panelToken", token)' "$app"; then
        fail "panel bearer token must not be stored in persistent localStorage"
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

@test "web token names validate aliases and escape through app renderer" {
    grep -qF 'len(value) > 64' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'ord(ch) < 32' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'const label = row.name || "Unnamed token";' "$BATS_TEST_DIRNAME/../web/app.js"
    grep -qF '${esc(label)}' "$BATS_TEST_DIRNAME/../web/app.js"
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

@test "web auth logging and domain-only host validation are present" {
    local server="$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'allowed_host_header' "$server"
    grep -qF 'HTTPStatus.MISDIRECTED_REQUEST' "$server"
    grep -qF 'reason=access policy' "$server"
    grep -qF 'missing / malformed / invalid / expired / insufficient scope' "$server"
    grep -qF 'reason={reason}' "$server"
    grep -qF 'fingerprint=' "$server"
    grep -qF 'reason=insufficient scope' "$server"
    if grep -qF 'Authorization="Bearer' "$server"; then
        fail "raw Authorization header must not be logged"
    fi
}

@test "web host allowlist accepts configured domain and managed public IP" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
os.environ["AWG_WEB_DOMAIN"] = "64-112-125-125.sslip.io"
os.environ["AWG_WEB_BIND"] = "0.0.0.0"
os.environ["AWG_ENDPOINT"] = "64.112.125.125"
policy = server.clean_access_policy({
    "bind_mode": "public",
    "bind_host": "0.0.0.0",
    "allowed_hosts": ["64-112-125-125.sslip.io", "64.112.125.125", "10.9.9.1", "localhost"],
    "allowed_source_cidrs": ["0.0.0.0/0"],
    "host_check_enabled": True,
    "source_check_enabled": False,
})
assert server.host_allowed("64-112-125-125.sslip.io", "198.51.100.1", policy)
assert server.host_allowed("64-112-125-125.sslip.io:8443", "198.51.100.1", policy)
assert server.host_allowed("64.112.125.125:443", "198.51.100.1", policy)
assert not server.host_allowed("[2001:db8::1]:8443", "198.51.100.1", policy)
assert server.host_allowed("10.9.9.1:8443", "10.9.9.2", policy)
assert server.host_allowed("panel.example:8443", "127.0.0.1", policy)
PY
}

@test "client regenerate API validates I1 passes it via env and invalidates import tokens" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    printf '[Interface]\nPrivateKey = phone\n[Peer]\nEndpoint = vpn.example:51820\n' > "$tmp/phone.conf"
    cat > "$tmp/awg0.conf" <<'CONF'
[Interface]
PrivateKey = SERVER

[Peer]
#_Name = phone
PublicKey = OLD
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = laptop
PublicKey = LAPTOP
AllowedIPs = 10.9.9.3/32
CONF
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "Alice", "clients": ["phone"]}},
})

old_token = "old-import-token-abcdefghijklmnopqrstuvwxyz"
server.write_import_tokens({"tokens": {server.token_hash(old_token): {
    "client": "phone",
    "expires_at": int(time.time()) + 3600,
    "one_time": False,
    "created_at": int(time.time()),
}}})

calls = []
def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append({"args": args, "timeout": timeout, "extra_env": extra_env or {}})
    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""
    return Result()
server.run_manage = fake_run_manage

class Headers(dict):
    def get(self, key, default=None):
        return super().get(key, default)

def make_handler(path, token=None, body=None):
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

server.RATE.clear()
valid_i1 = "<b 0xabcdef><r 0 1>"
handler = make_handler("/api/clients/phone/regenerate", token=user_token, body={"i1": valid_i1, "i1_sni": "mail.ru"})
handler.do_POST()
assert handler.responses == [200]
payload = json.loads(handler.wfile.getvalue().decode())
assert payload["ok"] is True
assert payload["client"] == "phone"
assert payload["download_url"] == "/api/clients/phone/config/download"
assert calls[-1]["args"] == ("client", "regenerate", "phone")
assert calls[-1]["extra_env"] == {"AWG_I1_OVERRIDE": valid_i1}
assert valid_i1 not in calls[-1]["args"]
assert server.load_import_tokens()["tokens"] == {}

handler = make_handler("/api/clients/laptop/regenerate", token=user_token, body={})
handler.do_POST()
assert handler.responses == [403]

for bad in ["<b 0xabc>;id", "<b 0xabc>$x", "`id`", "'bad'", '"bad"', "<b 0xabc>/x", "<b 0xabc>|x", "<b 0x" + ("a" * 2100) + ">"]:
    handler = make_handler("/api/clients/phone/regenerate", token=super_token, body={"i1": bad})
    handler.do_POST()
    assert handler.responses == [400], bad
PY
    rm -rf "$tmp"
}

@test "web static files and UI expose regenerate action and local I1 generator" {
    local root="$BATS_TEST_DIRNAME/.."
    grep -qF '<script src="/i1.js"></script>' "$root/web/index.html"
    grep -qF '"/i1.js": ("awg_i1.js", "application/javascript; charset=utf-8")' "$root/web/server.py"
    grep -qF 'regenerate-config' "$root/web/app.js"
    grep -qF 'CLIENT_NAME_RE = /^[A-Za-z0-9_-]+$/' "$root/web/app.js"
    grep -qF 'Use only Latin letters, digits, underscore and hyphen' "$root/web/app.js"
    grep -qF 'create.disabled = !ok' "$root/web/app.js"
    grep -qF 'data-menu-toggle' "$root/web/app.js"
    grep -qF 'aria-expanded' "$root/web/app.js"
    grep -qF 'closeClientMenus' "$root/web/app.js"
    grep -qF 'const preservedMenu = openClientMenu' "$root/web/app.js"
    grep -qF 'menu.classList.remove("hidden")' "$root/web/app.js"
    grep -qF 'client-card-menu-open' "$root/web/app.js"
    grep -qF 'clientActionMenuPortal' "$root/web/app.js"
    grep -qF 'getBoundingClientRect' "$root/web/app.js"
    grep -qF 'window.innerHeight' "$root/web/app.js"
    grep -qF 'window.innerWidth' "$root/web/app.js"
    grep -qF 'spaceBelow < height + gap' "$root/web/app.js"
    grep -qF 'event.key === "Escape"' "$root/web/app.js"
    grep -qF 'port-summary' "$root/web/app.js"
    grep -qF 'port-chip' "$root/web/app.js"
    grep -qF 'ports.map(port => `<span class="port-chip">' "$root/web/app.js"
    if grep -qF 'ports.slice(0, 2)' "$root/web/app.js"; then
        fail "port list must not be truncated"
    fi
    if grep -qF '+${ports.length' "$root/web/app.js"; then
        fail "port list must not render +N overflow chips"
    fi
    grep -qF 'client-card-chart-bg' "$root/web/app.js"
    grep -qF 'clientCharts' "$root/web/app.js"
    grep -qF 'background: "transparent"' "$root/web/app.js"
    grep -qF '.client-card-chart-bg' "$root/web/style.css"
    grep -qF 'pointer-events:none' "$root/web/style.css"
    grep -qF 'z-index:10' "$root/web/style.css"
    grep -qF 'z-index:1000' "$root/web/style.css"
    grep -qF '@media(max-width:640px)' "$root/web/style.css"
    grep -qF 'grid-template-columns:repeat(4,minmax(0,1fr))' "$root/web/style.css"
    grep -qF 'z-index:200' "$root/web/style.css"
    grep -qF -- '--accent:#b91c1c' "$root/web/style.css"
    grep -qF '/api/profile/rotate' "$root/web/app.js"
    grep -qF 'rotateProfileModal' "$root/web/app.js"
    grep -qF 'name="rotatePreset" value="mobile" checked' "$root/web/app.js"
    grep -qF 'name="rotatePreset" value="default"' "$root/web/app.js"
    grep -qF 'Refresh system parameters and regenerate all client profiles' "$root/web/app.js"
    grep -qF 'Rotate profile' "$root/web/app.js"
    grep -qF 'Regenerate profile for' "$root/web/app.js"
    grep -qF 'Profile regenerated. Download or copy the new profile.' "$root/web/app.js"
    grep -qF "default-src 'self'; script-src 'self'" "$root/web/server.py"
    if grep -E "https?://|unpkg" "$root/web/index.html" >/dev/null; then
        fail "index.html must not load external scripts"
    fi
    if grep -F 'localStorage.setItem("config' "$root/web/app.js" >/dev/null; then
        fail "app.js must not store configs in localStorage"
    fi
    if grep -F 'localStorage.setItem("i1' "$root/web/app.js" >/dev/null; then
        fail "app.js must not store I1 in localStorage"
    fi
}

@test "web JavaScript assets pass syntax check when node is available" {
    command -v node &>/dev/null || skip "node not available"
    node --check "$BATS_TEST_DIRNAME/../web/app.js"
    node --check "$BATS_TEST_DIRNAME/../web/awg_i1.js"
}

@test "server rotate-profile API is super-only and passes I1 overrides via temp file" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    cat > "$tmp/awg0.conf" <<'CONF'
[Interface]
PrivateKey = SERVER
Jc = 3
Jmin = 30
Jmax = 90
S1 = 1
S2 = 2
S3 = 3
S4 = 4
H1 = 1-2
H2 = 3-4
H3 = 5-6
H4 = 7-8

[Peer]
#_Name = phone
PublicKey = OLD
AllowedIPs = 10.9.9.2/32
CONF
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

super_token = "super-token"
user_token = "user-token"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "Alice", "clients": ["phone"]}},
})
server.write_import_tokens({"tokens": {server.token_hash("old-import-token-abcdefghijklmnopqrstuvwxyz"): {
    "client": "phone", "expires_at": 4102444800, "one_time": False, "created_at": 1,
}}})

calls = []
def fake_run_manage(*args, timeout=60, extra_env=None):
    calls.append({"args": args, "timeout": timeout, "extra_env": extra_env or {}})
    override_path = (extra_env or {}).get("AWG_I1_OVERRIDES_FILE")
    assert override_path and Path(override_path).stat().st_mode & 0o777 == 0o600
    assert json.loads(Path(override_path).read_text())["phone"] == "<b 0xabcdef><r 0 1>"
    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""
    return Result()
server.run_manage = fake_run_manage

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
    h.headers = Headers({"Host": "panel.example:8443", "Content-Length": str(len(payload)), "Authorization": f"Bearer {token}"})
    h.send_response = lambda code: h.responses.append(code)
    h.send_error = lambda code, *args, **kwargs: h.responses.append(code)
    h.send_header = lambda key, value: h.headers_sent.append((key, value))
    h.end_headers = lambda: None
    return h

server.RATE.clear()
handler = make_handler(user_token, {"preset": "mobile", "confirm": "ROTATE", "client_i1": {"phone": "<b 0xabcdef><r 0 1>"}})
handler.do_POST()
assert handler.responses == [403]

handler = make_handler(super_token, {"preset": "mobile", "confirm": "nope", "client_i1": {}})
handler.do_POST()
assert handler.responses == [400]

handler = make_handler(super_token, {"preset": "mobile", "confirm": "ROTATE", "client_i1": {"phone": "<b 0xabcdef><r 0 1>"}})
handler.do_POST()
assert handler.responses == [200]
assert calls[-1]["args"] == ("server", "rotate-profile", "--preset", "mobile")
assert server.load_import_tokens()["tokens"] == {}
assert not list((Path(os.environ["AWG_DIR"]) / "web").glob(".tmp.i1-overrides.*.json"))
PY
    rm -rf "$tmp"
}

@test "browser I1 generator uses realistic ClientHello and public generateI1 path" {
    local js="$BATS_TEST_DIRNAME/../web/awg_i1.js"
    [ -f "$js" ]
    grep -qF 'function buildRealisticClientHello' "$js"
    grep -qF 'async function generateI1' "$js"
    grep -qF '0x13, 0x01' "$js"
    grep -qF '0x13, 0x02' "$js"
    grep -qF '0x13, 0x03' "$js"
    grep -qF '0x002b' "$js"
    grep -qF '0x0010' "$js"
    grep -qF '0x000a' "$js"
    grep -qF '0x0033' "$js"
    grep -qF '0x68, 0x33' "$js"
    grep -qF 'const clientHello = buildRealisticClientHello(sni);' "$js"
    if awk '/async function generateI1/,/^}/' "$js" | grep -qF 'quicTlsClientHelloSniOnly'; then
        fail "generateI1 must not use legacy SNI-only ClientHello"
    fi
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
    grep -qF 'Raw super token:' <<< "$out"
    grep -qF 'Only SHA-256 hash is stored there.' <<< "$out"
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

@test "CLI reset-super updates summary and token check/status do not leak raw tokens" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp token_file old_hash out raw
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    token_file="$tmp/web/tokens.json"
    old_hash=$(printf old-token | sha256sum | awk '{print $1}')
    printf '{"super_token_hash":"%s","users":{}}\n' "$old_hash" > "$token_file"
    printf 'WEB PANEL\n  Super token: old-token\n  Token file: %s\n' "$token_file" > "$tmp/INSTALL_SUMMARY.txt"
    chmod 600 "$tmp/INSTALL_SUMMARY.txt"

    out=$(AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py reset-super")
    raw=$(awk '/Raw super token:/{getline; print}' <<<"$out")
    [ -n "$raw" ]
    grep -qF -- "$raw" "$tmp/INSTALL_SUMMARY.txt"
    [ "$(stat -c '%a' "$tmp/INSTALL_SUMMARY.txt")" = "600" ]
    [ "$(stat -c '%a' "$token_file")" = "600" ]

    run env AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py check '$raw'"
    [ "$status" -eq 0 ]
    run env AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py check old-token"
    [ "$status" -eq 1 ]
    run env AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py status"
    [ "$status" -eq 0 ]
    grep -qF 'super_hash_present: yes' <<<"$output"
    if grep -qF "$raw" <<<"$output"; then
        fail "token status leaked raw token"
    fi
    if grep -qF "$old_hash" <<<"$output"; then
        fail "token status leaked full hash"
    fi
    rm -rf "$tmp"
}

@test "CLI web token create supports optional alias and client binding" {
    local tmp token_file out hash
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    token_file="$tmp/web/tokens.json"
    printf '{"super_token_hash":"%064d","users":{}}\n' 0 > "$token_file"
    out=$(AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py add 'phone token' 'my_phone'")
    grep -qF 'Token created.' <<< "$out"
    python3 - "$token_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
records = list(data["users"].values())
assert records == [{"clients": ["my_phone"], "name": "phone token"}]
PY
    out=$(AWG_DIR="$tmp" bash -c "source <(sed -n '/^web_token_py() {$/,/^}$/p' '$BATS_TEST_DIRNAME/../manage_amneziawg.sh'); web_token_py add '' ''")
    python3 - "$token_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert any(record["name"] == "" for record in data["users"].values())
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
