# Upstream audit and surgical sync

This document records the comparison of `origin/main` with
`upstream/main` before the fork sync. It is a decision log, not a claim that
the two projects have identical product goals.

The original audit point was `origin/main`=`d6d3234` and
`upstream/main`=`c9ce1c7`: the fork was 373 commits ahead and 5 commits
behind. Those five upstream commits were reviewed individually. A fresh
comparison on 2026-09-01 reports `origin/main...upstream/main = 410 0`; no
upstream commits remain unmerged.

| Upstream commit | Area | Decision | Reason |
|---|---|---|---|
| `35f516c` | Loaded module build identity | Ported | Adds `srcversion` and package version to diagnostics without guessing protocol generation from a module version string. RU and EN paths are retained. |
| `17e91b2` | Stale references in CI and release helpers | Ported | Removes references to files absent from the public tree; no fork behavior is replaced. |
| `356fded` | Facts block guard | Not ported | Depends on the facts-block implementation and its AWG 2.0 assertion. The fork README and generator are explicitly AWG 3.1-first. |
| `fea8e74` | Dated README facts generator | Not ported | Its generated text describes AWG 2.0 configs and a kernel-version model, both false for this fork. The README was deliberately rewritten for the fork and must remain the source of truth. |
| `c9ce1c7` | Shared forbidden-marker scan | Ported and adapted | One scanner now checks commit messages and added lines. The exact project-required Codex attribution is allowed; unrelated co-author trailers remain rejected. <!-- allow-markers --> |

## Version policy

The fork keeps the upstream base version and appends its own suffix. This sync
therefore uses `5.29.0-bas.5`, released as `v5.29.0-bas.5`; the earlier plain
`v5.29.0` release remains the upstream-compatible baseline.

## Current tree comparison

`git diff --name-status upstream/main...origin/main` reports 215 paths:
112 fork-added, 101 fork-modified, and 2 fork-deleted. These are the
documented Web Panel, Telegram, optional WireSock proxy, IPv6/P2P, AWG 3.1
generator/probe, and related tests/docs; they are not unreviewed upstream
drift.

## Preserved fork surfaces

The sync was resolved without replacing the fork's IPv6 modes, P2P/DNAT,
AdGuard Home, web panel, Telegram bot, WireSock hints, domain-first endpoint,
AWG 1.5/2.0/3.0/3.1 selection, capability probe, generator presets, or
mobile-network configuration rules.
