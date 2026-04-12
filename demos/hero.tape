# Hero GIF for the README — uses :search to get safe, tech-focused content.
Output demos/out/hero.gif
Output demos/out/hero.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1400
Set Height 850
Set Padding 16
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set PlaybackSpeed 1.2

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 5s
Type ":search rust programming"
Enter
Sleep 5s
Show

# Scroll the feed
Sleep 400ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 600ms

# Expand a tweet
Type "x"
Sleep 1200ms
Type "x"
Sleep 400ms

# Open detail
Type "g"
Sleep 300ms
Type "j"
Sleep 200ms
Enter
Sleep 2500ms
Type "j"
Sleep 250ms
Type "j"
Sleep 250ms
Type "j"
Sleep 500ms

# Back
Type "h"
Sleep 500ms

# Help
Type "?"
Sleep 1500ms
Type " "
Sleep 300ms

# Filter toggle
Type "c"
Sleep 1000ms
Type "c"
Sleep 800ms

Type "q"
Sleep 200ms
