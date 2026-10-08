# 第三方组件与许可（THIRD-PARTY NOTICES）

本文件列出本仓库**实际分发**的第三方二进制，以及它们的来源、版本、许可与义务。
所有结论都能从 `licenses/build-config.txt`（由 `tools/collect-mpv-provenance.py` 从分发物本身重新生成）
与下方给出的上游 URL 复核。

> 复核命令：`python tools/collect-mpv-provenance.py`
> 该脚本会断言"这确实是 GPL 构建"；换了别的 mpv 构建（例如 LGPL 版）它会以退出码 2 失败。

---

## 1. 我们分发了什么

| 文件 | 大小 | SHA256 | 许可 | 是否修改 |
|---|---|---|---|---|
| `mpv.exe` | 57,294,336 | `6145e63f026451a764077d53fd60860ec9f5c2bc76dcd6e62a88967ac375453d` | **GPL-2.0-or-later** | 否（原样） |
| `mpv.com` | 7,680 | `9038ff36858e99624064f4ec6be2bb666985482aad234a2e38ef72562148aff7` | **GPL-2.0-or-later** | 否（原样） |
| `vulkan-1.dll` | 1,139,712 | `2baae0a109cb5962437b00a182750308ce9f69f59381df62939c00c21150ee6b` | **Apache-2.0** | 否（原样） |
| `mpv-register.bat` / `mpv-unregister.bat` | 202 / 206 | 见发行包 `SHA256SUMS.txt` | 随 mpv（GPL-2.0-or-later） | 否 |

**没有分发**：上游 zip 里的 `mpv.pdb`（229,097,472 字节的调试符号；体积原因剔除，不影响许可）。

### 上游原始资产（来源凭据）

| 项 | 值 |
|---|---|
| 来源 | mpv 官方 GitHub Releases：<https://github.com/mpv-player/mpv/releases/tag/v0.41.0> |
| 资产 | `mpv-v0.41.0-x86_64-pc-windows-msvc.zip` |
| 资产大小 / SHA256 | 77,205,127 字节 / `4e197f729f5071c6772f35fffd96e0f36e3e8a044bd9479b136bb09b7c6a80ff` |
| 发布时间 | 2025-12-21T19:17:10Z |
| zip 内条目（共 6） | `mpv-register.bat`、`mpv-unregister.bat`、`mpv.com`、`mpv.exe`、`mpv.pdb`、`vulkan-1.dll` |

> **来源已用哈希确证**：本仓库 `mpv.exe` 的 SHA256 与上述官方资产中解出的 `mpv.exe` **逐字节一致**。
> 因此不存在"我们自己编译/改动过 mpv"的情况，也没有夹带其它二进制。

---

## 2. 为什么是 GPL 而不是 LGPL

mpv 本身"默认 GPLv2+，若构建时不使用任何 GPL-only 文件则为 LGPLv2.1+"
（见 `licenses/mpv-Copyright.txt` 开头，以及 `-Dgpl=false` 开关的说明）。

本分发物**是 GPL 构建**，证据（均出自二进制自身，见 `licenses/build-config.txt`）：

```
构建配置： -Dgpl=true -Dffmpeg:gpl=enabled ...（完整串见 build-config.txt）
特性列表： ... gpl ...
各库自报： libavcodec  license: GPL version 2 or later
          libavformat license: GPL version 2 or later
          libavutil   license: GPL version 2 or later
          libavfilter license: GPL version 2 or later
          libswresample / libswscale / libavdevice 同上
```

→ **结论：`mpv.exe` / `mpv.com` 整体按 GPL-2.0-or-later 分发**，再分发必须同时满足 GPLv2 的
"提供对应源码"义务（见 [`SOURCE-OFFER.md`](SOURCE-OFFER.md)）。

> 上游另发布 `libmpv-*-lgpl.zip`（LGPL 变体，仅 libmpv）。**本仓库没有使用它**，请勿混用。

