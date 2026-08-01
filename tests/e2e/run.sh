#!/bin/sh
set -eu

: "${OPENCODE_VERSION:?set OPENCODE_VERSION to 1.17.3 or 1.18.9}"
: "${SNACKS_PATH:?set SNACKS_PATH to a snacks.nvim checkout}"

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

source_data=${XDG_DATA_HOME:-"$HOME/.local/share"}
source_auth="$source_data/opencode/auth.json"
test -f "$source_auth"

temporary=$(mktemp -d)
tmux_socket="$temporary/tmux"
tmux_session="opencode-e2e-$$"
nvim_status="$temporary/nvim.status"
tmux_config="$temporary/tmux.conf"
launcher="$temporary/run-nvim.sh"

# Runs one command against the private tmux socket and configuration.
# A separate socket keeps the disposable E2E server isolated from any user tmux server.
tmux_cmd() {
  tmux -S "$tmux_socket" -f "$tmux_config" "$@"
}

# Removes the session, server, and temporary credentials even after Neovim fails.
cleanup() {
  tmux_cmd kill-session -t "$tmux_session" >/dev/null 2>&1 || :
  tmux_cmd kill-server >/dev/null 2>&1 || :
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$temporary/config/opencode" "$temporary/data/opencode" "$temporary/state"
install -m 600 "$source_auth" "$temporary/data/opencode/auth.json"
printf '{"model":"%s"}\n' "${OPENCODE_E2E_MODEL:-openai/gpt-5.4}" >"$temporary/config/opencode/opencode.json"
: >"$tmux_config"

export OPENCODE_VERSION SNACKS_PATH
export OPENCODE_E2E_MODEL=${OPENCODE_E2E_MODEL:-openai/gpt-5.4}
export XDG_CONFIG_HOME="$temporary/config"
export XDG_DATA_HOME="$temporary/data"
export XDG_STATE_HOME="$temporary/state"
export E2E_STATUS_FILE="$nvim_status"

cat >"$launcher" <<'EOF'
#!/bin/sh
set +e

nvim --headless -u NONE \
  -c "set rtp+=$SNACKS_PATH" \
  -c "set rtp+=$PWD" \
  -c "lua local ok, err = pcall(dofile, 'tests/e2e/tmux_transport.lua'); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end" \
  -c "lua local ok, err = pcall(dofile, 'tests/e2e/smoke.lua'); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 1') end"
status=$?
printf '%s\n' "$status" >"$E2E_STATUS_FILE"
exit "$status"
EOF
chmod 700 "$launcher"

tmux_cmd new-session -d -s "$tmux_session" -c "$root" "$launcher"
while tmux_cmd has-session -t "$tmux_session" >/dev/null 2>&1; do
  sleep 0.1
done
test -s "$nvim_status"
exit "$(cat "$nvim_status")"
