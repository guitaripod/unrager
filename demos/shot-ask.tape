Output demos/shots/_ask.gif

Set Shell "bash"
Set FontSize 27
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
Sleep 1s

# Pick a tweet and ask gemma to explain it
Type "jj"
Sleep 300ms
Type "A"
Sleep 1200ms
Type "1"
Sleep 10s
Screenshot demos/shots/ask.png

Escape
Sleep 400ms
Type "q"
Sleep 200ms
