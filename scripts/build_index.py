#!/usr/bin/env python3
"""生成 FnDepot 外部源索引 fnpack.json（schema_version 2）。

数据来源：
  apps/<app>/app.json          商店展示元数据（分类、图标、预览图、维护者）
  apps/<app>/dist/<arch>.json  构建产物元数据（version/file/sha256/size/updated_at/changelog）
  fnpack.json                  已存在的索引（用于保留历史版本）

用法:
    python3 scripts/build_index.py                     # 写入 fnpack.json
    python3 scripts/build_index.py --dry-run           # 只打印
    python3 scripts/build_index.py --repo-owner xxx    # 换 release URL 前缀

每个版本对应 GitHub Release：tag = <app>-v<version>，资产 = dist 里的 fpk 文件名。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHES = ("x86", "arm")


def load(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def file_meta(path: str) -> tuple[str, int]:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest(), os.path.getsize(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--owner", default="zcc050")
    ap.add_argument("--repo", default="FnDepot")
    args = ap.parse_args()

    index_path = os.path.join(ROOT, "fnpack.json")
    index = {"schema_version": "2", "source_info": {}, "apps": {}}
    if os.path.isfile(index_path):
        index.update(load(index_path))
    index.setdefault("source_info", {})
    index["schema_version"] = "2"
    index["source_info"].setdefault("name", "zcc050 的飞牛应用源")
    index["source_info"].setdefault("author", args.owner)
    index["source_info"].setdefault(
        "homepage", f"https://github.com/{args.owner}/{args.repo}")
    index["source_info"].setdefault(
        "description", "自打包的飞牛 fnOS 第三方应用：magpie、Ekko Studio、T3 Code。")

    apps_dir = os.path.join(ROOT, "apps")
    problems: list[str] = []
    for name in sorted(os.listdir(apps_dir)):
        app_dir = os.path.join(apps_dir, name)
        meta_path = os.path.join(app_dir, "app.json")
        if not os.path.isfile(meta_path):
            continue
        meta = load(meta_path)
        entry = index["apps"].setdefault(name, {})
        entry.update({
            "display_name": meta["display_name"],
            "desc": meta["desc"],
            "platform": meta.get("platform", ["x86"]),
            "categories": meta.get("categories", []),
            "icon_url": f"./apps/{name}/{meta.get('icon', 'ICON.PNG')}",
            "preview_urls": [f"./apps/{name}/{p}" for p in meta.get("previews", [])],
            "readme_url": f"./apps/{name}/{meta.get('readme', 'README.md')}",
            "bug_report_url": meta.get("bug_report_url", f"https://github.com/{args.owner}/{args.repo}/issues"),
            "maintainer": meta["maintainer"],
            "maintainer_url": meta["maintainer_url"],
            "distributor": meta["distributor"],
            "distributor_url": meta["distributor_url"],
            "run_as": meta.get("run_as", "package"),
            "install_type": meta.get("install_type", "root"),
            "is_docker": bool(meta.get("is_docker", False)),
            "service_port": str(meta.get("service_port", "")),
        })
        releases = entry.setdefault("releases", {})

        for arch in ARCHES:
            dist_meta_path = os.path.join(app_dir, "dist", f"{arch}.json")
            fpk_guess = [f for f in os.listdir(os.path.join(app_dir, "dist"))
                         if f.endswith(f"-{arch}.fpk")] if os.path.isdir(os.path.join(app_dir, "dist")) else []
            if not os.path.isfile(dist_meta_path) or not fpk_guess:
                continue
            dist = load(dist_meta_path)
            fpk_path = os.path.join(app_dir, "dist", dist["file"])
            if not os.path.isfile(fpk_path):
                problems.append(f"{name}: dist/{arch}.json 指向的 {dist['file']} 不存在")
                continue
            sha, size = file_meta(fpk_path)
            if sha != dist.get("sha256"):
                problems.append(f"{name}: {dist['file']} sha256 与 dist/{arch}.json 不一致")
            if size != dist.get("size"):
                problems.append(f"{name}: {dist['file']} 大小 {size} != 记录 {dist.get('size')}")
            version = dist["version"]
            rel = releases.setdefault(version, {
                "changelog": dist.get("changelog", ""),
                "updated_at": dist.get("updated_at", ""),
                "os_min_version": dist.get("os_min_version", "1.0.0"),
                "packages": {},
            })
            rel["packages"][arch] = {
                "download_url": (f"https://github.com/{args.owner}/{args.repo}/releases/"
                                 f"download/{name}-v{version}/{dist['file']}"),
                "sha256": sha,
                "size": size,
            }

    # 版本按语义排序（数字段比较，非数字段回退字符串比较）
    def vkey(v: str):
        parts = []
        for p in v.replace("-", ".").split("."):
            parts.append((0, int(p)) if p.isdigit() else (1, p))
        return parts

    for name, entry in index["apps"].items():
        entry["releases"] = dict(sorted(entry.get("releases", {}).items(), key=lambda kv: vkey(kv[0])))

    # 修订号版本取代同上游版本的旧包：有 0.1.9-1 时不再暴露 0.1.9，
    # 否则客户端在 <ver> 与 <ver>-N 之间排序规则不明，可能选到旧包
    for name, entry in index["apps"].items():
        rels = entry.get("releases", {})
        for ver in list(rels):
            base = ver.rsplit("-", 1)[0]
            if base != ver and base in rels:
                del rels[base]

    text = json.dumps(index, ensure_ascii=False, indent=2) + "\n"
    if problems:
        print("索引生成失败：", file=sys.stderr)
        for p in problems:
            print("  -", p, file=sys.stderr)
        return 1
    if args.dry_run:
        print(text)
        return 0
    with open(index_path, "w", encoding="utf-8") as f:
        f.write(text)
    total = sum(len(e.get("releases", {})) for e in index["apps"].values())
    print(f"写入 {index_path}：{len(index['apps'])} 个应用 / {total} 个版本")
    for name, entry in index["apps"].items():
        latest = list(entry["releases"])[-1]
        pkgs = entry["releases"][latest]["packages"]
        arches = ",".join(sorted(pkgs))
        print(f"  {name:12} 最新 {latest:10} {arches:4} {pkgs[sorted(pkgs)[0]]['size']/1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
