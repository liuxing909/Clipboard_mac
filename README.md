# 剪贴匣 · ClipboardDeck

一个轻量的 macOS 本地剪贴板历史工具，采用类似 Windows Win+V 的交互：快捷键打开、上下选择、回车粘贴。使用 Swift、SwiftUI 和 AppKit，无第三方运行时依赖。

当前版本 **0.1.8，早期预览**。项目侧重常用格式、键盘操作和后台资源控制，兼容性验证范围见下文。

<img src="Resources/Preview.png" alt="剪贴匣界面：文字、富文本和文件历史" width="416">

## 功能

- 保存文字、HTML / RTF / RTFD 富文本、静态图片和 Finder 文件引用。
- 搜索内容、文件名和来源应用；支持分类、固定、去重、暂停和清理。
- 快捷键打开面板，选择后返回原应用粘贴，也可仅复制。
- 快捷键注册失败时持续提醒，替换失败保留原有快捷键。
- 后台串行处理图片和格式，限制队列与缓存预算，隐藏面板时释放图片缓存。

## 系统要求

| Mac | 最低运行版本 |
| --- | --- |
| Intel | macOS 10.15 |
| Apple Silicon | macOS 11 |

macOS 10.15–13 使用 AppKit 界面，14+ 使用 SwiftUI 界面；两种界面共享存储和格式处理。两个架构已编译验证，运行测试在现代 macOS 上完成，**尚未完成 macOS 10.15 实机验证**。

## 构建与安装

构建需要 Swift 6+（Xcode 或 Command Line Tools），开发主机需满足所用工具链的系统要求。

```sh
git clone https://github.com/liuxing909/Clipboard_mac.git
cd Clipboard_mac
bash scripts/build.sh
open dist/剪贴匣.app
```

默认生成 Intel + Apple Silicon 通用应用，并内嵌 Apple 的并发兼容运行库。快速开发可使用 `bash scripts/build.sh --native`，只编译当前架构。

生成可拖拽安装的 DMG：

```sh
bash scripts/package-dmg.sh
```

输出为 `dist/ClipboardDeck-<版本>-universal.dmg`。打开后将“剪贴匣”拖入 `Applications`，再从“应用程序”启动；系统收录后可以通过 **⌘＋空格** 搜索“剪贴匣”。更新前先退出旧版，再替换应用。

当前构建使用本地 **ad-hoc 签名，尚未完成 Developer ID 签名与公证**。构建和打包脚本不会自动安装应用。

## 使用

1. 启动后，图标常驻菜单栏，不显示 Dock 图标。记录从启动后的下一次复制开始。
2. 复制文字、富文本、图片，或在 Finder 复制文件。
3. 按 **Control + Option + V（⌃⌥V）** 打开面板，输入关键词或用方向键选择。
4. 按 **↵** 粘贴，按 **⌘↵** 仅复制。自动粘贴需要在系统设置的“辅助功能”中允许剪贴匣；未授权时可仅复制，再手动按 ⌘V。
5. 右键记录可预览、固定或删除；设置中可修改快捷键、历史条数、暂停记录或退出。

自动粘贴依赖目标应用的标准 ⌘V 行为和焦点恢复。快捷键检查覆盖系统快捷键和独占注册冲突，不能识别全部按键拦截或占用者名称。

## 格式与容量

| 内容 | 保存方式与边界 |
| --- | --- |
| 纯文字 | 保留 Unicode、换行、制表符，单条最多 1 MiB。 |
| HTML / RTF / RTFD | 保留支持格式的原始字节和文字摘要，格式数据合计最多 4 MiB；RTFD 支持已验证的平铺文件结构、最多 32 个静态 PNG / TIFF / JPEG 附件，附件总像素最多 16MP；未知结构尝试其他有效表示，否则不保存。 |
| 图片 | 保留 PNG 原数据；TIFF / JPEG 解码后转为 PNG，粘贴时在预算内同时提供 TIFF。新采集最多 20 MiB、16MP；不完整保留原编码和 EXIF 等元数据。 |
| 文件 / 文件夹 | 保存有序的本地文件 URL，每条最多 100 项、引用数据最多 1 MiB；粘贴前检查全部引用。只保存位置，不备份原文件，移动、删除或卷离线后可能无法粘贴。 |

默认保留 200 条，可选 100 / 200 / 500 条，最多固定 20 条。原始内容总量目标上限为 100 MiB；固定记录不会自动清理，固定内容占满预算时会提示并拒绝新记录。序列化和元数据另占空间，100 MiB 不是目录大小的硬上限，也不计引用的原文件大小。

富文本预览显示文字摘要。HTML 在记录和预览时不渲染、不下载外部资源；仅有 HTML 时不会伪造纯文本。无效格式会跳过，有有效纯文本时回退；预检失败不会先清空当前剪贴板。不支持的混合多项复制会提示。

**原格式字节一致不等于跨应用排版一致。** Word 私有对象、OLE、公式、非图片附件、动画、多页图片与精确分页不在稳定支持范围内。暂不支持 OCR、同步或开机启动。

后台约每 600 ms 检查一次剪贴板，打开面板时立即检查；短时间连续复制可能只记录最后一项。来源应用根据检查时的前台应用推测，可能与实际来源不同。

## 数据与隐私

数据存放在 `~/Library/Application Support/ClipboardDeck/`：`history.json` 保存文字、文件引用和元数据，`images/` 保存图片，`richtext/` 保存富文本原始数据。应用不使用网络、不上传记录，记录没有额外加密。当前可读取 v1 / v2 / v3 历史；不含 RTFD 时保存为 v2，含 RTFD 时保存为 v3。更新后不要使用旧版写入同一数据目录。

应用忽略部分敏感剪贴板标记和常见密码管理应用，但无法识别所有敏感内容，处理密码等内容时请暂停记录。删除文件历史只移除引用，不删除原文件；清空历史不会清空 macOS 当前剪贴板。

## 测试与参与开发

```sh
bash scripts/build.sh --native
bash scripts/test.sh
.build/release/ClipboardDeck --self-test
```

截至 2026-11-08，**38 项核心测试、17 组隔离自检通过**。自检使用临时历史、命名剪贴板和合成数据，已验证格式保存、重载、回写及原生系统读取端；**尚未完成真实 Word / WPS / Pages 窗口中的完整复制粘贴验证**。

测试命令、覆盖范围与待验证项见 [测试说明](docs/TESTING.md)，异常输入和连续压力结果见 [压力测试记录](docs/STRESS_TESTING.md)。历史测量及其限制见 [性能记录](docs/PERFORMANCE.md)，开发流程见 [参与开发](CONTRIBUTING.md)，版本变更见 [更新记录](CHANGELOG.md)。

## 项目结构

```text
Sources/ClipboardCore/          历史模型、存储与格式数据
Sources/ClipboardNativeBridge/  RTF 原生解码异常边界
Sources/ClipboardDeck/          菜单栏应用、界面和系统适配
Tests/ClipboardCoreTests/       核心单元测试
Resources/                      应用元数据、图标与预览
scripts/                        构建、打包、测试和格式检查
docs/                           架构、测试与性能说明
Benchmarks/                     历史基准原始数据
```

应用隔离自检与性能探针的实现集中在可执行模块的 `Diagnostics/` 中，沿用现有命令行入口。调度、缓存与模块边界见 [架构说明](docs/ARCHITECTURE.md)。`.build/` 与 `dist/` 为可重新生成的本地产物，不纳入源码提交。

## 许可证

[MIT License](LICENSE)，Copyright (c) 2026 liuxing909。
