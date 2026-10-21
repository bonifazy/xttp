#!/usr/bin/env bash
#
# Общая библиотека xttp. Её source-ят main.sh, change_uuid_and_path.sh,
# from_ru_relay_update_eu_uuid.sh, update_geodata.sh, tspu_watch.sh.
# Проект всегда в /home/dim/xttp.

SCRIPT_DIR="/home/dim/xttp"
cd "$SCRIPT_DIR" || return 1
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  echo "Нет файла .env. Скопируйте env_markup -> .env и заполните переменные."
  exit 1
fi

# shellcheck source=/home/dim/xttp/.env
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"

PROJECT_USER="${PROJECT_USER:-dim}"
BACKUP_DIR="${BACKUP_DIR:-/home/${PROJECT_USER}/backup}"
SSL_DIR="${SSL_DIR:-/etc/ssl/nerabotaet.com}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
GEODATA_DIR="${GEODATA_DIR:-/usr/local/share/xray}"
GEODATA_BUNDLE="${GEODATA_BUNDLE:-${SCRIPT_DIR}/geodata}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
HAPROXY_CERT="${HAPROXY_CERT:-/etc/haproxy/certs/nerabotaet.com.pem}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/default}"
SEARXNG_DIR="${SCRIPT_DIR}/searxng"
SECRETS_FILE="${SCRIPT_DIR}/.xttp_secrets"
PYTHON="${PYTHON:-python3}"

# Порт магистрали: из .env, иначе 443.
# С RU ALPN на :443 часто режут — для пары relay↔backbone ставят 8443.
EU_SERVER_PORT="${EU_SERVER_PORT:-443}"
# Inbound XHTTP на всех ролях принимает любой режим клиента.
XHTTP_MODE="auto"
# Hop relay→backbone: packet-up (короткие POST). Не Vision: он только с TCP/stream-one.
EU_XHTTP_MODE="${EU_XHTTP_MODE:-packet-up}"
# telemt #844: на hop RU→EU режем только TLS ClientHello, не весь TCP.
# 1 — включено (по умолчанию). 0 — обычный набор без fragment.
HELLO_FRAG="${HELLO_FRAG:-1}"
HELLO_FRAG_LENGTH="${HELLO_FRAG_LENGTH:-80-120}"
HELLO_FRAG_INTERVAL="${HELLO_FRAG_INTERVAL:-8-20}"
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
EU_SERVER_LINK="${EU_SERVER_LINK:-}"
CLIENT_MODE="${CLIENT_MODE:-stream-up}"
EU_SNI="${EU_SERVER_DOMAIN}"
EU_XHTTP_PATH="${EU_XHTTP_PATH:-}"

if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck source=/home/dim/xttp/.xttp_secrets
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
fi

_die() {
  echo "$*" >&2
  exit 1
}

# Свежий VPS часто держит dpkg lock (unattended-upgrades / cloud-init).
# Ждём до ~2 мин (12×10 с), lock сами не снимаем.
wait_for_apt() {
  local n=0
  while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    n=$((n + 1))
    if [[ "$n" -gt 12 ]]; then
      echo "apt lock занят дольше 2 минут. Смотрите: ps aux | grep -E 'apt|dpkg'" >&2
      sudo fuser -v /var/lib/dpkg/lock-frontend >&2 || true
      return 1
    fi
    echo "ждём освобождения apt lock (${n}/12)..."
    sleep 10
  done
}

# apt-get update/install только если пакета нет в dpkg.
ensure_apt_packages() {
  local missing=()
  local p status
  for p in "$@"; do
    status="$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)"
    if [[ "$status" != "installed" ]]; then
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  echo "Установка ${missing[*]}"
  wait_for_apt
  sudo apt-get update
  wait_for_apt
  sudo apt-get install -y "${missing[@]}"
}

case "$ROLE" in
  relay|edge|backbone) ;;
  *) _die "ROLE должен быть relay, edge или backbone. Сейчас: '${ROLE}'" ;;
esac

if [[ -z "$DOMAIN_NAME" || -z "$SUBS_PATH" ]]; then
  _die "В .env пусты DOMAIN_NAME или SUBS_PATH"
fi

if [[ "$ROLE" == "relay" && -z "$EU_SERVER_LINK" && -z "$EU_SERVER_DOMAIN" ]]; then
  _die "ROLE=relay требует EU_SERVER_LINK или EU_SERVER_DOMAIN в .env"
fi

