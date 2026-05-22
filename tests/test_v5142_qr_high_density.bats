#!/usr/bin/env bats
# Tests for high-density vpn:// QR generation flags.

load test_helper

mock_qrencode_capture() {
    local bin="$TEST_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/qrencode" <<SHIM
#!/bin/bash
printf '%s\n' "\$@" > "$TEST_DIR/qrencode-args"
out=""
while (( \$# > 0 )); do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -t|-l|-s|-m) shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "\$out" ]] || exit 2
cat > "\$out"
SHIM
    chmod +x "$bin/qrencode"
    export PATH="$bin:$PATH"
}

@test "generate_qr_vpnuri passes low EC, larger module size, and quiet zone" {
    mock_qrencode_capture
    echo "vpn://LONG_PAYLOAD" > "$AWG_DIR/c1.vpnuri"

    run generate_qr_vpnuri "c1"
    [ "$status" -eq 0 ]
    awk '/^-l$/{getline; print}' "$TEST_DIR/qrencode-args" | grep -qx 'L'
    awk '/^-s$/{getline; print}' "$TEST_DIR/qrencode-args" | grep -qx '6'
    awk '/^-m$/{getline; print}' "$TEST_DIR/qrencode-args" | grep -qx '4'
    awk '/^-t$/{getline; print}' "$TEST_DIR/qrencode-args" | grep -qx 'png'
}

@test "generate_qr_vpnuri still writes .vpnuri.png atomically from payload" {
    mock_qrencode_capture
    echo "vpn://REGRESSION_GUARD" > "$AWG_DIR/c2.vpnuri"

    run generate_qr_vpnuri "c2"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/c2.vpnuri.png" ]
    [ "$(cat "$AWG_DIR/c2.vpnuri.png")" = "vpn://REGRESSION_GUARD" ]
}

@test "structural: RU and EN qrencode invocation lines are identical" {
    local ru_line en_line
    ru_line=$(awk '/^generate_qr_vpnuri\(\) \{$/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh" \
        | grep -E 'qrencode .*-t png')
    en_line=$(awk '/^generate_qr_vpnuri\(\) \{$/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" \
        | grep -E 'qrencode .*-t png')
    [ "$ru_line" = "$en_line" ]
    grep -qE 'qrencode .*-l L' <<<"$ru_line"
    grep -qE 'qrencode .*-s 6' <<<"$ru_line"
    grep -qE 'qrencode .*-m 4' <<<"$ru_line"
}
