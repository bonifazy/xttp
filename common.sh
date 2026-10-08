#!/usr/bin/env bash
#
# Общая библиотека xttp. Её source-ят main.sh, change_uuid.sh,
# from_ru_relay_update_eu_uuid.sh, update_geodata.sh.
# Проект всегда в /home/dim/xttp.

SCRIPT_DIR="/home/dim/xttp"
cd "$SCRIPT_DIR" || return 1
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  echo "Нет файла .env. Скопируйте env_markup -> .env и заполните переменные."
  exit 1
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"

PROJECT_USER="${PROJECT_USER:-dim}"
BACKUP_DIR="${BACKUP_DIR:-/home/${PROJECT_USER}/backup}"
SSL_DIR="${SSL_DIR:-/etc/ssl/nerabotaet.com}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
GEODATA_DIR="${GEODATA_DIR:-/usr/local/share/xray}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
HAPROXY_CERT="${HAPROXY_CERT:-/etc/haproxy/certs/nerabotaet.com.pem}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/default}"
SEARXNG_DIR="${SCRIPT_DIR}/searxng"
SECRETS_FILE="${SCRIPT_DIR}/.xttp_secrets"
PYTHON="${PYTHON:-python3}"

# Константы. В .env не объявляются.
EU_SERVER_PORT=443
EU_FLOW="xtls-rprx-vision"
XHTTP_MODE="auto"
XRAY_XHTTP_LISTEN="127.0.0.1"
XRAY_XHTTP_PORT=10085
NGINX_FALLBACK="127.0.0.1:8081"
DECOY_ADDR="127.0.0.1:8888"
XRAY_USER="${XRAY_USER:-nobody}"
XRAY_GROUP="${XRAY_GROUP:-nogroup}"

LINK_FILE="${LINK_FILE:-/var/www/html/${SUBS_PATH:-}/update_subs_link}"

ROLE="${ROLE:-edge}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
SUBS_PATH="${SUBS_PATH:-}"
ALLOWED_IP="${ALLOWED_IP:-}"
EU_SERVER_DOMAIN="${EU_SERVER_DOMAIN:-}"
CLIENT_MODE="${CLIENT_MODE:-packet-up}"
EU_SNI="${EU_SERVER_DOMAIN}"

if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
fi

_die() {
  echo "$*" >&2
  exit 1
}

case "$ROLE" in
  relay|edge|backbone) ;;
  *) _die "ROLE должен быть relay, edge или backbone. Сейчас: '${ROLE}'" ;;
esac

if [[ -z "$DOMAIN_NAME" || -z "$SUBS_PATH" || -z "$ALLOWED_IP" ]]; then
  _die "В .env пусты DOMAIN_NAME, SUBS_PATH или ALLOWED_IP"
fi

if [[ "$ROLE" == "relay" && -z "$EU_SERVER_DOMAIN" ]]; then
  _die "ROLE=relay требует EU_SERVER_DOMAIN в .env"
fi

if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  case "$CLIENT_MODE" in
    packet-up|stream-up|auto) ;;
    *) _die "CLIENT_MODE: packet-up, stream-up или auto. Сейчас: '${CLIENT_MODE}'" ;;
  esac
fi

# Список IP из ALLOWED_IP. "*" — открыть всем.
allowed_ips_list() {
  if [[ "$ALLOWED_IP" == "*" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  printf '%s\n' $ALLOWED_IP
}

chown_project_user() {
  local path="$1"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${PROJECT_USER}:${PROJECT_USER}" "$path"
  elif [[ "$(id -un)" != "$PROJECT_USER" ]]; then
    sudo chown "${PROJECT_USER}:${PROJECT_USER}" "$path"
  fi
}

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 750 "$BACKUP_DIR"
  chown_project_user "$BACKUP_DIR"
}

write_backup() {
  local src="$1"
  local name="$2"
  ensure_backup_dir
  local dest="${BACKUP_DIR}/${name}_$(date +%F_%H%M%S)"
  cp "$src" "$dest"
  chmod 640 "$dest"
  chown_project_user "$dest"
  echo "Бекап: $dest"
}

backup_if_exists() {
  local src="$1"
  local name="$2"
  if [[ -f "$src" ]]; then
    local tmp
    tmp="$(mktemp)"
    if [[ -r "$src" ]]; then
      cp "$src" "$tmp"
    else
      sudo cat "$src" | tee "$tmp" >/dev/null
    fi
    write_backup "$tmp" "$name"
    rm -f "$tmp"
  fi
}

generate_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
  elif [[ -x /usr/local/bin/xray ]]; then
    /usr/local/bin/xray uuid
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen
  fi
}

