#!/usr/bin/env bash
#
# Перед ./main.sh:
#   1. .env из env_markup — ROLE и переменные для этой роли
#   2. Сертификаты: /tmp/{fullchain.crt,cert.key} (купленный wildcard) или
#      Let's Encrypt на DOMAIN_NAME (ACME_EMAIL в .env, автообновление)
#   3. DNS DOMAIN_NAME смотрит на этот VPS
#   4. ROLE=relay: EU_SERVER_LINK = постоянная vless-ссылка backbone
#      (XHTTP packet-up). SUBS_PATH из secrets; новый только если пусто.
#
# Идемпотентно: .xttp_secrets не перезаписывает. Конфиги собирает заново.
# ROLE=relay/edge: клиентская ссылка — XHTTP stream-up; downloadSettings использует TCP второй порт или HTTP/3.
# ROLE=backbone: ссылка для relay — XHTTP packet-up; снаружи HAProxy+SearXNG.
# Xray: готовый ELF из xray-core/xray-linux-* (сборка на Mac: ./build_xray_release.sh).
# Патч hello_frag внутри бинарника. С GitHub/Xray-install не качаем.
set -euo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

if [[ -z "${SUBS_PATH:-}" ]]; then
  SUBS_PATH="$(generate_subs_path)"
  echo "SUBS_PATH: $SUBS_PATH (новый)"
else
  echo "SUBS_PATH: $SUBS_PATH (из secrets)"
fi
LINK_FILE="/var/www/html/${SUBS_PATH}/update_subs_link"

echo ""
echo "ROLE: $ROLE"
echo "DOMAIN_NAME: $DOMAIN_NAME"
echo "CERT_DOMAIN: $CERT_DOMAIN"
echo "SSL_DIR: $SSL_DIR"
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
echo "CLIENT_PORT: $CLIENT_PORT"
echo "WARP_ENABLED: ${WARP_ENABLED}"
if [[ "$WARP_ENABLED" == "1" ]]; then
  echo "WARP_DOMAINS: ${WARP_DOMAINS}"
fi
if [[ "$CDN_ENABLED" == "1" ]]; then
  echo "CDN: HTTP origin :${CDN_ORIGIN_PORT}, uplink=${CDN_UPLINK_HTTP_METHOD}/${CDN_UPLINK_DATA_PLACEMENT} (${CDN_UPLINK_CHUNK_SIZE} B)"
fi
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  echo "DOWNLOAD_PORT: ${DOWNLOAD_LISTEN:-0}"
  echo "XHTTP_H3_DOWNLOAD: ${XHTTP_H3_DOWNLOAD}"
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
  echo "AdGuard via EU: 127.0.0.1:${ADGUARD_VIA_EU_PORT} → ${ADGUARD_VIA_EU_DEST}:53"
fi
echo "AdGuard DNS: ${ADGUARD_DNS_ADDR}:${ADGUARD_DNS_PORT}  UI: http://${ADGUARD_UI_ADDR}"
echo "AdGuard cache: ${ADGUARD_CACHE_SIZE} B, ttl_min=${ADGUARD_CACHE_TTL_MIN}s ttl_max=${ADGUARD_CACHE_TTL_MAX}"
echo ""

ensure_apt_packages python3 curl ca-certificates
"$PYTHON" --version
echo ""

if [[ "$CDN_ENABLED" == "1" ]]; then
  echo "CDN_ENABLED=1: TLS завершается на CDN; сертификат на VPS не требуется"
else
  install_ssl_certs
  echo ""
fi

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
sudo rm -f /var/www/html/index.html
sudo chown -R "${PROJECT_USER}:www-data" /var/www/html/

if ! command -v haproxy >/dev/null 2>&1; then
  echo "Установка HAProxy"
  wait_for_apt
  sudo apt-get install -y haproxy
fi
sudo systemctl unmask haproxy
sudo systemctl enable haproxy
backup_if_exists "$HAPROXY_CFG" haproxy.cfg
if [[ "$CDN_ENABLED" != "1" ]]; then
  install_haproxy_cert
fi

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
adguard_up
echo ""

# Свой Xray из xray-core/xray-linux-* (hello_frag). Релизы XTLS не трогаем.
install_xray
echo ""

echo "Загрузка geoip/geosite"
install_geodata
echo ""

ensure_secrets
write_secrets
LINK_FILE="/var/www/html/${SUBS_PATH}/update_subs_link"
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

chmod +x "${SCRIPT_DIR}/"*.sh
publish_link
echo ""

# SIGHUP от оборванного SSH (туннель через этот же xray) не должен резать main.sh.
trap '' HUP
echo "Тест Nginx"
sudo nginx -t
sudo systemctl restart nginx
sleep 1
sudo systemctl status nginx --no-pager
echo ""

echo "Тест HAProxy"
sudo haproxy -c -f "$HAPROXY_CFG"
sudo systemctl unmask haproxy
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sleep 1
sudo systemctl status haproxy --no-pager
echo ""

# Xray последним: restart рвёт клиентские сессии и SSH, если он идёт через этот узел.
echo "systemctl enable --now / restart xray"
sudo systemctl daemon-reload
sudo systemctl enable xray
restart_xray
sudo systemctl status xray --no-pager
echo ""

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

# До assert: иначе падение проверки оставляет crontab пустым.
add_cron "0 6 * * 1 ${SCRIPT_DIR}/update_geodata.sh" "update_geodata.sh"
add_cron "58 23 * * * truncate -s 0 /var/log/nginx/access.log /var/log/nginx/error.log /var/log/haproxy.log 2>/dev/null || true" "/var/log/nginx/access.log"
add_cron "59 23 * * * ${SCRIPT_DIR}/clear_xray_logs.sh" "clear_xray_logs.sh"

current="$(sudo crontab -l 2>/dev/null || true)"
current="$(printf '%s\n' "$current" \
  | grep -vF "change_uuid.sh" \
  | grep -vF "change_uuid_and_path.sh" \
  | grep -vF "Ротация XTTP UUID для edge EU сервера" \
  | grep -vF "Ротация UUID и XHTTP_PATH для edge EU сервера" \
  | grep -vF "Ротация UUID и XHTTP_PATH (клиентская ссылка)" \
  | grep -v '^$' || true)"
# relay и edge — клиентская ссылка. backbone: hop в EU_SERVER_LINK, не ротируем.
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  rot_comment="# Ротация UUID и XHTTP_PATH (клиентская ссылка)"
  printf '%s\n' \
    "$current" \
    "$rot_comment" \
    "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid_and_path.sh" \
    | grep -v '^$' | sudo crontab -
  echo "Cron: change_uuid_and_path.sh (${ROLE}: UUID + XHTTP_PATH)"
  echo "1 0 3,7,13,17,23,27 * * ${SCRIPT_DIR}/change_uuid_and_path.sh"
else
  printf '%s\n' "$current" | grep -v '^$' | sudo crontab - || true
  echo "Cron: change_uuid_and_path.sh снят (ROLE=${ROLE}, hop не ротируем)"
fi

assert_role_frontends
echo ""

subs_url="$(https_url "$DOMAIN_NAME" "${SUBS_PATH}/update_subs_link" "$CLIENT_PORT")"
echo "Файл подписки: $LINK_FILE"
echo "Ссылка:"
sudo cat "$LINK_FILE"
echo ""
echo "Тест с локального компьютера:"
echo "curl -fsS '${subs_url}'"
echo ""
assert_adguard_dns_split
