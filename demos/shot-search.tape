Output demos/shots/_search.gif

Set Shell "bash"
Set FontSize 27
Set Width 1920
Set Height 1180
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 7s
Show
Sleep 1s
Type ":search 東京"
Enter
Sleep 6s
Type "T"
Sleep 4s
Screenshot demos/shots/search.png
Type "q"
Sleep 200ms
