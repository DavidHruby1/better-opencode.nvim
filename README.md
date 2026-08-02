# opencode.nvim inline fork

Neovim-native managed workflow based on `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47`. The upstream project and its license remain the origin of this fork; see `LICENSE` and `CHANGELOG.md`.

This fork owns one loopback OpenCode Server and one input-locked TUI client per canonical project root. Build returns a scoped structured proposal and applies it only to the live buffer through a Base/Ours/Theirs merge. Dirty files are saved before Build dispatch; applying the proposal still leaves the live buffer modified. Plan is read-only.

## Requirements

- Neovim 0.11.0+
- OpenCode exactly `1.17.3` or `1.18.9`
- `curl`
- `git` with `git merge-file -p --diff3`
- `snacks.nvim` with input and picker enabled
- `tmux` (required for the Plan transcript pane)

OpenCode support is an exact compatibility matrix, not a semver range. Other versions fail the preflight.

## Configuration

```lua
vim.g.opencode_opts = {
  runtime = { binary = "opencode", startup_timeout = 10000 },
  notify = { enabled = true },
  sidebar = { width = 30 },
}

-- Recommended Build: start a new Session and use the default scope resolution
vim.keymap.set({ "n", "x" }, "<C-a>", function()
  require("opencode").ask(nil, { mode = "build", new_session = true })
end)

-- Explicit read-only Plan
vim.keymap.set({ "n", "x" }, "<leader>op", function()
  require("opencode").ask(nil, { mode = "plan" })
end)

-- Recovery actions, cancel one/all, sidebar, and diagnostics
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

The recommended Build mapping captures an active visual selection. In normal mode it uses the function under the cursor and falls back to the full file when no supported function is found; this uses the existing `ask()` API and adds no public function. The multiline prompt uses an upstream-like `Snacks.win` icon and style, keeps metadata compact instead of using a long title, and shows only short temporary states while it starts, submits, or waits for retry. `<CR>` submits or accepts visible completion, `<C-j>` inserts a newline, and `<Esc>` cancels. Failed startup or dispatch keeps the text available for retry.

`select()` is a recovery-only action menu for runtime and TUI problems, not a routine Session-navigation action. `cancel()` opens the active-Job picker when one Job must be chosen, while `cancel_all()` cancels every active Job. Plan creates a managed Session or reuses a selected reusable one, selects its transcript through the internal `/tui/select-session` request, and shows the shared input-locked pane without stealing source focus; the explicit Focus sidebar action is the only action that focuses the pane.

## Safety model

- Build and Plan use ordered Session rules with a default deny and explicit read-only allowlist. Both exact profiles filter hard-denied and unknown tools from the final model surface and apply execution-time hard deny on a fresh isolated Server.
- Passive config guards ignore custom plugins and enabled MCPs, while rejecting custom tools before startup; effective config is checked without calling `/mcp`.
- Dirty buffers are saved automatically before Build; Plan requires explicit `save and continue` or `cancel`. Clean merge changes only the buffer, preserves `modified`, and is one undo step.
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
