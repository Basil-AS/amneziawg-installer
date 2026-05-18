#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "RU installer must not hard-code the legacy default port"
    fi
}

@test "EN installer uses randomized default AWG port" {
    grep -q 'generate_random_awg_port()' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'default_port=$(generate_random_awg_port)' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    if grep -q 'local default_port=39743' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; then
        fail "EN installer must not hard-code the legacy default port"
    fi
}

@test "installer prefers local helper scripts and does not default to raw main" {
    grep -q 'AWG_REPO="${AWG_REPO:-Basil-AS/amneziawg-installer}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'AWG_BRANCH="${AWG_BRANCH:-v${SCRIPT_VERSION}}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'raw.githubusercontent.com/${AWG_REPO}/${AWG_BRANCH}/awg_common.sh' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF '_deploy_helper_script "awg_common.sh" "${INSTALLER_DIR}/awg_common.sh"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'AWG_ALLOW_UNVERIFIED_DOWNLOAD=1' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    if grep -qF 'AWG_BRANCH="${AWG_BRANCH:-main}"' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; then
        fail "installer must not silently default raw downloads to main"
    fi
}

@test "README quickstart uses fork raw GitHub main, not upstream release tag" {
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"
    grep -q 'raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg_en.sh' "$BATS_TEST_DIRNAME/../README.en.md"
    if grep -q 'raw.githubusercontent.com/bivlked/amneziawg-installer/v5.13.0/install_amneziawg.sh' "$BATS_TEST_DIRNAME/../README.md"; then
        fail "README quickstart must not point at upstream release installer"
    fi
}
