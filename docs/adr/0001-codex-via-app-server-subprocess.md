# Codex is driven through the `codex app-server` subprocess

Superseded by [ADR 0008: Direct ChatGPT plan sign-in](0008-direct-chatgpt-plan-sign-in.md). The Codex Backend was removed after direct sign-in and inference were verified.

We talk to Codex by launching the user's installed `codex` CLI as `codex app-server` and speaking JSON-RPC over stdio, rather than calling OpenAI's API with a key or reading `~/.codex/auth.json`. This reuses the user's ChatGPT subscription and `codex login`, so the app holds no credentials; the cost is a dependency on the app-server protocol, which may change between Codex versions. Agent features (shell, plugins, MCP, memories) are switched off with `-c` overrides so a Lookup is a plain completion.
