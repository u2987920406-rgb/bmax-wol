#!/bin/bash
# 1) Autorise la mise en veille sans mot de passe (polkit) — pour raf-linux.
# 2) Installe une veille automatique après IDLE_MIN minutes d'inactivité,
#    protégée par un GARDE-FOU : jamais de veille si le GPU ou le shell GNOME ne
#    répondent plus. Une veille demandée sur une session figée ne se termine pas :
#    systemd-suspend sort en FAILURE, logind devient increvable (SIGKILL sans
#    effet) et PID 1 relance le cycle pendant des heures — CPU à fond, ventilateurs
#    au maximum, plus aucune session possible (SSH compris), aucun redémarrage à
#    distance. Constaté le 14/10/2026 sur ce Dell (voir README).
#    Machine non saine et inoccupée -> redémarrage automatique, plafonné à 3 par 24 h.
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
# Met en veille si la machine est reellement inutilisee ET saine.
#
# GARDE-FOU : trois controles avant toute veille. Le 14/10/2026, une veille
# demandee sur un GNOME figé (GPU en Xid 154) a echoue (systemd-suspend status=1),
# laisse logind increvable et fait boucler PID 1 pendant 9 h : 23 000 lignes de
# journal, CPU a fond, ventilateurs au maximum, plus aucune session (SSH compris).
# Machine non saine et inoccupee -> redemarrage automatique (un Xid 154 ne se
# repare que par un redemarrage), plafonne a 3 par 24 h puis alerte seule.
#
#   --check   n'agit pas, affiche le verdict (sante / busy / redemarrages_24h),
#             exit 1 si la machine n'est pas saine. Sert a verifier le garde-fou.
set -u
IDLE_MIN="${IDLE_MIN:-15}"
STAMP="${STAMP:-/run/dell-idle-since}"
UID_MACHINE="${UID_MACHINE:-1000}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"      # surchargeables : permettent de tester
JOURNALCTL="${JOURNALCTL:-journalctl}"      # le garde-fou sans toucher au materiel
SUSPEND_CMD="${SUSPEND_CMD:-systemctl suspend}"
TRACE_DIR="${TRACE_DIR:-/var/lib/dell-guard}"
AUTO_DIR="${AUTO_DIR:-$TRACE_DIR}"
AUTO_LOG="$AUTO_DIR/redemarrages.log"
REBOOT_CMD="${REBOOT_CMD:-systemctl reboot}"
MAX_REBOOTS="${MAX_REBOOTS:-3}"    # plafond de redemarrages sur 24 h, puis alerte seule
MIN_UPTIME="${MIN_UPTIME:-900}"    # pas de redemarrage dans les 15 premieres minutes
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say() { logger -t dell-idle-suspend "$*" 2>/dev/null; [ "$CHECK_ONLY" = "1" ] && echo "$*"; }

# ---------- 1. sante de la machine ----------
problems=""
# a) le pilote NVIDIA repond-il ?
if command -v "$NVIDIA_SMI" >/dev/null 2>&1; then
  timeout -s KILL 10 "$NVIDIA_SMI" -L >/dev/null 2>&1 || problems="$problems gpu_injoignable"
fi
# b) erreur GPU fatale depuis le demarrage ? (154/79/48/62 = redemarrage requis)
if "$JOURNALCTL" -k -b 0 --no-pager 2>/dev/null | grep -qE "Xid .*(154|79|48|62)"; then
  problems="$problems xid_fatal"
fi
# c) la session graphique repond-elle ? (shell GNOME muet = session figee)
if [ -S "/run/user/$UID_MACHINE/bus" ] && command -v gdbus >/dev/null 2>&1; then
  if XDG_RUNTIME_DIR="/run/user/$UID_MACHINE" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_MACHINE/bus" \
     timeout 5 gdbus call --session --dest org.freedesktop.DBus \
       --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
       org.gnome.Shell 2>/dev/null | grep -q true; then
    XDG_RUNTIME_DIR="/run/user/$UID_MACHINE" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_MACHINE/bus" \
    timeout 6 gdbus introspect --session --dest org.gnome.Shell \
      --object-path /org/gnome/Shell --only-properties >/dev/null 2>&1 \
      || problems="$problems shell_muet"
  fi
