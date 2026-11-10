import { expect, test } from 'claude-code/testing'

const origin = { kind: 'person' } as never

test('the marker converts the text before the caret on its line', async ($, on) => {
  // Stands for the editor: applies the splice.
  on('prompt.edit', (_, e) => {
    const text = e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end)
    return { text, cursor: e.start + e.inputText.length }
  })
  let argv: readonly string[] = []
  on('process.run', (_, e) => {
    argv = e.argv
    return { value: { exitCode: 0, stdout: 'ls -all', stderr: '' } }
  })

  const text = 'first\nls -שךך tail'
  const cursor = 'first\nls -שךך'.length
  const box = await $.prompt.edit({ origin, text, cursor, start: cursor, end: cursor, inputText: '' })

  expect(argv[2]).toBe('ls -שךך')
  expect(box.text).toBe('first\nls -all tail')
  expect(box.cursor).toBe('first\nls -all'.length)
})

test('other input passes through', async ($, on) => {
  on('prompt.edit', (_, e) => ({ text: e.text + e.inputText, cursor: e.cursor + 1 }))
  const box = await $.prompt.edit({ origin, text: 'ab', cursor: 2, start: 2, end: 2, inputText: 'c' })
  expect(box.text).toBe('abc')
})
