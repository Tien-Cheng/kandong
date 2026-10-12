# Kandong

A personal macOS tool for learning Chinese from text met every day: look up any selected text, screenshot or clipboard content and get readings, word meanings, translation and explanations.

## Lookups

**Lookup**:
One request by the user to understand a piece of text, producing a Result.
_Avoid_: Query, translation request

**Source**:
Where a Lookup's text came from: a *Selection*, a *Screen capture*, or the *Clipboard*.
_Avoid_: Input

**Direction**:
Whether a Lookup is *Learn* (Chinese → English) or *Reverse* (English → Chinese); inferred from the text.
_Avoid_: Mode, language pair

**Result**:
Everything shown for one Lookup: Reading, Word breakdown, Translation and, on request, Explanation.

**Reading**:
The text with pinyin shown above each character, coloured by tone.
_Avoid_: Ruby, pinyin view

**Word breakdown**:
The text split into words, each with its pinyin, gloss and HSK level.
_Avoid_: Segmentation, word list

**Translation**:
A natural rendering of the whole text in the other language.

**Explanation**:
Grammar and usage notes about the text, produced only when asked for.
_Avoid_: Analysis, breakdown

**Pass-through token**:
A non-Chinese fragment (English word, @mention, hashtag, URL) left untouched: no pinyin, no gloss.

## Steering

**Term**:
A user-defined fixed English rendering of a Chinese expression, used to steer Translation. Not study material.
_Avoid_: Glossary entry, dictionary entry

**Context**:
Free-text description of the user and what they read, sent with every AI request.
_Avoid_: Profile, system prompt

**Backend**:
One AI endpoint the user can choose to answer Lookups, e.g. "Apple Intelligence", "Codex" or "Ollama · qwen3". The user can add several. The *Default backend* answers normally; the *Local backend*, which must run on this Mac, answers when the user holds ⇧.
_Avoid_: Provider, model

**Backend type**:
How Kandong talks to a Backend: *Apple Intelligence* (Apple's model on this Mac), *Codex*, or *OpenAI-compatible* (LM Studio, Ollama, hosted APIs). Apple Intelligence and Codex exist once each; OpenAI-compatible Backends are added from presets.

## Learning

**Vocabulary**:
Words the user is learning, each saved with the sentence it was found in.
_Avoid_: Flashcards, saved words, word bank

**Encounter**:
A later Lookup whose text contains a Vocabulary word.

**My level**:
The HSK band at or below which words count as already known.

**Workspace**:
The user-visible folder holding Context, Terms and Vocabulary as plain files.
_Avoid_: Config dir, data folder
