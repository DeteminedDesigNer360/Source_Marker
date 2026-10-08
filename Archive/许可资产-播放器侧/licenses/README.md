# 许可与第三方组件（licenses/）

本目录是**合并版仓库的许可中心**：法定文本、第三方组件清单、GPL 对应源码的书面要约与取证文件。

---

## 1. 三句话看懂边界

| 对象 | 许可 | 说明 |
|---|---|---|
| **本仓库自有代码**（播放器插件 Lua、测试与工具脚本、文档） | **MIT**（根目录 [`../LICENSE`](../LICENSE)） | 你可以自由使用/修改/再分发 |
| **随包分发的 mpv 二进制**（`mpv.exe`、`mpv.com`、register 脚本） | **GPL-2.0-or-later** | 它是 mpv 官方 v0.41.0 的 Windows 资产，**未做任何修改**；再分发须给许可文本 + 对应源码（见下文） |
| **`vulkan-1.dll`** | **Apache-2.0** | 由 mpv 官方 CI 从 Khronos Vulkan-Loader 源码构建 |

**为什么 mpv 是 GPL 而不是 LGPL**：这个构建用了 `-Dgpl=true -Dffmpeg:gpl=enabled`，
且 7 个 libav* 库都自报 `GPL version 2 or later`。证据不是"查文档得来的"，而是
`tools/collect-mpv-provenance.py` 从**分发物本身**提取并断言的，可随时复跑：

```bash
python tools/collect-mpv-provenance.py     # 生成/校验 licenses/build-config.txt；非 GPL 构建会以退出码 2 失败
```

---

## 2. 目录内容

| 文件 | 内容 |
|---|---|
| [`THIRD-PARTY.md`](THIRD-PARTY.md) | **组件清单**：我们分发了什么（含逐文件 SHA256）、上游资产来源、静态链接依赖与各自许可 |
| [`SOURCE-OFFER.md`](SOURCE-OFFER.md) | **GPL 对应源码**的书面要约 + 精确到修订版（mpv `41f6a6450`、FFmpeg `f853d12`）的获取与复现步骤 |
| [`build-config.txt`](build-config.txt) | **取证文件**：从 `mpv.exe` 内嵌数据提取的 meson 配置、特性列表、各库许可证行（由工具生成，勿手改） |
| [`GPL-2.0.txt`](GPL-2.0.txt) | GNU GPL v2 全文（取自 mpv 源码 `LICENSE.GPL`，即构建修订自带的那份） |
| [`LGPL-2.1.txt`](LGPL-2.1.txt) | GNU LGPL v2.1 全文（mpv 源码 `LICENSE.LGPL`） |
| [`mpv-Copyright.txt`](mpv-Copyright.txt) | mpv 的版权与许可总述（说明"默认 GPLv2+，`-Dgpl=false` 时为 LGPLv2.1+"） |
| [`Apache-2.0.txt`](Apache-2.0.txt) | Apache License 2.0 全文（Vulkan-Loader 用） |
| [`vulkan-loader-LICENSE.txt`](vulkan-loader-LICENSE.txt) | Khronos Vulkan-Loader 项目自带的许可说明 |

---

## 3. 再分发前必须做的事（清单）

- [ ] **填上 `SOURCE-OFFER.md` 第 1 节的联系方式**（否则书面要约不成立；用 issue 地址也可以）
- [ ] **填上根目录 `LICENSE` 的版权行**（当前是占位 `<COPYRIGHT HOLDER>`）
- [ ] 保留本目录**整目录**，不要只留 GPL-2.0.txt
- [ ] 若把 mpv 二进制放进 Git 仓库本身（而不是 Releases），注意仓库体积与"源码可得性"的一致性；
      本仓库的推荐做法是**二进制只进 Releases**，仓库里只留本目录的许可与取证文件
- [ ] 若修改了 mpv 或随包脚本中的 mpv 部分，GPL 要求对修改部分同样提供源码

---

## 4. 未决项（需要人来拍板，不是技术问题）

| 项 | 现状 | 建议 |
|---|---|---|
| 自有代码用哪个许可 | 本仓库默认给的是 **MIT**（播放器插件生态常见做法：uosc、thumbfast 等都是 MIT） | 若想彻底避开"Lua 脚本是否算 mpv 衍生作品"的争论，可整体改成 **GPL-2.0-or-later**（与随包 mpv 一致，零解释成本）。改动只需替换根目录 `LICENSE` |
| Pr 面板扩展（另一侧代码）的许可 | 本目录**没有**对它做任何授权声明 | 合并仓库需要一个统一说法：要么两侧各自文件头标注、要么统一到根 `LICENSE`。**请与 Pr 扩展的作者确认后再定**，不要由单方默认覆盖 |
| 发行包里 mpv 是否要放源码 tarball | 目前不放，靠 `SOURCE-OFFER.md` 指向上游 + 书面要约 | 若走商业/离线分发渠道，建议随包附带源码或明确的有效期书面要约 |

---

## 5. 一句话合规路径

> 我们的代码 MIT；随包 mpv 是 GPLv2+（未改动，哈希可验）；许可文本与书面要约都在本目录；
> 对应源码 = mpv `41f6a6450` + FFmpeg `f853d12` + CI 配方（`.github/workflows/build.yml`、`ci/build-win32.ps1`）
> 与 meson 配置串。任何人可据此完整重建。
