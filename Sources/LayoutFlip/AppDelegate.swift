import AppKit
import Carbon
import ServiceManagement
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = Logger(subsystem: "com.morrish.LayoutFlip", category: "convert")
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

    /// Terminals can't replace a selection, so there the shortcut sends ⌃X⌃L, which the zsh widget
    /// (layout-flip.zsh) binds to converting the command line.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

    private func replaceSelection() async {
        await waitForModifierRelease()
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.terminalBundleIDs.contains(bundleID) {
            Keyboard.press("x", flags: .maskControl, fallback: kVK_ANSI_X)
            Keyboard.press("l", flags: .maskControl, fallback: kVK_ANSI_L)
            log.info("Sent ⌃X⌃L to \(bundleID)")
            return
        }
        if Self.selectedTextViaAccessibility() == "" {
            // Nothing selected. Copying anyway would make some editors copy the whole line.
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.snapshot()
        let changeCount = pasteboard.changeCount
        Keyboard.press("c", flags: .maskCommand, fallback: kVK_ANSI_C)
        for _ in 0..<25 where pasteboard.changeCount == changeCount {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != changeCount, let text = pasteboard.string(forType: .string) else {
            log.info("Nothing copied")
            NSSound.beep()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let conversion = pickConversion(for: text) else {
            pasteboard.restore(saved)
            NSSound.beep()
            return
        }
        if NSApp.isActive {
            // The layout picker activated LayoutFlip; give focus back before pasting.
            frontmost?.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }

        pasteboard.clearContents()
        pasteboard.setString(conversion.text, forType: .string)
        // Tells clipboard managers not to record this entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        Keyboard.press("v", flags: .maskCommand, fallback: kVK_ANSI_V)
        try? await Task.sleep(for: .milliseconds(500))
        pasteboard.restore(saved)
        conversion.target.select()
        log.info("Converted \(conversion.source.name) -> \(conversion.target.name)")
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
        let keyCode = KeyboardLayout.asciiCapable()?.strokes[character]?.keyCode ?? UInt16(fallback)
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
