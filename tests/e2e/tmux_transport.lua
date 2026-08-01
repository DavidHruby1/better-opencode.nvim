---Confirms that this Neovim process is running in the real disposable tmux pane created by run.sh.
---It resolves the pane through tmux argv and checks the returned pane ID; it does not simulate terminal key bytes.
local pane = vim.env.TMUX_PANE
assert(vim.env.TMUX and vim.env.TMUX ~= "", "Neovim is not running inside the disposable tmux server")
assert(pane and pane ~= "", "tmux did not provide TMUX_PANE to Neovim")

local result = vim.system({ "tmux", "display-message", "-p", "-t", pane, "#{pane_id}" }, { text = true }):wait()
assert(result.code == 0, "tmux could not resolve Neovim's actual pane")
assert(vim.trim(result.stdout or "") == pane, "TMUX_PANE does not identify Neovim's actual tmux pane")
