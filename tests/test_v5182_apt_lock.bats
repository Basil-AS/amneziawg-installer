#!/usr/bin/env bats

@test "v5.18.2 apt lock timeout and bounded retry are symmetric" {
    local file
    for file in install_amneziawg.sh install_amneziawg_en.sh; do
        file="$BATS_TEST_DIRNAME/../$file"
        grep -qF 'DPkg::Lock::Timeout "300";' "$file"
        [ "$(grep -c 'apt-get upgrade -y --with-new-pkgs' "$file")" -ge 2 ]
        grep -qF 'fuser /var/lib/dpkg/lock-frontend' "$file"
        grep -qF 'dpkg --configure -a' "$file"
    done
}

@test "v5.18.2 final apt retry remains fatal" {
    grep -qF 'apt-get upgrade -y --with-new-pkgs || _die_upgrade_failed' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'apt-get upgrade -y --with-new-pkgs || _die_upgrade_failed' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}
