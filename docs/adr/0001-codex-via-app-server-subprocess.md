# Codex is driven through the `codex app-server` subprocess

We talk to Codex by launching the user's installed `codex` CLI as `codex app-server` and speaking JSON-RPC over stdio, rather than calling OpenAI's API with a key or reading `~/.codex/auth.json`. This reuses the user's ChatGPT subscription and `codex login`, so the app holds no credentials; the cost is a dependency on the app-server protocol, which may change between Codex versions. Agent features (shell, plugins, MCP, memories) are switched off with `-c` overrides so a Lookup is a plain completion.
