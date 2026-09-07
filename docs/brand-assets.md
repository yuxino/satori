# 品牌资产

更新：2026-09-07

## 当前角色与原图

用户从六个候选中选择 F「猫耳兜帽」，并要求更换项目 logo。当前图标采用已说明的默认导出方式：保留 F 原画的方形构图和象牙色背景，只缩放并封装为平台图标。未对原画抠图、重绘或调整五官。

[source.png](../src-tauri/icons/source.png) 与选定 F 原图逐字节一致，是后续重建的唯一原始输入：

- 尺寸：1254×1254。
- 文件大小：1,598,437 字节。
- SHA-256：`89094c287777b7c89b2635ad172ea4ba0feb9551dcd8676895de25195acac097`。
- 原图及所有平台派生均完全不透明，alpha 为 255；背景属于原画内容。

当前方案替代旧角色及旧透明背景图标。[ADR 0017](decisions/0017-windows-support.md) 保留历史要求，并记录本次视觉更新。项目的黑、白、中性灰界面保持既有规则。

## 文件与引用

| 文件 | 尺寸或图像帧 | 使用位置 |
| --- | --- | --- |
| [source.png](../src-tauri/icons/source.png) | 1254×1254 | 原图留存与重建输入，不加入 bundle 图标配置 |
| [32x32.png](../src-tauri/icons/32x32.png) | 32×32 | 基础 Tauri 图标配置 |
| [128x128.png](../src-tauri/icons/128x128.png) | 128×128 | 基础 Tauri 图标配置 |
| [128x128@2x.png](../src-tauri/icons/128x128@2x.png) | 256×256 | 基础 Tauri 配置、中英文 README |
| [icon.icns](../src-tauri/icons/icon.icns) | 10 个图像条目，像素尺寸覆盖 16、32、64、128、256、512、1024；另有 2 个蒙版条目 | macOS bundle 与稳定开发壳 |
| [icon.ico](../src-tauri/icons/icon.ico) | 16、20、24、32、40、48、64、128、256，共 9 帧 | Windows 应用、NSIS 安装器与卸载器 |

路径由 [基础配置](../src-tauri/tauri.conf.json) 与 [Windows 配置](../src-tauri/tauri.windows.conf.json) 引用。NSIS header/sidebar 仍属于独立的共享安装器主题，不从本项目图标派生。

## 重建方法

本次使用 Tauri CLI 2.11.4 与 Pillow 11.3.0。先让 Tauri 从原图生成平台资源，复制五个既有常规产物，再直接从原图用 Pillow 封装完整九尺寸 ICO。当前 Tauri CLI 的默认 ICO 候选缺少 128px 帧，因此不能省略最后一步。

在 macOS 的仓库根目录执行；Python 环境需已安装 Pillow。以下命令生成资源，不启动原生应用：

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
satori_icon_stage="$(mktemp -d "${TMPDIR:-/tmp}/satori-icons.XXXXXX")"
npm run tauri -- icon src-tauri/icons/source.png --output "$satori_icon_stage"
for satori_icon_name in 32x32.png 128x128.png 128x128@2x.png icon.icns icon.ico; do
  cp "$satori_icon_stage/$satori_icon_name" "src-tauri/icons/$satori_icon_name"
done

python3 - <<'PY'
from pathlib import Path
from PIL import Image

icons = Path("src-tauri/icons")
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
with Image.open(icons / "source.png") as source:
    source.convert("RGBA").save(
        icons / "icon.ico",
        format="ICO",
        sizes=[(size, size) for size in sizes],
    )
PY
```

RGBA 转换仅提供平台编码所需的通道，不会生成透明背景。Tauri 生成的其它平台文件留在临时目录；仓库保留上表中的六个文件。原图文件本身不经过重存或覆盖。

## 已完成检查与边界

本次逐字节核对原图来源，并解码 6 个文件中的全部 23 个图像帧：4 个 PNG（含原图）、9 个 ICO 帧、10 个 ICNS 图像条目。尺寸和容器结构检查通过；所有帧 alpha 的最小值和最大值均为 255，透明与半透明像素数均为零。九尺寸 ICO 的上述 Pillow 封装方法已在内存中重现，字节与当前文件一致。

外部交付证据 `native-icon-verification.json` 与独立重新解码结果完全一致。只读检查脚本的普通模式返回 `ok: true`、`structural_ok: true`、`transparency_ok: false`；使用 `--require-transparent` 时返回失败，明确反映当前不透明方案。

九尺寸 ICO 已在浅色、深色背景下实际目视检查，保留象牙方形背景；16px 能辨认帽子和脸的大致形状，细节有限。图标更新后的前端 72/72 项测试、TypeScript/Vite build，以及 `cargo check --locked --manifest-path src-tauri/Cargo.toml --release` 均通过。

本轮资源和编译检查不等于安装包或系统显示验收。原生源版本仍为 3.4.5，未安装、启动原生应用，也未创建或替换 Release。今后发布包含新图标的原生包时，仍需分别核对实际包内资源，以及 macOS Dock、Windows 任务栏、快捷方式、安装器和卸载器的显示效果。
