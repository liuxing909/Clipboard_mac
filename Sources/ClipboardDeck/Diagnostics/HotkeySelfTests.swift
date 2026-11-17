import Carbon
import Foundation

/// Exercises registration and routing without installing a system event handler or shortcut.
enum HotkeySelfTests {
    static func run() throws {
        let backend = FakeBackend()
        var hotkey: GlobalHotkey? = GlobalHotkey(backend: backend)
        var presses = 0
        hotkey?.onPress = { presses += 1 }

        try check(succeeded(hotkey?.register(preset: 0)), "initial shortcut registers")
        let first = backend.requests[0]
        try check(backend.send(first) && presses == 1, "current registration receives events")
        try check(
            succeeded(hotkey?.register(preset: 0)) && backend.requests.count == 1,
            "unchanged preset does not register twice")

        backend.shouldFailRegistration = true
        try check(failure(hotkey?.register(preset: 1)) == .occupied, "conflicting shortcut is rejected")
        let rejected = backend.requests[1]
        try check(
            backend.cancelledIDs.isEmpty && backend.send(first) && presses == 2,
            "failed replacement preserves the previous shortcut")
        try check(!backend.send(rejected) && presses == 2, "rejected registration cannot invoke callback")

        backend.shouldFailRegistration = false
        try check(succeeded(hotkey?.register(preset: 1)), "replacement shortcut registers")
        let replacement = backend.requests[2]
        try check(backend.cancelledIDs == [first.id], "successful replacement cancels only the old shortcut")
        try check(!backend.send(first) && presses == 2, "queued events from old registration are ignored")
        try check(!backend.send(EventHotKeyID(signature: 0, id: replacement.id)), "foreign signature is ignored")
        try check(backend.send(replacement) && presses == 3, "replacement registration receives events")

        let requestCount = backend.requests.count
        try check(
            failure(hotkey?.register(preset: -1)) == .invalidPreset
                && failure(hotkey?.register(preset: 3)) == .invalidPreset,
            "invalid presets are rejected")
        try check(
            backend.requests.count == requestCount && backend.cancelledIDs == [first.id],
            "invalid presets leave active registration untouched")
        hotkey = nil
        try check(
            backend.cancelledIDs == [first.id, replacement.id] && backend.removeCount == 1,
            "shutdown cancels active registration and removes handler once")

        let unavailable = FakeBackend()
        unavailable.shouldFailHandler = true
        let disabled = GlobalHotkey(backend: unavailable)
        try check(
            failure(disabled.register(preset: 0)) == .handlerUnavailable && unavailable.requests.isEmpty,
            "handler installation failure prevents unreachable registrations")
        unavailable.shouldFailHandler = false
        try check(succeeded(disabled.register(preset: 0)), "retry recovers a previously unavailable event handler")
        try checkSystemShortcutFilter()
        try checkCustomShortcuts()
        try checkHeldKeyRouting()
        try checkReentrantRouting()
        try checkRegistrationBoundaries()
        try checkRepeatedReplacement()
        print(
            "PASS: fake hotkey registration / conflict rollback / 2000 replacement attempts / stale event routing / invalid preset / cleanup"
        )
    }

    private static func checkReentrantRouting() throws {
        let key = EventHotKeyID(signature: 0x43445041, id: 1)
        let next = EventHotKeyID(signature: key.signature, id: 2)
        let down = UInt32(kEventHotKeyPressed), up = UInt32(kEventHotKeyReleased)
        let router = HotkeyEventRouter()
        var presses = 0
        func recursivePress(_ id: EventHotKeyID) -> Bool {
            presses += 1
            if presses == 1 { _ = router.receive(id, kind: down, press: recursivePress) }
            return true
        }
        _ = router.receive(key, kind: down, press: recursivePress)
        try check(presses == 1, "a nested event loop cannot deliver the same held press twice")
        router.cancel(key)
        for releaseInsideCallback in [false, true] {
            _ = router.receive(key, kind: down) { id in
                if releaseInsideCallback { _ = router.receive(id, kind: up) { _ in false } } else { router.cancel(id) }
                return true
            }
            var delivered = false
            _ = router.receive(key, kind: down) { _ in
                delivered = true; return true
            }
            try check(delivered, "callback cancellation or nested release cannot resurrect a held key")
            router.cancel(key)
        }
        _ = router.receive(key, kind: down) { _ in
            _ = router.receive(next, kind: down) { _ in true }
            return false
        }
        var nestedRepeated = false
        _ = router.receive(next, kind: down) { _ in
            nestedRepeated = true; return true
        }
        try check(!nestedRepeated, "a rejected outer callback cannot clear a newer nested held key")
        _ = router.receive(key, kind: down) { _ in false }
        _ = router.receive(next, kind: down) { _ in
            nestedRepeated = true; return true
        }
        try check(!nestedRepeated, "a rejected foreign press preserves the already held registration")
        try check(
            !router.receive(next, kind: UInt32(kEventRawKeyRepeat)) { _ in true },
            "unrelated event kinds never change hotkey state")
    }

