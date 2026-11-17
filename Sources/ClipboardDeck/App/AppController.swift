import AppKit
import SwiftUI
import ApplicationServices
import ClipboardCore

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var panel: ClipboardPanel!
    private var statusItem: NSStatusItem!
    private var hotkey: GlobalHotkey!
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var panelPlacement = PanelPlacement()
    private var isPositioningPanel = false
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private struct PasteRequest: Equatable {
        let id = UUID()
        let targetPID: pid_t
        let changeCount: Int
    }
    private var pendingPaste: PasteRequest?
    private let demoMode = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-legacy")
    private var demoRoot: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        let root: URL
        if demoMode {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipboardDeck-demo-" + UUID().uuidString)
            demoRoot = root
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClipboardDeck", isDirectory: true)
        }
        model = AppModel(directory: root, isPreview: demoMode)
        if demoMode {
            do { try PreviewSupport.populate(model) } catch {
                model.showToast("示例数据载入失败：\(error.localizedDescription)")
            }
        }
        model.onPaste = { [weak self] entry in self?.paste(entry) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onShortcutChange = { [weak self] shortcut in
            self?.hotkey?.register(shortcut: shortcut) ?? .failure(.handlerUnavailable)
        }
        installMainMenu()
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        if lastExternalApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = nil
        }

        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 608),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "剪贴匣"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = PanelContent.makeView(model: model, legacy: CommandLine.arguments.contains("--demo-legacy"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "剪贴匣")
            } else {
                button.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                    NSColor.labelColor.setStroke()
                    let outline = NSBezierPath(
                        roundedRect: NSRect(x: 3, y: 1, width: 12, height: 15), xRadius: 2, yRadius: 2)
                    outline.lineWidth = 1.5; outline.stroke()
                    NSBezierPath(roundedRect: NSRect(x: 6, y: 13, width: 6, height: 4), xRadius: 1, yRadius: 1).stroke()
                    return true
                }
            }
            button.image?.isTemplate = true
            button.toolTip = "剪贴匣 — 剪贴板历史"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        hotkey = GlobalHotkey()
        hotkey.onPress = { [weak self] in
            guard let self, !self.model.handleHotkeyWhileRecording() else { return }
            self.togglePanel()
        }
        model.activateHotkey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow,
                self.panel.attachedSheet == nil, !self.model.showingSettings
            else { return event }
            // Let Chinese/Japanese/Korean input methods commit or select candidates first.
            if let input = self.panel.firstResponder as? NSTextInputClient, input.hasMarkedText() {
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 53 where modifiers.isEmpty: self.dismiss(); return nil
            case 125 where modifiers.isEmpty: self.model.moveSelection(1); return nil
            case 126 where modifiers.isEmpty: self.model.moveSelection(-1); return nil
            case 36, 76:
                guard modifiers.isEmpty || modifiers == .command else { return event }
                if modifiers == .command, let entry = self.model.selectedEntry {
                    self.model.copyOnly(entry)
                } else {
                    self.model.pasteSelected()
                }
                return nil
            default: return event
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.pendingPaste = nil
            guard self.panel.isVisible, !self.model.showingSettings,
                self.panel.attachedSheet == nil
            else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.hidePanel() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.cancelPreparedCopy()
                self.lastExternalApplication = app
                // A user switching applications must not leave a panel pointing at the old target.
                self.hidePanel(cancelPendingPaste: false)
                if self.pendingPaste?.targetPID != app.processIdentifier { self.pendingPaste = nil }
            }
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainVisiblePanelToScreens() }
        }

        model.startMonitoring()
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { showPanel() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingPaste = nil
        model?.stopMonitoring()
        model?.cancelPreparedCopy()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
        if let demoRoot { try? FileManager.default.removeItem(at: demoRoot) }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开剪贴匣", action: #selector(openFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: model.isPaused ? "继续记录" : "暂停记录", action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出剪贴匣", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func openFromMenu() { showPanel() }
    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func installMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出剪贴匣", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func togglePanel() { panel.isVisible ? dismiss() : showPanel() }

    private func showPanel() {
        pendingPaste = nil
        model.cancelPreparedCopy()
        // Capture before activation so both the newest content and its source are available.
        model.capturePendingCopy()
        let front = NSWorkspace.shared.frontmostApplication
        targetApplication =
            front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApplication : front
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = panelPlacement.frameForPresentation(
            size: panel.frame.size, visibleScreens: NSScreen.screens.map(\.visibleFrame),
            initialScreen: screen?.visibleFrame)
        {
            positionPanel(at: frame)
        }
        model.refreshAccessibility()
        model.prepareForPresentation()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel,
            !isPositioningPanel, panel.isVisible
        else { return }
        panelPlacement.rememberMove(to: panel.frame)
    }

    private func positionPanel(at frame: NSRect) {
        isPositioningPanel = true
        defer { isPositioningPanel = false }
        panel.setFrameOrigin(frame.origin)
    }

    private func constrainVisiblePanelToScreens() {
        guard let panel, panel.isVisible else { return }
        let constrained = PanelPlacement.constrained(panel.frame, to: NSScreen.screens.map(\.visibleFrame))
        guard constrained.origin != panel.frame.origin else { return }
        positionPanel(at: constrained)
        panelPlacement.rememberMove(to: constrained)
    }

    private func dismiss() {
        hidePanel()
        targetApplication?.activate(options: [])
    }

    private func hidePanel(cancelPendingPaste: Bool = true) {
        if cancelPendingPaste {
            pendingPaste = nil
            model.cancelPreparedCopy()
        }
        model.isRecordingShortcut = false
        panel.orderOut(nil)
        model.setPanelVisible(false)
    }

    private func paste(_ entry: ClipEntry) {
        pendingPaste = nil
        if demoMode {
            model.showToast("演示模式：已选中记录，不会修改系统剪贴板。")
            return
        }
        let target = targetApplication
        model.copyPrepared(entry) { [weak self] success in
            guard let self, success else { return }
            self.finishPaste(target: target)
        }
    }

    private func finishPaste(target: NSRunningApplication?) {
        model.refreshAccessibility()
        guard model.accessibilityGranted else {
            model.showToast("已复制。返回原应用按 ⌘V；开启辅助功能后可自动粘贴。")
            return
        }
        guard let target, !target.isTerminated,
            target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            model.showToast("已复制。请切换到目标输入框，按 ⌘V。")
            return
        }
        let request = PasteRequest(targetPID: target.processIdentifier, changeCount: NSPasteboard.general.changeCount)
        pendingPaste = request
        hidePanel(cancelPendingPaste: false)
        guard target.activate(options: []) else {
            showPanel()
            model.showToast("已复制，但原应用无法激活。请手动按 ⌘V。")
            return
        }
        sendPasteWhenFocused(target: target, request: request, attempts: 0)
    }

    private func sendPasteWhenFocused(target: NSRunningApplication, request: PasteRequest, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.pendingPaste == request else { return }
            guard !target.isTerminated, NSPasteboard.general.changeCount == request.changeCount else {
                self.pendingPaste = nil
                return
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                if attempts < 7 {
                    self.sendPasteWhenFocused(target: target, request: request, attempts: attempts + 1)
                } else {
                    self.showPanel()
                    self.model.showToast("已复制，但焦点未回到原应用。请手动按 ⌘V。")
                }
                return
            }
            self.pendingPaste = nil
            guard AXIsProcessTrusted(),
                let source = CGEventSource(stateID: .combinedSessionState),
                let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

/// Session-only positioning: first open follows the pointer; a moved panel keeps its position.
struct PanelPlacement {
    private(set) var rememberedFrame: NSRect?

    mutating func rememberMove(to frame: NSRect) { rememberedFrame = frame }

    func frameForPresentation(size: NSSize, visibleScreens: [NSRect], initialScreen: NSRect?) -> NSRect? {
        if let rememberedFrame {
            return Self.constrained(NSRect(origin: rememberedFrame.origin, size: size), to: visibleScreens)
        }
        guard let screen = initialScreen ?? visibleScreens.first else { return nil }
        let proposed = NSRect(
            x: screen.midX - size.width / 2, y: max(screen.minY + 12, screen.midY - 250),
            width: size.width, height: size.height)
        return Self.constrained(proposed, to: [screen])
    }

    static func constrained(_ frame: NSRect, to visibleScreens: [NSRect]) -> NSRect {
        let screens = visibleScreens.filter { $0.width > 0 && $0.height > 0 }
        guard
            let screen = screens.max(by: { lhs, rhs in
                let leftArea = intersectionArea(frame, lhs), rightArea = intersectionArea(frame, rhs)
                if leftArea != rightArea { return leftArea < rightArea }
                return distanceSquared(from: frame, to: lhs) > distanceSquared(from: frame, to: rhs)
            })
        else { return frame }
        let insetX: CGFloat = screen.width > 24 ? 12 : 0
        let insetY: CGFloat = screen.height > 24 ? 12 : 0
        let usable = screen.insetBy(dx: insetX, dy: insetY)
        // On very small displays retain the title at the top so the panel remains draggable.
        let x = frame.width > usable.width ? usable.minX : min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        let y =
            frame.height > usable.height
            ? usable.maxY - frame.height : min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func distanceSquared(from frame: NSRect, to screen: NSRect) -> CGFloat {
        let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
        let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
        return dx * dx + dy * dy
    }
}
