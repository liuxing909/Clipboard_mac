import Carbon
import Foundation

enum HotkeyFailure: Error, Equatable {
    case occupied, systemReserved, handlerUnavailable, invalidPreset, invalidShortcut, registrationFailed(OSStatus)
}

enum HotkeyPresets {
    static let shortcuts = [controlKey | optionKey, optionKey, controlKey | shiftKey].map {
        HotkeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32($0))
    }
    static let labels = shortcuts.map(\.label)
    static func label(_ index: Int) -> String { labels.indices.contains(index) ? labels[index] : "未知快捷键" }
}

struct HotkeyWarning: Identifiable, Equatable {
    let id = UUID()
    let shortcut: HotkeyShortcut
    let failure: HotkeyFailure
    let retainedShortcut: HotkeyShortcut?

    var preset: Int { HotkeyPresets.shortcuts.firstIndex(of: shortcut) ?? -1 }
    var retainedPreset: Int? { retainedShortcut.flatMap { HotkeyPresets.shortcuts.firstIndex(of: $0) } }

    init(shortcut: HotkeyShortcut, failure: HotkeyFailure, retainedShortcut: HotkeyShortcut?) {
        self.shortcut = shortcut
        self.failure = failure
        self.retainedShortcut = retainedShortcut
    }

    init(preset: Int, failure: HotkeyFailure, retainedPreset: Int?) {
        shortcut =
            HotkeyPresets.shortcuts.indices.contains(preset)
            ? HotkeyPresets.shortcuts[preset] : HotkeyPresets.shortcuts[0]
        self.failure = failure
        retainedShortcut = retainedPreset.flatMap {
            HotkeyPresets.shortcuts.indices.contains($0) ? HotkeyPresets.shortcuts[$0] : nil
        }
    }

    var title: String {
        switch failure {
        case .occupied, .systemReserved: return "快捷键冲突"
        default: return "快捷键未启用"
        }
    }
    var message: String {
        let requested = shortcut.label
        let reason: String
        switch failure {
        case .occupied: reason = "\(requested) 已被占用，请换一组组合键。"
        case .systemReserved: reason = "\(requested) 已被 macOS 系统快捷键占用，请更换组合键或调整系统键盘设置。"
        case .invalidShortcut: reason = "请使用包含 ⌘、⌃ 或 ⌥ 的组合键，不能只使用普通按键或 ⇧。"
        default: reason = "暂时无法启用 \(requested)，请重试或换一组组合键。"
        }
        if let retainedShortcut { return reason + " 原快捷键 \(retainedShortcut.label) 仍可使用。" }
        return reason + " 当前没有可用的呼出快捷键，请点击菜单栏的剪贴匣图标打开。"
    }
}

/// A registration owns its cancellation, so replacement and shutdown cancel exactly once.
final class HotkeyRegistration {
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) { cancellation = cancel }

    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }

    deinit { cancel() }
}

protocol HotkeyBackend: AnyObject {
    func installHandler(_ receive: @escaping (EventHotKeyID) -> Bool) -> Bool
    func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> Result<HotkeyRegistration, HotkeyFailure>
    func removeHandler()
}

final class GlobalHotkey {
    var onPress: (() -> Void)?
    private let backend: HotkeyBackend
    private var handlerInstalled = false
    private var registration: HotkeyRegistration?
    private var activeShortcut: HotkeyShortcut?
    private var activeID: UInt32?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x43445041

    init(backend: HotkeyBackend = CarbonHotkeyBackend()) {
        self.backend = backend
        installHandlerIfNeeded()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = backend.installHandler { [weak self] id in
            guard let self, id.signature == Self.signature, id.id == self.activeID else { return false }
            self.onPress?()
            return true
        }
    }

    func register(preset: Int) -> Result<Void, HotkeyFailure> {
        guard HotkeyPresets.shortcuts.indices.contains(preset) else { return .failure(.invalidPreset) }
        return register(shortcut: HotkeyPresets.shortcuts[preset])
    }

