# v2.0 Acceptance Contract

## Rules

P0 safety and data-integrity scenarios and P1 functional scenarios cannot be skipped. P2 scenarios require automation or
a completed reproducible protocol. Every scenario is required for official OpenCode `1.17.3` and `1.18.9` profiles.
Fake or patched binaries are diagnostic only and cannot produce release evidence.

The authenticated E2E uses a real plugin-owned Server and Build agent. It must include a whole-file UTF-8 replacement
with a final newline and prove live-buffer mutation, unchanged source bytes on disk, terminal completion, and
metadata-only failure diagnostics.

## Runtime

### AC-RUN-01: Owned secure Runtime
**Priorita:** P0

An initial Build starts one authenticated loopback Server for the canonical root, routes every request to that root, and
does not start a TUI or require tmux.

### AC-RUN-02: No foreign attach or discovery
**Priorita:** P0

Runtime startup never discovers, attaches to, or sends requests to a foreign OpenCode process.

### AC-RUN-03: Unsupported version or API
**Priorita:** P0

An unknown version or mismatched exact `/doc` contract fails preflight before prompt dispatch.

### AC-RUN-04: Startup timeout
**Priorita:** P1

Startup timeout stops owned partial state and reports a safe error without falling back to another Server.

### AC-RUN-05: Multiple project roots
**Priorita:** P1

Each canonical root has an isolated Server, stream, Sessions, and Jobs; events cannot cross roots.

### AC-RUN-06: Safe shutdown
**Priorita:** P1

Shutdown aborts active owned Sessions, stops only proven owned Servers, cleans private state, and leaves foreign processes.

### AC-RUN-07: Verified stale ownership cleanup
**Priorita:** P0

Stale process cleanup requires matching process identity, executable, credentials, port, and root; uncertainty is manual.

### AC-RUN-08: Server recovery remains fail-closed
**Priorita:** P1

A disconnected owned Server blocks prompts until restart and reconciliation; unproven pending work cannot apply.

### AC-RUN-09: Config extension boundary
**Priorita:** P0

Config guards reject custom tools without importing them, leave plugins/MCP OpenCode-owned, and do not initialize `/mcp`.

## UI and Context

### AC-UI-01: Inline Build prompt
**Priorita:** P1

The prompt shows Build, root, and effective scope, preserves source focus, supports multiline input, and opens no sidebar.

### AC-UI-02: Runtime works without tmux or TUI
**Priorita:** P1

Build startup, dispatch, completion, Session selection, and recovery work with no tmux variables, executable, pane, or TUI.

### AC-UI-03: Readable identity without color
**Priorita:** P2

Status text identifies root, Session, Job, mode, and state without relying only on color.

### AC-UI-04: Background notifications are non-invasive
**Priorita:** P2

Completion, conflict, question, and error notifications do not change window, cursor, source buffer, or selected Session.

### AC-UI-05: Inline Build status and reasoning preview
**Priorita:** P1

Active Build state is bounded, content is not persisted, and terminal/conflict state removes transient marks.

### AC-CTX-01: Context placeholders
**Priorita:** P1

Supported context placeholders capture the invocation context and render canonical file-backed references.

### AC-CTX-02: Native commands, skills, and AGENTS
**Priorita:** P1

The plugin does not duplicate OpenCode discovery and rejects managed custom-command dispatch.

### AC-CTX-03: Dirty preflight and write hooks
**Priorita:** P0

Dirty target/context buffers are saved atomically and Base is captured only after successful write hooks.

### AC-CTX-04: Save failure stops dispatch
**Priorita:** P0

Save cancellation, failure, or invalid post-hook state prevents dispatch.

### AC-CTX-05: Unsupported target
**Priorita:** P1

Unnamed, non-file, binary/NUL, invalid UTF-8, and blockwise targets fail before serialization.

### AC-CTX-06: Build-only dirty preflight
**Priorita:** P1

All public Build entrypoints use the same save-before-dispatch preflight; no Plan-specific branch remains.

## Mode and Scope

### AC-MODE-01: Build is the only supported mode
**Priorita:** P0

Omitted mode and `build` use the primary Build agent; `plan` fails with `mode_unavailable` before dispatch.

### AC-MODE-02: Build proposes instead of writing source
**Priorita:** P0

Build returns structured output and cannot use source-write, shell, task, unknown, or custom tools.

### AC-MODE-03: Reusable Session continues with Build
**Priorita:** P1

A verified reusable managed Session can receive a new Build with a new message and transaction identity.

### AC-SCOPE-01: Invocation range wins
**Priorita:** P0

The captured visual/operator range takes priority over stale marks and later cursor movement.

### AC-SCOPE-02: Function and whole-file fallback
**Priorita:** P1

A supported function is selected when available; otherwise Build safely targets the whole file.

### AC-SCOPE-03: Scope violation rejects the proposal
**Priorita:** P0

Any Base-to-Theirs change outside the authorized range rejects the complete proposal without mutation.

### AC-SCOPE-04: Overlap is rejected
**Priorita:** P0

Active overlapping scopes in one buffer are rejected while merely adjacent scopes remain allowed.

### AC-SCOPE-05: Extmarks track but do not authorize
**Priorita:** P1

Extmarks track current positions; authorization remains tied to immutable Base scope.

### AC-SCOPE-06: New overlap before apply is rejected
**Priorita:** P0

User edits that make active scopes overlap stop application fail-closed.

## Proposal and Merge

### AC-PROP-01: Valid proposal creates exact Theirs
**Priorita:** P0

