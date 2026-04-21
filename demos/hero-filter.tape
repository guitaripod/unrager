# Hero — tour covering the product's real hooks:
#   1. Filtered home feed (local LLM already working, `−N` in status).
#   2. Reading a thread in the split detail pane.
#   3. Asking gemma about the focal post (streaming reply, Vim-mode input).
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
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 8s
Show

# Home feed with filter on (`−N` visible in top-right status)
Sleep 1800ms

# Scroll through a few tweets
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 400ms

# Open the thread detail for the selected tweet
Enter
Sleep 3s

# Show replies
Type "j"
Sleep 300ms
Type "j"
Sleep 500ms

# Ask gemma to explain this post
Type "A"
Sleep 1500ms

# Trigger the `1 Explain` preset — streams gemma's reply inline
Type "1"
Sleep 9s

# Close ask pane + detail pane
Escape
Sleep 600ms
Escape
Sleep 900ms

Type "q"
Sleep 200ms
