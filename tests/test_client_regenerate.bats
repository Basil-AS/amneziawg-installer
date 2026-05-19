#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

load test_helper

mock_awg_rotating() {
    echo 0 > "$TEST_DIR/key_counter"
    # shellcheck disable=SC2317
    awg() {
        case "$1" in
            genkey)
                local n
                n=$(cat "$TEST_DIR/key_counter")
                n=$((n + 1))
                echo "$n" > "$TEST_DIR/key_counter"
                echo "ROTATED_PRIVATE_KEY_${n}=="
                ;;
            pubkey)
                local pk
                pk=$(cat)
                echo "pub_${pk}"
                ;;
            genpsk) echo "ROTATED_PSK_VALUE_32B==" ;;
            set|syncconf|show) return 0 ;;
            *) return 0 ;;
        esac
    }
    export -f awg
}

seed_regen_client() {
    create_server_config
    create_init_config
    export AWG_SKIP_APPLY=1
    mkdir -p "$KEYS_DIR" "$AWG_DIR/web"
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
    echo "SERVER_PUB" > "$AWG_DIR/server_public.key"
    echo "OLD_PRIVATE_KEY==" > "$KEYS_DIR/phone.private"
    echo "OLD_PUBLIC_KEY==" > "$KEYS_DIR/phone.public"
    cat >> "$SERVER_CONF_FILE" <<'CONF'

[Peer]
#_Name = phone
PublicKey = OLD_PUBLIC_KEY==
PresharedKey = OLD_PSK_VALUE_32B==
#_P2PPorts_Disabled = 20000,20001
AllowedIPs = 10.9.9.5/32
CONF
    cat > "$AWG_DIR/phone.conf" <<'CONF'
[Interface]
PrivateKey = OLD_PRIVATE_KEY==
Address = 10.9.9.5/32
DNS = 10.9.9.1
MTU = 1280
I1 = <r 128>

[Peer]
PublicKey = SERVER_PUB
PresharedKey = OLD_PSK_VALUE_32B==
Endpoint = 203.0.113.1:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
    cat > "$AWG_DIR/web/traffic_history.json" <<'JSON'
{"last":{"phone":{"rx":10,"tx":5}},"days":{"2026-05-19":{"phone":{"rx":10,"tx":5}}},"totals":{"phone":{"rx":10,"tx":5}}}
JSON
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; }
    export -f get_server_public_ip
}

@test "manage help contains regenerate client command aliases" {
    local ru="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    local en="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    grep -qF 'regen <имя>' "$ru"
    grep -qF 'regenerate <имя>' "$ru"
    grep -qF 'client regenerate <имя>' "$ru"
    grep -qF 'regen <name>' "$en"
    grep -qF 'regenerate <name>' "$en"
    grep -qF 'client regenerate <name>' "$en"
}

@test "regenerate_client rejects missing client and invalid I1 override" {
    require_flock
    mock_awg_rotating
    create_server_config
    create_init_config
    export AWG_SKIP_APPLY=1

    run regenerate_client "missing"
    [ "$status" -ne 0 ]

    seed_regen_client
    export AWG_I1_OVERRIDE='<b 0xabc>;id'
    run regenerate_client "phone"
    [ "$status" -ne 0 ]
}

@test "regenerate_client rotates keys and PSK while preserving address metadata and history" {
    require_flock
    mock_awg_rotating
    seed_regen_client
    local before_history
    before_history=$(cat "$AWG_DIR/web/traffic_history.json")

    run regenerate_client "phone"
    [ "$status" -eq 0 ]
    grep -q '^PrivateKey = ROTATED_PRIVATE_KEY_1==$' "$AWG_DIR/phone.conf"
    grep -q '^PublicKey = pub_ROTATED_PRIVATE_KEY_1==$' "$SERVER_CONF_FILE"
    grep -q '^PresharedKey = ROTATED_PSK_VALUE_32B==$' "$AWG_DIR/phone.conf"
    grep -q '^PresharedKey = ROTATED_PSK_VALUE_32B==$' "$SERVER_CONF_FILE"
    grep -q '^Address = 10.9.9.5/32$' "$AWG_DIR/phone.conf"
    grep -q '^AllowedIPs = 10.9.9.5/32$' "$SERVER_CONF_FILE"
    grep -q '^#_P2PPorts_Disabled = 20000,20001$' "$SERVER_CONF_FILE"
    grep -q '^DNS = 10.9.9.1$' "$AWG_DIR/phone.conf"
    grep -q '^PersistentKeepalive = 33$' "$AWG_DIR/phone.conf"
    [ "$(cat "$AWG_DIR/web/traffic_history.json")" = "$before_history" ]
}

@test "regenerate_client accepts AWG_I1_OVERRIDE via env and works without override" {
    require_flock
    mock_awg_rotating
    seed_regen_client
    export AWG_I1_OVERRIDE='<b 0xabcdef><r 0 1>'
    run regenerate_client "phone"
    [ "$status" -eq 0 ]
    grep -qF 'I1 = <b 0xabcdef><r 0 1>' "$AWG_DIR/phone.conf"

    unset AWG_I1_OVERRIDE
    run regenerate_client "phone"
    [ "$status" -eq 0 ]
}

@test "regenerate_client has rollback path on apply failure" {
    local common="$BATS_TEST_DIRNAME/../awg_common.sh"
    awk '/^regenerate_client\(\) \{/,/^}/' "$common" | grep -qF 'restore_regenerate_backup'
    awk '/^regenerate_client\(\) \{/,/^}/' "$common" | grep -qF 'apply_config упал'
}
