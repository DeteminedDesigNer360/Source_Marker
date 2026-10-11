# Source Markers 播放器（mpv 便携版 + 标记插件）

面向剪辑流程的"看片打标记"工具：在播放头处打标记（时间戳 + 颜色 + 描述），
导出成 Premiere Pro **Source Marker** 面板可直接导入的标记文件。

- **本包已经包含 mpv 本体**，解压即用；不写注册表、不改文件关联、不动系统目录。
- 新手请先看 [`快速上手.md`](快速上手.md)；快捷键随时按 <kbd>F1</kbd>，鼠标党按 <kbd>F2</kbd> 开按钮面板。

---

## 包里有什么

```
mpv-player/
  mpv.exe                    mpv 0.41.0（官方 Windows x64 构建，未改动）
  mpv.com                    同上的控制台版本（给脚本/自动化用）
  vulkan-1.dll               Vulkan 加载器（mpv 需要的运行库）
  mpv-register.bat / -unregister.bat   官方自带的"关联文件类型"脚本（可选，会改注册表）
  portable_config/
    mpv.conf                 本包默认配置（已开启按钮面板、精确跳转、OSD）
    input.conf.example       改键位示例（要生效请复制成 input.conf）
    scripts/source-markers.lua   ← 标记插件本体（唯一需要关心的文件）
  打开视频.cmd                把视频拖到它上面即可播放（等价于拖到 mpv.exe）
  快速上手.md                 新手三步上手
  README.md                   本文件（技术细节、可调项、许可）
  校验.ps1                    核对 SHA256SUMS.txt，确认文件未被改动
  SHA256SUMS.txt              各文件校验和
  licenses/                   mpv 的许可与版权说明（GPL/LGPL 全文）
```

> 便携模式的关键：`portable_config/` 与 `mpv.exe` 同级，mpv 只读这里的配置，
> 不会碰你 `%APPDATA%\mpv` 里的个人配置。

---

## 标记功能怎么用

| 操作 | 键 |
|---|---|
| 帮助浮窗 | `F1` |
| 按钮面板（鼠标点一切） | `F2` |
| 打标记（当前颜色） | `Ctrl+m` |
| 打标记 + 写描述 | `Alt+m` |
| 选颜色 0..7 | `Ctrl+1` … `Ctrl+8` |
| 标记列表 / 上下跳 / 按序跳转 | `Ctrl+l` / `Alt+n` `Alt+p` / `Alt+g` |
| 编辑描述 / 删除最近 | `Alt+e` / `Ctrl+DEL` |
| 导出 / 导入 | `Ctrl+e` / `Ctrl+i` |

- **描述就是 Pr 里的标记名**：Pr 面板的规则是 `标记名 = 备注列`，
  所以本插件不让用户往"名字"列写字 —— 那一列保留在文件里但**写空**（Pr 整列忽略它）。
- 自动保存：与视频同名的 `*.mpv-autosave.json`，每改一次就原子写入，并**设为隐藏文件**防误删。
- 导出：`Ctrl+e` 写出 `.csv`（给 Pr / Excel）+ `.json`（无损，带 fps 与源文件信息）。
- 导入：`Ctrl+i` 支持 CSV / TSV / JSON / SRT。

标记文件格式规范（v1）见仓库里的 `docs/marker-format.md`；本包产出的文件已用**真机测试通过的
Pr 面板 v1.0.0** 的真实解析器与导入循环逐条验证过（`added = 标记数`、`failed = 0`）。

---

## 可调项

改 `portable_config\mpv.conf`（多个 `script-opts` 用逗号分隔，写在同一行）：

```ini
script-opts=source-markers-panel=yes,source-markers-time_format=ms,source-markers-default_color=1
```

| 选项 | 默认 | 说明 |
|---|---|---|
| `sidecar` | `yes` | 是否自动保存同名 `*.mpv-autosave.json` |
| `hide_sidecar` | `yes` | 把 sidecar 设为隐藏文件（Windows） |
| `time_format` | `ms` | `ms`（`HH:MM:SS.mmm`，与帧率无关）/ `ff`（`HH:MM:SS:FF`）/ `sec` / `auto` |
| `csv_bom` | `yes` | 导出 CSV 带 UTF-8 BOM（Excel 友好；Pr 面板会剥掉） |
| `default_color` | `1` | 起始颜色索引 |
| `import_mode` | `replace` | 导入时 `replace` 覆盖 / `append` 追加 |
| `panel` | 本包设为 `yes` | 启动时显示按钮面板（`F2` 随时开关，选择会记住） |
| `panel_anchor` | `bottom-left` | `bottom-left` / `top-left` / `top-right` / `bottom-right` |
| `panel_bottom` | `0` | `0` = 自动抬到进度条上方；也可填固定像素 |
| `hint` | `yes` | 首次打开素材自动弹一次帮助 |
| `overlay_limit` | `18` | 标记列表最多显示几条 |
| `hr_seek` | `yes` | 跳转是否帧精确（`no` 时按关键帧跳） |

---

## 版本与来源

| 组件 | 版本 | 来源 |
|---|---|---|
| mpv | **0.41.0**（2025-12-21，`mpv-v0.41.0-x86_64-pc-windows-msvc`） | 官方 GitHub Release，**二进制未做任何改动** |
| source-markers.lua | 插件 1.0.1-alpha（本仓库 `player-plugin/source-markers.lua`） | 同哈希随包提供，见 `SHA256SUMS.txt` |
| 标记格式 | v1（`docs/marker-format.md`） | — |

**校验**：在包里运行 `校验.ps1`（或 `Get-FileHash -Algorithm SHA256`）对照 `SHA256SUMS.txt`。

---

## 许可（重要）

本包**重新分发**了 mpv 的官方 Windows 构建，因此：

- mpv 本体以 **GPLv2+**（部分组件 LGPLv2.1+）发布；完整条款与版权说明见 `licenses/` 目录
  （`Copyright.txt`、`LICENSE-GPL.txt`、`LICENSE-LGPL.txt`，取自 mpv 官方仓库 v0.41.0 标签）。
- 该构建内嵌 FFmpeg 等库，其许可与源码获取方式同样见上面两个文件。
- 本包只做了"打包"，**未修改 mpv 的任何二进制**；需要 mpv/FFmpeg 源码请到
  <https://github.com/mpv-player/mpv> 与 <https://ffmpeg.org/download.html> 获取对应版本源码。
- `vulkan-1.dll` 为 Vulkan 加载器（Khronos 开源实现），随官方构建一同分发。
- 随包的 `source-markers.lua` 是独立脚本，与本仓库其他部分一同按仓库约定使用。

如果你要再分发本包，请**连同 `licenses/` 一起**分发。
