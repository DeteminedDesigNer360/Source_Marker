"""下载并解压官方 mpv Windows 便携版（仅写入工作区，不碰系统）。

用法： python tools/fetch-mpv.py
产物： _pkg/mpv/  （内含 mpv.exe / mpv.com；要换进包里之前，先跑 collect-mpv-provenance.py 验证仍是 GPL 构建）
"""
import json
import os
import sys
import time
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "_pkg")
ZIP = os.path.join(PKG, "mpv-win64.zip")
OUT = os.path.join(PKG, "mpv")
API = "https://api.github.com/repos/mpv-player/mpv/releases/latest"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}


def fetch_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def pick_asset(rel):
    for a in rel.get("assets", []):
        n = a["name"]
        if "x86_64-pc-windows-msvc" in n and n.endswith(".zip"):
            return a
    for a in rel.get("assets", []):
        n = a["name"]
        if "windows" in n and n.endswith(".zip") and "x86_64" in n:
            return a
    return None


def download(url, dest):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got, t0, last = 0, time.time(), 0
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            if time.time() - last > 1.5:
                last = time.time()
                pct = (got * 100.0 / total) if total else 0
                print(f"  {got/1048576:6.1f} MB / {total/1048576:.1f} MB  ({pct:.0f}%)", flush=True)
    return got


def main():
    os.makedirs(PKG, exist_ok=True)
    print("[1/3] 查询 mpv 最新 release ...")
    rel = fetch_json(API)
    print("      tag:", rel["tag_name"], "published:", rel["published_at"])
    asset = pick_asset(rel)
    if not asset:
        print("FAIL: 没有找到 Windows x86_64 zip 资产")
        return 1
    print(f"[2/3] 下载 {asset['name']} ({asset['size']/1048576:.1f} MB)")
    if not os.path.exists(ZIP) or os.path.getsize(ZIP) != asset["size"]:
        n = download(asset["browser_download_url"], ZIP)
        print(f"      已下载 {n} 字节")
    else:
        print("      已存在且大小一致，跳过下载")

    print("[3/3] 解压到", OUT)
    if os.path.isdir(OUT):
        import shutil
        shutil.rmtree(OUT)
    os.makedirs(OUT, exist_ok=True)
    with zipfile.ZipFile(ZIP) as z:
        z.extractall(OUT)
        names = z.namelist()
    print("      条目数:", len(names))
    for n in names[:20]:
        print("      -", n)
    # 直接摊平（有些包多一层目录）
    entries = os.listdir(OUT)
    if len(entries) == 1 and os.path.isdir(os.path.join(OUT, entries[0])):
        inner = os.path.join(OUT, entries[0])
        if os.path.exists(os.path.join(inner, "mpv.exe")):
            for it in os.listdir(inner):
                os.replace(os.path.join(inner, it), os.path.join(OUT, it))
            os.rmdir(inner)
    print("      最终内容:", sorted(os.listdir(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
