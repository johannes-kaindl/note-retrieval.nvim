# README demo: build the own index of a small vault → the panel of related notes → a search by meaning.
# Reproducible: make demo. Plays on a throw-away copy of tests/fixtures/vault, in a throw-away config,
# state and data folder (XDG_*_HOME) — never your own config, index or notes. Needs an embedding server,
# see docs/demo/init.lua. vhs 0.12 writes 25 fps whatever Set Framerate says; make demo converts this
# raw recording to the 20 fps GIF and MP4 the README embeds.
Output docs/demo/.build/demo.mp4

Set Width 800
Set Height 520
Set FontSize 15
Set TypingSpeed 70ms
Set Padding 12

Hide
Type "R=$PWD; D=/tmp/note-retrieval-demo; rm -rf $D; mkdir $D; cp -R tests/fixtures/vault $D/vault; cd $D/vault; XDG_CONFIG_HOME=$D XDG_STATE_HOME=$D XDG_DATA_HOME=$D nvim -u $R/docs/demo/init.lua Baking/hydration.md" Enter
Sleep 1.5s
Show

Type ":NoteRetrieval reindex" Enter
Wait+Screen@60s /rank 0/
Sleep 1.5s
Type ":NoteRetrieval status" Enter
Sleep 3.5s
Enter
Type ":NoteRetrieval related" Enter
Sleep 3.5s
Set TypingSpeed 40ms
Type ":NoteRetrieval search why does my loaf have big holes" Enter
Sleep 3s
Type "1" Enter
Sleep 3s
