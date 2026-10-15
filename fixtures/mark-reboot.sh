#!/bin/bash
# remplace systemctl reboot : trace au lieu de redemarrer la machine
echo "REDEMARRAGE-DEMANDE $(date -Is)" >> /tmp/reboot-marked
