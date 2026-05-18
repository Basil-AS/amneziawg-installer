<a id="top"></a>
<p align="center">
  <b>RU</b> <a href="README.md">Русский</a> | <b>EN</b> English
</p>

<p align="center"><em>Fork of the original AmneziaWG installer: upstream-compatible base plus IPv6, P2P ports, and a web panel</em></p>

<p align="center">
  <img src="logo.jpg" alt="AmneziaWG 2.0 VPN Installer — Ubuntu, Debian, Raspberry Pi, ARM64, mobile carrier optimization" width="600">
</p>

<p align="center">
  <strong>A set of Bash scripts for one-command installation, secure hardening,<br>
  and easy management of an AmneziaWG 2.0 VPN server on Ubuntu (24.04 LTS / 25.10 / 26.04) and Debian (12 / 13)</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_|_25.10_|_26.04-orange" alt="Ubuntu 24.04 | 25.10 | 26.04">
  <img src="https://img.shields.io/badge/Debian-12_|_13-A81D33" alt="Debian 12 | 13">
  <img src="https://img.shields.io/badge/Architecture-x86__64_|_ARM64_|_ARMv7-green" alt="x86_64 | ARM64 | ARMv7">
  <a href="https://github.com/bivlked/amneziawg-installer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/bivlked/amneziawg-installer" alt="License"></a>
  <img src="https://img.shields.io/badge/Status-Stable-success" alt="Status">
  <a href="https://github.com/bivlked/amneziawg-installer/releases"><img src="https://img.shields.io/badge/Upstream_Base-5.13.0-blue" alt="Upstream base version"></a>
  <img src="https://img.shields.io/badge/Fork_Delta-IPv6_|_P2P_|_Web-0aa" alt="Fork delta">
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-blueviolet" alt="AWG 2.0">
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml/badge.svg" alt="ShellCheck"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/stargazers"><img src="https://img.shields.io/github/stars/bivlked/amneziawg-installer?style=flat" alt="Stars"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/network/members"><img src="https://img.shields.io/github/forks/bivlked/amneziawg-installer?style=flat" alt="Forks"></a>
  <img src="https://img.shields.io/github/last-commit/bivlked/amneziawg-installer" alt="Last commit">
</p>

<p align="center">
  <a href="#why">Why this project</a> •
  <a href="#comparison">AWG vs WG</a> •
  <a href="#cli-vs-panel">CLI vs panels</a> •
  <a href="#similar-tools">Similar tools</a> •
  <a href="#quickstart">Quick Start</a> •
  <a href="#fork-delta">Fork Delta</a> •
  <a href="#features">Features</a> •
  <a href="#carriers">Carriers</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#hosting-recommendation">Hosting</a> •
  <a href="#installation">Installation</a> •
  <a href="#after-installation">After installation</a> •
  <a href="#client-management">Management</a> •
  <a href="#additional-information">More</a> •
  <a href="#roadmap">Roadmap</a> •
  <a href="#faq">FAQ</a> •
  <a href="#troubleshooting">Troubleshooting</a> •
  <a href="#ecosystem">Ecosystem</a> •
  <a href="#license">License</a>
</p>

<a id="quickstart"></a>
# AmneziaWG Installer Fork

This is an `amneziawg-installer` fork with a lightweight Python stdlib web panel, HTTPS, bearer token / `tokens.json`, RBAC access tokens, IPv6 `routed|ndp|nat66|legacy`, P2P/DNAT, AdGuard Home integration, `vpn://` URIs, QR/config integration, and UDP/voice diagnostics.

## 🚀 Quick Start

### Safe default installation

```bash
git clone https://github.com/<OWNER>/<REPO>.git
cd amneziawg-installer
sudo bash install_amneziawg_en.sh
```

If you run the installer directly through `curl`, use your own repository and branch:

```bash
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/install_amneziawg_en.sh -o install_amneziawg_en.sh
sudo bash install_amneziawg_en.sh
```

### Accessing the web panel

By default, the web panel is reachable only from inside the VPN:

```text
https://10.9.9.1:8443
```

Connect a VPN client and open that address in a browser. If you intentionally installed with `--web-bind=127.0.0.1`, use an SSH tunnel as a fallback:

```bash
ssh -L 8443:127.0.0.1:8443 root@SERVER_IP
```

Then open:

```text
https://127.0.0.1:8443
```

The panel ships local assets only, so bearer tokens are not exposed to third-party CDN JavaScript. User tokens can manage only assigned clients and cannot create new ones. If `tokens.json` becomes invalid, reset the super token with `manage web token reset-super` instead of expecting an automatic replacement.

### Public web panel, only when you really need it

```bash
sudo bash install_amneziawg_en.sh --web-bind=0.0.0.0 --web-port=8443
```

> Exposing the web panel to the whole internet is not recommended. Prefer a firewall allowlist, VPN, SSH tunnel, or a reverse proxy with extra authentication. Keep the bearer token long and secret; do not publish `tokens.json`, client configs, QR codes, or `vpn://` URIs.

## Common installation scenarios

```bash
# Minimal install
sudo bash install_amneziawg_en.sh

# Web panel inside the VPN only (default)
sudo bash install_amneziawg_en.sh --web-bind=10.9.9.1 --web-port=8443

# Web panel on localhost only, when you want an SSH tunnel
sudo bash install_amneziawg_en.sh --web-bind=127.0.0.1 --web-port=8443

# Public web panel — only when you intentionally want one
sudo bash install_amneziawg_en.sh --web-bind=0.0.0.0 --web-port=8443

# IPv6 through NDP proxy
sudo bash install_amneziawg_en.sh --enable-native-ipv6 --ipv6-mode=ndp

# IPv6 NAT66/ULA fallback
sudo bash install_amneziawg_en.sh --enable-native-ipv6 --ipv6-mode=nat66

# Routed IPv6 when the server has a routed prefix
sudo bash install_amneziawg_en.sh --enable-native-ipv6 --ipv6-mode=routed --ipv6-subnet=2001:db8:1234:1::/64

# AdGuard Home integration
sudo bash install_amneziawg_en.sh --enable-adguard --dns-mode=adguard
```

P2P/DNAT is configured after installation:

