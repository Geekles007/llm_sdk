# GIF : « changer de provider = 1 ligne ».
# Montre le MÊME fichier dont seule la ligne provider change.
# Rendu :  vhs tool/gif/swap.tape
# NB : ce tape mute tool/gif/swap.dart (sed) — restauré après rendu.
Output doc/swap.gif

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 18
Set Width 980
Set Height 560
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 45ms

# 1) Claude
Type "bat -pp --color=always tool/gif/swap.dart"
Sleep 400ms
Enter
Sleep 2800ms

# 2) → OpenAI
Ctrl+L
Type "sed -i '' 's/ClaudeProvider/OpenAIProvider/' tool/gif/swap.dart && bat -pp --color=always tool/gif/swap.dart"
Sleep 400ms
Enter
Sleep 2800ms

# 3) → Gemini
Ctrl+L
Type "sed -i '' 's/OpenAIProvider/GeminiProvider/' tool/gif/swap.dart && bat -pp --color=always tool/gif/swap.dart"
Sleep 400ms
Enter
Sleep 3000ms
