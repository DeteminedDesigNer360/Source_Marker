# 第三方组件与许可（THIRD-PARTY NOTICES）

本文件列出**本发行包实际分发**的第三方组件，以及各自的来源、版本、许可与义务。
mpv 相关的每一项都能从 `mpv-player/licenses/build-config.txt`（上游工具**从分发物本身**提取生成）
与下方给出的上游 URL 复核。

---

## 0. 三句话看懂边界

1. **本包自身代码**（`pr-extension/` 下的面板与宿主脚本、安装脚本、文档）
   按 **GPL-2.0-or-later** 分发 —— 见包根 [`LICENSE`](LICENSE)。
2. **`mpv-player/` 里的 mpv 二进制是第三方作品**，按 **GPL-2.0-or-later** 原样分发；
   **不是我们的作品、也没有改动过**（哈希与上游资产逐字节一致，见 §1）。
3. **`pr-extension/*/extension/client/CSInterface.js` 是 Adobe 的文件，不是 GPL**，
   **不在**包根 `LICENSE` 的覆盖范围内 —— 见 §4。**不要删它的文件头。**

---

## 1. 分发了什么、没分发什么

**分发了**（第三方部分）：

| 文件 | 许可 | 是否修改 |
|---|---|---|
| `mpv-player/mpv.exe` | GPL-2.0-or-later | 否（原样）|
| `mpv-player/mpv.com` | GPL-2.0-or-later | 否（原样）|
| `mpv-player/vulkan-1.dll` | **Apache-2.0** | 否（原样）|
| `mpv-player/mpv-register.bat`、`mpv-unregister.bat` | 随 mpv（GPL-2.0-or-later）| 否 |
| `mpv-player/portable_config/**` | 随 mpv（配置/文档类，各自许可）| 否 |
| `pr-extension/*/extension/client/CSInterface.js`（两份）| **Adobe**（非开源，见 §4）| 否 |

逐文件 SHA256 见 `mpv-player/SHA256SUMS.txt`；可用 `mpv-player/校验.ps1` 一键核对。

**没有分发**：上游 zip 里 229 MB 的调试符号 `mpv.pdb`（体积原因剔除，与许可无关）。

### 上游来源与凭据

| 项 | 值 |
|---|---|
| 来源 | mpv 官方 GitHub Releases <https://github.com/mpv-player/mpv/releases/tag/v0.41.0> |
| 资产 | `mpv-v0.41.0-x86_64-pc-windows-msvc.zip` |
| 资产大小 / SHA256 | 77,205,127 字节 / `4e197f729f5071c6772f35fffd96e0f36e3e8a044bd9479b136bb09b7c6a80ff` |
| 发布时间 | 2025-12-21T19:17:10Z |
| `mpv.exe` SHA256 | `6145e63f026451a764077d53fd60860ec9f5c2bc76dcd6e62a88967ac375453d` |
| 二进制自报 | mpv commit `41f6a6450`（`v0.41.0-dev-g41f6a6450`，构建于 2025-12-21 19:30:47）、FFmpeg `f853d12`、libplacebo `v7.358.0` |

> **来源已用哈希确证**：下载上游资产 → 解出 `mpv.exe` → SHA256 与包内**逐字节一致**。
> 因此不存在"我们编译或改动过 mpv"，也没有夹带其它二进制。
>
> ⚠️ **一个容易踩的点**：发布 tag 是 `v0.41.0`，但二进制内部版本串是
> `v0.41.0-dev-g41f6a6450`（官方 CI 在打 tag 之后从 master 构建所致）。
> **写许可与源码指向要以二进制自报的 commit 为准**；只写 tag 会与实际源码对不上。

---

## 2. 为什么是 GPL 而不是 LGPL

mpv 本身"默认 GPLv2+；若构建时不使用任何 GPL-only 文件则为 LGPLv2.1+"
（见 `mpv-player/licenses/Copyright.txt` 开头）。

**本包分发的这个构建是 GPL 构建**，证据全部出自二进制自身（见 `build-config.txt`）：

```
构建配置： -Dgpl=true -Dffmpeg:gpl=enabled …（完整串见 build-config.txt）
各库自报： libavcodec / libavformat / libavutil / libavfilter / libswresample
          / libswscale / libavdevice  → license: GPL version 2 or later
```

→ 结论：`mpv.exe` / `mpv.com` 整体按 **GPL-2.0-or-later** 分发；再分发必须同时满足
GPLv2 的"提供对应源码"义务（见 [`SOURCE-OFFER.md`](SOURCE-OFFER.md)）。

> 上游另发布 `libmpv-*-lgpl.zip`（仅 libmpv 的 LGPL 变体）。**本包没有使用它，请勿混用。**

---

## 3. 静态链接进 `mpv.exe` 的主要组件

这些库被静态链接进 `mpv.exe`，不单独分发文件。版本以二进制自报或 mpv 官方 CI 配方为准。