---

## 3. 链接进 `mpv.exe` 的主要组件

这些库被**静态链接**进 `mpv.exe`，不单独分发文件。版本以二进制自报或 mpv 官方 CI 配方为准。

| 组件 | 版本 / 修订 | 许可 | 上游 |
|---|---|---|---|
| mpv | commit `41f6a6450`（二进制自报 `v0.41.0-dev-g41f6a6450`），构建于 2025-12-21 19:30:47 | GPL-2.0-or-later | <https://github.com/mpv-player/mpv> |
| FFmpeg（libav* 全部） | commit `f853d12`（二进制自报 `FFmpeg version: f853d12`） | GPL-2.0-or-later（因此启用 `--enable-gpl` 的结果） | <https://github.com/FFmpeg/FFmpeg> |
| libplacebo | `v7.358.0`（二进制自报） | LGPL-2.1-or-later | <https://github.com/haasn/libplacebo> |
| Vulkan-Loader（即 `vulkan-1.dll`） | 1.3.285（mpv CI 配方里声明的版本） | Apache-2.0 | <https://github.com/KhronosGroup/Vulkan-Loader> |
| shaderc / SPIRV-Tools / glslang | shaderc `2024.1`（CI 配方）；SPIRV-Tools/glslang 由 shaderc 的 `git-sync-deps` 固定 | Apache-2.0 / BSD-3-Clause 等 | <https://github.com/google/shaderc> |
| SPIRV-Cross | `0.59.0`（CI 配方） | Apache-2.0 | <https://github.com/KhronosGroup/SPIRV-Cross> |
| libjxl | `0.12.0`（CI 配方） | BSD-3-Clause | <https://github.com/libjxl/libjxl> |
| libass | 由 Meson WrapDB 解析 | ISC | <https://github.com/libass/libass> |
| dav1d | 由 Meson WrapDB 解析 | BSD-2-Clause | <https://code.videolan.org/videolan/dav1d> |
| LuaJIT | 由 Meson WrapDB 解析（`-Dlua=luajit -Dluajit:amalgam=true`） | MIT | <https://luajit.org/> |
| mujs | 由 Meson WrapDB 解析 | ISC | <https://github.com/ccxvii/mujs> |
| harfbuzz / fribidi / freetype / expat / libpng / zlib / lcms2 / libaom / libjpeg-turbo / uchardet / xxhash | 由 Meson WrapDB 解析 | 各自的开源许可（MIT / BSD / Apache-2.0 / Zlib / ISC 等） | 见 Meson WrapDB |
| ffnvcodec（CUDA 头文件，仅编译期） | 由 CI 获取 | MIT | <https://github.com/FFmpeg/nv-codec-headers> |

**精度声明（诚实标注）**：上表中标"由 Meson WrapDB 解析"的组件，其**精确版本号**由构建时的
WrapDB 决定，二进制里没有完整自报，因此本仓库**无法逐一给出精确版本**。构建方式、获取方式、
配置串已在 [`SOURCE-OFFER.md`](SOURCE-OFFER.md) 中逐条记录，任何人可据此重建出等价的源码集合。

---

## 4. 本仓库自身代码

见仓库根目录的 [`LICENSE`](../LICENSE)（默认 **MIT**）。
其中**不包含** mpv / Vulkan-Loader 等第三方二进制——它们各自按上表许可分发。

---

## 5. 如果你再分发这个播放器包

1. 保留 `licenses/` 整目录（GPL-2.0 / LGPL-2.1 / Apache-2.0 文本 + mpv 版权声明 + 取证文件）；
2. 保留或重新发出 [`SOURCE-OFFER.md`](SOURCE-OFFER.md) 里的书面要约（**发布前请把联系邮箱填上**）；
3. **不要**声称本包内的 mpv 是你自己的作品，也不要给它换许可证；
4. 若你修改了 mpv 或随包脚本，GPL 要求你对修改部分同样提供源码。
