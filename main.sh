#!/usr/bin/env bash
#
# Перед ./main.sh:
#   1. .env из env_markup — ROLE и переменные для этой роли
#   2. Сертификаты в /tmp/fullchain.crt и /tmp/cert.key (или уже в SSL_DIR)
#   3. DNS DOMAIN_NAME смотрит на этот VPS
#   4. ROLE=relay: в .env EU_SERVER_LINK = постоянная vless-ссылка backbone
#      (XHTTP packet-up). Если пусто — качаем /$SUBS_PATH/update_subs_link
#      (IP relay в ALLOWED_IP).
#
# Идемпотентно: .xttp_secrets не перезаписывает. Конфиги собирает заново.
# ROLE=relay/edge: клиентская ссылка — XHTTP stream-up + alpn=h2 (HAProxy proto h2).
# ROLE=backbone: ссылка для relay — XHTTP packet-up; снаружи HAProxy+SearXNG.
# Xray: готовый ELF из xray-core/xray-linux-* (сборка на Mac: ./build_xray_release.sh).
# Патч hello_frag внутри бинарника. С GitHub/Xray-install не качаем.
set -euo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

echo ""
echo "ROLE: $ROLE"
echo "DOMAIN_NAME: $DOMAIN_NAME"
echo "SUBS_PATH: $SUBS_PATH"
if [[ -n "$ALLOWED_IP" ]]; then
  echo "ALLOWED_IP: $ALLOWED_IP"
else
  echo "ALLOWED_IP: пусто (ufw from не пишем, подписка без ACL)"
fi
if [[ "$ROLE" == "relay" ]]; then
  if [[ -n "${EU_SERVER_LINK:-}" ]]; then
    echo "EU_SERVER_LINK: задана"
  fi
  echo "EU_SERVER_DOMAIN: $EU_SERVER_DOMAIN"
  echo "EU_SERVER_PORT: $EU_SERVER_PORT"
fi
if [[ "$ROLE" == "backbone" || "$ROLE" == "edge" ]]; then
  echo "EU_SERVER_PORT: $EU_SERVER_PORT"
fi
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  echo "CLIENT_MODE: $CLIENT_MODE"
fi
if [[ "$ROLE" == "relay" || "$ROLE" == "backbone" ]]; then
  echo "EU_XHTTP_MODE: $EU_XHTTP_MODE"
fi
if [[ "$ROLE" == "relay" ]]; then
  if [[ "$HELLO_FRAG" == "1" ]]; then
    echo "HELLO_FRAG: tlshello ${HELLO_FRAG_LENGTH} / ${HELLO_FRAG_INTERVAL}ms"
  else
    echo "HELLO_FRAG: выключен"
  fi
fi
echo ""

ensure_apt_packages python3 curl ca-certificates
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
grant_project_user_admins
searxng_up
echo ""

# Свой Xray из xray-core/xray-linux-* (hello_frag). Релизы XTLS не трогаем.
install_xray
echo ""

echo "Загрузка geoip/geosite"
install_geodata
echo ""

ensure_secrets
echo "UUID: $UUID"
if [[ -n "${XHTTP_PATH:-}" ]]; then
  echo "XHTTP_PATH: $XHTTP_PATH"
fi

# ROLE=relay: EU_UUID из EU_SERVER_LINK или с подписки backbone, ДО рабочего конфига.
if [[ "$ROLE" == "relay" ]]; then
  echo ""
  resolve_relay_eu_uuid
  write_secrets
  echo "EU_UUID: $EU_UUID"
  echo "EU outbound: ${EU_SERVER_DOMAIN}:${EU_SERVER_PORT} sni=${EU_SNI} path=${EU_XHTTP_PATH} mode=${EU_XHTTP_MODE}"
fi

backup_if_exists "$XRAY_CONFIG" xray_config.json

echo "Собираю конфиги"
write_nginx_config
echo "Пишу HAProxy"
write_haproxy_config
echo "Пишу Xray config"
write_xray_config "$UUID" "${XHTTP_PATH:-}" "${EU_UUID:-}"

echo "Тест Nginx"
sudo nginx -t
sudo systemctl restart nginx
sleep 1
sudo systemctl status nginx --no-pager
echo ""

# Xray раньше HAProxy: на старом backbone :EU_SERVER_PORT держал Xray (Vision).
echo "systemctl enable --now / restart xray"
sudo systemctl daemon-reload
sudo systemctl enable xray
restart_xray
sudo systemctl status xray --no-pager
echo ""

echo "Тест HAProxy"
sudo haproxy -c -f "$HAPROXY_CFG"
sudo systemctl unmask haproxy
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sleep 1
sudo systemctl status haproxy --no-pager
echo ""
assert_role_frontends
echo ""

publish_link
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

current="$(sudo crontab -l 2>/dev/null || true)"
current="$(printf '%s\n' "$current" \
  | grep -vF "change_uuid.sh" \
  | grep -vF "change_uuid_and_path.sh" \
  | grep -vF "Ротация XTTP UUID для edge EU сервера" \
  | grep -vF "Ротация UUID и XHTTP_PATH для edge EU сервера" \
  | grep -v '^$' || true)"
if [[ "$ROLE" == "edge" ]]; then
  printf '%s\n' \
    "$current" \
    "# Ротация UUID и XHTTP_PATH для edge EU сервера" \
    "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid_and_path.sh" \
    | grep -v '^$' | sudo crontab -
  echo "Cron: change_uuid_and_path.sh (edge: UUID + XHTTP_PATH)"
  echo "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid_and_path.sh"
else
  printf '%s\n' "$current" | grep -v '^$' | sudo crontab - || true
  echo "Cron: change_uuid_and_path.sh снят (ROLE=${ROLE}, ротации UUID/XHTTP_PATH нет)"
fi

subs_port=443
if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
  subs_port="$EU_SERVER_PORT"
fi
subs_url="$(https_url "$DOMAIN_NAME" "${SUBS_PATH}/update_subs_link" "$subs_port")"
echo "Файл подписки: $LINK_FILE"
echo "Ссылка:"
sudo cat "$LINK_FILE"
echo ""
echo "Тест с локального компьютера:"
echo "curl -fsS '${subs_url}'"
