# LayoutFlip zsh widget: converts text typed with the wrong keyboard layout on the command line.
# Converts the text before the cursor if it was all typed in one layout, otherwise its trailing run typed in one
# layout. Bound to ^X^L, which LayoutFlip.app sends when its shortcut is pressed in a terminal.
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
bindkey '^X^L' layout-flip
