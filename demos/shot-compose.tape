Output demos/shots/_compose.gif

Set Shell "bash"
Set FontSize 27
Set Width 1920
Set Height 1180
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set PlaybackSpeed 1.2

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 8s
Show
Sleep 1s

# Select a tweet, open reply composer (Vim-mode editor)
Type "jj"
Sleep 300ms
Type "r"
Sleep 1500ms
Type "what a thoughtful thread"
Sleep 800ms
Screenshot demos/shots/compose.png

# Exit cleanly without posting: Esc to Normal, then :q style cancel via Esc again
Escape
Sleep 300ms
Escape
Sleep 300ms
Escape
Sleep 500ms
Type "q"
Sleep 200ms
