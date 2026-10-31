import AppKit
import Carbon

/// Click, then press a key combination to record it. Escape cancels.
final class ShortcutRecorder: NSView {
    var shortcut: Shortcut { didSet { needsDisplay = true } }
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            needsDisplay = true
            onRecordingChange?(recording)
        }
    }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            recording = false
            return
        }
        let candidate = Shortcut(event: event)
        guard candidate.isValid else {
            NSSound.beep()
            return
        }
        recording = false
        onRecord?(candidate)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? "Type shortcut…" : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let hotKey: HotKey
    private let onChange: () -> Void
    private let recorder = ShortcutRecorder(shortcut: Shortcut.saved)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(hotKey: HotKey, onChange: @escaping () -> Void) {
        self.hotKey = hotKey
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "LayoutFlip Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        recorder.onRecordingChange = { [weak self] recording in
            // Free the current shortcut while recording so pressing it gets recorded instead of converting.
            guard let self else { return }
            if recording { self.hotKey.unregister() } else { self.hotKey.register(Shortcut.saved) }
        }
        recorder.onRecord = { [weak self] shortcut in self?.choose(shortcut) }

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        let row = NSStackView(views: [NSTextField(labelWithString: "Convert selection:"), recorder, reset])
        row.spacing = 8
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let column = NSStackView(views: [row, statusLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = column
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        recorder.shortcut = Shortcut.saved
        updateStatus()
        if window?.isVisible == false { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func resetShortcut() {
        choose(.default)
    }

    private func choose(_ shortcut: Shortcut) {
        let previous = Shortcut.saved
        recorder.shortcut = shortcut
        guard shortcut != previous else { return }
        guard hotKey.register(shortcut) == noErr else {
            hotKey.register(previous)
            recorder.shortcut = previous
            showAlert("\(shortcut.displayString) is already registered by another app.", "Choose a different shortcut.")
            return
        }
        statusLabel.stringValue = "Checking \(shortcut.displayString) for conflicts…"
        Task {
            let conflicts = await ShortcutConflicts.find(shortcut)
            if !conflicts.isEmpty, !confirmOverride(shortcut, conflicts) {
                hotKey.register(previous)
                recorder.shortcut = previous
            } else {
                Shortcut.saved = shortcut
                onChange()
            }
            updateStatus()
        }
    }

    private func confirmOverride(_ shortcut: Shortcut, _ conflicts: [String]) -> Bool {
        let shown = conflicts.prefix(10).map { "• \($0)" }
        let more = conflicts.count > shown.count ? ["…and \(conflicts.count - shown.count) more"] : []
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(shortcut.displayString) is already in use"
        alert.informativeText = (["Used by:"] + shown + more + ["", "If you use it anyway, one of them won't work."])
            .joined(separator: "\n")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showAlert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    private func updateStatus() {
        statusLabel.stringValue = AXIsProcessTrusted()
            ? "Conflicts are checked against macOS shortcuts and the menus of running apps."
            : "Accessibility access not granted: only macOS shortcuts are checked for conflicts."
    }
}
