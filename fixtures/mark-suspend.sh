#!/bin/bash
# remplace systemctl suspend : trace au lieu d'endormir la machine
echo "VEILLE-DEMANDEE $(date -Is)" >> /tmp/suspend-marked
