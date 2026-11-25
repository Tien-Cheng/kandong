# Long text is read in passages, and the Reading is drawn with Core Text

Text of more than about 120 Chinese characters is split into Passages (a paragraph each; long paragraphs are cut at sentence ends, and lines a screenshot or PDF wrapped are rejoined). Each is shown as its Reading with its Translation beneath it, in a lazy stack. Before, the whole Reading came first and the whole Translation after it, thousands of points further down.

## The Reading is one view per Passage

A SwiftUI view for each word (a button holding stacks of pinyin and characters) costs about ten views a word. Lazy loading alone doesn't help enough: bringing one 75-word Passage on screen took 55–70 ms, several dropped frames. `ReadingLayout` (in KandongKit, so line breaking and the shared baseline are unit-tested) works out where everything goes, and `ReadingBlockView` draws it with Core Text. Pointer, tooltips, menus and one accessibility element per word are handled there. Measured with `Kandong --time-panel` (debug build, 5,000 characters):

| | Before | After |
|---|---|---|
| Analysing the text | 264 ms, on the main thread | 75 ms, off it |
| Opening | 3,338 ms | 35 ms |
| ←/→ | 741 ms | 7 ms |
| A streamed update | 94 ms | 4 ms |

Jumping (↑/↓) to a Passage that has no view yet takes up to 50 ms.

## Passages are keyed in the reply

The Backend gets the text as `[p01] …`, `[p02] …` and answers with an object holding one string per key, which the schema enforces. Keys are zero-padded because `JSONValue` encodes objects in sorted order, and servers write their reply in the schema's order. Whatever passages come back are kept: a reply that is cut off, or leaves some out or copies them, costs only those, which are asked for once more, four at a time.

A Backend in Choose mode is asked for context readings afterwards, in requests of their own, as Reverse already does (ADR 0003). Asked for both at once, Apple Intelligence copied the Chinese of eight passages instead of translating it and took 57 s; asked to translate only, it got all eight right in 15 s (Gemma 4 E4B: eight of eight in one request, then the readings).

## Considered Options

- Translate the text whole and match its paragraphs up by line breaks: models merge and split lines, and a mismatch shifts every later passage.
- One request per passage: slower on every Backend, and each passage loses the text around it.
- Lazy loading with a lighter SwiftUI view per word: still 30–40 ms a Passage.
