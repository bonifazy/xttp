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
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
GEODATA_DIR="${GEODATA_DIR:-/usr/local/share/xray}"
GEODATA_BUNDLE="${GEODATA_BUNDLE:-${SCRIPT_DIR}/geodata}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/default}"
SEARXNG_DIR="${SCRIPT_DIR}/searxng"
ADGUARD_DIR="${SCRIPT_DIR}/adguard"
SECRETS_FILE="${SCRIPT_DIR}/.xttp_secrets"
PYTHON="${PYTHON:-python3}"
# AdGuard Home: DNS только localhost. UI не на 80/443 (там HAProxy).
ADGUARD_DNS_ADDR="127.0.0.1"
ADGUARD_DNS_PORT=5353
ADGUARD_UI_ADDR="127.0.0.1:3000"
ADGUARD_VIA_EU_PORT=1053
# Relay: заглушка dest:53 в туннель. На EU (edge/backbone) порт 53 перехватывает локальный AdGuard.
ADGUARD_VIA_EU_DEST="${ADGUARD_VIA_EU_DEST:-94.140.14.14}"
# Кеш AdGuard: min TTL (сек) подменяет короткие ответы, чтобы реже звать Яндекс/Google. 0 max = не резать длинные.
ADGUARD_CACHE_SIZE="${ADGUARD_CACHE_SIZE:-268435456}"
ADGUARD_CACHE_TTL_MIN="${ADGUARD_CACHE_TTL_MIN:-604800}"
ADGUARD_CACHE_TTL_MAX="${ADGUARD_CACHE_TTL_MAX:-0}"

# Порт магистрали: из .env, иначе 443.
# С RU ALPN на :443 часто режут — для пары relay↔backbone ставят 8443.
EU_SERVER_PORT="${EU_SERVER_PORT:-443}"
# Клиентский GET (downloadSettings). 0 — выкл. Пусто — 8443, если аплинк уже 8443 — 443.
DOWNLOAD_PORT="${DOWNLOAD_PORT:-}"
DOWNLOAD_HOST="${DOWNLOAD_HOST:-}"
DOWNLOAD_LISTEN=""
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

ROLE="${ROLE:-edge}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
# SUBS_PATH из .env игнорируем: main.sh генерирует, остальные скрипты берут из secrets.
unset SUBS_PATH
ALLOWED_IP="${ALLOWED_IP:-}"
EU_SERVER_DOMAIN="${EU_SERVER_DOMAIN:-}"
EU_SERVER_LINK="${EU_SERVER_LINK:-}"
CLIENT_MODE="${CLIENT_MODE:-stream-up}"
ACME_EMAIL="${ACME_EMAIL:-}"
EU_SNI="${EU_SERVER_DOMAIN}"
EU_XHTTP_PATH="${EU_XHTTP_PATH:-}"

if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck source=/home/dim/xttp/.xttp_secrets
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
fi

SUBS_PATH="${SUBS_PATH:-}"
LINK_FILE="/var/www/html/${SUBS_PATH}/update_subs_link"

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

if [[ -z "$DOMAIN_NAME" ]]; then
  _die "В .env пуст DOMAIN_NAME"
fi

# Wildcard-апекс: duba1e.newip.dev → newip.dev. Override: CERT_DOMAIN в .env.
# Пара лежит в ~/CERT_DOMAIN, на сервере ещё /etc/ssl/CERT_DOMAIN.
_apex_domain() {
  local h="${1:-}"
  h="${h%.}"
  h="${h%%:*}"
  [[ -z "$h" ]] && return 1
  awk -F. '{ if (NF <= 2) print $0; else print $(NF-1) "." $NF }' <<< "$h"
}
CERT_DOMAIN="${CERT_DOMAIN:-$(_apex_domain "$DOMAIN_NAME")}"
if [[ -z "$CERT_DOMAIN" ]]; then
  _die "не удалось взять апекс из DOMAIN_NAME=${DOMAIN_NAME}"
fi
SSL_DIR="${SSL_DIR:-/etc/ssl/${CERT_DOMAIN}}"
HAPROXY_CERT="${HAPROXY_CERT:-/etc/haproxy/certs/${CERT_DOMAIN}.pem}"
HOME_SSL_DIR="${HOME_SSL_DIR:-/home/${PROJECT_USER}/${CERT_DOMAIN}}"

if [[ "$ROLE" == "relay" && -z "$EU_SERVER_LINK" ]]; then
  _die "ROLE=relay требует EU_SERVER_LINK в .env (SUBS_PATH на backbone каждый main.sh новый)"
fi

