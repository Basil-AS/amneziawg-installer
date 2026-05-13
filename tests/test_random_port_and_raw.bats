#!/usr/bin/env bats

@test "installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    ! grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "EN installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    ! grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "installer downloads fork helper scripts from raw GitHub main by default" {
    grep -q 'AWG_REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'AWG_BRANCH="${AWG_BRANCH:-main}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'raw.githubusercontent.com/${AWG_REPO}/${AWG_BRANCH}/awg_common.sh' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "README quickstart uses fork raw GitHub main, not upstream release tag" {
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg_en.sh' "$BATS_TEST_DIRNAME/../README.en.md"
    ! grep -q 'raw.githubusercontent.com/bivlked/amneziawg-installer/v5.13.0/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"
}
