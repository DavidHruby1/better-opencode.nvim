local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["active location is injected exactly once"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "local x = 1" }, path)
  vim.cmd.edit(path)
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  local rendered = context:render("Explain @this").plaintext
  local location = require("opencode.context.builtins").this(context)
  local _, count = rendered:gsub(vim.pesc(location), "")
  eq(count, 1)
  vim.uv.fs_unlink(path)
end

T["unsupported unnamed buffer fails before Runtime"] = function()
  vim.cmd.enew()
  eq(select(2, require("opencode.context").capture()), "unnamed_buffer")
end

return T
