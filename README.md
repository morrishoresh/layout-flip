# LayoutFlip

Menu-bar app that fixes text typed with the wrong keyboard layout (e.g. `akuo` -> `שלום`) by re-typing the same physical keys on another layout.

- Works with whatever keyboard layouts are enabled in System Settings › Keyboard › Input Sources; no layouts are hard-coded.
- The source layout is detected from the characters in the text. With two layouts the text is converted to the other one; with more, a menu at the mouse pointer shows the result for each layout.
- After converting, the active input source switches to the target layout.

## Build / install

```sh
./build.sh            # builds build/LayoutFlip.app
./build.sh --install  # also copies it to /Applications, registers the Services entry and installs the Claude Code mod
```

## Use

1. Open `/Applications/LayoutFlip.app` (keyboard icon in the menu bar) and grant Accessibility access when asked.
2. Either:
   - press the shortcut (default ⌃⌥⌘L): converts the selection, or with nothing selected, the text before the caret on its line (all of it if typed in one layout, otherwise its trailing run typed in one layout), or
   - select text and right-click -> Services -> Convert Keyboard Layout (shown only when text is selected).
3. Settings… -> click the shortcut field and press a new combination. If it is already used by a macOS shortcut or by a menu item of a running app, a warning lists where; you can cancel or use it anyway.

The shortcut copies the selection, pastes the converted text and restores the clipboard. With nothing selected, it selects the text via Accessibility, or in apps that don't expose it (e.g. Firefox) with ⇧⌘←, then pastes the line with only its trailing run converted. The Services entry replaces the selection directly without touching the clipboard. If the Services entry is missing, enable it in System Settings › Keyboard › Keyboard Shortcuts › Services › Text.

In a terminal the shortcut types U+E000, which converts the text before the cursor in:

- zsh: source `layout-flip.zsh` from `~/.zshrc` (see the header of `shell/layout-flip.zsh`).
- Claude Code: the mod in `claude-code/`. When `claude` is on the `PATH`, `./build.sh --install` copies it to `~/Library/Application Support/LayoutFlip/claude-code` and adds that folder to `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json`. It runs from outside the app because Claude Code writes into the plugin folders it loads, which would break the app's signature.

Accessibility access is needed for sending ⌘C/⌘V and for checking app menus for shortcut conflicts. The app is ad-hoc signed, so after each rebuild remove and re-add it under System Settings › Privacy & Security › Accessibility.

Command-line check of the layout maps:

```sh
build/LayoutFlip.app/Contents/MacOS/LayoutFlip --list
build/LayoutFlip.app/Contents/MacOS/LayoutFlip --convert "akuo"
```

Logs: `log stream --predicate 'subsystem == "com.morrishoresh.LayoutFlip"'`
