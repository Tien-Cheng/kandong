# Context, Terms and Vocabulary live as plain files in a visible Workspace

`context.md`, `terms.csv` and `vocabulary.csv` sit in a user-visible folder (default `~/.config/kandong/`) rather than in an app database, so the user's AI agents can fill in Terms and Context they already know, and Anki can import Vocabulary directly. The app watches the folder and re-reads on change. History and Encounter counts are high-volume, app-written data and stay in SQLite under Application Support, so the app never races an agent editing the CSVs.

## Considered Options

- YAML: nicer multi-line notes, but the app rewriting it destroys user comments.
- Markdown tables: readable, fragile to parse and append to.
