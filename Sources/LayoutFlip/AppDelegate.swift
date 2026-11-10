import AppKit
import Carbon
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: "com.morrishoresh.LayoutFlip", category: "convert")
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey!
    private var settings: SettingsWindowController?
    private var converting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "LayoutFlip")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey { [weak self] in self?.convertSelection() }
        let status = hotKey.register(Shortcut.saved)
        if status != noErr { log.error("Registering \(Shortcut.saved.displayString) failed: \(status)") }

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if !AXIsProcessTrusted() { requestAccessibility() }
        log.info("Launched")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Convert Selection (\(Shortcut.saved.displayString))", action: #selector(convertSelection), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Keyboard Layouts"))
        let layouts = KeyboardLayout.enabled()
        let currentID = KeyboardLayout.currentID()
        for layout in layouts {
            let item = menu.addItem(withTitle: layout.name, action: nil, keyEquivalent: "")
            item.state = layout.id == currentID ? .on : .off
        }
        if layouts.count < 2 {
            menu.addItem(withTitle: "Add another layout in System Settings › Keyboard", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
                .target = self
        }
        let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LayoutFlip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(hotKey: hotKey) { [weak self] in
                self?.log.info("Shortcut set to \(Shortcut.saved.displayString)")
            }
        }
        settings?.show()
    }

    @objc private func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("Launch at Login change failed: \(error.localizedDescription)")
        }
    }

    // MARK: Conversion via shortcut: copy the selection, convert it, paste it back

    @objc private func convertSelection() {
        log.info("Convert requested")
        guard !converting else { return }
        guard AXIsProcessTrusted() else {
            log.error("No Accessibility access")
            requestAccessibility()
            return
        }
        converting = true
        Task {
            await replaceSelection()
            converting = false
        }
    }

    /// Terminals can't replace a selection, so there the shortcut types `terminalMarker`, which the zsh widget
    /// (layout-flip.zsh) and the Claude Code mod (claude-code/) take as a request to convert the text before the caret.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    /// A private-use character, so it is never typed otherwise.
    private static let terminalMarker = "\u{E000}"

    private func replaceSelection() async {
        await waitForModifierRelease()
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.terminalBundleIDs.contains(bundleID) {
            Keyboard.type(Self.terminalMarker)
            log.info("Sent marker to \(bundleID)")
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.snapshot()
        // Nil selected text means the app doesn't expose it; then ⌘C tells whether anything is selected.
        // With "" (nothing selected) ⌘C is skipped, since some editors would copy the whole line.
        var text: String?
        if Self.selectedTextViaAccessibility() != "" || Self.selectTextBeforeCaret() {
            text = await copySelection()
        }
        var linePrefix: String?
        var collapseKey: Int?
        if text?.isEmpty ?? true {
            // Nothing selected and Accessibility can't select (e.g. Firefox): select to the line start with the
            // arrow keys and convert the trailing run of the copied text, keeping the rest of it as is.
            text = nil
            let selection = await selectToLineStartWithKeys()
            collapseKey = selection.collapseKey
            if let line = selection.text {
                linePrefix = ""
                if let runStart = LayoutConverter.trailingRunUTF16Start(of: line, among: KeyboardLayout.enabled()) {
                    linePrefix = (line as NSString).substring(to: runStart)
                    text = (line as NSString).substring(from: runStart)
                }
            }
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let text, !text.isEmpty, let conversion = pickConversion(for: text) else {
            log.info("Nothing to convert")
            pasteboard.restore(saved)
            if let collapseKey {
                // Drop the arrow-key selection, leaving the caret where it was.
                Keyboard.press(keyCode: collapseKey, flags: [.maskSecondaryFn, .maskNumericPad])
            }
            NSSound.beep()
            return
        }
        if NSApp.isActive {
            // The layout picker activated LayoutFlip; give focus back before pasting.
            frontmost?.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }

        pasteboard.clearContents()
        pasteboard.setString((linePrefix ?? "") + conversion.text, forType: .string)
        // Tells clipboard managers not to record this entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        Keyboard.press("v", flags: .maskCommand, fallback: kVK_ANSI_V)
        try? await Task.sleep(for: .milliseconds(500))
        pasteboard.restore(saved)
        conversion.target.select()
        log.info("Converted \(conversion.source.name) -> \(conversion.target.name)")
    }

    /// Sends ⌘C and returns the copied text; nil when nothing was copied.
    private func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        Keyboard.press("c", flags: .maskCommand, fallback: kVK_ANSI_C)
        for _ in 0..<25 where pasteboard.changeCount == changeCount {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != changeCount else {
            log.info("Nothing copied")
            return nil
        }
        return pasteboard.string(forType: .string)
    }

    /// Selects from the caret to the start of its line and returns the copied text (nil when empty), plus the arrow
    /// key that drops the selection again (nil when nothing is selected). ⇧⌘← selects to the visual left end of the
    /// line, which in a right-to-left paragraph is its end. So when it copies nothing or right-to-left text, ⇧⌘→
    /// extends from the caret to the visual right end instead, which is the start of a right-to-left paragraph.
    private func selectToLineStartWithKeys() async -> (text: String?, collapseKey: Int?) {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskSecondaryFn, .maskNumericPad]
        Keyboard.press(keyCode: kVK_LeftArrow, flags: flags)
        let left = await copySelection() ?? ""
        if !left.isEmpty, Self.startsRightToLeft(left) != true { return (left, kVK_RightArrow) }

        Keyboard.press(keyCode: kVK_RightArrow, flags: flags)
        let right = await copySelection() ?? ""
        if Self.startsRightToLeft(right) == true { return (right, kVK_LeftArrow) }
        if !left.isEmpty {
            // Right-to-left text in a left-to-right paragraph (e.g. a web input without dir="auto"): back to ⇧⌘←.
            Keyboard.press(keyCode: kVK_LeftArrow, flags: flags)
            return (left, kVK_RightArrow)
        }
        return (nil, right.isEmpty ? nil : kVK_LeftArrow)
    }

    /// Whether the first strongly directional character is right-to-left (Hebrew, Arabic, ...); nil without one.
    private static func startsRightToLeft(_ text: String) -> Bool? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return nil
    }

    /// The shortcut fires while its modifiers are still down; wait so they don't mix into the synthetic ⌘C/⌘V.
    private func waitForModifierRelease() async {
        for _ in 0..<50 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Selected text of the focused element, "" when nothing is selected, nil when the app doesn't expose it.
    private static func selectedTextViaAccessibility() -> String? {
        let focused: AXUIElement? = AXUIElementCreateSystemWide().attribute(kAXFocusedUIElementAttribute)
        return focused?.attribute(kAXSelectedTextAttribute)
    }

    /// With nothing selected, selects what the zsh widget converts on a command line: the text from the start of the
    /// caret's line to the caret if it was all typed in one layout, otherwise its trailing run typed in one layout.
    /// False when the focused element doesn't expose or accept its text and selection via Accessibility.
    private static func selectTextBeforeCaret() -> Bool {
        guard let focused: AXUIElement = AXUIElementCreateSystemWide().attribute(kAXFocusedUIElementAttribute),
              let value: String = focused.attribute(kAXValueAttribute),
              let selection: AXValue = focused.attribute(kAXSelectedTextRangeAttribute) else { return false }
        var caret = CFRange()
        let text = value as NSString
        guard AXValueGetValue(selection, .cfRange, &caret), caret.length == 0, caret.location <= text.length else {
            return false
        }
        let lineStart = text.lineRange(for: NSRange(location: caret.location, length: 0)).location
        let line = text.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
        guard let runStart = LayoutConverter.trailingRunUTF16Start(of: line, among: KeyboardLayout.enabled()) else {
            return false
        }
        var run = CFRange(location: lineStart + runStart, length: caret.location - lineStart - runStart)
        guard run.length > 0, let runValue = AXValueCreate(.cfRange, &run),
              AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, runValue) == .success
        else { return false }
        // Some elements report success without changing the selection.
        return selectedTextViaAccessibility()?.isEmpty == false
    }

    // MARK: Conversion via Services (right-click menu)

    @objc func convertLayout(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), let conversion = pickConversion(for: text) else {
            error.pointee = "No other keyboard layout produces different text."
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(conversion.text, forType: .string)
        conversion.target.select()
        log.info("Service converted \(conversion.source.name) -> \(conversion.target.name)")
    }

    // MARK: Target choice

    /// With one possible target layout it is used directly; with several, a menu at the mouse offers each result.
    private func pickConversion(for text: String) -> Conversion? {
        let conversions = LayoutConverter.conversions(of: text, among: KeyboardLayout.enabled())
        guard conversions.count > 1 else { return conversions.first }
        let picker = ConversionPicker()
        return withExtendedLifetime(picker) { picker.pick(from: conversions) }
    }
}

