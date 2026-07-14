#!/usr/bin/env bats
# Upstream v5.18.0 I2-I5 passthrough adapted to the fork runtime.

load test_helper

create_server_config_with_i() {
    create_server_config
    sed -i '/^H4 = /a I1 = <r 100>\nI2 = <b 0xf1>\nI3 = <c>\nI4 = <r 64>\nI5 = <t>' "$SERVER_CONF_FILE"
}

decode_vpn_inner() {
    python3 - "$1" <<'PY'
import base64, json, sys, zlib
payload = sys.argv[1].removeprefix("vpn://")
raw = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["containers"][0]["awg"]["last_config"])
PY
}

@test "I2-I5 load atomically from the live server config" {
    create_server_config_with_i
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_I1" = "<r 100>" ]
    [ "$AWG_I2" = "<b 0xf1>" ]
    [ "$AWG_I3" = "<c>" ]
    [ "$AWG_I4" = "<r 64>" ]
    [ "$AWG_I5" = "<t>" ]
}

@test "optional I2-I5 do not leak from stale init state" {
    create_server_config_with_i
    load_awg_params
    [ "$AWG_I2" = "<b 0xf1>" ]
    create_server_config
    load_awg_params
    [ -z "${AWG_I2:-}" ]
    [ -z "${AWG_I5:-}" ]
}

@test "client config receives all server special-junk fields" {
    create_server_config_with_i
    render_client_config "client" "10.9.9.2" "CLIENT_PRIV" "SERVER_PUB" "vpn.example" "39743"
    grep -qFx 'I1 = <r 100>' "$AWG_DIR/client.conf"
    grep -qFx 'I2 = <b 0xf1>' "$AWG_DIR/client.conf"
    grep -qFx 'I3 = <c>' "$AWG_DIR/client.conf"
    grep -qFx 'I4 = <r 64>' "$AWG_DIR/client.conf"
    grep -qFx 'I5 = <t>' "$AWG_DIR/client.conf"
}

@test "client config omits unset I2-I5 fields" {
    create_server_config
    render_client_config "client" "10.9.9.2" "CLIENT_PRIV" "SERVER_PUB" "vpn.example" "39743"
    run grep -E '^I[2-5] = ' "$AWG_DIR/client.conf"
    [ "$status" -ne 0 ]
}

@test "vpn URI carries I2-I5 in structured fields and embedded config" {
    command -v python3 >/dev/null || skip "python3 unavailable"
    perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "required Perl modules unavailable"
    create_server_config_with_i
    echo 'SERVER_PUB' > "$AWG_DIR/server_public.key"
    render_client_config "client" "10.9.9.2" "CLIENT_PRIV" "SERVER_PUB" "vpn.example" "39743"
    generate_vpn_uri "client"
    local inner
    inner=$(decode_vpn_inner "$(cat "$AWG_DIR/client.vpnuri")")
    [[ "$inner" == *'"I2":"<b 0xf1>"'* ]]
    [[ "$inner" == *'"I5":"<t>"'* ]]
    [[ "$inner" == *'I2 = <b 0xf1>'* ]]
}

@test "RU and EN runtimes keep all I2-I5 integration points" {
    local file
    for file in awg_common.sh awg_common_en.sh; do
        grep -qE 'I2\)[[:space:]]+_I2=' "$BATS_TEST_DIRNAME/../$file"
        grep -qF '$i1,$i2,$i3,$i4,$i5' "$BATS_TEST_DIRNAME/../$file"
        grep -qF 'echo "I5 = ${AWG_I5}"' "$BATS_TEST_DIRNAME/../$file"
    done
}

@test "RU and EN installers whitelist and persist I2-I5" {
    local file
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qF 'AWG_I2|AWG_I3|AWG_I4|AWG_I5' "$BATS_TEST_DIRNAME/../$file"
        grep -qF "export AWG_I2='" "$BATS_TEST_DIRNAME/../$file"
        grep -qF "export AWG_I5='" "$BATS_TEST_DIRNAME/../$file"
    done
}
