# Real profile Build E2E

`run.sh` uses the selected official OpenCode binary and an existing `opencode auth login` credential. It copies only
`auth.json` into disposable config/data directories and drives public Build workflows through the owned Server without a
TUI attach. The whole-file scenario verifies exact UTF-8 text, final-newline preservation, live-buffer mutation, unchanged
disk bytes, terminal completion, and metadata-only failure diagnostics.

The private tmux server exists only to deliver real prompt key mappings to Neovim. tmux is not a plugin Runtime
dependency, and the E2E does not run `opencode attach` or create a TUI pane.

```sh
SNACKS_PATH=/path/to/snacks.nvim OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
SNACKS_PATH=/path/to/snacks.nvim PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
```

Set `OPENCODE_E2E_MODEL` only when the authenticated provider needs a different model. No `OPENCODE_API_KEY` is required.
Patched, wrapped, or fake binaries are diagnostic only and cannot count as release evidence.
