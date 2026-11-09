# 测试与验证范围

当前应用版本为 **0.1.8**。截至 2026-11-08，38 项核心测试、17 组隔离自检通过，Intel 与 Apple Silicon 两个架构编译通过。运行测试在现代 macOS 上完成，不能代替 macOS 10.15 实机验证。

本文记录实际覆盖范围，不把合成格式测试等同于 Word、WPS 或其他应用的完整窗口验证。

## 运行测试

在仓库根目录执行：

```sh
bash scripts/build.sh --native
bash scripts/test.sh
.build/release/ClipboardDeck --self-test
```

`scripts/test.sh` 使用 Swift Testing 运行核心测试；测试主机需满足所用 Swift 工具链及 Testing 框架的系统要求。应用隔离自检使用临时历史目录、命名剪贴板、隔离设置和合成素材，不读取用户现有文档、历史或系统通用剪贴板。

只运行格式专项测试：

```sh
.build/release/ClipboardDeck --self-test-formats
```

完整 `--self-test` 也包含这些检查。应用自检与性能探针位于 `Sources/ClipboardDeck/Diagnostics/`，保留在同一可执行模块中，以覆盖内部应用行为；核心测试位于 `Tests/ClipboardCoreTests/`。

在同一进程中重复隔离自检，并输出每轮物理内存、分配器统计和 AppKit 窗口数：

```sh
dist/剪贴匣.app/Contents/MacOS/ClipboardDeck --stress-test 20
dist/剪贴匣.app/Contents/MacOS/ClipboardDeck --stress-test 20 format-fuzz
```

轮数为 1–100，默认 20；首次失败立即停止。可选专项为 `all`（默认）、`formats`、`format-fuzz`、`office`、`model`、`ui`、`worker`、`thumbnails`、`hotkeys`。该命令不包含核心测试，需先单独运行 `bash scripts/test.sh`。排查单项核心测试可传入 `--filter`，例如 `bash scripts/test.sh --filter HistoryStoreStressTests`。分配器统计可能包含尚未触及的虚拟分配，不能当作实际占用的物理内存。详细结果及边界见 [压力测试记录](STRESS_TESTING.md)。

## 核心存储测试

38 项核心测试覆盖：

- 去重、固定、清理、容量保护、哈希兼容和无变化时跳过写入。
- 图片与富文本侧文件生命周期、损坏拒绝、重新复制修复及孤立文件清理。
- v1 历史迁移、未知未来版本拒绝、原始格式字节恢复和格式参与去重。
- 目录越界与符号链接保护、多文件顺序和限额；删除记录不修改原文件。
- 保存失败时保留已有记录，固定内容占满容量时拒绝新记录。
- 极端复制计数、损坏索引元数据、图片目录符号链接、损坏图片重新复制修复，以及序列化清单读写限额。
- 同内容重新复制修复图片、富文本派生元数据；排除已删除摘要时不更新历史或重新创建侧文件。
- 八个固定种子、合计 4,000 次混合操作，包含定期重载、固定保护、容量拒绝与侧文件一致性。

## 格式验证

用例经过采集、后台处理、保存、重新加载、粘贴准备及回写，并按格式使用原生 `NSTextView` 或文件 URL 读取接口消费结果。

| 格式 | 已验证内容 |
| --- | --- |
| 纯文字 | 中文、组合字符、ZWJ emoji、空白、Tab、CRLF / CR / LF；原生文本控件读取；恰好 1 MiB 接收、超限拒绝。 |
| HTML | UTF-8、带 BOM 的 UTF-16LE / BE 原始字节保持；HTML-only 不伪造文字；无效编码或 NUL 内容回退到来源提供的纯文字。 |
| RTF 字符与样式 | ANSI 字符、Unicode 回退、括号和反斜线转义；字体、字号、颜色、粗体、斜体、下划线、删除线、上下标及超链接目标。 |
| RTF 段落与列表 | 对齐、缩进、行距、段后间距；编号与项目符号列表的正文和段落列表结构。 |
| RTF / HTML 表格 | 合并表头、行列位置及跨度；`00123`、`12.50` 保持原文本；同条记录的 RTF、HTML、Tab 分隔纯文字同时保留。 |
| RTF 图片片段 | 十六进制及二进制 PNG 片段的正文提取和原始字节回写；无效二进制长度回退。未据此保证所有目标应用的图片显示。 |
| RTFD | AppKit 生成的 v0 平铺普通文件结构，PNG / TIFF / JPEG 混合附件，经 `NSTextView` 导入后正文、附件顺序和字节保持；32 个附件允许、33 个拒绝或回退纯文字。未知序列化结构不纳入支持。 |
| PNG / TIFF / JPEG | PNG 原字节、尺寸及解码像素；全透明、半透明和不透明区域；TIFF / JPEG 转换及 JPEG EXIF 方向修正；带方向信息的 PNG 转 TIFF 显示一致；旧历史大图片兼容检查。 |
| 文件与文件夹 | 单个及多选顺序、文件夹、中文 / emoji / 空格及 `# % & ?` 路径；原文件内容不变；缺失文件在清空目标剪贴板前拒绝。 |

异常用例包含截断或损坏图片、无效或超额富文本、敏感标记、忽略自身写入、不支持的混合多项复制，以及粘贴前文件消失。预检失败时验证目标剪贴板内容和 `changeCount` 不变。

