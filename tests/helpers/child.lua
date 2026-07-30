local M = {}

---Creates a clean child Neovim rooted at this plugin.
---@return table
function M.new()
  local child = MiniTest.new_child_neovim()
  child:start({ "-u", "tests/minimal_init.lua" })
  return child
end

return M
