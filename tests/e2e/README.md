# Real profile public ask e2e

`run.sh` uses the selected real OpenCode binary and an existing `opencode auth login` credential. It copies only `auth.json` into disposable config/data directories, drives the public one-line Build prompt through the owned Server without a TUI attach, applies the Build only to the live buffer, verifies that the source fixture did not change, and removes the temporary credential on exit.

```sh
SNACKS_PATH=/path/to/snacks.nvim OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
SNACKS_PATH=/path/to/snacks.nvim PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
```

Set `OPENCODE_E2E_MODEL` only when the authenticated provider needs a different model. No `OPENCODE_API_KEY` is required.