每次格式自检还运行 448 个固定种子的 RTF / HTML / RTFD / PNG 变异输入，其中新增三个种子的 192 个输入不提供纯文字回退；检查采集不改源、存储重载和原字节回写。另有 18 个 RTFD 结构拒绝用例，包括曾触发巨额虚拟分配的五个样例，及长度、名称、目录元数据等边界。单独覆盖 PNG 截断容器和多页 TIFF 拒绝；诊断时可设置 `STRESS_TRACE_FORMATS=1` 输出合成用例序号、长度及异常分配输入，不输出用户内容。

损坏 RTFD 还通过真实后台调度器验证采集回退及粘贴准备拒绝，检查任务和字节预算归零、源/目标剪贴板不变。旧界面测试在退出后核对窗口、视图、模型的弱引用释放。

办公格式用例使用合成的标准 RTF / HTML 内容和原生读取端。HTML 样例可由原生控件读取，但应用的日常记录与预览不渲染 HTML、不获取外部资源。上述结果不代表实际 Word / WPS / Pages 窗口中的兼容性，也不保证跨应用精确排版。

## 状态、调度与资源验证

17 组应用隔离自检还覆盖以下行为：

| 范围 | 检查内容 |
| --- | --- |
| 应用模型 | 启动基线、立即采集、暂停与恢复、筛选、固定、选择路由；隐藏后释放缓存并按需重新加载。 |
| 删除与待处理采集 | 16 种调度顺序验证删除不丢失无关新复制、已删除内容不被旧任务恢复、压力重试沿用排除状态、未来新复制仍可保存；清空、暂停、停止释放状态。另八个边界序列覆盖队列满或压力下尚未取快照时的删除、清空、选择等待，以及清空保存失败后保留采集。 |
| 粘贴生命周期 | 新复制、应用切换、面板关闭或新粘贴使旧操作失效；准备完成后再次检查目标与剪贴板版本。 |
| 等待最新复制时的选择 | 压力恢复或队列满尚未采集时回车不会误粘贴旧记录；用户明确选择旧记录仍可操作；新内容到达后选择更新，排除或失败后结束等待。 |
| 模拟快捷键 | 冲突保留旧键及设置、成功替换、启动失败提示、同一组合键重试、事件监听初始化失败后恢复。 |
| 轮询 | 幂等启停、停止后无回调、重启、释放；注入轮询器触发实际采集。 |
| 缓存与缩略图 | 成本及数量预算、LRU 淘汰、替换、超大项和引用释放；图片比例、旋转、不放大小图、列表与预览用途隔离。 |
| 后台任务 | 非主线程解码、单并发、等待上限、同 key 去重、取消后的迟到结果、结果顺序、压力暂停与恢复、失败抑制。 |
| 展示生命周期 | 缓存容量小于展示数量时不持续重复解码；压力变化释放展示引用；重新复制损坏图片后恢复失败缩略图及可见旧像素，隐藏项不触发解码。 |
| 旧系统界面 | AppKit 搜索、筛选、固定、删除、选择路由，以及隐藏和重新打开；在现代系统上运行这些控件。 |

## 原生快捷键检查

此项独立于默认隔离自检：

```sh
.build/release/ClipboardDeck --self-test-hotkey-system
```

测试短暂注册 **Control + Option + Shift + Command + F20**，验证同进程重复独占注册被拒绝、释放后可重试，结束时注销测试组合键及监听器。不发送按键，不修改系统快捷键设置；测试组合键已被占用时会报告失败。

原生注册检查已通过，但仍需单独验证真实跨应用快捷键触发、焦点恢复和粘贴。

## 界面与安装包检查

以下命令使用合成数据生成界面图，可用于人工检查：

```sh
.build/release/ClipboardDeck --render-preview .build/preview.png
.build/release/ClipboardDeck --render-legacy-preview .build/legacy-preview.png
.build/release/ClipboardDeck --render-hotkey-warning .build/hotkey-warning.png
```

交互式演示使用临时示例数据，不监控或修改系统通用剪贴板，退出后删除演示数据：

```sh
open dist/剪贴匣.app --args --demo
open dist/剪贴匣.app --args --demo-legacy
```

已有界面预览、旧界面及模拟冲突提醒的渲染检查。安装包验证涵盖应用元数据、两个架构及最低系统版本、内嵌兼容运行库、本地签名和 DMG 挂载读取。当前为 ad-hoc 签名，未完成 Developer ID 签名与公证。

## 尚待实机验证

- Intel macOS 10.15 上的启动、界面、权限、快捷键、格式和安装更新流程。
- Word、WPS、Pages、浏览器与 Finder 的真实窗口复制粘贴组合。
- 辅助功能授权前后、跨应用焦点恢复及全局快捷键实际触发。
- 复杂分页、公式、OLE 私有对象与跨应用精确排版；这些尚未纳入稳定支持范围。

报告问题时请注明 macOS 和应用版本、复制来源、粘贴目标及复现步骤，优先提供不含隐私的最小样例。格式原字节一致和系统读取端通过不能替代目标应用的实际显示检查。

原生接口参考：[NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)、[NSTextView 格式读取](https://developer.apple.com/documentation/appkit/nstextview/readselection(from:type:))、[仅文件 URL 的读取选项](https://developer.apple.com/documentation/appkit/nspasteboard/readingoptionkey/urlreadingfileurlsonly)。
