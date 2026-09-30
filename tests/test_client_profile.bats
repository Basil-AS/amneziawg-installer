#!/usr/bin/env bats
# Per-client sender profile: scripts/awg_client_profile.py and the awg_common.sh hooks.

load test_helper

PROF() { python3 "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" "$@"; }

@test "client profile: generate returns sane sender-side fields" {
    run PROF generate --os android --network mobile
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; p=json.loads(sys.argv[1]); assert p["preset"]=="mobile"; assert p["jmin"]<p["jmax"]; assert 1<=p["jc"]<=10; assert p["mtu"]==1280; assert p["i1"].startswith("<b 0x")' "$output"
    [ "$status" -eq 0 ]
}

@test "client profile: 30 profiles are pairwise different and I1 first byte is odd" {
    for _ in $(seq 1 30); do PROF generate --os windows >> "$TEST_DIR/all.jsonl"; done
    run python3 -c '
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
assert len({r["i1"] for r in rows})==30
assert all(int(r["i1"][5:7],16)%2==1 for r in rows)
assert len({(r["jmin"],r["jmax"],r["jc"]) for r in rows})>5
' "$TEST_DIR/all.jsonl"
    [ "$status" -eq 0 ]
}

@test "client profile: preset suggestion follows os/network/device" {
    [ "$(PROF generate --os router | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "router" ]
    [ "$(PROF generate --os ios --network mobile | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "ios" ]
    [ "$(PROF generate --os windows | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "desktop" ]
    [ "$(PROF generate --preset stealth | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "stealth" ]
}

@test "client profile: invalid labels are rejected" {
    run PROF generate --os plan9
    [ "$status" -eq 1 ]
    run PROF generate --carrier 'bad label!'
    [ "$status" -eq 1 ]
    run PROF generate --preset nope
    [ "$status" -eq 1 ]
}

@test "client profile: classify uses ASN then org name" {
    run PROF classify --asn AS8359 --org "PJSC MTS"
    [[ "$output" == *'"network": "mobile"'* && "$output" == *'"carrier": "mts"'* ]]
    run PROF classify --org "Hetzner Online GmbH"
    [[ "$output" == *'"network": "hosting"'* ]]
    run PROF classify
    [[ "$output" == *'"network": "unknown"'* ]]
}

@test "client profile: env output is validated" {
    PROF generate --os linux > "$TEST_DIR/p.json"
    run PROF env "$TEST_DIR/p.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"jc="* && "$output" == *"jmin="* && "$output" == *"mtu="* && "$output" == *"i1=<b 0x"* ]]
    printf '{"jc":4,"jmin":90,"jmax":50,"mtu":1280,"keepalive":25}' > "$TEST_DIR/bad.json"
    run PROF env "$TEST_DIR/bad.json"
    [ "$status" -eq 1 ]
    printf '{"jc":4,"jmin":50,"jmax":90,"mtu":1280,"keepalive":25,"i1":"$(id)"}' > "$TEST_DIR/bad2.json"
    run PROF env "$TEST_DIR/bad2.json"
    [ "$status" -eq 1 ]
}

@test "client profile: _apply_client_profile overrides only sender-side values" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    mkdir -p "$AWG_CLIENT_PROFILE_DIR"
    printf '{"jc":3,"jmin":40,"jmax":77,"mtu":1200,"keepalive":20,"i1":"<b 0xab>"}' > "$AWG_CLIENT_PROFILE_DIR/laptop.json"
    AWG_Jc=9 AWG_Jmin=1 AWG_Jmax=2 AWG_S1=55 AWG_H4="1-2" AWG_I1="<r 5>"
    _apply_client_profile laptop
    [ "$AWG_Jc" = "3" ] && [ "$AWG_Jmin" = "40" ] && [ "$AWG_Jmax" = "77" ]
    [ "$AWG_I1" = "<b 0xab>" ]
    [ "$CLIENT_PROFILE_MTU" = "1200" ] && [ "$CLIENT_PROFILE_KEEPALIVE" = "20" ]
    [ "$AWG_S1" = "55" ] && [ "$AWG_H4" = "1-2" ]
}

@test "client profile: AWG_I1_OVERRIDE wins over the profile I1" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    mkdir -p "$AWG_CLIENT_PROFILE_DIR"
    printf '{"jc":3,"jmin":40,"jmax":77,"mtu":1200,"keepalive":20,"i1":"<b 0xab>"}' > "$AWG_CLIENT_PROFILE_DIR/laptop.json"
    AWG_I1="<r 5>"; export AWG_I1_OVERRIDE="<r 9>"
    _apply_client_profile laptop
    [ "$AWG_I1" = "<r 5>" ]
}

@test "client profile: a missing or broken profile changes nothing" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    mkdir -p "$AWG_CLIENT_PROFILE_DIR"
    AWG_Jc=9; AWG_Jmin=1; AWG_Jmax=2
    _apply_client_profile nobody
    [ "$AWG_Jc" = "9" ] && [ -z "$CLIENT_PROFILE_MTU" ]
    printf 'not json' > "$AWG_CLIENT_PROFILE_DIR/broken.json"
    _apply_client_profile broken
    [ "$AWG_Jc" = "9" ] && [ -z "$CLIENT_PROFILE_MTU" ]
}

@test "client profile: client_profile_set writes a 0600 file and autocreate is opt-out" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    client_profile_set phone android phone mobile mts
    [ -f "$AWG_CLIENT_PROFILE_DIR/phone.json" ]
    [ "$(stat -c %a "$AWG_CLIENT_PROFILE_DIR/phone.json")" = "600" ]
    AWG_PER_CLIENT_PARAMS=0 client_profile_autocreate other
    [ ! -f "$AWG_CLIENT_PROFILE_DIR/other.json" ]
    client_profile_autocreate other
    [ -f "$AWG_CLIENT_PROFILE_DIR/other.json" ]
}
