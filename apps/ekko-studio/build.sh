#!/bin/bash
# 打包 Ekko Studio：上游 Release 直接提供开箱即用的 Web 运行时 hermes-web-ui-<ver>.tar.gz（自带
# node_modules 与前端产物；npm 上那个瘦包不行），再配一个官方 Node 运行时即可。
# 用法: bash apps/ekko-studio/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=ekko-studio
SRC="${ROOT}/apps/${APP}/src"
CACHE="$(cache_dir ${APP})"

read -r VER PUBLISHED TAG <<<"$(app_version "$APP")"
[ -n "${TAG:-}" ] || { echo "取不到 ekko-studio 最新版本" >&2; exit 1; }
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
# 资产名跟的是内部版本（如 tag v1.1.0 里是 hermes-web-ui-0.8.27.tar.gz），
# 不能拿 tag 的版本号直接拼——拼出来是 404（曾让整条流水线连续失败）
UI_ASSET="$(gh_json "repos/EKKOLearnAI/ekko-studio/releases/tags/${TAG}" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
names = [a["name"] for a in d.get("assets", [])
         if a["name"].startswith("hermes-web-ui-") and a["name"].endswith(".tar.gz")]
print(sorted(names)[-1] if names else "")
')"
[ -n "${UI_ASSET:-}" ] || { echo "release ${TAG} 里找不到 hermes-web-ui-*.tar.gz 资产" >&2; exit 1; }
echo "  资产 ${UI_ASSET}"
TGZ="${CACHE}/${UI_ASSET}"
SUM="${CACHE}/${UI_ASSET}.sha256"
download "${BASE}/${UI_ASSET}" "$TGZ"
download "${BASE}/${UI_ASSET}.sha256" "$SUM"
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
