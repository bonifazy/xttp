#!/usr/bin/env bash
#
# Перед ./main.sh:
#   1. .env из env_markup — ROLE и переменные для этой роли
#   2. Сертификаты в /tmp/fullchain.crt и /tmp/cert.key (или уже в SSL_DIR)
#   3. DNS DOMAIN_NAME смотрит на этот VPS
#   4. ROLE=relay: парный backbone уже отдаёт /$SUBS_PATH/update_subs_link
#      на EU_SERVER_PORT (часто 8443). IP этого relay есть в ALLOWED_IP на backbone
#
# Идемпотентно: .xttp_secrets не перезаписывает. Конфиги собирает заново.
set -euo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

echo ""
echo "ROLE: $ROLE"
echo "DOMAIN_NAME: $DOMAIN_NAME"
echo "SUBS_PATH: $SUBS_PATH"
echo "ALLOWED_IP: $ALLOWED_IP"
if [[ "$ROLE" == "relay" ]]; then
  echo "EU_SERVER_DOMAIN: $EU_SERVER_DOMAIN"
  echo "EU_SERVER_PORT: $EU_SERVER_PORT"
fi
if [[ "$ROLE" == "backbone" ]]; then
  echo "EU_SERVER_PORT: $EU_SERVER_PORT"
fi
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  echo "CLIENT_MODE: $CLIENT_MODE"
fi
echo ""

echo "Установка python3 curl"
wait_for_apt
sudo apt-get update
wait_for_apt
sudo apt-get install -y python3 curl ca-certificates
"$PYTHON" --version
echo ""

install_ssl_certs
echo ""

ensure_backup_dir
echo "Бекапы: $BACKUP_DIR"

if ! command -v ufw >/dev/null 2>&1; then
  wait_for_apt
  sudo apt-get install -y ufw
fi
apply_ufw
echo ""

if ! command -v nginx >/dev/null 2>&1; then
  echo "Установка Nginx"
  wait_for_apt
  sudo apt-get install -y nginx
fi
sudo systemctl unmask nginx
sudo systemctl enable nginx

sudo mkdir -p "/var/www/html/${SUBS_PATH}"
sudo cp "${SCRIPT_DIR}/index.html" "/var/www/html/index.html"
sudo chown -R "${PROJECT_USER}:www-data" /var/www/html/

if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  if ! command -v haproxy >/dev/null 2>&1; then
    echo "Установка HAProxy"
    wait_for_apt
    sudo apt-get install -y haproxy
  fi
  sudo systemctl unmask haproxy
  sudo systemctl enable haproxy
  backup_if_exists "$HAPROXY_CFG" haproxy.cfg
  install_haproxy_cert

  if ! command -v docker >/dev/null 2>&1; then
    echo "Установка Docker"
    wait_for_apt
    sudo apt-get install -y docker.io
    wait_for_apt
    sudo apt-get install -y docker-compose-v2 || sudo apt-get install -y docker-compose || true
  fi
  sudo systemctl enable --now docker
  searxng_up
  echo ""
else
  # ROLE=backbone: EU_SERVER_PORT — только Xray (fallbacks на nginx = подписка).
  # Предыдущая роль edge/relay могла оставить HAProxy enabled — глушим всегда.
  stop_haproxy_for_backbone
  searxng_stop
fi

if [[ ! -x /usr/local/bin/xray ]]; then
  echo "Xray не установлен. Начинаю установку..."
  echo ""
  curl -fsSL --retry 3 -o /tmp/xray-install.sh \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  if [[ -n "${XRAY_VER:-}" ]]; then
    sudo bash /tmp/xray-install.sh install -u nobody --version "$XRAY_VER"
  else
    sudo bash /tmp/xray-install.sh install -u nobody
  fi
  rm -f /tmp/xray-install.sh
  sudo xray version || sudo xray -version
else
  echo "пакет xray уже установлен"
  sudo xray version || sudo xray -version
fi
echo ""

echo "Загрузка geoip/geosite"
install_geodata
echo ""

ensure_secrets
echo "UUID: $UUID"
if [[ -n "${XHTTP_PATH:-}" ]]; then
  echo "XHTTP_PATH: $XHTTP_PATH"
fi

# ROLE=relay: EU_UUID с backbone ДО записи рабочего конфига Xray.
if [[ "$ROLE" == "relay" ]]; then
  echo ""
  EU_UUID="$(fetch_eu_uuid)"
  write_secrets
  echo "EU_UUID получен"
fi

backup_if_exists "$XRAY_CONFIG" xray_config.json

echo "Собираю конфиги"
write_nginx_config
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  write_haproxy_config
fi
write_xray_config "$UUID" "${XHTTP_PATH:-}" "${EU_UUID:-}"

echo "Тест Nginx"
sudo nginx -t
sudo systemctl restart nginx
sleep 1
sudo systemctl status nginx --no-pager
echo ""

if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  echo "Тест HAProxy"
  sudo haproxy -c -f "$HAPROXY_CFG"
  sudo systemctl unmask haproxy
  sudo systemctl enable haproxy
  sudo systemctl restart haproxy
  sleep 1
  sudo systemctl status haproxy --no-pager
  echo ""
else
  stop_haproxy_for_backbone
fi

echo "systemctl enable --now / restart xray"
sudo systemctl daemon-reload
sudo systemctl enable xray
restart_xray
sudo systemctl status xray --no-pager
echo ""
assert_role_frontends
echo ""

publish_link
sudo file "$LINK_FILE"
echo ""

chmod +x "${SCRIPT_DIR}/"*.sh

add_cron() {
  local line="$1"
  local marker="$2"
  local current
  current="$(sudo crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -qF "$marker"; then
    current="$(printf '%s\n' "$current" | grep -vF "$marker" || true)"
    echo "Cron обновлён: $marker"
  else
    echo "Добавлен sudo crontab:"
  fi
  printf '%s\n' "$current" "$line" | grep -v '^$' | sudo crontab -
  echo "$line"
}

add_cron "0 6 * * 1 ${SCRIPT_DIR}/update_geodata.sh" "update_geodata.sh"
add_cron "58 23 * * * truncate -s 0 /var/log/nginx/access.log /var/log/nginx/error.log /var/log/haproxy.log 2>/dev/null || true" "/var/log/nginx/access.log"
add_cron "59 23 * * * ${SCRIPT_DIR}/clear_xray_logs.sh" "clear_xray_logs.sh"

if [[ "$ROLE" == "edge" ]]; then
  current="$(sudo crontab -l 2>/dev/null || true)"
  current="$(printf '%s\n' "$current" \
    | grep -vF "change_uuid.sh" \
    | grep -vF "Ротация XTTP UUID для edge EU сервера" \
    | grep -v '^$' || true)"
  printf '%s\n' \
    "$current" \
    "# Ротация XTTP UUID для edge EU сервера" \
    "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid.sh" \
    | grep -v '^$' | sudo crontab -
  echo "Cron: change_uuid.sh (edge)"
  echo "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid.sh"
fi

echo "Файл подписки:"
echo "$LINK_FILE"
