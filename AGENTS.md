# opencode.nvim — agent guide

## What it is

A Neovim Lua plugin that bridges Neovim and the `opencode` CLI (external binary). It discovers or starts an `opencode` server, communicates via REST + SSE, and provides UI for prompting, context injection, session management, and edit review.

## Entrypoints

- **Public API**: `lua/opencode.lua` — exports `ask()`, `prompt()`, `select()`, `cancel()`, `cancel_all()`, and `statusline()`
- **Config**: `vim.g.opencode_opts` global (not a `setup()` call); merged with defaults from `lua/opencode/config.lua`
- **Plugin files**: `plugin/highlights.lua` sets highlight groups. Runtime SSE events are routed directly to root-owned Sessions, Jobs, and the interaction queue.

## Config quirks

- Config is passed via `vim.g.opencode_opts`; supported keys are documented in `docs/CONFIGURATION.md` and validated at startup.
- `ask.snacks.win` customizes the multiline `Snacks.win` prompt; lifecycle callbacks, required buffer options, and clamped geometry remain plugin-owned.

## Dependencies

- **Required**: Neovim 0.11+, exact OpenCode `1.17.3` or `1.18.9`, `curl`, `git merge-file`, and `snacks.nvim`
- No hard Lua dependencies beyond Neovim itself

## Verification commands

```bash
# Type-check (requires neovim + lua-language-server + cloned snacks/blink)
lua-language-server --configpath .luarc.ci.json --check=.

# Format check
stylua --check .

# Format in place
stylua .
```

## CI

- **`.github/workflows/lua-ls.yml`**: type-check on push/PR to main
- **`.github/workflows/stylua.yml`**: format check on push/PR to main
- **`.github/workflows/release-please.yml`**: automated releases via release-please (non-fork, main branch only)

## Testing

- MiniTest suites live under `tests/unit`, `tests/integration`, and `tests/contract`; `tests/e2e` covers both exact OpenCode profiles.
- Release validation and evidence generation live under `tests/release`.
- Manual verification: `:checkhealth opencode`

## Formatting (StyLua)

- `column_width = 120`, `indent_width = 2`, spaces, double quotes, no call parentheses
- File: `.stylua.toml`

## Type-checking (LuaLS)

- Config: `.luarc.ci.json`
- Runtime: `LuaJIT`
- Library paths: `/opt/nvim/share/nvim/runtime/lua`, cloned `snacks.nvim` and `blink.cmp`

## Architecture notes

- **Async**: custom Promise implementation in `lua/opencode/promise/init.lua` (fork of `promise.nvim`)
- **Runtime ownership**: one isolated Server is started per canonical project root; foreign processes are never attached or stopped. Legacy TUI identities are cleaned only from old manifests.
- **Context system** (`lua/opencode/context/init.lua`): captures buffer, window, cursor, and selection before UI opens and renders configured context placeholders.
- **Events**: each Runtime owns one authenticated SSE stream and routes events by exact Session, message, request, Job, and root identity.
- **Edit review**: Build proposals use Base/Ours/Theirs merge and change only the live buffer. Agent conflicts use four scratch buffers; external conflicts compare buffer and disk in a scratch tab.
- **Safety**: Build is the only prompt workflow, tool permissions fail closed, dirty files are saved before dispatch, and stale generations or disk changes block apply.

## Project vision

See [CONTRIBUTING.md](./CONTRIBUTING.md) for project guidelines, priorities, and maintenance philosophy. When in doubt, follow the patterns already in the codebase.