@MainActor
private final class ConversionPicker: NSObject {
    private var picked: Int?

    func pick(from conversions: [Conversion]) -> Conversion? {
        let menu = NSMenu()
        for (index, conversion) in conversions.enumerated() {
            let preview = conversion.text.count > 40 ? conversion.text.prefix(40) + "…" : Substring(conversion.text)
            let item = menu.addItem(
                withTitle: "\(conversion.target.name): \(preview)", action: #selector(choose(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            item.keyEquivalentModifierMask = []
            item.tag = index
            item.target = self
        }
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return picked.map { conversions[$0] }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        picked = sender.tag
    }
}

enum Keyboard {
    /// Presses the key that types `character` on the ASCII-capable layout (so ⌘C stays ⌘C on Dvorak).
    static func press(_ character: String, flags: CGEventFlags, fallback: Int) {
        press(keyCode: Int(KeyboardLayout.asciiCapable()?.strokes[character]?.keyCode ?? UInt16(fallback)), flags: flags)
    }

    /// Types `text` regardless of the active layout.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event?.post(tap: .cghidEventTap)
        }
    }

    static func press(keyCode: Int, flags: CGEventFlags) {
        let keyCode = CGKeyCode(keyCode)
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

extension NSPasteboard {
    func snapshot() -> [NSPasteboardItem] {
        (pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    func restore(_ items: [NSPasteboardItem]) {
        clearContents()
        if !items.isEmpty { writeObjects(items) }
    }
}
