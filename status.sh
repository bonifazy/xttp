#!/usr/bin/env bash
#
# Сводка xttp: сервисы, контейнеры, URL подписки для REST-клиента.
# Не меняет конфиги. Запуск: /home/dim/xttp/status.sh
set -uo pipefail

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

_ok() { printf 'OK    %s\n' "$*"; }
_fail() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
_skip() { printf 'SKIP  %s\n' "$*"; }

FAIL=0
_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

echo "===== xttp status ====="
echo "ROLE=${ROLE}  DOMAIN=${DOMAIN_NAME}  CLIENT_PORT=${CLIENT_PORT}"
if [[ "$ROLE" == "relay" || "$ROLE" == "edge" ]]; then
  echo "DOWNLOAD_PORT=${DOWNLOAD_LISTEN:-0}  CLIENT_MODE=${CLIENT_MODE}"
fi
echo ""

echo "--- systemd ---"
for u in xray haproxy nginx docker; do
  st="$(systemctl is-active "$u" 2>/dev/null || true)"
  if [[ "$st" == "active" ]]; then
    _ok "${u} ${st}"
  else
    _fail "${u} ${st:-unknown}"
  fi
done

echo ""
echo "--- processes ---"
_proc() {
  local name="$1" bin="$2"
  local pids
  pids="$(pgrep -x "$bin" 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$pids" ]]; then
    _ok "${name}: ${pids}"
  else
    _fail "${name}: нет процесса ${bin}"
  fi
}
_proc xray xray
_proc haproxy haproxy
_proc nginx nginx
_proc adguard AdGuardHome

echo ""
echo "--- docker ---"
if command -v docker >/dev/null 2>&1; then
  dps="$(_sudo docker ps -a --filter name=xttp- --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  if [[ -z "$dps" ]]; then
    _fail "нет контейнеров xttp-*"
  else
    while IFS=$'\t' read -r name st; do
      [[ -z "$name" ]] && continue
      if [[ "$st" == Up* ]]; then
        _ok "${name}  ${st}"
      else
        _fail "${name}  ${st}"
      fi
    done <<< "$dps"
  fi
  if ! printf '%s\n' "$dps" | grep -q '^xttp-adguard'; then
    _fail "xttp-adguard не найден"
  fi
else
  _fail "docker не установлен"
fi

echo ""
echo "--- warp ---"
warp_hit=0
for u in warp-svc cloudflare-warp wg-quick@wgcf wg-quick@warp; do
  st="$(systemctl is-active "$u" 2>/dev/null || true)"
  if [[ "$st" == "active" ]]; then
    _ok "systemd ${u}"
    warp_hit=1
  fi
done
if command -v warp-cli >/dev/null 2>&1; then
  _ok "warp-cli: $(warp-cli status 2>/dev/null | tr '\n' ' ' | head -c 120)"
  warp_hit=1
fi
if ip link show CloudflareWARP >/dev/null 2>&1 || ip link show wgcf >/dev/null 2>&1; then
  _ok "warp iface: $(ip -o link show | awk -F': ' '/CloudflareWARP|wgcf|warp/{print $2}' | tr '\n' ' ')"
  warp_hit=1
fi
if [[ -f "$XRAY_CONFIG" ]]; then
  warp_xray="$(_sudo "$PYTHON" - "$XRAY_CONFIG" <<'PY' 2>/dev/null || true
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
hits = []
for o in c.get("outbounds") or []:
    tag = str(o.get("tag") or "")
    proto = str(o.get("protocol") or "")
    if proto == "wireguard" or "warp" in tag.lower():
        hits.append(f"{tag}:{proto}")
print(" ".join(hits))
PY
)"
  if [[ -n "${warp_xray:-}" ]]; then
    _ok "xray outbound ${warp_xray}"
    warp_hit=1
  fi
fi
if [[ "$warp_hit" -eq 0 ]]; then
  _skip "WARP не настроен (нет unit/iface/xray wireguard)"
fi

echo ""
echo "--- ports ---"
ss_out="$(ss -lnt 2>/dev/null || true)"
_port() {
  local p="$1" want="$2"
  if printf '%s\n' "$ss_out" | grep -qE ":${p}\\b"; then
    _ok "listen :${p} (${want})"
  else
    _fail "нет :${p} (${want})"
  fi
}
_port 80 http
_port "$CLIENT_PORT" "HAProxy TLS POST"
[[ -n "${DOWNLOAD_LISTEN:-}" ]] && _port "$DOWNLOAD_LISTEN" "HAProxy TLS GET"
_port 10085 "xray xhttp"
_port 8081 nginx
_port 8888 searxng
_port 5353 adguard-dns
_port 3000 adguard-ui

echo ""
echo "--- subscription ---"
hap_paths="$(_sudo "$PYTHON" - "$HAPROXY_CFG" <<'PY' 2>/dev/null || true
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
seen = []
for m in re.finditer(r"acl is_subs\s+path(?:_beg)?\s+(\S+)", text):
    p = m.group(1).strip("/")
    p = p.replace("update_subs_link", "").strip("/")
    if p and p not in seen:
        seen.append(p)
print("\n".join(seen))
PY
)"
primary="${SUBS_PATH:-}"
if [[ -z "$primary" ]]; then
  primary="$(printf '%s\n' "$hap_paths" | head -n1)"
fi
if [[ -z "$primary" ]]; then
  _fail "нет SUBS_PATH (secrets и HAProxy пусты)"
  echo "SUBS_URL="
else
  url="$(https_url "$DOMAIN_NAME" "${primary}/update_subs_link" "$CLIENT_PORT")"
  f="/var/www/html/${primary}/update_subs_link"
  if [[ -f "$f" ]]; then
    _ok "file ${f}"
  else
    _fail "нет файла ${f}"
  fi
  if printf '%s\n' "$hap_paths" | grep -qx "$primary"; then
    _ok "HAProxy is_subs /${primary}/"
  else
    hap_list="$(printf '%s' "$hap_paths" | tr '\n' ' ')"
    _fail "HAProxy не отдаёт /${primary}/ (is_subs: ${hap_list})"
  fi
  tmp="$(mktemp)"
  code="$(curl -4sk --http1.1 --max-time 8 -o "$tmp" -w '%{http_code}' --resolve "${DOMAIN_NAME}:${CLIENT_PORT}:127.0.0.1" "$url" || true)"
  if [[ "$code" == "200" ]] && grep -q '^vless://' "$tmp"; then
    _ok "GET ${url} HTTP ${code}"
  else
    _fail "GET ${url} HTTP ${code:-err}"
  fi
  rm -f "$tmp"
  echo ""
  echo "SUBS_URL=${url}"
  if [[ -n "$hap_paths" ]]; then
    while read -r p; do
      [[ -z "$p" || "$p" == "$primary" ]] && continue
      alt="$(https_url "$DOMAIN_NAME" "${p}/update_subs_link" "$CLIENT_PORT")"
      echo "SUBS_URL_ALT=${alt}"
    done <<< "$hap_paths"
  fi
fi

echo ""
echo "===== end ====="
exit "$FAIL"
