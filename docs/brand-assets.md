# 品牌资产

更新：2026-09-08

## 当前角色与原图

用户从六个候选中选择 F「猫耳兜帽」，并授权使用本地图像工具完成圆形透明 Logo。当前版本从认可原画直接添加居中圆形透明蒙版，保留五官、配色、画风和 1254×1254 原生分辨率，不重绘或放大原图。圆形边界会自然裁去原方图四角的一部分帽沿与衣服；脸部、眼睛与书签领扣保持原位置。

原画逐字节保存在 [portrait-original.png](brand/portrait-original.png)，后续重建以它为唯一输入：

- 尺寸：1254×1254 RGB。
- 文件大小：1,598,437 字节。
- SHA-256：`89094c287777b7c89b2635ad172ea4ba0feb9551dcd8676895de25195acac097`。

圆形主图 [source.png](../src-tauri/icons/source.png) 为真实 RGBA PNG，RGB 三个通道逐像素等同原图，只改变 alpha：

- 尺寸：1254×1254；文件大小：1,793,559 字节。
- SHA-256：`10f18a0b0c24b9ef809db1af040ba5c5e0d873e4c5c2d6d45a3ad509303a8de1`。
- 四角 alpha 均为 0；331,696 个完全透明像素、12,004 个抗锯齿像素、1,228,816 个完全不透明像素。
- 圆内保留原画象牙色背景，圆外真正透明；不包含模拟透明的棋盘格、额外边框或阴影。

内置绘图的透明背景尝试返回了带棋盘格的 RGB 图片，均未采用。用户许可后使用 Pillow 处理原画透明蒙版。此方案替代 2026-09-07 的不透明方形导出；[ADR 0017](decisions/0017-windows-support.md) 保留相应历史。黑、白、中性灰的应用界面不变。

## 文件与引用

| 文件 | 尺寸或图像帧 | 使用位置 |
| --- | --- | --- |
| [portrait-original.png](brand/portrait-original.png) | 1254×1254 | 认可原画档案，不加入 bundle |
| [source.png](../src-tauri/icons/source.png) | 1254×1254 | 圆形透明主图，平台图标导出输入 |
| [32x32.png](../src-tauri/icons/32x32.png) | 32×32 | 基础 Tauri 图标配置 |
| [128x128.png](../src-tauri/icons/128x128.png) | 128×128 | 基础 Tauri 图标配置 |
| [128x128@2x.png](../src-tauri/icons/128x128@2x.png) | 256×256 | 基础 Tauri 配置、中英文 README（显示 128px） |
| [icon.icns](../src-tauri/icons/icon.icns) | 10 个图像条目，像素尺寸覆盖 16、32、64、128、256、512、1024；另有 2 个蒙版条目 | macOS bundle 与稳定开发壳 |
| [icon.ico](../src-tauri/icons/icon.ico) | 16、20、24、32、40、48、64、128、256，共 9 帧 | Windows 应用、NSIS 安装器与卸载器 |

路径继续由 [基础配置](../src-tauri/tauri.conf.json) 与 [Windows 配置](../src-tauri/tauri.windows.conf.json) 引用。NSIS header/sidebar 仍是独立共享安装器主题，不从项目图标派生。

## 重建方法

使用已安装的 Tauri CLI 2.11.4 和 Pillow 11.3.0。在仓库根目录执行：

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 scripts/generate-brand-icons.py
```

[重建脚本](../scripts/generate-brand-icons.py) 先验证原图尺寸与 SHA，再以 4 倍采样绘制居中圆形蒙版，用 Lanczos 缩至原分辨率并仅替换 alpha。随后调用 Tauri 生成平台资源，并用 Pillow 补齐 Windows ICO 的全部九个尺寸（Tauri 默认 ICO 缺少 128px 帧）。中间导出保留在 `src-tauri/target/brand-icons/`，不加入版本控制。官网 `public/satori-avatar.png` 与此处 `source.png` 同字节，使用新路径避开旧方图的一年不可变缓存；官网 hero 保留原画。

## 已完成检查与边界

圆形主图的四角透明、alpha 分布和 RGB 原样保留检查通过。六个图标文件的全部 23 个图像帧（4 个 PNG、9 个 ICO、10 个 ICNS）均可解码，尺寸完整，存在真实透明背景与抗锯齿像素，四角均透明。浅色和深色背景下已目视检查主图及 16、24、32、64、128px 的实际 ICO 导出；圆形边缘干净，16px 只能保留脸与帽子的概貌。

本次前端生产构建和 release profile 的 Rust 检查通过。资源与编译检查不等于安装包或系统显示验收。原生版本仍为 3.4.5，未安装、启动原生应用，也未创建或替换 Release。今后发布包含新图标的原生包时，仍需核对包内资源以及 macOS Dock、Windows 任务栏、快捷方式、安装器和卸载器的实际显示。
