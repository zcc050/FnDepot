#!/usr/bin/env python3
"""给 magpie 二进制打「能在飞牛 iframe 里显示」的等长补丁。

背景
----
magpie 的 Web 响应带 CSP `frame-ancestors 'self'`。飞牛桌面是用 iframe 打开应用的，
祖先链里有 fnOS 页面（跨源、sandbox），浏览器会整帧拒绝 → 页面灰屏/破图。
另外部分浏览器在 sandbox iframe（origin 为 null）里会因为完整的 CSP 头拦掉子资源。

做法
----
只做**等长**字节替换，不改变文件大小、不移动 Go 段偏移，避免破坏可执行文件：

    frame-ancestors 'self'   (22B) -> frame-ancestors *      (22B)
    Content-Security-Policy  (23B) -> X-Content-Security-Poli (23B)

第二条把 CSP 头的名字改掉，浏览器就不再识别这个响应头；页面自身仍在 iframe 的
sandbox="allow-scripts" 隔离里运行。若你更希望保留 CSP 头（只放开 frame-ancestors），
设置 MAGPIE_KEEP_CSP=1 再启动即可只打第一条。

用法
----
    python3 patch-csp.py <magpie-binary>          # 打补丁（幂等）
    python3 patch-csp.py <magpie-binary> --check  # 只检查，退出码 0=已打/无需 1=未打 2=出错

必须在 magpie 进程停止后执行（运行中二进制是 Text file busy）。
写入采用「同目录临时文件 + os.replace」，避免写一半把二进制写坏。
"""
from __future__ import annotations

import os
import sys
import tempfile

FRAME_OLD = b"frame-ancestors 'self'"
FRAME_NEW = b"frame-ancestors *     "
CSP_OLD = b"Content-Security-Policy"
CSP_NEW = b"X-Content-Security-Poli"

assert len(FRAME_OLD) == len(FRAME_NEW) == 22, "frame-ancestors 替换必须等长"
assert len(CSP_OLD) == len(CSP_NEW) == 23, "CSP 头名替换必须等长"


def patches(keep_csp: bool) -> list[tuple[bytes, bytes]]:
    out = [(FRAME_OLD, FRAME_NEW)]
    if not keep_csp:
        out.append((CSP_OLD, CSP_NEW))
    return out


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    check_only = "--check" in argv
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    path = args[0]
    if not os.path.isfile(path) or os.path.islink(path):
        print(f"不是普通文件: {path}", file=sys.stderr)
        return 2

    keep_csp = os.environ.get("MAGPIE_KEEP_CSP") == "1"
    with open(path, "rb") as f:
        data = f.read()

    todo = []
    for old, new in patches(keep_csp):
        n_old = data.count(old)
        n_new = data.count(new)
        if n_old:
            todo.append((old, new, n_old))
        elif n_new == 0:
            # 上游改了这段文案：不猜，只记录，交给验收时人工确认
            print(f"WARN 未找到片段（可能上游改版）: {old.decode()}，跳过", file=sys.stderr)

    if not todo:
        print(f"already patched or nothing to do: {os.path.basename(path)}")
        return 0
    if check_only:
        print(f"NOT PATCHED ({sum(n for _, _, n in todo)} 处): {os.path.basename(path)}")
        return 1

    out = data
    for old, new, n in todo:
        out = out.replace(old, new)
        print(f"patched {n} × {old.decode()} -> {new.decode()}")

    if len(out) != len(data):
        print("内部错误：替换后长度变化，放弃写入", file=sys.stderr)
        return 2

    st = os.stat(path)
    d = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".magpie-patch-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(out)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)          # 原子替换，保留同目录
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    with open(path, "rb") as f:
        if f.read() != out:
            print("写入校验失败", file=sys.stderr)
            return 2
    print(f"ok  {path}  ({len(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