if [[ ! "$EU_SERVER_PORT" =~ ^[0-9]+$ ]] || [[ "$EU_SERVER_PORT" -lt 1 || "$EU_SERVER_PORT" -gt 65535 ]]; then
  _die "EU_SERVER_PORT должен быть 1-65535. Сейчас: '${EU_SERVER_PORT}'"
fi

if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  case "$CLIENT_MODE" in
    packet-up|stream-up|auto) ;;
    *) _die "CLIENT_MODE: packet-up, stream-up или auto. Сейчас: '${CLIENT_MODE}'" ;;
  esac
fi

if [[ "$ROLE" == "relay" || "$ROLE" == "backbone" ]]; then
  case "$EU_XHTTP_MODE" in
    packet-up|stream-up|auto) ;;
    *) _die "EU_XHTTP_MODE: packet-up, stream-up или auto. Сейчас: '${EU_XHTTP_MODE}'" ;;
  esac
fi

if [[ "$ROLE" == "relay" ]]; then
  case "$HELLO_FRAG" in
    0|1) ;;
    *) _die "HELLO_FRAG: 0 или 1. Сейчас: '${HELLO_FRAG}'" ;;
  esac
fi

# Список IP из ALLOWED_IP. Пусто или "*" — без списка (ufw from не пишем).
allowed_ips_list() {
  if [[ -z "$ALLOWED_IP" || "$ALLOWED_IP" == "*" ]]; then
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

# Пишет .xttp_secrets текущими UUID / XHTTP_PATH / hop EU_*.
# umask 077 + chmod 600 + dim:dim, даже если пишет root из cron.
write_secrets() {
  umask 077
  {
    printf 'UUID=%s\n' "${UUID:-}"
    printf 'XHTTP_PATH=%s\n' "${XHTTP_PATH:-}"
    if [[ "$ROLE" == "relay" ]]; then
      printf 'EU_UUID=%s\n' "${EU_UUID:-}"
      printf 'EU_XHTTP_PATH=%s\n' "${EU_XHTTP_PATH:-}"
      printf 'EU_XHTTP_MODE=%s\n' "${EU_XHTTP_MODE:-packet-up}"
    fi
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  chown_project_user "$SECRETS_FILE"
}

# Первый запуск: UUID и XHTTP_PATH. Повторный — только читает.
ensure_secrets() {
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Нет .xttp_secrets — генерирую UUID"
    UUID="$(generate_uuid)"
    XHTTP_PATH="/$(generate_uuid)"
    echo "XHTTP_PATH сгенерирован"
    write_secrets
    return 0
  fi
  # shellcheck source=/home/dim/xttp/.xttp_secrets
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
  if [[ -z "${UUID:-}" ]]; then
    _die "В .xttp_secrets нет UUID"
  fi
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    XHTTP_PATH="/$(generate_uuid)"
    echo "В .xttp_secrets не было XHTTP_PATH — сгенерирован"
    write_secrets
  fi
}

# https URL. Порт 443 в authority не пишем.
https_url() {
  local host="$1"
  local path="$2"
  local port="${3:-$EU_SERVER_PORT}"
  path="/${path#/}"
  if [[ "$port" == "443" ]]; then
    printf 'https://%s%s' "$host" "$path"
  else
    printf 'https://%s:%s%s' "$host" "$port" "$path"
  fi
}

# Собирает ссылку подписки. Хост — DOMAIN_NAME этого сервера.
# relay/edge: XHTTP + CLIENT_MODE (телефон). backbone: XHTTP + EU_XHTTP_MODE (hop relay).
build_vless_link() {
  local uuid="${1:-$UUID}"
  if [[ -z "$uuid" ]]; then
    echo "build_vless_link: нет UUID" >&2
    return 1
  fi
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    echo "build_vless_link: нет XHTTP_PATH" >&2
    return 1
  fi
  local client_port=443
  local mode="$CLIENT_MODE"
  if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
    client_port="$EU_SERVER_PORT"
  fi
  if [[ "$ROLE" == "backbone" ]]; then
    mode="${EU_XHTTP_MODE:-packet-up}"
  fi
  "$PYTHON" - "$uuid" "$DOMAIN_NAME" "$XHTTP_PATH" "$mode" "$client_port" <<'PY'
import sys
from urllib.parse import quote
uuid, host, path, mode, port = sys.argv[1:]
enc_path = quote(path, safe="")
print(
    f"vless://{uuid}@{host}:{port}?encryption=none&security=tls"
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

# vless-ссылка backbone → EU_UUID, HOST, PORT, SNI, XHTTP path/mode.
apply_eu_server_link() {
  local link parsed
  link="$(printf '%s' "${1:-${EU_SERVER_LINK:-}}" | tr -d '\r\n ')"
  if [[ "$link" != vless://* ]]; then
    echo "EU_SERVER_LINK должна начинаться с vless://" >&2
    return 1
  fi
  parsed="$("$PYTHON" - "$link" <<'PY'
import re
import sys
from urllib.parse import parse_qs, unquote, urlparse

raw = sys.argv[1]
u = urlparse(raw)
uuid = u.username or ""
host = u.hostname or ""
port = u.port
qs = parse_qs(u.query, keep_blank_values=False)
sni = unquote((qs.get("sni") or [host])[0] or "")
typ = unquote((qs.get("type") or ["tcp"])[0] or "tcp")
path = unquote((qs.get("path") or [""])[0] or "")
mode = unquote((qs.get("mode") or [""])[0] or "")
flow = unquote((qs.get("flow") or [""])[0] or "")
if not uuid or not host:
    sys.stderr.write("EU_SERVER_LINK: нет UUID или хоста\n")
    sys.exit(1)
if not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", uuid):
    sys.stderr.write("EU_SERVER_LINK: UUID не разобрать\n")
    sys.exit(1)
if port is None:
    port = 443
if not 1 <= int(port) <= 65535:
    sys.stderr.write("EU_SERVER_LINK: плохой порт\n")
    sys.exit(1)
if not sni:
    sni = host
if typ != "xhttp" or flow:
    sys.stderr.write(
        "EU hop теперь VLESS+XHTTP, не tcp/Vision.\n"
        "Поставьте в EU_SERVER_LINK ссылку с подписки backbone (type=xhttp&mode=packet-up).\n"
    )
    sys.exit(1)
if not path:
    sys.stderr.write("EU_SERVER_LINK: нет path для XHTTP\n")
    sys.exit(1)
if not path.startswith("/"):
    path = "/" + path
if not mode:
    mode = "packet-up"
if mode not in ("packet-up", "stream-up", "auto"):
    sys.stderr.write(f"EU_SERVER_LINK: mode={mode} — нужен packet-up/stream-up/auto\n")
    sys.exit(1)
print(f"EU_UUID={uuid}")
print(f"EU_SERVER_DOMAIN={host}")
print(f"EU_SERVER_PORT={port}")
print(f"EU_SNI={sni}")
print(f"EU_XHTTP_PATH={path}")
print(f"EU_XHTTP_MODE={mode}")
PY
)" || return 1
  eval "$parsed"
  if [[ -z "${EU_UUID:-}" || -z "${EU_SERVER_DOMAIN:-}" || -z "${EU_XHTTP_PATH:-}" ]]; then
    echo "EU_SERVER_LINK не разобралась" >&2
    return 1
  fi
}

# Для relay: постоянная EU_SERVER_LINK или GET подписки с backbone.
# Ставит hop-поля в текущем shell, не в $().
resolve_relay_eu_uuid() {
  local link
  if [[ -n "${EU_SERVER_LINK:-}" ]]; then
    echo "EU hop из EU_SERVER_LINK, подписку backbone не запрашиваем"
    apply_eu_server_link || return 1
    return 0
  fi
  link="$(fetch_eu_link)" || return 1
  apply_eu_server_link "$link" || return 1
}

# Качает подписку с backbone. Пишет vless:// в stdout.
fetch_eu_link() {
  local url code tmp link
  url="$(https_url "$EU_SERVER_DOMAIN" "${SUBS_PATH}/update_subs_link")"
  tmp="$(mktemp)"
  echo "Запрос EU hop: $url" >&2
  code="$(curl -4sS --http1.1 -o "$tmp" -w '%{http_code}' --retry 3 --retry-delay 2 --max-time 20 "$url" || true)"
  link="$(tr -d '\r\n ' < "$tmp")"
  rm -f "$tmp"
  if [[ "$code" != "200" ]] || [[ "$link" != vless://* ]]; then
    echo "Не удалось получить ссылку backbone с ${url}" >&2
    echo "curl: HTTP ${code:-error}" >&2
    if [[ -n "$link" ]]; then
      echo "ответ: ${link:0:200}" >&2
    fi
    echo "Проверьте: backbone запущен, DNS ${EU_SERVER_DOMAIN} смотрит на него," >&2
    echo "IP этого relay есть в ALLOWED_IP на backbone." >&2
    return 1
  fi
  printf '%s\n' "$link"
}

apply_ufw() {
  local ip
  if [[ "$ROLE" == "relay" ]]; then
    sudo ufw allow 80/tcp comment "HTTP redirect"
    sudo ufw allow 443/tcp comment "HTTPS"
  elif [[ "$ROLE" == "edge" ]]; then
    sudo ufw allow 80/tcp comment "HTTP redirect"
    sudo ufw allow "${EU_SERVER_PORT}/tcp" comment "HTTPS"
  elif [[ "$ROLE" == "backbone" ]]; then
    sudo ufw allow 80/tcp comment "HTTP redirect"
    sudo ufw allow "${EU_SERVER_PORT}/tcp" comment "HTTPS backbone"
  fi
  if [[ -n "$ALLOWED_IP" && "$ALLOWED_IP" != "*" ]]; then
    while read -r ip; do
      [[ -z "$ip" ]] && continue
      sudo ufw allow from "$ip" comment "All from allowed_ip"
    done < <(allowed_ips_list)
  fi
}

_geodata_file_ok() {
  local f="$1"
  [[ -f "$f" ]] && [[ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 1000 ]]
}

# 1) GitHub 10 с  2) зеркала jsDelivr / Fastly  3) иначе локальные geodata/ из репозитория.
_fetch_geodat() {
  local dest="$1"
  local github="$2"
  shift 2
  echo "  1) GitHub (10s): ${github}"
  if curl -4fsSL --connect-timeout 10 --max-time 10 --retry 0 -o "$dest" "$github" \
    && _geodata_file_ok "$dest"; then
    echo "  ок GitHub"
    return 0
  fi
  rm -f "$dest"
  echo "  GitHub не успел за 10с"
  local url
  for url in "$@"; do
    echo "  2) зеркало: ${url}"
    if curl -4fsSL --connect-timeout 10 --max-time 60 --retry 0 -o "$dest" "$url" \
      && _geodata_file_ok "$dest"; then
      echo "  ок зеркало"
      return 0
    fi
    rm -f "$dest"
  done
  echo "  зеркала не дали файл"
  return 1
}

# Только после провала GitHub и зеркал: файлы из ~/xttp/geodata.
_geodata_fallback() {
  local name="$1" dest="$2"
  if _geodata_file_ok "${GEODATA_BUNDLE}/${name}"; then
    echo "  3) локальный ${GEODATA_BUNDLE}/${name}"
    cp -a "${GEODATA_BUNDLE}/${name}" "$dest"
    return 0
  fi
  echo "нет ${GEODATA_BUNDLE}/${name} после GitHub и зеркал" >&2
  return 1
}

install_geodata() {
  local tmp
  tmp="$(mktemp -d)"
  echo "geoip/geosite: GitHub → зеркало → локальные geodata/"
  if ! _fetch_geodat "${tmp}/geoip.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
    "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" \
    "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
  then
    if ! _geodata_fallback geoip.dat "${tmp}/geoip.dat"; then
      rm -rf "$tmp"
      return 1
    fi
  fi
  if ! _fetch_geodat "${tmp}/geosite.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
    "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" \
    "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
  then
    if ! _geodata_fallback geosite.dat "${tmp}/geosite.dat"; then
      rm -rf "$tmp"
      return 1
    fi
  fi
  sudo mkdir -p "$GEODATA_DIR"
  sudo install -o root -g root -m 644 "${tmp}/geoip.dat" "${GEODATA_DIR}/geoip.dat"
  sudo install -o root -g root -m 644 "${tmp}/geosite.dat" "${GEODATA_DIR}/geosite.dat"
  rm -rf "$tmp"
}

publish_link() {
  sudo mkdir -p "/var/www/html/${SUBS_PATH}"
  build_vless_link "$UUID" | sudo tee "$LINK_FILE" >/dev/null
  sudo chown -R "${PROJECT_USER}:www-data" /var/www/html/
  sudo chmod 644 "$LINK_FILE"
}

# Собирает /usr/local/etc/xray/config.json. В xhttpSettings только path и mode.
# XHTTP-паддинг ядро ставит само (xPaddingBytes 100-1000, Referer x_padding / X-Padding).
# Все роли: VLESS+XHTTP на 127.0.0.1 (TLS снимает HAProxy).
# relay outbound: XHTTP packet-up + TLS на backbone.
# ClientHello-only fragment — патч xray-core (XRAY_HELLO_FRAG в unit), не JSON.
write_xray_config() {
  local uuid="${1:-$UUID}"
  local xhttp_path="${2:-${XHTTP_PATH:-}}"
  local eu_uuid="${3:-${EU_UUID:-}}"
  if [[ -z "$uuid" ]]; then
    echo "write_xray_config: нет UUID" >&2
    return 1
  fi
  if [[ -z "$xhttp_path" ]]; then
    echo "write_xray_config: нет XHTTP_PATH" >&2
    return 1
  fi
  if [[ "$ROLE" == "relay" ]]; then
    if [[ -z "$eu_uuid" ]]; then
      echo "write_xray_config: нет EU_UUID" >&2
      return 1
    fi
    if [[ -z "${EU_XHTTP_PATH:-}" ]]; then
      echo "write_xray_config: нет EU_XHTTP_PATH (ссылка backbone без type=xhttp&path=)" >&2
      return 1
    fi
  fi
  "$PYTHON" - "/tmp/xray-config.json" "$ROLE" "$uuid" "$xhttp_path" "$eu_uuid" \
    "$DOMAIN_NAME" "${EU_SERVER_DOMAIN:-}" "$EU_SERVER_PORT" "${EU_SNI:-}" \
    "$XHTTP_MODE" "$XRAY_XHTTP_LISTEN" "$XRAY_XHTTP_PORT" \
    "${EU_XHTTP_PATH:-}" "${EU_XHTTP_MODE:-packet-up}" <<'PY'
import json, sys

(
    dst, role, uuid, xhttp_path, eu_uuid, domain, eu_host,
    eu_port, eu_sni, xhttp_mode, xlisten, xport,
    eu_xhttp_path, eu_xhttp_mode,
) = sys.argv[1:]
xport = int(xport)
eu_port = int(eu_port) if eu_port else 443


def xhttp_settings(path, mode):
    if path and not path.startswith("/"):
        path = "/" + path
    return {"path": path, "mode": mode}


log = {"loglevel": "warning", "access": "none"}

sniff = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": True,
}

direct = {"protocol": "freedom", "tag": "direct"}
block = {"protocol": "blackhole", "tag": "block"}

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
        "xhttpSettings": xhttp_settings(xhttp_path, xhttp_mode),
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
                "port": eu_port,
                "users": [{
                    "id": eu_uuid,
                    "encryption": "none",
                }],
            }]
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "tls",
            "tlsSettings": {
                "serverName": eu_sni or eu_host,
                "alpn": ["h2"],
                "fingerprint": "chrome",
            },
            "xhttpSettings": xhttp_settings(eu_xhttp_path, eu_xhttp_mode),
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
  sudo mkdir -p "$(dirname "$XRAY_CONFIG")"
  sudo install -o root -g "$XRAY_GROUP" -m 640 /tmp/xray-config.json "$XRAY_CONFIG"
  rm -f /tmp/xray-config.json
}

write_haproxy_config() {
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    echo "write_haproxy_config: нет XHTTP_PATH" >&2
    return 1
  fi
  local tls_port=443
  if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
    tls_port="$EU_SERVER_PORT"
  fi
  "$PYTHON" - "/tmp/haproxy.cfg" "$DOMAIN_NAME" "$SUBS_PATH" "$XHTTP_PATH" \
    "$ALLOWED_IP" "$HAPROXY_CERT" "$XRAY_XHTTP_LISTEN" "$XRAY_XHTTP_PORT" \
    "$NGINX_FALLBACK" "$DECOY_ADDR" "$tls_port" <<'PY'
import sys
dst, domain, subs, xhttp, allowed, cert, xlisten, xport, nginx, decoy, tls_port = sys.argv[1:]
tls_port = int(tls_port)
subs_path = f"/{subs.strip('/')}/update_subs_link"
if not xhttp.startswith("/"):
    xhttp = "/" + xhttp
ips = [] if allowed in ("", "*") else allowed.split()
acl_ok = ""
use_subs = "use_backend be_subs if is_subs"
if ips:
    acl_ok = "    acl subs_ok src 127.0.0.1 " + " ".join(ips) + "\n"
    use_subs = "use_backend be_subs if is_subs subs_ok"
bind_ssl = f"    bind :{tls_port} ssl crt {cert} alpn h2,http/1.1"
if tls_port == 443:
    redir = "    http-request redirect scheme https code 301 unless { ssl_fc }"
else:
    redir = (
        f"    http-request redirect location https://%[hdr(host),field(1,:)]:{tls_port}%[capture.req.uri] "
        "unless { ssl_fc }"
    )
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
    # telemt #844: большие TLS-записи на потоке; мелкий maxrecord = MSS на всю сессию.
    tune.ssl.maxrecord 16384

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option dontlog-normal
    option http-keep-alive
    # cork первого ответа: ServerHello+сертификат в одном TCP, не ~200 байт SH.
    option tcp-smart-accept
    option tcp-smart-connect
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    timeout http-request 15s
    timeout http-keep-alive 10s

frontend fe_tls
    bind :80
{bind_ssl}
{redir}
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
  if [[ -f /etc/nginx/sites-available/default ]]; then
    backup_if_exists /etc/nginx/sites-available/default nginx_sites_available_default
  fi
  if [[ -e /etc/nginx/sites-enabled/default && ! -L /etc/nginx/sites-enabled/default ]]; then
    backup_if_exists /etc/nginx/sites-enabled/default nginx_sites_enabled_default
  fi

  "$PYTHON" - "/tmp/nginx_default" "$SUBS_PATH" "$ALLOWED_IP" <<'PY'
import sys
dst, subs, allowed = sys.argv[1:]
subs = subs.strip("/")
if allowed in ("", "*"):
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
  echo "nginx default перезаписан: $NGINX_SITE"

  # Всегда свой vhost: убрать чужой файл/ссылку в sites-enabled и поставить symlink.
  sudo mkdir -p /etc/nginx/sites-enabled
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo ln -sfn "$NGINX_SITE" /etc/nginx/sites-enabled/default
  echo "sites-enabled/default -> $NGINX_SITE"
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
    # shellcheck source=/home/dim/xttp/searxng/.env
    # shellcheck disable=SC1091
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

# Останавливает контейнеры SearXNG. volumes и searxng/.env не трогает.
searxng_stop() {
  if [[ ! -f "${SEARXNG_DIR}/docker-compose.yml" ]]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    searxng_compose stop || true
  fi
}

# Всегда unit + drop-in 99-xttp: старый installer/ручной ~/xray/config.json
# перекрывается 10-donot_touch_single_conf.conf, его 99-xttp побеждает.
write_xray_service_unit() {
  local unit_user unit_group
  unit_user="${XRAY_USER:-nobody}"
  unit_group="${XRAY_GROUP:-nogroup}"
  sudo tee /etc/systemd/system/xray.service >/dev/null <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=${unit_user}
Group=${unit_group}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config ${XRAY_CONFIG}
Environment=XRAY_HELLO_FRAG=${HELLO_FRAG}
Environment=XRAY_HELLO_FRAG_LENGTH=${HELLO_FRAG_LENGTH}
Environment=XRAY_HELLO_FRAG_INTERVAL=${HELLO_FRAG_INTERVAL}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
  sudo mkdir -p /etc/systemd/system/xray.service.d
  sudo tee /etc/systemd/system/xray.service.d/99-xttp.conf >/dev/null <<EOF
[Service]
User=${unit_user}
Group=${unit_group}
ExecStart=
ExecStart=/usr/local/bin/xray run -config ${XRAY_CONFIG}
Environment=XRAY_HELLO_FRAG=${HELLO_FRAG}
Environment=XRAY_HELLO_FRAG_LENGTH=${HELLO_FRAG_LENGTH}
Environment=XRAY_HELLO_FRAG_INTERVAL=${HELLO_FRAG_INTERVAL}
EOF
  sudo systemctl daemon-reload
}

# Процесс Xray — от пользователя xray (не PROJECT_USER). systemd не любит User=nobody.
adopt_xray_runtime_user() {
  if ! getent group xray >/dev/null 2>&1; then
    sudo groupadd --system xray
  fi
  if ! id -u xray >/dev/null 2>&1; then
    sudo useradd --system --gid xray --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin --comment "Xray Service" xray
  fi
  XRAY_USER=xray
  XRAY_GROUP=xray
  if [[ -f "${SSL_DIR}/cert.key" ]]; then
    sudo chown root:"${XRAY_GROUP}" "${SSL_DIR}/cert.key"
    sudo chmod 640 "${SSL_DIR}/cert.key"
  fi
}

# Xray на VPS: готовый ELF из xray-core/xray-linux-* (сборка на Mac: ./build_xray_release.sh).
# Патч hello_frag уже внутри бинарника. Go/swap на VPS не нужны. GitHub не качаем.
linux_xray_arch() {
  local debarch
  debarch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$debarch" in
    amd64|x86_64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# Не grep -q в пайпе: при pipefail xray version ловит SIGPIPE и if считает провал.
xray_has_hello_frag() {
  local out
  out="$(/usr/local/bin/xray version 2>&1 || true)"
  [[ "$out" == *xttp-hello-frag* ]]
}

install_xray() {
  local src="${SCRIPT_DIR}/xray-core"
  local arch tag stamp bin
  if [[ "$(uname -s)" != "Linux" ]]; then
    _die "Xray ставится только на Ubuntu VPS. Сейчас: $(uname -s). Сборка релиза: ./build_xray_release.sh"
  fi
  if [[ ! -f /etc/os-release ]]; then
    _die "нет /etc/os-release — нужен Ubuntu 22.04, 24.04 или 26.04"
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    _die "xttp/Xray только Ubuntu. Сейчас: ${ID:-?} ${VERSION_ID:-?}"
  fi
  case "${VERSION_ID:-}" in
    22.04|24.04|26.04) ;;
    *) _die "xttp/Xray: Ubuntu 22.04, 24.04 или 26.04. Сейчас: ${VERSION_ID:-?}" ;;
  esac
  arch="$(linux_xray_arch)" || _die "архитектура $(uname -m): нужен amd64 или arm64"
  tag="$(head -n 1 "${src}/XTLS_TAG" 2>/dev/null | tr -d '[:space:]')"
  tag="${tag:-v26.10.17}"
  stamp="/usr/local/share/xray/.xttp_build"
  bin="${src}/xray-linux-${arch}"
  if [[ ! -f "$bin" ]]; then
    _die "нет ${bin}. На Mac: ./build_xray_release.sh и скопируйте xray-core/xray-linux-* на VPS."
  fi
  if [[ -x /usr/local/bin/xray ]] && [[ -f "$stamp" ]] \
    && [[ "$(cat "$stamp")" == "${tag} hello-frag ${arch}" ]] \
    && xray_has_hello_frag; then
    echo "Xray ${tag} linux/${arch} уже стоит (xttp-hello-frag)"
  else
    echo "Ставлю Xray ${tag} linux/${arch} из ${bin} (не GitHub, не go build)"
    sudo install -o root -g root -m 755 "$bin" /usr/local/bin/xray
    sudo mkdir -p /usr/local/share/xray
    echo "${tag} hello-frag ${arch}" | sudo tee "$stamp" >/dev/null
  fi
  sudo /usr/local/bin/xray version || sudo /usr/local/bin/xray -version
  if [[ ! -x /usr/local/bin/xray ]]; then
    _die "после установки нет /usr/local/bin/xray"
  fi
  if ! xray_has_hello_frag; then
    _die "/usr/local/bin/xray без xttp-hello-frag — это не наш релиз"
  fi
  adopt_xray_runtime_user
  echo "xray.service -> ${XRAY_CONFIG} (User=${XRAY_USER})"
  write_xray_service_unit
  if ! systemctl cat xray.service >/dev/null 2>&1; then
    _die "нет xray.service после записи unit"
  fi
  grant_project_user_admins
}

# PROJECT_USER администрирует сервис, процесс xray остаётся от xray/nobody.
# docker: группа docker. xray: NOPASSWD systemctl/journalctl только для xray.service.
grant_project_user_admins() {
  if ! id -u "$PROJECT_USER" >/dev/null 2>&1; then
    echo "нет пользователя ${PROJECT_USER}, права docker/xray не выдаю" >&2
    return 0
  fi
  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker "$PROJECT_USER"
    echo "${PROJECT_USER} в группе docker"
  fi
  local tmp sudoers
  tmp="$(mktemp)"
  sudoers=/etc/sudoers.d/xttp-xray
  cat > "$tmp" <<EOF
# xttp: ${PROJECT_USER} управляет xray.service без пароля.
Cmnd_Alias XTTP_XRAY = \\
  /usr/bin/systemctl start xray, /usr/bin/systemctl start xray.service, \\
  /usr/bin/systemctl stop xray, /usr/bin/systemctl stop xray.service, \\
  /usr/bin/systemctl restart xray, /usr/bin/systemctl restart xray.service, \\
  /usr/bin/systemctl reload xray, /usr/bin/systemctl reload xray.service, \\
  /usr/bin/systemctl status xray, /usr/bin/systemctl status xray *, \\
  /usr/bin/systemctl status xray.service, /usr/bin/systemctl status xray.service *, \\
  /usr/bin/systemctl is-active xray, /usr/bin/systemctl is-active xray.service, \\
  /usr/bin/systemctl enable xray, /usr/bin/systemctl enable xray.service, \\
  /usr/bin/systemctl disable xray, /usr/bin/systemctl disable xray.service, \\
  /usr/bin/systemctl kill xray, /usr/bin/systemctl kill xray.service, \\
  /usr/bin/systemctl reset-failed xray, /usr/bin/systemctl reset-failed xray.service, \\
  /usr/bin/journalctl -u xray, /usr/bin/journalctl -u xray *, \\
  /usr/bin/journalctl -u xray.service, /usr/bin/journalctl -u xray.service *, \\
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json, \\
  /usr/local/bin/xray version
${PROJECT_USER} ALL=(root) NOPASSWD: XTTP_XRAY
EOF
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    sudo install -o root -g root -m 440 "$tmp" "$sudoers"
    echo "${PROJECT_USER}: NOPASSWD systemctl/journalctl для xray.service"
  else
    echo "sudoers ${sudoers} невалиден, не ставлю" >&2
  fi
  rm -f "$tmp"
}

restart_xray() {
  if [[ "$(id -u)" -eq 0 ]]; then
    /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
    systemctl reset-failed xray 2>/dev/null || true
    systemctl restart xray
  else
    sudo /usr/local/bin/xray run -test -config "$XRAY_CONFIG"
    sudo systemctl reset-failed xray 2>/dev/null || true
    sudo systemctl restart xray
  fi
}

# После старта backbone: HAProxy на EU_SERVER_PORT, Xray на localhost, подписка = xhttp.
assert_role_frontends() {
  if [[ "$ROLE" != "backbone" ]]; then
    return 0
  fi
  local url
  url="$(https_url "$DOMAIN_NAME" "${SUBS_PATH}/update_subs_link")"
  if ! systemctl is-active --quiet xray; then
    sudo journalctl -u xray -n 40 --no-pager >&2 || true
    _die "xray не active — ${url} не работает"
  fi
  if ! systemctl is-active --quiet haproxy; then
    sudo journalctl -u haproxy -n 40 --no-pager >&2 || true
    _die "haproxy не active — :${EU_SERVER_PORT} должен держать HAProxy, не Xray"
  fi
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do
    if sudo ss -lntp 2>/dev/null | grep -E ":${EU_SERVER_PORT}\\b" | grep -q haproxy; then
      break
    fi
    echo "ждём, пока HAProxy откроет :${EU_SERVER_PORT} (${n}/10)..."
    sleep 1
  done
  if ! sudo ss -lntp 2>/dev/null | grep -E ":${EU_SERVER_PORT}\\b" | grep -q haproxy; then
    sudo journalctl -u haproxy -n 40 --no-pager >&2 || true
    _die "HAProxy не слушает :${EU_SERVER_PORT}"
  fi
  if sudo ss -lntp 2>/dev/null | grep -E ":${EU_SERVER_PORT}\\b" | grep -q xray; then
    _die "xray всё ещё на :${EU_SERVER_PORT} — старый Vision-inbound. Перезапустите ./main.sh"
  fi
  for n in 1 2 3 4 5 6 7 8 9 10; do
    if sudo ss -lntp 2>/dev/null | grep -E ":${XRAY_XHTTP_PORT}\\b" | grep -q xray; then
      break
    fi
    echo "ждём, пока xray откроет ${XRAY_XHTTP_LISTEN}:${XRAY_XHTTP_PORT} (${n}/10)..."
    sleep 1
  done
  if ! sudo ss -lntp 2>/dev/null | grep -E ":${XRAY_XHTTP_PORT}\\b" | grep -q xray; then
    sudo journalctl -u xray -n 40 --no-pager >&2 || true
    _die "xray не слушает ${XRAY_XHTTP_LISTEN}:${XRAY_XHTTP_PORT}"
  fi
  local code tmp
  tmp="$(mktemp)"
  code="$(curl -4sk --http1.1 --resolve "${DOMAIN_NAME}:${EU_SERVER_PORT}:127.0.0.1" -o "$tmp" -w '%{http_code}' --max-time 10 "$url" || true)"
  if [[ "$code" != "200" ]] || ! grep -q '^vless://' "$tmp" || ! grep -q 'type=xhttp' "$tmp"; then
    echo "HTTP ${code} с ${url} (через 127.0.0.1)" >&2
    head -c 400 "$tmp" >&2 || true
    echo >&2
    rm -f "$tmp"
    _die "подписка не отдаёт XHTTP-ссылку. GET /$SUBS_PATH/update_subs_link идёт в HAProxy → nginx."
  fi
  echo "подписка отвечает: $url"
  rm -f "$tmp"
}
