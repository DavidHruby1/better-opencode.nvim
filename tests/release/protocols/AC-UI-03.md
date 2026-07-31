# AC-UI-03 Colorless status protocol

tester:
date:
profile:
artifact:

Setup: create two managed Sessions with the same short-ID suffix, one foreground and one background, and at least one active Job in each. Disable highlights and capture the status text.

Command: run the release status snapshot test and save the text snapshot as the artifact named above.

Expected: root basename, Runtime state, exact profile, title, collision-safe short IDs, mode, availability, and exact Job state/kind remain distinguishable without color. No short ID or state is truncated.
