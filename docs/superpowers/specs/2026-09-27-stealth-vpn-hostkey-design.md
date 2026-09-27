# Stealth VPN Server & Architect Config Engine Specification

## 1. Executive Summary & Goals
Build and deploy a hardened, censorship-resistant VPN server on `hostkey` (`s1.charles.men` / `195.26.230.166`) specifically designed to defeat Russian TSPU (ТСПУ) active probing and protocol classification.

Key pillars:
1. **Network Topology & Anti-Active-Probing Layer:**
   - **UDP 443:** WireSock `amneziawg-proxy` acting as a stateful QUIC responder (`imitate_protocol = "quic"`, `quic_domain = "s1.charles.men"`), forwarding legitimate AmneziaWG sessions to the internal loopback.
   - **TCP 443:** Nginx reverse proxy with valid Let's Encrypt certificate for `s1.charles.men` and `Alt-Svc: h3=":443"; ma=86400`.
   - **Deep Nextcloud Camouflage:** Root `/` and standard paths serve an authentic Nextcloud Hub login portal with real static assets, Nextcloud HTTP response headers, and simulated API endpoints (`/status.php`, `/ocs/v1.php/cloud/capabilities`, etc.).
   - **Secret Web Panel Routing:** The management panel runs on `127.0.0.1:8443` and is exposed only via a secret URL prefix (e.g. `/hub-mgr-<secret>/`) or internal VPN interface.
2. **Core VPN & DNS Services:**
   - **AmneziaWG 2.0:** Bound to `127.0.0.1:51821` on interface `awg0` with subnet `10.88.88.0/24`.
   - **AdGuard Home:** Bound to `10.88.88.1:53` (UDP/TCP) inside the tunnel with DoH upstreams (Cloudflare, Quad9, AdGuard) and web dashboard at `10.88.88.1:3000`.
3. **Client Configuration Engine (Any-Tech-ARCHITECT Integration):**
   - **RFC 9000 QUIC Initial Generation:** `mkQUICi` CPS logic with authentic header forms, varints, and SNI padding.
   - **Anti-Collision Arithmetic:** Strictly enforces `avoidCollision` derived from message length offsets (`S2 != S1 + 56`, `S3 != S1 + 84`, `S3 != S2 + 28`).
   - **Router Compatibility Bounds:** Limits $H_1..H_4 < 2^{31}-1$ to eliminate integer overflow crashes on Keenetic and OpenWrt devices.
   - **Dual Syntax Support:** Includes native WireSock Windows hints (`#@ws:Id`, `#@ws:Ip`, `#@ws:Ib`) alongside standard AmneziaWG parameters.
   - **Smart Network Presets:**
     - **Mobile LTE/5G:** MTU 1280, Jc=2, Jmin=10, Jmax=40, compact S1/S2 padding, PersistentKeepalive 25.
     - **Home PC / Broadband:** MTU 1380, Jc=1..2, S1/S2 padding 30..60, PersistentKeepalive 35.
     - **Router (Keenetic / OpenWrt):** MTU 1360, H < 2^31-1, Jc=1, PersistentKeepalive 30.

---

## 2. Component Specifications

### 2.1 Network Topology & Port Map
| Protocol | Port | Service | Visibility | Behavior / Anti-DPI Role |
| :--- | :--- | :--- | :--- | :--- |
| **UDP** | 443 | WireSock `amneziawg-proxy` | Public | Inspects packets: forwards AWG packets to `127.0.0.1:51821`; replies to active probes with RFC 9000 QUIC Initial / Stateless Reset. |
| **UDP** | 51821 | AmneziaWG 2.0 (`awg0`) | Localhost only | Core VPN crypto and routing (`10.88.88.0/24`). |
| **TCP** | 443 | Nginx (HTTPS) | Public | Serves Let's Encrypt TLS for `s1.charles.men`. Root serves Nextcloud; secret path routes to web panel. |
| **TCP** | 80 | Nginx (HTTP) | Public | Redirects to HTTPS and answers ACME challenges. |
| **TCP** | 8443 | Python VPN Web Panel | Localhost only | Management API and UI. |
| **UDP/TCP** | 10.88.88.1:53 | AdGuard Home DNS | VPN Tunnel only | Ad-blocking DNS resolver with encrypted DoH upstreams. |
| **TCP** | 10.88.88.1:3000 | AdGuard Home UI | VPN Tunnel only | Admin panel for DNS query logs and filter management. |
| **TCP** | 22 | OpenSSH | Public | Hardened key-only SSH with UFW rate limiting. |

