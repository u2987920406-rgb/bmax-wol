#!/usr/bin/env bash
# Extinction à distance du Dell depuis le BMAX.
# Pourquoi pas `ssh dell 'sudo systemctl poweroff'` :
#   polkit ne considère JAMAIS une session SSH (Remote=yes) comme "active",
#   donc l'exception `implicit active: yes` ne s'applique pas -> auth_admin.
#   `gnome-session-quit` fait porter la demande par gnome-shell, dont la
#   session locale (seat0, Active=yes) est autorisée : pkcheck gnome-shell = rc 0.
# Précédent : arrêt complet confirmé 2026-10-01 07:29:32, réveil WoL en 49 s.
set -euo pipefail
HOST="${HOST:-dell}"
TIMEOUT="${1:-30}"

echo "-> extinction du Dell ($HOST)…"
ssh "$HOST" 'export XDG_RUNTIME_DIR=/run/user/1000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; gnome-session-quit --power-off --no-prompt'

echo "-> attente de l'extinction (max ${TIMEOUT}s)…"
for i in $(seq 1 "$TIMEOUT"); do
  if ! ping -c1 -W1 "$HOST" >/dev/null 2>&1; then
    echo "Dell éteint (plus de réponse réseau) après ${i}s"
    exit 0
  fi
  sleep 1
done
echo "ATTENTION : le Dell répond toujours après ${TIMEOUT}s" >&2
exit 1
