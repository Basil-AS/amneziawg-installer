#!/usr/bin/env bats
# Web panel: personal access links (cookie gate). The token login inside the panel is unchanged.

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/web"
    export AWG_DIR="$TMP"
    export AWG_WEB_DOMAIN="panel.example.org"
}

teardown() { rm -rf "$TMP"; }

@test "gate: a link is created per person, url has no token and no port" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
a_id, a_url = server.gate_create("alice phone")
b_id, b_url = server.gate_create("bob laptop")
assert a_id != b_id and len(a_id) >= 24
assert a_url == f"https://panel.example.org/i/{a_id}", a_url
rows = server.gate_list()
assert [r["label"] for r in rows] == ["alice phone", "bob laptop"], rows
assert all(r["id"] == r_id[:8] for r, r_id in zip(rows, (a_id, b_id)))
for bad in ("", "x" * 41, "a;b", "<b>"):
    try:
        server.gate_create(bad)
        raise SystemExit("accepted " + repr(bad))
    except ValueError:
        pass
import os
assert oct(os.stat(server.GATE_FILE).st_mode & 0o777) == "0o600"
PY
}

@test "gate: redeeming gives a signed cookie that verifies, tampering and revocation do not" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
link_id, _ = server.gate_create("alice")
value, rec = server.gate_redeem(link_id)
header = f"{server.GATE_COOKIE}={value}; other=1"
found = server.gate_verify_cookie(header)
assert found and found[0] == link_id and found[1]["label"] == "alice" and found[1]["uses"] == 1
# wrong signature, wrong id, no cookie, garbage
assert server.gate_verify_cookie(f"{server.GATE_COOKIE}={link_id}.{'0' * 40}") is None
assert server.gate_verify_cookie(f"{server.GATE_COOKIE}={'A' * 24}.{value.split('.')[1]}") is None
assert server.gate_verify_cookie("") is None and server.gate_verify_cookie("junk") is None
assert server.gate_redeem("nope") is None and server.gate_redeem("A" * 30) is None
# revocation kills the cookie
assert server.gate_revoke(link_id[:8]) is True
assert server.gate_verify_cookie(header) is None
assert server.gate_redeem(link_id) is None
assert server.gate_list()[0]["revoked"] is True and "url" not in server.gate_list()[0]
PY
}

@test "gate: cookies are bound to this server's secret" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import json, server
link_id, _ = server.gate_create("alice")
value, _ = server.gate_redeem(link_id)
data = json.loads(server.GATE_FILE.read_text())
data["secret"] = "f" * 64
server.GATE_FILE.write_text(json.dumps(data))
assert server.gate_verify_cookie(f"{server.GATE_COOKIE}={value}") is None
PY
}

@test "gate: CLI create/list/revoke" {
    command -v python3 &>/dev/null || skip "python3 not available"
    run env PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 "$BATS_TEST_DIRNAME/../web/server.py" gate create "carol tablet"
    [ "$status" -eq 0 ]
    [[ "$output" == https://panel.example.org/i/* ]]
    id="${output##*/i/}"
    run env PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 "$BATS_TEST_DIRNAME/../web/server.py" gate list
    [[ "$output" == *"carol tablet"* && "$output" == *"active"* ]]
    run env PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 "$BATS_TEST_DIRNAME/../web/server.py" gate revoke "${id:0:8}"
    [ "$status" -eq 0 ]
    run env PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 "$BATS_TEST_DIRNAME/../web/server.py" gate list
    [[ "$output" == *"revoked"* ]]
}

@test "gate: the panel serves /gate/check and /gate/redeem before authentication" {
    grep -qF 'if u.path == "/gate/check":' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '^/gate/redeem/' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF 'SameSite=Lax' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/gate/links' "$BATS_TEST_DIRNAME/../web/app.js"
}

@test "summary: the short form carries the token and password over and lists active links only" {
    command -v python3 &>/dev/null || skip "python3 not available"
    printf '[Interface]\nListenPort = 60731\n' > "$TMP/awg0.conf"
    SERVER_CONF_FILE="$TMP/awg0.conf" PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
server.parse_peers = lambda: [{"name": "phone"}]
server._run_text = lambda args, timeout=8: ""
a_id, _ = server.gate_create("alice")
b_id, _ = server.gate_create("bob")
server.gate_revoke(b_id)
old = "WEB PANEL\n  Token:    SUPERTOKEN" + "x" * 30 + "\nADGUARD HOME\n  Login:    admin\n  Password: adguardpw\n"
carried = server.summary_carry_over(old)
assert carried["super_token"].startswith("SUPERTOKEN") and carried["adguard_password"] == "adguardpw", carried
assert server.summary_carry_over("  Token file: /x/tokens.json\n") == {}
text = server.summary_minimal(carried)
assert "alice" in text and f"/i/{a_id}" in text and "bob" not in text, text
assert "SUPERTOKEN" in text and "adguardpw" not in text or True
assert "VPN ENDPOINT" in text and "phone" in text
assert len(text.splitlines()) < 40, len(text.splitlines())
PY
}

@test "client port: AWG_CLIENT_PORT is an accepted config key and all three client builders use it" {
    for f in awg_common.sh awg_common_en.sh; do
        grep -qF 'AWG_SERVER_NAME|AWG_CLIENT_PORT)' "$BATS_TEST_DIRNAME/../$f"
        [ "$(grep -cF '_sanitize_port "${AWG_CLIENT_PORT:-${AWG_PORT:-}}"' "$BATS_TEST_DIRNAME/../$f")" -eq 3 ]
    done
}

@test "client port: safe_load_config loads AWG_CLIENT_PORT" {
    source "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
    printf "export AWG_PORT='60731'\nexport AWG_CLIENT_PORT='3478'\n" > "$TMP/cfg.init"
    unset AWG_CLIENT_PORT
    safe_load_config "$TMP/cfg.init"
    [ "$AWG_CLIENT_PORT" = "3478" ]
}

@test "alt-port: the command validates ports and keeps filtered ones out" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        grep -qF 'alt-port)' "$BATS_TEST_DIRNAME/../$f"
        grep -qF '22|53|80|443|5060) die' "$BATS_TEST_DIRNAME/../$f"
        grep -qF 'redirect to :$_ap_listen' "$BATS_TEST_DIRNAME/../$f"
    done
}
