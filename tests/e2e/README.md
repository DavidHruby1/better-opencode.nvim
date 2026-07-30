# Real profile Plan e2e

`run.sh` uses the selected real OpenCode binary and an existing `opencode auth login` credential. It copies only `auth.json` into disposable config/data directories, runs owned serve + attach + Plan + correlated completion + shutdown, verifies that the source fixture did not change, and removes the temporary credential on exit.

```sh
OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
```

Set `OPENCODE_E2E_MODEL` only when the authenticated provider needs a different model. No `OPENCODE_API_KEY` is required.
