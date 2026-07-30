---@class opencode.Opts
---@field runtime? { startup_timeout?: integer }
---@field sidebar? { width?: number }
---@field contexts? table<string, function>
---@field ask? table

---@type opencode.Opts?
vim.g.opencode_opts = vim.g.opencode_opts

local defaults = {
  runtime = { startup_timeout = 10000 },
  sidebar = { width = 0.30 },
  contexts = {
    ["@this"] = require("opencode.context.builtins").this,
    ["@buffer"] = require("opencode.context.builtins").buffer,
    ["@buffers"] = require("opencode.context.builtins").buffers,
    ["@diagnostics"] = require("opencode.context.builtins").diagnostics,
    ["@marks"] = require("opencode.context.builtins").marks,
    ["@quickfix"] = require("opencode.context.builtins").quickfix,
    ["@visible"] = require("opencode.context.builtins").visible_text,
  },
  ask = {
    completion = "customlist,v:lua.opencode_completion",
    snacks = {
      icon = "Plan ",
      history = false,
      win = {
        relative = "cursor",
        row = -3,
        col = 0,
        b = { completion = true },
        bo = { filetype = "opencode_ask" },
      },
    },
  },
}

return { opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.g.opencode_opts or {}) }
