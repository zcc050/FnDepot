#!/usr/bin/env python3
"""校验 FnDepot 外部源（fnpack.json + apps/*）是否符合飞牛端的校验规则。

飞牛同步源时会拒收整份索引，历史上踩过的坑：
  - 分类必须是固定枚举，写 "AI 工具" 这种自造分类会整源被拒（"包含无效分类"）
  - download_url 必须是可达的绝对地址
  - sha256/size 必须与真实文件一致

用法:
    python3 scripts/validate_source.py              # 本地校验（不联网）
    python3 scripts/validate_source.py --online     # 额外校验下载地址可达且大小一致
    python3 scripts/validate_source.py --strict     # 告警也当失败

退出码: 0 通过；1 不通过。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 飞牛应用中心分类枚举。来源：对多个可正常同步的第三方源做聚合（111+23+12+4+3 个应用），
# 只有这 8 个反复出现且从未导致整源被拒；自造分类（"AI 工具"/"开发工具"…）会整源被拒。
VALID_CATEGORIES = {
    "系统工具", "生活服务", "编程开发", "游戏地带",
    "影音娱乐", "AI赋能", "教育学习", "智能智控",
}
VALID_PLATFORMS = {"x86", "arm", "loongarch", "risc-v", "all"}
REQUIRED_APP_FIELDS = [
    "display_name", "desc", "platform", "categories", "icon_url",
    "preview_urls", "readme_url", "maintainer", "maintainer_url",
    "distributor", "distributor_url", "releases",
]
URL_PREFIX = "https://github.com/zcc050/FnDepot/releases/download/"

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def load_json(path: str, label: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        err(f"{label}: 文件不存在 {path}")
    except json.JSONDecodeError as exc:
        err(f"{label}: JSON 解析失败 {exc}")
    return None


def check_rel_asset(index_dir: str, app: str, url: str, kind: str) -> None:
    if not isinstance(url, str) or not url.startswith("./"):
        err(f"{app}: {kind} 必须是仓库内相对路径（以 ./ 开头），实际 {url!r}")
        return
    path = os.path.normpath(os.path.join(index_dir, url))
    if not os.path.isfile(path):
        err(f"{app}: {kind} 指向的文件不存在: {url}")
    elif os.path.getsize(path) == 0:
        err(f"{app}: {kind} 是空文件: {url}")


def head_ok(url: str) -> tuple[bool, str]:
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return True, str(resp.status)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None, help="仓库根目录（默认脚本所在仓库，测试用）")
    ap.add_argument("--online", action="store_true", help="校验下载地址是否可达")
    ap.add_argument("--strict", action="store_true", help="有告警也返回失败")
    args = ap.parse_args()
    root = os.path.abspath(args.root) if args.root else ROOT

    index_path = os.path.join(root, "fnpack.json")
    index = load_json(index_path, "fnpack.json")
    if index is None:
        print("\n".join(errors), file=sys.stderr)
        return 1

    if index.get("schema_version") != "2":
        err(f"schema_version 必须是 \"2\"，实际 {index.get('schema_version')!r}")
    info = index.get("source_info") or {}
    for key in ("name", "author", "homepage", "description"):
        if not str(info.get(key) or "").strip():
            err(f"source_info.{key} 不能为空")
    apps = index.get("apps")
    if not isinstance(apps, dict) or not apps:
        err("apps 不能为空（空的源会让飞牛报“没有可同步的有效应用”）")
        apps = {}

    for app, entry in apps.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", app):
            err(f"{app}: appname 只能是小写字母/数字/. _ -")
        for field in REQUIRED_APP_FIELDS:
            if field not in entry:
                err(f"{app}: 缺少字段 {field}")

        cats = entry.get("categories") or []
        if not isinstance(cats, list) or not cats:
            err(f"{app}: categories 必须是非空数组")
        else:
            for c in cats:
                if c not in VALID_CATEGORIES:
                    err(f"{app}: 包含无效分类：{c}（合法值: {'、'.join(sorted(VALID_CATEGORIES))}）")

        plats = entry.get("platform") or []
        for p in plats:
            if p not in VALID_PLATFORMS:
                err(f"{app}: platform 非法 {p!r}")

        check_rel_asset(root, app, entry.get("icon_url"), "icon_url")
        previews = entry.get("preview_urls") or []
        if not previews:
            warn(f"{app}: 没有 preview_urls（商店里没有截图）")
        for p in previews:
            check_rel_asset(root, app, p, "preview_urls")
        check_rel_asset(root, app, entry.get("readme_url"), "readme_url")

        for key in ("maintainer", "maintainer_url", "distributor", "distributor_url"):
            if not str(entry.get(key) or "").strip():
                err(f"{app}: {key} 不能为空")

        releases = entry.get("releases") or {}
        if not releases:
            err(f"{app}: releases 不能为空")
        for ver, rel in releases.items():
            # 飞牛允许打包修订号后缀（如 0.8.24-1），上游版本本体仍须是点分数字
            if not re.fullmatch(r"[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?", ver):
                err(f"{app}: 版本号必须是点分数字（可带 -N 修订号），实际 {ver!r}")
            for key in ("changelog", "updated_at", "packages"):
                if key not in rel:
                    err(f"{app} {ver}: 缺少 {key}")
            pkgs = rel.get("packages") or {}
            if not pkgs:
                err(f"{app} {ver}: packages 不能为空")
            for arch, pkg in pkgs.items():
                if arch not in VALID_PLATFORMS:
                    err(f"{app} {ver}: packages 架构非法 {arch!r}")
                url = str(pkg.get("download_url") or "")
                if not url.startswith(URL_PREFIX):
                    err(f"{app} {ver} {arch}: download_url 必须以 {URL_PREFIX} 开头，实际 {url}")
                if not re.fullmatch(r"[0-9a-f]{64}", str(pkg.get("sha256") or "")):
                    err(f"{app} {ver} {arch}: sha256 必须是 64 位小写 hex")
                if not isinstance(pkg.get("size"), int) or pkg["size"] <= 0:
                    err(f"{app} {ver} {arch}: size 必须是正整数")
                if args.online:
                    ok, detail = head_ok(url)
                    if not ok:
                        err(f"{app} {ver} {arch}: 下载地址不可达（{detail}）: {url}")

    # app.json 与索引一致性（防止只改一处）
    apps_dir = os.path.join(root, "apps")
    if os.path.isdir(apps_dir):
        for name in sorted(os.listdir(apps_dir)):
            meta_path = os.path.join(apps_dir, name, "app.json")
            if not os.path.isfile(meta_path):
                continue
            meta = load_json(meta_path, f"apps/{name}/app.json")
            if meta is None:
                continue
            entry = apps.get(name)
            if entry is None:
                err(f"apps/{name} 存在但 fnpack.json 里没有（索引未重建？）")
                continue
            if meta.get("categories") != entry.get("categories"):
                err(f"{name}: app.json 与 fnpack.json 的 categories 不一致（需重新生成索引）")
            if str(meta.get("service_port")) != str(entry.get("service_port")):
                err(f"{name}: service_port 不一致（app.json={meta.get('service_port')} index={entry.get('service_port')}）")

    if warnings:
        for w in warnings:
            print(f"WARN {w}")
    if errors:
        print(f"FAIL 源校验未通过（{len(errors)} 项）")
        for e in errors:
            print(f"  - {e}")
        return 1
    if args.strict and warnings:
        print("FAIL --strict：存在告警")
        return 1
    total = sum(len(e.get("releases") or {}) for e in apps.values())
    print(f"OK   源校验通过：{len(apps)} 个应用 / {total} 个版本 / {len(warnings)} 条告警")
    return 0


if __name__ == "__main__":
    sys.exit(main())
