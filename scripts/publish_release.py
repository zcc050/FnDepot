#!/usr/bin/env python3
"""把 dist 里的 fpk 发布到 GitHub Release（tag = <app>-v<version>）。

幂等：release 已存在则复用；同名资产已存在先删除再上传。
token 来源：$GH_TOKEN / $GITHUB_TOKEN，否则从 `git credential fill` 读（与 git push 同一份）。

用法:
    python3 scripts/publish_release.py --app magpie --version 0.1.4283
    python3 scripts/publish_release.py --app magpie --version 0.1.4283 --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER, REPO = "zcc050", "FnDepot"
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"


def token() -> str:
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if tok:
        return tok.strip()
    try:
        r = subprocess.run(["git", "credential", "fill"], cwd=ROOT, capture_output=True,
                           text=True, timeout=30,
                           input="protocol=https\nhost=github.com\n\n")
    except (OSError, subprocess.TimeoutExpired):
        return ""
    for line in r.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    return ""


def api(method: str, path: str, tok: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            payload = json.loads(raw)
        except Exception:  # noqa: BLE001
            payload = {"raw": raw.decode("utf-8", "replace")[:200]}
        return exc.code, payload


def upload(tok: str, url: str, path: str) -> int:
    """流式上传（不能把整包读进内存，240MB 会炸；也不能只发 header，GitHub 会 408）。"""
    from urllib.parse import urlparse
    import http.client

    u = urlparse(url)
    size = os.path.getsize(path)
    conn = http.client.HTTPSConnection(u.hostname, timeout=1800)
    try:
        conn.putrequest("POST", u.path + ("?" + u.query if u.query else ""))
        conn.putheader("Authorization", f"Bearer {tok}")
        conn.putheader("Accept", "application/vnd.github+json")
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(size))
        conn.endheaders()
        sent = 0
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                conn.send(chunk)
                sent += len(chunk)
        if sent != size:
            raise OSError(f"上传字节数不符: {sent} != {size}")
        resp = conn.getresponse()
        body = resp.read(400)
        if resp.status >= 300:
            raise urllib.error.HTTPError(url, resp.status, body[:200].decode("utf-8", "replace"), resp.headers, None)
        return resp.status
    finally:
        conn.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--arch", default="x86")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    dist_json = os.path.join(ROOT, "apps", args.app, "dist", f"{args.arch}.json")
    if not os.path.isfile(dist_json):
        print(f"没有 {dist_json}", file=sys.stderr)
        return 2
    meta = json.load(open(dist_json, encoding="utf-8"))
    if meta.get("version") != args.version:
        print(f"dist 版本 {meta.get('version')} != 请求版本 {args.version}", file=sys.stderr)
        return 2
    fpk = os.path.join(ROOT, "apps", args.app, "dist", meta["file"])
    if not os.path.isfile(fpk):
        print(f"没有产物 {fpk}", file=sys.stderr)
        return 2
    tag = f"{args.app}-v{args.version}"
    print(f"release {tag}: {meta['file']} ({meta['size']} bytes)")

    if args.dry_run:
        print("--dry-run，跳过")
        return 0

    tok = token()
    if not tok:
        print("拿不到 GitHub token", file=sys.stderr)
        return 3

    status, rel = api("GET", f"/repos/{OWNER}/{REPO}/releases/tags/{tag}", tok)
    if status == 200:
        print(f"  release 已存在 id={rel['id']}，复用")
        for asset in rel.get("assets", []):
            if asset["name"] == meta["file"]:
                print(f"  删除同名旧资产 id={asset['id']}")
                api("DELETE", f"/repos/{OWNER}/{REPO}/releases/assets/{asset['id']}", tok)
    else:
        status, rel = api("POST", f"/repos/{OWNER}/{REPO}/releases", tok, {
            "tag_name": tag,
            "target_commitish": "main",
            "name": tag,
            "body": meta.get("changelog") or f"更新到 {args.version}",
            "draft": False,
            "prerelease": False,
        })
        if status != 201:
            print(f"创建 release 失败 http={status} {rel}", file=sys.stderr)
            return 4
        print(f"  已创建 release id={rel['id']}")

    url = f"{UPLOADS}/repos/{OWNER}/{REPO}/releases/{rel['id']}/assets?name={meta['file']}"
    try:
        code = upload(tok, url, fpk)
    except urllib.error.HTTPError as exc:
        print(f"上传失败 http={exc.code} {exc.read()[:200]!r}", file=sys.stderr)
        return 5
    print(f"  上传 http={code}")

    download = rel.get("html_url", "")  # 仅用于日志
    print(f"  https://github.com/{OWNER}/{REPO}/releases/download/{tag}/{meta['file']}")
    if not download:
        print("  (release html_url 缺失，跳过展示)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
