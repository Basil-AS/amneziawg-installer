#!/usr/bin/env bats
# optimize_swap: the /etc/fstab append must not glue its entry onto the
# previous line.
#
# Until this guard existed, optimize_swap did a bare
# `echo '/swapfile none swap sw 0 0' >> /etc/fstab`. If the file did not end
# with a newline (some hoster images ship it that way), the entry was
# concatenated onto the last existing record, producing a single line of 11
# whitespace-separated fields instead of six. A malformed fstab line is the
# worst class of failure this installer can cause: the damage only surfaces on
# the next boot, after the connection is already gone.
#
# The functional tests below deliberately do NOT reimplement the logic. They
# lift the real block out of the shipped installer, retarget /etc/fstab to a
# scratch file and run it. A copy of the logic living in the test would keep
# passing after the guard was removed from the installer, which is exactly the
# failure mode a regression test exists to prevent.

# Pull the body of the "entry missing -> append it" branch out of an installer.
extract_fstab_append() {
    sed -n "/\/etc\/fstab; then\$/,/'\/swapfile none swap sw 0 0' >> \/etc\/fstab/p" "$1" \
        | sed '1d'
}

# Run that block against a scratch fstab instead of the real one.
run_shipped_append() {
    local script="$1" target="$2" block
    block=$(extract_fstab_append "$script")
    [ -n "$block" ] || return 1
    eval "${block//\/etc\/fstab/$target}"
}

RU_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; }
EN_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; }

fields_in_last_data_line() {
    awk 'NF { last = NF } END { print last+0 }' "$1"
}

# ===========================================================================
# static: both installers carry the guard
# ===========================================================================

@test "fstab guard: RU install checks the last byte before appending" {
    grep -q 'if \[\[ -s /etc/fstab && -n "\$(tail -c1 /etc/fstab)" \]\]; then' \
        "$(RU_INSTALL)"
}

@test "fstab guard: EN install checks the last byte before appending" {
    grep -q 'if \[\[ -s /etc/fstab && -n "\$(tail -c1 /etc/fstab)" \]\]; then' \
        "$(EN_INSTALL)"
}

@test "fstab guard: the append branch is extractable from both installers" {
    [ -n "$(extract_fstab_append "$(RU_INSTALL)")" ]
    [ -n "$(extract_fstab_append "$(EN_INSTALL)")" ]
}

# ===========================================================================
# functional: the shipped block, executed against scratch files
# ===========================================================================

@test "fstab guard: RU, fstab WITHOUT trailing newline keeps its last record intact" {
    tmp=$(mktemp)
    printf 'LABEL=cloudimg-rootfs / ext4 defaults 0 1\nLABEL=UEFI /boot/efi vfat umask=0077 0 1' > "$tmp"
    run_shipped_append "$(RU_INSTALL)" "$tmp"

    # The regression produced one 11-field line; a correct append leaves six.
    [ "$(fields_in_last_data_line "$tmp")" -eq 6 ]
    # The UEFI record must survive untouched on its own line.
    grep -qx 'LABEL=UEFI /boot/efi vfat umask=0077 0 1' "$tmp"
    grep -qx '/swapfile none swap sw 0 0' "$tmp"
    [ "$(grep -c . "$tmp")" -eq 3 ]
    rm -f "$tmp"
}

@test "fstab guard: EN, fstab WITHOUT trailing newline keeps its last record intact" {
    tmp=$(mktemp)
    printf 'LABEL=cloudimg-rootfs / ext4 defaults 0 1\nLABEL=UEFI /boot/efi vfat umask=0077 0 1' > "$tmp"
    run_shipped_append "$(EN_INSTALL)" "$tmp"

    [ "$(fields_in_last_data_line "$tmp")" -eq 6 ]
    grep -qx 'LABEL=UEFI /boot/efi vfat umask=0077 0 1' "$tmp"
    [ "$(grep -c . "$tmp")" -eq 3 ]
    rm -f "$tmp"
}

@test "fstab guard: fstab WITH trailing newline gains no blank line" {
    tmp=$(mktemp)
    printf 'LABEL=cloudimg-rootfs / ext4 defaults 0 1\nLABEL=UEFI /boot/efi vfat umask=0077 0 1\n' > "$tmp"
    run_shipped_append "$(RU_INSTALL)" "$tmp"

    [ "$(wc -l < "$tmp")" -eq 3 ]
    run grep -c '^$' "$tmp"
    [ "$output" -eq 0 ]
    rm -f "$tmp"
}

@test "fstab guard: empty fstab yields exactly one record" {
    tmp=$(mktemp)
    : > "$tmp"
    run_shipped_append "$(RU_INSTALL)" "$tmp"

    [ "$(grep -c . "$tmp")" -eq 1 ]
    grep -qx '/swapfile none swap sw 0 0' "$tmp"
    rm -f "$tmp"
}

@test "fstab guard: a last line ending in whitespace is still separated" {
    tmp=$(mktemp)
    printf 'LABEL=UEFI /boot/efi vfat umask=0077 0 1 ' > "$tmp"
    run_shipped_append "$(RU_INSTALL)" "$tmp"

    [ "$(fields_in_last_data_line "$tmp")" -eq 6 ]
    grep -qx '/swapfile none swap sw 0 0' "$tmp"
    rm -f "$tmp"
}

@test "fstab guard: the field-match detector still sees the entry afterwards" {
    tmp=$(mktemp)
    printf 'LABEL=UEFI /boot/efi vfat umask=0077 0 1' > "$tmp"
    run_shipped_append "$(RU_INSTALL)" "$tmp"

    # Same awk check optimize_swap uses to decide whether to append at all:
    # on a second run it must find the entry and skip.
    awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' "$tmp"
    rm -f "$tmp"
}
