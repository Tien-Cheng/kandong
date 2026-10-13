# Add-on dictionaries are downloaded into the Workspace, not bundled

CC-CEDICT lacks most technical vocabulary (多模态, 大模型, the 多摸 slang for "multimodal"), so Kandong lets the user add dictionaries. An add-on is a CC-CEDICT-format file in the Workspace's `dictionaries/` folder. Its words join CC-CEDICT for splitting text into words, readings and glosses, and are passed to the AI as a glossary. CC-CEDICT's own sense still comes first when both have a word.

The first add-on is the CSET-ETO Chinese Technical Glossary (about 15,000 terms). Its CC BY-NC 4.0 license allows redistribution only for non-commercial use, unlike CC-CEDICT (CC BY-SA) and the HSK list (MIT). Kandong itself is MIT. So the app never ships the glossary: the user downloads it from its published CSV with one click in Settings, and Kandong converts it on their Mac. That keeps the release free of non-commercial data, picks up the glossary's frequent updates without a release, and lets other glossaries, or the user's own, plug in the same way.

## Considered Options

- Bundle ETO in the app or in `scripts/fetch-data.sh`: simplest, but makes every build carry a non-commercial license and freezes the glossary at build time.
- Ask the AI to recognise technical terms: no instant offline Reading, and small models get them wrong (Gemma read 多摸 as "too many").
- A separate file format per glossary: CC-CEDICT's format already holds headword, pinyin and senses, and users can write it by hand.
