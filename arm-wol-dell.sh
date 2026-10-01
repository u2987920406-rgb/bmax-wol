#!/bin/bash
# Arme le Wake-on-LAN (BMAX -> Dell) de façon persistante.
# À lancer sur le Dell, avec sudo.
set -e
IF=enp0s25
CON=netplan-enp0s25

echo "== 1. NIC : activer wake-on magic =="
ethtool -s "$IF" wol g
ethtool "$IF" | grep -i "Wake-on" || true

echo "== 2. NetworkManager : rendre persistant =="
nmcli con mod "$CON" 802-3-ethernet.wake-on-lan magic
nmcli -f 802-3-ethernet.wake-on-lan con show "$CON"

echo "== 3. service systemd : réarmer à chaque démarrage =="
cat > /etc/systemd/system/wol-arm.service <<'EOF'
[Unit]
Description=Armer Wake-on-LAN sur enp0s25
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s enp0s25 wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wol-arm.service

echo "== 4. hook : réarmer après une mise en veille =="
cat > /usr/lib/systemd/system-sleep/wol-arm <<'EOF'
#!/bin/bash
case "$1" in
  pre|post) /usr/sbin/ethtool -s enp0s25 wol g ;;
esac
EOF
chmod +x /usr/lib/systemd/system-sleep/wol-arm

echo "== 5. ACPI : autoriser le réveil par le LAN =="
grep -qi "^LAN0.*\*disabled" /proc/acpi/wakeup && echo LAN0 > /proc/acpi/wakeup || true
grep -i "^LAN0" /proc/acpi/wakeup || true

echo
echo "=== ETAT FINAL ==="
ethtool enp0s25 | grep -i "Wake-on" || echo "Wake-on: ?"
nmcli -f 802-3-ethernet.wake-on-lan con show "$CON"
systemctl is-enabled wol-arm.service
cat /sys/class/net/enp0s25/device/power/wakeup
