#!/usr/bin/env bash
# Register this edge VPS in Cloudflare WARP and install its Xray WireGuard outbound.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WORK_DIR="${SCRIPT_DIR}/.warp-work"
SECRETS_FILE="${SCRIPT_DIR}/.warp_secrets"
WGCF_VERSION="2.3.1"
CHECKSUMS_SHA256="15ab012ba30009ca2183483b246fc3b805318a91be9f35db89dfd85e7ca635ad"

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || fail "не найден ${ENV_FILE}; скопируйте env_markup в .env"
[[ "$(id -u)" -ne 0 ]] || fail "запускайте от пользователя проекта, не через sudo"

# .env is a trusted shell config used by the project.
# shellcheck disable=SC1090
source "$ENV_FILE"
if [[ "${WARP_ENABLED:-0}" == "0" ]]; then
  printf 'WARP_ENABLED=0: пропускаю регистрацию и настройку WARP/wgcf. VPS не изменён.\n'
  exit 0
fi
[[ "${WARP_ENABLED:-}" == "1" ]] || fail "укажите WARP_ENABLED=0 или WARP_ENABLED=1 в .env"
[[ "${ROLE:-}" == "edge" ]] || fail "WARP outbound поддерживается только на ROLE=edge"
command -v curl >/dev/null || fail "нужен curl"
command -v sha256sum >/dev/null || fail "нужен sha256sum"
command -v python3 >/dev/null || fail "нужен python3"

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"
cd "$WORK_DIR"

arch="$(uname -m)"
case "$arch" in
  x86_64) wgcf_arch=amd64 ;;
  aarch64|arm64) wgcf_arch=arm64 ;;
  *) fail "неподдерживаемая архитектура для wgcf: ${arch}" ;;
esac
asset="wgcf_${WGCF_VERSION}_linux_${wgcf_arch}"
base_url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}"

curl -fsSLo checksums.txt "${base_url}/checksums.txt"
printf '%s  %s\n' "$CHECKSUMS_SHA256" checksums.txt | sha256sum -c - >/dev/null \
  || fail "SHA-256 checksum list wgcf не совпал"
grep -E "^[[:xdigit:]]{64}[[:space:]]+${asset}$" checksums.txt > asset.sha256 \
  || fail "релиз wgcf не содержит бинарник ${asset}"
curl -fsSLo "$asset" "${base_url}/${asset}"
sha256sum -c asset.sha256 >/dev/null || fail "SHA-256 бинарника wgcf не совпал"
chmod 700 "$asset"

if [[ ! -f wgcf-account.toml ]]; then
  [[ ! -f "$SECRETS_FILE" ]] || fail "есть .warp_secrets, но потерян .warp-work/wgcf-account.toml; восстановите регистрацию вручную, чтобы не заменить действующий профиль"
  printf '%s\n' "Будет создана отдельная бесплатная регистрация Cloudflare WARP для этого VPS."
  printf '%s' "wgcf неофициальный клиент Cloudflare; регистрация требует принятия условий WARP. Продолжить? [y/N] "
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || fail "регистрация отменена"
  "./${asset}" register --accept-tos
fi

"./${asset}" generate
[[ -s wgcf-profile.conf ]] || fail "wgcf не создал wgcf-profile.conf"
chmod 600 wgcf-account.toml wgcf-profile.conf

# Extract only the fields consumed by Xray; validate them before writing shell assignments.
python3 - wgcf-profile.conf "$SECRETS_FILE" <<'PY'
import configparser
import ipaddress
import os
import re
import sys
import tempfile

profile, output = sys.argv[1:]
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.read(profile)
try:
    interface = cfg["Interface"]
    peer = cfg["Peer"]
    private_key = interface["PrivateKey"].strip()
    addresses = [ipaddress.ip_interface(x.strip()) for x in interface["Address"].split(",") if x.strip()]
    public_key = peer["PublicKey"].strip()
    endpoint = peer["Endpoint"].strip()
    mtu = int(interface.get("MTU", "1280"))
except (KeyError, ValueError) as exc:
    raise SystemExit(f"некорректный WARP WireGuard профиль: {exc}")

if not re.fullmatch(r"[A-Za-z0-9+/]{42}[A-Za-z0-9+/]{1,2}=?", private_key):
    raise SystemExit("некорректный PrivateKey в профиле WARP")
if not re.fullmatch(r"[A-Za-z0-9+/]{42}[A-Za-z0-9+/]{1,2}=?", public_key):
    raise SystemExit("некорректный PublicKey в профиле WARP")
if not addresses or not re.fullmatch(r"(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.\-]+):\d+", endpoint):
    raise SystemExit("в профиле WARP отсутствует Address или Endpoint")
if not 576 <= mtu <= 1420:
    raise SystemExit("MTU профиля WARP вне диапазона 576..1420")

reserved = ""
raw_reserved = peer.get("Reserved", interface.get("Reserved", "")).strip()
if raw_reserved:
    vals = [int(x.strip()) for x in raw_reserved.strip("[]").split(",")]
    if len(vals) != 3 or any(x < 0 or x > 255 for x in vals):
        raise SystemExit("некорректное Reserved поле в WARP профиле")
    reserved = ",".join(map(str, vals))

values = {
    "WARP_PRIVATE_KEY": private_key,
    "WARP_ADDRESS": ",".join(str(x) for x in addresses),
    "WARP_RESERVED": reserved,
    "WARP_ENDPOINT": endpoint,
    "WARP_PUBLIC_KEY": public_key,
    "WARP_MTU": str(mtu),
}
body = "".join(f"{k}='{v}'\n" for k, v in values.items())
fd, temp = tempfile.mkstemp(prefix=".warp-secrets.", dir=os.path.dirname(output))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(body)
    os.chmod(temp, 0o600)
    os.replace(temp, output)
finally:
    if os.path.exists(temp):
        os.unlink(temp)
PY

printf 'WARP профиль сохранён в %s (права 600)\n' "$SECRETS_FILE"
printf 'Применяю Xray outbound и WARP_DOMAINS через main.sh...\n'
cd "$SCRIPT_DIR"
./main.sh