    func register(shortcut: HotkeyShortcut) -> Result<Void, HotkeyFailure> {
        guard shortcut.isValid else { return .failure(.invalidShortcut) }
        installHandlerIfNeeded()
        guard handlerInstalled else { return .failure(.handlerUnavailable) }
        if activeShortcut == shortcut, registration != nil { return .success(()) }

        let candidateID = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let id = EventHotKeyID(signature: Self.signature, id: candidateID)
        let candidate: HotkeyRegistration
        switch backend.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) {
        case .success(let value): candidate = value
        case .failure(let error): return .failure(error)
        }

        // Keep the old shortcut live until its replacement has actually registered.
        let previous = registration
        registration = candidate
        activeShortcut = shortcut
        activeID = candidateID
        previous?.cancel()
        return .success(())
    }

    deinit {
        registration?.cancel()
        if handlerInstalled { backend.removeHandler() }
    }
}

/// A held global shortcut opens the panel once, including when it finishes a recording.
/// No timer or background polling is needed: Carbon supplies both press and release.
final class HotkeyEventRouter {
    private var heldID: EventHotKeyID?

    func receive(_ id: EventHotKeyID, kind: UInt32, press: (EventHotKeyID) -> Bool) -> Bool {
        let isHeld = heldID?.signature == id.signature && heldID?.id == id.id
        if kind == UInt32(kEventHotKeyReleased) {
            if isHeld { heldID = nil }
            return isHeld
        }
        guard kind == UInt32(kEventHotKeyPressed) else { return false }
        if isHeld { return true }
        guard press(id) else { return false }
        heldID = id
        return true
    }

    func cancel(_ id: EventHotKeyID) {
        if heldID?.signature == id.signature && heldID?.id == id.id { heldID = nil }
    }
}

final class CarbonHotkeyBackend: HotkeyBackend {
    private var handler: EventHandlerRef?
    private var receive: ((EventHotKeyID) -> Bool)?
    private var eventRouter = HotkeyEventRouter()

    func installHandler(_ receive: @escaping (EventHotKeyID) -> Bool) -> Bool {
        guard handler == nil else { return false }
        self.receive = receive
        var types = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context -> OSStatus in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let owner = Unmanaged<CarbonHotkeyBackend>.fromOpaque(context).takeUnretainedValue()
                let handled = owner.eventRouter.receive(id, kind: GetEventKind(event)) {
                    owner.receive?($0) == true
                }
                return handled ? noErr : OSStatus(eventNotHandledErr)
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &installed)
        guard status == noErr, let installed else {
            if let installed { RemoveEventHandler(installed) }
            self.receive = nil
            return false
        }
        handler = installed
        return true
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> Result<HotkeyRegistration, HotkeyFailure> {
        // Only check on registration, never in the clipboard polling loop.
        if Self.hasSystemConflict(keyCode: keyCode, modifiers: modifiers) {
            return .failure(.systemReserved)
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if let reference { UnregisterEventHotKey(reference) }
            return .failure(
                status == OSStatus(eventHotKeyExistsErr)
                    ? .occupied : .registrationFailed(status == noErr ? OSStatus(eventInternalErr) : status))
        }
        return .success(
            HotkeyRegistration { [weak self] in
                UnregisterEventHotKey(reference)
                self?.eventRouter.cancel(id)
            })
    }

    private static func hasSystemConflict(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        let values = array?.takeRetainedValue()
        guard status == noErr, let entries = values as? [[String: Any]] else { return false }
        return hasSystemConflict(in: entries, keyCode: keyCode, modifiers: modifiers)
    }

    static func hasSystemConflict(in entries: [[String: Any]], keyCode: UInt32, modifiers: UInt32) -> Bool {
        entries.contains { item in
            (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
                && (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode
                && (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == modifiers
        }
    }

    func removeHandler() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        receive = nil
        eventRouter = HotkeyEventRouter()
    }

    deinit { removeHandler() }
}
