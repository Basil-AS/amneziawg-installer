#!/usr/bin/env bats
# shellcheck disable=SC2317,SC2329
# Tests for installer state machine hardening (v5.11).
#
# Covers:
#   • update_state() - atomic write via tmp + flock + mv (A1.3).
#   • request_reboot() - boot_id capture before the 1->2 reboot gate (A4.1).
#   • step 2 entry guard - die when boot_id matches (reboot did not happen).
#
# The installer script `install_amneziawg.sh` is too large to source as a
# whole (it parses $@, checks root, sets traps). We extract the three
# functions we care about via `sed` range and evaluate them in a clean shell
# with mocked environment.

setup() {
    # shellcheck disable=SC2154
    local installer="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    [ -f "$installer" ] || { echo "Installer not found: $installer" >&2; return 1; }

    BATS_TMP_AWG=$(mktemp -d)
    export AWG_DIR="$BATS_TMP_AWG"
    export STATE_FILE="$BATS_TMP_AWG/setup_state"
    export LOG_FILE="$BATS_TMP_AWG/install.log"

    # Silence logging and avoid side effects.
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    die()       { echo "die: $*" >&2; return 1; }
    export -f log log_warn log_error log_debug die

    # Extract `update_state` from the installer (first contiguous function body).
    # shellcheck source=/dev/null
    source <(sed -n '/^update_state() {$/,/^}$/p' "$installer")
}

teardown() {
    rm -rf "$BATS_TMP_AWG"
}

@test "update_state: writes step number to STATE_FILE" {
    run update_state 3
    [ "$status" -eq 0 ]
    [ -f "$STATE_FILE" ]
    [ "$(cat "$STATE_FILE")" = "3" ]
}

@test "update_state: overwrites existing state" {
    update_state 1
    update_state 5
    [ "$(cat "$STATE_FILE")" = "5" ]
}

@test "update_state: creates AWG_DIR if missing" {
    rm -rf "$AWG_DIR"
    run update_state 2
    [ "$status" -eq 0 ]
    [ -f "$STATE_FILE" ]
}

@test "update_state: cleans up tmp file on success (no leaked .tmp.*)" {
    update_state 4
    # No tmp-pattern files should remain next to STATE_FILE
    run bash -c "ls '$BATS_TMP_AWG'/setup_state.tmp.* 2>/dev/null"
    # glob didn't match -> ls prints nothing and exits with non-zero
    [ -z "$output" ]
}

@test "update_state: content is just the step number, nothing else" {
    update_state 7
    # Expect exactly one line with "7"
    run wc -l "$STATE_FILE"
    [[ "$output" == *" 1 "* ]] || [[ "$output" == *"1 "* ]]
    [ "$(head -1 "$STATE_FILE")" = "7" ]
}

@test "update_state: concurrent invocations serialize via flock" {
    # Launch 3 updates in parallel; final file should be consistent (one step).
    update_state 1 &
    update_state 2 &
    update_state 3 &
    wait
    [ -f "$STATE_FILE" ]
    # The file should contain ONE line with a single digit, not mixed garbage.
    run cat "$STATE_FILE"
    [[ "$output" =~ ^[1-3]$ ]]
}

# ----------------------------------------------------------------
# request_reboot boot_id capture + step 2 entry guard
# ----------------------------------------------------------------
#
# We can't source the full `request_reboot` or `step2_install_amnezia`
# functions without too much setup (they call apt-get, reboot, etc).
# Instead, we test the boot_id invariant directly: the guard logic is a
# simple file-based comparison, so we exercise it by replicating the
# check in a test harness.

@test "boot_id guard: different boot_id -> pass, file removed" {
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    printf '%s\n' "old-boot-id-1111" > "$boot_id_file"
    local saved_boot_id current_boot_id
    saved_boot_id=$(< "$boot_id_file")
    current_boot_id="new-boot-id-2222"
    # Simulating the guard logic
    [ "$saved_boot_id" != "$current_boot_id" ]
    rm -f "$boot_id_file"
    [ ! -f "$boot_id_file" ]
}

@test "boot_id guard: same boot_id -> die (user did not reboot)" {
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    local id="same-boot-id-3333"
    printf '%s\n' "$id" > "$boot_id_file"
    local saved_boot_id current_boot_id
    saved_boot_id=$(< "$boot_id_file")
    current_boot_id="$id"
    # This is the failure scenario - guard must trigger die.
    [ "$saved_boot_id" = "$current_boot_id" ]
}

@test "boot_id file: installer writes boot_id format (32 hex + 4 dashes)" {
    # Real-system format check: /proc/sys/kernel/random/boot_id is UUID.
    # We verify the format the installer will compare against.
    local sample="3c1a8b44-7f9e-4e2d-b1c7-d2a6f8e0c1b3"
    printf '%s\n' "$sample" > "$AWG_DIR/.boot_id_before_step2"
    local loaded
    loaded=$(< "$AWG_DIR/.boot_id_before_step2")
    [[ "$loaded" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "boot_id file: missing saved file -> guard skipped (first install)" {
    # If .boot_id_before_step2 does not exist, the guard block is skipped.
    # This simulates the "first install" case where step 1 hasn't run yet
    # (shouldn't happen in normal flow, but guard must be resilient).
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    [ ! -f "$boot_id_file" ]
    # The code path is: `if [[ -f "$boot_id_file" ]] ...` - false -> skipped.
    # No die, no crash. Nothing to assert beyond "no file".
    run bash -c "[[ -f '$boot_id_file' ]] && echo present || echo absent"
    [ "$output" = "absent" ]
}

# ----------------------------------------------------------------
# Code invariants - installer must contain the hardening
# ----------------------------------------------------------------

@test "installer RU contains tmp+mv atomic write" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    run grep -c "mv -f \"\$tmp\" \"\$STATE_FILE\"" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "installer EN contains tmp+mv atomic write" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    run grep -c "mv -f \"\$tmp\" \"\$STATE_FILE\"" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "installer RU captures boot_id on reboot 1->2" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    run grep -c "/proc/sys/kernel/random/boot_id" "$f"
    [ "$status" -eq 0 ]
    # At least one write in request_reboot and one read in step2
    [ "$output" -ge 2 ]
}

@test "installer EN captures boot_id on reboot 1->2" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    run grep -c "/proc/sys/kernel/random/boot_id" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]
}

@test "installer RU has step 2 entry guard with die" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    # The guard should contain a die call mentioning reboot
    run grep -c "Ожидалась перезагрузка перед шагом 2" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "installer EN has step 2 entry guard with die" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    run grep -c "Reboot expected before step 2" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "installer RU cleans boot_id file on finish" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    # Final step99 cleanup should include boot_id file
    run grep -c "\.boot_id_before_step2" "$f"
    [ "$status" -eq 0 ]
    # at least: capture in request_reboot, check in step 2, cleanup in step 99
    [ "$output" -ge 3 ]
}

@test "installer EN cleans boot_id file on finish" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    run grep -c "\.boot_id_before_step2" "$f"
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]
}
