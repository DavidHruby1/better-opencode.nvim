# opencode.nvim inline fork

Neovim-native managed workflow built from `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47`.

The current F01-F02 slice:

- starts one plugin-owned OpenCode `1.17.3` or `1.18.9` Server for the canonical project root,
- verifies passive and effective config, exact OpenAPI operations, process ownership and routed authentication,
- starts one `opencode attach --dir <root>` terminal as an input-locked right sidebar,
- dispatches read-only Plan turns through the Session HTTP API,
- preserves `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix` and `@marks`,
- saves explicitly referenced dirty file buffers only after one `save and continue` confirmation.

Build, direct TUI input, external Server attachment, Session reuse and source application are intentionally unavailable in this slice.

## Requirements

- Neovim 0.11.0+
- `opencode` exactly `1.17.3` or `1.18.9`
- `curl`
- `snacks.nvim` with input and picker enabled

## Configuration

```lua
vim.g.opencode_opts = {
  runtime = { startup_timeout = 10000 },
  sidebar = { width = 0.30 },
}

vim.keymap.set({ "n", "x" }, "<C-a>", function()
  require("opencode").ask(nil, { mode = "plan" })
end)
vim.keymap.set("n", "<leader>ot", function()
  local runtime = require("opencode.runtime").current()
  if runtime then runtime.sidebar:toggle() end
end)
```

## Maintainer checks

```sh
stylua --check .
lua-language-server --configpath .luarc.ci.json --check=.
MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"
OPENCODE_VERSION=1.17.3 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.18.9 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
```

CI runs the same unit, integration and per-profile contract commands with Neovim 0.11.0, then verifies installation of both exact OpenCode binaries.
