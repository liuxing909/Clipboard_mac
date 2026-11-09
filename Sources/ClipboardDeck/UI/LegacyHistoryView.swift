import AppKit
import Combine
import SwiftUI
import ClipboardCore

@MainActor
enum PanelContent {
    static func makeView(model: AppModel, legacy: Bool = false) -> NSView {
        if #available(macOS 14.0, *), !legacy {
            return NSHostingView(rootView: HistoryPanelView(model: model))
        }
        return LegacyHistoryView(model: model)
    }
}

/// Catalina-compatible presentation. Storage, hotkeys, formats and resource
/// budgets are shared with the modern UI; table rows are created only on demand.
@MainActor
final class LegacyHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSPopoverDelegate, NSMenuDelegate
{
    private let model: AppModel
    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let pause = NSButton(title: "暂停", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    private let settingsPopover = NSPopover()
    private var subscription: AnyCancellable?
    private var settingsWarning: NSTextField?
    private var hotkeyPicker: NSPopUpButton?
    private var rows: [ClipEntry] = []
    private var updating = false
    private var presentationID: UUID?

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 416, height: 608))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        let title = NSTextField(labelWithString: "剪贴匣")
        title.font = .boldSystemFont(ofSize: 22)
        let header = NSStackView(views: [title, NSView(), pause, settingsButton])
        header.orientation = .horizontal; header.spacing = 8
        pause.target = self; pause.action = #selector(togglePause)
        settingsButton.target = self; settingsButton.action = #selector(openSettings)
        stack.addArrangedSubview(header)
        search.placeholderString = "搜索内容或来源应用…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        stack.addArrangedSubview(search)
        filter.addItems(withTitles: ClipFilter.allCases.map(\.rawValue))
        filter.target = self; filter.action = #selector(changeFilter)
        stack.addArrangedSubview(filter)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemOrange
        message.maximumNumberOfLines = 6
        stack.addArrangedSubview(message)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil; table.rowHeight = 106; table.intercellSpacing = NSSize(width: 0, height: 5)
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(selectRow); table.doubleAction = #selector(pasteRow)
        table.allowsEmptySelection = true
        let context = NSMenu()
        context.delegate = self
        for (title, action) in [
            ("粘贴", #selector(pasteRow)), ("仅复制", #selector(copyRow)),
            ("预览", #selector(previewRow)), ("固定 / 取消固定", #selector(pinRow)),
            ("删除", #selector(deleteRow)),
        ] {
            context.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        table.menu = context
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        let actions = NSStackView(views: [
            button("粘贴", #selector(pasteRow)), button("仅复制", #selector(copyRow)),
            button("固定", #selector(pinRow)), button("清理", #selector(clearHistory)),
        ])
        actions.orientation = .horizontal; actions.distribution = .fillEqually; actions.spacing = 8
        stack.addArrangedSubview(actions)
        footer.font = .systemFont(ofSize: 10); footer.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        settingsPopover.behavior = .transient; settingsPopover.delegate = self
        // objectWillChange arrives before @Published changes; deliver next turn.
        subscription = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func refresh() {
        updating = true
        defer { updating = false }
        let next = model.isPanelVisible ? model.visibleEntries : []
        if rows != next { rows = next; table.reloadData() }
        if let id = model.selectedID, let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if table.visibleRect.height >= table.rowHeight { table.scrollRowToVisible(index) }
        } else {
            table.deselectAll(nil)
        }
        for index in rows.indices {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? LegacyHistoryCell)?.refreshImage()
        }
        let warning = model.hotkeyWarning.map { $0.title + "：" + $0.message }
        message.stringValue = [
            model.persistentError, warning, model.isPreparingCopy ? "正在准备粘贴…" : nil,
            model.toast, rows.isEmpty ? "暂无记录。复制内容后会显示在这里。" : nil,
        ].compactMap { $0 }.joined(separator: "\n")
        message.isHidden = message.stringValue.isEmpty
        pause.title = model.isPaused ? "继续记录" : "暂停"
        footer.stringValue =
            "\(model.isHotkeyAvailable ? model.shortcutLabel : "快捷键未启用")  ·  ↑↓ 选择  ↵ 粘贴  ⌘↵ 复制  ·  \(rows.count) 条"
        filter.selectItem(at: ClipFilter.allCases.firstIndex(of: model.filter) ?? 0)
        if search.stringValue != model.query { search.stringValue = model.query }
        settingsWarning?.stringValue = warning ?? "快捷键正常"
        hotkeyPicker?.selectItem(at: model.hotkeyPreset)
        if !model.showingSettings { settingsPopover.close() }
        if presentationID != model.presentationID {
            presentationID = model.presentationID
            if model.isPanelVisible { window?.makeFirstResponder(search) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(search) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let previous = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        NSAppearance.current = previous
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        return LegacyHistoryCell(entry: rows[row], model: model)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow) else { return }
        model.selectedID = rows[table.selectedRow].id
    }
    func controlTextDidChange(_ obj: Notification) { model.query = search.stringValue }
    @objc private func changeFilter() { model.filter = ClipFilter.allCases[filter.indexOfSelectedItem] }
    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func selectRow() {
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }
    private var actionEntry: ClipEntry? { model.selectedEntry }
    func menuWillOpen(_ menu: NSMenu) {
        guard rows.indices.contains(table.clickedRow) else { return }
        model.selectedID = rows[table.clickedRow].id
    }
    @objc private func pasteRow() { if let entry = actionEntry { model.onPaste?(entry) } }
    @objc private func copyRow() { if let entry = actionEntry { model.copyOnly(entry) } }
    @objc private func pinRow() { if let entry = actionEntry { model.togglePin(entry) } }
    @objc private func deleteRow() { if let entry = actionEntry { model.remove(entry) } }

    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清理剪贴板历史？"
        alert.informativeText = "记录删除后无法恢复。文件记录指向的原文件不会被删除。"
        ["清理未固定记录", "清空全部记录", "取消"].forEach { alert.addButton(withTitle: $0) }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.model.clear(keepingPinned: true)
            } else if response == .alertSecondButtonReturn {
                self?.model.clear(keepingPinned: false)
            }
        }
    }

    @objc private func previewRow() {
        guard let entry = actionEntry, let window else { return }
        let alert = NSAlert()
        alert.messageText = entry.kind == .image ? "图片预览" : "完整内容"
        alert.addButton(withTitle: "关闭")
        var presentation: ThumbnailPresentation?
        var observer: AnyCancellable?
        if entry.kind == .image {
            let image = NSImageView(frame: NSRect(x: 0, y: 0, width: 330, height: 300))
            image.imageScaling = .scaleProportionallyUpOrDown
            let item = model.thumbnailPresentation(for: entry, variant: .preview)
            presentation = item
            observer = item.objectWillChange.receive(on: RunLoop.main).sink { [weak item, weak image] _ in
                image?.image = item?.image
            }
            item.appear(); image.image = item.image
            // Thumbnail completion is published through the model.
            let updates = model.$thumbnailRevision.receive(on: RunLoop.main).sink { [weak item] _ in item?.refresh() }
            observer = AnyCancellable { [observer] in
                observer?.cancel(); updates.cancel()
            }
            alert.accessoryView = image
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 330, height: 250))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isRichText = false
            text.string =
                entry.kind == .files
                ? (entry.fileURLs ?? []).compactMap { URL(string: $0)?.path }.joined(separator: "\n") : entry.title
            text.autoresizingMask = [.width]; scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.beginSheetModal(for: window) { _ in
            presentation?.disappear(); observer?.cancel()
        }
    }

    @objc private func openSettings() {
        let controller = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let title = NSTextField(labelWithString: "设置 · 剪贴匣")
        title.font = .boldSystemFont(ofSize: 16); stack.addArrangedSubview(title)
        let keys = NSPopUpButton()
        keys.addItems(withTitles: HotkeyPresets.labels); keys.selectItem(at: model.hotkeyPreset)
        keys.target = self; keys.action = #selector(changeHotkey)
        stack.addArrangedSubview(NSTextField(labelWithString: "呼出快捷键")); stack.addArrangedSubview(keys)
        hotkeyPicker = keys
        let warning = NSTextField(wrappingLabelWithString: model.hotkeyWarning?.message ?? "快捷键正常")
        warning.font = .systemFont(ofSize: 11); warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 290; stack.addArrangedSubview(warning); settingsWarning = warning
        stack.addArrangedSubview(button("重试快捷键", #selector(retryHotkey)))
        let limit = NSPopUpButton()
        limit.addItems(withTitles: ["100 条", "200 条", "500 条"])
        limit.selectItem(at: [100, 200, 500].firstIndex(of: model.historyLimit) ?? 1)
        limit.target = self; limit.action = #selector(changeLimit(_:))
        stack.addArrangedSubview(NSTextField(labelWithString: "保留记录")); stack.addArrangedSubview(limit)
        stack.addArrangedSubview(button(model.isPaused ? "继续记录" : "暂停记录", #selector(togglePause)))
        stack.addArrangedSubview(button("开启辅助功能以自动粘贴…", #selector(accessibility)))
        let detail = NSTextField(wrappingLabelWithString: "记录只保存在本机。支持文字、HTML/RTF/RTFD、图片和文件引用。文件记录不备份原文件，最多固定20条。")
        detail.font = .systemFont(ofSize: 11); detail.preferredMaxLayoutWidth = 290
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(button("退出剪贴匣", #selector(quit)))
        stack.setFrameSize(NSSize(width: 330, height: 470))
        controller.view = stack
        settingsPopover.contentViewController = controller
        model.showingSettings = true
        settingsPopover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .minY)
    }
    @objc private func changeHotkey() { if let keys = hotkeyPicker { model.setHotkey(keys.indexOfSelectedItem) } }
    @objc private func retryHotkey() { model.setHotkey(model.hotkeyWarning?.preset ?? model.hotkeyPreset) }
    @objc private func changeLimit(_ sender: NSPopUpButton) {
        model.setLimit([100, 200, 500][sender.indexOfSelectedItem])
    }
    @objc private func accessibility() { model.openAccessibilitySettings() }
    @objc private func quit() { model.onQuit?() }
    func popoverDidClose(_ notification: Notification) { model.showingSettings = false }

    static func selfTest() throws {
        weak var releasedWindow: NSWindow?
        weak var releasedView: LegacyHistoryView?
        weak var releasedModel: AppModel?
        try autoreleasepool {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipboardDeck-legacy-ui-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(directory: root, isPreview: true)
            releasedModel = model
            try PreviewSupport.populate(model)
            let view = LegacyHistoryView(model: model)
            releasedView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            releasedWindow = window
            window.contentView = view
            defer { window.orderOut(nil) }
            func check(_ condition: Bool, _ label: String) throws {
                if !condition { throw PreviewSupport.TestError.failed("legacy UI: " + label) }
            }
            try check(view.rows.count == 5, "initial history")
            view.search.stringValue = "git status"
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            try check(SelfTestWait.until { view.rows.count == 1 }, "native search updates rows")
            view.search.stringValue = ""
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            view.filter.selectItem(at: ClipFilter.allCases.firstIndex(of: .files)!)
            view.changeFilter()
            try check(SelfTestWait.until { view.rows.count == 1 && view.rows.first?.kind == .files }, "file filter")
            var pasted: UUID?
            model.onPaste = { pasted = $0.id }
            view.pasteRow()
            try check(pasted == view.rows.first?.id, "paste action routes the selected entry")
            let pin = model.selectedEntry!.isPinned
            view.pinRow()
            try check(SelfTestWait.until { view.rows.first?.isPinned != pin }, "pin update")
            view.deleteRow()
            try check(SelfTestWait.until { view.rows.isEmpty }, "delete update")
            model.filter = .all
            try check(SelfTestWait.until { view.rows.count == 4 }, "filter reset")
            model.setPanelVisible(false)
            try check(SelfTestWait.until { view.rows.isEmpty }, "hidden panel releases rows")
            model.prepareForPresentation()
            try check(SelfTestWait.until { view.rows.count == 4 }, "reopen restores rows")
        }
        // Check ordinary orderOut cleanup after the fixture scope and autorelease
        // pool end; delayed AppKit callbacks must release their owners as well.
        guard
            SelfTestWait.until({
                releasedWindow == nil && releasedView == nil && releasedModel == nil
            })
        else {
            throw PreviewSupport.TestError.failed(
                "legacy UI: fixture release (window=\(releasedWindow == nil), view=\(releasedView == nil), model=\(releasedModel == nil))"
            )
        }
        print(
            "PASS: Catalina AppKit UI / native search / filters / selected paste routing / pin / delete / hidden-row release / reopen / window-view-model release"
        )
    }
}

@MainActor
private final class LegacyHistoryCell: NSTableCellView {
    private let picture = NSImageView()
    private var presentation: ThumbnailPresentation?
    init(entry: ClipEntry, model: AppModel) {
        super.init(frame: NSRect(x: 0, y: 0, width: 370, height: 106))
        let hasImage = entry.kind == .image
        let title = NSTextField(wrappingLabelWithString: String(entry.title.prefix(300)))
        title.font = .systemFont(ofSize: 13); title.maximumNumberOfLines = 3
        title.frame = NSRect(x: hasImage ? 108 : 8, y: 32, width: hasImage ? 250 : 350, height: 65)
        title.autoresizingMask = [.width]; addSubview(title)
        let details = NSTextField(
            labelWithString:
                "\(entry.isPinned ? "📌 " : "")\(entry.sourceApp) · \(entry.kind == .richText ? "保留格式" : entry.kind == .image ? "图片" : entry.kind == .files ? "文件" : "文字")"
        )
        details.font = .systemFont(ofSize: 10); details.textColor = .secondaryLabelColor
        details.frame = NSRect(x: 8, y: 6, width: 350, height: 18)
        details.autoresizingMask = [.width]; addSubview(details)
        if hasImage {
            picture.frame = NSRect(x: 8, y: 28, width: 92, height: 72)
            picture.imageScaling = .scaleProportionallyUpOrDown; addSubview(picture)
            presentation = model.thumbnailPresentation(for: entry)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            presentation?.disappear(); picture.image = nil
        } else {
            presentation?.appear(); refreshImage()
        }
    }
    func refreshImage() { presentation?.refresh(); picture.image = presentation?.image }
}
