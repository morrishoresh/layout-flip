import AppKit
import Carbon

/// A key combination: virtual key code plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey | cmdKey))
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private static let keyCodeKey = "shortcutKeyCode"
    private static let modifiersKey = "shortcutModifiers"

    static var saved: Shortcut {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keyCodeKey) != nil else { return .default }
            return Shortcut(
                keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: modifiersKey))
            )
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: keyCodeKey)
            UserDefaults.standard.set(Int(newValue.modifiers), forKey: modifiersKey)
        }
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// Plain keys and Shift-only combinations would fire while typing; function keys may be used alone.
    var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys[Int(keyCode)] != nil
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// Character the key types on the ASCII-capable layout (e.g. "l"); nil for non-character keys.
    var keyCharacter: String? {
        guard Self.specialKeys[Int(keyCode)] == nil else { return nil }
        return KeyboardLayout.asciiCapable()?.output[KeyStroke(keyCode: UInt16(keyCode), shift: false)]
    }

    private var keyName: String {
        Self.specialKeys[Int(keyCode)] ?? keyCharacter?.uppercased() ?? "Key \(keyCode)"
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = functionKeys.merging([
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]) { first, _ in first }
}
