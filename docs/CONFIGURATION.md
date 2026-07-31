# Configuration

Set `vim.g.opencode_opts` before the first plugin command. Unsupported keys and invalid types are reported by `:checkhealth opencode` and are not merged into runtime options. A restart is the safest way to apply changes to startup and transport settings.

## Supported options

| Key | Default | Type | Scope | Restart |
|---|---|---|---|---|
| `runtime.binary` | `"opencode"` | string | executable used for owned Server/TUI | yes |
| `runtime.startup_timeout` | `10000` | positive integer | owned Server health poll, milliseconds | yes |
| `runtime.shutdown_timeout` | `2000` | positive integer | owned process cleanup, milliseconds | yes |
| `runtime.reconnect.max_attempts` | `5` | positive integer | SSE reconnect limit | no |
| `runtime.reconnect.backoff_ms` | `100` | positive integer | first reconnect delay | no |
| `runtime.reconnect.max_backoff_ms` | `2000` | positive integer | reconnect delay cap | no |
| `sidebar.width` | `0.30` | number from `0.05` to `0.95` | shared sidebar width fraction | no |
| `contexts` | built-ins | table of string to function | context placeholder overrides | yes |
| `ask.completion` | `"customlist,v:lua.opencode_completion"` | string | prompt completion option | yes |
| `ask.snacks` | built-in Snacks input options | table | options passed to `snacks.input` | yes |
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
  sidebar = { width = 0.30 },
  notify = { enabled = true, opts = { timeout = 3000 } },
}
```

`contexts` replaces or extends the built-in `@this`, `@buffer`, `@buffers`, `@visible`, `@diagnostics`, `@quickfix`, and `@marks` functions. The plugin does not provide a provider framework, content-debug logging, telemetry, or an option for external Server attachment.

The documented keys are checked against `lua/opencode/config.lua` by the release test suite.
