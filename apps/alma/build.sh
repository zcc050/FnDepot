#!/bin/bash
# 打包 Alma：上游 yetone/alma-releases 提供 headless 服务端 tar.gz（自带 node/bun/uv 运行时）。
# 用法: bash apps/alma/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=alma
SRC="${ROOT}/apps/${APP}/src"
read -r VER PUBLISHED TAG <<<"$(app_version "$APP")"
[ -n "${TAG:-}" ] || { echo "取不到 alma 最新版本" >&2; exit 1; }
# 上游一天几十个版本，追最新不现实；PIN_VERSION 用于锁定某个已验证的版本
if [ -n "${PIN_VERSION:-}" ]; then
    VER="$PIN_VERSION"; TAG="v${PIN_VERSION}"; PUBLISHED="$(date -Iseconds)"
    echo "  pinned to ${VER}"
fi
SLUG="linux-x64"
is_arm && SLUG="linux-arm64"
ASSET="alma-server-${VER}-${SLUG}.tar.gz"
PKG_VER="$(pkg_version "$APP" "$VER")"
echo "alma ${VER} (${ARCH}) -> package ${PKG_VER}"

TGZ="$(cache_dir ${APP})/${ASSET}"
# 226MB 的包解出来 610MB，改 fpk 自身文件（图标、脚本）时不必重下一遍
if [ "${SKIP_FETCH:-}" = "1" ] && [ -x "${SRC}/app/server/bin/alma-server" ]; then
    echo "  复用已有 server 目录（SKIP_FETCH=1）"
else
    download "https://github.com/yetone/alma-releases/releases/download/${TAG}/${ASSET}" "$TGZ"
    rm -rf "${SRC}/app/server"
    mkdir -p "${SRC}/app/server"
    tar -xzf "$TGZ" -C "${SRC}/app/server" --strip-components=1
fi
chmod +x "${SRC}/app/server/bin/alma-server" "${SRC}/app/server/go/alma-server" \
         "${SRC}/app/server/runtime/node" 2>/dev/null
[ -x "${SRC}/app/server/bin/alma-server" ] || { echo "解包后找不到 bin/alma-server" >&2; exit 1; }

set_manifest "$SRC" version "$PKG_VER" platform "$ARCH"
fnpack_build "$APP"
publish "$APP" "$PKG_VER" "跟进上游 ${VER}：Alma headless 服务端，网页/手机 App 访问，前端保持原版未改动" "$PUBLISHED"
