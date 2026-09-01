# Feature audit: upstream, WireSock and awg-easy-3

This is the current evidence-based integration map for the fork. The target
repository is `Basil-AS/amneziawg-installer`; the clean reference clone is not
part of the worktree.

## Upstream

At the sync point, `upstream/main` was `c9ce1c7` and the fork had a common
ancestor at that commit. `git rev-list --left-right --count origin/main...upstream/main`
reports `383 0`: all upstream history is connected, while the fork retains its
documented product delta.

The five upstream commits immediately preceding the sync were reviewed in
`docs/UPSTREAM_AUDIT.md`. Build identity diagnostics, stale-reference cleanup,
and the marker scanner were ported. The dated facts generator was intentionally
not ported because it asserts AWG 2.0 and kernel-version semantics that are
false for this AWG 3.1-first fork.

## Fork delta retained

| Area | Current evidence | Decision |
|---|---|---|
| AWG protocol matrix | `install_amneziawg*.sh`, `awg_common*.sh`, `scripts/awg_profile.py` | Keep 1.5/2.0/3.0/3.1; 3.1 is the new-install default; old missing-version state remains 2.0-compatible. |
| 3.1 capability | `scripts/probe-awg31.sh` | Keep capability probe with temporary interface, `setconf`, and `WG_HIDE_KEYS=never awg show` read-back; no kernel gate. |
| Generator profiles | `scripts/awg_profile.py`, `tests/test_awg_profile.bats` | Keep balanced/mobile/stealth/compatibility profiles, non-overlapping H ranges and S-size validation. |
| Runtime surfaces | `web/`, AdGuard, IPv6, P2P/DNAT, Telegram, domain-first endpoint | Preserve; no upstream replacement is allowed to erase them. |
| Security | `HeaderProtectionKey` profile and summary paths | Keep mode 0600 and no logging/argument leakage. |

## WireSock audit

The audited WireSock tree was `b715087` (2026-08-20). Its material feature is
`amneziawg-proxy`, not another AWG parameter preset:

- async Rust UDP relay in `amneziawg-proxy/src/`;
- protocol detection and probe responses for QUIC, DNS, STUN and SIP;
- per-session forwarding and AWG S1-S4 padding transformation;
- global and per-source probe rate limiting;
- optional stateful QUIC TLS response and DNS forwarding;
- systemd installer with AWG loopback rebinding and backup/reconfigure logic.

The component is now vendored under `amneziawg-proxy/`, with the standalone
entry point `amneziawg-proxy.sh`. It is deliberately opt-in: normal AWG
installations keep their public UDP topology and do not require Rust. The
standalone bootstrap points to this fork, not to an unpinned upstream clone.

## awg-easy-3 audit

The audited tree was `5a64b8b` (v0.1.3, 2026-08-31). Useful concepts confirmed
against this fork are:

- canonical AWG 3.x field ordering and validation;
- preservation of all AWG 3.x fields through `vpn://` payloads;
- explicit independent IPv4/IPv6 client permissions;
- diagnostics that distinguish recent handshake evidence from an active
  connection and avoid invented traffic rates;
- persistent client state and safe migration behavior.

The first two and diagnostics are already represented by the fork's typed
`vpn://` renderer, AWG profile validator and Web Panel tests. The independent
per-client IP-family permission model is not silently copied: implementing it
requires a separate firewall/state-machine design so it cannot weaken the
fork's existing IPv6 leak-block, P2P/DNAT or client-isolation guarantees.

## Release policy

The next release for the proxy integration is `5.29.0-bas.3`, retaining the
upstream base number and incrementing only the fork suffix. All changes must
land through a pull request with the repository's required attribution policy
and a green full test suite.
