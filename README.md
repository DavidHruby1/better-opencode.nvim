# opencode.nvim inline fork

Neovim-native managed workflow based on `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47`. The upstream project and its license remain the origin of this fork; see `LICENSE` and `CHANGELOG.md`.

This fork owns one loopback OpenCode Server and one input-locked TUI client per canonical project root. Build returns a scoped structured proposal and applies it only to the live buffer through a Base/Ours/Theirs merge. Plan is read-only. The source file is not autosaved.

## Requirements

- Neovim 0.11.0+
- OpenCode exactly `1.17.3` or `1.18.9`
- `curl`
- `git` with `git merge-file -p --diff3`
- `snacks.nvim` with input and picker enabled
- `tmux` with extended keyboard support enabled

OpenCode support is an exact compatibility matrix, not a semver range. Other versions fail the preflight.

## Configuration

```lua
vim.g.opencode_opts = {
  runtime = { binary = "opencode", startup_timeout = 10000 },
  notify = { enabled = true },
  sidebar = { width = 0.30 },
}

-- Primary Build
vim.keymap.set({ "n", "x" }, "<leader>op", function()
  require("opencode").ask()
end)

-- Optional Build alias
vim.keymap.set({ "n", "x" }, "<C-a>", function()
  require("opencode").ask()
end)

-- Explicit read-only Plan
vim.keymap.set({ "n", "x" }, "<leader>oP", function()
  require("opencode").ask(nil, { mode = "plan" })
end)

-- Session actions, cancel one/all, sidebar, and diagnostics
vim.keymap.set("n", "<leader>os", function()
  require("opencode").select()
end)
vim.keymap.set("n", "<leader>oc", function()
  require("opencode").cancel()
end)
vim.keymap.set("n", "<leader>oC", function()
  require("opencode").cancel_all()
end)
vim.keymap.set("n", "<leader>ot", function()
  local runtime = require("opencode.runtime").current()
  if runtime then runtime.sidebar:toggle() end
end)
vim.keymap.set("n", "<leader>of", function()
  local runtime = require("opencode.runtime").current()
  if runtime then runtime.sidebar:focus() end
end)
```

The multiline prompt opens while OpenCode starts. `<CR>` submits or accepts visible completion, `<S-CR>` inserts a newline, `<C-j>` is the terminal-safe newline fallback, and `<Esc>` cancels. Failed startup or dispatch keeps the text available for retry.

### Terminal transport setup

Modified Enter keys must survive every layer between the terminal and Neovim. For WezTerm, enable the Kitty keyboard protocol:

```lua
config.enable_kitty_keyboard = true
```

In tmux, enable extended keys and attach the `extkeys` feature to the actual client terminal name, not an assumed `$TERM` value:

```sh
tmux set -g extended-keys on
tmux display-message -p '#{client_termname}'
tmux set -as terminal-features ',<actual-client_termname>:extkeys'
```

Put the equivalent `set` lines in `~/.tmux.conf` for future sessions, replacing `<actual-client_termname>` with the exact output from `display-message`. Restart the tmux client after changing terminal transport settings, then run `:checkhealth opencode` inside tmux. If `<S-CR>` is unavailable, use `<C-j>` for a newline.

To reproduce the full path, start WezTerm with Kitty keyboard support, enter WSL, attach tmux, start Neovim, and try `<S-CR>` in the multiline prompt. This verifies the raw WezTerm -> WSL -> tmux -> Neovim input transport. A direct Lua call to the prompt's newline callback checks only the callback and does not verify that raw key input reaches it.

The select menu provides Session selection, cancel current Job, cancel all Jobs, TUI attach retry, sidebar toggle/focus, runtime restart, and metadata-only diagnostics. Run `:checkhealth opencode` for dependencies and the selected compatibility profile.

## Safety model

- Build and Plan use ordered Session rules with a default deny and explicit read-only allowlist. Both exact profiles filter hard-denied and unknown tools from the final model surface and apply execution-time hard deny on a fresh isolated Server.
- Passive config guards ignore custom plugins and enabled MCPs, while rejecting custom tools before startup; effective config is checked without calling `/mcp`.
- Dirty buffers require explicit `save and continue` or `cancel`. Clean merge changes only the buffer, preserves `modified`, and is one undo step.
- External disk changes, conflicts, stale changedticks, scope violations, unknown events, and unowned processes fail closed.
- Default logs and notifications contain metadata only. They omit prompts, source, diffs, replacements, credentials, response bodies, and absolute paths.

## Workflow

- Build defaults to the current function, visual range, or file fallback. Plan must be selected explicitly.
- A conflict offers `keep my changes`, `accept agent changes`, or `open manual diff`. External changes offer `open external diff`, `retry apply`, or `cancel`.
- A Plan Session can be reused for a new Build after it becomes reusable. Active Sessions never queue a follow-up.
- Parallel non-overlapping Build scopes are allowed in one buffer. Overlap is rejected before dispatch and rechecked before application.
- Multiple canonical roots have separate Servers, Sessions, Jobs, and event streams; at most one lazy tmux pane shows the selected root's TUI.

## Deferred

Multi-file changes, create/delete/rename, blockwise selection, worktrees, external Server attach, prompt input history, managed custom commands, model picker, and additional OpenCode versions are outside v2.0.

## Maintainer checks

```sh
stylua --check .
lua-language-server --configpath .luarc.ci.json --check=.
MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"
OPENCODE_VERSION=1.17.3 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.18.9 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
nvim --headless -u NONE -c "luafile tests/release/validate.lua" -c 'qa!'
nvim --headless -u NONE -c "lua assert(dofile('tests/release/evidence.lua').generate('.', 'tests/release/results/index.lua', 'docs/release/v2.0-evidence.md'))" -c 'qa!'
```

CI runs the same unit, integration and per-profile contract commands with Neovim 0.11.0, then verifies installation of both exact OpenCode binaries. Release evidence is FAIL until every result artifact and manual protocol is captured for both profiles.
