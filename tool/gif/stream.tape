# GIF : effet machine à écrire via LlmClient.streamText (vrai code SDK).
# Rendu :  vhs tool/gif/stream.tape
Output doc/stream.gif

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 24
Set Width 1100
Set Height 360
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 55ms

# Préchauffe le compilateur incrémental hors caméra pour un rendu net.
Hide
Type "dart run tool/gif/stream_demo.dart"
Enter
Sleep 4s
Ctrl+L
Show

Type "dart run tool/gif/stream_demo.dart"
Sleep 500ms
Enter
Sleep 4s
