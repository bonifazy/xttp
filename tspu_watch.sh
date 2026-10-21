#!/usr/bin/env bash
set -euo pipefail

# ROLE=edge (EU). ТСПУ сидит на канале клиента, не «сканирует с спец-IP».
# С edge видно только вход на HAProxy: пробы, обрывы TLS, идёт ли XHTTP.
# Не банит IP: среди источников РФ — клиенты.
#
# Задачи:
#   1. Счётчики HAProxy: frontend / be_xray / be_decoy / ошибки TLS
#   2. Дельты с прошлого запуска (удобно из cron каждые 5 мин)
#   3. Источники SSL handshake failure (сканеры, старый Reality, пробы)
#   4. «XHTTP молчит, а пробы живы» — возможный burn IP на ТСПУ
#   5. Xray не должен слушать публично (только 127.0.0.1:10085)
#
# XHTTP в haproxy.cfg silent — IP клиентов туннеля в journal нет, только stot.
#
# cron (sudo crontab, ROLE=edge):
#   */5 * * * * /home/dim/xttp/tspu_watch.sh >> /home/dim/xttp/logs/tspu_watch.log 2>&1

# shellcheck disable=SC1091
source /home/dim/xttp/common.sh

STATE_FILE="${SCRIPT_DIR}/.tspu_watch_state"
HAPROXY_SOCK="${HAPROXY_SOCK:-/run/haproxy/admin.sock}"
WINDOW_SEC="${TSPU_WATCH_WINDOW:-300}"
XHTTP_SILENCE_SEC="${TSPU_XHTTP_SILENCE:-3600}"

if [[ "$ROLE" != "edge" ]]; then
  echo "tspu_watch.sh для ROLE=edge (сейчас: ${ROLE})"
  exit 0
fi

_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

mkdir -p "${SCRIPT_DIR}/logs"

tls_port=443
if [[ "$ROLE" == "edge" ]]; then
  tls_port="$EU_SERVER_PORT"
fi

now="$(date +%s)"
now_iso="$(date -Iseconds)"

echo "===== tspu_watch ${now_iso} ====="
echo "ROLE=${ROLE} DOMAIN=${DOMAIN_NAME} TLS_PORT=${tls_port}"

echo "--- listeners ---"
ss_out="$(_sudo ss -lntp 2>/dev/null || ss -lnt)"
printf '%s\n' "$ss_out" | grep -E ":${tls_port}\\b|:80\\b|:10085\\b|:8888\\b|:8081\\b" || true
if printf '%s\n' "$ss_out" | grep -E ":${tls_port}\\b" | grep -q xray; then
  echo "ALERT: xray слушает публичный :${tls_port} — должен быть только HAProxy"
fi
if printf '%s\n' "$ss_out" | grep -E ":10085\\b" | grep -qE '0\\.0\\.0\\.0:10085|\\*:10085'; then
  echo "ALERT: xray :10085 не только 127.0.0.1"
fi

stat_csv=""
if [[ -S "$HAPROXY_SOCK" ]]; then
  stat_csv="$(_sudo socat - UNIX-CONNECT:"$HAPROXY_SOCK" <<<"show stat" 2>/dev/null || true)"
else
  echo "нет ${HAPROXY_SOCK} — HAProxy не запущен или нет прав"
fi

eval "$("$PYTHON" - "$stat_csv" <<'PY'
import csv, io, sys
raw = sys.argv[1]
fe = xr = decoy = ssl_err = -1
if raw.strip():
    buf = io.StringIO(raw.lstrip("# "))
    for row in csv.reader(buf):
        if len(row) < 8:
            continue
        px, sv = row[0], row[1]
        def n(i):
            try:
                return int(row[i] or 0)
            except ValueError:
                return 0
        if px == "fe_tls" and sv == "FRONTEND":
            fe = n(7)
            ssl_err = n(12)  # ereq
        elif px == "be_xray" and sv == "BACKEND":
            xr = n(7)
        elif px == "be_decoy" and sv == "BACKEND":
            decoy = n(7)
print(f"FE_STOT={fe}")
print(f"XRAY_STOT={xr}")
print(f"DECOY_STOT={decoy}")
print(f"FE_EREQ={ssl_err}")
PY
)"

echo "--- haproxy counters (cumulative) ---"
echo "frontend_stot=${FE_STOT} be_xray_stot=${XRAY_STOT} be_decoy_stot=${DECOY_STOT} frontend_ereq=${FE_EREQ}"