```bash
sudo /root/awg/manage_amneziawg.sh p2p add CLIENT_NAME PORT
sudo /root/awg/manage_amneziawg.sh p2p remove CLIENT_NAME PORT
sudo /root/awg/manage_amneziawg.sh p2p toggle CLIENT_NAME
```

## Important installer flags

| Flag | Purpose | Example |
| --- | --- | --- |
| `--yes` | Run without interactive confirmations | `sudo bash install_amneziawg_en.sh --yes` |
| `--web-bind=ADDR` | Address the web panel listens on. Default: VPN gateway `10.9.9.1` | `--web-bind=0.0.0.0` |
| `--web-port=PORT` | Web panel HTTPS port | `--web-port=8443` |
| `--disable-web` | Do not deploy the web panel | `--disable-web` |
| `--enable-native-ipv6` | Compatibility alias for enabling client IPv6 | `--enable-native-ipv6` |
| `--disallow-ipv6` | Force-disable IPv6 | `--disallow-ipv6` |
| `--ipv6-mode=MODE` | IPv6 mode: `routed`, `ndp`, `nat66` | `--ipv6-mode=ndp` |
| `--ipv6-subnet=CIDR` | Client IPv6 prefix | `--ipv6-subnet=2001:db8:1::/64` |
| `--upgrade-ipv6` | Add IPv6/P2P metadata to existing clients | `--upgrade-ipv6` |
| `--p2p-base-port=PORT` | Base P2P port range | `--p2p-base-port=20000` |
| `--p2p-ports-per-client=N` | P2P ports assigned to each new client | `--p2p-ports-per-client=3` |
| `--fullcone-nat` | Try `FULLCONENAT`, otherwise fall back to `MASQUERADE` | `--fullcone-nat` |
| `--enable-adguard` | Install AdGuard Home | `--enable-adguard` |
| `--dns-mode=MODE` | DNS mode: `adguard`, `system`, `custom` | `--dns-mode=adguard` |
| `--route-all` | Route all traffic through the VPN | `--route-all` |
| `--route-amnezia` | Use the Amnezia route list | `--route-amnezia` |
| `--endpoint=IP` | External server IP when the VPS is behind NAT | `--endpoint=203.0.113.10` |
| `--preset=TYPE` | Obfuscation preset: `default` or `mobile` | `--preset=mobile` |
| `--no-tweaks` | Skip hardening/optimization | `--no-tweaks` |

See `sudo bash install_amneziawg_en.sh --help` for the full list.

## Post-install management commands

```bash
sudo /root/awg/manage_amneziawg.sh list
sudo /root/awg/manage_amneziawg.sh add CLIENT_NAME
sudo /root/awg/manage_amneziawg.sh remove CLIENT_NAME
sudo /root/awg/manage_amneziawg.sh toggle CLIENT_NAME
sudo /root/awg/manage_amneziawg.sh stats
sudo /root/awg/manage_amneziawg.sh restart
sudo /root/awg/manage_amneziawg.sh web token list
sudo /root/awg/manage_amneziawg.sh set-name "My VPN"
sudo /root/awg/manage_amneziawg.sh voice-check
sudo /root/awg/manage_amneziawg.sh udp-check
sudo /root/awg/manage_amneziawg.sh dns status
sudo /root/awg/manage_amneziawg.sh dns restart
```

## Security notes

* The web panel binds to VPN gateway `10.9.9.1` by default and is reachable only by connected VPN clients.
* Static serving is restricted to an allowlist: `index.html`, `style.css`, `app.js`, `favicon.svg`.
* Private files such as `tokens.json`, `auth_token`, `key.pem`, `cert.pem`, and `server.py` are not served over static HTTP.
* `tokens.json` stores token hashes, but it still must remain private.
* Do not publish client configs, QR codes, or `vpn://` URIs.
* For localhost-only access, use `--web-bind=127.0.0.1` plus an SSH tunnel; for a public panel, use a firewall allowlist, VPN, or a reverse proxy with additional authentication.


---

<a id="fork-delta"></a>
## 🔀 This is a fork of the original project

This repository is a fork of [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer), not a separate upstream release line. The base is intentionally documented as **upstream `v5.13.0`** so future upstream changes can be pulled in more easily and the fork delta stays obvious.

**Main differences from the original:**

* **Full IPv6 for clients:** native `/64` when the VPS/provider routes a public prefix, or explicit `ULA fd.../64 + NAT66` fallback.
* **P2P ports:** every client gets TCP+UDP ports for torrents, games, and self-hosted services; extra ports are managed through CLI and the web panel.
* **Full Cone NAT attempt:** `FULLCONENAT` is used when available; otherwise the scripts fall back to `MASQUERADE`.
* **Web panel:** HTTPS `:8443`, self-signed TLS, bearer token, clients, config/QR/vpnuri, stats, logs, service restart, and a DNS/AdGuard card.
* **AdGuard Home DNS:** optional no-Docker install, DNS only on localhost/VPN, clients receive `10.9.9.1` and the server IPv6 address when dual-stack is enabled.
* **New management commands:** `p2p list/show/add/remove`, `ipv6 status/upgrade`, `dns status/restart/logs/set-mode`.
* **Generated firewall hooks:** `/root/awg/postup.sh`, `/root/awg/postdown.sh`, `/root/awg/p2p_rules.sh`.
* **Fork patchset:** upstream version stays `5.13.0`; fork changes are documented as delta on top.

**Important:** the README does not take over future upstream version numbers. If the fork needs its own marker, prefer a separate `FORK_PATCHSET`/`FORK_NAME` instead of bumping the upstream version.

> Installation commands below pull this fork directly from raw GitHub, without releases or tags. The upstream base remains `v5.13.0`, while the fork patchset branch is `main`.

---

<a id="why"></a>
## 💡 Why this project

