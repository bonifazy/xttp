#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

install_geodata
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl restart xray
else
  sudo systemctl restart xray
fi
echo "geoip/geosite updated"
