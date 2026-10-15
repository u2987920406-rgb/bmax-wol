# bmax-wol — Dell en nœud GPU pilotable à distance

Scripts qui font du **Dell Precision Tower 5810** (Ubuntu Server 26.04, GTX 1080 Ti)
un nœud GPU qu'on allume, utilise et éteint depuis le **BMAX**, sans jamais toucher
au clavier du Dell.

## Cycle de vie

| Action | Commande (sur le BMAX) |
|---|---|
| Réveiller | `~/projets/bmax-wol/wol-dell.sh -w 120` |
| Éteindre | `~/projets/bmax-wol/poweroff-dell.sh` |

**Réveil** : envoie le magic packet (6×FF + 16×MAC) sur `192.168.1.7`,
`192.168.1.255` et `255.255.255.255`, port 9, puis attend la réponse.
Mesuré : **10-11 s** depuis une veille, **49 s** depuis un arrêt complet.

**Extinction** : `ssh dell 'sudo systemctl poweroff'` **ne marche pas** — polkit ne
considère jamais une session SSH (`Remote=yes`) comme « active », donc
`login1.power-off` (`auth_admin_keep`) exige une auth interactive. On passe par
`gnome-session-quit --power-off`, qui fait porter la demande par gnome-shell, dont
la session locale (seat0, `Active=yes`) est autorisée (`pkcheck` → rc 0).

**Attention — « pas de sudo » est faux au sens strict** : le Dell n'a pas de `sudo`
*sans mot de passe*, mais `sudo` fonctionne avec le mot de passe de `raf-linux`
(vérifié le 15/10/2026 : `printf '%s\n' "$MDP" | ssh dell 'sudo -S -k -p "" id'`
→ `uid=0`). Donc les voies root existent (`sudo systemctl reboot`), et c'est ce
qu'il faut tester **avant** de conclure « aucun redémarrage à distance possible ».

## Garde-fou de veille (incident du 14/10/2026)

Chaîne réelle de la panne, relevée dans le journal :

1. `Xid 154` sur la GTX 1080 Ti (« node reboot required ») → GNOME figé.
2. Une veille demandée sur cette session morte : `systemd-suspend.service` sort en
   **`status=1/FAILURE`** au bout de 4 min, les unités sont « thawed ».
3. `systemd-logind` ne meurt plus (`SIGKILL` sans effet) et PID 1 relance le cycle
   `State '*-sigterm' timed out. Killing.` **pendant 9 h** : 23 300 lignes de
   journal, CPU à fond, ventilateurs au maximum.
4. Plus aucune session ne peut s'ouvrir — **SSH compris** (sshd se bloque après
   l'authentification, dans `pam_systemd`) — et aucun redémarrage à distance.
   Seule issue : SysRq `REISUB` ou appui long sur le bouton.

`dell-idle-suspend` contrôle donc **trois choses avant toute veille** :

| Contrôle | Détection |
|---|---|
| `nvidia-smi -L` répond en moins de 10 s | `gpu_injoignable` |
| pas de `Xid 154/79/48/62` dans le noyau de ce boot | `xid_fatal` |
| `org.gnome.Shell` répond à une introspection D-Bus en moins de 6 s | `shell_muet` |

Machine non saine **et inoccupée** → la veille est annulée, une trace est écrite
dans `/var/lib/dell-guard/historique.log`, et la machine **redémarre d'elle-même**
(un `Xid 154` ne se répare que par un redémarrage). Garde-fous anti-boucle : jamais
de redémarrage dans les 15 premières minutes de vie de la machine, et **3 par 24 h
maximum** — au-delà, alerte seule dans l'historique.

Au moindre doute : `--check` n'agit pas, il rend le verdict.

```bash
/usr/local/bin/dell-idle-suspend --check
# sante=ok busy=1 redemarrages_24h=0/3   -> exit 0
# sante= gpu_injoignable busy=0 redemarrages_24h=0/3 -> exit 1
```

**Limite connue** : une connexion SSH établie compte comme « occupé », même si elle
est elle-même bloquée. Le garde-fou ne redémarrera donc pas la machine pendant une
intervention à distance — c'est voulu.

Banc de test : `test-guard.sh` + `fixtures/` — **20 PASS / 0 FAIL** le 15/10/2026
(les trois détections, le redémarrage, le plafond, le report, et la contre-épreuve
« la veille part quand tout va bien »). Tout est prouvé par fichiers marqueurs :
aucune veille et aucun redémarrage réels ne partent pendant les tests.

## Mise en place (une fois, avec `sudo` sur le Dell)

| Script | Rôle |
|---|---|
| `arm-wol-dell.sh` | active WoL de façon persistante (`wol-arm.service` + hook system-sleep) |
| `auto-suspend-dell.sh` | veille auto après 15 min d'inactivité (règle polkit + timer systemd) |

**BIOS** : `ErP/EuP` désactivé, `Wake on LAN` activé.

**Limite** : Tailscale ne réveille pas (pas de magic packet routé niveau IP). Le WoL
doit venir d'une machine du même /24 — le BMAX (`192.168.1.5`) convient.

## Détails complets

Vault : `11 Ressources/raf-dell — Fiche opérationnelle.md`