if [[ ! "$EU_SERVER_PORT" =~ ^[0-9]+$ ]] || [[ "$EU_SERVER_PORT" -lt 1 || "$EU_SERVER_PORT" -gt 65535 ]]; then
  _die "EU_SERVER_PORT должен быть 1-65535. Сейчас: '${EU_SERVER_PORT}'"
fi

# relay/edge: второй вход в тот же HAProxy. Телефон POST→основной, GET→DOWNLOAD_LISTEN.
DOWNLOAD_HOST="${DOWNLOAD_HOST:-$DOMAIN_NAME}"
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  _up_port=443
  [[ "$ROLE" == "edge" ]] && _up_port="$EU_SERVER_PORT"
  if [[ "${DOWNLOAD_PORT}" == "0" ]]; then
    DOWNLOAD_LISTEN=""
  elif [[ -n "${DOWNLOAD_PORT}" ]]; then
    DOWNLOAD_LISTEN="$DOWNLOAD_PORT"
  elif [[ "$_up_port" == "8443" ]]; then
    DOWNLOAD_LISTEN="443"
  else
    DOWNLOAD_LISTEN="8443"
  fi
  if [[ -n "$DOWNLOAD_LISTEN" ]]; then
    if [[ ! "$DOWNLOAD_LISTEN" =~ ^[0-9]+$ ]] || [[ "$DOWNLOAD_LISTEN" -lt 1 || "$DOWNLOAD_LISTEN" -gt 65535 ]]; then
      _die "DOWNLOAD_PORT должен быть 1-65535 или 0. Сейчас: '${DOWNLOAD_LISTEN}'"
    fi
    if [[ "$DOWNLOAD_LISTEN" == "$_up_port" ]]; then
      _die "DOWNLOAD_PORT=${DOWNLOAD_LISTEN} совпадает с клиентским :${_up_port}. Другой порт или 0."
    fi
  fi
  unset _up_port
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

# Каталог подписки: 12–32 символа [A-Za-z0-9], длина каждый раз разная.
generate_subs_path() {
  "$PYTHON" - <<'PY'
import random, secrets, string
n = random.randint(12, 32)
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(n)))
PY
}

