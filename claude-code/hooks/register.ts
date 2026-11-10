import type { Register } from 'claude-code'

/** Private-use character LayoutFlip.app types into terminals when its shortcut is pressed. */
const MARKER = ''
const CLI = '/Applications/LayoutFlip.app/Contents/MacOS/LayoutFlip'

/**
 * Converts the text from the start of the caret's line to the caret: all of it if typed in one layout, otherwise
 * its trailing run typed in one layout. Same rule as the zsh widget (`LayoutFlip --flip-line`).
 */
export const register: Register = on => {
  on('prompt.edit', async ($, e, next) => {
    if (!e.inputText.includes(MARKER)) return next(e)
    const box = await next({ ...e, inputText: e.inputText.replaceAll(MARKER, '') })
    const lineStart = box.text.lastIndexOf('\n', box.cursor - 1) + 1
    const line = box.text.slice(lineStart, box.cursor)
    if (line === '') return box
    const flipped = await $.process.run([CLI, '--flip-line', line], { timeoutMs: 5000 })
    if (flipped.exitCode !== 0) return box
    return {
      text: box.text.slice(0, lineStart) + flipped.stdout + box.text.slice(box.cursor),
      cursor: lineStart + flipped.stdout.length,
    }
  })
}
