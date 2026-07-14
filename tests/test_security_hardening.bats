#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "systemd unit helpers exist in RU and EN installers" {
    for installer in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF 'validate_no_control_chars()' "$installer"
        grep -qF 'systemd_escape_value()' "$installer"
        grep -qF 'systemd_env_line()' "$installer"
        grep -qF 'validate_safe_abs_path()' "$installer"
        grep -qF 'systemd_abs_path_value()' "$installer"
        grep -qF 'Environment="%s=%s"\n' "$installer"
        grep -qF 'validate_safe_abs_path "$AWG_DIR"' "$installer"
        grep -qF 'validate_safe_abs_path "$SERVER_CONF_FILE"' "$installer"
        grep -qF 'validate_safe_abs_path "$web_dir/server.py"' "$installer"
        grep -qF 'WorkingDirectory=${ag_dir_unit}' "$installer"
        grep -qF 'ExecStart=${ag_bin_unit} -c ${ag_conf_unit} -w ${ag_dir_unit} --no-check-update' "$installer"
        grep -qF 'ExecStart=/usr/bin/python3 ${web_server_unit}' "$installer"
        grep -qF 'systemd_env_line AWG_DIR "$AWG_DIR"' "$installer"
        local quoted_workdir='WorkingDirectory='
        quoted_workdir+='"'
        local quoted_exec='ExecStart='
        quoted_exec+='"'
        if grep -qF "$quoted_workdir" "$installer"; then
            fail "quoted WorkingDirectory returned in $installer"
        fi
        if grep -qF "$quoted_exec" "$installer"; then
            fail "quoted ExecStart returned in $installer"
        fi
        local quoted_ag='"'
        quoted_ag+='/opt/AdGuardHome'
        quoted_ag+='"'
        if grep -qF "$quoted_ag" "$installer"; then
            fail "quoted AdGuardHome path returned in $installer"
        fi
        if grep -qF 'Environment=AWG_DIR=${AWG_DIR}' "$installer"; then
            fail "raw unquoted awg-web Environment line returned in $installer"
        fi
    done
}

@test "systemd validators reject control chars and relative paths" {
    eval "$(awk '/^validate_no_control_chars\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(awk '/^validate_safe_abs_path\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(awk '/^systemd_abs_path_value\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"

    validate_no_control_chars "plain-value"
    run validate_no_control_chars $'bad\nvalue'
    [ "$status" -ne 0 ]
    run validate_no_control_chars $'bad\tvalue'
    [ "$status" -ne 0 ]
    local safe_path=/root/awg/web/server.py
    validate_safe_abs_path "$safe_path"
    run validate_safe_abs_path "relative/path"
    [ "$status" -ne 0 ]
    run systemd_abs_path_value "$safe_path"
    [ "$status" -eq 0 ]
    [ "$output" = "$safe_path" ]
    run systemd_abs_path_value "/root/awg/web/server with space.py"
    [ "$status" -ne 0 ]
    run systemd_abs_path_value '/root/awg/web/"server.py"'
    [ "$status" -ne 0 ]
    run systemd_abs_path_value "/root/awg/web/'server.py'"
    [ "$status" -ne 0 ]
    run systemd_abs_path_value $'/root/awg/web/bad\nserver.py'
    [ "$status" -ne 0 ]
}

@test "install log never receives raw generated Web or AdGuard secrets" {
    for installer in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF 'print_secret_console_only()' "$installer"
        grep -qF 'raw value printed to console and INSTALL_SUMMARY only' "$installer"
        if grep -Eq 'log .*AWG_WEB_SUPER_TOKEN|log .*AG_PASSWORD' "$installer"; then
            fail "raw secret variable is still logged in $installer"
        fi
    done
}

@test "public Web Panel warning mentions reverse proxy, VPN-only and SSH tunnel" {
    grep -qF 'reverse proxy' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'VPN-only bind on the VPN gateway' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'SSH tunnel' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qF 'reverse proxy' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'VPN-only bind на шлюзе VPN' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'SSH tunnel' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "docs include reverse proxy timeout guidance and explicit PPA fallback" {
    for doc in README.md README.en.md ADVANCED.md ADVANCED.en.md; do
        grep -qF 'client_header_timeout' "$BATS_TEST_DIRNAME/../$doc"
        grep -qF 'AWG_ALLOW_PPA_CODENAME_FALLBACK=1' "$BATS_TEST_DIRNAME/../$doc"
        grep -qF -- '--allow-ppa-codename-fallback' "$BATS_TEST_DIRNAME/../$doc"
    done
}

@test "server and I1 validators reject sed/config injection payloads" {
    command -v python3 &>/dev/null || skip "python3 not available"
    AWG_DIR="$(mktemp -d)" SERVER_CONF_FILE="/tmp/awg0.conf" REPO_ROOT="$BATS_TEST_DIRNAME/.." python3 - <<'PY'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("panel_server", Path(os.environ["REPO_ROOT"]) / "web" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

bad_names = ["bad/name", "bad|name", "bad&name", "bad;name", "bad`name`", "bad$(id)", "bad\nname", "bad\rname"]
for value in bad_names:
    try:
        server.require_server_name(value)
    except ValueError:
        pass
    else:
        raise AssertionError(value)

bad_i1 = ["foo/bar/e", "x&y", "x\\y", "x|y", "x$(id)"]
for value in bad_i1:
    try:
        server.validate_i1(value)
    except ValueError:
        pass
    else:
        raise AssertionError(value)
PY
}

@test "manage set-name validators reject shell and sed metacharacters" {
    for manage in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        eval "$(awk '/^validate_server_name\(\)/,/^}/' "$manage")"
        validate_server_name "Office VPN"
        for value in 'bad/name' 'bad|name' 'bad&name' 'bad;name' 'bad`name`' 'bad$(id)' $'bad\nname' $'bad\rname'; do
            run validate_server_name "$value"
            [ "$status" -ne 0 ]
        done
    done
}
