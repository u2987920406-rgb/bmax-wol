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
