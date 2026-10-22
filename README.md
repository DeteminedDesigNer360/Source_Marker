# Source Marker 工作区

这是 **Source Marker 的开发工作区**，不是发行版本身。
发行版在 `source-marker-united-1.2.0-alpha-r46/`，它的内容与 GitHub 上 `main` 分支一一对应。

## 目录

| 路径 | 是什么 |
|---|---|
| `source-marker-united-1.2.0-alpha-r46/` | **发行包**（Pr 面板 + mpv 播放器 + 许可与文档）。双击包里的 `安装.cmd` 安装。 |
| `docs/` | 标记格式的可机器读版本（JSON Schema）、契约样例、面板截图。 |
| `tools/` | 开发与验证工具：锚点解析、BOM 检查、契约与漂移回归、来源取证、离线测试套件。 |
| `tools/probes/` | **回归探针库**（12 个，见 `可用工具.md` §十四）：拖圆锁死 / 越界 / 双击 / 最小跨度 / Pr 概览条扫描。 |
| `_tmp/` | 一次性探针与截图（已 gitignore）。**每轮收尾清空**，有复用价值的移进 `tools/probes/`。 |
| `参考视频/` | 冻结标记格式时用的参考素材与实测记录。 |
| `Archive/` | 历史归档：三个 1.0.0 原始发行版（只读回滚基线）、播放器侧许可资产、旧发布说明。 |
| `Archive/历史文档/` | 过期交接（`交接-r46-时间轴-换人总结`、`交接-r46-下一对话`、`r45-r46-改动速查`）。 |
| `run-all-tests.ps1` | 一键跑完离线测试（见下）。 |
| `.gitignore` | 排除 `ffmpeg.exe` 等本地工具（208 MB，超出 GitHub 单文件上限）。 |

## 文档导航（先读哪份）

| 想做的事 | 读这份 |
|---|---|
| 看**还剩什么没做**、目标与验收 | `新功能开发目标1.2.0『交织』.md` |
| 接手开发 / 看**每轮到哪一步** | `交接-1.2.0-进度.md` |
| **上机验**当前构建 | `source-marker-united-1.2.0-alpha-r46/上机测试清单-1.2.0.md`（最新是步骤 11） |
| 查某处**为什么这么改** | `source-marker-united-1.2.0-alpha-r46/改动说明.md` |
| 第 9 条（时间轴/面板）**设计定稿** | `设计-第9条-时间轴与面板.md`（§十三 是 r47 定稿） |
| 第 8 条（OSD 控制栏）设计与实测 | `设计-第8条-Pr风格OSD栏.md` |
| **Pr 的缩放条到底怎么工作**（实测数据） | `测量-Pr概览条与最小可视范围.md`、`测量方案-Pr控制条.md`、`测量工作表-NS1NS4.md` |
| 别重复踩坑 | `经验与规矩.md` |
| 有哪些工具 / 探针 / 命令 | `可用工具.md` |

## 一条命令跑完离线测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-all-tests.ps1
```

## 两处不要动

- `Archive/原始发行版/` 里的三个 1.0.0 目录是**只读回滚基线**，用来与发行包逐字节对照 —— 别改。
- 发行包内 `mpv-player/mpv.exe` 的字节是**许可证据链**的一环（`SHA256SUMS.txt` + `licenses/build-config.txt`）；
  换二进制之前先读 `THIRD-PARTY.md`，并按 `SOURCE-OFFER.md` 更新源码指向。