#!/usr/bin/env bats
# Web panel: client labels (tags), profile summary, network classification, statistics, access log.

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/scripts" "$TMP/web"
    cp "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" "$TMP/scripts/"
    export AWG_DIR="$TMP"
}

teardown() { rm -rf "$TMP"; }

@test "web tags: free-form slugs, labels list and note; junk is dropped" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
t = server.clean_client_tags({"os": "OpenWrt", "device": "router", "network": "Home", "carrier": "MegaFon",
                              "labels": "openwrt, bpi-r4, OpenWrt, bad label!, office", "note": "main gw", "evil": "x"})
assert t == {"os": "openwrt", "device": "router", "network": "home", "carrier": "megafon",
             "labels": ["openwrt", "bpi-r4", "bad", "office"], "note": "main gw"}, t
assert server.clean_client_tags({"os": "<script>", "carrier": "x" * 40, "note": "<b>"}) == {}
assert len(server.clean_client_tags({"labels": [f"l{i}" for i in range(20)]})["labels"]) == 8
assert server.clean_client_tags("nope") == {}
PY
}

@test "web tags: metadata record keeps only clean tags" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
r = server.clean_client_metadata_record({"display_name": "laptop", "tags": {"os": "windows", "x": 1}})
assert r == {"display_name": "laptop", "tags": {"os": "windows"}}, r
assert "tags" not in server.clean_client_metadata_record({"display_name": "laptop", "tags": {"os": "<x>"}})
PY
}

@test "web tags: profile summary never exposes the CPS packets and the profile file is 0600" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import os, server
server.write_client_profile("phone", {"preset": "mobile", "jc": 3, "jmin": 40, "jmax": 90, "mtu": 1280, "keepalive": 25,
                                      "i1": "<b 0xab><r 10>", "extra": {"content_padding": "10-90"}})
s = server.client_profile_summary("phone")
assert s["i1_bytes"] == 11 and s["extra"] == {"content_padding": "10-90"} and s["mtu"] == 1280, s
assert "i1" not in s
assert oct(os.stat(server.client_profile_path("phone")).st_mode & 0o777) == "0o600"
assert server.client_profile_summary("missing") == {}
PY
}

@test "web tags: endpoint info is classified into network type and preset" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
c = server.classify_endpoint_info({"asn": "AS8359", "org": "PJSC MTS"})
assert c["network"] == "mobile" and c["carrier"] == "mts" and c["suggested_preset"] == "mobile", c
assert server.classify_endpoint_info({"asn": "AS24940", "org": "Hetzner Online GmbH"})["network"] == "hosting"
assert "router" in server.client_profile_presets()
PY
}

@test "web tags: statistics group clients and traffic by tag" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
server.load_client_metadata = lambda: {"clients": {
    "a": {"display_name": "a", "tags": {"os": "openwrt", "carrier": "megafon", "labels": ["gw"]}},
    "b": {"display_name": "b", "tags": {"os": "openwrt", "labels": ["gw", "office"]}},
}}
r = server.client_tag_stats([{"name": "a"}, {"name": "b"}, {"name": "c"}], {"a": {"rx": 5, "tx": 7}, "b": {"rx": 1, "tx": 2}})
assert r["total"] == 3 and r["untagged"] == ["c"]
assert r["fields"]["os"]["openwrt"] == {"count": 2, "clients": ["a", "b"], "rx": 6, "tx": 9}, r
assert r["labels"]["gw"]["count"] == 2 and r["labels"]["office"]["count"] == 1
PY
}

@test "web access log: JSON lines with device, rotation, 0600" {
    command -v python3 &>/dev/null || skip "python3 not available"
    ACCESSLOG="$TMP/access.log" PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import os, server
from pathlib import Path
server.ACCESS_LOG_FILE = Path(os.environ["ACCESSLOG"])
server.audit_log = lambda m: None
server.access_log_event("auth_fail", "203.0.113.9", "Mozilla/5.0 (Linux; Android 14) Chrome/120 Mobile Safari/537.36", path="/api/status", reason="bad token")
server.access_log_event("action", "203.0.113.9", "curl/8.0", method="POST", path="/api/clients", role="super", fp="abcd1234")
rows = server.access_log_tail(10)
assert [r["kind"] for r in rows] == ["action", "auth_fail"], rows
assert rows[1]["device"] == {"os": "android", "browser": "chrome", "form": "mobile"}, rows[1]
assert rows[0]["device"]["browser"] == "curl"
assert server.access_log_tail(10, "auth_fail")[0]["reason"] == "bad token"
assert oct(os.stat(server.ACCESS_LOG_FILE).st_mode & 0o777) == "0o600"
server.ACCESS_LOG_MAX_BYTES = 10
server.access_log_event("session", "203.0.113.9", "x")
assert os.path.exists(str(server.ACCESS_LOG_FILE) + ".1")
PY
}

@test "web access log: a session is logged once per ip and device, then again after idling" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import time, server
auth = {"hash": "ab" * 32, "role": "super"}
assert server.note_api_session(auth, "203.0.113.9", "UA-1") is True
assert server.note_api_session(auth, "203.0.113.9", "UA-1") is False
assert server.note_api_session(auth, "203.0.113.10", "UA-1") is True
assert server.note_api_session(auth, "203.0.113.9", "UA-2") is True
key = (server.auth_fingerprint(auth), "203.0.113.9", hash("UA-1"))
server.ACCESS_SESSIONS[key] = time.time() - 4000
assert server.note_api_session(auth, "203.0.113.9", "UA-1") is True
PY
}

@test "web params: shared server values are read-only context" {
    command -v python3 &>/dev/null || skip "python3 not available"
    printf '[Interface]\nS1 = 101\nH4 = 5-9\nJc = 4\n' > "$TMP/awg0.conf"
    SERVER_CONF_FILE="$TMP/awg0.conf" PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
sh = server.shared_server_params()
assert sh.get("S1") == "101" and sh.get("H4") == "5-9", sh
payload = server.client_params_payload("phone")
assert payload["server"]["S1"] == "101" and "shared_note" in payload and "limits" in payload and "presets" in payload
PY
}
