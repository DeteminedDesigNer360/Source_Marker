# Source Marker 工作区

这是 **Source Marker 的开发工作区**，不是发行版本身。
发行版在 `source-marker-united-1.2.0-alpha-r3/`，它的内容与 GitHub 上 `main` 分支一一对应。

## 目录

| 路径 | 是什么 |
|---|---|
| `source-marker-united-1.2.0-alpha-r3/` | **发行包**（Pr 面板 + mpv 播放器 + 许可与文档）。双击包里的 `安装.cmd` 安装。 |
| `docs/` | 标记格式的可机器读版本（JSON Schema）、契约样例、面板截图。 |
| `tools/` | 开发与验证工具：锚点解析、BOM 检查、契约与漂移回归、来源取证、离线测试套件。 |
| `参考视频/` | 冻结标记格式时用的参考素材与实测记录。 |
| `Archive/` | 历史归档：三个 1.0.0 原始发行版（只读回滚基线）、播放器侧许可资产、旧发布说明与交接文档。 |
| `run-all-tests.ps1` | 一键跑完离线测试（见下）。 |
| `.gitignore` | 排除 `ffmpeg.exe` 等本地工具（208 MB，超出 GitHub 单文件上限）。 |

## 一条命令跑完离线测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-all-tests.ps1
```

## 两处不要动

- `Archive/原始发行版/` 里的三个 1.0.0 目录是**只读回滚基线**，用来与发行包逐字节对照 —— 别改。
- 发行包内 `mpv-player/mpv.exe` 的字节是**许可证据链**的一环（`SHA256SUMS.txt` + `licenses/build-config.txt`）；
  换二进制之前先读 `THIRD-PARTY.md`，并按 `SOURCE-OFFER.md` 更新源码指向。