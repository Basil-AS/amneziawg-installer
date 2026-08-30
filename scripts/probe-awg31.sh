#!/usr/bin/env bash
# Capability probe for AWG 3.1.  A kernel version is not evidence of support.
set -euo pipefail

command -v ip >/dev/null 2>&1 || exit 1
command -v awg >/dev/null 2>&1 || exit 1

probe_if="awgprobe$$"
tmp_conf="$(mktemp)"
cleanup() {
    rm -f "$tmp_conf"
    ip link delete "$probe_if" >/dev/null 2>&1 || true
}
trap cleanup EXIT
chmod 600 "$tmp_conf"

private_key="$(awg genkey 2>/dev/null)" || exit 1
header_key="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | base64 -w0)" || exit 1
cat >"$tmp_conf" <<EOF
[Interface]
PrivateKey = $private_key
Jc = 4
Jmin = 10
Jmax = 50
S1 = 32
S2 = 48
S3 = 64
S4 = 12
H1 = 1000-1999
H2 = 3000-3999
H3 = 5000-5999
H4 = 7000-7999
HeaderProtectionKey = $header_key
ContentPaddingAddition = 10-100
KeepaliveTimeout = 25-35
RandomTrailers = off
DisableCookies = off
EOF

ip link add "$probe_if" type amneziawg >/dev/null 2>&1 || exit 1
awg setconf "$probe_if" "$tmp_conf" >/dev/null 2>&1 || exit 1

# Read-back is mandatory: accepting setconf alone would produce false positives
# on binaries that silently ignore fields they do not understand.
readback="$(WG_HIDE_KEYS=never awg show "$probe_if" 2>/dev/null)" || exit 1
grep -Eiq 'header[_ ]?protection[_ ]?key|HeaderProtectionKey' <<<"$readback" || exit 1
grep -Eiq 'random[_ ]?trailers|RandomTrailers' <<<"$readback" || exit 1
