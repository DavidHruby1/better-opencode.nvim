# Maintainer Release Procedure

## Baselines

- Upstream plugin: `nickjvandyke/opencode.nvim` commit `7749a034db61258ece828df70a89ff31bb27ff47`.
- OpenCode `1.17.3`: commit `8c8011336163d7e7fb24a6a4a049cdb1f6e6ee74`, fixture SHA `41d34a78b59d6bd472dd6b10b3de77fd200faec1c6ed7b757f352eed58b84e24`.
- OpenCode `1.18.9`: commit `4da7bb44c84e013fa53e9c5d02ac753d1435c81a`, fixture SHA `f5cb443f0d160fc4b17190f64c2401f199160eb2137ce4e00ca319b99aa34005`.

Support is not a semver range. A new OpenCode version requires source audit of tool construction and permissions, route/schema comparison, a frozen `/doc` fixture, an explicit profile, and all P0/P1 tests for both baselines.

## Fixture capture

Capture `/doc` from an owned temporary Server with a disposable password and a loopback port. Use argv-based `curl`, `-H 'x-opencode-directory: <canonical-root>'`, and credentials through a private config/stdin. Do not commit credentials, absolute home paths, response bodies outside the frozen fixture, or live logs. Record version, upstream commit, capture command with placeholders, and SHA-256 in the matching `.meta` file.

The contract depends on append semantics for Session PATCH permissions, `info.structured`, SSE `event: message` frames whose JSON has a `type`, the root header on every request, fresh approval state for each owned Server, and profile-specific extra events in `1.18.9`. Verify these assumptions before changing `compat.lua` or `client.lua`.

## Checks

Run from a clean checkout with dependencies imported:

```sh
stylua --check .
lua-language-server --configpath .luarc.ci.json --check=.
MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"
OPENCODE_VERSION=1.17.3 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.18.9 MINI_TEST_PATH=/path/to/mini.nvim nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/contract', 'test_*.lua', false, true) end } })"
OPENCODE_VERSION=1.17.3 sh tests/e2e/run.sh
PATH=/path/to/opencode-1.18.9/bin:$PATH OPENCODE_VERSION=1.18.9 sh tests/e2e/run.sh
nvim --headless -u NONE -c "luafile tests/release/validate.lua" -c 'qa!'
```

Run `tests/release/privacy.lua` with the unit suite and generate evidence only after every result artifact has an exit code and repository-relative artifact/checksum. The evidence generator must fail on missing results, skipped P0/P1, missing profile runs, or an incomplete P2 protocol.

## Upgrade checklist

- Add one explicit compatibility profile and immutable `/doc` fixture.
- Re-audit permission surface filtering, execution-time hard deny, Session PATCH append order, structured output, root headers, SSE event shape, and fresh approval behavior.
- Add profile-specific contract fixtures and run all P0/P1 tests against both exact versions.
- Capture failure injection for source disk writes, stale apply, cross-Job/root events, unauthorized execution, foreign process termination, Ours loss, reload/whole-buffer mutation, and one-undo behavior.
- Run the privacy scan, validate the 63-ID acceptance manifest, generate evidence, and review the report before release approval.
