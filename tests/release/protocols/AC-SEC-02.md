# AC-SEC-02 Health fixture protocol

tester:
date:
profile:
artifact:

Setup: run health with parametrized missing dependency, unsupported version, missing Snacks input/picker, missing parser, and unwritable private state fixtures. Do not start OpenCode Server, MCP, or process discovery.

Command: run the health fixture test and save the structured health observations as the artifact named above.

Expected: hard dependencies are actionable errors, parser absence is a warning with file-scope fallback, the selected exact profile and fixture SHA are shown, and no option values, credentials, process lists, or absolute home paths are printed.
