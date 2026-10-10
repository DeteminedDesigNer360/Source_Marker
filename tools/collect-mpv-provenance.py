"""core：从实际分发的 mpv.exe 里提取并断言许可事实，生成 licenses/build-config.txt。

为什么要有这个脚本：
  这个仓库**分发**了 mpv 的官方二进制（GPLv2+）。"它是 GPL 构建"这句话必须能随时从
  分发物本身重新证明一遍，而不是靠人记得。本脚本：
    1) 从 mpv.exe 里抽出内嵌的 meson 构建配置、启用特性列表、各 libav* 的许可行；
    2) 断言这些证据确实指向 GPL 构建（-Dgpl=true / -Dffmpeg:gpl=enabled / "GPL version 2 or later"）；
    3) 把结果写成 licenses/build-config.txt（可提交进仓库的取证原文）。
  断言失败即退出码 2 —— 说明换了别的构建（例如 LGPL 版），需要重新审查 licenses/。

用法：
    python tools/collect-mpv-provenance.py                 # 用默认路径
    python tools/collect-mpv-provenance.py --exe <mpv.exe> --out <build-config.txt>
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXE = os.path.join(ROOT, "source-marker-united-1.2.0-alpha-r15", "mpv-player", "mpv.exe")
DEFAULT_OUT = os.path.join(ROOT, "source-marker-united-1.2.0-alpha-r15", "mpv-player", "licenses", "build-config.txt")

# 预期在 GPL 构建里出现的证据（任一缺失就说明构建性质变了）
EXPECT_GPL = ["-Dgpl=true", "-Dffmpeg:gpl=enabled"]
EXPECT_LICENSE = "GPL version 2 or later"
EXPECT_LIBS = ["libavcodec", "libavformat", "libavutil", "libswresample", "libswscale", "libavfilter", "libavdevice"]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def strings_min(data, minlen):
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, data):
        yield m.group().decode("latin1")


def extract(data):
    out = {"config": None, "features": None, "licenses": {}, "others": []}
    for s in strings_min(data, 24):
        if out["config"] is None and s.startswith("-D") and "ffmpeg" in s:
            out["config"] = s
        if out["features"] is None and s.startswith("List of enabled features"):
            out["features"] = s
        m = re.match(r"^(lib\w+) license: (.+)$", s)
        if m and m.group(1) not in out["licenses"]:
            out["licenses"][m.group(1)] = m.group(2)
        if "libplacebo" in s and re.search(r"v\d+\.\d+", s) and len(out["others"]) < 5:
            out["others"].append(s)
    return out


def run_version(exe):
    com = os.path.join(os.path.dirname(exe), "mpv.com")
    target = com if os.path.exists(com) else exe
    try:
        p = subprocess.run([target, "--version"], capture_output=True, text=True, timeout=60)
        return (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return "(无法执行 --version: %s %s)" % (type(e).__name__, e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.path.exists(a.exe):
        print("找不到 mpv.exe: %s" % a.exe)
        return 2

    data = open(a.exe, "rb").read()
    info = extract(data)
    version_txt = run_version(a.exe)
    h = sha256_file(a.exe)
    size = os.path.getsize(a.exe)
    dll = os.path.join(os.path.dirname(a.exe), "vulkan-1.dll")
    dll_line = ""
    if os.path.exists(dll):
        dll_line = "  vulkan-1.dll            %12d  %s" % (os.path.getsize(dll), sha256_file(dll))
    com = os.path.join(os.path.dirname(a.exe), "mpv.com")
    com_line = ""
    if os.path.exists(com):
        com_line = "  mpv.com                 %12d  %s" % (os.path.getsize(com), sha256_file(com))

    lines = []
    lines.append("mpv 分发物 · 构建配置与许可取证（由 tools/collect-mpv-provenance.py 生成）")
    lines.append("=" * 78)
    lines.append("")
    lines.append("分发文件（本仓库实际打包进发行版的这些文件）")
    lines.append("  %-22s %12s  %s" % ("mpv.exe", size, h))
    if com_line:
        lines.append(com_line)
    if dll_line:
        lines.append(dll_line)
    lines.append("")
    lines.append("mpv --version 输出")
    lines.append("-" * 78)
    for line in version_txt.strip().splitlines():
        lines.append("  " + line)
    lines.append("")
    lines.append("内嵌的 meson 构建配置（二进制里可读出的原文）")
    lines.append("-" * 78)
    lines.append("  " + (info["config"] or "(未提取到)"))
    lines.append("")
    lines.append("启用特性（含 gpl 标记）")
    lines.append("-" * 78)
    lines.append("  " + (info["features"] or "(未提取到)"))
    lines.append("")
    lines.append("各库自报的许可证")
    lines.append("-" * 78)
    for lib in EXPECT_LIBS:
        if lib in info["licenses"]:
            lines.append("  %-14s %s" % (lib + ":", info["licenses"][lib]))
    for lib, lic in sorted(info["licenses"].items()):
        if lib not in EXPECT_LIBS:
            lines.append("  %-14s %s" % (lib + ":", lic))
    lines.append("")

    # 断言：这必须是 GPL 构建
    problems = []
    cfg = info["config"] or ""
    for token in EXPECT_GPL:
        if token not in cfg:
            problems.append("构建配置里缺少 %s" % token)
    for lib in EXPECT_LIBS:
        lic = info["licenses"].get(lib, "")
        if EXPECT_LICENSE not in lic:
            problems.append("%s 自报的不是 GPLv2+（实际: %s）" % (lib, lic or "缺失"))

    lines.append("断言结果")
    lines.append("-" * 78)
    if problems:
        for p in problems:
            lines.append("  [FAIL] " + p)
        lines.append("")
        lines.append("  → 该二进制**不是**已知的 GPL 构建，licenses/ 需重新审查后再分发。")
    else:
        lines.append("  [OK] 含 %s（GPL 构建）" % "、".join(EXPECT_GPL))
        lines.append("  [OK] 各 libav* 均自报 \"GPL version 2 or later\"")
        lines.append("")
        lines.append("  → 结论：本仓库分发的 mpv 为 **GPLv2 或更高版本** 构建，")
        lines.append("     再分发须遵守 licenses/GPL-2.0.txt，并遵守 licenses/SOURCE-OFFER.md 的对应源码义务。")
    lines.append("")

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    if not a.quiet:
        print("\n".join(lines))
        print("已写入: %s" % a.out)
    return 2 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
