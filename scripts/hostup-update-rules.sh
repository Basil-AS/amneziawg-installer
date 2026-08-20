#!/usr/bin/env bash
# Refresh HostUp's custom IPv4 P2P forwarding without embedding the server IP.
# The script intentionally does not invent public IPv6 addresses for AWG peers:
# HostUp currently exposes a public IPv6 on eth0, while its client subnet is ULA.
set -euo pipefail

MANAGEMENT_DIR="${MANAGEMENT_DIR:-/root/amnezia_management}"
PORTS_FILE="${PORTS_FILE:-$MANAGEMENT_DIR/client_ports.json}"
PUBLIC_IFACE="${PUBLIC_IFACE:-eth0}"
PUBLIC_IPV4="${PUBLIC_IPV4:-$(ip -4 -o addr show dev "$PUBLIC_IFACE" scope global | awk 'NR == 1 { split($4, a, "/"); print a[1] }')}"

[[ "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "Unable to determine a global IPv4 address on $PUBLIC_IFACE" >&2
    exit 1
}
[[ -f "$PORTS_FILE" ]] || { echo "Missing $PORTS_FILE" >&2; exit 1; }

echo "Applying P2P rules for $PUBLIC_IPV4..."
iptables -t nat -F PREROUTING

if ! iptables -t nat -C POSTROUTING -o "$PUBLIC_IFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$PUBLIC_IFACE" -j MASQUERADE
fi

while IFS=$'\t' read -r client_ipv4 p2p_port; do
    [[ "$client_ipv4" =~ ^10\.10\. ]] || continue
    [[ "$p2p_port" =~ ^[0-9]+$ ]] || continue
    iptables -t nat -A PREROUTING -i "$PUBLIC_IFACE" -p udp --dport "$p2p_port" -j DNAT --to-destination "$client_ipv4"
    iptables -t nat -I POSTROUTING 1 -s "$client_ipv4" -p udp -j SNAT --to-source "$PUBLIC_IPV4:$p2p_port"
done < <(python3 - "$PORTS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    clients = json.load(handle)
for data in clients.values():
    if isinstance(data, dict):
        print(f"{data.get('ipv4', '')}\t{data.get('p2p_port', '')}")
PY
)

ip6tables-save > /etc/iptables/rules.v6
iptables-save > /etc/iptables/rules.v4
echo "P2P rules applied successfully."
