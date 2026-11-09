# 参与开发

项目使用 Swift、SwiftUI 和 AppKit，没有第三方运行时依赖。先阅读 [README](README.md) 和 [架构说明](docs/ARCHITECTURE.md)。

## 本地检查

```sh
bash scripts/build.sh
bash scripts/test.sh
dist/剪贴匣.app/Contents/MacOS/ClipboardDeck --self-test
```

默认构建 Intel + Apple Silicon 通用应用；快速开发可使用 `bash scripts/build.sh --native`。运行测试需满足本机 Swift 工具链和 Testing 框架的系统要求，详见 [测试说明](docs/TESTING.md)。

## 代码格式

使用工具链附带的 Apple `swift-format`，当前格式基线为 6.3.0，配置位于 `.swift-format`。

```sh
bash scripts/format.sh
bash scripts/format.sh --check
```

保持改动聚焦；格式或调度行为变化应增加覆盖实际行为的测试。AppKit 自检使用临时历史、隔离设置和命名剪贴板，不读取开发者的真实剪贴板。新增格式需明确大小上限、回退方式及目标应用验证范围。

## 提交与反馈

不要提交 `.build/`、`dist/`、日志、签名凭据或个人剪贴板记录。安装包适合通过 GitHub Releases 单独分发，源码仓库只保存可复现构建所需的文件。

PR 请说明问题、行为变化和验证结果；不能在旧系统或目标应用实测时，应如实注明。问题反馈请使用虚构内容复现，避免公开个人剪贴板数据。