# Пишет .xttp_secrets текущими UUID / XHTTP_PATH / hop EU_*.
# umask 077 + chmod 600 + dim:dim, даже если пишет root из cron.
write_secrets() {
  umask 077
  {
    printf 'UUID=%s\n' "${UUID:-}"
    printf 'XHTTP_PATH=%s\n' "${XHTTP_PATH:-}"
    printf 'SUBS_PATH=%s\n' "${SUBS_PATH:-}"
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
# SUBS_PATH, который уже выставил main.sh, secrets не затирает.
ensure_secrets() {
  local keep_subs="${SUBS_PATH:-}"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Нет .xttp_secrets — генерирую UUID"
    UUID="$(generate_uuid)"
    XHTTP_PATH="/$(generate_uuid)"
    echo "XHTTP_PATH сгенерирован"
    [[ -n "$keep_subs" ]] && SUBS_PATH="$keep_subs"
    write_secrets
    LINK_FILE="/var/www/html/${SUBS_PATH}/update_subs_link"
    return 0
  fi
  # shellcheck source=/home/dim/xttp/.xttp_secrets
  # shellcheck disable=SC1091
  source "$SECRETS_FILE"
  if [[ -n "$keep_subs" ]]; then
    SUBS_PATH="$keep_subs"
  fi
  LINK_FILE="/var/www/html/${SUBS_PATH}/update_subs_link"
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
# relay/edge: XHTTP + CLIENT_MODE (телефон) + extra.downloadSettings на второй порт.
# backbone: XHTTP + EU_XHTTP_MODE (hop relay), без extra — hop один XHTTP.
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
  local dl_host="${DOWNLOAD_HOST:-$DOMAIN_NAME}"
  local dl_port=""
  if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
    client_port="$EU_SERVER_PORT"
  fi
  if [[ "$ROLE" == "backbone" ]]; then
    mode="${EU_XHTTP_MODE:-packet-up}"
  fi
  if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
    dl_port="${DOWNLOAD_LISTEN:-}"
  fi
  "$PYTHON" - "$uuid" "$DOMAIN_NAME" "$XHTTP_PATH" "$mode" "$client_port" "$dl_host" "$dl_port" <<'PY'
import json
import sys
from urllib.parse import quote
uuid, host, path, mode, port, dl_host, dl_port = sys.argv[1:]
enc_path = quote(path, safe="")
link = (
    f"vless://{uuid}@{host}:{port}?encryption=none&security=tls"
    f"&sni={host}&fp=chrome&alpn=h2&type=xhttp"
    f"&path={enc_path}&mode={mode}"
)
if dl_port:
    xh_path = path if path.startswith("/") else "/" + path
    extra = {
        "downloadSettings": {
            "address": dl_host,
            "port": int(dl_port),
            "network": "xhttp",
            "security": "tls",
            "tlsSettings": {"serverName": host, "fingerprint": "chrome", "alpn": ["h2"]},
            "xhttpSettings": {"path": xh_path, "mode": "auto"},
        }
    }
    link += "&extra=" + quote(json.dumps(extra, separators=(",", ":")), safe="")
print(link)
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
  if [[ -n "${DOWNLOAD_LISTEN:-}" ]]; then
    sudo ufw allow "${DOWNLOAD_LISTEN}/tcp" comment "HTTPS download"
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

# 1) GitHub 30 с  2) зеркала jsDelivr / Fastly  3) иначе локальные geodata/ из репозитория.
_fetch_geodat() {
  local dest="$1"
  local github="$2"
  shift 2
  echo "  1) GitHub (30s): ${github}"
  if curl -4fsSL --connect-timeout 10 --max-time 30 --retry 0 -o "$dest" "$github" \
    && _geodata_file_ok "$dest"; then
    echo "  ок GitHub"
    return 0
  fi
  rm -f "$dest"
  echo "  GitHub не успел за 30с"
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
# DNS только в AdGuard 127.0.0.1:5353.
# relay: *.ru — Яндекс DoH; hop — DNS хостера; остальное — DoH Google, fallback CF / 8.8.8.8 / 8.8.4.4.
# edge/backbone уже в EU: UDP/TCP 53 с xhttp-in → этот же AdGuard.
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
    "${EU_XHTTP_PATH:-}" "${EU_XHTTP_MODE:-packet-up}" "${CERT_DOMAIN:-}" \
    "${ADGUARD_DNS_ADDR}" "${ADGUARD_DNS_PORT}" \
    "${ADGUARD_VIA_EU_PORT}" "${ADGUARD_VIA_EU_DEST}" <<'PY'
import json, sys

(
    dst, role, uuid, xhttp_path, eu_uuid, domain, eu_host,
    eu_port, eu_sni, xhttp_mode, xlisten, xport,
    eu_xhttp_path, eu_xhttp_mode, cert_domain,
    ag_addr, ag_port, via_eu_port, via_eu_dest,
) = sys.argv[1:]
xport = int(xport)
eu_port = int(eu_port) if eu_port else 443
ag_port = int(ag_port)
via_eu_port = int(via_eu_port)


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
dns = {
    "servers": [{"address": ag_addr, "port": ag_port}],
    "queryStrategy": "UseIPv4",
    "disableFallbackIfMatch": True,
}

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
inbounds = [inbound]

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
    inbounds.append({
        "tag": "dns-via-eu",
        "listen": "127.0.0.1",
        "port": via_eu_port,
        "protocol": "dokodemo-door",
        "settings": {
            "address": via_eu_dest or "94.140.14.14",
            "port": 53,
            "network": "tcp,udp",
        },
    })
    rules = [
        {"type": "field", "inboundTag": ["dns-via-eu"], "outboundTag": "eu"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
        {"type": "field", "domain": ["geosite:category-ads-all", "geosite:category-public-tracker"], "outboundTag": "block"},
        {"type": "field", "domain": [d for d in (
            f"full:{domain}" if domain else "",
            f"full:{eu_host}" if eu_host else "",
            f"domain:{cert_domain}" if cert_domain else "",
        ) if d], "outboundTag": "direct"},
        {"type": "field", "domain": ["geosite:category-ru", "regexp:.*\\.ru$", "regexp:.*\\.su$", "domain:xn--p1ai"], "outboundTag": "direct"},
        {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
    ]
else:
    dns_local = {
        "protocol": "freedom",
        "tag": "dns-local",
        "settings": {"redirect": f"{ag_addr}:{ag_port}"},
    }
    outbounds = [direct, block, dns_local]
    rules = [
        {"type": "field", "inboundTag": ["xhttp-in"], "port": 53, "outboundTag": "dns-local"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
        {"type": "field", "domain": ["geosite:category-ads-all", "geosite:category-public-tracker"], "outboundTag": "block"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    ]

cfg = {
    "log": log,
    "dns": dns,
    "inbounds": inbounds,
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
  # sudo mkdir -p с umask 077 даёт 700 root:root — User=xray не открывает config.json
  # (Helsinki: permission denied, exit 23). Каталог 750 root:xray, файл 640.
  local cfg_dir cfg_grp
  cfg_dir="$(dirname "$XRAY_CONFIG")"
  cfg_grp="${XRAY_GROUP}"
  if [[ -z "$cfg_grp" || "$cfg_grp" == "nogroup" ]]; then
    cfg_grp=xray
  fi
  sudo mkdir -p "$cfg_dir"
  sudo chown "root:${cfg_grp}" "$cfg_dir"
  sudo chmod 750 "$cfg_dir"
  sudo install -o root -g "$cfg_grp" -m 640 /tmp/xray-config.json "$XRAY_CONFIG"
  rm -f /tmp/xray-config.json
}

write_haproxy_config() {
  if [[ -z "${XHTTP_PATH:-}" ]]; then
    echo "write_haproxy_config: нет XHTTP_PATH" >&2
    return 1
  fi
  local tls_port=443
  local h2_fe_be=0
  local hap_ver hap_maj hap_min
  if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
    tls_port="$EU_SERVER_PORT"
  fi
  # 2.4 (Ubuntu 22.04): tune.h2.initial-window-size. 2.6+: fe/be.
  # haproxy обычно в /usr/sbin — его нет в PATH у dim; с set -e это роняло main.sh.
  local hap_bin=""
  if command -v haproxy >/dev/null 2>&1; then
    hap_bin="$(command -v haproxy)"
  elif [[ -x /usr/sbin/haproxy ]]; then
    hap_bin=/usr/sbin/haproxy
  fi
  hap_ver=""
  if [[ -n "$hap_bin" ]]; then
    hap_ver="$("$hap_bin" -v 2>/dev/null | awk 'NR==1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit } }' || true)"
  fi
  hap_ver="${hap_ver%%-*}"
  hap_maj="${hap_ver%%.*}"
  hap_min="${hap_ver#*.}"; hap_min="${hap_min%%.*}"
  if [[ "${hap_maj:-0}" -gt 2 ]] || { [[ "${hap_maj:-0}" -eq 2 ]] && [[ "${hap_min:-0}" -ge 6 ]]; }; then
    h2_fe_be=1
  fi
  "$PYTHON" - "/tmp/haproxy.cfg" "$DOMAIN_NAME" "$SUBS_PATH" "$XHTTP_PATH" \
    "$ALLOWED_IP" "$HAPROXY_CERT" "$XRAY_XHTTP_LISTEN" "$XRAY_XHTTP_PORT" \
    "$NGINX_FALLBACK" "$DECOY_ADDR" "$tls_port" "$h2_fe_be" "${DOWNLOAD_LISTEN:-}" <<'PY'
import sys
dst, domain, subs, xhttp, allowed, cert, xlisten, xport, nginx, decoy, tls_port, h2_fe_be, download_port = sys.argv[1:]
tls_port = int(tls_port)
download_port = int(download_port) if download_port and download_port != "0" else 0
if h2_fe_be == "1":
    h2_window = (
        "    tune.h2.fe.initial-window-size 1048576\n"
        "    tune.h2.be.initial-window-size 1048576"
    )
else:
    h2_window = "    tune.h2.initial-window-size 1048576"
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
if download_port and download_port != tls_port:
    bind_ssl += f"\n    bind :{download_port} ssl crt {cert} alpn h2,http/1.1"
if tls_port == 443:
    redir = "    http-request redirect scheme https code 301 unless { ssl_fc || is_acme }"
else:
    redir = (
        f"    http-request redirect location https://%[hdr(host),field(1,:)]:{tls_port}%[capture.req.uri] "
        "unless { ssl_fc || is_acme }"
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
{h2_window}
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

    acl is_acme  path_beg /.well-known/acme-challenge/
    acl is_xhttp path_beg {xhttp}
    acl is_subs  path {subs_path}
{acl_ok}    http-request set-log-level silent if is_xhttp

    use_backend be_subs if is_acme
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

    location ^~ /.well-known/acme-challenge/ {{
        root /var/www/html;
        default_type text/plain;
    }}

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
  local home_crt="${HOME_SSL_DIR}/fullchain.crt"
  local home_key="${HOME_SSL_DIR}/cert.key"
  mkdir -p "$HOME_SSL_DIR"
  chmod 750 "$HOME_SSL_DIR"
  chown_project_user "$HOME_SSL_DIR"

  if [[ -f /tmp/fullchain.crt && -f /tmp/cert.key ]]; then
    echo "Сертификаты /tmp -> ${HOME_SSL_DIR}"
    sudo install -o "${PROJECT_USER}" -g "${PROJECT_USER}" -m 644 /tmp/fullchain.crt "$home_crt"
    sudo install -o "${PROJECT_USER}" -g "${PROJECT_USER}" -m 640 /tmp/cert.key "$home_key"
    rm -f /tmp/fullchain.crt /tmp/cert.key
  elif [[ -f "$home_crt" && -f "$home_key" ]]; then
    echo "Сертификаты ${HOME_SSL_DIR}"
  elif [[ -f "${SSL_DIR}/fullchain.crt" && -f "${SSL_DIR}/cert.key" ]]; then
    echo "Сертификаты ${SSL_DIR} -> ${HOME_SSL_DIR}"
    sudo install -o "${PROJECT_USER}" -g "${PROJECT_USER}" -m 644 "${SSL_DIR}/fullchain.crt" "$home_crt"
    sudo install -o "${PROJECT_USER}" -g "${PROJECT_USER}" -m 640 "${SSL_DIR}/cert.key" "$home_key"
  else
    echo "Ошибка: нет пары fullchain.crt + cert.key" >&2
    IPv4="$(curl -4sS https://api.ipify.org || true)"
    echo "DNS DOMAIN_NAME (${DOMAIN_NAME}) должен смотреть на ${IPv4}." >&2
    echo "Положите wildcard ${CERT_DOMAIN} в ${HOME_SSL_DIR}/ или в /tmp/{fullchain.crt,cert.key}" >&2
    exit 1
  fi

  echo "Установка ${HOME_SSL_DIR} -> ${SSL_DIR}"
  sudo install -o root -g root -m 755 -d "$SSL_DIR"
  sudo install -o root -g root -m 644 "$home_crt" "${SSL_DIR}/fullchain.crt"
  sudo install -o root -g "${XRAY_GROUP}" -m 640 "$home_key" "${SSL_DIR}/cert.key"
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

# Контейнер AdGuard пишет conf/work от root — dim иначе не открывает yaml.
adguard_chown_tree() {
  sudo chown -R "${PROJECT_USER}:${PROJECT_USER}" "${ADGUARD_DIR}/conf" "${ADGUARD_DIR}/work"
  sudo chmod -R u+rwX,go+rX "${ADGUARD_DIR}/conf" "${ADGUARD_DIR}/work"
}

write_adguard_base_yaml() {
  local yaml="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
http:
  address: ${ADGUARD_UI_ADDR}
dns:
  bind_hosts:
    - 127.0.0.1
  port: ${ADGUARD_DNS_PORT}
  upstream_dns_file: /opt/adguardhome/conf/upstreams.txt
  bootstrap_dns:
    - 127.0.0.53
  protection_enabled: true
  filtering_enabled: true
  safebrowsing_enabled: false
  parental_enabled: false
  safesearch_enabled: false
  aaaa_disabled: true
  cache_size: ${ADGUARD_CACHE_SIZE}
  cache_ttl_min: ${ADGUARD_CACHE_TTL_MIN}
  cache_ttl_max: ${ADGUARD_CACHE_TTL_MAX}
  cache_optimistic: true
  ratelimit: 0
  fallback_dns:
    - https://cloudflare-dns.com/dns-query
    - 8.8.8.8
    - 8.8.4.4
querylog:
  enabled: true
  file_enabled: true
  interval: 2160h
  size_memory: 1000
statistics:
  enabled: true
  interval: 2160h
tls:
  enabled: false
dhcp:
  enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
schema_version: 27
EOF
  sudo install -o "$PROJECT_USER" -g "$PROJECT_USER" -m 644 "$tmp" "$yaml"
  rm -f "$tmp"
}

# Пишет AdGuardHome.yaml (один раз) и upstreams.txt. Кеш/querylog в adguard/work не трогает.
write_adguard_config() {
  local conf_dir="${ADGUARD_DIR}/conf"
  local yaml="${conf_dir}/AdGuardHome.yaml"
  local ups="${conf_dir}/upstreams.txt"
  local ups_tmp yaml_tmp
  ADGUARD_NEED_RESTART=0
  mkdir -p "$conf_dir" "${ADGUARD_DIR}/work"
  adguard_chown_tree
  if [[ ! -f "$yaml" ]]; then
    write_adguard_base_yaml "$yaml"
    ADGUARD_NEED_RESTART=1
    echo "AdGuard: новый ${yaml} (UI ${ADGUARD_UI_ADDR}, без пароля — только localhost)"
  fi
  if [[ -f "$yaml" ]]; then
    yaml_tmp="$(mktemp)"
    sudo cat "$yaml" > "$yaml_tmp"
    if "$PYTHON" - "$yaml_tmp" "$ADGUARD_CACHE_SIZE" "$ADGUARD_CACHE_TTL_MIN" "$ADGUARD_CACHE_TTL_MAX" <<'PY'
import re, sys
path, size, ttl_min, ttl_max = sys.argv[1:]
text = open(path, encoding="utf-8").read()
wanted = {
    "cache_size": size,
    "cache_ttl_min": ttl_min,
    "cache_ttl_max": ttl_max,
    "cache_optimistic": "true",
    "cache_optimistic_max_age": "720h",
    "cache_optimistic_answer_ttl": "24h",
}
changed = False
missing = []
for key, val in wanted.items():
    line = f"  {key}: {val}"
    pat = re.compile(rf"^  {re.escape(key)}:.*$", re.M)
    m = pat.search(text)
    if m:
        if m.group(0) != line:
            text = pat.sub(line, text, count=1)
            changed = True
    else:
        pass
if changed:
    open(path, "w", encoding="utf-8").write(text)
    sys.exit(0)
sys.exit(1)
PY
    then
      sudo install -o "$PROJECT_USER" -g "$PROJECT_USER" -m 644 "$yaml_tmp" "$yaml"
      ADGUARD_NEED_RESTART=1
      echo "AdGuard: кеш size=${ADGUARD_CACHE_SIZE} ttl_min=${ADGUARD_CACHE_TTL_MIN}s ttl_max=${ADGUARD_CACHE_TTL_MAX}"
    fi
    rm -f "$yaml_tmp"
  fi
  local eu_hop="${EU_SERVER_DOMAIN:-}"
  if [[ -z "$eu_hop" && -n "${EU_SERVER_LINK:-}" ]]; then
    eu_hop="${EU_SERVER_LINK#*@}"
    eu_hop="${eu_hop%%[:/?]*}"
  fi
  ups_tmp="$(mktemp)"
  "$PYTHON" - "$ROLE" "$eu_hop" "${EU_SNI:-$eu_hop}" "${ADGUARD_VIA_EU_PORT}" <<'PY' > "$ups_tmp"
import sys
role, eu_host, eu_sni, via_port = sys.argv[1:]

def ok(h):
    h = (h or "").strip().lower().rstrip(".")
    if not h or ".." in h:
        return ""
    if not all(c.isalnum() or c in ".-" for c in h):
        return ""
    return h

def hoster_ns():
    for path in ("/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"):
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] == "nameserver":
                        ip = parts[1]
                        if ip.startswith("127.") or ip == "::1":
                            continue
                        return ip
        except OSError:
            continue
    return "127.0.0.53"

if role == "relay":
    names = []
    for h in (eu_host, eu_sni):
        n = ok(h)
        if n and n not in names:
            names.append(n)
    if names:
        print("[/" + "/".join(names) + "/]" + hoster_ns())
    print("[/common.dot.dns.yandex.net/]77.88.8.8")
    print("[/ru/su/xn--p1ai/]https://common.dot.dns.yandex.net/dns-query 77.88.8.8")
    print("[/dns.google/]8.8.8.8")
    print("[/cloudflare-dns.com/]1.1.1.1")
    print("https://dns.google/dns-query")
    print("https://cloudflare-dns.com/dns-query")
    print("8.8.8.8")
    print("8.8.4.4")
else:
    print("https://dns.adguard-dns.com/dns-query")
PY
  if [[ ! -f "$ups" ]] || ! sudo cmp -s "$ups_tmp" "$ups"; then
    sudo install -o "$PROJECT_USER" -g "$PROJECT_USER" -m 644 "$ups_tmp" "$ups"
    ADGUARD_NEED_RESTART=1
    echo "AdGuard: апстримы → ${ups}"
  fi
  rm -f "$ups_tmp"
}

adguard_compose() {
  if sudo docker compose version >/dev/null 2>&1; then
    sudo docker compose -f "${ADGUARD_DIR}/docker-compose.yml" "$@"
  else
    sudo docker-compose -f "${ADGUARD_DIR}/docker-compose.yml" "$@"
  fi
}

# TCP :5353 — AdGuard жив, не ждём апстрим.
adguard_dns_listening() {
  "$PYTHON" - "$ADGUARD_DNS_ADDR" "$ADGUARD_DNS_PORT" <<'PY'
import socket, sys
addr, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect((addr, port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

adguard_wait() {
  local n
  for n in $(seq 1 20); do
    if adguard_dns_listening; then
      echo "AdGuard слушает ${ADGUARD_DNS_ADDR}:${ADGUARD_DNS_PORT}"
      return 0
    fi
    sleep 1
  done
  return 1
}

adguard_print_logs() {
  echo "--- docker ps xttp-adguard ---" >&2
  sudo docker ps -a --filter name=xttp-adguard >&2 || true
  echo "--- docker logs xttp-adguard ---" >&2
  sudo docker logs --tail 80 xttp-adguard >&2 || true
}

# Поднимает AdGuard. Restart только если yaml/апстримы новые — иначе RAM-кеш живёт.
adguard_up() {
  local running=0 yaml="${ADGUARD_DIR}/conf/AdGuardHome.yaml"
  write_adguard_config
  if command -v docker >/dev/null 2>&1; then
    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx xttp-adguard; then
      running=1
    fi
  fi
  echo "Запуск AdGuard Home (DNS ${ADGUARD_DNS_ADDR}:${ADGUARD_DNS_PORT}, UI http://${ADGUARD_UI_ADDR})"
  adguard_compose up -d --remove-orphans
  if [[ "$running" -eq 1 && "${ADGUARD_NEED_RESTART:-0}" -eq 1 ]]; then
    echo "AdGuard: конфиг изменился — restart (RAM-кеш сбросится, querylog на диске)"
    adguard_compose restart
  fi
  if ! adguard_wait; then
    echo "AdGuard не слушает :${ADGUARD_DNS_PORT} — пишу запасной yaml и force-recreate"
    if [[ -f "$yaml" ]]; then
      sudo cp "$yaml" "${yaml}.bak-$(date +%F_%H%M%S)" || true
    fi
    write_adguard_base_yaml "$yaml"
    adguard_compose up -d --force-recreate --remove-orphans
    if ! adguard_wait; then
      adguard_print_logs
      _die "AdGuard не слушает ${ADGUARD_DNS_ADDR}:${ADGUARD_DNS_PORT}"
    fi
  fi
}

adguard_stop() {
  if [[ ! -f "${ADGUARD_DIR}/docker-compose.yml" ]]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    adguard_compose stop || true
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

# Ждём, пока HAProxy откроет порт. 10×1 с, потом _die.
_wait_haproxy_port() {
  local port="$1" n
  for n in 1 2 3 4 5 6 7 8 9 10; do
    if sudo ss -lntp 2>/dev/null | grep -E ":${port}\\b" | grep -q haproxy; then
      return 0
    fi
    echo "ждём, пока HAProxy откроет :${port} (${n}/10)..."
    sleep 1
  done
  sudo journalctl -u haproxy -n 40 --no-pager >&2 || true
  _die "HAProxy не слушает :${port}"
}

# Xray должен быть active на любой роли. Иначе HAProxy отдаёт 502 на XHTTP path
# (подписка при этом 200 — как на Helsinki). Backbone: ещё HAProxy на :EU_SERVER_PORT.
# relay/edge: второй bind DOWNLOAD_LISTEN и extra= в подписке.
assert_role_frontends() {
  local tls_port=443
  if [[ "$ROLE" == "edge" || "$ROLE" == "backbone" ]]; then
    tls_port="$EU_SERVER_PORT"
  fi
  if ! systemctl is-active --quiet xray; then
    sudo journalctl -u xray -n 40 --no-pager >&2 || true
    _die "xray не active — HAProxy :${tls_port} жив, прокси нет"
  fi
  if ! systemctl is-active --quiet haproxy; then
    sudo journalctl -u haproxy -n 40 --no-pager >&2 || true
    _die "haproxy не active — :${tls_port} должен держать HAProxy, не Xray"
  fi
  _wait_haproxy_port "$tls_port"
  if [[ -n "${DOWNLOAD_LISTEN:-}" ]]; then
    _wait_haproxy_port "$DOWNLOAD_LISTEN"
  fi
  if [[ "$ROLE" != "backbone" ]]; then
    if [[ -n "${DOWNLOAD_LISTEN:-}" ]] && ! sudo grep -q 'extra=' "$LINK_FILE" 2>/dev/null; then
      _die "подписка без extra=downloadSettings — build_vless_link"
    fi
    return 0
  fi
  local url n
  url="$(https_url "$DOMAIN_NAME" "${SUBS_PATH}/update_subs_link")"
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

# Живой запрос в AdGuard :5353 + query log. Relay: max.ru → Яндекс DoH, instagram.com → :1053 (EU).
assert_adguard_dns_split() {
  echo "Проверка DNS AdGuard: max.ru и instagram.com @${ADGUARD_DNS_ADDR}:${ADGUARD_DNS_PORT}"
  adguard_chown_tree
  "$PYTHON" - "$ROLE" "$ADGUARD_DNS_ADDR" "$ADGUARD_DNS_PORT" "$ADGUARD_UI_ADDR" \
    "${ADGUARD_DIR}/work" <<'PY' || _die "проверка DNS AdGuard не прошла"
import glob, json, os, random, socket, struct, sys, time, urllib.error, urllib.request

role, dns_addr, dns_port, ui, work = sys.argv[1:]
dns_port = int(dns_port)
base = "http://" + ui

def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        raw = label.encode()
        out += bytes([len(raw)]) + raw
    return out + b"\x00"

def dns_query(name, timeout=20):
    tid = random.randint(0, 65535)
    pkt = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    pkt += encode_name(name) + struct.pack("!HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(pkt, (dns_addr, dns_port))
        data, _ = sock.recvfrom(4096)
    finally:
        sock.close()
    if len(data) < 12:
        raise RuntimeError(f"{name}: короткий DNS-ответ")
    flags = struct.unpack("!H", data[2:4])[0]
    rcode = flags & 0xF
    if rcode != 0:
        raise RuntimeError(f"{name}: DNS rcode={rcode}")
    return True

def http_json(path, method="GET"):
    body = b"{}" if method == "POST" else None
    req = urllib.request.Request(base + path, data=body, method=method)
    req.add_header("Accept", "application/json")
    if method == "POST":
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=5) as resp:
        raw = resp.read()
    if not raw:
        return {}
    return json.loads(raw.decode())

def entry_host(entry):
    q = entry.get("question") if isinstance(entry.get("question"), dict) else {}
    for src in (q, entry):
        for key in ("host", "name", "QH", "qh"):
            val = src.get(key)
            if val:
                return str(val).rstrip(".").lower()
    return ""

def entry_up(entry):
    for key in ("upstream", "Upstream", "Up"):
        val = entry.get(key)
        if val:
            return str(val)
    return ""

def entry_ips(entry):
    out = []
    for ans in entry.get("answer") or []:
        if isinstance(ans, dict) and ans.get("value"):
            out.append(str(ans["value"]))
    return out

def iter_file_entries():
    for path in glob.glob(os.path.join(work, "data", "querylog.json*")):
        try:
            raw = open(path, encoding="utf-8").read().strip()
        except OSError:
            continue
        if not raw:
            continue
        try:
            if raw[0] == "[":
                for item in reversed(json.loads(raw)):
                    yield item
            else:
                for line in reversed(raw.splitlines()):
                    line = line.strip()
                    if line:
                        yield json.loads(line)
        except json.JSONDecodeError:
            continue

def latest_log(host):
    host = host.rstrip(".").lower()
    try:
        payload = http_json("/control/querylog?limit=50")
        items = payload.get("data")
        if isinstance(items, dict):
            items = items.get("data") or []
        for entry in items or []:
            if entry_host(entry) == host:
                return entry
    except Exception as exc:
        print(f"querylog API: {exc}", file=sys.stderr)
    for entry in iter_file_entries():
        if entry_host(entry) == host:
            return entry
    return None

ok = True
checks = (("max.ru", "yandex"), ("instagram.com", "eu"))
for host, expect in checks:
    try:
        dns_query(host, timeout=8)
    except Exception as exc:
        print(f"FAIL {host}: {exc}")
        ok = False
        continue
    entry = None
    for _ in range(10):
        time.sleep(0.4)
        entry = latest_log(host)
        if entry:
            break
    if not entry:
        print(f"FAIL {host}: ответ есть, в query log записи нет (UI {base}, {work}/data)")
        ok = False
        continue
    upstream = entry_up(entry)
    cached = bool(entry.get("cached") or entry.get("Cached"))
    ips = ", ".join(entry_ips(entry)[:4]) or "-"
    low = upstream.lower()
    if expect == "yandex":
        hit = ("yandex" in low) or ("77.88.8.8" in low)
        want = "DoH Yandex / 77.88.8.8"
    else:
        hit = ("dns.google" in low) or ("8.8.8.8" in low) or ("8.8.4.4" in low)
        hit = hit or ("cloudflare" in low) or ("1.1.1.1" in low)
        want = "DoH Google / CF / 8.8.8.8"
    if role != "relay":
        print(f"{host}: {ips}  upstream={upstream or '-'}  cached={cached}  (не relay — split не проверяем)")
        continue
    if hit:
        print(f"OK {host}: {ips}  upstream={upstream}  cached={cached}  ({want})")
    else:
        print(f"FAIL {host}: {ips}  upstream={upstream or '-'}  cached={cached}  ждали {want}")
        ok = False
sys.exit(0 if ok else 1)
PY
}
