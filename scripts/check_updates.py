#!/usr/bin/env python3
"""检查 apps/* 是否有上游新版本（对比 dist/<arch>.json 里已构建的版本）。

上游仓库由 `scripts/lib.sh` 的 `app_release_repo()` 统一维护，本脚本通过
`bash scripts/lib.sh version <app>` 取最新稳定版，避免版本来源两处硬编码。

用法:
    python3 scripts/check_updates.py            # 人读表格
    python3 scripts/check_updates.py --json     # 机器读
    python3 scripts/check_updates.py --arch arm # 只关心某个架构

退出码: 0 全部最新；10 有更新；2 检查失败（网络/配置）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "scripts", "lib.sh")


def ver_tuple(v: str) -> tuple:
    parts = []
    for p in re.split(r"[.\-+]", v):
        parts.append((0, int(p)) if p.isdigit() else (1, p))
    return tuple(parts)


def local_versions(app_dir: str) -> dict[str, str]:
    out = {}
    dist = os.path.join(app_dir, "dist")
    if not os.path.isdir(dist):
        return out
    for name in os.listdir(dist):
        if name.endswith(".json"):
            try:
                d = json.load(open(os.path.join(dist, name), encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            if d.get("version") and d.get("arch"):
                out[d["arch"]] = d["version"]
    return out


def upstream_version(app: str) -> str | None:
    try:
        r = subprocess.run(["bash", LIB, "version", app], capture_output=True,
                           text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    line = r.stdout.strip().splitlines()
    if not line:
        return None
    return line[0].split()[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--arch", default="x86")
    args = ap.parse_args()

    apps_dir = os.path.join(ROOT, "apps")
    rows = []
    failed = False
    for name in sorted(os.listdir(apps_dir)):
        app_dir = os.path.join(apps_dir, name)
        if not os.path.isfile(os.path.join(app_dir, "build.sh")):
            continue
        local = local_versions(app_dir).get(args.arch)
        up = upstream_version(name)
        if up is None:
            rows.append({"app": name, "local": local, "upstream": None,
                         "update": None, "error": "取不到上游版本"})
            failed = True
            continue
        if local is None:
            rows.append({"app": name, "local": None, "upstream": up,
                         "update": True, "error": f"没有 {args.arch} 产物"})
            continue
        rows.append({"app": name, "local": local, "upstream": up,
                     "update": ver_tuple(up) > ver_tuple(local), "error": None})

    pending = [r for r in rows if r["update"]]
    if args.json:
        print(json.dumps({"arch": args.arch, "rows": rows,
                          "pending": [r["app"] for r in pending]},
                         ensure_ascii=False, indent=2))
    else:
        width = max(len(r["app"]) for r in rows) if rows else 8
        print(f"{'应用'.ljust(width)}  {'本地'.ljust(10)}  {'上游'.ljust(10)}  状态")
        for r in rows:
            state = "需要更新" if r["update"] else ("已是最新" if r["update"] is False else "检查失败")
            print(f"{r['app'].ljust(width)}  {str(r['local']).ljust(10)}  "
                  f"{str(r['upstream']).ljust(10)}  {state}{'  ('+r['error']+')' if r['error'] else ''}")
        print(f"\n{len(pending)} 个应用需要更新" + (f"：{', '.join(r['app'] for r in pending)}" if pending else ""))

    if failed:
        return 2
    return 10 if pending else 0


if __name__ == "__main__":
    sys.exit(main())