### 2.2 Nextcloud Camouflage Subsystem
To ensure TSPU and external scanners recognize the server as a legitimate Nextcloud deployment:
1. **Response Headers:**
   - `Alt-Svc: h3=":443"; ma=86400`
   - `X-Nextcloud-Version: 29.0.5`
   - `X-Powered-By: PHP/8.2.18`
   - `X-Content-Type-Options: nosniff`
   - `X-Frame-Options: SAMEORIGIN`
   - `X-Robots-Tag: none`
2. **Static Mock Assets:**
   - HTML login page styled with authentic Nextcloud CSS, SVG icons, and favicon.
3. **Simulated Endpoints:**
   - `/status.php`: Returns valid JSON:
     `{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"29.0.5.1","versionstring":"29.0.5","edition":"","productname":"Nextcloud","extendedSupport":false}`
   - `/ocs/v1.php/cloud/capabilities`: Returns standard XML capabilities payload.
   - `/login` & `/index.php/login`: Serves the login page.
   - `POST /login`: Returns HTTP `401 Unauthorized` with realistic authentication failure JSON and artificial delay.

### 2.3 WireSock Proxy Configuration
Location: `/etc/amneziawg-proxy/proxy.toml`
```toml
listen = "0.0.0.0:443"
backend = "127.0.0.1:51821"
imitate_protocol = "quic"
quic_handshake_enabled = true
quic_domain = "s1.charles.men"
session_ttl_secs = 300
cleanup_interval_secs = 60
max_sessions = 10000
status_file = "/var/lib/amneziawg-proxy/sessions.json"
status_interval_secs = 5
rate_limit_per_sec = 5
probe_reply_bytes_per_sec = 32768
awg_config = "/etc/amnezia/amneziawg/awg0.conf"
```

### 2.4 Client Configuration Generator & Smart Presets
The generator computes:
1. **CPS Tag (`I1`):** Formatted as `<b 0x...><rc N><c><t><r N>` adhering to RFC 9000 QUIC Initial with Connection IDs and Length varint covering the packet payload.
2. **WireSock Hints:**
   ```ini
   #@ws:Id = s1.charles.men
   #@ws:Ip = quic
   #@ws:Ib = curl
   ```
3. **Presets:**
   - **Mobile:** `MTU = 1280`, `Jc = 2`, `Jmin = 10`, `Jmax = 40`, `S1 = 20`, `S2 = 30`, `PersistentKeepalive = 25`.
   - **Desktop:** `MTU = 1380`, `Jc = 2`, `Jmin = 20`, `Jmax = 60`, `S1 = 40`, `S2 = 50`, `PersistentKeepalive = 35`.
   - **Router:** `MTU = 1360`, `Jc = 1`, `Jmin = 10`, `Jmax = 30`, `S1 = 25`, `S2 = 35`, `PersistentKeepalive = 30`.
   - `DNS = 10.88.88.1`.

---

## 3. Deployment & Execution Plan

1. **Host Preparation (`hostkey`):**
   - Clean slate: stop existing unneeded services, clear obsolete configurations while retaining `/etc/letsencrypt/live/s1.charles.men`.
   - Configure UFW: allow 22/tcp (limit), 80/tcp, 443/tcp, 443/udp.
2. **AmneziaWG 2.0 & WireSock Proxy Setup:**
   - Configure `/etc/amnezia/amneziawg/awg0.conf` on `127.0.0.1:51821`.
   - Build/install and configure `amneziawg-proxy` on `0.0.0.0:443 UDP`.
3. **AdGuard Home Setup:**
   - Install AdGuard Home into `/opt/AdGuardHome`, bind to `10.88.88.1:53` and `10.88.88.1:3000`.
4. **Nginx & Nextcloud Camouflage Setup:**
   - Author Nginx vhost with SSL, `Alt-Svc: h3`, static Nextcloud login page, `/status.php`, and secret web panel location.
5. **Web Panel & Generator Integration:**
   - Install Python web panel in `/root/awg/web/` listening on `127.0.0.1:8443`.
   - Integrate Any-Tech-ARCHITECT generation routines into `web/server.py` and preset buttons in `web/app.js`.
6. **Installer Repository Update & GitHub PR:**
   - Commit all scripts, configs, and generator additions into a new branch and submit a GitHub PR.
7. **Verification & End-to-End Validation:**
   - Test QUIC probe on UDP 443.
   - Test Nextcloud camouflage on TCP 443.
   - Generate test client config and verify handshake through proxy.
