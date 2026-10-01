#!/bin/bash
# Réveille le Dell (Wake-on-LAN) depuis le BMAX.
# Usage: wol-dell.sh [-n] [-w secondes]
#   -n  n'envoie rien, montre juste ce qui serait fait (dry-run)
#   -w  attend que le Dell réponde en SSH (défaut: 0 = pas d'attente)
set -uo pipefail

DELL_MAC="${DELL_MAC:-34:17:eb:da:f2:27}"   # enp0s25
DELL_IP="${DELL_IP:-192.168.1.7}"
BROADCAST="${BROADCAST:-192.168.1.255}"
PORT="${PORT:-9}"
WAIT=0
DRY=0

while getopts "nw:" opt; do
  case $opt in
    n) DRY=1 ;;
    w) WAIT=$OPTARG ;;
    *) echo "usage: $0 [-n] [-w secondes]" >&2; exit 2 ;;
  esac
done

# --- magic packet : 6 x 0xFF + 16 x MAC ---
python3 - "$DELL_MAC" "$DELL_IP" "$BROADCAST" "$PORT" "$DRY" <<'PY'
import socket, sys
mac, ip, bcast, port, dry = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5] == "1"
raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
if len(raw) != 6:
    sys.exit("MAC invalide: " + mac)
pkt = b"\xff" * 6 + raw * 16
targets = [ip, bcast, "255.255.255.255"]
if dry:
    print(f"[dry-run] magic packet {len(pkt)} octets -> {mac} via {', '.join(targets)} udp/{port}")
    sys.exit(0)
for t in targets:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.sendto(pkt, (t, port))
    print(f"-> {t}:{port} ({len(pkt)} octets)")
print("magic packet envoyé")
PY
rc=$?
[ $rc -ne 0 ] && exit $rc
[ "$DRY" = "1" ] && exit 0

if [ "$WAIT" -gt 0 ]; then
  echo "attente du Dell (max ${WAIT}s)…"
  for i in $(seq 1 "$WAIT"); do
    if ssh -o ConnectTimeout=2 -o BatchMode=yes dell true 2>/dev/null; then
      echo "Dell en ligne après ${i}s"
      exit 0
    fi
    sleep 1
  done
  echo "Dell toujours injoignable après ${WAIT}s" >&2
  exit 1
fi
