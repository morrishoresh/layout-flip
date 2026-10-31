import AppKit

// Command-line mode:
//   LayoutFlip --list                 enabled layouts
//   LayoutFlip --convert "akuo"       conversion to every other layout
//   LayoutFlip --flip-line "ls -שךך"  shell line with its trailing wrong-layout run converted (used by the zsh widget);
//                                     printed without a newline, and the active input source switches to the target
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, ["--list", "--convert", "--flip-line"].contains(command) {
    let layouts = KeyboardLayout.enabled()
    if command == "--list" {
        layouts.forEach { print("\($0.name)\t\($0.id)") }
        exit(0)
    }
    guard arguments.count == 2 else {
        print("usage: LayoutFlip \(command) TEXT")
        exit(2)
    }
    if command == "--flip-line" {
        guard let conversion = LayoutConverter.convertTrailingRun(of: arguments[1], among: layouts) else { exit(1) }
        FileHandle.standardOutput.write(Data(conversion.text.utf8))
        conversion.target.select()
        exit(0)
    }
    guard let source = LayoutConverter.sourceLayout(of: arguments[1], among: layouts) else {
        print("No layout found for the text")
        exit(1)
    }
    print("source: \(source.name)")
    LayoutConverter.conversions(of: arguments[1], among: layouts).forEach { print("\($0.target.name): \($0.text)") }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
