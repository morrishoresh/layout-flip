import Carbon

/// A physical key plus Shift state.
struct KeyStroke: Hashable {
    let keyCode: UInt16
    let shift: Bool
}

/// An enabled keyboard layout and the characters its keys produce with and without Shift.
final class KeyboardLayout {
    let id: String
    let name: String
    let source: TISInputSource
    /// Character produced by each key stroke.
    let output: [KeyStroke: String]
    /// Key stroke producing each character; unshifted strokes and lower key codes win.
    let strokes: [String: KeyStroke]

    /// Nil for input sources without key layout data (e.g. input methods such as Pinyin).
    init?(source: TISInputSource) {
        guard let id: String = source.property(kTISPropertyInputSourceID),
              let data: Data = source.property(kTISPropertyUnicodeKeyLayoutData) else { return nil }
        var output: [KeyStroke: String] = [:]
        var strokes: [String: KeyStroke] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                for keyCode in UInt16(0)..<128 {
                    guard let text = Self.translate(layout, keyCode: keyCode, shift: shift) else { continue }
                    let stroke = KeyStroke(keyCode: keyCode, shift: shift)
                    output[stroke] = text
                    if strokes[text] == nil { strokes[text] = stroke }
                }
            }
        }
        guard !output.isEmpty else { return nil }
        self.id = id
        self.name = source.property(kTISPropertyLocalizedName) ?? id
        self.source = source
        self.output = output
        self.strokes = strokes
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, keyCode: UInt16, shift: Bool) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        // Skip control characters (Return, Tab, Escape, ...) and function-key private-use characters.
        let printable = text.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }
        return printable ? text : nil
    }

    func select() {
        TISSelectInputSource(source)
    }

    /// Enabled keyboard layouts, in Input menu order.
    static func enabled() -> [KeyboardLayout] {
        let filter = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap(KeyboardLayout.init)
    }

    /// The layout used for keyboard shortcuts (e.g. ABC while a non-Latin layout is active).
    static func asciiCapable() -> KeyboardLayout? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(source: source)
    }

    static func currentID() -> String? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue().property(kTISPropertyInputSourceID)
    }
}

extension TISInputSource {
    func property<T>(_ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

/// Text re-typed on another layout using the same physical keys.
struct Conversion {
    let source: KeyboardLayout
    let target: KeyboardLayout
    let text: String
}

enum LayoutConverter {
    /// The layout that most likely produced `text`: the one producing most of the characters that not every
    /// layout produces. Nil when no layout stands out (e.g. digits only).
    static func sourceLayout(of text: String, among layouts: [KeyboardLayout]) -> KeyboardLayout? {
        let distinctive = text.unicodeScalars.map { String($0) }.filter { char in
            !layouts.allSatisfy { $0.strokes[char] != nil }
        }
        let scores = layouts.map { layout in (layout, distinctive.filter { layout.strokes[$0] != nil }.count) }
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Characters the source layout can't type (spaces, newlines, characters from other layouts) are kept as is.
    static func convert(_ text: String, from source: KeyboardLayout, to target: KeyboardLayout) -> String {
        text.unicodeScalars.map { scalar in
            let char = String(scalar)
            guard let stroke = source.strokes[char], let converted = target.output[stroke] else { return char }
            return converted
        }.joined()
    }

    /// For a shell command line: converts the whole text if it was typed in one layout, otherwise only its trailing
    /// run typed in one layout (e.g. "ls -שךך" -> "ls -all"). Characters every layout types (spaces, digits, ...)
    /// don't end a run. Returns the full text with the run converted, using the first layout that changes it.
    static func convertTrailingRun(of text: String, among layouts: [KeyboardLayout]) -> Conversion? {
        let chars = text.unicodeScalars.map { String($0) }
        guard let (start, candidates) = trailingRun(of: chars, among: layouts) else { return nil }
        let prefix = chars[..<start].joined()
        let run = chars[start...].joined()
        guard let source = sourceLayout(of: run, among: candidates) ?? candidates.first else { return nil }
        for target in layouts where target.id != source.id {
            let converted = convert(run, from: source, to: target)
            if converted != run { return Conversion(source: source, target: target, text: prefix + converted) }
        }
        return nil
    }

    /// The part of `text` that `convertTrailingRun` converts, as a UTF-16 offset (for NSRange / Accessibility).
    static func trailingRunUTF16Start(of text: String, among layouts: [KeyboardLayout]) -> Int? {
        let chars = text.unicodeScalars.map { String($0) }
        guard let (start, _) = trailingRun(of: chars, among: layouts) else { return nil }
        return chars[..<start].joined().utf16.count
    }

    /// Start index of the trailing run typed in one layout (0 when the whole text was), plus the layouts that can
    /// type all of it.
    private static func trailingRun(of chars: [String], among layouts: [KeyboardLayout]) -> (Int, [KeyboardLayout])? {
        var candidates = layouts
        var runStart: Int?
        var wholeText = true
        for index in chars.indices.reversed() {
            let producers = Set(layouts.filter { $0.strokes[chars[index]] != nil }.map(\.id))
            if producers.isEmpty || producers.count == layouts.count { continue }
            let remaining = candidates.filter { producers.contains($0.id) }
            if remaining.isEmpty {
                wholeText = false
                break
            }
            candidates = remaining
            runStart = index
        }
        guard let start = wholeText ? 0 : runStart else { return nil }
        return (start, candidates)
    }

    /// One conversion per other enabled layout, skipping those that leave the text unchanged.
    static func conversions(of text: String, among layouts: [KeyboardLayout]) -> [Conversion] {
        guard let source = sourceLayout(of: text, among: layouts) else { return [] }
        return layouts
            .filter { $0.id != source.id }
            .map { Conversion(source: source, target: $0, text: convert(text, from: source, to: $0)) }
            .filter { $0.text != text }
    }
}
