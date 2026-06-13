#!/usr/bin/env bats
# Tests for IPv6 NDP proxy (ndppd) support:
#   - shell-side state classification and config generation (awg_common.sh)
#   - manage_amneziawg.sh "ipv6 ndp ..." subcommands
#   - web panel diagnostics (ipv6_ndp_state, validate_ipv6_prefix) and
#     /api/ipv6/ndp/* admin endpoints
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.5.0

load test_helper

# Write a fake /proc/net/if_inet6-style file.
# scope "00" = global, "20" = link-local.
write_if_inet6() {
    local file="$1" scope="$2"
    cat > "$file" << EOF
fe80000000000000549f00fffee40423 02 40 20 80       ens1
EOF
    if [[ "$scope" == "00" ]]; then
        cat >> "$file" << EOF
20010db8000000000000000000000001 02 40 00 80       ens1
EOF
    fi
}

# -------------------------------------------------------------------------
# Shell-side: ipv6_ndp_state classification
# -------------------------------------------------------------------------

@test "ipv6_ndp_state: IPv4-only (no global IPv6) => ipv6_disabled" {
    write_if_inet6 "$TEST_DIR/if_inet6" "20"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_MODE="legacy"
    export AWG_IPV6_SUBNET=""
    [[ "$(ipv6_ndp_state)" == "ipv6_disabled" ]]
}

@test "ipv6_ndp_state: on-link prefix (mode=ndp) => ipv6_prefix_onlink_needs_ndp_proxy" {
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_MODE="ndp"
    export AWG_IPV6_SUBNET="2001:db8:abcd::/64"
    [[ "$(ipv6_ndp_state)" == "ipv6_prefix_onlink_needs_ndp_proxy" ]]
}

@test "ipv6_ndp_state: routed prefix (mode=routed) => ipv6_prefix_routed_to_server (not needed)" {
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_MODE="routed"
    export AWG_IPV6_SUBNET="2001:db8:abcd::/64"
    [[ "$(ipv6_ndp_state)" == "ipv6_prefix_routed_to_server" ]]
}

@test "ipv6_ndp_state: nat66 prefix => ipv6_prefix_routed_to_server (not needed)" {
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_MODE="nat66"
    export AWG_IPV6_SUBNET="fd00:abcd::/64"
    [[ "$(ipv6_ndp_state)" == "ipv6_prefix_routed_to_server" ]]
}

@test "ipv6_ndp_state: global address, no AWG IPv6 prefix => ipv6_public_single_address_only" {
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_MODE="legacy"
    export AWG_IPV6_SUBNET=""
    [[ "$(ipv6_ndp_state)" == "ipv6_public_single_address_only" ]]
}

# -------------------------------------------------------------------------
# Shell-side: validate_ipv6_cidr
# -------------------------------------------------------------------------

@test "validate_ipv6_cidr: accepts a valid IPv6 prefix" {
    command -v python3 &>/dev/null || skip "python3 not available"
    validate_ipv6_cidr "2001:db8:abcd::/64"
}

@test "validate_ipv6_cidr: rejects garbage input" {
    command -v python3 &>/dev/null || skip "python3 not available"
    run validate_ipv6_cidr "not-a-prefix"
    [ "$status" -ne 0 ]
}

