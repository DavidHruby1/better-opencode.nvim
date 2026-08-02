# Commands

## Summary

The plugin does not ship default keymaps. The README examples use a `<leader>o*` namespace.

## Public API

- `require("opencode").ask(default?, opts?)`: opens the Build prompt window. `mode = "plan"` is rejected with `mode_unavailable`; omitted mode and `mode = "build"` use the same flow.
- `require("opencode").prompt(text, opts?)`: dispatches an immediate Build without opening the prompt window.
- `require("opencode").select_session(opts?)`: opens the reusable-session picker, then resumes Build with the captured context.
- `require("opencode").select()`: recovery menu with `Restart runtime` and `Show diagnostics`.
- `require("opencode").cancel()`: cancels the active Job, or opens a Job picker when more than one is running.
- `require("opencode").cancel_all()`: cancels every active Job.
- `require("opencode").statusline()`: returns the current status text.

## Suggested mappings

- `<leader>oi`: `require("opencode").select_session({ mode = "build" })`
- `<leader>od` (normal/visual): `require("opencode").prompt("Implement the current target safely and return the required structured replacement.", { mode = "build", new_session = true })`

## Build prompt keys

- `<CR>` submits or accepts visible completion.
- Shift+Enter (`<S-CR>`) inserts a newline.
- `<C-j>` is the newline fallback.
- `<Esc>` cancels.
