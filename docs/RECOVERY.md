# Recovery

Run `:checkhealth opencode` first. Health reports only safe capability names, config source scopes, exact OpenCode profile, fixture SHA, and actionable fixes. It does not start MCP, import plugins/tools, discover processes, or print option values.

## Startup or health failure

- Install Neovim `0.11.0` or newer, `curl`, and Git with `git merge-file -p --diff3`.
- Install OpenCode `1.17.3` or `1.18.9`, or set `runtime.binary` to the exact executable.
- Enable `snacks.input` and `snacks.picker`.
- Install the Tree-sitter parser for the active language if function scope is needed. Without it, file scope remains available.
- Fix write permission for Neovim `stdpath("state")`; private Runtime manifests and temporary merge inputs live below `opencode.nvim/`.
- For an unsupported option, use the source scope and type reported by health, then consult `docs/CONFIGURATION.md`.

## Runtime disconnected

Use the select menu's `Restart runtime` only after checking the diagnostic error class. Restart is explicit and reconciles the owned Runtime before prompts reopen. The plugin never attaches to a foreign process.

## Conflicts

- Agent conflict: choose `keep my changes`, `accept agent changes`, or `open manual diff`.
- External disk change: reconcile the disk and current buffer yourself, then use `retry apply` only when the disk exactly matches the current buffer.
- `cancel` leaves the current buffer and disk untouched.
- Never overwrite Ours blindly. The plugin does not autosave, reload, run `:e`, or call `checktime` during apply.

## Orphaned processes

Normal shutdown removes owned manifests. After a hard crash, startup verifies PID identity, executable, credentials, port, canonical root, and ownership before signaling anything. If a check fails, no process is signaled. Keep the diagnostic manifest and inspect the named root manually; do not use `killall`, `pgrep`, blind manifest deletion, reload, or overwrite Ours.

## Data-loss prevention

Build changes remain in the modified buffer and are reversible with one standard undo. Save explicitly when ready. If a stale event, unknown event, invalid proposal, scope violation, changedtick race, disk race, or missing reconciliation result occurs, the Job fails closed and no proposal is applied.
