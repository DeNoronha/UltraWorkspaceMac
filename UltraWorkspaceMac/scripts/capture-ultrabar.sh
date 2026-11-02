#!/bin/bash
# Capture network traffic of your own UltraBar X for analysis (owner use).
#
#   sudo scripts/capture-ultrabar.sh                 # Mac <-> CoreBar on your LAN (default host 192.168.50.54)
#   sudo scripts/capture-ultrabar.sh --host 10.0.0.5  # other CoreBar IP
#   sudo scripts/capture-ultrabar.sh --shared         # CoreBar connected to the Mac's Internet Sharing hotspot:
#                                                     # captures EVERYTHING the CoreBar sends (cloud, DNS, …)
#
# What you can and cannot see:
#   * LAN mode: only packets to/from this Mac (Wi-Fi is switched). TLS :7431 stays opaque
#     (Deckhand already logs that channel decrypted in wire.log); HTTP :8080 is readable.
#   * Shared mode: all CoreBar traffic flows through the Mac (bridge100) — hosts, DNS, SNI,
#     timings and sizes are visible; TLS payloads are not.
# Files rotate every 15 minutes into ~/Documents/DNC-captures/ (open with Wireshark).
set -euo pipefail
HOST="192.168.50.54"; MODE="lan"; IFACE=""
while [ $# -gt 0 ]; do case "$1" in
  --host) HOST="$2"; shift 2;; --shared) MODE="shared"; shift;; --iface) IFACE="$2"; shift 2;;
  *) echo "unknown arg $1"; exit 2;; esac; done
[ "$(id -u)" = 0 ] || { echo "run with sudo (tcpdump needs it)"; exit 1; }
OUT="$HOME/Documents/DNC-captures"; [ -n "${SUDO_USER:-}" ] && OUT="$(eval echo ~"$SUDO_USER")/Documents/DNC-captures"
mkdir -p "$OUT"
if [ "$MODE" = shared ]; then
  IFACE="${IFACE:-bridge100}"
  ifconfig "$IFACE" >/dev/null 2>&1 || { echo "no $IFACE — turn on System Settings → General → Sharing → Internet Sharing first, and join the CoreBar to that Wi-Fi"; exit 1; }
  FILTER="not port 5353 and not arp"
  echo "==> shared mode on $IFACE: everything the devices on the hotspot send"
else
  IFACE="${IFACE:-$(route -n get "$HOST" 2>/dev/null | awk '/interface/{print $2}')}"
  [ -n "$IFACE" ] || { echo "cannot determine interface towards $HOST"; exit 1; }
  FILTER="host $HOST"
  echo "==> LAN mode on $IFACE: packets between this Mac and $HOST"
fi
STAMP=$(date +%Y%m%d-%H%M%S)
echo "==> writing $OUT/ultrabar-$STAMP-*.pcap (rotating every 15 min). Ctrl-C to stop."
exec tcpdump -i "$IFACE" -nn -s 0 -U -G 900 -w "$OUT/ultrabar-$STAMP-%H%M.pcap" $FILTER
