# v2.0 completion roadmap

## Status

Implementation phases F01-F11 are complete. Their detailed `PLAN-F*-done.md` files are historical implementation
records, not current runtime or API contracts. The active contracts are:

- `docs/PRD.md`
- `docs/ARCHITECTURE.md`
- `docs/ACCEPTANCE.md`
- `docs/COMMANDS.md`
- `docs/CONFIGURATION.md`

The later Build-only cleanup removed Plan mode and the complete tmux/sidebar/TUI runtime. `docs/FIX-PLAN.md` records that
transition; its investigation and old line references are historical.

## Completed Slices

1. Exact OpenCode compatibility and owned per-root headless Runtime
2. Build context capture, dirty-buffer preflight, and hard scope
3. Structured proposal validation and Base/Ours/Theirs merge
4. Buffer-only minimal apply, conflict handling, and disk reconciliation
5. Managed questions, permissions, and serialized interactions
6. Session picker/reuse, exact event routing, parallel Jobs, and cancellation
7. SSE/Server recovery, multi-root lifecycle, status, privacy, and diagnostics
8. Build-only/no-TUI cleanup and release evidence hardening

## Current Release Gate

v2.0 is releasable only when all of these pass on the candidate commit:

- StyLua and LuaLS
- unit, integration, contract, release acceptance, and privacy checks
- official OpenCode `1.17.3` authenticated real-server E2E
- official OpenCode `1.18.9` authenticated real-server E2E
- one current checksummed result for every acceptance scenario/profile pair
- no skipped P0/P1 scenario and complete automated or manual P2 evidence

Missing, stale, skipped, mismatched, or checksum-invalid evidence blocks release creation. Patched source builds are useful
for diagnosis but cannot satisfy this gate.

## Deferred

- additional OpenCode versions
- Plan mode
- TUI/sidebar/tmux integration or external Server attach
- multi-file/create/delete/rename edits
- worktree orchestration
- custom commands, model picker, prompt history, and transcript renderer
