#!/usr/bin/env bats
# Tests for generate_awg_h_ranges (#38 fix: H1-H4 randomization per install)

load test_helper

@test "generate_awg_h_ranges: returns 4 lines" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "generate_awg_h_ranges: each line is low-high format" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        [[ "$line" =~ ^[0-9]+-[0-9]+$ ]]
    done
}

@test "generate_awg_h_ranges: each pair has low <= high" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -le "$high" ]
    done
}

@test "generate_awg_h_ranges: each pair width >= 1000" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        local width=$(( high - low ))
        [ "$width" -ge 1000 ]
    done
}

@test "generate_awg_h_ranges: 4 ranges are non-overlapping (sorted ascending)" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    local prev_high=-1
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -gt "$prev_high" ]
        prev_high="$high"
    done
}

@test "generate_awg_h_ranges: all values within [0, 2^31-1] (Windows client compat, #40)" {
    # Upstream amnezia-vpn/amneziawg-windows-client#85: the UI highlighter in
    # ui/syntax/highlighter.go caps H1-H4 at 2_147_483_647 (INT32_MAX) even
    # though the spec allows full uint32. Our installer must stay in the
    # safe half of the range so generated configs open cleanly in the
    # standalone Windows client. Server (amneziawg-go) accepts the full
    # uint32 either way.
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    for line in "${lines[@]}"; do
        local low="${line%-*}"
        local high="${line#*-}"
        [ "$low" -ge 0 ]
        [ "$high" -le 2147483647 ]
    done
}

@test "generate_awg_h_ranges: none of 20 runs exceeds Windows client limit (regression #40)" {
    # Runs the generator 20 times, checks every produced value is
    # compatible with amneziawg-windows-client. 20 runs × 8 values each
    # = 160 samples — a stable signal against accidental regressions in
    # the bit-mask / fallback path.
    local run_i line low high
    for run_i in $(seq 1 20); do
        run generate_awg_h_ranges
        [ "$status" -eq 0 ]
        for line in "${lines[@]}"; do
            low="${line%-*}"
            high="${line#*-}"
            [ "$high" -le 2147483647 ] || {
                echo "Run $run_i produced $line — high > 2147483647"
                return 1
            }
        done
    done
}

@test "generate_awg_h_ranges: two consecutive runs produce different output (randomization)" {
    local out1 out2
    out1=$(generate_awg_h_ranges)
    out2=$(generate_awg_h_ranges)
    [ "$out1" != "$out2" ]
}

@test "generate_awg_h_ranges: not the old hardcoded values" {
    run generate_awg_h_ranges
    [ "$status" -eq 0 ]
    # The old hardcoded values were: 100000-800000, 1000000-8000000, etc.
    # New randomized output should never match this exact pattern.
    [ "${lines[0]}" != "100000-800000" ]
    [ "${lines[1]}" != "1000000-8000000" ]
    [ "${lines[2]}" != "10000000-80000000" ]
    [ "${lines[3]}" != "100000000-800000000" ]
}

@test "AWG 3.1 runtime profile keeps S bounds and padded lengths unique" {
    export AWG_PROTOCOL_VERSION=3.1
    generate_runtime_awg_profile mobile
    [ "$AWG_S1" -ge 12 ] && [ "$AWG_S1" -le 149 ]
    [ "$AWG_S2" -ge 12 ] && [ "$AWG_S2" -le 149 ]
    [ "$AWG_S3" -ge 12 ] && [ "$AWG_S3" -le 63 ]
    [ "$AWG_S4" -eq 12 ]
    [ "$((148 + AWG_S1))" -ne "$((92 + AWG_S2))" ]
    [ "$((148 + AWG_S1))" -ne "$((64 + AWG_S3))" ]
    [ "$((148 + AWG_S1))" -ne "$((32 + AWG_S4))" ]
    [ "$((92 + AWG_S2))" -ne "$((64 + AWG_S3))" ]
    [ "$((92 + AWG_S2))" -ne "$((32 + AWG_S4))" ]
    [ "$((64 + AWG_S3))" -ne "$((32 + AWG_S4))" ]
}

@test "rand_range: uint32 boundary values" {
    run rand_range 0 4294967295
    [ "$status" -eq 0 ]
    [ "$output" -ge 0 ]
    [ "$output" -le 4294967295 ]
}
