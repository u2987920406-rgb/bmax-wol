#!/bin/bash
# 1) Autorise la mise en veille sans mot de passe (polkit) — pour raf-linux.
# 2) Installe une veille automatique après IDLE_MIN minutes d'inactivité.
# À lancer sur le Dell avec sudo.
set -e
IDLE_MIN="${IDLE_MIN:-15}"

echo "== 1. regle polkit =="
cat > /etc/polkit-1/rules.d/49-suspend-nopasswd.rules <<'EOF'
// Autorise raf-linux (et le groupe sudo) a suspendre sans authentification.
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.suspend" ||
         action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
         action.id == "org.freedesktop.login1.hibernate") &&
        (subject.user == "raf-linux" || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
EOF
systemctl restart polkit

echo "== 2. script de veille sur inactivite (${IDLE_MIN} min) =="
cat > /usr/local/bin/dell-idle-suspend <<'EOF'
#!/bin/bash
# Met en veille si la machine est reellement inutilisee.
set -u
IDLE_MIN="${IDLE_MIN:-15}"
STAMP=/run/dell-idle-since
UID_MACHINE=1000
busy=0

# SSH entrant actif ?
ss -tnH state established '( sport = :22 )' 2>/dev/null | grep -q . && busy=1

# Processus GPU en cours ?
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q '[0-9]' && busy=1
fi

# Session locale (clavier/souris) utilisee recemment ?
for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0"{print $1}'); do
  hint=$(loginctl show-session "$sid" -p IdleHint --value 2>/dev/null)
  [ "$hint" = "no" ] && busy=1
done

if [ "$busy" = "1" ]; then
  rm -f "$STAMP"
  exit 0
fi

now=$(date +%s)
[ -f "$STAMP" ] || { echo "$now" > "$STAMP"; exit 0; }
since=$(cat "$STAMP" 2>/dev/null || echo "$now")
if [ $(( now - since )) -ge $(( IDLE_MIN * 60 )) ]; then
  rm -f "$STAMP"
  logger -t dell-idle-suspend "inactif depuis ${IDLE_MIN} min -> suspend"
  systemctl suspend
fi
EOF
chmod +x /usr/local/bin/dell-idle-suspend

echo "== 3. timer systemd =="
cat > /etc/systemd/system/dell-idle-suspend.service <<'EOF'
[Unit]
Description=Veille automatique si inactif

[Service]
Type=oneshot
Environment=IDLE_MIN=15
ExecStart=/usr/local/bin/dell-idle-suspend
EOF
cat > /etc/systemd/system/dell-idle-suspend.timer <<'EOF'
[Unit]
Description=Verifie l'inactivite toutes les 2 min

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now dell-idle-suspend.timer

echo
echo "=== VERIFICATION ==="
systemctl is-enabled dell-idle-suspend.timer
systemctl is-active dell-idle-suspend.timer
ls -l /etc/polkit-1/rules.d/49-suspend-nopasswd.rules
echo -n "test suspend (dry) : "
pkcheck --action-id org.freedesktop.login1.suspend --process $$ 2>&1 | head -2 || true
