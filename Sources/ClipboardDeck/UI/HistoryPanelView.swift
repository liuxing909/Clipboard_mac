import SwiftUI
import AppKit
import ClipboardCore

@available(macOS 14.0, *)
struct HistoryPanelView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var confirmClear = false
    @State private var previewEntry: ClipEntry?
    private let accent = Color(red: 0.12, green: 0.49, blue: 0.44)

    var body: some View {
        Group {
            if model.isPanelVisible {
                VStack(spacing: 0) {
                    header
                    searchBox
                    filters
                    Divider().padding(.top, 12)
                    if let error = model.persistentError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).padding(14)
                    }
                    if let warning = model.hotkeyWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(warning.title + "：" + warning.message)
                                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("调整") { model.showingSettings = true }.font(.caption)
                        }.padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.orange.opacity(0.08))
                    }
                    history
                    if model.isPreparingCopy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在准备粘贴…").font(.system(size: 12))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    if let toast = model.toast {
                        Text(toast)
                            .font(.system(size: 12)).foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(accent.opacity(0.10))
                    }
                    if !model.accessibilityGranted && !model.isPreview { permissionHint }
                    Divider()
                    footer
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 416, height: 608)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.10)))
        .tint(accent)
        .onAppear { searchFocused = true }
        .onChange(of: model.presentationID) { _, _ in searchFocused = true }
        .onChange(of: model.isPanelVisible) { _, visible in
            if !visible { confirmClear = false; previewEntry = nil }
        }
        .alert("清理剪贴板历史？", isPresented: $confirmClear) {
            Button("清理未固定记录", role: .destructive) { model.clear(keepingPinned: true) }
            Button("清空全部记录", role: .destructive) { model.clear(keepingPinned: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理会删除保存的剪贴板记录，无法撤销。文件记录指向的原文件不会被删除。")
        }
        .sheet(item: $previewEntry) { entry in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(entry.kind == .image ? "图片预览" : "完整内容", systemImage: entry.kind.symbol)
                        .font(.headline)
                    Spacer()
                    Button("关闭") { previewEntry = nil }.keyboardShortcut(.cancelAction)
                }
                if entry.kind == .image {
                    HistoryThumbnailView(entry: entry, model: model, variant: .preview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(
                            entry.kind == .files
                                ? (entry.fileURLs ?? []).compactMap { URL(string: $0)?.path }.joined(separator: "\n")
                                : entry.title
                        )
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if entry.kind == .richText {
                        Text("此处显示文字内容，粘贴时保留已保存的格式。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if entry.kind == .files {
                        Text("只保存文件位置。原文件移动或删除后，该记录将无法粘贴。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.sourceApp).font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 500, height: 400)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("剪贴匣").font(.system(size: 20, weight: .semibold))
                Text("随手复制，随时找回").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.isPaused.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(model.isPaused ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(model.isPaused ? "已暂停" : "记录中").font(.system(size: 11, weight: .medium))
                }.padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.primary.opacity(0.045), in: Capsule())
            }.buttonStyle(.plain)
                .help(model.isPaused ? "继续记录剪贴板" : "暂停记录剪贴板")
            Button {
                model.showingSettings.toggle()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 25, height: 30)
            }.buttonStyle(.plain).help("设置")
                .popover(isPresented: $model.showingSettings, arrowEdge: .bottom) { settings }
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 17)
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索内容或来源应用…", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain).help("清空搜索")
            }
        }.padding(.horizontal, 12).frame(height: 38)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
            .padding(.horizontal, 20)
    }

    private var filters: some View {
        HStack(spacing: 5) {
            ForEach(ClipFilter.allCases) { filter in
                Button {
                    model.filter = filter
                } label: {
                    HStack(spacing: 4) {
                        if filter == .pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                        Text(filter.rawValue).font(
                            .system(size: 12, weight: model.filter == filter ? .semibold : .regular))
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(model.filter == filter ? accent : .secondary)
                        .background(model.filter == filter ? accent.opacity(0.11) : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
            Spacer()
            Text("\(model.visibleEntries.count)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }.padding(.horizontal, 20).padding(.top, 12)
    }

    private var history: some View {
        Group {
            if model.visibleEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.entries.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.6))
                    Text(model.entries.isEmpty ? "从下一次复制开始" : "没有找到匹配的记录")
                        .font(.system(size: 15, weight: .medium))
                    Text(model.entries.isEmpty ? "复制文字、图片或 Finder 文件。\n它们会出现在这里。" : "试试其他关键词，或切换内容分类。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(model.visibleEntries) { entry in
                                ClipCard(
                                    entry: entry, model: model, accent: accent, onPreview: { previewEntry = entry }
                                )
                                .id(entry.id)
                            }
                        }.padding(14)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            Text("开启辅助功能，即可选中后直接粘贴")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("设置") { model.openAccessibilitySettings() }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Text(model.isHotkeyAvailable ? model.shortcutLabel : "快捷键未启用").font(
                .system(size: 11, weight: .medium, design: .monospaced)
            )
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            if model.isHotkeyAvailable { Text("呼出").foregroundStyle(.secondary) }
            Spacer()
            Text("↑↓ 选择  ↵ 粘贴  ⌘↵ 复制").foregroundStyle(.secondary)
            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash").frame(width: 24, height: 25).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("清理历史记录")
        }.font(.system(size: 10)).padding(.horizontal, 18).frame(height: 43)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Text(
                    "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.8")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker("呼出快捷键", selection: Binding(get: { model.hotkeyPreset }, set: { model.setHotkey($0) })) {
                Text("⌃⌥V（Control + Option + V）").tag(0)
                Text("⌥V（Option + V）").tag(1)
                Text("⌃⇧V（Control + Shift + V）").tag(2)
            }
            if let warning = model.hotkeyWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(warning.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("重试 " + HotkeyPresets.label(warning.preset)) { model.setHotkey(warning.preset) }
                        .font(.caption)
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Picker("保留记录", selection: Binding(get: { model.historyLimit }, set: { model.setLimit($0) })) {
                Text("100 条").tag(100); Text("200 条").tag(200); Text("500 条").tag(500)
            }
            Toggle("暂停记录", isOn: $model.isPaused)
            Divider()
            Label("记录只保存在这台 Mac", systemImage: "internaldrive")
                .font(.system(size: 12, weight: .medium))
            Text("支持文字、HTML/RTF/RTFD 富文本、图片和 Finder 文件；搜索内容、文件名与来源应用。最多固定 20 条，原始内容预算 100 MiB。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("文件记录只保存位置，不备份原文件；富文本效果取决于粘贴目标支持的格式。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("已标记为敏感或临时的剪贴板内容会被忽略。无法识别所有密码，请在处理敏感内容时暂停记录。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.accessibilityGranted {
                Button("打开辅助功能设置…") { model.openAccessibilitySettings() }
            }
            Divider()
            HStack {
                Text("剪贴匣 · ClipboardDeck").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { model.onQuit?() }
            }
        }.padding(20).frame(width: 330)
    }
}

@available(macOS 14.0, *)
private struct ClipCard: View {
    let entry: ClipEntry
    @ObservedObject var model: AppModel
    let accent: Color
    let onPreview: () -> Void
    var selected: Bool { model.selectedID == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: entry.kind.symbol)
                    .font(.system(size: 10))
                Text(entry.sourceApp).lineLimit(1)
                Spacer()
                Text(entry.copiedAt, style: .relative).lineLimit(1)
                Button {
                    model.togglePin(entry)
                } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(entry.isPinned ? accent : .secondary)
                        .frame(width: 23, height: 20)
                }.buttonStyle(.plain).help(entry.isPinned ? "取消固定" : "固定这条记录")
            }.font(.system(size: 10)).foregroundStyle(.secondary)

            if entry.kind == .image {
                HistoryThumbnailView(entry: entry, model: model)
                    .frame(maxWidth: .infinity).frame(height: 122)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                HStack {
                    Text("\(entry.imageWidth ?? 0) × \(entry.imageHeight ?? 0)")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            } else {
                Text(entry.title.prefix(600))
                    .font(.system(size: 13)).lineSpacing(3).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
                if entry.kind == .richText {
                    Label(
                        "保留格式 · "
                            + (entry.richTextTypes ?? []).map {
                                switch $0 {
                                case HistoryStore.rtfdType: return "RTFD"
                                case "public.rtf": return "RTF"
                                case "public.html": return "HTML"
                                default: return "其他"
                                }
                            }.joined(separator: " / "), systemImage: "textformat"
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if entry.kind == .files {
                    Text("\(entry.fileURLs?.count ?? 0) 个文件或文件夹 · 保存位置")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(12)
            .background(
                selected ? accent.opacity(0.065) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11).strokeBorder(
                    selected ? accent.opacity(0.55) : .primary.opacity(0.065), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .onTapGesture {
                model.selectedID = entry.id; model.onPaste?(entry)
            }
            .contextMenu {
                Button("粘贴") { model.onPaste?(entry) }
                Button("仅复制") { model.copyOnly(entry) }
                Button(entry.kind == .image ? "预览图片" : "查看完整内容", action: onPreview)
                Divider()
                Button(entry.isPinned ? "取消固定" : "固定") { model.togglePin(entry) }
                Button("删除", role: .destructive) { model.remove(entry) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(entry.title.prefix(100)))
            .accessibilityHint("点击粘贴，右键查看更多操作")
    }
}

private extension ClipKind {
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }
}
