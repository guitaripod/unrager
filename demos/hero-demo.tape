# Hero recorded against `unrager demo` — bundled offline feed designed
# to exercise the filter visibly.
#
# Sequence:
#   1. Launch unrager demo (filter defaults on → Ollama classifies the 15
#      bundled tweets → `−N` appears in status as rage-bait gets dropped).
#   2. Scroll the remaining filtered feed.
#   3. Open a thread.
#   4. Press A to ask gemma about the focal post (streaming response).
Output demos/out/hero.gif

Set Shell "bash"
Set FontSize 18
Set Width 1920
Set Height 1180
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms
Set PlaybackSpeed 1.2

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager demo"
Enter
Sleep 10s
Show

# Hold on the filtered home state (−N should be visible top-right)
Sleep 2s

# Scroll through the kept tweets
Type "jjj"
Sleep 800ms
Type "jj"
Sleep 800ms

# Open a thread detail
Enter
Sleep 2s

# Ask gemma to explain this post
Type "A"
Sleep 1500ms
Type "1"
Sleep 8s

Escape
Sleep 500ms
Escape
Sleep 700ms

Type "q"
Sleep 200ms
