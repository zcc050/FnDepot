#!/bin/bash
# =============================================================================
# FnDepot 自动更新流水线
# -----------------------------------------------------------------------------
# 做的事：检查上游稳定版 → 有新版就构建 fpk → 结构校验 → 真机冒烟
#        → 重建 fnpack.json → 源校验 → 提交推送 → 建 Release 并上传 → 校验下载
#
# 任一环节失败都不会发布（保留本地产物与日志，方便排查）。
#
# 用法：
#   bash scripts/auto_update.sh                 # 检查 + 构建 + 发布
#   bash scripts/auto_update.sh --dry-run       # 只看有没有更新
#   bash scripts/auto_update.sh --no-publish    # 构建到本地，不提交/不发布
#   bash scripts/auto_update.sh --only magpie    # 只处理某个应用
#   bash scripts/auto_update.sh --arch arm       # 只处理 arm 产物
#   bash scripts/auto_update.sh --allow-dirty    # 允许工作区有未提交改动（默认拒绝，避免混提交）
#
# 退出码：0 正常（含“无需更新”）；1 构建/校验失败；2 环境问题；3 发布失败
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib.sh"
STATE_DIR="${ROOT}/.auto-update"
mkdir -p "$STATE_DIR"
LOG="${STATE_DIR}/auto-update-$(date +%Y%m%d).log"
LOCK="${STATE_DIR}/lock"

DRY=0; PUBLISH=1; ONLY=""; ARCH=x86; ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY=1 ;;
        --no-publish)  PUBLISH=0 ;;
        --only)        ONLY="${2:?--only 需要应用名}"; shift ;;
        --arch)        ARCH="${2:?--arch 需要 x86|arm}"; shift ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$ARCH" in x86|arm) ;; *) echo "--arch 只支持 x86|arm" >&2; exit 2 ;; esac

exec 9>"$LOCK"
if ! flock -n 9; then
    echo "另一个 auto_update 正在运行（$LOCK），退出"
    exit 0
fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# 无人值守时凭证必须是"存好的"：优先环境变量，其次 git credential（store 文件是绝对路径，
# cron 的最小环境里也能读到）。注意不能 source lib.sh —— 它带 set -e，会改变本脚本的失败语义。
gh_credential_ok() {
    [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && return 0
    printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | grep -q '^password=.'
}

# github.com:443 会间歇性不通，无人值守时要多轮退避，不能一次失败就丢掉提交
push_retry() {
    local i
    for i in 1 2 3 4 5; do
        if git -c http.version=HTTP/1.1 push origin HEAD:main; then return 0; fi
        log "  push 第 $i 轮失败，$((i * 10))s 后重试"
        sleep $((i * 10))
    done
    return 1
}

log "===== auto_update 开始 arch=${ARCH} dry=${DRY} publish=${PUBLISH} only=${ONLY:-all}"

cd "$ROOT" || exit 2

# 工作区必须干净，否则自动提交会混进无关改动
if [ "$PUBLISH" = "1" ] && [ "$DRY" = "0" ] && [ "$ALLOW_DIRTY" = "0" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        log "FAIL 工作区有未提交改动，拒绝自动发布（用 --allow-dirty 或先提交）"
        exit 2
    fi
fi

# 发布需要 GitHub 凭证。无人值守时它必须已经存好（git credential store 的文件，或 GH_TOKEN）。
# 这里只做自检，不做交互式登录——cron 里没有 stdin。
if [ "$PUBLISH" = "1" ] && [ "$DRY" = "0" ]; then
    if ! gh_credential_ok; then
        log "FAIL 拿不到 GitHub 凭证（credential.helper=store 的文件里没有 github.com，也没有 GH_TOKEN）"
        log "     一次性修法：printf 'protocol=https\\nhost=github.com\\n\\n' | git credential approve"
        exit 2
    fi
fi

# 上次 push 失败留下的提交：先补推，否则这轮会因"dist 已是最新"而永远不再推它
if [ "$PUBLISH" = "1" ] && [ "$DRY" = "0" ]; then
    ahead="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ]; then
        log "本地领先远端 ${ahead} 个提交，先补推"
        if ! push_retry; then
            log "FAIL 补推失败，本轮跳过"
            exit 3
        fi
    fi
fi

vercmp() {  # vercmp A B -> 0 if A>B
    python3 - "$1" "$2" <<'PY'
import re, sys
def k(v): return tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.\-+]", v))
sys.exit(0 if k(sys.argv[1]) > k(sys.argv[2]) else 1)
PY
}

apps=()
for f in "$ROOT"/apps/*/build.sh; do
    a="$(basename "$(dirname "$f")")"
    [ -n "$ONLY" ] && [ "$a" != "$ONLY" ] && continue
    apps+=("$a")
done
[ "${#apps[@]}" -gt 0 ] || { log "FAIL 没有找到任何应用"; exit 2; }

updated=()
failed=()
port=18400
for app in "${apps[@]}"; do
    port=$((port+2))
    local_ver=$(python3 -c "
import json,sys
try: print(json.load(open('$ROOT/apps/$app/dist/$ARCH.json'))['version'])
except Exception: print('')
" 2>/dev/null)
    up_line="$(timeout 150 bash "$LIB" version "$app" 2>/dev/null | head -1)" || up_line=""
    up_ver="${up_line%% *}"
    if [ -z "$up_ver" ]; then
        log "WARN $app 取不到上游版本，跳过"
        failed+=("$app:version")
        continue
    fi
    if [ -n "$local_ver" ] && ! vercmp "$up_ver" "$local_ver"; then
        log "OK   $app 已是最新 $local_ver（上游 $up_ver）"
        continue
    fi

    log "----- $app: 本地 ${local_ver:-无} -> 上游 $up_ver"
    if [ "$DRY" = "1" ]; then
        log "  (dry-run) 需要构建 $app $up_ver"
        updated+=("$app:$up_ver")
        continue
    fi

    if ! bash "$ROOT/apps/$app/build.sh" --arch "$ARCH"; then
        log "FAIL $app 构建失败"
        failed+=("$app:build")
        continue
    fi
    # 包版本可能带修订号（如 0.1.4299-1），文件名与版本一律以 dist/<arch>.json 为唯一事实源
    read -r dist_file pkg_ver <<<"$(python3 -c "
import json,sys
try:
    d = json.load(open('$ROOT/apps/$app/dist/$ARCH.json'))
    print(d['file'], d['version'])
except Exception:
    print('')
")"
    if [ -z "${dist_file:-}" ] || [ ! -f "$ROOT/apps/$app/dist/$dist_file" ]; then
        log "FAIL $app 没找到构建产物（dist/$ARCH.json 缺失或指向的文件不存在）"
        failed+=("$app:artifact")
        continue
    fi
    fpk="$ROOT/apps/$app/dist/$dist_file"
    if ! python3 "$ROOT/scripts/verify_fpk.py" "$fpk"; then
        log "FAIL $app 结构校验失败"
        failed+=("$app:verify")
        continue
    fi
    # 只有 x86 能在本机真跑；arm 需要 qemu，缺失时明确跳过并标记
    if [ "$ARCH" = "x86" ]; then
        if ! bash "$ROOT/scripts/smoke.sh" "$app" "$port"; then
            log "FAIL $app 冒烟失败（端口 $port）"
            failed+=("$app:smoke")
            continue
        fi
    else
        if command -v qemu-aarch64-static >/dev/null 2>&1; then
            if ! QEMU_LD_PREFIX=/usr/aarch64-linux-gnu bash "$ROOT/scripts/smoke.sh" "$app" "$port"; then
                log "FAIL $app arm 冒烟失败"
                failed+=("$app:smoke-arm")
                continue
            fi
        else
            log "WARN $app arm 包仅做结构校验（无 qemu-aarch64-static，未真机运行）"
        fi
    fi
    updated+=("$app:$pkg_ver")
done

if [ "$DRY" = "1" ]; then
    if [ "${#failed[@]}" -gt 0 ]; then
        log "===== dry-run：有检查失败项 ${failed[*]}"
        exit 1
    fi
    log "===== dry-run：需要更新 ${updated[*]:-无}"
    exit 0
fi
if [ "${#failed[@]}" -gt 0 ]; then
    log "===== 失败项：${failed[*]}（不发布）"
    # 构建过程会改写 manifest 里的 version；失败时如果不还原，工作区就变脏，
    # 下一轮开头的「工作区必须干净」检查会直接退出——曾经因此连续空转 4 轮。
    if [ -n "$(git status --porcelain -- apps/*/src/manifest 2>/dev/null)" ]; then
        git checkout -- apps/*/src/manifest 2>/dev/null && log "  已还原 manifest（失败轮不留下脏改动）"
    fi
    exit 1
fi
if [ "${#updated[@]}" -eq 0 ]; then
    log "===== 没有需要更新的应用"
    echo '{"updated":[],"at":"'"$(date -Iseconds)"'"}' > "$STATE_DIR/last-run.json"
    exit 0
fi

log "----- 重建索引"
if ! python3 "$ROOT/scripts/build_index.py"; then
    log "FAIL 索引生成失败"
    exit 1
fi
if ! python3 "$ROOT/scripts/validate_source.py"; then
    log "FAIL 源校验失败（不发布）"
    exit 1
fi

if [ "$PUBLISH" = "0" ] || [ "$DRY" = "1" ]; then
    log "===== 已构建：${updated[*]}（--no-publish/--dry-run，不提交不发布）"
    exit 0
fi

log "----- 发布 Release"
release_failed=0
for u in "${updated[@]}"; do
    app="${u%%:*}"; ver="${u##*:}"
    if ! python3 "$ROOT/scripts/publish_release.py" --app "$app" --version "$ver" --arch "$ARCH"; then
        log "FAIL $app $ver 发布失败"
        release_failed=1
        continue
    fi
    url="https://github.com/zcc050/FnDepot/releases/download/${app}-v${ver}/${app}-${ver}-${ARCH}.fpk"
    # GitHub 资产下载会间歇超时；重试后再判失败，避免把已上传成功的 Release 误判成 404
    code=$(curl -sSL -o /dev/null -w '%{http_code}' --retry 3 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 180 -I "$url" || true)
    log "  下载地址 http=${code} ${url}"
    case "$code" in 200|302) ;; *) log "WARN 下载地址返回 ${code}"; release_failed=1 ;; esac
done

if [ "$release_failed" = "1" ]; then
    log "===== 有 Release 发布或下载校验失败，本轮不更新索引、不推送（避免索引指向 404）"
    exit 3
fi

names=""
for u in "${updated[@]}"; do names="${names} ${u%%:*}"; done
log "----- 提交并推送"
git add -A
if ! git commit -q -m "auto: 跟进上游更新${names}

$(for u in "${updated[@]}"; do echo "- ${u%%:*} ${u##*:}"; done)

由 scripts/auto_update.sh 自动构建、校验、冒烟后提交。

Co-Authored-By: Claude Code <noreply@anthropic.com>"; then
    log "FAIL git commit 失败"
    exit 3
fi
if ! push_retry; then
    log "FAIL git push 失败（本地已提交，下次运行会先补推）"
    exit 3
fi

python3 - "$STATE_DIR/last-run.json" "${updated[@]}" <<'PY'
import json, sys, datetime
data = {"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "updated": [{"app": u.split(":", 1)[0], "version": u.split(":", 1)[1]} for u in sys.argv[2:]]}
json.dump(data, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PY

log "===== 完成：${updated[*]}"
exit 0
