#!/bin/bash
# 给某个应用抓商店预览图：解包 fpk → 启动 → 用无头 Chromium 截图 → 停止。
# 用法: bash scripts/preview.sh <app> [port] [张数]
# 产物: apps/<app>/Preview/1.png ...
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

APP="${1:?用法: preview.sh <app> [port] [shots]}"
PORT="${2:-18199}"
SHOTS="${3:-1}"
CHROME="${CHROME:-/vol1/@apphome/hermes-studio/data/desktop-runtime/hermes/0.23.0/linux-x64/python/ms-playwright/chromium-1254/chrome-linux64/chrome}"
FPK=$(ls "${ROOT}/apps/${APP}/dist/${APP}"-*-x86.fpk 2>/dev/null | tail -1)
[ -n "$FPK" ] || { echo "没有 ${APP} 的 x86 fpk" >&2; exit 1; }
[ -x "$CHROME" ] || { echo "找不到 Chromium: $CHROME（可用 CHROME=... 覆盖）" >&2; exit 1; }

W=$(mktemp -d /tmp/fnpreview.XXXXXX)
OUT="${ROOT}/apps/${APP}/Preview"
mkdir -p "$OUT"
cleanup() { TRIM_APPDEST="$W/dest" TRIM_PKGVAR="$W/var" TRIM_PKGHOME="$W/home" bash "$W/dest/cmd/main" stop >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/dest" "$W/var" "$W/home" "$W/chrome"
tar -xzf "$FPK" -C "$W/dest" && tar -xzf "$W/dest/app.tgz" -C "$W/dest" && rm -f "$W/dest/app.tgz"

export TRIM_APPDEST="$W/dest" TRIM_PKGVAR="$W/var" TRIM_PKGHOME="$W/home" launcher_port="$PORT"
bash "$W/dest/cmd/install_callback" >/dev/null 2>&1 || true
bash "$W/dest/cmd/main" start >/dev/null 2>&1 || { echo "FAIL start"; exit 1; }

URL=$(PORT="$PORT" python3 -c 'import json,os,sys;d=json.load(open(sys.argv[1]));e=list(d[".url"].values())[0];p=str(e["port"]).replace("${launcher_port}",os.environ["PORT"]);print(e.get("protocol","http")+"://127.0.0.1:"+p+e.get("url","/"))' "$W/dest/ui/config")
echo "== ${APP} ${URL}"
code=000
for _ in $(seq 1 45); do
    code=$(curl -sSL -c "$W/cj" -b "$W/cj" -o /dev/null -w '%{http_code}' --max-time 8 "$URL" || true)
    [ "$code" = "200" ] && break
    sleep 2
done
[ "$code" = "200" ] || { echo "FAIL 页面没起来 http=${code}"; tail -20 "$W/var/logs/${APP}.log"; exit 1; }

sleep 6   # 让前端首屏渲染完
for i in $(seq 1 "$SHOTS"); do
    "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
        --disable-dev-shm-usage --force-device-scale-factor=1 \
        --user-data-dir="$W/chrome" --window-size=1440,900 \
        --virtual-time-budget=8000 --screenshot="$OUT/${i}.png" "$URL" >/dev/null 2>&1
    [ -s "$OUT/${i}.png" ] && echo "  -> $OUT/${i}.png ($(du -h "$OUT/${i}.png" | cut -f1))" || { echo "FAIL 截图 ${i}"; exit 1; }
done
bash "$W/dest/cmd/main" stop >/dev/null 2>&1
echo "== DONE ${APP}"
