# Hero: launch, home feed loads, scroll, zebra + colored handles visible.
Output demos/out/home.gif
Output demos/out/home.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1600
Set Height 960
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0

Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 5s
Screenshot demos/out/home-initial.png
Type "jjjjj"
Sleep 800ms
Type "jjjjj"
Sleep 800ms
Screenshot demos/out/home-scrolled.png
Type "kkkkkk"
Sleep 1s
Type "q"
Sleep 400ms
