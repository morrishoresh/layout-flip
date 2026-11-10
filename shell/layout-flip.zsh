# LayoutFlip zsh widget: converts text typed with the wrong keyboard layout on the command line.
# Converts the text before the cursor if it was all typed in one layout, otherwise its trailing run typed in one
# layout. Bound to U+E000, which LayoutFlip.app types when its shortcut is pressed in a terminal, and to ^X^L.
#
# Load it from ~/.zshrc:
#   [[ -r /Applications/LayoutFlip.app/Contents/Resources/layout-flip.zsh ]] && source /Applications/LayoutFlip.app/Contents/Resources/layout-flip.zsh

layout-flip() {
  local out
  # The trailing "." keeps command substitution from stripping trailing newlines.
  out=$(/Applications/LayoutFlip.app/Contents/MacOS/LayoutFlip --flip-line "$LBUFFER" && print -n .) || {
    zle beep
    return
  }
  LBUFFER=${out%.}
}

zle -N layout-flip
bindkey $'\uE000' layout-flip
bindkey '^X^L' layout-flip