fi

# ---------- 2. machine reellement inutilisee ? ----------
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

if [ "$CHECK_ONLY" = "1" ]; then
  nb=$(cat "$AUTO_LOG" 2>/dev/null | wc -l)   # 0 si le fichier n'existe pas encore
  echo "sante=${problems:-ok} busy=$busy redemarrages_24h=$nb/$MAX_REBOOTS"
  [ -n "$problems" ] && exit 1 || exit 0
fi

if [ "$busy" = "1" ]; then
  rm -f "$STAMP"
  exit 0
fi

# ---------- 2 bis. garde-fou : machine non saine -> ni veille, ni attente passive ----------
if [ -n "$problems" ]; then
  rm -f "$STAMP"
  say "GARDE-FOU: veille ANNULEE ($problems) - machine non saine"
  mkdir -p "$TRACE_DIR" "$AUTO_DIR" 2>/dev/null
  echo "$(date -Is) veille annulee:${problems}" >> "$TRACE_DIR/historique.log" 2>/dev/null

  # Redemarrage automatique : un GPU en Xid 154 ne se repare QUE par un
  # redemarrage. Plafonne pour ne jamais boucler (3 par 24 h, puis alerte seule)
  # et jamais dans les 15 premieres minutes de vie de la machine.
  now=$(date +%s)
  touch "$AUTO_LOG" 2>/dev/null
  awk -v k=$(( now - 86400 )) '$1 >= k' "$AUTO_LOG" > "$AUTO_LOG.tmp" 2>/dev/null \
    && mv "$AUTO_LOG.tmp" "$AUTO_LOG"
  n=$(wc -l < "$AUTO_LOG" 2>/dev/null || echo 0)
  up=$(cut -d. -f1 /proc/uptime)
  if [ "$n" -ge "$MAX_REBOOTS" ]; then
    say "GARDE-FOU: plafond atteint ($n redemarrages/24 h) - alerte seule, plus de redemarrage"
    echo "$(date -Is) ALERTE plafond atteint ($problems)" >> "$TRACE_DIR/historique.log" 2>/dev/null
  elif [ "$up" -lt "$MIN_UPTIME" ]; then
    say "GARDE-FOU: redemarrage reporte (machine demarree depuis ${up}s < ${MIN_UPTIME}s)"
    echo "$(date -Is) redemarrage reporte (uptime ${up}s, $problems)" >> "$TRACE_DIR/historique.log" 2>/dev/null
  else
    say "GARDE-FOU: redemarrage automatique de la machine ($problems)"
    echo "$(date -Is) redemarrage automatique ($problems)" >> "$TRACE_DIR/historique.log" 2>/dev/null
    echo "$now" >> "$AUTO_LOG"
    $REBOOT_CMD
  fi
  exit 0
fi

# ---------- 3. veille si inactif depuis IDLE_MIN ----------
now=$(date +%s)
[ -f "$STAMP" ] || { echo "$now" > "$STAMP"; exit 0; }
since=$(cat "$STAMP" 2>/dev/null || echo "$now")
if [ $(( now - since )) -ge $(( IDLE_MIN * 60 )) ]; then
  rm -f "$STAMP"
  say "inactif depuis ${IDLE_MIN} min -> suspend"
  $SUSPEND_CMD
fi
EOF
chmod +x /usr/local/bin/dell-idle-suspend
mkdir -p /var/lib/dell-guard        # etat : historique des veilles annulees, compteur de redemarrages

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
ls -ld /var/lib/dell-guard
echo -n "test suspend (dry) : "
pkcheck --action-id org.freedesktop.login1.suspend --process $$ 2>&1 | head -2 || true
echo -n "garde-fou (--check) : "
/usr/local/bin/dell-idle-suspend --check || true