@test "validate_ipv6_cidr: rejects IPv4 CIDR" {
    command -v python3 &>/dev/null || skip "python3 not available"
    run validate_ipv6_cidr "10.0.0.0/24"
    [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------------
# Shell-side: ipv6_ndp_generate_config
# -------------------------------------------------------------------------

setup_wan_mock() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/ip" << 'EOF'
#!/bin/bash
if [[ "$1" == "-6" ]]; then
    exit 0
fi
echo "1.1.1.1 dev ens1 src 10.0.0.5"
EOF
    chmod +x "$TEST_DIR/bin/ip"
    export PATH="$TEST_DIR/bin:$PATH"
}

@test "ipv6_ndp_generate_config: writes proxy <wan> { rule <prefix> { iface <vpn> } }" {
    command -v python3 &>/dev/null || skip "python3 not available"
    setup_wan_mock
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    ipv6_ndp_generate_config "2001:db8:abcd::/64"
    [ -f "$NDPPD_CONF_FILE" ]
    grep -qF "proxy ens1 {" "$NDPPD_CONF_FILE"
    grep -qF "rule 2001:db8:abcd::/64 {" "$NDPPD_CONF_FILE"
    grep -qF "iface awg0" "$NDPPD_CONF_FILE"
}

@test "is_prefix_onlink_on_wan: same WAN /64 is on-link, different prefix is not" {
    command -v python3 &>/dev/null || skip "python3 not available"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
if [[ "$*" == "-6 -o addr show dev ens18 scope global" ]]; then
    echo "2: ens18 inet6 2a09:9340:808:4::2/64 scope global"
fi
EOF
    chmod +x "$TEST_DIR/bin/ip"
    export PATH="$TEST_DIR/bin:$PATH"
    is_prefix_onlink_on_wan "2a09:9340:808:4::/64" "ens18"
    run is_prefix_onlink_on_wan "2a09:9340:809:100::/64" "ens18"
    [ "$status" -ne 0 ]
}

@test "ipv6_ndp_generate_config: backs up existing config" {
    command -v python3 &>/dev/null || skip "python3 not available"
    setup_wan_mock
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    echo "# old config" > "$NDPPD_CONF_FILE"
    ipv6_ndp_generate_config "2001:db8:abcd::/64"
    compgen -G "${NDPPD_CONF_FILE}.bak.*" >/dev/null
}

@test "ipv6_ndp_generate_config: rejects invalid prefix and writes nothing" {
    command -v python3 &>/dev/null || skip "python3 not available"
    setup_wan_mock
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    run ipv6_ndp_generate_config "not-a-prefix"
    [ "$status" -ne 0 ]
    [ ! -f "$NDPPD_CONF_FILE" ]
}

@test "ipv6_ndp_generate_config: refuses when IPv6 absent (no global address), writes nothing" {
    command -v python3 &>/dev/null || skip "python3 not available"
    setup_wan_mock
    write_if_inet6 "$TEST_DIR/if_inet6" "20"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    run ipv6_ndp_generate_config "2001:db8:abcd::/64"
    [ "$status" -ne 0 ]
    [ ! -f "$NDPPD_CONF_FILE" ]
}

@test "ipv6_ndp_generate_config: empty prefix and empty AWG_IPV6_SUBNET fails" {
    command -v python3 &>/dev/null || skip "python3 not available"
    setup_wan_mock
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    export AWG_IPV6_SUBNET=""
    run ipv6_ndp_generate_config ""
    [ "$status" -ne 0 ]
    [ ! -f "$NDPPD_CONF_FILE" ]
}

# -------------------------------------------------------------------------
# Shell-side: ipv6_ndp_enable never auto-installs when IPv6 absent
# -------------------------------------------------------------------------

@test "ipv6_ndp_enable: refuses (no auto-install) when IPv6 absent" {
    write_if_inet6 "$TEST_DIR/if_inet6" "20"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    run ipv6_ndp_enable
    [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------------
# manage_amneziawg.sh "ipv6 ndp ..." subcommand wiring (RU + EN)
# -------------------------------------------------------------------------

@test "manage_amneziawg.sh (RU) defines an 'ipv6 ndp' subcommand dispatch" {
    grep -qE '^\s*ndp\)' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_print_status' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_generate_config' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_enable' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_disable' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_restart' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'ipv6_ndp_fix' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "manage_amneziawg_en.sh (EN) defines an 'ipv6 ndp' subcommand dispatch" {
    grep -qE '^\s*ndp\)' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    grep -qF 'ipv6_ndp_print_status' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    grep -qF 'ipv6_ndp_generate_config' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    grep -qF 'ipv6_ndp_fix' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "ipv6_ndp_print_status reports NDP proxy needed for effective ndp" {
    log(){ echo "$*"; }
    log_warn(){ echo "$*"; }
    export -f log log_warn
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    export AWG_IPV6_ENABLED=1
    export AWG_IPV6_MODE_REQUESTED=auto
    export AWG_IPV6_MODE=routed
    export AWG_IPV6_MODE_EFFECTIVE=ndp
    export AWG_IPV6_SUBNET="2a09:9340:808:4::/64"
    run ipv6_ndp_print_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"NDP proxy needed: yes"* ]]
    [[ "$output" == *"IPv6 mode requested: auto"* ]]
    [[ "$output" == *"IPv6 mode effective: ndp"* ]]
}

@test "ipv6_ndp_fix updates auto same-WAN /64 config and is idempotent" {
    command -v python3 &>/dev/null || skip "python3 not available"
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/systemd/ndppd.service.d" "$TEST_DIR/sysctl.d"
    cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
if [[ "$*" == "route get 1.1.1.1" ]]; then
    echo "1.1.1.1 dev ens18 src 10.0.0.5"
    exit 0
fi
if [[ "$*" == "-6 -o addr show dev ens18 scope global" ]]; then
    echo "2: ens18 inet6 2a09:9340:808:4::2/64 scope global"
    exit 0
fi
if [[ "$*" == "-6 route show default" ]]; then
    echo "default via 2a09:9340:808:4::1 dev ens18"
    exit 0
fi
exit 0
EOF
    cat > "$TEST_DIR/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
    is-active) echo active ;;
    is-enabled) echo enabled ;;
esac
exit 0
EOF
    cat > "$TEST_DIR/bin/sysctl" <<'EOF'
#!/bin/bash
exit 0
EOF
    touch "$TEST_DIR/bin/ndppd"
    chmod +x "$TEST_DIR/bin/"*
    export PATH="$TEST_DIR/bin:$PATH"
    export NDPPD_CONF_FILE="$TEST_DIR/ndppd.conf"
    export NDPPD_SYSTEMD_DROPIN="$TEST_DIR/systemd/ndppd.service.d/10-amneziawg.conf"
    export NDP_SYSCTL_FILE="$TEST_DIR/sysctl.d/99-amneziawg-ndp.conf"
    write_if_inet6 "$TEST_DIR/if_inet6" "00"
    export IF_INET6_FILE="$TEST_DIR/if_inet6"
    cat > "$CONFIG_FILE" <<'EOF'
export AWG_IPV6_ENABLED=1
export AWG_IPV6_MODE='routed'
export AWG_IPV6_MODE_REQUESTED='auto'
export AWG_IPV6_MODE_EFFECTIVE='routed'
export AWG_IPV6_MODE_REASON='selected routed because user provided dedicated prefix'
export AWG_IPV6_SUBNET='2a09:9340:808:4::/64'
export AWG_IPV6_NDP_PROXY=0
EOF
    run ipv6_ndp_fix
    [ "$status" -eq 0 ]
    grep -qF "export AWG_IPV6_MODE='ndp'" "$CONFIG_FILE"
    grep -qF "export AWG_IPV6_MODE_EFFECTIVE='ndp'" "$CONFIG_FILE"
    grep -qF "export AWG_IPV6_NDP_PROXY=1" "$CONFIG_FILE"
    grep -qF "rule 2a09:9340:808:4::/64" "$NDPPD_CONF_FILE"
    grep -qF "iface awg0" "$NDPPD_CONF_FILE"
    run ipv6_ndp_fix
    [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------------
# Web panel: Python-side diagnostics and API endpoints
# -------------------------------------------------------------------------

@test "web panel: validate_ipv6_prefix accepts valid and rejects invalid prefixes" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

assert server.validate_ipv6_prefix("2001:db8:abcd::/64") == "2001:db8:abcd::/64"
for bad in ("", "not-a-prefix", "10.0.0.0/24", "2001:db8::1/64"):
    try:
        server.validate_ipv6_prefix(bad)
    except ValueError:
        continue
    raise AssertionError(f"expected ValueError for {bad!r}")
PY
}

@test "web panel: ipv6_ndp_state classifies modes consistently with shell side" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

disabled = {"mode": "disabled", "global_address": False}
enabled = {"mode": "enabled", "global_address": True}

assert server.ipv6_ndp_state(disabled, {}) == "ipv6_disabled"
assert server.ipv6_ndp_state(enabled, {"AWG_IPV6_MODE": "ndp", "AWG_IPV6_SUBNET": "2001:db8::/64"}) == "ipv6_prefix_onlink_needs_ndp_proxy"
assert server.ipv6_ndp_state(enabled, {"AWG_IPV6_MODE": "routed", "AWG_IPV6_SUBNET": "2001:db8::/64"}) == "ipv6_prefix_routed_to_server"
assert server.ipv6_ndp_state(enabled, {"AWG_IPV6_MODE": "nat66", "AWG_IPV6_SUBNET": "fd00::/64"}) == "ipv6_prefix_routed_to_server"
assert server.ipv6_ndp_state(enabled, {"AWG_IPV6_MODE": "legacy", "AWG_IPV6_SUBNET": ""}) == "ipv6_public_single_address_only"
PY
}

