#!/usr/bin/env bats

@test "web/server.py compiles with Python stdlib" {
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -m py_compile "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "installer deploys awg-web.service and token store" {
    grep -qF 'awg-web.service' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'Authorization' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "English installer deploys repository web assets instead of legacy inline panel" {
    local installer="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    ! grep -qF 'TOKEN_FILE = WEB_DIR / "auth_token"' "$installer"
    ! grep -qF 'cat > "$web_dir/server.py"' "$installer"
    grep -qF 'tokens.json' "$installer"
    for asset in server.py index.html style.css app.js favicon.svg; do
        grep -qF "for asset in server.py index.html style.css app.js favicon.svg" "$installer"
        [ -f "$BATS_TEST_DIRNAME/../web/$asset" ]
    done
}

@test "web index includes Tailwind and ApexCharts" {
    grep -q 'cdn.tailwindcss.com' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -q 'apexcharts' "$BATS_TEST_DIRNAME/../web/index.html"
    grep -q 'app.js' "$BATS_TEST_DIRNAME/../web/index.html"
}

@test "web panel exposes RBAC and token controls" {
    grep -qF 'tokens.json' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/tokens/([^/]+)/name' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'super_token_hash' "$BATS_TEST_DIRNAME/../web/server.py"
}

@test "web server hardening keeps bounded rate, body, logs, and token storage" {
    grep -qF 'RATE_LOCK = threading.Lock()' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'RATE_CLEANUP_INTERVAL = 60' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'MAX_JSON_BODY = 64 * 1024' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'TOKENS_LOCK = threading.RLock()' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'def tail_lines(' "$BATS_TEST_DIRNAME/../web/server.py"
    ! grep -qF 'f.read_text(errors="ignore").splitlines()[-100:]' "$BATS_TEST_DIRNAME/../web/server.py"
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

@test "traffic history keeps persistent totals across counter resets" {
    command -v python3 &>/dev/null || skip "python3 not available"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/web"
    AWG_DIR="$tmp" SERVER_CONF_FILE="$tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import json
import os
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
PY
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