A valid structured replacement deterministically creates Theirs for the exact target and Base.

### AC-PROP-02: Invalid structured output
**Priorita:** P0

Missing, malformed, duplicate, or invalid structured output terminates without applying.

### AC-PROP-03: Transaction identity mismatch
**Priorita:** P0

Target path, Base hash, and scope come only from the local Job; wrong Session, parent message, or generation cannot complete it.

### AC-MERGE-01: Clean agent change
**Priorita:** P0

A clean proposal changes only the live buffer and leaves disk unchanged.

### AC-MERGE-02: Non-conflicting user change
**Priorita:** P0

Three-way merge preserves non-conflicting Ours and Theirs changes.

### AC-MERGE-03: Identical change
**Priorita:** P1

Identical Ours and Theirs completes without duplicate or conflict.

### AC-MERGE-04: InsertLeave defers apply
**Priorita:** P0

Completion in Insert mode waits and revalidates before applying after `InsertLeave`.

### AC-MERGE-05: Changedtick race
**Priorita:** P0

A changed buffer invalidates stale merge output and requires a fresh merge.

### AC-MERGE-06: Agent conflict choices
**Priorita:** P0

A true conflict offers keep mine, accept agent, or manual diff while preserving non-conflicting hunks.

### AC-MERGE-07: Manual diff lifecycle
**Priorita:** P1

Manual conflict buffers are isolated and explicit confirm/cancel controls completion.

### AC-MERGE-08: One undo and no reload
**Priorita:** P0

Apply is one minimal buffer mutation and one undo step with no write, reload, `:edit`, or `checktime`.

### AC-MERGE-09: External disk change
**Priorita:** P0

Unexpected disk bytes stop apply for explicit reconciliation and are never overwritten.

### AC-MERGE-10: User saves Ours during Job
**Priorita:** P1

When disk equals current Ours, merge can continue without losing user changes.

### AC-MERGE-11: Disk changes between merge and apply
**Priorita:** P0

The final disk fingerprint check rejects a stale merge immediately before mutation.

### AC-MERGE-12: UTF-8, EOL, and empty-file fidelity
**Priorita:** P0

Logical-buffer conversion preserves UTF-8, file format, final newline, trailing empty lines, and empty files.

## Sessions, Jobs, and Events

### AC-JOB-01: One nonterminal Job per Session
**Priorita:** P0

A Session rejects a follow-up while its current Job is nonterminal.

### AC-JOB-02: Managed Session picker
**Priorita:** P1

The picker shows only verified managed Sessions for the current root and can resume or safely delete one.

### AC-JOB-03: Parallel non-overlapping Jobs
**Priorita:** P0

Separate Sessions may apply non-overlapping scopes in either completion order without cross-mutation.

### AC-JOB-04: Cancel one Job
**Priorita:** P0

Cancel aborts the exact Session turn, clears owned state, and ignores late events.

### AC-JOB-05: Cancel all
**Priorita:** P1

Cancel-all snapshots active Jobs across Runtimes and handles each independently.

### AC-JOB-06: Session ownership, reuse, and retention
**Priorita:** P0

Only matching root/version/permission managed Sessions are reusable; archived or foreign Sessions are not.

### AC-JOB-07: No TUI interaction channel
**Priorita:** P0

The plugin never starts `opencode attach`, sends TUI input, or depends on `/tui/select-session`.

### AC-EVT-01: Session and message routing
**Priorita:** P0

Events correlate by Runtime, Session, user message, assistant parent, and registered assistant IDs.

### AC-EVT-02: Request without message ID
**Priorita:** P0

A request without message ID routes only to the single provable active Job or fails reconciliation.

### AC-EVT-03: Reconnect with completed result
**Priorita:** P0

Reconciliation completes exactly once only from one valid structured response with the expected parent.

### AC-EVT-04: Reconnect without provable result
**Priorita:** P0

Missing, duplicate, or invalid remote result ends in error without apply.

### AC-EVT-05: Server crash and restart
**Priorita:** P1

Server death disconnects its Runtime, preserves local safety data, and requires owned restart plus reconciliation.

### AC-EVT-06: Delta events cannot bypass completion
**Priorita:** P1

Reasoning/delta/updated events never replace exact structured completion correlation.

## Interaction and State

### AC-INT-01: Question resumes the correct Job
**Priorita:** P0

Native question UI replies once to the exact request and Job.

### AC-INT-02: Permission dialog and hard deny
**Priorita:** P0

Only allowlisted permissions are approvable; hard-denied or unknown capabilities are rejected without override.

### AC-INT-03: FIFO dialog queue
**Priorita:** P1

Questions, permissions, and conflicts from concurrent Jobs are serialized without cross-routing.

### AC-INT-04: Snacks is the only managed interaction UI
**Priorita:** P0

Managed replies occur only through native Snacks UI; there is no sidebar/TUI response path.

### AC-STATE-01: Valid state transitions
**Priorita:** P0

Only declared Job transitions are allowed; invalid and duplicate transitions fail closed.

### AC-STATE-02: Session availability is derived
**Priorita:** P1

Session availability follows active/nonterminal Job state and becomes reusable after terminal completion.

## Security and Release

### AC-SEC-01: Metadata-only output
**Priorita:** P0

Logs, notifications, diagnostics, and release artifacts exclude content, credentials, response bodies, and absolute paths.

### AC-SEC-02: Practical health and release evidence
**Priorita:** P2

Health reports actionable capability metadata. Release evidence has one current checksummed result per scenario/profile and
explicitly fails missing, stale, skipped, mismatched, or checksum-invalid results.