@test "web panel: ndp readiness marks missing ndppd as error for effective ndp" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server

server.shutil.which = lambda name: None
result = server.ndp_proxy_check(
    "enabled",
    True,
    {"AWG_IPV6_MODE_EFFECTIVE": "ndp", "AWG_IPV6_SUBNET": "2a09:9340:808:4::/64"},
    "ens18",
)
assert result["needed"] is True
assert result["status"] in {"error", "warn"}
assert "NDP proxy is needed" in result["detail"]
PY
}

@test "web panel: vpn-readiness ndp_proxy includes mode/wan_iface/vpn_iface/prefix" {
    command -v python3 &>/dev/null || skip "python3 not available"
    REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

payload = server.vpn_readiness_payload(force=True)
ndp = payload["ndp_proxy"]
for key in ("mode", "wan_iface", "vpn_iface", "prefix", "proxy_ndp_sysctl", "ndppd_active"):
    assert key in ndp, f"missing {key}"
assert ndp["mode"] in {
    "ipv6_disabled",
    "ipv6_public_single_address_only",
    "ipv6_prefix_routed_to_server",
    "ipv6_prefix_onlink_needs_ndp_proxy",
    "ipv6_unknown_manual_review",
}
PY
}

@test "web panel: /api/ipv6/ndp/generate is super-only and validates prefix" {
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

super_token = "super-secret-ndp"
user_token = "user-secret-ndp"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

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

# user (non-super) is forbidden
handler = make_handler("POST", "/api/ipv6/ndp/generate", token=user_token, body={"prefix": "2001:db8::/64"})
handler.do_POST()
assert handler.responses[0] in (401, 403), handler.responses

# super with invalid prefix -> 400, no manage call
server.RATE.clear()
handler = make_handler("POST", "/api/ipv6/ndp/generate", token=super_token, body={"prefix": "not-a-prefix"})
handler.do_POST()
assert handler.responses == [400], handler.responses
assert calls == []

# super with valid prefix -> 200, manage called with the prefix
server.RATE.clear()
handler = make_handler("POST", "/api/ipv6/ndp/generate", token=super_token, body={"prefix": "2001:db8:abcd::/64"})
handler.do_POST()
assert handler.responses == [200], handler.responses
assert calls[-1] == ("ipv6", "ndp", "generate", "2001:db8:abcd::/64")
PY
    rm -rf "$tmp"
}

@test "web panel: /api/ipv6/ndp/{enable,disable,restart} are super-only and call manage" {
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

super_token = "super-secret-ndp2"
user_token = "user-secret-ndp2"
server.write_tokens({
    "super_token_hash": server.token_hash(super_token),
    "users": {server.token_hash(user_token): {"name": "u", "clients": []}},
})

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

for action in ("enable", "disable", "restart"):
    server.RATE.clear()
    handler = make_handler("POST", f"/api/ipv6/ndp/{action}", token=user_token, body={})
    handler.do_POST()
    assert handler.responses[0] in (401, 403), (action, handler.responses)

    server.RATE.clear()
    handler = make_handler("POST", f"/api/ipv6/ndp/{action}", token=super_token, body={})
    handler.do_POST()
    assert handler.responses == [200], (action, handler.responses)
    assert calls[-1] == ("ipv6", "ndp", action), (action, calls)
PY
    rm -rf "$tmp"
}
