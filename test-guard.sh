#!/bin/bash
# Banc de test du garde-fou de veille du Dell (dell-idle-suspend).
# S'execute SUR le Dell, apres avoir copie sur /tmp : ce script, fixtures/*.sh et
# le script a tester. Depuis le BMAX :
#
#   cd ~/projets/bmax-wol
#   scp -q test-guard.sh fixtures/*.sh ~/.hermes/cache/scratch/dell-idle-suspend.sh dell:/tmp/
#   ssh dell 'bash /tmp/test-guard.sh'      # mot de passe sudo attendu sur stdin
#
# Chaque detection est prouvee par FICHIER MARQUEUR : aucune veille et aucun
# redemarrage reel ne partent, et jamais de grep du journal (les lignes de
# commande sont auditees et contiennent le marqueur cherche : faux positif).
# Les fichiers ecrits par root dans /tmp se manipulent avec sudo, sinon les
# nettoyages echouent (bit collant) et faussent les cas suivants.
PW=$(head -1)
S() { sudo -S -p "" "$@" <<<"$PW"; }
G=/tmp/dell-idle-suspend.sh
ok=0; ko=0
P() { echo "  PASS  $1"; ok=$((ok+1)); }
F() { echo "  FAIL  $1"; ko=$((ko+1)); }
has() { case "$1" in $2) P "$3";; *) F "$3 (obtenu '$1')";; esac; }
clean() { S rm -rf /tmp/guard-trace /tmp/guard-auto; S rm -f /tmp/suspend-marked /tmp/reboot-marked /tmp/stamp-test; }

mkdir -p /tmp/fakebin-gdbus /tmp/fakebin-idle
cp /tmp/gdbus-muet.sh /tmp/fakebin-gdbus/gdbus
cp /tmp/ss-vide.sh /tmp/fakebin-idle/ss
cp /tmp/loginctl-vide.sh /tmp/fakebin-idle/loginctl
cp /tmp/nvidia-smi-sain.sh /tmp/fakebin-idle/nvidia-smi
chmod +x /tmp/fakebin-gdbus/gdbus /tmp/fakebin-idle/* /tmp/fake-hang.sh /tmp/mark-suspend.sh /tmp/mark-reboot.sh $G
bad=0; for f in /tmp/fakebin-gdbus/gdbus /tmp/fakebin-idle/ss /tmp/fakebin-idle/nvidia-smi /tmp/fake-hang.sh /tmp/mark-suspend.sh /tmp/mark-reboot.sh $G; do test -x "$f" || { echo "  FI: $f non executable"; bad=1; }; done
[ "$bad" = 0 ] && P "toutes les fixtures sont executables" || F "fixture(s) non executable(s)"

common="PATH=/tmp/fakebin-idle:$PATH TRACE_DIR=/tmp/guard-trace AUTO_DIR=/tmp/guard-auto STAMP=/tmp/stamp-test IDLE_MIN=0 SUSPEND_CMD=/tmp/mark-suspend.sh REBOOT_CMD=/tmp/mark-reboot.sh"
clean

echo "== A. etat reel (--check) =="
r=$($G --check); echo "  $r"
has "$r" "sante=ok *redemarrages_24h=*" "machine reelle jugee saine, compteur affiche"

echo "== B. shell GNOME muet =="
r=$(PATH=/tmp/fakebin-gdbus:$PATH $G --check); rc=$?
has "$r" "sante= shell_muet*" "shell muet detecte"
[ "$rc" = 1 ] && P "code retour 1" || F "code retour $rc"

echo "== C. GPU injoignable =="
r=$(NVIDIA_SMI=/tmp/fake-hang.sh $G --check); rc=$?
has "$r" "sante= gpu_injoignable*" "GPU injoignable detecte"
[ "$rc" = 1 ] && P "code retour 1" || F "code retour $rc"

echo "== D. Xid fatal =="
r=$(JOURNALCTL=/tmp/fake-xid.sh $G --check); rc=$?
has "$r" "sante= xid_fatal*" "Xid fatal detecte"
[ "$rc" = 1 ] && P "code retour 1" || F "code retour $rc"

echo "== E. non saine + inoccupee -> aucune veille, redemarrage demande =="
S env $common NVIDIA_SMI=/tmp/fake-hang.sh MIN_UPTIME=0 $G
[ -f /tmp/suspend-marked ] && F "veille demandee malgre le garde-fou" || P "aucune veille demandee"
[ -s /tmp/reboot-marked ] && P "redemarrage demande : $(cat /tmp/reboot-marked)" || F "aucun redemarrage demande"
n=$(wc -l < /tmp/guard-auto/redemarrages.log 2>/dev/null || echo 0)
[ "$n" = 1 ] && P "compteur de redemarrages = 1" || F "compteur = $n (attendu 1)"
grep -q "redemarrage automatique" /tmp/guard-trace/historique.log && P "trace du redemarrage ecrite" || F "trace absente"

echo "== F. ANTI-REGRESSION : saine + inoccupee -> la veille part, pas de redemarrage =="
S rm -f /tmp/suspend-marked /tmp/reboot-marked /tmp/stamp-test
S env $common MIN_UPTIME=0 $G
S env $common MIN_UPTIME=0 $G
[ -s /tmp/suspend-marked ] && P "veille demandee quand tout va bien" || F "veille jamais demandee"
[ -f /tmp/reboot-marked ] && F "redemarrage demande alors que la machine est saine" || P "aucun redemarrage quand tout va bien"

echo "== G. PLAFOND : 3 redemarrages en 24 h -> alerte seule =="
S rm -f /tmp/reboot-marked; S mkdir -p /tmp/guard-auto
now=$(date +%s); printf '%s\n%s\n%s\n' $((now-3)) $((now-2)) $((now-1)) > /tmp/seed-auto
S cp /tmp/seed-auto /tmp/guard-auto/redemarrages.log
S env $common NVIDIA_SMI=/tmp/fake-hang.sh MIN_UPTIME=0 $G
[ -f /tmp/reboot-marked ] && F "redemarrage malgre le plafond" || P "plafond respecte (aucun redemarrage)"
grep -q "ALERTE plafond atteint" /tmp/guard-trace/historique.log && P "alerte tracee" || F "alerte non tracee"
n=$(wc -l < /tmp/guard-auto/redemarrages.log); [ "$n" = 3 ] && P "compteur inchange (3)" || F "compteur = $n"

echo "== H. REPORT : machine trop jeune -> pas de redemarrage =="
S rm -f /tmp/reboot-marked
S rm -f /tmp/guard-auto/redemarrages.log
S env $common NVIDIA_SMI=/tmp/fake-hang.sh MIN_UPTIME=999999 $G
[ -f /tmp/reboot-marked ] && F "redemarrage malgre la jeunesse de la machine" || P "redemarrage reporte (jeune machine)"
grep -q "redemarrage reporte" /tmp/guard-trace/historique.log && P "report trace" || F "report non trace"

echo "== I. une trace existe bien dans le dossier d'etat du VRAI deploiement =="
ls -ld /var/lib/dell-guard 2>/dev/null && P "/var/lib/dell-guard present" || F "/var/lib/dell-guard absent"

echo "TOTAL: $ok PASS / $ko FAIL"
[ "$ko" = 0 ]
