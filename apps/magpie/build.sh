#!/bin/bash
# 打包 magpie：上游 yetone/magpie 是 Go 单文件，二进制发布在 yetone/magpie-releases。
# 用法: bash apps/magpie/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=magpie
SRC="${ROOT}/apps/${APP}/src"
read -r VER PUBLISHED TAG <<<"$(app_version "$APP")"
[ -n "${TAG:-}" ] || { echo "取不到 magpie 最新版本" >&2; exit 1; }
ASSET="magpie-cli-linux-amd64"
is_arm && ASSET="magpie-cli-linux-arm64"
echo "magpie ${VER} (${ARCH})"

BIN="$(cache_dir ${APP})/${ASSET}.${TAG}"
download "https://github.com/yetone/magpie-releases/releases/download/${TAG}/${ASSET}" "$BIN"
mkdir -p "${SRC}/app/server"
cp -f "$BIN" "${SRC}/app/server/magpie"
chmod 755 "${SRC}/app/server/magpie"

set_manifest "$SRC" version "$VER" platform "$ARCH"
fnpack_build "$APP"
publish "$APP" "$VER" "跟进上游 ${VER}：模型/供应商面板与 Agent 适配更新，详见 https://github.com/yetone/magpie/releases/tag/${TAG}" "$PUBLISHED"
