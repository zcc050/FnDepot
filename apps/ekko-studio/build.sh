#!/bin/bash
# 打包 Ekko Studio：上游 Release 直接提供开箱即用的 Web 运行时 hermes-web-ui-<ver>.tar.gz（自带
# node_modules 与前端产物；npm 上那个瘦包不行），再配一个官方 Node 运行时即可。
# 用法: bash apps/ekko-studio/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=ekko-studio
SRC="${ROOT}/apps/${APP}/src"
CACHE="$(cache_dir ${APP})"

read -r TAG PUBLISHED <<<"$(latest_release EKKOLearnAI/ekko-studio stable)"
[ -n "${TAG:-}" ] || { echo "取不到 ekko-studio 最新版本" >&2; exit 1; }
VER="${TAG#v}"
echo "ekko-studio ${VER} (${ARCH})"

# 官方 Node LTS（v24）；nodejs.org 在本机会 TLS 断连，走镜像
NODESLUG="linux-x64"; is_arm && NODESLUG="linux-arm64"
NODEBASE="https://registry.npmmirror.com/-/binary/node"
NODEVER=$(curl -fsSL --retry 2 --max-time 60 "${NODEBASE}/index.json" | python3 -c '
import json,sys
v=[r for r in json.load(sys.stdin) if r["lts"] and r["version"].startswith("v24.")]
print(v[0]["version"])')
[ -n "${NODEVER:-}" ] || { echo "取不到 Node 版本" >&2; exit 1; }
echo "  node ${NODEVER}"

BASE="https://github.com/EKKOLearnAI/ekko-studio/releases/download/${TAG}"
TGZ="${CACHE}/hermes-web-ui-${VER}.tar.gz"
SUM="${CACHE}/hermes-web-ui-${VER}.tar.gz.sha256"
download "${BASE}/hermes-web-ui-${VER}.tar.gz" "$TGZ"
download "${BASE}/hermes-web-ui-${VER}.tar.gz.sha256" "$SUM"
if ! ( cd "$CACHE" && sha256sum -c "$(basename "$SUM")" >/dev/null 2>&1 ); then
    echo "  sha256 不匹配，重新下载" >&2
    rm -f "$TGZ"
    download "${BASE}/hermes-web-ui-${VER}.tar.gz" "$TGZ"
    ( cd "$CACHE" && sha256sum -c "$(basename "$SUM")" ) || { echo "sha256 校验失败" >&2; exit 1; }
fi
NTGZ="${CACHE}/node-${NODEVER}-${NODESLUG}.tar.xz"
download "${NODEBASE}/${NODEVER}/node-${NODEVER}-${NODESLUG}.tar.xz" "$NTGZ"

rm -rf "${SRC}/app/server/ekko" "${SRC}/app/server/node"
mkdir -p "${SRC}/app/server"
tar -xzf "$TGZ" -C "$SRC/app/server"
mv "${SRC}/app/server/$(tar -tzf "$TGZ" | head -1 | cut -d/ -f1)" "${SRC}/app/server/ekko"
tar -xJf "$NTGZ" -C "$SRC/app/server"
mv "${SRC}/app/server/node-${NODEVER}-${NODESLUG}" "${SRC}/app/server/node"
rm -rf "${SRC}/app/server/node/include" "${SRC}/app/server/node/share"
# 别的平台/架构的 native 预编译产物，Linux 上用不到，纯占体积
find "${SRC}/app/server/ekko/node_modules" -maxdepth 3 -type d \
    \( -name 'win32-*' -o -name 'darwin-*' -o -name "${NODESLUG%-*}-arm64" \) -prune -exec rm -rf {} + 2>/dev/null || true

set_manifest "$SRC" version "$VER" platform "$ARCH"
fnpack_build "$APP"
publish "$APP" "$VER" "跟进上游 ${VER}：多 Agent 工作区与可视化工作流改进，详见 https://github.com/EKKOLearnAI/ekko-studio/releases/tag/${TAG}" "$PUBLISHED"
