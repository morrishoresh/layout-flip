import AppKit
import ApplicationServices
import Carbon

/// Finds existing shortcuts that use a given key combination: macOS system shortcuts, and menu shortcuts
/// of running apps (read through Accessibility, so only when access is granted).
enum ShortcutConflicts {
    @MainActor
    static func find(_ shortcut: Shortcut) async -> [String] {
        var found = systemConflicts(shortcut)
        guard AXIsProcessTrusted() else { return found }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { ($0.processIdentifier, $0.localizedName ?? "App \($0.processIdentifier)") }
        let keyCharacter = shortcut.keyCharacter
        let menus = await withTaskGroup(of: [String].self) { group in
            for (pid, name) in apps {
                group.addTask { menuConflicts(shortcut, keyCharacter: keyCharacter, pid: pid, appName: name) }
            }
            var all = Set<String>()
            for await result in group { all.formUnion(result) }
            return all.sorted()
        }
        found += menus
        return found
    }

    private static func systemConflicts(_ shortcut: Shortcut) -> [String] {
        var found: [String] = []
        if shortcut.keyCode == UInt32(kVK_Tab), shortcut.modifiers & UInt32(cmdKey) != 0 {
            found.append("macOS app switcher")
        }
        var hotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotKeys) == noErr,
              let list = hotKeys?.takeRetainedValue() as? [[String: Any]] else { return found }
        let taken = list.contains { hotKey in
            (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool ?? false)
                && (hotKey[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == shortcut.keyCode
                && (hotKey[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & Shortcut.modifierMask }
                    == shortcut.modifiers
        }
        if taken { found.append("macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts)") }
        return found
    }

    private static func menuConflicts(_ shortcut: Shortcut, keyCharacter: String?, pid: pid_t, appName: String) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar: AXUIElement = app.attribute(kAXMenuBarAttribute) else { return [] }
        var found: [String] = []

        func matches(_ item: AXUIElement) -> Bool {
            let character: String? = item.attribute(kAXMenuItemCmdCharAttribute)
            let virtualKey: Int? = item.attribute(kAXMenuItemCmdVirtualKeyAttribute)
            let keyMatches: Bool
            if let character, !character.isEmpty, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 }) {
                keyMatches = character.uppercased() == keyCharacter?.uppercased()
            } else if let virtualKey {
                keyMatches = UInt32(virtualKey) == shortcut.keyCode
            } else {
                return false
            }
            guard keyMatches, let axModifiers: Int = item.attribute(kAXMenuItemCmdModifiersAttribute) else { return false }
            return carbonModifiers(axModifiers) == shortcut.modifiers
        }

        func walk(_ element: AXUIElement, path: [String], depth: Int) {
            guard depth < 5 else { return }
            for child in element.children {
                guard child.role == kAXMenuItemRole else {
                    walk(child, path: path, depth: depth)
                    continue
                }
                let itemPath = path + [child.title]
                if matches(child) { found.append(itemPath.joined(separator: " › ")) }
                walk(child, path: itemPath, depth: depth + 1)
            }
        }

        for (index, barItem) in menuBar.children.enumerated() {
            // The Apple menu is the same in every app, so it is reported once, without the app name.
            walk(barItem, path: index == 0 ? ["Apple menu"] : [appName, barItem.title], depth: 0)
        }
        return found
    }

    /// AXMenuItemCmdModifiers: bit 0 Shift, bit 1 Option, bit 2 Control, bit 3 "no Command".
    private static func carbonModifiers(_ axModifiers: Int) -> UInt32 {
        var modifiers: UInt32 = 0
        if axModifiers & 1 != 0 { modifiers |= UInt32(shiftKey) }
        if axModifiers & 2 != 0 { modifiers |= UInt32(optionKey) }
        if axModifiers & 4 != 0 { modifiers |= UInt32(controlKey) }
        if axModifiers & 8 == 0 { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var children: [AXUIElement] { attribute(kAXChildrenAttribute) ?? [] }
    var role: String? { attribute(kAXRoleAttribute) }
    var title: String { attribute(kAXTitleAttribute) ?? "" }
}
