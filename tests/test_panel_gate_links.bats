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
    grep -qF 'SameSite=Strict' "$BATS_TEST_DIRNAME/../web/server.py"
    grep -qF '/api/gate/links' "$BATS_TEST_DIRNAME/../web/app.js"
}
