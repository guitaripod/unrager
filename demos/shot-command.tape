Output demos/shots/_command.gif

Set Shell "bash"
Set FontSize 27
Set Width 1920
Set Height 1180
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.2

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 8s
Show
Sleep 1s

# Open command palette and partially type a query to capture auto-hints
Type ":"
Sleep 400ms
Type "search "
Sleep 800ms
Screenshot demos/shots/command.png

# Finish the command and close
Type "rust programming"
Sleep 400ms
Escape
Sleep 400ms
Type "q"
Sleep 200ms