| 组件 | 版本 / 修订 | 许可 | 上游 |
|---|---|---|---|
| mpv | commit `41f6a6450` | GPL-2.0-or-later | <https://github.com/mpv-player/mpv> |
| FFmpeg（libav\* 全部）| commit `f853d12`（二进制自报）| GPL-2.0-or-later（启用 `--enable-gpl` 的结果）| <https://github.com/FFmpeg/FFmpeg> |
| libplacebo | `v7.358.0`（二进制自报）| LGPL-2.1-or-later | <https://github.com/haasn/libplacebo> |
| Vulkan-Loader（即 `vulkan-1.dll`）| 1.3.285（CI 配方声明）| Apache-2.0 | <https://github.com/KhronosGroup/Vulkan-Loader> |
| shaderc / SPIRV-Tools / glslang | shaderc `2024.1`（CI 配方）| Apache-2.0 / BSD-3-Clause 等 | <https://github.com/google/shaderc> |
| SPIRV-Cross | `0.59.0`（CI 配方）| Apache-2.0 | <https://github.com/KhronosGroup/SPIRV-Cross> |
| libjxl | `0.12.0`（CI 配方）| BSD-3-Clause | <https://github.com/libjxl/libjxl> |
| libass | 由 Meson WrapDB 解析 | ISC | <https://github.com/libass/libass> |
| dav1d | 由 Meson WrapDB 解析 | BSD-2-Clause | <https://code.videolan.org/videolan/dav1d> |
| LuaJIT | 由 Meson WrapDB 解析 | MIT | <https://luajit.org/> |
| mujs | 由 Meson WrapDB 解析 | ISC | <https://github.com/ccxvii/mujs> |
| harfbuzz / fribidi / freetype / expat / libpng / zlib / lcms2 / libaom / libjpeg-turbo / uchardet / xxhash | 由 Meson WrapDB 解析 | 各自的开源许可（MIT / BSD / Apache-2.0 / Zlib / ISC 等）| 见 Meson WrapDB |
| ffnvcodec（CUDA 头文件，仅编译期）| 由 CI 获取 | MIT | <https://github.com/FFmpeg/nv-codec-headers> |

**精度声明（诚实标注）**：上表中标"由 Meson WrapDB 解析"的组件，其**精确版本号**由构建时的
WrapDB 决定，二进制里没有完整自报，因此本包**无法逐一给出精确版本**。构建方式、获取方式、
配置串已在 [`SOURCE-OFFER.md`](SOURCE-OFFER.md) 中逐条记录，任何人可据此重建等价的源码集合。

---

## 4. ⚠️ `CSInterface.js`：Adobe 的文件（不是 GPL）

`pr-extension/新手版/extension/client/CSInterface.js` 与 `pr-extension/完整版/extension/client/CSInterface.js`
两份都来自 Adobe 的 CEP SDK。文件头原文：

```
ADOBE SYSTEMS INCORPORATED
Copyright 2020 Adobe Systems Incorporated
All Rights Reserved.
NOTICE:  Adobe permits you to use, modify, and distribute this file in accordance with the
terms of the Adobe license agreement accompanying it.  If you have received this file from a
source other than Adobe, then your use, modification, or distribution of it requires the prior
written permission of Adobe.
```

含义（照做就行）：

- **它不是 GPL** —— 我们无权把它纳入包根的 `LICENSE`；它按 Adobe 随 CEP 提供的条款使用。
  （以 CEP 扩展的形式分发它是 CEP 生态的常规做法，Adobe 自己的示例也这么发。）
- **不要删除或改写它的文件头。**
- 若想彻底不依赖它：可以不用这个文件，直接调用 CEP 的 `window.__adobe_cep__` ——
  那是代码改动，不是许可问题。

---

## 5. 本包自身代码的许可

**GPL-2.0-or-later**。包根 [`LICENSE`](LICENSE) 是 GPLv2 全文；
`or later` 表示也可以按更新版本的 GPL 使用（这一句写在文档里，因为标准全文本身不含版权人信息）。

> **版权人**：`README.md`「许可」一节与本文件此处一致记作 **`<DeteminedDesigNer360>`** ——
> `LICENSE` 是标准全文、本身不含版权人信息，所以两处都要写。

（本项目早先按"自有代码 MIT + 第三方例外"的思路走过一段；现按项目决定**统一为 GPL-2.0-or-later**，
理由之一是彻底避开"Lua 脚本是否算 mpv 衍生作品"的争论。）

---

## 6. 再分发这个包时

1. 保留 `mpv-player/licenses/` **整目录**（GPLv2 / LGPL2.1 / Apache-2.0 全文 + mpv 版权声明
   + Vulkan 许可 + 取证文件 `build-config.txt`）；
2. 保留或重新发出 [`SOURCE-OFFER.md`](SOURCE-OFFER.md) 的书面要约（**发布前把联系方式填上**）；
3. **不要**声称包内的 mpv 是你自己的作品，也不要给它换许可证；
4. **不要**把 `CSInterface.js` 说成 GPL；
5. 若你修改了 mpv 或随包脚本，GPL 要求你对修改部分同样提供源码。
