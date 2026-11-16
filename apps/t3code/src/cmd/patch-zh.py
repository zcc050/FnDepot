#!/usr/bin/env python3
"""给 T3 Code 的 Web 前端打简体中文补丁。

背景
----
T3 Code（pingdotgg/t3code）没有 i18n 框架，界面文案直接以字符串字面量写在
Vite 打包产物里。上游有两个中文 PR（#27965 / #37458）都没合进正式版。

做法
----
**只替换 UI 位置的字符串字面量**，即 `children:` / `title:` / `placeholder:` /
`aria-label:` / `label:` / `alt:` / `description:` 后面紧跟的反引号或引号字符串。
这样不会碰到 `status === "Cancel"` 这类枚举值——那些字符串前面不是这些 JSX 属性名。

替换表在 cmd/zh-CN.json（英文原文 → 中文）。没命中的词条会被统计出来，
方便增量扩充词表；命中为 0 的说明上游改了文案，不会报错。

用法
----
    python3 patch-zh.py <client-assets-dir>            # 打补丁（幂等）
    python3 patch-zh.py <client-assets-dir> --check    # 只统计，不写
    python3 patch-zh.py <client-assets-dir> --revert   # 从备份恢复

必须在 T3 Code 进程停止时执行（正在运行的进程会把文件读进内存，改动要重启才生效）。
写入采用「同目录临时文件 + os.replace」，失败不会留下半个文件。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "zh-CN.json")

# 这些 JSX 属性名的值一定是给人看的文案，不会参与逻辑判断
ATTRS = "children|title|placeholder|aria-label|aria-description|label|alt|description|emptyText|helperText"
PAT = re.compile(r"\b(" + ATTRS + r")(\s*:\s*)(`|\"|')([^`\"'\\\n]{1,90})\3")


def load_table() -> dict[str, str]:
    with open(TABLE, encoding="utf-8") as f:
        return json.load(f)


def backup_dir(assets: str) -> str:
    # 放在 assets 的兄弟目录，避开前端静态资源扫描
    return os.path.join(os.path.dirname(assets), ".zh-backup")


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    check = "--check" in argv
    revert = "--revert" in argv
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    assets = args[0]
    if not os.path.isdir(assets):
        print(f"不是目录: {assets}", file=sys.stderr)
        return 2

    if revert:
        bak = backup_dir(assets)
        if not os.path.isdir(bak):
            print("没有备份，无需恢复")
            return 0
        n = 0
        for f in os.listdir(bak):
            if f.endswith(".js"):
                shutil.copy2(os.path.join(bak, f), os.path.join(assets, f))
                n += 1
        print(f"已恢复 {n} 个文件")
        return 0

    table = load_table()
    if not table:
        print("词表为空", file=sys.stderr)
        return 2

    files = [f for f in os.listdir(assets) if f.endswith(".js")]
    total = 0
    touched = []
    missed: dict[str, int] = {k: 0 for k in table}

    for name in files:
        path = os.path.join(assets, name)
        try:
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
                src = f.read()
        except OSError:
            continue

        n_file = 0

        def repl(m: re.Match) -> str:
            nonlocal n_file
            zh = table.get(m.group(4))
            if zh is None:
                missed[m.group(4)] = missed.get(m.group(4), 0) + 1
                return m.group(0)
            n_file += 1
            return f"{m.group(1)}{m.group(2)}{m.group(3)}{zh}{m.group(3)}"

        out = PAT.sub(repl, src)
        if n_file == 0 or out == src:
            continue
        total += n_file
        touched.append((name, n_file))
        if check:
            continue

        # 备份 + 原子写
        bak = backup_dir(assets)
        if not check:
            os.makedirs(bak, exist_ok=True)
            dst_bak = os.path.join(bak, name)
            if not os.path.exists(dst_bak):
                shutil.copy2(path, dst_bak)
        st = os.stat(path)
        fd, tmp = tempfile.mkstemp(prefix=".zh-", dir=assets)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(out)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, st.st_mode & 0o7777)
            os.replace(tmp, path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    action = "可替换" if check else "已替换"
    print(f"{action} {total} 处，涉及 {len(touched)} 个文件（词表 {len(table)} 条）")
    for name, n in sorted(touched, key=lambda x: -x[1])[:10]:
        print(f"  {n:4d}  {name}")
    unused = [k for k, v in missed.items() if v == 0]
    if not check and unused:
        print(f"  未命中词条 {len(unused)} 条（上游文案可能已变，可忽略）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
