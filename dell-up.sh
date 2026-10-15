#!/bin/bash
# Réveille le Dell et remet les services du socle en route.
# Usage: dell-up.sh [-w secondes]   (défaut 120)
# Le Dell n'a pas de sudo : le service ComfyUI est en "systemd --user" et ne
# redémarre pas seul après un reboot (linger désactivé). On le relance ici.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT=120
[ "${1:-}" = "-w" ] && WAIT="${2:-120}"

ssh -o ConnectTimeout=3 -o BatchMode=yes dell true 2>/dev/null || {
  echo "réveil du Dell…"
  "$HERE/wol-dell.sh" -w "$WAIT" || exit 1
}

echo "démarrage de comfyui.service…"
ssh dell 'systemctl --user start comfyui.service' 2>/dev/null

echo "attente du port 8188 (max 180 s)…"
for i in $(seq 1 36); do
  if ssh -o ConnectTimeout=3 dell 'ss -tln | grep -q 8188' 2>/dev/null; then
    echo "ComfyUI prêt — http://100.91.24.46:8188 (http://192.168.1.7:8188 sur le LAN)"
    exit 0
  fi
  sleep 5
done
echo "ComfyUI n'a pas ouvert le port 8188" >&2
exit 1
