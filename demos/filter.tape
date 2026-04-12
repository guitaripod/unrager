# Rage filter in action: default on, then toggle off to show what was hidden.
Output demos/out/filter.gif
Output demos/out/filter.mp4

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
Screenshot demos/out/filter-on.png
Type "c"
Sleep 2s
Screenshot demos/out/filter-off.png
Type "c"
Sleep 2s
Type "q"
Sleep 400ms
