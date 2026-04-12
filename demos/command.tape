# Command palette: :user jack, :search rust, back to :home.
Output demos/out/command.gif
Output demos/out/command.mp4

Set Shell "bash"
Set FontSize 14
Set Width 1600
Set Height 960
Set Padding 20
Set Margin 0
Set Theme "Catppuccin Mocha"
Set TypingSpeed 70ms

Hide
Type "UNRAGER_DISABLE_KITTY=1 ./target/release/unrager"
Enter
Sleep 5s
Show
Type ":user jack"
Sleep 800ms
Enter
Sleep 5s
Show
Screenshot demos/out/command-user.png
Type ":search rust lang"
Sleep 800ms
Enter
Sleep 5s
Show
Screenshot demos/out/command-search.png
Type ":home"
Sleep 500ms
Enter
Sleep 4s
Show
Type "q"
Sleep 400ms