    private static func checkRegistrationBoundaries() throws {
        let backend = FakeBackend()
        var hotkey: GlobalHotkey? = GlobalHotkey(backend: backend)
        weak var releasedHotkey: GlobalHotkey?
        releasedHotkey = hotkey
        defer { backend.onRegister = nil; backend.onCancel = nil }
        try check(succeeded(hotkey?.register(preset: 0)), "boundary test initial registration")
        let old = backend.requests[0]
        var oldLiveWhileRegistering = false, candidatePrematurelyLive = false
        backend.onRegister = { candidate in
            oldLiveWhileRegistering = backend.send(old)
            candidatePrematurelyLive = backend.send(candidate)
        }
        var cancelledKeyStillLive = false, replacementLiveAtCancellation = false
        backend.onCancel = { cancelled in
            cancelledKeyStillLive = backend.send(cancelled)
            if let candidate = backend.requests.last { replacementLiveAtCancellation = backend.send(candidate) }
        }
        try check(succeeded(hotkey?.register(preset: 1)), "boundary replacement registers")
        try check(
            oldLiveWhileRegistering && !candidatePrematurelyLive && !cancelledKeyStillLive
                && replacementLiveAtCancellation,
            "registration has no gap and stale callbacks cannot route during old-key cancellation")
        // Test callbacks must not retain their fake backend beyond this scope.
        backend.onRegister = nil
        backend.onCancel = nil
        hotkey = nil
        try check(
            releasedHotkey == nil && backend.removeCount == 1 && backend.cancelledIDs.count == 2,
            "handler callback and registration cancellation do not retain the owner")
        var cancellations = 0
        var registration: HotkeyRegistration?
        registration = HotkeyRegistration {
            cancellations += 1; registration?.cancel()
        }
        registration?.cancel()
        registration?.cancel()
        registration = nil
        try check(cancellations == 1, "reentrant cancel plus explicit cancel plus deinit release a resource once")
    }

    private static func checkHeldKeyRouting() throws {
        let router = HotkeyEventRouter()
        let key = EventHotKeyID(signature: 0x43445041, id: 1)
        let foreign = EventHotKeyID(signature: 0, id: 1)
        var presses = 0
        func receive(_ id: EventHotKeyID) -> Bool {
            guard id.signature == key.signature else { return false }
            presses += 1
            return true
        }
        for _ in 0..<100 {
            try check(
                router.receive(key, kind: UInt32(kEventHotKeyPressed), press: receive),
                "holding a registered key remains handled")
        }
        try check(presses == 1, "held shortcut cannot reopen the panel after a recorder consumes its first press")
        try check(
            !router.receive(foreign, kind: UInt32(kEventHotKeyReleased), press: receive),
            "foreign release cannot reset the held key")
        try check(
            router.receive(key, kind: UInt32(kEventHotKeyReleased), press: receive), "matching release is handled")
        try check(
            router.receive(key, kind: UInt32(kEventHotKeyPressed), press: receive) && presses == 2,
            "a new physical press after release activates the shortcut again")
        router.cancel(key)
        try check(
            router.receive(key, kind: UInt32(kEventHotKeyPressed), press: receive) && presses == 3,
            "cancelling a registration clears its held state")
        try check(
            !router.receive(foreign, kind: UInt32(kEventHotKeyPressed), press: receive),
            "unhandled foreign hotkeys do not consume another application's event")
    }

