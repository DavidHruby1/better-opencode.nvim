local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local mini = vim.env.MINI_TEST_PATH
if mini and mini ~= "" then
  vim.opt.runtimepath:prepend(mini)
end

require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.globpath(root .. "/tests", "{unit,integration,contract}/test_*.lua", false, true)
    end,
  },
})
