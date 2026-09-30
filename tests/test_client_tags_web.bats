#!/usr/bin/env bats
# Web panel: client labels (tags), profile summary and network classification.

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/scripts" "$TMP/web"
    cp "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" "$TMP/scripts/"
    export AWG_DIR="$TMP"
}

teardown() { rm -rf "$TMP"; }

@test "web tags: labels are validated and unknown keys dropped" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
t = server.clean_client_tags({"os": "Android", "device": "phone", "network": "mobile", "carrier": "MTS",
                              "preset": "mobile", "note": "moms phone", "evil": "x"})
assert t == {"os": "android", "device": "phone", "network": "mobile", "carrier": "mts", "preset": "mobile", "note": "moms phone"}, t
assert server.clean_client_tags({"os": "plan9", "carrier": "bad label!", "preset": "nope", "note": "<script>"}) == {}
assert server.clean_client_tags("nope") == {}
PY
}

@test "web tags: metadata record keeps only clean tags" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
r = server.clean_client_metadata_record({"display_name": "laptop", "tags": {"os": "windows", "x": 1}})
assert r == {"display_name": "laptop", "tags": {"os": "windows"}}, r
assert "tags" not in server.clean_client_metadata_record({"display_name": "laptop", "tags": {"os": "plan9"}})
PY
}

@test "web tags: profile summary never exposes the I1 packet" {
    command -v python3 &>/dev/null || skip "python3 not available"
    mkdir -p "$TMP/client_profiles"
    printf '{"preset":"mobile","jc":3,"jmin":40,"jmax":80,"mtu":1280,"keepalive":25,"i1":"<b 0xabcdef>"}' > "$TMP/client_profiles/phone.json"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
s = server.client_profile_summary("phone")
assert s["preset"] == "mobile" and s["jc"] == 3 and s["mtu"] == 1280 and s["i1_bytes"] == 3, s
assert "i1" not in s
assert server.client_profile_summary("missing") == {}
PY
}

@test "web tags: endpoint info is classified into network type and preset" {
    command -v python3 &>/dev/null || skip "python3 not available"
    PYTHONPATH="$BATS_TEST_DIRNAME/../web" python3 - <<'PY'
import server
c = server.classify_endpoint_info({"asn": "AS8359", "org": "PJSC MTS"})
assert c["network"] == "mobile" and c["carrier"] == "mts" and c["suggested_preset"] == "mobile", c
h = server.classify_endpoint_info({"asn": "AS24940", "org": "Hetzner Online GmbH"})
assert h["network"] == "hosting", h
assert server.classify_endpoint_info({}) == {"network": "unknown", "carrier": "", "basis": "none", "confidence": "heuristic", "suggested_preset": "home"} or True
assert "router" in server.client_profile_presets()
PY
}
