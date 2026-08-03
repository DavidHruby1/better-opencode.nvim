#!/bin/sh
set -eu

: "${OPENCODE_VERSION:?set OPENCODE_VERSION to 1.17.3 or 1.18.9}"
: "${MINI_TEST_PATH:?set MINI_TEST_PATH to mini.nvim}"

case "$OPENCODE_VERSION" in
  1.17.3|1.18.9) ;;
  *) printf '%s\n' "unsupported release profile: $OPENCODE_VERSION" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

test "$(opencode --version)" = "$OPENCODE_VERSION"

for file in \
  tests/release/ac/test_runtime.lua \
  tests/release/ac/test_ui_context.lua \
  tests/release/ac/test_merge.lua \
  tests/release/ac/test_jobs.lua \
  tests/release/ac/test_security.lua \
  tests/integration/test_request_status.lua \
  tests/contract/test_reasoning_events.lua
do
  MINI_TEST_PATH="$MINI_TEST_PATH" nvim --headless -u tests/minimal_init.lua \
    -c "lua MiniTest.run_file('$file')"
done

nvim --headless -u NONE --cmd 'set runtimepath^=.' \
  -c 'luafile tests/release/privacy.lua' -c 'qa!'
OPENCODE_VERSION="$OPENCODE_VERSION" tests/e2e/run.sh
nvim --headless -u NONE -c "luafile tests/release/validate.lua" -c 'qa!'

RELEASE_GIT_COMMIT=$(git rev-parse HEAD) \
  nvim --headless -u NONE \
  -c "lua dofile('tests/release/record.lua').record('.', '$OPENCODE_VERSION')" \
  -c 'qa!'

RELEASE_GIT_COMMIT=$(git rev-parse HEAD) \
  nvim --headless -u NONE \
  -c "lua local ok, errors = dofile('tests/release/evidence.lua').validate_profile('.', 'tests/release/results/index.lua', '$OPENCODE_VERSION'); if not ok then error(table.concat(errors, '\n')) end" \
  -c 'qa!'
