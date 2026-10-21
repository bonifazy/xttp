#!/usr/bin/env bash
set -euo pipefail

# Меняет UUID и XHTTP_PATH (ссылка подписки). Hop EU_XHTTP_PATH на relay не трогает.
# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Нет .xttp_secrets: сначала запустите main.sh"
  exit 1
fi

UUID="$(generate_uuid)"
XHTTP_PATH="/$(generate_uuid)"
echo "Новый UUID: $UUID"
echo "Новый XHTTP_PATH: $XHTTP_PATH"

backup_if_exists "$XRAY_CONFIG" xray_uuid.json
backup_if_exists "$HAPROXY_CFG" haproxy.cfg
write_secrets
write_xray_config
write_haproxy_config
restart_xray
echo "Тест HAProxy"
sudo haproxy -c -f "$HAPROXY_CFG"
sudo systemctl restart haproxy
publish_link
echo "updated ok"
build_vless_link "$UUID"
