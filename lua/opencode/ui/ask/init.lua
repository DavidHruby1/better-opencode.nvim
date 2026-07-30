local M = { contexts = {} }

---Opens a history-free Plan input with visible root and active location.
---The context is keyed by input buffer so completion never depends on global current editor state.
---@param default? string
---@param context table
---@return Promise<string>
function M.ask(default, context)
  local config = require("opencode.config")
  local location = require("opencode.context.builtins").this(context)
  local opts = {
    default = default,
    prompt = string.format("Plan | %s | %s: ", vim.fs.basename(context.root), location),
    highlight = function(text)
      return context:render(text).input:input_highlight()
    end,
  }
  opts = vim.tbl_deep_extend("keep", opts, config.opts.ask, config.opts.ask.snacks or {})
  opts.history = false
  opts.win = opts.win or {}
  local previous = opts.win.on_buf
  opts.win.on_buf = function(win)
    M.contexts[win.buf] = context
    if previous then
      previous(win)
    end
    vim.lsp.start(require("opencode.ui.ask.cmp"), { bufnr = win.buf })
  end
  return require("opencode.promise.ui")
    .input(opts)
    :next(function(input)
      if vim.api.nvim_win_is_valid(context.win) then
        vim.api.nvim_set_current_win(context.win)
      end
      return require("opencode.promise").resolve(input)
    end)
    :catch(function(err)
      if vim.api.nvim_win_is_valid(context.win) then
        vim.api.nvim_set_current_win(context.win)
      end
      return require("opencode.promise").reject(err)
    end)
end

_G.opencode_completion = function(_, line)
  local items = {}
  for placeholder in pairs(require("opencode.config").opts.contexts) do
    if placeholder:find(line:match("[^%s]*$") or "", 1, true) == 1 then
      table.insert(items, placeholder)
    end
  end
  return items
end

return M