[AmneziaWG](https://github.com/amnezia-vpn) is a fork of WireGuard with traffic obfuscation. DPI systems cannot distinguish it from random noise, so the connection is not blocked.

This set of scripts turns a clean VPS into a ready-to-use VPN server. No Linux knowledge required — the script configures the firewall, optimizes the system, and generates client configs and QR codes automatically.

Works on Ubuntu 24.04/25.10/26.04 and Debian 12/13. Any cheap VPS with 1 GB RAM is enough.

---

<a id="comparison"></a>
## ⚖️ AmneziaWG vs WireGuard

| | WireGuard | AmneziaWG 2.0 |
|---|---|---|
| **DPI detection** | Fingerprinted by fixed packet sizes and magic bytes | Undetectable — randomized headers, padding, protocol mimicry |
| **Blocked in** | China, Russia, Iran, UAE, Turkmenistan | No known blocks (as of April 2026) |
| **Server setup** | Manual: keys, iptables, sysctl, systemd | One command, 20 min, fully automatic |
| **Hardening** | DIY: UFW, Fail2Ban, sysctl | Automatic: firewall + brute-force protection + kernel tuning |
| **Client management** | Edit configs by hand, restart | `add`/`remove`/`list`/`stats` with hot-reload |
| **Temporary access** | Not built-in | `--expires=7d` with auto-cleanup |
| **Server requirements** | — | Same — any $3-5/mo VPS, 1 GB RAM |
| **Speed overhead** | Baseline | Negligible (<2%) |

> If WireGuard works for you and isn't blocked — keep using it. If it's blocked or throttled — AmneziaWG 2.0 is the drop-in replacement.

---

<a id="cli-vs-panel"></a>
## ⚙️ CLI Installer vs Web Panels

> **The goal: set up a VPN on a cheap VPS in 20 minutes.** The script doesn't pull in Docker, a database, or a heavy web stack. After installation AWG, the firewall, and an optional Python stdlib web panel are running — minimal footprint, maximum resources for VPN.

| | This project (CLI) | Docker-based web panels |
|---|---|---|
| **AWG module** | Kernel module — runs at kernel level | Userspace inside a container |
| **Server requirements** | Any VPS with 512 MB RAM, Python3 for the web panel | Needs PHP/Python, database, web server, Docker |
| **Attack surface** | SSH + UDP VPN port + HTTPS panel with bearer token | + HTTP panel, database, Docker |
| **Installation** | Single command on the server, 20 minutes | docker-compose + giving SSH access to the panel |
| **After reboot** | Resumes installation from the same step | Depends on container and database state |
| **Web interface** | ✅ Lightweight built-in panel, no DB | ✅ GUI, browser-based management |
| **Multiple protocols** | AmneziaWG only | WireGuard, OpenVPN, VLESS and others |

> Need a VPN without GUI on a dedicated server — this project. Need a web panel with multiple protocols — look for Docker-based solutions.

---

<a id="similar-tools"></a>
## 🔧 Comparison with similar tools

There are a few other ways to get AmneziaWG running. Each picks a different trade-off:

| Tool | Path | Best for |
|---|---|---|
| **This installer** | SSH + one bash command | Headless VPS, single-purpose box, no Docker, ARM prebuilts |
| **[wg-easy](https://github.com/wg-easy/wg-easy)** | Docker + web UI | Home-lab boxes that already run Docker; want a browser panel for peers |
| **[spcfox/amnezia-wg-easy](https://github.com/spcfox/amnezia-wg-easy)** | Docker fork of wg-easy | Existing wg-easy users who specifically want AmneziaWG instead of plain WireGuard |
| **[Amnezia VPN app](https://amnezia.org/)** | Desktop GUI + SSH deploy | Click-through setup with no terminal; prefer a graphical client |

This installer is the SSH-first path without a heavy stack: a lightweight Python stdlib web panel, kernel-level AmneziaWG, and ARM prebuilts for cheap boxes. If you already run Docker and want a multi-protocol GUI suite, **wg-easy** is the more natural fit. If you want point-and-click deployment, the **Amnezia VPN** desktop client includes its own SSH deployment workflow.


<a id="fork-details"></a>
## 🌐 Fork implementation details: IPv6 + P2P + Web

This fork delta is built on top of upstream `v5.13.0`. Legacy installs keep working while new or migrated clients can opt into dual-stack IPv6 and P2P metadata.

### Why

* **Real IPv6 for VPN clients.** With a public `/64`, clients receive routed IPv6 addresses without NAT66.
* **Honest fallback.** If no public `/64` is available, the installer can use `ULA fd.../64 + NAT66` and clearly warns that this is not public native IPv6.
* **P2P ports.** Each client gets TCP+UDP ports for torrents, games, and self-hosted services.
* **Better UDP NAT behavior.** `FULLCONENAT` is used when available; otherwise the scripts fall back to `MASQUERADE`. Messengers such as Telegram/WhatsApp still decide themselves whether to use direct P2P or relay.
* **Web panel.** Browser-based client CRUD, configs, QR codes, stats, logs, and restart actions without typing SSH commands every time.

### Voice / Calls optimization

AmneziaWG is an L3 VPN. It does not need XUDP for normal calls: XUDP belongs to the Xray/VLESS/VMess proxy stack and is not part of AWG. For WebRTC and calls, this installer applies safe UDP optimizations: `MTU 1280`, `PersistentKeepalive 25`, UDP conntrack timeout `120`, UDP conntrack stream timeout `300`, normal `MASQUERADE`/`SNAT`, and optional P2P forwarding for static-port apps. Full Cone NAT is not enabled by default.

Messenger calls usually use ICE/STUN/TURN and dynamic UDP ports. P2P/DNAT ports are useful for torrents, games, and static-port apps; Telegram/WhatsApp/Discord calls usually do not need manual port forwarding.

#### Voice / STUN test on Windows

Download the Windows STUNTMAN binary, extract the whole archive (not only `stunclient.exe`), open PowerShell in that folder, and run:

```powershell
.\stunclient.exe stun.l.google.com 19302
.\stunclient.exe stun.cloudflare.com 3478
.\stunclient.exe stunserver2025.stunprotocol.org 3478
```

Expected result: `Mapped address: <VPS_PUBLIC_IP>:<port>`. If `Mapped address` shows the VPS IP, UDP/STUN through AWG works. Preserving the source port, for example `49340 -> 49340`, is a good sign of port-preserving NAT, but it is not a guarantee of Full Cone NAT.

### How to enable

```bash
sudo bash ./install_amneziawg_en.sh --enable-native-ipv6
sudo bash ./install_amneziawg_en.sh --enable-native-ipv6 --ipv6-subnet=2001:db8:1234:1::/64
sudo bash ./install_amneziawg_en.sh --upgrade-ipv6
```

Useful flags:

```bash
--p2p-base-port=20000
--p2p-ports-per-client=3
--fullcone-nat
--web-port=8443
--web-bind=10.9.9.1
--disable-web
--enable-adguard
--adguard-port=3000
--dns-mode=adguard|system|custom
```

### Implementation notes

* New config keys live in `/root/awg/awgsetup_cfg.init`: `AWG_IPV6_*`, `AWG_P2P_*`, `AWG_FULLCONE_NAT`, `AWG_WEB_*`, `AWG_DNS_MODE`, `AWG_ADGUARD_*`.
* Server config uses dual `Address` and external hooks: `/root/awg/postup.sh` and `/root/awg/postdown.sh`.
* Peer blocks are the source of truth: `AllowedIPs = <ipv4>/32, <ipv6>/128` and `#_P2PPorts = p1,p2,p3`.
* Default P2P ports for IPv4 last octet `N`: `20000+N`, `20256+N`, `20512+N`; extra ports are allocated from `20001-21024`.
* Web files live in `/root/awg/web/`; the panel listens on VPN gateway `10.9.9.1:8443` by default, uses local assets without external CDNs, self-signed TLS, and stores bearer-token hashes/RBAC records in `/root/awg/web/tokens.json`.
* AdGuard Home is installed in `/opt/AdGuardHome`; DNS listens on `127.0.0.1`, `10.9.9.1`, and the server IPv6 address inside the VPN. If it fails, VPN remains usable; fallback: `manage dns set-mode system`.

### Not finished yet

* `FULLCONENAT` depends on kernel/iptables target availability; `MASQUERADE` is the fallback.
* Self-signed TLS is expected to trigger a browser warning.
* Release SHA256 values are still `RELEASE_PLACEHOLDER` until the fork release build.
* Local checks covered `bash -n`, Python compile, and helper smoke tests; full Bats, ShellCheck, and clean Ubuntu VPS testing still need to run in Linux/CI.

---

<a id="features"></a>
## ✨ Features

* **DPI bypass** — AmneziaWG 2.0 with traffic obfuscation. DPI cannot detect the connection
* **One command — working VPN** — from a clean VPS to a running server with client configs and QR codes
* **Dual-stack IPv6** — native `/64` when available, or explicit ULA/NAT66 fallback
* **P2P ports** — automatic TCP+UDP ports per client plus CLI/Web management
* **Web panel** — HTTPS `:8443`, bearer token, clients, QR/config/vpnuri, stats, and logs
* **Secure by default** — UFW, Fail2Ban, sysctl hardening, strict file permissions (600/700)
* **Easy management** — add/remove clients, temporary clients with auto-removal, traffic stats, backups
* **4 operating systems** — Ubuntu 24.04, Ubuntu 25.10/26.04, Debian 12, Debian 13
* **x86_64 and ARM** — cloud VPS, Raspberry Pi 3/4/5, ARM64 servers (AWS Graviton, Oracle Ampere, Hetzner)
* **Mobile network optimization** — `--preset=mobile` for Tele2, Yota, Megafon and other carriers with DPI blocking. Fine-tune with `--jc`, `--jmin`, `--jmax` ([details](ADVANCED.en.md#presets-adv))

<details>
<summary><strong>All features</strong></summary>

* Native key and config generation via `awg`; the web panel uses Python3 stdlib only, with no Node/PHP/database
* Hardware-aware optimization: swap, NIC offloads, network buffers tuned to server specs
* DKMS — automatic kernel module rebuild on updates
* `vpn://` URI for one-tap import into Amnezia Client (`.vpnuri` files)
* Per-client traffic statistics (`stats`, `stats --json`)
* Temporary clients with auto-removal (`--expires=1h`, `7d`, `4w`, etc.)
* Diagnostic report (`--diagnostic`) and full uninstall (`--uninstall`)
* All actions logged to `/root/awg/`
* Resume after reboot — the script picks up from where it left off
* Choice of port, subnet, IPv6 mode, and routing mode. `--endpoint` flag for servers behind NAT
</details>

---

<a id="carriers"></a>
## 📡 Tested mobile carriers (Russia)

If your VPN is unstable on mobile data, run the installer with `--preset=mobile`. Below — working configurations reported in issues and discussions:

- **Yota** — Moscow, `--preset=mobile`
- **Tele2** — Moscow (`--preset=mobile`); Krasnoyarsk (`--preset=mobile` + remove the `I1` parameter)
- **Tattelecom / Letai** — Tatarstan, `--preset=mobile`
- **Megafon** — regional networks, `--preset=mobile` + remove the `I1` parameter
- **Beeline** — default preset, no flags needed
- **Home / wired ISPs** — default preset usually works out of the box

Your carrier is not on the list? Try `--preset=mobile`. If that doesn't work — open a thread in [Discussions](https://github.com/bivlked/amneziawg-installer/discussions) or [Issues](https://github.com/bivlked/amneziawg-installer/issues) and I'll add the entry.

> Full operator parameter table (Jc, Jmin, Jmax, I1) — in [ADVANCED.en.md → FAQ "connects over cellular only on the third attempt"](ADVANCED.en.md#faq-advanced-adv). Per-flag overrides via `--jc`/`--jmin`/`--jmax` — in [ADVANCED.en.md → Presets](ADVANCED.en.md#presets-adv).

---

<a id="requirements"></a>
## 🖥️ Requirements

* **OS:** A **clean** installation of **Ubuntu Server 24.04 LTS** / **Ubuntu 25.10** / **Ubuntu 26.04** / **Debian 12** / **Debian 13** Minimal
* **Access:** `root` privileges (via `sudo`)
* **Internet:** Stable connection
* **Resources:** ~1 GB RAM (2+ GB recommended), minimum ~2 GB disk (3+ GB recommended)
* **SSH:** SSH access to the server

**OS Compatibility:**

| OS | Status | Notes |
|----|--------|-------|
| Ubuntu 24.04 LTS | ✅ Fully supported | Recommended |
| Ubuntu 25.10 | ✅ Supported | PPA `noble` fallback applied automatically since v5.13.0 |
| Ubuntu 26.04 | ✅ Supported | PPA `noble` fallback applied automatically since v5.13.0 |
| Debian 12 (bookworm) | ✅ Supported | Tested. PPA via codename mapping to focal |
| Debian 13 (trixie) | ✅ Supported | Tested. PPA via codename mapping to noble, DEB822 |

**Architecture support (v5.10.0+):**

| Architecture | Status | Platforms |
|---|---|---|
| x86_64 (amd64) | ✅ Fully supported | All cloud VPS |
| ARM64 (aarch64) | ✅ Supported | Raspberry Pi 3/4/5, AWS Graviton, Oracle Ampere, Hetzner |
| ARMv7 (armhf) | ✅ Supported | Raspberry Pi 3/4 (32-bit) |

> On ARM, the installer downloads prebuilt kernel modules when available and falls back to DKMS compilation automatically.

> ⚠️ **Non-standard SSH port:** If SSH is not on port 22, run `sudo ufw allow YOUR_PORT/tcp` **before** starting the installer, otherwise you will lose access to the server.

**Clients:**
* **All platforms:** [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases) **>= 4.8.12.7** — full-featured VPN client with AWG 2.0. Import via `vpn://` URI
* **Windows:** [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) **>= 2.0.0** — lightweight tunnel manager with AWG 2.0. Import via `.conf` files

> [Full client compatibility table →](ADVANCED.en.md#client-compat-adv)

---

<a id="hosting-recommendation"></a>
## 🚀 Hosting Recommendation

For a stable, high-throughput VPN server, you need reliable hosting with a good network.

I've tested and recommend [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). Their **BUDGET VPS** lineup offers excellent value for money.

Their IPs are not flagged as datacenter — they are not blocked by services that restrict hosting/datacenter IP ranges (unlike Azure and some major clouds).

* **Recommended plan:** **BVPS-2**
* **Specs:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Key advantage:** **10 Gbps** port with **unlimited traffic**. Perfect for VPN!
* **Price:** Just **€25 per year**.

This configuration is more than enough for comfortable AmneziaWG operation with many connections and heavy traffic.

---

<a id="installation"></a>
## 🔧 Installation (Recommended Method)

This installation method handles interactive prompts and colored output correctly in your terminal.

1.  **Connect** to a **clean** server (Ubuntu 24.04 / Ubuntu 25.10 / Ubuntu 26.04 / Debian 12 / Debian 13) via SSH.
    > **Tip:** After creating the server, wait 5-10 minutes for all background initialization processes to complete before starting the installation.

2.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg_en.sh
    # or: curl -fLo install_amneziawg_en.sh https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg_en.sh
    ```
3.  **Make it executable:**
    ```bash
    chmod +x install_amneziawg_en.sh
    ```
4.  **Run with `sudo`:**
    ```bash
    sudo bash ./install_amneziawg_en.sh
    ```
    *(You can also pass command-line parameters, see `sudo bash ./install_amneziawg_en.sh --help` or [ADVANCED.en.md#install-cli-adv](ADVANCED.en.md#install-cli-adv))*

    > **Russian version:** For Russian output, use `install_amneziawg.sh`:
    > ```bash
    > wget https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh
    > sudo bash ./install_amneziawg.sh
    > ```
    > The Russian version is functionally identical; only user-facing messages and logs are in Russian.
    > After reboots, resume with the same file: `sudo bash ./install_amneziawg.sh`

5.  **Initial setup:** The script will interactively ask for:
    * **UDP port:** Port for client connections (1024-65535). Default: a random high port; you can set it manually with `--port=XXXXX`.
    * **Tunnel subnet:** Internal VPN network. Default: `10.9.9.1/24`.
    * **Disable IPv6:** Recommended (`Y`) to prevent traffic leaks.
    * **Routing mode:** Determines which traffic goes through the VPN. Default `2` (Amnezia List + DNS) — recommended for best compatibility and bypassing restrictions.

    AWG 2.0 parameters (Jc, S1-S4, H1-H4, I1) are generated **automatically** — no action required.

6.  **Reboots:** **TWO** reboots are required. The script will ask for confirmation `[y/N]`. Type `y` and press Enter.

7.  **Resume:** After each reboot, **run the script again** with the same command:
    ```bash
    sudo bash ./install_amneziawg_en.sh
    ```
    The script will automatically resume from where it left off **without repeating any prompts**.

8.  **Completion:** After the second reboot and the third script run, you will see the message:
    `AmneziaWG 2.0 installation and configuration completed SUCCESSFULLY!`

---

<a id="after-installation"></a>
## 📦 After installation

**Where to find client files:**

| File | Path | Purpose |
|------|------|---------|
| `.conf` | `/root/awg/name.conf` | Configuration for client import |
| `.png` | `/root/awg/name.png` | QR code for mobile devices |
| `.vpnuri` | `/root/awg/name.vpnuri` | `vpn://` URI for Amnezia Client |

**Download config to your computer:**

```bash
scp root@SERVER_IP:/root/awg/my_phone.conf .
```

<details>
<summary><strong>Import into Amnezia VPN (phone) via vpn:// URI</strong></summary>

1. On the server, run: `cat /root/awg/my_phone.vpnuri`
2. Copy the text and send it to yourself (Telegram, email, etc.)
3. On your phone: Amnezia VPN → "Add VPN" → "Paste from clipboard"
</details>

<details>
<summary><strong>Import via QR code</strong></summary>

1. Download the QR code: `scp root@SERVER_IP:/root/awg/my_phone.png .`
2. Open the file on your computer screen
3. On your phone: Amnezia VPN → "Add VPN" → "Scan QR code"
</details>

<details>
<summary><strong>Import into AmneziaWG for Windows</strong></summary>

1. Download the `.conf` file to your computer via `scp` or `sftp`
2. AmneziaWG → Import tunnel(s) from file → select the `.conf` file
</details>

**Other files on the server:**

* Server configuration: `/etc/amnezia/amneziawg/awg0.conf`
* Script settings: `/root/awg/awgsetup_cfg.init`
* Management script: `/root/awg/manage_amneziawg.sh`
* Shared functions: `/root/awg/awg_common.sh`
* Web panel: `/root/awg/web/` (`server.py`, `index.html`, `style.css`, `app.js`, `auth_token`, `cert.pem`, `key.pem`)
* Firewall hooks: `/root/awg/postup.sh`, `/root/awg/postdown.sh`, `/root/awg/p2p_rules.sh`
* NDP proxy config for native IPv6: `/etc/ndppd.conf`
* Client expiry data: `/root/awg/expiry/`
* Logs: `/root/awg/*.log`

---

<a id="client-management"></a>
## 👥 Client Management (`manage_amneziawg.sh`)

The `manage_amneziawg.sh` script is downloaded automatically during installation.

**Usage:**

```bash
sudo bash /root/awg/manage_amneziawg.sh <command> [arguments]
```

**Main commands:** (Full list: `... help` or [ADVANCED.en.md#manage-commands-adv](ADVANCED.en.md#manage-commands-adv))

| Command   | Arguments              | Description                    | Restart? |
| :-------- | :--------------------- | :----------------------------- | :------: |
| `add`     | `<name> [name2 ...] [--expires=DUR]`  | Add client(s) (opt. with expiry) | No (auto) |
| `remove`  | `<name> [name2 ...]`   | Remove client(s)               | No (auto) |
| `list`    | `[-v]`                 | List clients (`-v` for details)|    No     |
| `regen`   | `[client_name]`        | Regenerate files (all/one)     |    No     |
| `modify`  | `<name> <param> <val>` | Modify a client parameter      |    No     |
| `backup`  |                        | Create a backup                |    No     |
| `restore` | `[file]`               | Restore from backup            |    No     |
| `stats`   | `[--json]`                | Per-client traffic statistics    |    No     |
| `p2p list` | | Show P2P ports for all clients | No |
| `p2p show` | `<name>` | Show client IPv4/IPv6/P2P info | No |
| `p2p add` | `<name> [port]` | Add a TCP+UDP P2P port | No (auto) |
| `p2p remove` | `<name> <port>` | Remove a P2P port | No (auto) |
| `ipv6 status` | | Show IPv6 mode | No |
| `ipv6 upgrade` | | Backfill IPv6/P2P metadata for existing clients | No (auto) |
| `show`    |                        | Run `awg show`                 |    No     |
| `check`   |                        | Check server status            |    No     |
| `restart` |                        | Restart AmneziaWG service      |    -      |

> **💡 Note:** `add` and `remove` commands auto-apply changes via `awg syncconf` — no service restart needed.

### 📌 Quick Reference

```bash
# Installation (English)
wget https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh       # Run (+ 2 reboots)

# Installation (Russian)
wget https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/install_amneziawg.sh
sudo bash ./install_amneziawg.sh          # Run (+ 2 reboots)

# Client management
sudo bash /root/awg/manage_amneziawg.sh add my_phone       # Add
sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk  # +PresharedKey (Shadowrocket iOS/macOS)
sudo bash /root/awg/manage_amneziawg.sh remove my_phone    # Remove
sudo bash /root/awg/manage_amneziawg.sh list                # List
sudo bash /root/awg/manage_amneziawg.sh regen               # Regenerate

# Temporary client (7 days)
sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d

# Traffic statistics
sudo bash /root/awg/manage_amneziawg.sh stats
sudo bash /root/awg/manage_amneziawg.sh stats --json

# IPv6 / P2P
sudo bash /root/awg/manage_amneziawg.sh ipv6 status
sudo bash /root/awg/manage_amneziawg.sh ipv6 upgrade
sudo bash /root/awg/manage_amneziawg.sh p2p list
sudo bash /root/awg/manage_amneziawg.sh p2p add my_phone
sudo bash /root/awg/manage_amneziawg.sh p2p add my_phone 20077
sudo bash /root/awg/manage_amneziawg.sh p2p remove my_phone 20077

# Maintenance
sudo bash /root/awg/manage_amneziawg.sh check               # Diagnostics
sudo bash /root/awg/manage_amneziawg.sh backup               # Backup
sudo bash /root/awg/manage_amneziawg.sh restart              # Restart
```

---

<a id="additional-information"></a>
## ℹ️ Additional Information

For detailed information on configuration, security settings, AWG 2.0 parameters, management commands, technical details, and more, see **[ADVANCED.en.md](ADVANCED.en.md)**.

For the changelog, see **[CHANGELOG.en.md](CHANGELOG.en.md)**.

---

<a id="roadmap"></a>
## 🧭 Roadmap

### AdGuard Home as VPN DNS

This fork delta includes built-in **AdGuard Home** as a DNS resolver/filter for VPN clients.

Why:

* block ads, trackers, telemetry, malware/phishing domains, and noisy DNS requests on the VPN server;
* provide one DNS setup for all VPN clients without configuring every phone or laptop manually;
* reduce background traffic and make browsing/apps cleaner;
* allow future per-profile filtering for regular clients, kids' devices, and temporary guests.

Usage:

```bash
sudo bash ./install_amneziawg_en.sh --enable-adguard --dns-mode=adguard
sudo bash /root/awg/manage_amneziawg.sh dns status
sudo bash /root/awg/manage_amneziawg.sh dns restart
sudo bash /root/awg/manage_amneziawg.sh dns logs
sudo bash /root/awg/manage_amneziawg.sh dns set-mode system
```

Implemented:

* installer flags `--enable-adguard`, `--adguard-port=3000`, `--dns-mode=adguard|system|custom`;
* no-Docker AdGuard Home install under `/opt/AdGuardHome`;
* DNS bind only on localhost/VPN addresses, not as an open public resolver;
* client DNS: `10.9.9.1` and, with IPv6, the server IPv6 from `AWG_IPV6_SUBNET`;
* UFW opens DNS/UI only on `awg0`;
* `manage_amneziawg.sh dns status|restart|logs|set-mode`;
* AdGuard/DNS card in the web panel;
* fallback: if AdGuard fails, VPN remains usable and DNS mode can be switched back to `system`.

Safety goals:

* AdGuard Home must stay optional;
* disabling AdGuard must keep the current DNS path working;
* AdGuard web-admin must not be publicly exposed by default;
* if AdGuard fails, VPN should remain usable and clients should have a clear fallback DNS path.

---

<a id="faq"></a>
## ❓ FAQ

<details>
  <summary><strong>Q: Will it survive a kernel update?</strong></summary>
  <b>A:</b> Yes, DKMS should automatically rebuild the module. Verify with <code>dkms status</code>.
</details>

<details>
  <summary><strong>Q: How do I completely uninstall AmneziaWG?</strong></summary>
  <b>A:</b> Download the installer script (if you don't have it) and run: <code>sudo bash ./install_amneziawg_en.sh --uninstall</code>.
</details>

<details>
  <summary><strong>Q: Clients can't connect — what should I do?</strong></summary>
  <b>A:</b> 1. Check status: <code>sudo bash /root/awg/manage_amneziawg.sh check</code>. 2. Check firewall: <code>sudo ufw status verbose</code>. 3. Verify client config. 4. Check logs: <code>sudo journalctl -u awg-quick@awg0 -n 50</code>. 5. Make sure the client supports AWG 2.0: Amnezia VPN <b>>= 4.8.12.7</b> or AmneziaWG <b>>= 2.0.0</b>.
</details>

<details>
  <summary><strong>Q: Handshake completes but no traffic flows - what's wrong?</strong></summary>
  <b>A:</b> A common cause is the split-tunneling AllowedIPs gotcha during manual customization. If you want to ping or SSH to the server by its inner tunnel IP (<code>10.9.9.1</code> in the default subnet), add the <b>tunnel subnet</b> (default <code>10.9.9.0/24</code>, or your custom one if you changed <code>--subnet</code>) to the client's <code>AllowedIPs</code>. Otherwise the client does not route traffic to the server even from inside the tunnel. The <code>--route-all</code> mode (full tunnel <code>0.0.0.0/0</code>) covers the subnet automatically; the default <code>--route-amnezia</code> (Amnezia List) and <code>--route-custom=</code> do not, add it explicitly. See <a href="ADVANCED.en.md#allowedips-adv">ADVANCED.en.md → AllowedIPs</a>.
</details>

<details>
  <summary><strong>Q: Can I use this with AWG 1.x clients?</strong></summary>
  <b>A:</b> No. AWG 2.0 is not compatible with AWG 1.x. All clients must support the 2.0 protocol. For AWG 1.x, use the <a href="https://github.com/bivlked/amneziawg-installer/tree/legacy/v4">legacy/v4</a> branch.
</details>

<details>
  <summary><strong>Q: Config import error "Invalid key: s3" — what's wrong?</strong></summary>
  <b>A:</b> You're using an outdated version of <code>amneziawg-windows-client</code> (< 2.0.0). Update to <a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases"><b>version 2.0.0+</b></a> which supports AWG 2.0. Alternatively, use <a href="https://github.com/amnezia-vpn/amnezia-client/releases"><b>Amnezia VPN</b></a> >= 4.8.12.7.
</details>

<details>
  <summary><strong>Q: How do I update the scripts to a newer version?</strong></summary>
  <b>A:</b> Download the updated scripts and replace them on the server:
  <pre>
  # English version:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/manage_amneziawg_en.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/awg_common_en.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh

  # Russian version:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/manage_amneziawg.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/Basil-AS/amneziawg-installer/main/awg_common.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
  </pre>
  Server reinstallation is not required.
</details>

<details>
  <summary><strong>Q: What is the maximum number of clients?</strong></summary>
  <b>A:</b> A <code>/24</code> subnet supports up to 253 clients (.2 — .254), which is sufficient for most use cases.
</details>

<details>
  <summary><strong>Q: Which hosting providers work well?</strong></summary>
  <b>A:</b> Any VPS with Ubuntu 24.04 LTS / Ubuntu 25.10 / Ubuntu 26.04 / Debian 12 / Debian 13, root access, and at least 1 GB RAM. Pick providers with clean (non-blacklisted) IPs and unlimited traffic. See the <a href="#hosting-recommendation">recommendation</a> below.
</details>

<details>
  <summary><strong>Q: How do I migrate the VPN to another server?</strong></summary>
  <b>A:</b> 1. Create a backup: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Copy the archive from <code>/root/awg/backups/</code> to the new server. 3. Install AmneziaWG on the new server. 4. Restore: <code>sudo bash /root/awg/manage_amneziawg.sh restore</code> (interactive selection, or specify the full archive path). 5. Regenerate configs with new IP: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>.
</details>

<details>
  <summary><strong>Q: How do I create a temporary client?</strong></summary>
  <b>A:</b> <code>sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d</code>. Formats: <code>1h</code>, <code>12h</code>, <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>4w</code>. A cron job checks every 5 minutes and automatically removes expired clients.
</details>

<details>
  <summary><strong>Q: What are .vpnuri files?</strong></summary>
  <b>A:</b> <code>.vpnuri</code> files contain <code>vpn://</code> URIs for one-tap config import into Amnezia Client. Copy the file contents → open Amnezia Client → "Add VPN" → "Paste from clipboard".
</details>

<details>
  <summary><strong>Q: Shadowrocket on iOS/macOS does not connect — needs PresharedKey</strong></summary>
  <b>A:</b> Since v5.11.1 the <code>add</code> command supports a <code>--psk</code> flag: <code>sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk</code>. The client config will include a <code>PresharedKey = ...</code> line matching the server <code>[Peer]</code>. For existing clients: recreate with the flag (<code>remove</code> + <code>add --psk</code>) or manually — generate the key <em>once</em> (<code>PSK=$(awg genpsk)</code>) and paste the <em>same value</em> into both sides (the server <code>[Peer]</code> for that client and the client's <code>[Peer]</code> for the server); the handshake fails if the values differ. <code>regen</code> preserves an existing PSK across rotation. Details — in <a href="ADVANCED.en.md#manage-cli-adv">ADVANCED.en.md</a>.
</details>

<details>
  <summary><strong>Q: Why is the port random now?</strong></summary>
  <b>A:</b> Fresh installs choose a random high UDP port so every server does not expose the same fingerprint. You can set it manually: <code>--port=XXXXX</code> (any port 1024-65535).
</details>

<details>
  <summary><strong>Q: Is Perl required on the server?</strong></summary>
  <b>A:</b> Perl is used optionally for generating <code>vpn://</code> URIs (<code>.vpnuri</code> files). If Perl is absent, <code>.conf</code> files are still created normally — you can use them via file import or QR code. Perl is installed by default on Ubuntu and Debian.
</details>

<details>
  <summary><strong>Q: Is it safe to re-run the installer?</strong></summary>
  <b>A:</b> Yes. On re-run, the server config is recreated, but existing clients are automatically restored from backup. Default clients (<code>my_phone</code>, <code>my_laptop</code>) are recreated; all others are preserved.
</details>

> More answers and solutions in **[ADVANCED.en.md](ADVANCED.en.md)**.

---

<a id="troubleshooting"></a>
## 🛠️ Troubleshooting

1.  **Logs:** `/root/awg/install_amneziawg.log`, `/root/awg/manage_amneziawg.log`
2.  **Service status:** `sudo systemctl status awg-quick@awg0`
3.  **AmneziaWG status:** `sudo awg show`
4.  **UFW status:** `sudo ufw status verbose`
5.  **Diagnostic report:** `sudo bash ./install_amneziawg_en.sh --diagnostic`
    For a detailed breakdown of the report, see [ADVANCED.en.md](ADVANCED.en.md#diagnostic-report-adv).

---

<a id="ecosystem"></a>
## 🌐 Ecosystem

### Clients

> **Which client should I use?** Install [**Amnezia VPN**](https://github.com/amnezia-vpn/amnezia-client/releases) (>= 4.8.12.7) — works on all platforms, supports `vpn://` URI import.
> For a lightweight connection (`.conf` import only), use **AmneziaWG** for your platform.

| Client | Platform | AWG 2.0 | Type | Notes |
|--------|----------|:-------:|------|-------|
| **[Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases)** | Windows, macOS, Linux, Android, iOS | ✅ >= 4.8.12.7 | Official | **Recommended.** Full-featured, `vpn://` URI |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) | Windows | ✅ >= 2.0.0 | Official | Lightweight tunnel manager, `.conf` import |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-android) | Android | ✅ >= 2.0.0 | Official | Lightweight tunnel manager, `.conf` import |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | iOS | ✅ | Official | Lightweight tunnel manager, `.conf` import |
| [WG Tunnel](https://github.com/wgtunnel/android) | Android | ⚠️ partial | Third-party, FOSS | Auto-tunneling, split tunnel, F-Droid |
| [VeilBox](https://github.com/artem4150/VeilBox) | Windows, macOS | ✅ | Third-party, FOSS | Also supports VLESS |

> [Full compatibility table with AWG 1.x details →](ADVANCED.en.md#client-compat-adv)

### Configuration Tools

| Project | Description |
|---------|-------------|
| [Junker](https://spatiumstas.github.io/junker/) | AmneziaWG signature generator by @spatiumstas — for manual setup without an installer |
| [AmneziaWG-Architect](https://vadim-khristenko.github.io/AmneziaWG-Architect/) | CPS/mimicry generator UI for AWG 2.0 by @Vadim-Khristenko ([GitHub](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)) |

### Router Firmware

| Project | Platform | Description |
|---------|----------|-------------|
| [AWG Manager](https://github.com/hoaxisr/awg-manager) | Keenetic (Entware) | Web UI for managing AWG tunnels on Keenetic routers |
| [AmneziaWG for Merlin](https://github.com/r0otx/asuswrt-merlin-amneziawg) | ASUS (Asuswrt-Merlin) | AWG 2.0 addon with web UI, GeoIP/GeoSite routing |

<a id="featured-in"></a>
<details>
<summary><strong>📰 Featured in</strong></summary>

**📖 Tutorials & Guides**
- [Hetzner Community - Making a website accessible from restricted regions](https://community.hetzner.com/tutorials/making-website-accessible-from-restricted-regions) (cross-link in Resources)
- [Debian Forums — HowTo: Install AmneziaWG 2.0 on Debian 12/13](https://forums.debian.net/viewtopic.php?t=166105)
- [LowEndTalk - [Tutorial] One-command AmneziaWG VPN server install on Ubuntu / Debian / ARM](https://lowendtalk.com/discussion/217191)

**📰 Articles & Reviews**
- [XDA Developers — "I found a self-hosted VPN that works where WireGuard gets blocked"](https://www.xda-developers.com/self-hosted-vpn-works-where-wireguard-gets-blocked/)
- [Pinggy — Top 5 Best Self-Hosted VPNs in 2026](https://pinggy.io/blog/top_5_best_self_hosted_vpns/)
- [gHacks Tech News — AmneziaWG 2.0](https://www.ghacks.net/2026/03/25/amnezia-releases-amneziawg-2-0-to-bypass-advanced-internet-censorship-systems/)

**📋 Listings & Directories**
- [VPN Status (RU) — AmneziaWG services and server-side options catalog](https://vpnstatus.site/protocols/amneziawg)
- [AlternativeTo - amneziawg-installer (42 alternatives)](https://alternativeto.net/software/amneziawg-installer/about/)
- [LibHunt - #1 in Shell VPN category](https://www.libhunt.com/r/amneziawg-installer)

**💬 Forums & Communities**
- [Qubes OS Forum — AmneziaWG for censored regions](https://forum.qubes-os.org/t/installation-of-amnezia-vpn-and-amnezia-wg-effective-tools-against-internet-blocks-via-dpi-for-china-russia-belarus-turkmenistan-iran-vpn-with-vless-xray-reality-best-obfuscation-for-wireguard-easy-self-hosted-vpn-bypass/39005)
- [Lemmy.world /c/selfhosted - amneziawg-installer announce (143 upvotes / 39 comments)](https://lemmy.world/post/45242153)

</details>

---

<a id="license"></a>
## 📝 License & Author

* **Author:** @bivlked - [GitHub](https://github.com/bivlked)
* **License:** MIT — free and open-source (see `LICENSE`)

---

<p align="center">
  <a href="#top">↑ Back to top</a>
</p>
