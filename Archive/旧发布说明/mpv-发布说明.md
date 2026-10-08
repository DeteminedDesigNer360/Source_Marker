# Source Markers 播放器 v1.0.0

2026-10-06 打包 ｜ 自带 mpv 的绿色便携播放器 + 播放头标记插件（导出给 Premiere 的 Source Marker 面板）

## 下载哪个

| 文件 | 说明 |
|---|---|
| `mpv-source-markers-1.0.0.zip` | 解压即用（22.4 MB） |
| `mpv-source-markers-1.0.0/` | 同一个包的目录形式（不想解压就直接用目录里的 mpv.exe） |

## 三步用起来

1. 解压到任意目录（别放 `C:\Program Files`）；
2. 把视频拖到 `mpv.exe` 或 `打开视频.cmd` 上；
3. 按 `F1` 看快捷键 / `F2` 开按钮面板（鼠标点一切）→ `Ctrl+e` 导出 →
   Pr 里 `窗口 > 扩展 > Source Marker` 导入那个 CSV。

细节见包内 `快速上手.md` 与 `README.md`。

## 校验和

```
SHA256(mpv-source-markers-1.0.0.zip)   = a1128cdfbb5ea580c56407a8fb6eaf3b4bd2059febfe22495cf7a32d6ba3ab6b
SHA256(source-markers.lua) = 4e1eb76c4dd171085b7eeb6fe072c1c8f74e1815a1335cb3126337275aa94308
```

包内还有 `SHA256SUMS.txt` 与 `校验.ps1`，可逐个文件核对。

## 组成

- **mpv 0.41.0**（官方 Windows x64 构建，二进制**未改动**）
- **source-markers.lua**（本仓库插件，哈希见上）
- 默认配置已开启按钮面板与精确跳转
- `licenses/`：mpv 的 Copyright / GPL / LGPL 全文（**再分发请一并保留**）

## 已验证

- 解压后的便携包**只读自己的 portable_config**，插件自动加载；
- 插件产出的标记文件经仓库里**真机测试通过的 Pr 面板 v1.0.0** 的真实解析器与导入循环验证：
  `added = 标记数`、`failed = 0`、颜色与命名映射正确；
- 插件自身回归：7 个套件 / 185 项断言全绿（含真实鼠标点击面板、29.97fps 漂移、坏文件健壮性）。

## 许可

mpv 以 GPLv2+（部分 LGPLv2.1+）发布；本包原样再分发官方构建，完整条款见包内 `licenses/`。
mpv/FFmpeg 源码获取见 `README.md` 的「许可」一节。