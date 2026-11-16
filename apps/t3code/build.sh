#!/bin/bash
# 打包 T3 Code：上游 pingdotgg/t3code 的服务器包（自带 node 运行时），取最新稳定版（跳过 nightly）。
# 用法: bash apps/t3code/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=t3code
SRC="${ROOT}/apps/${APP}/src"
read -r TAG PUBLISHED <<<"$(latest_release pingdotgg/t3code stable)"
[ -n "${TAG:-}" ] || { echo "取不到 t3code 最新稳定版" >&2; exit 1; }
VER="${TAG#v}"
SLUG="linux-x64"
is_arm && SLUG="linux-arm64"
ASSET="t3-${VER}-${SLUG}.tar.gz"
echo "t3code ${VER} (${ARCH})"

TGZ="$(cache_dir ${APP})/${ASSET}"
download "https://github.com/pingdotgg/t3code/releases/download/${TAG}/${ASSET}" "$TGZ"
rm -rf "${SRC}/app/server/t3" "${SRC}/app/server/t3-${VER}-${SLUG}"
mkdir -p "${SRC}/app/server"
tar -xzf "$TGZ" -C "${SRC}/app/server"
mv "${SRC}/app/server/t3-${VER}-${SLUG}" "${SRC}/app/server/t3"
chmod 755 "${SRC}/app/server/t3/t3"

set_manifest "$SRC" version "$VER" platform "$ARCH"
fnpack_build "$APP"
publish "$APP" "$VER" "跟进上游 ${VER}：编码 Agent 控制面、配对与远程访问改进，详见 https://github.com/pingdotgg/t3code/releases/tag/${TAG}" "$PUBLISHED"
