#!/usr/bin/env bats
# Tests for GeoIP MMDB auto-update wiring:
#   - awg_common.sh / awg_common_en.sh helpers: geoip_update_dbs,
#     geoip_auto_update_install_units, geoip_auto_update_enable/disable/status
#   - manage_amneziawg.sh / _en.sh "geoip ..." subcommand dispatch
#   - install_amneziawg.sh / _en.sh --enable-geoip-auto-update flag and
#     scripts/update_geoip_dbs.py deployment/SHA manifest entry
# shellcheck disable=SC2016,SC2030,SC2031,SC2329

bats_require_minimum_version 1.5.0

load test_helper

# -------------------------------------------------------------------------
# awg_common.sh helpers
# -------------------------------------------------------------------------

@test "geoip_update_dbs: dies if the updater script is missing" {
    GEOIP_UPDATE_SCRIPT="$TEST_DIR/no-such-script.py"
    run geoip_update_dbs
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* || "$output" == *"не найден"* ]] || true
}

@test "geoip_update_dbs: invokes python3 on the configured updater script" {
    cat > "$TEST_DIR/fake_update_geoip_dbs.py" << 'EOF'
import sys
print("ok:" + " ".join(sys.argv[1:]))
EOF
    GEOIP_UPDATE_SCRIPT="$TEST_DIR/fake_update_geoip_dbs.py"
    run geoip_update_dbs
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
    [[ "$output" == *"--awg-dir"* ]]
    [[ "$output" == *"$AWG_DIR"* ]]
}

@test "geoip_auto_update_install_units: writes service+timer units with correct ExecStart and schedule" {
    cat > "$TEST_DIR/fake_update_geoip_dbs.py" << 'EOF'
print("noop")
EOF
    GEOIP_UPDATE_SCRIPT="$TEST_DIR/fake_update_geoip_dbs.py"
    GEOIP_SERVICE_UNIT_FILE="$TEST_DIR/awg-geoip-update.service"
    GEOIP_TIMER_UNIT_FILE="$TEST_DIR/awg-geoip-update.timer"
    systemctl() { :; }  # stub: avoid touching the real systemd
    export -f systemctl

    run geoip_auto_update_install_units
    [ "$status" -eq 0 ]

    [ -f "$GEOIP_SERVICE_UNIT_FILE" ]
    [ -f "$GEOIP_TIMER_UNIT_FILE" ]
    grep -qF "ExecStart=/usr/bin/python3 $TEST_DIR/fake_update_geoip_dbs.py --awg-dir $AWG_DIR" "$GEOIP_SERVICE_UNIT_FILE"
    grep -qF "Type=oneshot" "$GEOIP_SERVICE_UNIT_FILE"
    grep -qF "OnCalendar=weekly" "$GEOIP_TIMER_UNIT_FILE"
    grep -qF "Persistent=true" "$GEOIP_TIMER_UNIT_FILE"
    grep -qF "WantedBy=timers.target" "$GEOIP_TIMER_UNIT_FILE"
}

@test "geoip_auto_update_enable/disable/status: drive systemctl enable/disable/is-enabled for the timer" {
    cat > "$TEST_DIR/fake_update_geoip_dbs.py" << 'EOF'
print("noop")
EOF
    export GEOIP_UPDATE_SCRIPT="$TEST_DIR/fake_update_geoip_dbs.py"
    GEOIP_SERVICE_UNIT_FILE="$TEST_DIR/awg-geoip-update.service"
    GEOIP_TIMER_UNIT_FILE="$TEST_DIR/awg-geoip-update.timer"
    SYSTEMCTL_LOG="$TEST_DIR/systemctl.log"
    systemctl() { printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"; [[ "$1" == "is-enabled" || "$1" == "is-active" ]] && echo "enabled"; return 0; }
    export -f systemctl

    run geoip_auto_update_enable
    [ "$status" -eq 0 ]
    grep -qF "enable --now awg-geoip-update.timer" "$SYSTEMCTL_LOG"

    run geoip_auto_update_disable
    [ "$status" -eq 0 ]
    grep -qF "disable --now awg-geoip-update.timer" "$SYSTEMCTL_LOG"

    run geoip_auto_update_status
    [ "$status" -eq 0 ]
    grep -qF "is-enabled awg-geoip-update.timer" "$SYSTEMCTL_LOG"
    grep -qF "is-active awg-geoip-update.timer" "$SYSTEMCTL_LOG"
}

# -------------------------------------------------------------------------
# manage_amneziawg.sh "geoip ..." subcommand wiring (RU + EN)
# -------------------------------------------------------------------------

@test "manage_amneziawg.sh (RU+EN) define a 'geoip' subcommand with update-dbs and auto-update actions" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        local script="$BATS_TEST_DIRNAME/../$f"
        grep -qE '^\s*geoip\)' "$script"
        grep -qF 'geoip_update_dbs' "$script"
        grep -qF 'geoip_auto_update_enable' "$script"
        grep -qF 'geoip_auto_update_disable' "$script"
        grep -qF 'geoip_auto_update_status' "$script"
        grep -qE '^\s*auto-update\)' "$script"
    done
}

# -------------------------------------------------------------------------
# install_amneziawg.sh / _en.sh: flag, deployment, SHA manifest
# -------------------------------------------------------------------------

@test "install_amneziawg.sh (RU+EN): --enable-geoip-auto-update flag is parsed and wired to geoip_auto_update_enable" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local script="$BATS_TEST_DIRNAME/../$f"
        grep -qF 'CLI_ENABLE_GEOIP_AUTO_UPDATE=0' "$script"
        grep -qE -- '--enable-geoip-auto-update\) CLI_ENABLE_GEOIP_AUTO_UPDATE=1' "$script"
        grep -qF '"$CLI_ENABLE_GEOIP_AUTO_UPDATE" -eq 1' "$script"
        grep -qF 'geoip_auto_update_enable' "$script"
    done
}

@test "install_amneziawg.sh (RU+EN): scripts/update_geoip_dbs.py is deployed and present in the SHA256 manifest" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local script="$BATS_TEST_DIRNAME/../$f"
        grep -qE '\["scripts/update_geoip_dbs\.py"\]="[0-9a-fA-F]{64}"' "$script"
        grep -qF '_deploy_asset "scripts/update_geoip_dbs.py"' "$script"
    done
}

@test "scripts/update-installer-sha-manifest.sh includes scripts/update_geoip_dbs.py" {
    grep -qF 'scripts/update_geoip_dbs.py' "$BATS_TEST_DIRNAME/../scripts/update-installer-sha-manifest.sh"
}
