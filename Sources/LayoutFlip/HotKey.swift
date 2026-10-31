import Carbon

/// One global hot key registered through the Carbon Event Manager (works without Accessibility access).
@MainActor
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    /// Replaces the current registration. Returns eventHotKeyExistsErr when another app holds the combination.
    @discardableResult
    func register(_ shortcut: Shortcut) -> OSStatus {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4C46_6C70), id: 1)  // "LFlp"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
