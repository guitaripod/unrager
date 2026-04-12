# Detail pane: open a tweet, see the unified focal + replies list.
Output demos/out/detail.gif
Output demos/out/detail.mp4

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
Sleep 6s
Type "jj"
Sleep 500ms
Enter
Sleep 3s
Screenshot demos/out/detail-open.png
Type "jjj"
Sleep 800ms
Screenshot demos/out/detail-reply.png
Type "h"
Sleep 500ms
Type "q"
Sleep 400ms
