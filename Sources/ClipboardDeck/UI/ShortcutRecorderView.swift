import AppKit
import Carbon
import SwiftUI

/// Shared by the SwiftUI settings and the macOS 10.15 AppKit settings popover.
/// The local event monitor exists only while this button owns keyboard focus.
@MainActor
final class ShortcutRecorderControl: NSButton {
    var shortcut = HotkeyPresets.shortcuts[0] {
        didSet { if !isRecording { updateTitle() } }
    }
    var onShortcutChange: ((HotkeyShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var eventMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    private var pendingShortcut: HotkeyShortcut?
    private weak var boundModel: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        toolTip = "点击后按组合键；Esc 取消，Tab 退出。至少包含 ⌘、⌃ 或 ⌥。"
        setAccessibilityLabel("自定义呼出快捷键")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    func bind(to model: AppModel) {
        boundModel = model
        shortcut = model.shortcut
        onShortcutChange = { [weak model] shortcut in model?.setCustomHotkey(shortcut) }
        onRecordingChange = { [weak model, weak self] recording in
            if model?.isRecordingShortcut != recording { model?.isRecordingShortcut = recording }
            model?.onRecordedActiveShortcut =
                recording
                ? { [weak self] shortcut in
                    self?.finishRecording(shortcut)
                } : nil
        }
    }

    @objc private func clicked() {
        if isRecording { cancelRecording() } else { beginRecording() }
    }

    func beginRecording() {
        guard !isRecording, let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        pendingShortcut = nil
        updateTitle()
        onRecordingChange?(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.window === self.window, self.window?.firstResponder === self else {
                self.cancelRecording()
                return event
            }
            return self.capture(event) ? nil : event
        }
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancelRecording() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancelRecording() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancelRecording() }
            },
        ]
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        pendingShortcut = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers.removeAll()
        updateTitle()
        onRecordingChange?(false)
    }

    /// Consume key-down and its matching key-up, so Space/Return never re-click this button.
    /// Registration occurs on release while global-key callbacks are still suppressed.
    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.type == .keyUp {
            if let pendingShortcut, pendingShortcut.keyCode == UInt32(event.keyCode) {
                finishRecording(pendingShortcut)
            }
            return true
        }
        guard event.type == .keyDown else { return false }
        guard !event.isARepeat else { return true }
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
        } else if event.keyCode == UInt16(kVK_Tab) {
            cancelRecording()
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        } else if pendingShortcut == nil {
            let candidate = HotkeyShortcut(event: event)
            if candidate.isValid {
                pendingShortcut = candidate
                title = candidate.label + "（松开保存）"
            } else {
                title = "请加上 ⌘、⌃ 或 ⌥"
            }
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if capture(event) { return }
        // A held key must not start a second recording immediately after capture.
        if !event.isARepeat { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finishRecording(_ value: HotkeyShortcut) {
        guard isRecording else { return }
        // Keep the recording flag true until the candidate has replaced the old registration.
        onShortcutChange?(value)
        if let boundModel { shortcut = boundModel.shortcut } else { shortcut = value }
        cancelRecording()
    }

    private func updateTitle() {
        title = isRecording ? "请按组合键…（Esc 取消）" : shortcut.label + " · 点击修改"
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        focusObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

@MainActor
struct ShortcutRecorderView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl(frame: .zero)
        control.bind(to: model)
        return control
    }

    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        control.shortcut = model.shortcut
        if !model.isRecordingShortcut { control.cancelRecording() }
    }

    static func dismantleNSView(_ control: ShortcutRecorderControl, coordinator: ()) {
        control.cancelRecording()
    }
}
