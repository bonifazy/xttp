#!/usr/bin/env bash
set -euo pipefail

# Только ROLE=relay. Тянет UUID магистрали с backbone и кладёт в .xttp_secrets.
# Если рабочий конфиг Xray уже есть — пересобирает его и рестартует.
# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

if [[ "$ROLE" != "relay" ]]; then
  echo "from_ru_relay_update_eu_uuid.sh только для ROLE=relay (сейчас: ${ROLE})"
  exit 1
fi

EU_UUID="$(fetch_eu_uuid)"
write_secrets
echo "EU_UUID=${EU_UUID}"

if [[ -f "$XRAY_CONFIG" ]]; then
  backup_if_exists "$XRAY_CONFIG" xray_eu_uuid.json
  write_xray_config
  restart_xray
  echo "xray config updated"
fi
