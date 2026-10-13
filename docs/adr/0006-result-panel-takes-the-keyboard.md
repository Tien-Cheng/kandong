# The Result panel takes the keyboard, without activating Kandong

The panel is a non-activating `NSPanel` that becomes key when it opens, the way Spotlight does: the app the user was reading stays the active app, but keys typed while the panel is open go to the panel. That gives the panel a keyboard model (←/→ through words, Space to say, S to save, E to explain, Esc to let go of a word and then close) and makes it reachable with VoiceOver and Full Keyboard Access, which a panel that never takes focus is not. Clicking back into the other app closes the panel unless it's pinned, so focus returns there.

A consequence: while the panel has the keyboard, the copy-to-read fallback for apps without accessibility support (it posts ⌘C) would copy from the panel. So a second tap of the lookup key while the panel has the keyboard never reads the selection again: it flips mixed Chinese and English to the other Direction, or closes the panel.

## Considered Options

- Never take focus (the old `becomesKeyOnlyIfNeeded`): keystrokes stay in the reading app, but the panel has no keys besides a global Esc and is out of reach for keyboard and VoiceOver users.
- Activate Kandong when the panel opens: simplest focus handling, but it pulls the user out of the app they're reading and changes the menu bar.
