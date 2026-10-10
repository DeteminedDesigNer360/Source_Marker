# 对应源码的书面要约（Written Offer for Corresponding Source）

本发行包中包含按 **GPL-2.0-or-later** 分发的第三方二进制 **mpv**
（`mpv-player/mpv.exe`、`mpv-player/mpv.com`，及其静态链接的库）。
依据 GNU GPL 第 2 版第 3 条，我们在此提供获取**对应源码**的途径。S

---

## 1. 书面要约

> 本发行包的维护者向任何获得本包的个人或组织承诺：自本包发布之日起 **三年内**，
> 可依申请提供该包中 GPL 授权二进制的**完整对应源码**（含构建所需的脚本与配置文件），
> 费用不超过我们实际执行分发的成本（通常为 0，通过网络提供）。
>
> 申请方式：2054013566@qq.com

在网络分发场景下，更简便的做法是直接按下面第 2 节自行获取源码 —— 那是**逐条可复现**的。

---

## 2. 精确到修订版的源码获取方式

### 2.1 分发物到底是什么

| 项                    | 值                                                                                                   |
| --------------------- | ---------------------------------------------------------------------------------------------------- |
| 上游资产              | `mpv-v0.41.0-x86_64-pc-windows-msvc.zip`                                                             |
| 下载地址              | <https://github.com/mpv-player/mpv/releases/download/v0.41.0/mpv-v0.41.0-x86_64-pc-windows-msvc.zip> |
| 资产 SHA256           | `4e197f729f5071c6772f35fffd96e0f36e3e8a044bd9479b136bb09b7c6a80ff`                                   |
| 其中 `mpv.exe` SHA256 | `6145e63f026451a764077d53fd60860ec9f5c2bc76dcd6e62a88967ac375453d`                                   |
| 二进制自报的构建修订  | mpv `41f6a6450`；FFmpeg `f853d12`；libplacebo `v7.358.0`                                             |

> 我们**没有修改**这些二进制（哈希与上游资产逐字节一致）。
> 注意：发布 tag 是 `v0.41.0`，但二进制自报的是 `v0.41.0-dev-g41f6a6450`
> （官方 CI 在打 tag 之后从 master 构建）—— **以 commit 为准**。

### 2.2 源码清单

1. **mpv** —— `https://github.com/mpv-player/mpv`，检出构建修订：

   ```bash
   git clone https://github.com/mpv-player/mpv
   git checkout 41f6a6450
   ```

   该修订自带的许可文本即本包 `mpv-player/licenses/` 下的
   `LICENSE-GPL.txt`、`LICENSE-LGPL.txt`、`Copyright.txt`
   （对应上游的 `LICENSE.GPL`、`LICENSE.LGPL`、`Copyright`）。
   离线快照：`https://codeload.github.com/mpv-player/mpv/tar.gz/41f6a6450`
   （注意 GitHub 生成的 tarball 不作为字节稳定的凭据，权威依据是 commit 本身）。

2. **FFmpeg** —— `https://github.com/FFmpeg/FFmpeg`，检出 `f853d12`
   （由二进制自报 `FFmpeg version: f853d12` 得出）。

3. **其余静态链接依赖** —— 由 mpv 官方 CI 通过 **Meson WrapDB** 与少量手工 wrap 获取，
   获取方式记录在 mpv 源码内的这两个文件（同一 `41f6a6450` 修订）：

   - `.github/workflows/build.yml` —— `win32` 作业（`x86_64-pc-windows-msvc`，`windows-latest`）；
     步骤 `Update Meson WrapDB` 执行 `meson wrap update-db` 与
     `meson wrap install expat|harfbuzz|libpng|zlib`
   - `ci/build-win32.ps1` —— 手工 wrap 了 `shaderc`（2024.1）、`spirv-cross`（0.59.0）、
     `Vulkan-Loader`（1.3.285，产出本包内的 `vulkan-1.dll`）、`libjxl`（0.12.0）等

4. **精确构建配置** —— 见 `mpv-player/licenses/build-config.txt`，其中逐字记录了二进制内嵌的 meson 配置：

   ```
   -Ddefault_library=static -Dlibmpv=true -Dtests=true -Dgpl=true -Dffmpeg:gpl=enabled ... -Dwrap_mode=forcefallback
   ```

   这份配置由上游工具**从分发物本身**重新提取，因此它描述的正是这个二进制，
   而不是"上游大概怎么编的"。

### 2.3 复现步骤（等价重建）

```bash
# 环境：Windows + Visual Studio 2022 + Python3 + meson 1.9.2 + nasm + cmake 4.0.2（CI 同款）
git clone https://github.com/mpv-player/mpv && cd mpv && git checkout 41f6a6450
mkdir subprojects
meson wrap update-db
meson wrap install expat harfbuzz libpng zlib
powershell -File ci/build-win32.ps1          # 按 CI 的 win32 作业执行
```

产物即等价于上游 `x86_64-pc-windows-msvc` 资产（同一配置、同一依赖解析）。

---

## 3. 其他组件的源码

- **Vulkan-Loader**（`vulkan-1.dll`，Apache-2.0）：<https://github.com/KhronosGroup/Vulkan-Loader>
  —— CI 配方声明 1.3.285；许可文本见包内 `mpv-player/licenses/vulkan-loader-LICENSE.txt` 与 `Apache-2.0.txt`。
- 其余库（libass / dav1d / LuaJIT / mujs / harfbuzz / …）均为公开开源项目，
  源码地址见 [`THIRD-PARTY.md`](THIRD-PARTY.md) 第 3 节。

---

## 4. 本包自身代码

本包自有代码（Pr 面板的 CEP 前端与 ExtendScript 宿主、Lua 脚本、安装脚本、文档）
按 **GPL-2.0-or-later** 分发（包根 [`LICENSE`](LICENSE)）。
它本身就是 GPL 代码，因此"提供对应源码"这一点由本包自身满足 —— **源码即包内可读的文本文件**。

> **例外**：`pr-extension/*/extension/client/CSInterface.js` 是 Adobe 的文件，
> 不适用本包许可，详见 [`THIRD-PARTY.md`](THIRD-PARTY.md) 第 4 节。

> ⚠️ **发布前必须补一处占位**：第 1 节的联系方式（邮箱或 issue 地址）不填，书面要约不成立。
