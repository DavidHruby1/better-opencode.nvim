# PRD: safe inline Build workflow

## Status

This is the product contract for v2.0. `docs/ARCHITECTURE.md` describes the implementation and
`docs/ACCEPTANCE.md` describes release acceptance.

The plugin is Build-only. Plan mode, an attached OpenCode TUI, a sidebar, and tmux integration are not supported.
Passing `mode = "plan"` fails with `mode_unavailable`; it is never silently converted to Build.

## Product

The plugin runs one owned headless OpenCode Server for each canonical project root. A user opens a Build prompt or
dispatches one directly. OpenCode returns a structured replacement for one authorized scope. The plugin validates the
proposal, merges Base/Ours/Theirs, and changes only the live Neovim buffer. It does not write the merged result to disk.

Verified managed Sessions can be selected, resumed for another Build, or deleted through a Snacks picker. Multiple
Build Jobs may run in separate Sessions when their scopes do not overlap.

## Requirements

- Neovim is the primary UI. Prompt, Session picker, questions, permissions, conflicts, status, and diagnostics are
  native Neovim/Snacks surfaces.
- Runtime startup and normal use work without `$TMUX`, `$TMUX_PANE`, `tmux`, or `opencode attach`.
- OpenCode support is exact: only `1.17.3` and `1.18.9` pass compatibility preflight.
- The plugin starts and owns its Server. It never discovers, attaches to, or terminates an unverified foreign Server.
- Build uses the OpenCode primary `build` agent and JSON-schema structured output.
- Build tools are default-denied. Source-writing, shell, task, unknown, and custom tools cannot bypass proposal review.
- Every Build targets one visual range, recognized function, or whole-file fallback.
- Scope enforcement uses the Base-to-Theirs diff, not prompt wording or highlighting.
- Dirty target/context buffers are saved before dispatch so Base and disk agree.
- A clean merge is one undo step, leaves the live buffer modified, and does not call write, reload, `:edit`, or
  `checktime`.
- UTF-8, final-newline state, trailing empty lines, file format, and empty files are preserved.
- Disk changes, stale buffer state, invalid proposals, unknown events, and ownership uncertainty fail closed.
- Default logs, notifications, diagnostics, and release artifacts contain metadata only. They omit prompts, source,
  reasoning, replacements, diffs, credentials, response bodies, and absolute paths.

## Public Workflow

1. `ask()` captures the current visual/function/file scope and opens the Build editor.
2. `prompt()` captures the same context and dispatches Build without opening the editor.
3. `select_session()` opens the managed reusable-Session picker and resumes Build after selection.
4. `cancel()` cancels one active Job; `cancel_all()` cancels a snapshot of all active Jobs.
5. `select()` is recovery-only and offers Runtime restart or safe diagnostics.
6. `statusline()` returns the current one-line status text.

The prompt starts at one row, soft-wraps as it grows, submits with `<CR>`, inserts a newline with `<S-CR>` or `<C-j>`,
and cancels with `<Esc>`.

## Non-goals

- Plan mode or Plan-to-Build workflow
- TUI transcript, tmux pane, or external Server attach
- direct agent writes to the source workspace
- multi-file, create, delete, rename, or binary edits
- worktree or branch orchestration
- blockwise visual Build
- custom command execution, prompt history, or model picker
- automatic persistence of merged buffer changes

## Release

Release acceptance runs all automated acceptance, privacy, and authenticated real-server E2E checks against both exact
official binaries. The whole-file E2E must prove UTF-8 content, final newline, live-buffer mutation, unchanged disk, a
terminal completed Job, and metadata-only failure diagnostics. Patched or fake binaries cannot produce release evidence.
