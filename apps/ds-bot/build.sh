#!/bin/bash
# 打包 DS Bot：上游 Fei2411/DS-Bot 是 dsh 插件（npm 包 ds-bot），NAS 上唯一官方部署路径是
# 自带 Node 的 Docker 镜像。这里改成原生包：Node 运行时 + 定版 dsh + 已装好插件的
# DSH_HOME 模板全部打进 app/server，首次启动不联网（只有调模型 API 才需要）。
# 用法: bash apps/ds-bot/build.sh [--arch x86|arm]
. "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib.sh"
parse_arch "$@"

APP=ds-bot
SRC="${ROOT}/apps/${APP}/src"
CACHE="$(cache_dir ${APP})"

# ds-bot 对 dsh 内部包声明了 peer 依赖（cordis / dsh-llm / dsh-web / dsh-tools /
# dsh-scope / dsh-typert-protocol），两个版本必须成对升级，否则启动即崩。
DSH_VERSION="${DSH_VERSION:-0.2.2-rc.1}"
NODE_VERSION="${NODE_VERSION:-24.22.3}"
PNPM_VERSION="${PNPM_VERSION:-10.14.0}"
# 国内直连 npmjs 慢，默认走镜像；要发官方源就 NPM_REGISTRY=https://registry.npmjs.org/
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com/}"

NODEBASE="https://registry.npmmirror.com/-/binary/node"
NODESLUG="linux-x64"; is_arm && NODESLUG="linux-arm64"
NODE_ARCHIVE="node-v${NODE_VERSION}-${NODESLUG}.tar.xz"

# ── 上游版本：取 npm 上的最新稳定版 ──
REPO_JSON="$(curl -fsSL --retry 3 --connect-timeout 30 "${NPM_REGISTRY}ds-bot")"
read -r VER PUBLISHED <<<"$(printf '%s' "$REPO_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = d["dist-tags"]["latest"]
print(v, d.get("time", {}).get(v, ""))
')"
[ -n "${VER:-}" ] || { echo "取不到 ds-bot 最新版本" >&2; exit 1; }
PKG_VER="$(pkg_version "$APP" "$VER")"
echo "ds-bot ${VER} (${ARCH}) -> package ${PKG_VER}  [dsh ${DSH_VERSION}, node ${NODE_VERSION}]"

rm -rf "${SRC}/app/server"
S="${SRC}/app/server"
mkdir -p "${S}/bin" "${S}/ds-bot"

# 1. Node 运行时（nodejs.org 在本机 TLS 会断，走镜像）
NTGZ="${CACHE}/${NODE_ARCHIVE}"
download "${NODEBASE}/v${NODE_VERSION}/${NODE_ARCHIVE}" "$NTGZ"
tar -xJf "$NTGZ" -C "${CACHE}"
NBIN="${CACHE}/node-v${NODE_VERSION}-${NODESLUG}/bin/node"
[ -x "$NBIN" ] || { echo "解包后找不到 node: $NBIN" >&2; exit 1; }
cp "$NBIN" "${S}/bin/node"
chmod 755 "${S}/bin/node"

# 2. dsh 本体（含 90 个依赖）
echo "  npm install @deepseek-ai/dsh@${DSH_VERSION}"
mkdir -p "${S}"
( cd "${S}" && "${CACHE}/node-v${NODE_VERSION}-${NODESLUG}/bin/npm" init -y >/dev/null 2>&1 \
  && NPM_CONFIG_CACHE="${CACHE}/npm" "${CACHE}/node-v${NODE_VERSION}-${NODESLUG}/bin/npm" \
       install "@deepseek-ai/dsh@${DSH_VERSION}" --registry "$NPM_REGISTRY" \
       --omit=dev --no-audit --no-fund ) >/dev/null || { echo "dsh 安装失败" >&2; exit 1; }

# 3. dsh 的插件管理会直接调 pnpm，别指望 NAS 上装过
echo "  bundling pnpm ${PNPM_VERSION}"
NPM_CONFIG_CACHE="${CACHE}/npm" "${CACHE}/node-v${NODE_VERSION}-${NODESLUG}/bin/npm" \
    install --global --prefix "$S" "pnpm@${PNPM_VERSION}" --registry "$NPM_REGISTRY" \
    --omit=dev --no-audit --no-fund >/dev/null || { echo "pnpm 安装失败" >&2; exit 1; }

cat > "${S}/bin/dsh" <<'EOF'
#!/bin/bash
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${BIN_DIR}/.." && pwd)"
export PATH="${BIN_DIR}:${PATH}"
exec "${BIN_DIR}/node" "${APP_DIR}/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
EOF
chmod 755 "${S}/bin/dsh"

# 4. 插件 tarball + 预先装好插件的 DSH_HOME 模板（等价于上游 Dockerfile 的构建阶段）
echo "  pack ds-bot@${VER}"
NPM_CONFIG_CACHE="${CACHE}/npm" "${CACHE}/node-v${NODE_VERSION}-${NODESLUG}/bin/npm" \
    pack "ds-bot@${VER}" --registry "$NPM_REGISTRY" --pack-destination "${S}/ds-bot" >/dev/null
mv "${S}/ds-bot"/ds-bot-*.tgz "${S}/ds-bot/ds-bot.tgz"

echo "  seeding DSH_HOME template"
rm -rf "${CACHE}/dsh-template"
DSH_HOME="${CACHE}/dsh-template" PATH="${S}/bin:${PATH}" \
    "${S}/bin/dsh" plugin --profile web add "${S}/ds-bot/ds-bot.tgz" >/dev/null 2>&1 \
    || { echo "插件装载失败" >&2; exit 1; }
[ -d "${CACHE}/dsh-template/profiles/web" ] || { echo "profile 目录没生成" >&2; exit 1; }
# pnpm 的操作日志对运行没用，纯占体积
find "${CACHE}/dsh-template" -type d -name 'operation-*' -exec rm -rf {} + 2>/dev/null || true
cp -a "${CACHE}/dsh-template" "${S}/dsh-template"

chmod -R u+rwX,go+rX "${S}/bin" "${S}/ds-bot" "${S}/dsh-template" 2>/dev/null || true
chmod -R 755 "${SRC}/cmd"

set_manifest "$SRC" version "$PKG_VER" platform "$ARCH"
fnpack_build "$APP"
publish "$APP" "$PKG_VER" \
    "首版：跟进上游 ${VER}（dsh ${DSH_VERSION}，Node ${NODE_VERSION}）。包内自带运行时与已装好插件的 DSH_HOME，首次启动无需联网；安装后在 Web 设置里填模型 API Key。" \
    "$PUBLISHED"
