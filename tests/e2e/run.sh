#!/bin/sh
set -eu

: "${OPENCODE_VERSION:?set OPENCODE_VERSION to 1.17.3 or 1.18.9}"

source_data=${XDG_DATA_HOME:-"$HOME/.local/share"}
source_auth="$source_data/opencode/auth.json"
test -f "$source_auth"

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary/config/opencode" "$temporary/data/opencode" "$temporary/state"
install -m 600 "$source_auth" "$temporary/data/opencode/auth.json"
printf '{"model":"%s"}\n' "${OPENCODE_E2E_MODEL:-openai/gpt-5.4}" >"$temporary/config/opencode/opencode.json"

XDG_CONFIG_HOME="$temporary/config" \
  XDG_DATA_HOME="$temporary/data" \
  XDG_STATE_HOME="$temporary/state" \
  nvim --headless -u NONE \
  -c "set rtp+=$PWD" \
  -c "lua local ok, err = pcall(dofile, 'tests/e2e/smoke.lua'); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end"
