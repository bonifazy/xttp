#!/usr/bin/env bash
# Сборка linux-бинарника Xray на Mac (патч hello_frag / telemt #844).
# CGO=0: один ELF для Ubuntu 22.04/24.04/26.04. На VPS go build не нужен.
# Запуск: ./build_xray_release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SCRIPT_DIR}/xray-core"
DIST="${SRC}"
# Кэш Go не в ~/xttp: иначе .goroot/.gopath/.gocache раздувают проект.
CACHE_ROOT="${XTTP_GO_CACHE:-${HOME}/.cache/xttp-xray}"
GOROOT_DIR="${CACHE_ROOT}/goroot"

_die() { echo "$*" >&2; exit 1; }

if [[ ! -f "${SRC}/go.mod" || ! -f "${SRC}/transport/internet/splithttp/hello_frag.go" ]]; then
  _die "нет ${SRC} (Xray-core + hello_frag)"
fi
if [[ ! -f "${SRC}/main/main.go" ]]; then
  _die "нет ${SRC}/main/main.go"
fi

go_need="$(awk '/^go / { print $2; exit }' "${SRC}/go.mod")"
[[ -n "$go_need" ]] || _die "в ${SRC}/go.mod нет строки go"
tag="$(head -n 1 "${SRC}/XTLS_TAG" | tr -d '[:space:]')"
tag="${tag:-v26.10.17}"

host_os="$(uname -s)"
host_arch="$(uname -m)"
case "$host_os" in
  Darwin) goos=darwin ;;
  Linux) goos=linux ;;
  *) _die "сборка релиза: Darwin или Linux. Сейчас: ${host_os}" ;;
esac
case "$host_arch" in
  arm64|aarch64) goarch=arm64 ;;
  x86_64|amd64) goarch=amd64 ;;
  *) _die "архитектура хоста ${host_arch}: нужен amd64 или arm64" ;;
esac

ver="go${go_need}"
if [[ "$go_need" != *.* ]]; then
  ver="go${go_need}.0"
elif [[ "$(printf '%s' "$go_need" | tr -cd '.' | wc -c)" -eq 1 ]]; then
  ver="go${go_need}.0"
fi

export PATH="${GOROOT_DIR}/bin:${PATH}"
need_go=1
if [[ -x "${GOROOT_DIR}/bin/go" ]] && "${GOROOT_DIR}/bin/go" version 2>/dev/null | grep -qE "go${go_need}(\\b|\\.)"; then
  need_go=0
fi
if [[ "$need_go" -eq 1 ]] && command -v go >/dev/null 2>&1 && go version | grep -qE "go${go_need}(\\b|\\.)"; then
  need_go=0
fi
if [[ "$need_go" -eq 1 ]]; then
  tgz="/tmp/${ver}.${goos}-${goarch}.tar.gz"
  echo "Go ${ver} ${goos}/${goarch} → ${GOROOT_DIR}"
  _fetch_go() {
    local u
    for u in \
      "https://dl.google.com/go/${ver}.${goos}-${goarch}.tar.gz" \
      "https://go.dev/dl/${ver}.${goos}-${goarch}.tar.gz"; do
      echo "  ${u}"
      if curl -fL --retry 3 -A "xttp-build" -o "$tgz" "$u"; then
        return 0
      fi
    done
    return 1
  }
  if ! _fetch_go; then
    ver="go${go_need}"
    tgz="/tmp/${ver}.${goos}-${goarch}.tar.gz"
    _fetch_go || _die "не скачался Go ${ver}.${goos}-${goarch}"
  fi
  rm -rf "$GOROOT_DIR"
  mkdir -p "$GOROOT_DIR"
  tar -C "$GOROOT_DIR" --strip-components=1 -xzf "$tgz"
  rm -f "$tgz"
fi
command -v go >/dev/null 2>&1 || _die "нет go"
echo "go: $(go version)"

export GOPATH="${CACHE_ROOT}/gopath"
export GOCACHE="${CACHE_ROOT}/gocache"
export GOMODCACHE="${GOPATH}/pkg/mod"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"

modflag=(-mod=mod)
if [[ -d "${SRC}/vendor" ]]; then
  modflag=(-mod=vendor)
  export GOPROXY=off
fi

ldflags="-s -w -X github.com/xtls/xray-core/core.build=xttp-hello-frag"
build_one() {
  local linux_arch="$1"
  local out="${DIST}/xray-linux-${linux_arch}"
  echo "Сборка ${tag} linux/${linux_arch} (hello_frag) → ${out}"
  (
    cd "$SRC"
    CGO_ENABLED=0 GOOS=linux GOARCH="$linux_arch" go build "${modflag[@]}" \
      -trimpath -buildvcs=false \
      -ldflags "$ldflags" \
      -o "$out" ./main
  ) || _die "go build linux/${linux_arch} не удался"
  chmod 755 "$out"
  python3 -c 'import sys; sys.exit(0 if b"xttp-hello-frag" in open(sys.argv[1],"rb").read() else 1)' "$out" \
    || _die "${out}: нет xttp-hello-frag в бинарнике"
  echo "  $(ls -lh "$out" | awk '{print $5, $NF}')"
}

build_one amd64
build_one arm64

{
  echo "${tag} hello-frag"
  echo "GOOS=linux"
  echo "built_host=${goos}/${goarch}"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DIST}/xray-linux.BUILD"
echo "Готово: ${DIST}/xray-linux-amd64 и xray-linux-arm64 (Ubuntu 22.04/24.04/26.04)"
