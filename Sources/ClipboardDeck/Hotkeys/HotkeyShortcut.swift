import AppKit
import Carbon

/// A physical key and the four modifiers understood by Carbon's global shortcut API.
/// Saving key codes keeps shortcuts stable when switching between input methods.
struct HotkeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let storageKey = "hotkeyShortcut"
    private static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var isValid: Bool {
        Self.keyLabels[keyCode] != nil
            && modifiers & ~Self.allowedModifiers == 0
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + (Self.keyLabels[keyCode] ?? "未知按键")
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        modifiers = flags
    }

    static func load(from defaults: UserDefaults) -> HotkeyShortcut {
        if let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode(Self.self, from: data), saved.isValid
        {
            return saved
        }
        let legacy = defaults.integer(forKey: "hotkeyPreset")
        return HotkeyPresets.shortcuts.indices.contains(legacy)
            ? HotkeyPresets.shortcuts[legacy] : HotkeyPresets.shortcuts[0]
    }

    private static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "空格", 50: "`", 51: "⌫", 53: "⎋",
        64: "F17", 65: "小键盘 .", 67: "小键盘 *", 69: "小键盘 +", 71: "清除",
        75: "小键盘 /", 76: "小键盘 ↩", 78: "小键盘 -", 79: "F18", 80: "F19",
        81: "小键盘 =", 82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3",
        86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7", 90: "F20",
        91: "小键盘 8", 92: "小键盘 9", 93: "¥", 94: "_", 95: "小键盘 ,",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
