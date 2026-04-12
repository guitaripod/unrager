# The grand tour: launch → scroll → filter toggle → detail → reply nav → help → quit.
Output demos/out/overview.gif
Output demos/out/overview.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1600
Set Height 960
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 6s
Show

# Scroll the feed
Type "jjjjjj"
Sleep 1s

# Filter toggle off then on
Type "c"
Sleep 1500ms
Type "c"
Sleep 1500ms

# Back to top
Type "gg"
Sleep 500ms

# Open a tweet
Type "jj"
Sleep 300ms
Enter
Sleep 3s
Show
Type "jjj"
Sleep 800ms
Type "h"
Sleep 500ms

# Help overlay
Type "?"
Sleep 2s
Type " "
Sleep 500ms

# Quit
Type "q"
Sleep 400ms
