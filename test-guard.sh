#!/bin/bash
# Banc de test du garde-fou de veille du Dell (dell-idle-suspend).
# S'execute SUR le Dell, apres avoir copie sur /tmp : ce script, fixtures/*.sh et
# le script a tester. Depuis le BMAX :
#
#   cd ~/projets/bmax-wol
#   scp -q test-guard.sh fixtures/*.sh /tmp/dell-idle-suspend.sh dell:/tmp/
#   ssh dell 'bash /tmp/test-guard.sh'          # le mot de passe sudo arrive sur stdin
#
# Toutes les detections sont prouvees par FICHIERS MARQUEURS, jamais en laissant
# une vraie veille partir, et jamais par grep du journal (les lignes de commande
# sont auditees et polluent la recherche).
PW=$(head -1)
S() { sudo -S -p "" "$@" <<<"$PW"; }
G=/tmp/dell-idle-suspend.sh
ok=0; ko=0
P() { echo "  PASS  $1"; ok=$((ok+1)); }
F() { echo "  FAIL  $1"; ko=$((ko+1)); }

# --- fixtures, executables VERIFIES ---
mkdir -p /tmp/fakebin-gdbus /tmp/fakebin-idle
cp /tmp/gdbus-muet.sh        /tmp/fakebin-gdbus/gdbus
cp /tmp/ss-vide.sh           /tmp/fakebin-idle/ss
cp /tmp/loginctl-vide.sh     /tmp/fakebin-idle/loginctl
cp /tmp/fakebin-idle-nvidia.sh /tmp/fakebin-idle/nvidia-smi
chmod +x /tmp/fakebin-gdbus/gdbus /tmp/fakebin-idle/* /tmp/fake-hang.sh /tmp/mark-suspend.sh $G
echo "fixtures executables : $(for f in /tmp/fakebin-gdbus/gdbus /tmp/fakebin-idle/ss /tmp/fakebin-idle/nvidia-smi /tmp/fake-hang.sh /tmp/mark-suspend.sh $G; do test -x $f && echo -n "ok " || echo -n "KO:$f "; done)"
echo "fixture GPU qui pend doit echouer : "; timeout -s KILL 3 /tmp/fake-hang.sh -L; echo "  rc timeout=$?"
echo "environnement REEl : $(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader | head -3 | tr '\n' ' ')"
rm -f /tmp/suspend-marked; rm -rf /tmp/guard-trace /tmp/stamp-test

echo "== A. etat reel =="
r=$($G --check); echo "  $r"
case "$r" in "sante=ok "*) P "machine reelle jugee saine";; *) F "machine reelle";; esac

echo "== B. shell GNOME muet =="
r=$(PATH=/tmp/fakebin-gdbus:$PATH $G --check); rc=$?
[ "$r" = "sante= shell_muet busy=1" ] && P "shell muet detecte ($r)" || F "attendu 'sante= shell_muet busy=1', obtenu '$r'"
[ "$rc" = "1" ] && P "code retour 1" || F "code retour $rc au lieu de 1"

echo "== C. GPU injoignable =="
r=$(NVIDIA_SMI=/tmp/fake-hang.sh $G --check); rc=$?
[ "$r" = "sante= gpu_injoignable busy=1" ] && P "GPU injoignable detecte ($r)" || F "obtenu '$r'"
[ "$rc" = "1" ] && P "code retour 1" || F "code retour $rc"

echo "== D. Xid fatal =="
r=$(JOURNALCTL=/tmp/fake-xid.sh $G --check); rc=$?
[ "$r" = "sante= xid_fatal busy=1" ] && P "Xid fatal detecte ($r)" || F "obtenu '$r'"
[ "$rc" = "1" ] && P "code retour 1" || F "code retour $rc"

echo "== E. ACTION : machine vue inoccupee + GPU injoignable -> aucune veille =="
S env PATH=/tmp/fakebin-idle:$PATH NVIDIA_SMI=/tmp/fake-hang.sh \
     TRACE_DIR=/tmp/guard-trace STAMP=/tmp/stamp-test IDLE_MIN=0 \
     SUSPEND_CMD=/tmp/mark-suspend.sh $G
echo "  execution terminee (rc=$?)"
[ -s /tmp/guard-trace/historique.log ] && P "trace ecrite : $(cat /tmp/guard-trace/historique.log)" || F "aucune trace ecrite"
[ -f /tmp/suspend-marked ] && F "veille DEMANDEE malgre le garde-fou" || P "aucune veille demandee"

echo "== F. ANTI-REGRESSION : machine inoccupee et saine -> la veille part =="
S env PATH=/tmp/fakebin-idle:$PATH TRACE_DIR=/tmp/guard-trace STAMP=/tmp/stamp-test IDLE_MIN=0 SUSPEND_CMD=/tmp/mark-suspend.sh $G
S env PATH=/tmp/fakebin-idle:$PATH TRACE_DIR=/tmp/guard-trace STAMP=/tmp/stamp-test IDLE_MIN=0 SUSPEND_CMD=/tmp/mark-suspend.sh $G
[ -s /tmp/suspend-marked ] && P "veille demandee quand tout va bien : $(cat /tmp/suspend-marked)" || F "veille jamais demandee alors que la machine est saine"
[ -f /tmp/guard-trace/historique.log ] && echo "  (note: trace presente aussi en F)"; 
echo "TOTAL: $ok PASS / $ko FAIL"
[ "$ko" = "0" ]