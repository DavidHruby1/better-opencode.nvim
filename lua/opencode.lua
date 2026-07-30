local M = {}

local function notify_error(err)
  local class = type(err) == "table" and err.error_class or "cancelled"
  if class ~= "cancelled" then
    vim.notify("OpenCode: " .. class, vim.log.levels.ERROR)
  end
end

local function start_context(range)
  local Promise = require("opencode.promise")
  local capture, err = require("opencode.context").capture(range)
  if not capture then
    return Promise.reject({ error_class = err })
  end
  return require("opencode.runtime").get_or_start(capture):next(function(runtime)
    return Promise.resolve(require("opencode.context").new(capture, runtime))
  end)
end

---Opens the managed Build input, or an explicit read-only Plan input.
---@param default? string
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean }
function M.ask(default, opts)
  if opts and opts.mode and opts.mode ~= "plan" and opts.mode ~= "build" then
    notify_error({ error_class = "mode_unavailable" })
    return
  end
  local mode = (opts and opts.mode) or "build"
  start_context()
    :next(function(context)
      return require("opencode.ui.ask").ask(default, context, mode, opts):next(function(input)
        return require("opencode.api.prompt").prompt(input, context, opts)
      end)
    end)
    :catch(notify_error)
end

---Dispatches a managed Build directly, or an explicit read-only Plan.
---@param text string
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean }
function M.prompt(text, opts)
  if opts and opts.mode and opts.mode ~= "plan" and opts.mode ~= "build" then
    notify_error({ error_class = "mode_unavailable" })
    return
  end
  start_context()
    :next(function(context)
      return require("opencode.api.prompt").prompt(text, context, opts)
    end)
    :catch(notify_error)
end

---Selects the F02 Runtime UI actions.
function M.select()
  local runtime = require("opencode.runtime").current()
  if not runtime or runtime.state ~= "ready" then
    notify_error({ error_class = "runtime_not_ready" })
    return
  end
  vim.ui.select(
    { "Ask Build", "Ask Plan", "Toggle sidebar", "Focus sidebar" },
    { prompt = "OpenCode" },
    function(choice)
      if choice == "Ask Build" then
        M.ask()
      elseif choice == "Ask Plan" then
        M.ask(nil, { mode = "plan" })
      end
      if choice == "Toggle sidebar" then
        runtime.sidebar:toggle()
      end
      if choice == "Focus sidebar" then
        runtime.sidebar:focus()
      end
    end
  )
end

---Creates an operator range and sends it through the Build workflow by default.
---@param text string
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean }
---@return string
function M.operator(text, opts)
  _G.opencode_build_operator = function(kind)
    local from, to = vim.api.nvim_buf_get_mark(0, "["), vim.api.nvim_buf_get_mark(0, "]")
    start_context({ from = from, to = to, kind = kind })
      :next(function(context)
        return require("opencode.api.prompt").prompt(text, context, opts)
      end)
      :catch(notify_error)
  end
  vim.o.operatorfunc = "v:lua.opencode_build_operator"
  return "g@"
end

M.format = require("opencode.context").format
M.statusline = function()
  local runtime = require("opencode.runtime").current()
  return runtime and ("OpenCode " .. runtime.state) or ""
end

return M
