# AmneziaWG 3.1 on home links: ports, filters, speed

Measurement notes from two home links in Russia. Providers are not named: "link A" is a wired gigabit line, "link B" a wired 500 Mbit/s line. Test node: 2 vCPU, AmneziaWG 3.1. Figures are **received Mbit/s** unless stated otherwise.

Treat these as observations, not guarantees: provider behaviour changes over time (one of the filters below was visible in one run and gone in the next).

## In short

1. **Plain traffic does not depend on the port; AWG is throttled adaptively per flow.** On link B plain TCP and plain UDP run at the line ceiling on every port (TCP down ~500, UDP ~550) and TCP never freezes. After accumulated load AWG on an ordinary port drops to 190-360 with +20-100 ms latency. A specific long-lived UDP flow (source port + destination port) is throttled: **changing the client's local (source) port restores 500+ immediately**. Ports such as 3478 and 4500 stay fast even under load.
2. **AWG parameters and mimicry do not get around the slowdown,** a different source port does. Jc, I1 (DNS, QUIC, STUN, SIP, TLS, random, none), padding, S, H, `RandomTrailers`, `DisableCookies` stay at the same 190-300 on a throttled flow.
3. **Link A polices only outgoing UDP:** about 28.7 Mbit/s per UDP flow and at most ~144 in total however many flows are used. Incoming UDP and all TCP are not limited. AWG gets ~37 up and 750-850 down.
4. **Path blocks** under sustained load towards one external address: short ones (about 20 s) and long ones (14-15 min), roughly once per 40-60 minutes of continuous testing.
5. **Download speed on a 2 vCPU node is bound by the node's CPU** (92% system), not by the link.

## Method

For every port number (both TCP and UDP, regardless of the protocol's usual transport) three measurements: plain TCP (connect success, flow "freeze" at 16 KB and 1 MB, down/up speed), plain UDP, and AWG over a live interface using the same port. The node redirects any test port to the real AWG port. 149 ports were checked (ViPNet, Kontinent, SIP/IMS, IKE/IPsec, RTP, STUN, VPN protocols, popular services) plus 10 never-used ones.

## Link B: ports and flow state

In the daytime and evening run (under accumulated load), class by the mean of min(up, down): fast >= 440, slow <= 360.

| Group | Ports | Fast | Slow |
|---|---|---|---|
| ViPNet | 12 | 1 | 9 |
| Kontinent | 21 | 4 | 16 |
| SIP/IMS/RTP/STUN/IKE | 34 | 9 | 21 |
| VPN protocols | 11 | 3 | 8 |
| Services | 28 | 11 | 11 |
| Other (high, "fresh") | 53 | 36 | 9 |

Consistently fast (A/B over three rounds and under load): 3478, 4500, 5000, 5104, 10000. Slow under load: 22, 80, 123, 443, 2046, 10092, 55777 and others. Of 10 "fresh" ports 6 were slow.

**But this is a flow state, not a permanent property of the port.** In the morning after idle the same ports (22, 123, 443) ran at 515-534; after every ~3 GB of load they degraded to 225-450. An alternating test then showed that on port 22 the default source port gave 285-403 while source ports 40000, 22222, 51820, 61000 gave 461-534, within minutes. Plain single-flow UDP runs at ~520 on the same ports, so it is the long-lived AWG flow that is throttled. Latency is higher on a throttled flow (a shaper queue).

## Link A: what is limited

| Traffic | Result |
|---|---|
| TCP down/up | 810 / 750 |
| Plain UDP down | 935 |
| Plain UDP up, 1 flow | **28.7** |
| Plain UDP up, 8 flows | 115 |
| Plain UDP up, 16+ flows | 144 (ceiling) |
| AWG up / down | 37 / 750-850 |

The port does not change this. The limit is 28.7 per flow with about five "buckets". To get around it you need several outer UDP flows (several ports/interfaces) or a TCP transport.

Also on link A: UDP 53 and 5060 do not get through at all; on UDP 80/443 only odd first bytes passed in one run and all bytes in another; the AWG handshake never completes on 5060 and is unreliable on 53/80/443 (retries of 4-8 s). IP protocols 241, 4, 132 and 41 are blocked, ESP/AH/GRE pass. On link B every protocol and port passes.

## AmneziaWG 3.1 parameters

- **Speed** does not depend on S1-S4, H1-H4, Jc, I1, padding or MTU 1200-1340 (within noise). MTU 1420 with padding up to 100 fragments (latency x3).
- **`RandomTrailers`**: with different S the upload collapses about 28x (15 vs 430); with equal S1=S2=S3=S4 it works. It removes the constant init packet size (148 + S1).
- **Accepted S values** in this module build: S1, S2 >= 14, S3 >= 9, S4 >= 5; the upper bounds from the documentation are not enforced.
- **Wire fingerprints**: the init packet has a constant size; without Jc it comes first; with padding 0 almost all packets share one size; the first byte is random (~50% even) and cannot be controlled by parameters.
- **Node load**: 2 vCPU saturate at ~800 Mbit/s down (encryption kworkers and iperf itself).

## Recommendations

- **Rotate the client's source (local) port periodically** (for AWG that is `ListenPort`, random on every start anyway): a new flow clears the adaptive throttle. Take the destination port from the fast pool (3478, 4500, 5000, 10000) and change it rarely.
- Avoid 53, 80, 443, 5060 (blocks/filters on different links). A fast port scan from one address triggers a path block of ~14 minutes by itself.
- Do not change parameters for speed; never set padding or Jc to 0; use `RandomTrailers` only with equal S (it requires re-importing clients, so decide before going to production).
- On links that police outgoing UDP per flow: several flows or a TCP transport.
- For speeds near a gigabit the node needs more than two cores.

## Not checked

Mobile networks, a real QUIC client, how long a new flow stays fast before it is throttled again. Results belong to one node and one period.
