#!/usr/bin/env bats
# Per-client profile: free-form labels, local timers/padding, I2-I5 and the editor validation rules.

load test_helper

PROF() { python3 "$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py" "$@"; }

@test "client profile: openwrt/keenetic count as routers for the preset" {
    [ "$(PROF generate --os openwrt | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "router" ]
    [ "$(PROF generate --os keenetic | python3 -c 'import json,sys; print(json.load(sys.stdin)["preset"])')" = "router" ]
}

@test "client profile: labels are free-form slugs" {
    run PROF generate --os openwrt --device router --network home --carrier megafon
    [ "$status" -eq 0 ]
    run PROF generate --os 'bad os!'
    [ "$status" -eq 1 ]
}

@test "client profile: generated extras are per-client ranges and reach the shell env" {
    for _ in $(seq 1 20); do PROF generate --os linux >> "$TEST_DIR/x.jsonl"; done
    run python3 -c '
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
assert len({r["extra"]["content_padding"] for r in rows})>5
for r in rows:
    for k,v in r["extra"].items():
        a,b=map(int,v.split("-")); assert 0<=a<=b<=300,(k,v)
' "$TEST_DIR/x.jsonl"
    [ "$status" -eq 0 ]
    PROF generate --os linux > "$TEST_DIR/p.json"
    run PROF env "$TEST_DIR/p.json"
    [[ "$output" == *"content_padding="* && "$output" == *"keepalive_timeout="* && "$output" == *"rekey_after_time="* && "$output" == *"rekey_timeout="* ]]
}

@test "client profile: validate accepts editor payloads" {
    printf '{"jc":4,"jmin":50,"jmax":120,"mtu":1380,"keepalive":25,"i1":"<b 0xab><r 100>","i2":"<r 64>","extra":{"content_padding":"10-100"}}' > "$TEST_DIR/ok.json"
    run PROF validate "$TEST_DIR/ok.json"
    [ "$status" -eq 0 ]
}

@test "client profile: validate rejects out-of-range, inverted and unsafe values" {
    printf '%s' '{"jc":99,"jmin":50,"jmax":120,"mtu":1380,"keepalive":25}' > "$TEST_DIR/b1.json"
    printf '%s' '{"jc":4,"jmin":150,"jmax":120,"mtu":1380,"keepalive":25}' > "$TEST_DIR/b2.json"
    printf '%s' '{"jc":4,"jmin":50,"jmax":120,"mtu":100,"keepalive":25}' > "$TEST_DIR/b3.json"
    printf '%s' '{"jc":4,"jmin":50,"jmax":120,"mtu":1380,"keepalive":25,"i1":"rm -rf /"}' > "$TEST_DIR/b4.json"
    printf '%s' '{"jc":4,"jmin":50,"jmax":120,"mtu":1380,"keepalive":25,"extra":{"content_padding":"90-10"}}' > "$TEST_DIR/b5.json"
    for n in 1 2 3 4 5; do
        run PROF validate "$TEST_DIR/b$n.json"
        [ "$status" -eq 1 ]
    done
}

@test "client profile: _apply_client_profile applies I2-I5 and the local timers" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    mkdir -p "$AWG_CLIENT_PROFILE_DIR"
    printf '%s' '{"jc":3,"jmin":40,"jmax":77,"mtu":1200,"keepalive":20,"i1":"<r 50>","i2":"<r 60>","i5":"<b 0xaa>","extra":{"content_padding":"12-90","keepalive_timeout":"21-30","rekey_after_time":"101-111","rekey_timeout":"3-5"}}' > "$AWG_CLIENT_PROFILE_DIR/n.json"
    _apply_client_profile n
    [ "$AWG_I2" = "<r 60>" ] && [ "$AWG_I5" = "<b 0xaa>" ]
    [ "$CLIENT_PROFILE_PADDING" = "12-90" ] && [ "$CLIENT_PROFILE_KA_TIMEOUT" = "21-30" ]
    [ "$CLIENT_PROFILE_REKEY_AFTER" = "101-111" ] && [ "$CLIENT_PROFILE_REKEY_TIMEOUT" = "3-5" ]
}

@test "client profile: the 3.x filter rewrites only the local timer lines" {
    export AWG_CLIENT_PROFILE_SCRIPT_PATH="$BATS_TEST_DIRNAME/../scripts/awg_client_profile.py"
    export AWG_CLIENT_PROFILE_DIR="$TEST_DIR/client_profiles"
    mkdir -p "$AWG_CLIENT_PROFILE_DIR"
    printf '%s' '{"jc":3,"jmin":40,"jmax":77,"mtu":1200,"keepalive":20,"i1":"<r 50>","extra":{"content_padding":"12-90","keepalive_timeout":"21-30","rekey_after_time":"101-111","rekey_timeout":"3-5"}}' > "$AWG_CLIENT_PROFILE_DIR/n.json"
    _apply_client_profile n
    out=$(printf 'ContentPaddingAddition = 10-100\nHeaderProtectionKey = KEEP\nKeepaliveTimeout = 25-35\nRekeyAfterTime = 100-120\nRekeyTimeout = 3-7\nRandomTrailers = off\n' | _client_profile_apply_extra)
    [[ "$out" == *"ContentPaddingAddition = 12-90"* && "$out" == *"KeepaliveTimeout = 21-30"* ]]
    [[ "$out" == *"RekeyAfterTime = 101-111"* && "$out" == *"RekeyTimeout = 3-5"* ]]
    [[ "$out" == *"HeaderProtectionKey = KEEP"* && "$out" == *"RandomTrailers = off"* ]]
}
