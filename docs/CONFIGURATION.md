# Configuration

Set `vim.g.opencode_opts` before the first plugin command. Unsupported keys and invalid types are reported by `:checkhealth opencode` and are not merged into runtime options. A restart is the safest way to apply changes to startup and transport settings.

## Supported options

| Key | Default | Type | Scope | Restart |
|---|---|---|---|---|
| `runtime.binary` | `"opencode"` | string | executable used for owned Server/TUI | yes |
| `runtime.startup_timeout` | `10000` | positive integer | full owned Runtime readiness deadline, milliseconds | yes |
| `runtime.shutdown_timeout` | `2000` | positive integer | owned process cleanup, milliseconds | yes |
| `runtime.reconnect.max_attempts` | `5` | positive integer | SSE reconnect limit | no |
| `runtime.reconnect.backoff_ms` | `100` | positive integer | first reconnect delay | no |
| `runtime.reconnect.max_backoff_ms` | `2000` | positive integer | reconnect delay cap | no |
| `sidebar.width` | `30` | integer from `5` to `95` | width percentage for the shared right tmux pane | no |
| `contexts` | built-ins | table of string to function | context placeholder overrides | yes |
| `ask.snacks.win` | bounded float defaults | table | `Snacks.win` appearance and safe window overrides | yes |
| `notify.enabled` | `true` | boolean | metadata notification enable switch | no |
| `notify.opts` | `{}` | table | standard `vim.notify` options | no |

Example:

```lua
vim.g.opencode_opts = {
  runtime = {
    binary = "/usr/local/bin/opencode",
    startup_timeout = 10000,
    reconnect = { max_attempts = 5, backoff_ms = 100, max_backoff_ms = 2000 },
    shutdown_timeout = 2000,
  },
  sidebar = { width = 30 },
  ask = { snacks = { win = { border = "rounded", width = 72 } } },
  notify = { enabled = true, opts = { timeout = 3000 } },
}
```

`ask.snacks.win` is merged into the multiline prompt's `Snacks.win` options. Width, height, and placement are clamped to the usable editor; the scratch buffer, mode/root/scope title, submit keys, lifecycle callbacks, and no-history behavior remain plugin-owned.

`sidebar.width` is passed to `tmux split-window` as a percentage. The plugin lazily creates one detached right pane across all project roots, disables direct input to it, and focuses it only after the explicit Focus sidebar action.

`contexts` replaces or extends the built-in `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix`, and `@marks` functions. The plugin does not provide a provider framework, content-debug logging, telemetry, or an option for external Server attachment.

The documented keys are checked against `lua/opencode/config.lua` by the release test suite.
