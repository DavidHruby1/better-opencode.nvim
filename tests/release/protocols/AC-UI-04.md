# AC-UI-04 Focus-safe notification protocol

tester:
date:
profile:
artifact:

Setup: keep a source window and a different sidebar Session selected. Enqueue four background Jobs owned by a different root/session snapshot: completed, agent conflict, question, and error.

Command: run the release notification integration test with a stubbed `vim.notify` and save the captured metadata-only messages and focus assertions.

Expected: each message contains the event-owning root basename, Session short ID, mode, and text state; completion, conflict, question, and error are distinct. Window, cursor, and sidebar buffer do not change.
