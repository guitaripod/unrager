# Filter toggle — tight clip.
Output demos/out/filter.gif

Set Shell "bash"
Set FontSize 14
Set Width 1400
Set Height 850
Set Padding 16
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 7s
Show

Sleep 800ms
Screenshot demos/out/filter-on.png
Type "c"
Sleep 1500ms
Screenshot demos/out/filter-off.png
Type "c"
Sleep 1200ms
Type "q"
Sleep 200ms
