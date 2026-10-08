# NOTICE —— 适用范围

本文件说明**哪些部分受根目录 `LICENSE`（MIT）约束，哪些不受**。发布前请补齐占位内容。

## 受 MIT 约束（本仓库自有代码）

- `player-plugin/`（mpv 播放器标记插件：Lua 脚本、安装与打包脚本、测试）
- `tools/`（构建、打包、验证工具）
- `docs/`、`research/`、`probe/`、`verify/`（文档与验证留档）
- 仓库根目录的说明与脚本

## 不受 MIT 约束（第三方，各自按自己的许可分发）

| 组件 | 许可 | 说明 |
|---|---|---|
| `mpv.exe`、`mpv.com`、`mpv-register.bat`、`mpv-unregister.bat` | **GPL-2.0-or-later** | mpv 官方 v0.41.0 Windows 资产的**原样**再分发（哈希可验），版权归 mpv/MPlayer/mplayer2 项目及其贡献者 |
| `vulkan-1.dll` | **Apache-2.0** | 由 mpv 官方 CI 从 Khronos Vulkan-Loader 源码构建 |

完整的组件清单、来源、修订版与义务见 [`licenses/THIRD-PARTY.md`](licenses/THIRD-PARTY.md)，
GPL 对应源码的获取方式见 [`licenses/SOURCE-OFFER.md`](licenses/SOURCE-OFFER.md)。

## 待补齐（发布前）

- [ ] 根 `LICENSE` 的版权行：`<COPYRIGHT HOLDER>` → 实际版权人/组织
- [ ] `licenses/SOURCE-OFFER.md` 第 1 节的联系方式
- [ ] Pr 面板扩展（`extension/`，另一侧代码）的许可声明——**需与该侧作者确认**
