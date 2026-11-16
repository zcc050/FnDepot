#!/bin/bash
# Shared helpers for apps/*/build.sh. Bash + curl + python3 only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

parse_arch() {  # parse_arch "$@" -> sets ARCH (x86 default, --arch arm)
    ARCH=x86
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch) ARCH="${2:?--arch 需要 x86|arm}"; shift 2 ;;
            *) echo "未知参数: $1" >&2; exit 2 ;;
        esac
    done
    case "${ARCH}" in x86|arm) ;; *) echo "arch 只能是 x86 或 arm" >&2; exit 2 ;; esac
}

is_arm() { [ "${ARCH}" = "arm" ]; }

cache_dir() { echo "${HOME}/.cache/fndepot/$1"; }

gh_json() {  # gh_json <api-path>  (token optional)
    local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "${tok}" ]; then
        curl -fsSL --retry 3 --connect-timeout 30 -H "Authorization: Bearer ${tok}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    else
        curl -fsSL --retry 3 --connect-timeout 30 -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    fi
}

# latest_release <owner/repo> [stable|any] -> "<tag> <published_at>"
# "stable" skips tags containing a pre-release word (nightly/beta/rc/alpha/preview).
latest_release() {
    gh_json "repos/$1/releases?per_page=30" | python3 -c '
import json, re, sys
want = sys.argv[1] if len(sys.argv) > 1 else "stable"
bad = re.compile(r"(nightly|alpha|beta|preview|rc)", re.I)
for r in json.load(sys.stdin):
    if r.get("draft"): continue
    if want == "stable" and (r.get("prerelease") or bad.search(r["tag_name"])): continue
    print(r["tag_name"], r["published_at"]); break
' "$2"
}

download() {  # download <url> <dest-file>; cached, resumable-ish
    local url="$1" dest="$2"
    if [ -s "$dest" ]; then echo "  cached $(basename "$dest")"; return 0; fi
    mkdir -p "$(dirname "$dest")"
    echo "  downloading $(basename "$dest")"
    curl -fL --retry 3 --connect-timeout 30 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
}

set_manifest() {  # set_manifest <src-dir> <key> <value> [key value ...]
    local src="$1"; shift
    python3 - "$src/manifest" "$@" <<'EOF'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
kv = dict(zip(pairs[::2], pairs[1::2]))
lines, seen = [], set()
for line in open(path, encoding="utf-8"):
    k = line.split("=")[0].strip()
    if k in kv:
        line, seen = f"{k:<22}= {kv[k]}\n", seen | {k}
    lines.append(line)
missing = [k for k in kv if k not in seen]
if missing:
    sys.exit(f"manifest 缺少字段: {missing}")
open(path, "w", encoding="utf-8").writelines(lines)
EOF
}

fnpack_build() {  # fnpack_build <app> -> builds src, leaves <app>.fpk in src
    local app="$1"
    local src="${ROOT}/apps/$app/src"
    chmod 755 "${src}"/cmd/*
    echo "  fnpack build"
    ( cd "$src" && fnpack build -d . ) | tail -2
    [ -f "${src}/${app}.fpk" ] || { echo "fnpack 没有产出 ${app}.fpk" >&2; exit 1; }
}

publish() {  # publish <app> <version> <changelog> <updated_at>
    local app="$1" ver="$2" changelog="$3" updated="$4"
    local src="${ROOT}/apps/$app/src" dist="${ROOT}/apps/$app/dist"
    mkdir -p "$dist"
    local name="${app}-${ver}-${ARCH}.fpk"
    mv "${src}/${app}.fpk" "${dist}/${name}"
    APP="$app" VER="$ver" ARCH="$ARCH" NAME="$name" CHANGELOG="$changelog" UPDATED="$updated" DIST="$dist" \
        python3 - <<'EOF'
import hashlib, json, os
d = os.environ
p = os.path.join(d["DIST"], d["NAME"])
meta = {"version": d["VER"], "arch": d["ARCH"], "file": d["NAME"], "size": os.path.getsize(p),
        "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
        "updated_at": d["UPDATED"], "os_min_version": "1.0.0", "changelog": d["CHANGELOG"]}
with open(os.path.join(d["DIST"], d["ARCH"] + ".json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2); f.write("\n")
print(f"  -> {p} ({meta['size']} bytes, sha256 {meta['sha256'][:12]}…)")
EOF
}
