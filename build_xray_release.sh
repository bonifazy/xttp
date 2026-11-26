#!/usr/bin/env bash
# Скачать официальный linux-релиз XTLS/Xray-core (amd64 + arm64). Go на Mac не нужен.
# На VPS не качаем. Запуск: ./build_xray_release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST="${SCRIPT_DIR}/xray-core"

_die() { echo "$*" >&2; exit 1; }

mkdir -p "$DIST"
tag="$(head -n 1 "${DIST}/XTLS_TAG" 2>/dev/null | tr -d '[:space:]')"
tag="${tag:-v26.11.9}"
[[ "$tag" == v* ]] || _die "XTLS_TAG: ожидается тег вида v26.11.9, сейчас: ${tag}"
command -v unzip >/dev/null 2>&1 || _die "нет unzip"
command -v curl >/dev/null 2>&1 || _die "нет curl"

base="https://github.com/XTLS/Xray-core/releases/download/${tag}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch_zip() {
  local zip_name="$1" linux_arch="$2"
  local zip="${tmp}/${zip_name}" out="${DIST}/xray-linux-${linux_arch}"
  local url="${base}/${zip_name}" want have
  echo "XTLS ${tag} ${zip_name}"
  curl -fL --retry 1 -m 30 -A "xttp" -o "$zip" "$url" || _die "не скачался ${url}"
  if curl -fL --retry 1 -m 15 -A "xttp" -o "${zip}.dgst" "${url}.dgst"; then
    want="$(awk 'tolower($0) ~ /sha256/ { print $NF; exit }' "${zip}.dgst")"
    have="$(shasum -a 256 "$zip" | awk '{print $1}')"
    want="$(printf '%s' "$want" | tr 'A-F' 'a-f')"
    have="$(printf '%s' "$have" | tr 'A-F' 'a-f')"
    if [[ -n "$want" && "$want" != "$have" ]]; then
      _die "SHA256 ${zip_name}: ожидали ${want}, получили ${have}"
    fi
  else
    echo "  нет ${zip_name}.dgst, SHA256 не проверяю" >&2
  fi
  mkdir -p "${tmp}/${linux_arch}"
  unzip -qo "$zip" xray -d "${tmp}/${linux_arch}" || _die "в ${zip_name} нет xray"
  install -m 755 "${tmp}/${linux_arch}/xray" "$out"
  echo "  $(ls -lh "$out" | awk '{print $5, $NF}')"
}

fetch_zip Xray-linux-64.zip amd64
fetch_zip Xray-linux-arm64-v8a.zip arm64

{
  echo "${tag}"
  echo "source=https://github.com/XTLS/Xray-core/releases/tag/${tag}"
  echo "assets=Xray-linux-64.zip Xray-linux-arm64-v8a.zip"
  echo "fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DIST}/xray-linux.BUILD"
echo "Готово: официальный ${tag} → ${DIST}/xray-linux-amd64 и xray-linux-arm64"
