#!/usr/bin/env python3
"""校验 fpk 安装包是否符合 docs/PACKAGING.md 的契约。

用法:
    python3 scripts/verify_fpk.py apps/magpie/dist/magpie-0.1.4261-x86.fpk

检查项（任一失败则退出码 1）:
  1. fpk 是有效的 tar.gz，且根目录含 manifest / app.tgz / cmd / config / ui
  2. manifest 为 key = value 纯文本，必需字段齐全
  3. platform ∈ {x86, arm, loongarch, risc-v, all}，且与文件名里的架构一致
  4. manifest.checksum == md5(app.tgz)，且 version == 文件名里的版本
  5. desktop_applaunchname 以 appname 开头（fnpack 的硬校验）
  6. cmd/ 下必需脚本存在且可执行（755）
  7. ui/config、config/*.json、wizard/* JSON 可解析；ui/config 的 .url key 与桌面入口一致
  8. ICON.PNG / ICON_256.PNG 是 PNG 且尺寸合规
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import struct
import sys
import tarfile
import tempfile

REQUIRED_FIELDS = [
    "appname", "version", "display_name", "desc", "platform", "source",
    "maintainer", "maintainer_url", "distributor", "distributor_url",
    "os_min_version", "desktop_uidir", "desktop_applaunchname",
    "service_port", "checkport", "ctl_stop",
]
PLATFORMS = {"x86", "arm", "loongarch", "risc-v", "all"}
CMD_SCRIPTS = [
    "main", "install_init", "install_callback", "config_init", "config_callback",
    "uninstall_init", "uninstall_callback", "upgrade_init", "upgrade_callback",
]
errors: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def parse_manifest(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"manifest 行格式不合法: {raw!r}")
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def png_size(blob: bytes) -> tuple[int, int] | None:
    if len(blob) < 24 or blob[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w, h = struct.unpack(">II", blob[16:24])
    return w, h


def main(path: str) -> int:
    if not os.path.isfile(path):
        print(f"没有这个文件: {path}", file=sys.stderr)
        return 2
    name = os.path.basename(path)
    m = re.match(r"^(?P<app>[a-z0-9._-]+)-(?P<ver>[0-9][0-9.]*)-(?P<arch>x86|arm|loongarch|risc-v)\.fpk$", name)
    if not m:
        fail(f"文件名不符合 <app>-<version>-<arch>.fpk: {name}")

    try:
        outer = tarfile.open(path, "r:gz")
    except (tarfile.TarError, OSError) as exc:
        print(f"不是有效 tar.gz: {exc}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="verify-fpk.") as tmp:
        outer.extractall(tmp)
        members = set(os.listdir(tmp))
        for need in ("manifest", "app.tgz", "cmd", "config"):
            if need not in members:
                fail(f"缺少 {need}")

        man_path = os.path.join(tmp, "manifest")
        if not os.path.isfile(man_path):
            print("\n".join(errors), file=sys.stderr)
            return 1
        man = parse_manifest(open(man_path, encoding="utf-8").read())
        for key in REQUIRED_FIELDS:
            if key not in man:
                fail(f"manifest 缺少字段: {key}")

        if man.get("platform") not in PLATFORMS:
            fail(f"platform 非法: {man.get('platform')!r}（只允许 {sorted(PLATFORMS)}）")
        if m and man.get("platform") not in ("all", None) and man.get("platform") != m.group("arch"):
            fail(f"manifest platform={man.get('platform')} 与文件名架构 {m.group('arch')} 不一致")
        if m and man.get("version") != m.group("ver"):
            fail(f"manifest version={man.get('version')} 与文件名版本 {m.group('ver')} 不一致")
        if m and man.get("appname") != m.group("app"):
            fail(f"manifest appname={man.get('appname')} 与文件名 {m.group('app')} 不一致")

        launch = man.get("desktop_applaunchname", "")
        if man.get("appname") and not launch.startswith(man["appname"] + "."):
            fail(f"desktop_applaunchname 必须以 {man['appname']}. 开头（fnpack 硬校验）")

        app_tgz = os.path.join(tmp, "app.tgz")
        if os.path.isfile(app_tgz):
            md5 = hashlib.md5(open(app_tgz, "rb").read()).hexdigest()
            if man.get("checksum") != md5:
                fail(f"checksum 不匹配: manifest={man.get('checksum')} 实际={md5}")

        cmd_dir = os.path.join(tmp, "cmd")
        if os.path.isdir(cmd_dir):
            for script in CMD_SCRIPTS:
                p = os.path.join(cmd_dir, script)
                if not os.path.isfile(p):
                    fail(f"cmd/{script} 缺失")
                    continue
                mode = os.stat(p).st_mode
                if mode & 0o111 == 0:
                    fail(f"cmd/{script} 没有可执行位（当前 {oct(mode & 0o777)}）")

        # ui/config 在 app.tgz 里（fnpack 把 ui/ 与 server/ 一起压进 app.tgz）
        app_root = os.path.join(tmp, "_app")
        app_tgz = os.path.join(tmp, "app.tgz")
        if os.path.isfile(app_tgz):
            os.makedirs(app_root, exist_ok=True)
            try:
                with tarfile.open(app_tgz, "r:gz") as inner:
                    inner.extractall(app_root)
            except (tarfile.TarError, OSError) as exc:
                fail(f"app.tgz 解包失败: {exc}")

        def locate(rel: str) -> str | None:
            for base in (app_root, tmp):
                cand = os.path.join(base, rel)
                if os.path.isfile(cand):
                    return cand
            return None

        for rel in ("ui/config", "config/privilege", "config/resource"):
            p = locate(rel)
            if p is None:
                fail(f"{rel} 缺失")
                continue
            if not os.path.isfile(p):
                fail(f"{rel} 缺失")
                continue
            try:
                data = json.loads(open(p, encoding="utf-8").read())
            except json.JSONDecodeError as exc:
                fail(f"{rel} 不是合法 JSON: {exc}")
                continue
            if rel == "ui/config":
                urls = data.get(".url")
                if not isinstance(urls, dict) or not urls:
                    fail("ui/config 缺少 .url")
                else:
                    for key in urls:
                        if man.get("appname") and not key.startswith(man["appname"] + "."):
                            fail(f"ui/config .url key {key} 必须以 {man['appname']}. 开头")

        wiz_dir = os.path.join(tmp, "wizard")
        if os.path.isdir(wiz_dir):
            for f in os.listdir(wiz_dir):
                p = os.path.join(wiz_dir, f)
                if os.path.isfile(p):
                    try:
                        json.loads(open(p, encoding="utf-8").read())
                    except json.JSONDecodeError as exc:
                        fail(f"wizard/{f} 不是合法 JSON: {exc}")

        for icon, expect in (("ICON.PNG", (111, 111)), ("ICON_256.PNG", (256, 256))):
            p = os.path.join(tmp, icon)
            if not os.path.isfile(p):
                fail(f"{icon} 缺失")
                continue
            size = png_size(open(p, "rb").read(64))
            if size is None:
                fail(f"{icon} 不是 PNG")
            elif icon == "ICON_256.PNG" and size != expect:
                fail(f"{icon} 尺寸 {size[0]}x{size[1]}，期望 256x256")
            elif icon == "ICON.PNG" and size[0] != size[1]:
                fail(f"{icon} 不是正方形: {size[0]}x{size[1]}")

    if errors:
        print(f"FAIL {name}")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"OK   {name}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
