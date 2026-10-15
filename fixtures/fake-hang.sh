#!/bin/bash
# simule un pilote NVIDIA qui ne repond plus : pend sur -L
for a in "$@"; do [ "$a" = "-L" ] && sleep 60; done
exit 0
