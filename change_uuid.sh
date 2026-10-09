#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Нет .xttp_secrets: сначала запустите main.sh"
  exit 1
fi

UUID="$(generate_uuid)"
echo "Новый UUID: $UUID"

backup_if_exists "$XRAY_CONFIG" xray_uuid.json
write_secrets
write_xray_config
restart_xray
publish_link
echo "updated ok"
build_vless_link "$UUID"
