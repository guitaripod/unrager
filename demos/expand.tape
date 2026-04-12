# Expand a tweet body in place with x.
Output demos/out/expand.gif
Output demos/out/expand.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1600
Set Height 960
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 5s
Type "jj"
Sleep 400ms
Type "x"
Sleep 1500ms
Screenshot demos/out/expand.png
Type "x"
Sleep 500ms
Type "q"
Sleep 400ms