# Пишет .xttp_secrets текущими UUID / XHTTP_PATH / EU_UUID.
# umask 077 + chmod 600 + dim:dim, даже если пишет root из cron.
write_secrets() {
  umask 077
  {
    printf 'UUID=%s\n' "${UUID:-}"
    if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
      printf 'XHTTP_PATH=%s\n' "${XHTTP_PATH:-}"
    fi
    if [[ "$ROLE" == "relay" ]]; then
      printf 'EU_UUID=%s\n' "${EU_UUID:-}"
    fi
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  chown_project_user "$SECRETS_FILE"
}

# Первый запуск: UUID и (для relay/edge) XHTTP_PATH. Повторный — только читает.
ensure_secrets() {
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Нет .xttp_secrets — генерирую UUID"
    UUID="$(generate_uuid)"
    if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
      XHTTP_PATH="/$(generate_uuid)"
      echo "XHTTP_PATH сгенерирован"
    fi
    write_secrets
    return 0
  fi
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
  if [[ -z "${UUID:-}" ]]; then
    _die "В .xttp_secrets нет UUID"
  fi
  if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
    if [[ -z "${XHTTP_PATH:-}" ]]; then
      XHTTP_PATH="/$(generate_uuid)"
      echo "В .xttp_secrets не было XHTTP_PATH — сгенерирован"
      write_secrets
    fi
  fi
}

# Собирает ссылку подписки. Хост — DOMAIN_NAME этого сервера.
# relay/edge: vless+xhttp+tls. backbone: vless+tcp+tls+vision (для relay).
build_vless_link() {
  local uuid="${1:-$UUID}"
  if [[ -z "$uuid" ]]; then
    echo "build_vless_link: нет UUID" >&2
    return 1
  fi
  if [[ "$ROLE" == "backbone" ]]; then
    printf 'vless://%s@%s:443?type=tcp&encryption=none&flow=%s&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1\n' \
      "$uuid" "$DOMAIN_NAME" "$EU_FLOW" "$DOMAIN_NAME"
    return 0
  fi
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    echo "build_vless_link: нет XHTTP_PATH" >&2
    return 1
  fi
  "$PYTHON" - "$uuid" "$DOMAIN_NAME" "$XHTTP_PATH" "$CLIENT_MODE" <<'PY'
import sys
from urllib.parse import quote
uuid, host, path, mode = sys.argv[1:]
enc_path = quote(path, safe="")
print(
    f"vless://{uuid}@{host}:443?encryption=none&security=tls"
    f"&sni={host}&fp=chrome&alpn=h2&type=xhttp"
    f"&path={enc_path}&mode={mode}"
)
PY
}

parse_vless_uuid() {
  local link="$1"
  local rest uuid
  rest="${link#*vless://}"
  uuid="${rest%%@*}"
  if [[ -z "$uuid" || "$uuid" == "$link" || "$uuid" == "$rest" ]]; then
    echo "не удалось разобрать UUID из vless-ссылки" >&2
    return 1
  fi
  printf '%s\n' "$uuid"
}

# Качает подписку с backbone. Пишет UUID в stdout. При ошибке — подробности в stderr.
fetch_eu_uuid() {
  local url code tmp link uuid
  url="https://${EU_SERVER_DOMAIN}/${SUBS_PATH}/update_subs_link"
  tmp="$(mktemp)"
  echo "Запрос EU_UUID: $url" >&2
  code="$(curl -4sS -o "$tmp" -w '%{http_code}' --retry 3 --retry-delay 2 --max-time 20 "$url" || true)"
  link="$(tr -d '\r\n ' < "$tmp")"
  rm -f "$tmp"
  if [[ "$code" != "200" ]] || [[ "$link" != vless://* ]]; then
    echo "Не удалось получить EU_UUID с ${url}" >&2
    echo "curl: HTTP ${code:-error}" >&2
    if [[ -n "$link" ]]; then
      echo "ответ: ${link:0:200}" >&2
    fi
    echo "Проверьте: backbone запущен, DNS ${EU_SERVER_DOMAIN} смотрит на него," >&2
    echo "IP этого relay есть в ALLOWED_IP на backbone." >&2
    return 1
  fi
  uuid="$(parse_vless_uuid "$link")" || return 1
  printf '%s\n' "$uuid"
}

apply_ufw() {
  local ip
  if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
    sudo ufw allow 80/tcp comment "HTTP redirect"
    sudo ufw allow 443/tcp comment "HTTPS"
  elif [[ "$ALLOWED_IP" == "*" ]]; then
    sudo ufw allow 443/tcp comment "HTTPS"
  fi
  if [[ "$ALLOWED_IP" != "*" ]]; then
    while read -r ip; do
      [[ -z "$ip" ]] && continue
      sudo ufw allow from "$ip" comment "All from allowed_ip"
    done < <(allowed_ips_list)
  fi
}

install_geodata() {
  local tmp
  tmp="$(mktemp -d)"
  echo "curl geoip.dat / geosite.dat (Loyalsoldier)"
  curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/geoip.dat" \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
  curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/geosite.dat" \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
  if [[ "$(stat -c%s "${tmp}/geoip.dat")" -le 1000 || "$(stat -c%s "${tmp}/geosite.dat")" -le 1000 ]]; then
    echo "Слишком маленький geoip/geosite" >&2
    rm -rf "$tmp"
    return 1
  fi
  sudo mkdir -p "$GEODATA_DIR"
  sudo install -o root -g root -m 644 "${tmp}/geoip.dat" "${GEODATA_DIR}/geoip.dat"
  sudo install -o root -g root -m 644 "${tmp}/geosite.dat" "${GEODATA_DIR}/geosite.dat"
  rm -rf "$tmp"
}

publish_link() {
  sudo mkdir -p "/var/www/html/${SUBS_PATH}"
  build_vless_link | sudo tee "$LINK_FILE" >/dev/null
  sudo chown -R "${PROJECT_USER}:www-data" /var/www/html/
  sudo chmod 644 "$LINK_FILE"
  echo "Файл подписки: $LINK_FILE"
}

# Собирает /usr/local/etc/xray/config.json. В xhttpSettings только path и mode.
write_xray_config() {
  local uuid="${1:-$UUID}"
  local xhttp_path="${2:-${XHTTP_PATH:-}}"
  local eu_uuid="${3:-${EU_UUID:-}}"
  if [[ -z "$uuid" ]]; then
    echo "write_xray_config: нет UUID" >&2
    return 1
  fi
  if [[ "$ROLE" == "relay" && -z "$eu_uuid" ]]; then
    echo "write_xray_config: нет EU_UUID" >&2
    return 1
  fi
  if [[ "$ROLE" != "backbone" && -z "$xhttp_path" ]]; then
    echo "write_xray_config: нет XHTTP_PATH" >&2
    return 1
  fi
  "$PYTHON" - "/tmp/xray-config.json" "$ROLE" "$uuid" "$xhttp_path" "$eu_uuid" \
    "$DOMAIN_NAME" "${EU_SERVER_DOMAIN:-}" "$EU_FLOW" "$XHTTP_MODE" \
    "$XRAY_XHTTP_LISTEN" "$XRAY_XHTTP_PORT" "$SSL_DIR" "$NGINX_FALLBACK" <<'PY'
import json, sys

(
    dst, role, uuid, xhttp_path, eu_uuid, domain, eu_host, eu_flow,
    xhttp_mode, xlisten, xport, ssl_dir, fallback,
) = sys.argv[1:]
xport = int(xport)
fb_host, fb_port = fallback.rsplit(":", 1)

log = {"loglevel": "warning", "access": "none"}

sniff = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": True,
}

direct = {"protocol": "freedom", "tag": "direct"}
block = {"protocol": "blackhole", "tag": "block"}

if role == "backbone":
    inbound = {
        "tag": "vless-in",
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": eu_flow, "email": "dim"}],
            "decryption": "none",
            "fallbacks": [{"dest": fallback, "xver": 1}],
        },
        "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["h2", "http/1.1"],
                "certificates": [{
                    "certificateFile": f"{ssl_dir}/fullchain.crt",
                    "keyFile": f"{ssl_dir}/cert.key",
                }],
            },
        },
        "sniffing": sniff,
    }
    outbounds = [direct, block]
    dns = {
        "servers": ["1.1.1.1", "8.8.8.8"],
        "queryStrategy": "UseIPv4",
        "disableFallbackIfMatch": True,
    }
    rules = [
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
        {"type": "field", "domain": ["geosite:category-ads-all", "geosite:category-public-tracker"], "outboundTag": "block"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    ]
else:
    inbound = {
        "tag": "xhttp-in",
        "listen": xlisten,
        "port": xport,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "email": "dim"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"path": xhttp_path, "mode": xhttp_mode},
        },
        "sniffing": sniff,
    }
    if role == "relay":
        eu = {
            "tag": "eu",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": eu_host,
                    "port": 443,
                    "users": [{
                        "id": eu_uuid,
                        "encryption": "none",
                        "flow": eu_flow,
                    }],
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                    "serverName": eu_host,
                    "alpn": ["http/1.1"],
                    "fingerprint": "chrome",
                },
                "sockopt": {"domainStrategy": "UseIPv4"},
            },
        }
        outbounds = [eu, direct, block]
        dns = {
            "servers": [
                {
                    "address": "8.8.8.8",
                    "domains": [f"full:{domain}", f"full:{eu_host}"],
                    "skipFallback": True,
                    "tag": "dns-direct",
                },
                {
                    "address": "77.88.8.8",
                    "domains": [
                        "geosite:category-ru",
                        "regexp:.*\\.ru$",
                        "regexp:.*\\.su$",
                        "domain:xn--p1ai",
                    ],
                    "skipFallback": True,
                    "tag": "dns-ru",
                },
                {"address": "1.1.1.1", "tag": "dns-eu"},
            ],
            "queryStrategy": "UseIPv4",
            "disableFallbackIfMatch": True,
            "tag": "dns-in",
        }
        rules = [
            {"type": "field", "inboundTag": ["dns-direct", "dns-ru"], "outboundTag": "direct"},
            {"type": "field", "inboundTag": ["dns-eu"], "outboundTag": "eu"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            {"type": "field", "domain": ["geosite:category-ads-all", "geosite:category-public-tracker"], "outboundTag": "block"},
            {"type": "field", "domain": [f"full:{domain}", f"full:{eu_host}", "domain:nerabotaet.com"], "outboundTag": "direct"},
            {"type": "field", "domain": ["geosite:category-ru", "regexp:.*\\.ru$", "regexp:.*\\.su$", "domain:xn--p1ai"], "outboundTag": "direct"},
            {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
        ]
    else:
        outbounds = [direct, block]
        dns = {
            "servers": ["1.1.1.1", "8.8.8.8"],
            "queryStrategy": "UseIPv4",
            "disableFallbackIfMatch": True,
        }
        rules = [
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            {"type": "field", "domain": ["geosite:category-ads-all", "geosite:category-public-tracker"], "outboundTag": "block"},
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
        ]

cfg = {
    "log": log,
    "dns": dns,
    "inbounds": [inbound],
    "outbounds": outbounds,
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": rules,
    },
}
with open(dst, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  sudo install -o root -g "$XRAY_GROUP" -m 640 /tmp/xray-config.json "$XRAY_CONFIG"
  rm -f /tmp/xray-config.json
}

write_haproxy_config() {
  if [[ "$ROLE" == "backbone" ]]; then
    return 0
  fi
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    echo "write_haproxy_config: нет XHTTP_PATH" >&2
    return 1
  fi
  "$PYTHON" - "/tmp/haproxy.cfg" "$DOMAIN_NAME" "$SUBS_PATH" "$XHTTP_PATH" \
    "$ALLOWED_IP" "$HAPROXY_CERT" "$XRAY_XHTTP_LISTEN" "$XRAY_XHTTP_PORT" \
    "$NGINX_FALLBACK" "$DECOY_ADDR" <<'PY'
import sys
dst, domain, subs, xhttp, allowed, cert, xlisten, xport, nginx, decoy = sys.argv[1:]
subs_path = f"/{subs.strip('/')}/update_subs_link"
if not xhttp.startswith("/"):
    xhttp = "/" + xhttp
ips = [] if allowed == "*" else allowed.split()
acl_ok = ""
use_subs = "use_backend be_subs if is_subs"
if ips:
    acl_ok = "    acl subs_ok src " + " ".join(ips) + "\n"
    use_subs = "use_backend be_subs if is_subs subs_ok"
cfg = f"""global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 group haproxy level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 20000
    ssl-default-bind-options ssl-min-ver TLSv1.2 prefer-client-ciphers no-tls-tickets
    tune.h2.fe.initial-window-size 1048576
    tune.h2.be.initial-window-size 1048576

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option dontlog-normal
    option http-keep-alive
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    timeout http-request 15s
    timeout http-keep-alive 10s

frontend fe443
    bind :80
    bind :443 ssl crt {cert} alpn h2,http/1.1
    http-request redirect scheme https code 301 unless {{ ssl_fc }}
    http-response set-header Strict-Transport-Security "max-age=31536000"

    acl is_xhttp path_beg {xhttp}
    acl is_subs  path {subs_path}
{acl_ok}    http-request set-log-level silent if is_xhttp

    use_backend be_xray if is_xhttp
    {use_subs}
    default_backend be_decoy

backend be_xray
    timeout server 1h
    timeout tunnel 1h
    option http-no-delay
    server xray {xlisten}:{xport} proto h2

backend be_subs
    server nginx {nginx} send-proxy

backend be_decoy
    http-request set-header Host {domain}
    server searxng {decoy}
"""
with open(dst, "w", encoding="utf-8") as f:
    f.write(cfg)
PY
  sudo install -o root -g haproxy -m 640 /tmp/haproxy.cfg "$HAPROXY_CFG"
  rm -f /tmp/haproxy.cfg
}

write_nginx_config() {
  "$PYTHON" - "/tmp/nginx_default" "$SUBS_PATH" "$ALLOWED_IP" <<'PY'
import sys
dst, subs, allowed = sys.argv[1:]
subs = subs.strip("/")
if allowed == "*":
    geo_body = "    default 1;\n"
else:
    lines = ["    default 0;", "    127.0.0.1 1;", "    ::1 1;"]
    for ip in allowed.split():
        lines.append(f"    {ip} 1;")
    geo_body = "\n".join(lines) + "\n"
cfg = f"""geo $remote_addr $subs_ok {{
{geo_body}}}

server {{
    listen 127.0.0.1:8081 proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header proxy_protocol;

    root /var/www/html;
    index index.html;
    server_name _;

    location = /{subs}/update_subs_link {{
        if ($subs_ok = 0) {{
            return 404;
        }}
        alias /var/www/html/{subs}/update_subs_link;
        default_type text/plain;
        add_header Cache-Control "no-store";
        add_header X-Content-Type-Options nosniff;
    }}

    location / {{
        try_files $uri $uri/ /index.html;
    }}
}}
"""
with open(dst, "w", encoding="utf-8") as f:
    f.write(cfg)
PY
  sudo install -o root -g root -m 644 /tmp/nginx_default "$NGINX_SITE"
  rm -f /tmp/nginx_default
}

install_haproxy_cert() {
  sudo mkdir -p /etc/haproxy/certs
  sudo bash -c "cat '${SSL_DIR}/fullchain.crt' '${SSL_DIR}/cert.key' > '${HAPROXY_CERT}'"
  sudo chown root:haproxy "$HAPROXY_CERT"
  sudo chmod 640 "$HAPROXY_CERT"
}

install_ssl_certs() {
  if [[ -f /tmp/fullchain.crt && -f /tmp/cert.key ]]; then
    echo "Установка сертификатов /tmp -> ${SSL_DIR}"
    sudo install -o root -g root -m 755 -d "$SSL_DIR"
    sudo install -o root -g root -m 644 /tmp/fullchain.crt "${SSL_DIR}/fullchain.crt"
    sudo install -o root -g "${XRAY_GROUP}" -m 640 /tmp/cert.key "${SSL_DIR}/cert.key"
    rm -f /tmp/fullchain.crt /tmp/cert.key
  elif [[ -f "${SSL_DIR}/fullchain.crt" && -f "${SSL_DIR}/cert.key" ]]; then
    echo "Сертификат ${SSL_DIR}/fullchain.crt установлен"
    sudo chown root:"${XRAY_GROUP}" "${SSL_DIR}/cert.key"
    sudo chmod 640 "${SSL_DIR}/cert.key"
  else
    echo "Ошибка: нет ни /tmp/{fullchain.crt,cert.key}, ни ${SSL_DIR}" >&2
    IPv4="$(curl -4sS https://api.ipify.org || true)"
    echo "Для начала работы установите DNS-зоны на текущий ip: ${IPv4}."
    echo "Затем загрузите сертификаты в /tmp/{fullchain.crt,cert.key}" >&2
    exit 1
  fi
}

write_searxng_env() {
  local secret_file="${SEARXNG_DIR}/.env"
  local secret=""
  if [[ -f "$secret_file" ]]; then
    # shellcheck disable=SC1090
    secret="$(. "$secret_file"; printf '%s' "${SEARXNG_SECRET:-}")"
  fi
  if [[ -z "$secret" ]]; then
    secret="$(openssl rand -hex 32)"
  fi
  cat > "$secret_file" <<EOF
SEARXNG_BASE_URL=https://${DOMAIN_NAME}/
SEARXNG_SECRET=${secret}
EOF
  chmod 600 "$secret_file"
  chown_project_user "$secret_file"
}

# docker compose из каталога searxng. Файлы проекта не удаляет.
searxng_compose() {
  if sudo docker compose version >/dev/null 2>&1; then
    sudo docker compose -f "${SEARXNG_DIR}/docker-compose.yml" --env-file "${SEARXNG_DIR}/.env" "$@"
  else
    sudo docker-compose -f "${SEARXNG_DIR}/docker-compose.yml" --env-file "${SEARXNG_DIR}/.env" "$@"
  fi
}

# Пересоздаёт контейнеры, чтобы SEARXNG_BASE_URL из текущего .env попал в процесс.
searxng_up() {
  write_searxng_env
  echo "Запуск SearXNG (docker compose --force-recreate)"
  searxng_compose up -d --force-recreate --remove-orphans
}

# Останавливает контейнеры при ROLE=backbone. volumes и searxng/.env не трогает.
searxng_stop() {
  if [[ ! -f "${SEARXNG_DIR}/docker-compose.yml" ]]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    searxng_compose stop || true
  fi
}

restart_xray() {
  if [[ "$(id -u)" -eq 0 ]]; then
    xray run -test -config "$XRAY_CONFIG"
    systemctl restart xray
  else
    sudo xray run -test -config "$XRAY_CONFIG"
    sudo systemctl restart xray
  fi
}
