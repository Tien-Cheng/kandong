# Readings and glosses come from an offline dictionary first; AI only corrects

Reading and Word breakdown are computed instantly from bundled CC-CEDICT with a dictionary-driven segmenter, and the AI is asked only for Translation, context-dependent reading corrections (多音字 like 了, 行, 得) and Explanations. This keeps the tool useful with no Backend configured, makes the first paint instant, and avoids the model inventing pinyin; corrected readings are highlighted so the user sees where the AI disagreed with the dictionary.

## Update: how much the AI may change readings depends on the Backend

Each Backend has a **Reading corrections** setting:
- **Off:** the dictionary's readings stand.
- **Choose:** for every word CC-CEDICT reads more than one way, the model picks one of CC-CEDICT's readings, enforced by an enum in the reply schema. It can't make one up.
- **Free:** the model names any reading it thinks is wrong and writes the right one.

We measured both modes with `KandongEval` on 39 多音字 sentences, 12 of which the dictionary gets wrong:

| Backend | Free | Choose |
|---|---|---|
| Codex | fixed 12, 0 worse | 11 (一行 has no right option in CC-CEDICT) |
| Gemma 4 12B | fixed 6, 1 worse | 6, 1 worse |
| Gemma 4 E4B | fixed 0 | 9, 3 worse |
| Apple Intelligence | fixed 0 | 4, 0 worse |

Small models make up readings or change nothing when free, and a fixed list helps them. A strong model is held back by the list. So Apple Intelligence and Backends on this Mac default to Choose, Codex and hosted Backends to Free, and the user can change it per Backend.

## Update: Reverse gets context readings too

A Reverse Lookup's Chinese is written by the model, and its Reading used to keep the dictionary's pinyin (我们还没测过 showed 还 as huán). Choose needs the Chinese's words to build its enum, and they don't exist until the reply does, so the readings can't be asked in the same request. Once the Chinese is in, Kandong sends the same Backend a second, readings-only request in its Reading corrections mode, with the English for meaning and no Translation. The Reading shows the dictionary's pinyin at once and updates when the answer lands. Nothing is sent when the mode is Off, no word has more than one reading, or the request doesn't fit; if it fails, the dictionary's readings stand and the Chinese is still shown.
