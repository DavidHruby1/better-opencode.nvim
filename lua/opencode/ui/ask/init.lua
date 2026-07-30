local M = { contexts = {} }

---Opens a history-free Plan or Build input with visible root and effective scope.
---The context is keyed by input buffer so completion never depends on global current editor state.
---@param default? string
---@param context table
---@param mode? "plan"|"build"
---@param workflow_opts? table
---@return Promise<string>
function M.ask(default, context, mode, workflow_opts)
  local config = require("opencode.config")
  local location = require("opencode.context.builtins").this(context)
  mode = mode or "build"
  local scope_kind = ""
  if mode == "build" then
    local base = { text = table.concat(vim.api.nvim_buf_get_lines(context.buf, 0, -1, false), "\n") }
    local scope = require("opencode.scope").resolve(context, base, workflow_opts and workflow_opts.scope)
    scope_kind = " | " .. (scope and scope.kind or "unsupported")
  end
  local opts = {
    default = default,
    prompt = string.format(
      "%s | %s | %s%s: ",
      mode == "build" and "Build" or "Plan",
      context.root,
      location,
      scope_kind
    ),
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