    private static func checkCustomShortcuts() throws {
        let backend = FakeBackend()
        let hotkey = GlobalHotkey(backend: backend)
        let custom = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        let alternative = HotkeyShortcut(keyCode: UInt32(kVK_F12), modifiers: UInt32(controlKey | optionKey))
        var presses = 0
        hotkey.onPress = { presses += 1 }
        try check(custom.label == "⇧⌘K" && custom.isValid, "custom key has a readable label")
        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: encoded)
        try check(decoded == custom, "custom key code and modifiers survive Codable round trip")
        try check(succeeded(hotkey.register(shortcut: custom)), "arbitrary custom key registers")
        let first = backend.requests[0]
        try check(backend.shortcuts == [custom], "registration receives custom hardware key and Carbon modifiers")
        try check(
            succeeded(hotkey.register(shortcut: custom)) && backend.requests.count == 1,
            "unchanged custom key does not attempt duplicate registration")
        let invalid = [
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: 0),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey)),
            HotkeyShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)),
            HotkeyShortcut(keyCode: .max, modifiers: UInt32(cmdKey)),
            HotkeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey) | (1 << 31)),
        ]
        for value in invalid {
            try check(
                failure(hotkey.register(shortcut: value)) == .invalidShortcut,
                "unsupported and unmodified keys cannot consume global keyboard input")
        }
        try check(
            backend.requests.count == 1 && backend.cancelledIDs.isEmpty && backend.send(first),
            "invalid custom keys leave the working key registered")
        backend.shouldFailRegistration = true
        try check(
            failure(hotkey.register(shortcut: alternative)) == .occupied,
            "custom conflicts use the same exclusive registration path")
        try check(
            backend.cancelledIDs.isEmpty && backend.send(first) && presses == 2,
            "custom conflict keeps the previous registration live")
        backend.shouldFailRegistration = false
        try check(succeeded(hotkey.register(shortcut: alternative)), "custom conflict can be retried")
        try check(
            backend.shortcuts.last == alternative && backend.cancelledIDs == [first.id],
            "successful custom replacement cancels the previous registration once")
        try check(!backend.send(first), "old custom key events cannot activate a replacement")
    }

    private static func checkRepeatedReplacement() throws {
        let backend = FakeBackend()
        var hotkey: GlobalHotkey? = GlobalHotkey(backend: backend)
        var presses = 0
        hotkey?.onPress = { presses += 1 }
        try check(succeeded(hotkey?.register(preset: 0)), "stress initial shortcut")
        var activePreset = 0
        var activeID = backend.requests[0]
        var registeredIDs = [activeID.id]
        for index in 0..<2_000 {
            let nextPreset = (activePreset + 1) % HotkeyPresets.labels.count
            backend.shouldFailRegistration = index % 5 == 0
            let result = hotkey?.register(preset: nextPreset)
            guard let attempted = backend.requests.last else { throw Failure.failed("stress registration missing") }
            if backend.shouldFailRegistration {
                try check(failure(result) == .occupied, "stress conflict result at \(index)")
                try check(!backend.send(attempted), "failed registration must never route at \(index)")
            } else {
                try check(succeeded(result), "stress replacement result at \(index)")
                try check(!backend.send(activeID), "retired registration must never route at \(index)")
                registeredIDs.append(attempted.id)
                activeID = attempted
                activePreset = nextPreset
            }
            let beforePress = presses
            try check(backend.send(activeID) && presses == beforePress + 1, "only active key routes at \(index)")
            try check(
                backend.cancelledIDs.count == registeredIDs.count - 1,
                "exactly one live registration remains at \(index)")
        }
        hotkey = nil
        try check(backend.cancelledIDs == registeredIDs, "all successful registrations cancel once in order")
        try check(backend.removeCount == 1 && !backend.send(activeID), "no event routing after owner release")
    }

    private static func succeeded(_ result: Result<Void, HotkeyFailure>?) -> Bool {
        if case .success? = result { return true }
        return false
    }
    private static func failure(_ result: Result<Void, HotkeyFailure>?) -> HotkeyFailure? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    private static func checkSystemShortcutFilter() throws {
        let key = UInt32(kVK_ANSI_V), flags = UInt32(controlKey | optionKey)
        func item(
            _ enabled: Bool, keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(controlKey | optionKey)
        ) -> [String: Any] {
            [
                kHISymbolicHotKeyEnabled as String: enabled,
                kHISymbolicHotKeyCode as String: keyCode,
                kHISymbolicHotKeyModifiers as String: modifiers,
            ]
        }
        try check(
            CarbonHotkeyBackend.hasSystemConflict(in: [item(true)], keyCode: key, modifiers: flags),
            "enabled system shortcuts are recognized before registration")
        try check(
            !CarbonHotkeyBackend.hasSystemConflict(
                in: [item(false), item(true, keyCode: 1), item(true, modifiers: 0), [:]],
                keyCode: key, modifiers: flags),
            "disabled, malformed and unrelated system shortcuts are not false conflicts")
    }

    /// Explicit integration probe: registers a rare chord, never sends global input.
    /// Both registrations and the handler are released even if an assertion fails.
    static func runSystemRegistration() throws {
        let backend = CarbonHotkeyBackend()
        var activeNativeID: UInt32? = 1
        var nativePresses = 0
        guard
            backend.installHandler({ id in
                guard id.signature == 0x43445453, id.id == activeNativeID else { return false }
                nativePresses += 1
                return true
            })
        else { throw Failure.failed("native hotkey handler") }
        defer { backend.removeHandler() }
        let flags = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let key = UInt32(kVK_F20)
        let firstID = EventHotKeyID(signature: 0x43445453, id: 1)
        let first: HotkeyRegistration
        switch backend.register(keyCode: key, modifiers: flags, id: firstID) {
        case .success(let registration): first = registration
        case .failure(let error): throw Failure.failed("native test chord unavailable: \(error)")
        }
        defer { first.cancel() }
        for _ in 0..<25 { try sendNativeHotkey(firstID, kind: UInt32(kEventHotKeyPressed)) }
        try check(nativePresses == 1, "native event handler suppresses repeated Pressed events")
        try sendNativeHotkey(firstID, kind: UInt32(kEventHotKeyReleased))
        try sendNativeHotkey(firstID, kind: UInt32(kEventHotKeyPressed))
        try check(nativePresses == 2, "native handler receives Released and accepts the next physical press")
        let conflict = backend.register(
            keyCode: key, modifiers: flags,
            id: EventHotKeyID(signature: firstID.signature, id: 2))
        switch conflict {
        case .failure(.occupied): break
        case .success(let accidental):
            accidental.cancel()
            throw Failure.failed("duplicate native registration must report a conflict")
        case .failure(let error): throw Failure.failed("native conflict misclassified: \(error)")
        }
        first.cancel()
        activeNativeID = nil
        try sendNativeHotkey(firstID, kind: UInt32(kEventHotKeyPressed))
        try check(nativePresses == 2, "cancelled native registration cannot invoke its retired callback")
        let retryID = EventHotKeyID(signature: firstID.signature, id: 3)
        switch backend.register(
            keyCode: key, modifiers: flags,
            id: retryID)
        {
        case .success(let retry):
            defer { retry.cancel() }
            activeNativeID = retryID.id
            try sendNativeHotkey(retryID, kind: UInt32(kEventHotKeyPressed))
            try sendNativeHotkey(firstID, kind: UInt32(kEventHotKeyReleased))
            try sendNativeHotkey(retryID, kind: UInt32(kEventHotKeyPressed))
            try check(nativePresses == 3, "late old release cannot unblock a held replacement key")
            try sendNativeHotkey(retryID, kind: UInt32(kEventHotKeyReleased))
            try sendNativeHotkey(retryID, kind: UInt32(kEventHotKeyPressed))
            try check(nativePresses == 4, "replacement key routes again after its own native release")
        case .failure(let error): throw Failure.failed("native retry after release: \(error)")
        }
        print(
            "PASS: native Carbon exclusive registration / duplicate conflict / local Pressed-Released dispatch / stale IDs / retry; no global input sent"
        )
    }

    /// Dispatch only to this test process's application target, never to the keyboard or other apps.
    private static func sendNativeHotkey(_ id: EventHotKeyID, kind: UInt32) throws {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(), 0, &event)
        guard created == noErr, let event else { throw Failure.failed("create local Carbon test event: \(created)") }
        defer { ReleaseEvent(event) }
        var value = id
        let assigned = SetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &value)
        guard assigned == noErr else { throw Failure.failed("set local Carbon test event ID: \(assigned)") }
        let sent = SendEventToEventTarget(event, GetApplicationEventTarget())
        try check(sent == noErr || sent == OSStatus(eventNotHandledErr), "local Carbon event dispatch status: \(sent)")
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }

    private final class FakeBackend: HotkeyBackend {
        var shouldFailRegistration = false
        var shouldFailHandler = false
        var requests: [EventHotKeyID] = []
        var shortcuts: [HotkeyShortcut] = []
        var cancelledIDs: [UInt32] = []
        var removeCount = 0
        var onRegister: ((EventHotKeyID) -> Void)?
        var onCancel: ((EventHotKeyID) -> Void)?
        private var receive: ((EventHotKeyID) -> Bool)?

        func installHandler(_ receive: @escaping (EventHotKeyID) -> Bool) -> Bool {
            guard !shouldFailHandler else { return false }
            self.receive = receive
            return true
        }

        func register(keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID) -> Result<
            HotkeyRegistration, HotkeyFailure
        > {
            requests.append(id)
            shortcuts.append(HotkeyShortcut(keyCode: keyCode, modifiers: modifiers))
            onRegister?(id)
            guard !shouldFailRegistration else { return .failure(.occupied) }
            return .success(
                HotkeyRegistration { [weak self] in
                    self?.cancelledIDs.append(id.id)
                    self?.onCancel?(id)
                })
        }

        func removeHandler() { removeCount += 1; receive = nil }
        func send(_ id: EventHotKeyID) -> Bool { receive?(id) ?? false }
    }
}
