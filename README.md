# Kandong 看懂

A macOS menu-bar tool for learning Chinese from the text you meet every day. Highlight Chinese anywhere — or snap a screen region, or copy an image — and get:

- **Reading**: the text with tone-coloured pinyin above each character (instant, offline)
- **Words**: each word with pinyin, gloss and HSK level; ★ to save it to your Vocabulary
- **Translation**: natural English from your AI backend, steered by your Terms and Context
- **Explain**: on-demand grammar and usage notes

Highlight English instead and it shows how to say it in Chinese. See [GLOSSARY.md](GLOSSARY.md) for the vocabulary used in the code and [docs/adr](docs/adr) for the main decisions.

## Build and install

Needs macOS 26+ and the Xcode Command Line Tools (full Xcode isn't required).

```sh
scripts/make-signing-identity.sh   # once: stable self-signed identity, so permissions survive rebuilds
scripts/build-app.sh --install     # downloads dictionary data, builds, installs to ~/Applications, launches
```

On first launch, grant **Accessibility** (to read selected text and the tap key). **Screen Recording** is needed for region capture. Tests: `swift test`. Live Codex round-trips: `KANDONG_LIVE=1 swift test --filter LiveCodexTests`.

## Use

| Shortcut | Action |
|---|---|
| tap right ⌘ | Look up the selection (tap key can be changed in Settings — right ⌥ / ⌃ or off) |
| ⌃⌥L | Look up the selection |
| ⌃⌥S | Capture a screen region |
| ⌃⌥V | Look up the clipboard (image or text) |
| add ⇧ | …using the Local backend instead (e.g. for private messages) |

All shortcuts can be changed in Settings. Esc closes the panel, 📌 keeps it open, and clicking a word reads it aloud. Lookups can also be scripted: `open "kandong://lookup?text=你好"`, `kandong://clipboard`, `kandong://selection`, `kandong://capture`, each optionally with `&local=1`.

## AI backends

- **Codex** (default) uses your ChatGPT subscription through the installed `codex` CLI (`codex app-server`). Sign in once with `codex login`.
- **LM Studio** runs fully on this Mac. Start its server (`lms server start`) and pick a model in Settings. Vision models are detected automatically, so screenshots go to the model; for text-only models, Kandong reads images with Apple's on-device OCR.
- **Other OpenAI-compatible servers** (Ollama, hosted APIs): set a URL, model and optional key (stored in the Keychain).

## Workspace: Context, Terms, Vocabulary

Plain files in `~/.config/kandong/` (the folder can be changed in Settings). Edits — yours or your agents' — apply to the next lookup:

- `context.md`: who you are and what you read. It is sent with every request.
- `terms.csv` (`chinese,english,note`): fixed translations for names, slang and set phrases.
- `vocabulary.csv`: saved words with the sentence they came from. Anki can import it directly.

History and repeat-sighting counts are kept in `~/Library/Application Support/Kandong/history.sqlite` (90 days by default).

## Data

Dictionary: [CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cc-cedict) (CC BY-SA 4.0). HSK 3.0 levels: [complete-hsk-vocabulary](https://github.com/drkameleon/complete-hsk-vocabulary) (MIT). Both are downloaded by `scripts/fetch-data.sh` and not committed.

## License

Code: [MIT](LICENSE). The dictionary data keeps its own licenses above; a built `Kandong.app` bundles it, so keep those notices if you redistribute the app.
