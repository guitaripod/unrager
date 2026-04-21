# Hero — tour of a filtered feed.
# Shows `−N` in the status bar (filter working), scroll through clean
# content, open a thread detail, close, idle on the home feed. Because
# the filter physically removes tweets rather than hiding them, a
# toggle-off/toggle-on animation wouldn't re-reveal what was dropped —
# so the hook here is the persistent `−N` count plus live navigation.
Output demos/out/hero.gif

Set Shell "bash"
Set FontSize 18
Set Width 1920
Set Height 1180
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms
Set PlaybackSpeed 1.3

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 7s
Show

# Hold on filtered feed (−N visible)
Sleep 2s

# Scroll down through the feed
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 500ms

# Open a tweet's thread
Enter
Sleep 3s

# Browse the replies
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms
Type "j"
Sleep 700ms

# Pop back to the home feed
Escape
Sleep 1500ms

Type "q"
Sleep 200ms
