#!/bin/bash
# 解包 fpk 并在 /tmp 里跑一遍真实生命周期，验证装完能打开。
# 用法: bash scripts/smoke.sh <app> [port]
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

APP="${1:?用法: smoke.sh <app> [port]}"
PORT="${2:-18199}"
FPK=$(ls -t "${ROOT}/apps/${APP}"/dist/"${APP}"-*-x86.fpk 2>/dev/null | head -1)
[ -n "$FPK" ] || { echo "没有找到 ${APP} 的 x86 fpk" >&2; exit 1; }

W=$(mktemp -d /tmp/fnsmoke.XXXXXX)
trap 'TRIM_APPDEST=$W/dest TRIM_PKGVAR=$W/var TRIM_PKGHOME=$W/home bash $W/cmd/main stop >/dev/null 2>&1; rm -rf $W' EXIT
mkdir -p "$W/dest" "$W/var" "$W/home"
tar -xzf "$FPK" -C "$W/dest" 2>/dev/null
tar -xzf "$W/dest/app.tgz" -C "$W/dest" && rm -f "$W/dest/app.tgz"
# 生产布局：cmd/* 装在 /var/apps/<app>/cmd，和 $TRIM_APPDEST 是两个不同目录。
# 原来沙箱把 cmd 留在 dest 里，掩盖了「脚本不能假设自己在安装目录下」这类 bug（alma 就踩过）。
mkdir -p "$W/cmd" && cp -a "$W/dest/cmd/." "$W/cmd/" && rm -rf "$W/dest/cmd"
CMD="$W/cmd"

export TRIM_APPDEST="$W/dest" TRIM_PKGVAR="$W/var" TRIM_PKGHOME="$W/home" launcher_port="$PORT"
# magpie 还要一个网关端口：冲烟时避开生产在用的 3425
[ "$APP" = "magpie" ] && export MAGPIE_GATEWAY_PORT="${MAGPIE_GATEWAY_PORT:-$((PORT+100))}"
echo "== ${APP} $(basename "$FPK") port ${PORT}"
bash "$CMD/install_callback" >/dev/null 2>&1 || echo "install_callback rc=$?"

bash "$CMD/main" start || { echo "FAIL start"; tail -20 "$W/var/logs/${APP}.log"; exit 1; }

# 端口与路径由 cmd/main 在启动后写入 ui/config（magpie 带 key，t3code 带配对令牌），启动后再读。
URL=$(PORT="$PORT" python3 -c 'import json,os,sys;d=json.load(open(sys.argv[1]));e=list(d[".url"].values())[0];p=str(e["port"]).replace("${launcher_port}",os.environ["PORT"]);print(e.get("protocol","http")+"://127.0.0.1:"+p+e.get("url","/"))' "$W/dest/ui/config")
echo "== ui/config -> ${URL}"
code=000
for _ in $(seq 1 40); do
    code=$(curl -sSL -c "$W/cj" -b "$W/cj" -o /dev/null -w '%{http_code}' --max-time 8 "$URL" || true)
    [ "$code" = "200" ] && break
    sleep 2
done
bash "$CMD/main" status; st=$?
echo "== http=${code} status_rc=${st}"
[ "$code" = "200" ] && [ "$st" = "0" ] || { echo "FAIL"; tail -30 "$W/var/logs/${APP}.log"; exit 1; }
bash "$CMD/main" stop
sleep 2
if ss -tln | grep -q ":${PORT} "; then echo "FAIL 端口 ${PORT} 未释放"; exit 1; fi
echo "== PASS ${APP}"