prev_ts=0
prev_fe=0
prev_xr=0
prev_decoy=0
prev_ereq=0
xhttp_last=0
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  prev_ts="${prev_ts:-0}"
  prev_fe="${prev_fe:-0}"
  prev_xr="${prev_xr:-0}"
  prev_decoy="${prev_decoy:-0}"
  prev_ereq="${prev_ereq:-0}"
  xhttp_last="${xhttp_last:-0}"
fi

dt="$WINDOW_SEC"
if [[ "$prev_ts" -gt 0 ]]; then
  dt=$((now - prev_ts))
  [[ "$dt" -lt 1 ]] && dt=1
fi

d_fe=0
d_xr=0
d_decoy=0
d_ereq=0
if [[ "$FE_STOT" -ge 0 && "$prev_fe" -ge 0 && "$FE_STOT" -ge "$prev_fe" ]]; then
  d_fe=$((FE_STOT - prev_fe))
fi
if [[ "$XRAY_STOT" -ge 0 && "$prev_xr" -ge 0 && "$XRAY_STOT" -ge "$prev_xr" ]]; then
  d_xr=$((XRAY_STOT - prev_xr))
fi
if [[ "$DECOY_STOT" -ge 0 && "$prev_decoy" -ge 0 && "$DECOY_STOT" -ge "$prev_decoy" ]]; then
  d_decoy=$((DECOY_STOT - prev_decoy))
fi
if [[ "$FE_EREQ" -ge 0 && "$prev_ereq" -ge 0 && "$FE_EREQ" -ge "$prev_ereq" ]]; then
  d_ereq=$((FE_EREQ - prev_ereq))
fi

echo "--- delta ${dt}s ---"
echo "frontend +${d_fe}  xhttp +${d_xr}  decoy +${d_decoy}  ereq +${d_ereq}"

if [[ "$d_xr" -gt 0 ]]; then
  xhttp_last="$now"
fi

echo "--- tls handshake failures (journal ${WINDOW_SEC}s) ---"
fail_log="$(_sudo journalctl -u haproxy --since "${WINDOW_SEC} sec ago" --no-pager 2>/dev/null || true)"
fail_n="$(printf '%s\n' "$fail_log" | grep -c 'SSL handshake failure' || true)"
echo "ssl_handshake_failure=${fail_n}"
printf '%s\n' "$fail_log" | grep 'SSL handshake failure' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  | sort | uniq -c | sort -nr | head -15 || true
badreq="$(printf '%s\n' "$fail_log" | grep -c '<BADREQ>' || true)"
echo "badreq=${badreq}"

echo "--- established :${tls_port} ---"
_sudo ss -tnp state established "( sport = :${tls_port} )" 2>/dev/null | awk 'NR>1{c++} END{print "n=" (c+0)}'

echo "--- hints ---"
if [[ "$d_xr" -eq 0 && ( "$fail_n" -gt 20 || "$d_decoy" -gt 30 ) ]]; then
  echo "HINT: XHTTP не рос, а TLS-пробы/декой шли. Сканеры есть; это ещё не бан ТСПУ."
fi
if [[ "$xhttp_last" -gt 0 ]]; then
  silent=$((now - xhttp_last))
  echo "last_xhttp_ago=${silent}s"
  if [[ "$silent" -ge "$XHTTP_SILENCE_SEC" && ( "$fail_n" -gt 5 || "$d_decoy" -gt 5 ) ]]; then
    echo "ALERT: XHTTP тишина >${XHTTP_SILENCE_SEC}s при живом входе на :${tls_port}."
    echo "ALERT: с РФ клиенты могли перестать доходить (IP/порт/SNI в ТСПУ). Проверка — с RU VPS, не с edge."
  fi
elif [[ "$prev_ts" -gt 0 && "$XRAY_STOT" -eq 0 ]]; then
  echo "HINT: be_xray.stot=0 с начала учёта — либо нет клиентов, либо туннель не бьётся в HAProxy."
fi
if [[ "$d_xr" -gt 0 && "$fail_n" -gt 30 ]]; then
  echo "HINT: клиенты есть и одновременно шторм handshake failure — пробы параллельно, не обязательно 'сканер затем бан'."
fi

umask 077
cat > "$STATE_FILE" <<EOF
prev_ts=${now}
prev_fe=${FE_STOT}
prev_xr=${XRAY_STOT}
prev_decoy=${DECOY_STOT}
prev_ereq=${FE_EREQ}
xhttp_last=${xhttp_last}
EOF
chown_project_user "$STATE_FILE" 2>/dev/null || true

echo "===== end ====="
echo ""
