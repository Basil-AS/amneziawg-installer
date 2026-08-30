#!/usr/bin/env bats

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    SCRIPT="$ROOT/scripts/gen_vpn_uri.py"
    TMPDIR_TEST="$(mktemp -d)"
    CONF="$TMPDIR_TEST/client.conf"
    cat >"$CONF" <<'EOF'
[Interface]
PrivateKey = ignored-by-renderer
Address = 10.0.0.2/32, fd00::2/128
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280
PersistentKeepalive = 33
ContentPaddingAddition = 12
HeaderProtectionKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MaxHandshakeAttempts = 10
KeepaliveTimeout = 10
RejectAfterTime = 180
RekeyAfterTime = 3600
RekeyTimeout = 10
RandomTrailers = 1
DisableCookies = false
[Peer]
PresharedKey = client-psk
Endpoint = [2001:db8::1]:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

@test "Python vpn URI renderer preserves IPv6, PSK, and AWG 3.1 fields" {
    run env \
        AWG_PORT=51820 AWG_PROTOCOL_VERSION=3.1 AWG_SERVER_NAME="Mobile test" \
        AWG_URI_CPK=client-private AWG_URI_SPK=server-public \
        AWG_H1=1 AWG_H2=2 AWG_H3=3 AWG_H4=4 AWG_Jc=4 AWG_Jmin=10 AWG_Jmax=50 \
        AWG_S1=12 AWG_S2=13 AWG_S3=14 AWG_S4=12 \
        python3 "$SCRIPT" --conf "$CONF"
    [ "$status" -eq 0 ]
    [ "${output:0:6}" = "vpn://" ]
    run python3 - "$output" <<'PY'
import base64, json, struct, sys, zlib
payload = sys.argv[1][6:]
payload += "=" * (-len(payload) % 4)
raw = base64.urlsafe_b64decode(payload)
size = struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
assert size == len(zlib.decompress(raw[4:]))
assert outer["hostName"] == "2001:db8::1"
inner = json.loads(outer["containers"][0]["awg"]["last_config"])
assert inner["client_ipv6"] == "fd00::2"
assert inner["psk_key"] == "client-psk"
assert inner["HeaderProtectionKey"] == "a" * 64
assert inner["allowed_ips"] == ["0.0.0.0/0", "::/0"]
assert outer["containers"][0]["awg"]["protocol_version"] == "3.1"
PY
    [ "$status" -eq 0 ]
}

@test "Python vpn URI renderer fails closed when an AWG 3.1 field is missing" {
    sed -i '/DisableCookies/d' "$CONF"
    run env \
        AWG_PORT=51820 AWG_PROTOCOL_VERSION=3.1 AWG_URI_CPK=client-private AWG_URI_SPK=server-public \
        AWG_H1=1 AWG_H2=2 AWG_H3=3 AWG_H4=4 AWG_Jc=4 AWG_Jmin=10 AWG_Jmax=50 \
        AWG_S1=12 AWG_S2=13 AWG_S3=14 AWG_S4=12 \
        python3 "$SCRIPT" --conf "$CONF"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing AWG 3.1 field DisableCookies"* ]]
}
