import Carbon

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
        try checkRepeatedReplacement()
        print(
            "PASS: fake hotkey registration / conflict rollback / 2000 replacement attempts / stale event routing / invalid preset / cleanup"
        )
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

    /// Explicit integration probe: registers a rare chord, never emits key events.
    /// Both registrations and the handler are released even if an assertion fails.
    static func runSystemRegistration() throws {
        let backend = CarbonHotkeyBackend()
        guard backend.installHandler({ _ in true }) else { throw Failure.failed("native hotkey handler") }
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
        switch backend.register(
            keyCode: key, modifiers: flags,
            id: EventHotKeyID(signature: firstID.signature, id: 3))
        {
        case .success(let retry): retry.cancel()
        case .failure(let error): throw Failure.failed("native retry after release: \(error)")
        }
        print(
            "PASS: native Carbon exclusive registration / actual duplicate conflict / release and retry; no key events sent"
        )
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }

    private final class FakeBackend: HotkeyBackend {
        var shouldFailRegistration = false
        var shouldFailHandler = false
        var requests: [EventHotKeyID] = []
        var cancelledIDs: [UInt32] = []
        var removeCount = 0
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
            guard !shouldFailRegistration else { return .failure(.occupied) }
            return .success(HotkeyRegistration { [weak self] in self?.cancelledIDs.append(id.id) })
        }

        func removeHandler() { removeCount += 1; receive = nil }
        func send(_ id: EventHotKeyID) -> Bool { receive?(id) ?? false }
    }
}
