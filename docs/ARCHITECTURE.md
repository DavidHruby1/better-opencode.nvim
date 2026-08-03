# Build-only architecture

## Runtime Ownership

Each canonical project root owns an isolated Runtime:

```text
Runtime
  owned loopback OpenCode Server
  authenticated HTTP client
  one authenticated SSE stream
  managed Session registry
  correlated Job registry
  interaction queue
```

The Server is started with a random loopback port and random password. Its private ownership manifest records enough
process identity to stop only a proven child. A stale legacy `manifest.tui` identity may be verified and cleaned once;
new Runtime state never creates or attaches a TUI.

Runtime readiness depends on Server health, exact compatibility preflight, routed root identity, effective config,
Build-agent inventory, SSE connection, and reconciliation. It has no tmux or terminal prerequisite.

## Compatibility

Supported profiles are data in `lua/opencode/compat.lua`:

- OpenCode `1.17.3`, commit `8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`
- OpenCode `1.18.9`, commit `4da7bb44c84e013fa53e9c5d02ac753d1435c81a`

Startup verifies the exact version, immutable `/doc` fixture checksum and required operations, `/path` root, `/config`,
and a primary `build` agent. Unknown versions and schema drift fail closed. There is no semver fallback.

Every instance request includes `x-opencode-directory: <canonical-root>`. Session responses and events are accepted only
for their owning Runtime and exact Session/Job identity.

## Public API

`lua/opencode.lua` exports:

- `ask(default?, opts?)`
- `prompt(text, opts?)`
- `select_session(opts?)`
- `select()`
- `cancel()`
- `cancel_all()`
- `operator(text, opts?)`
- `format`
- `statusline()`

Prompt entrypoints accept omitted mode or `mode = "build"`. Other modes return `mode_unavailable`.

## Build Transaction

1. Capture the active file, window, cursor, invocation range, and configured context.
2. Resolve visual, function, or whole-file scope and reject unsupported buffers or overlapping active scopes.
3. Save dirty target/context files and capture Base only after write hooks complete.
4. Create or verify a managed Session and register the Job before `prompt_async`.
5. Send a new OpenCode-compatible user message ID, `agent = "build"`, context parts, and the proposal JSON schema.
6. Correlate SSE events by Runtime, Session, user message, assistant parent, request, and Job generation.
7. Validate one structured replacement, attach canonical target/Base/scope identity locally, and enforce UTF-8 and hard scope.
8. Build Theirs, merge Base/Ours/Theirs with `git merge-file -p --diff3`, and recheck buffer and disk state.
9. Apply one minimal changed span to the live buffer. Never write or reload the source file.

Jobs terminate as `completed`, `cancelled`, `error`, or `scope_violation`; `waiting_user`, `pending_apply`, and `conflict`
are nonterminal states with explicit continuations. Unknown or stale state cannot apply a proposal.

## Text Model

Base, Ours, and Theirs use an LF logical-buffer representation while retaining Neovim's `fileformat`, `endofline`, and
`fixendofline` semantics. The applier preserves UTF-8 byte boundaries, final-newline state, trailing empty lines, and
empty files. A successful apply changes the live buffer, leaves it modified, and is one undo step.

## Permissions

Managed Sessions begin with wildcard deny followed by the explicit read-only capabilities needed for proposal creation.
`edit`, `write`, `apply_patch`, `bash`, `task`, unknown tools, and unsafe external paths remain hard-denied. The final model
tool surface is filtered before dispatch and execution-time permission handling fails closed.

Questions and permitted approval requests use the native interaction queue. No second TUI interaction channel exists.

## Recovery and Privacy

SSE reconnect performs Session/message/request reconciliation before prompts resume. Server restart creates a new owned
generation and never falls back to a foreign process. Disk or changedtick races recompute or stop before application.

Logs and user-facing diagnostics use root IDs, short Session/message IDs, states, and error classes only. Content,
credentials, response bodies, and absolute paths are excluded. Release artifacts follow the same rule.

## Release Gate

`tests/release/run.sh` runs acceptance suites, privacy checks, authenticated real-server E2E, manifest validation, and
per-scenario evidence recording for one exact profile. CI runs it for both profiles. The release workflow reruns both
profiles and requires complete, current, checksummed evidence before release-please can create a release.
