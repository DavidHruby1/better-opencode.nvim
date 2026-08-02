## Contributing to opencode.nvim

Keep changes focused, safe, and easy to review. Open an issue or discussion first when product behavior or the exact
OpenCode compatibility matrix would change.

## Project Direction

- Keep the workflow Neovim-native and Build-only.
- Do not add Plan mode, a TUI/sidebar, tmux dependence, or foreign Server attach.
- Preserve proposal-only source changes, hard scope, Base/Ours/Theirs merge, and unchanged disk after apply.
- Prefer small robust changes over convenience features or new abstractions.
- Add tests at the lowest useful level and a real vertical check when compatibility risk requires it.
- Never replace official-binary release evidence with a fake or patched OpenCode success.

## Checks

Run the relevant commands from `README.md` and `docs/MAINTAINERS.md`. Pull requests must pass formatting, LuaLS, unit,
integration, contract, privacy, and required release-acceptance CI checks.

## Conduct

Be respectful and constructive. See [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).
