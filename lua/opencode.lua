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

---Opens the managed read-only Plan input.
---@param default? string
---@param opts? { mode?: "plan" }
function M.ask(default, opts)
  if opts and opts.mode and opts.mode ~= "plan" then
    notify_error({ error_class = "mode_unavailable" })
    return
  end
  start_context()
    :next(function(context)
      return require("opencode.ui.ask").ask(default, context):next(function(input)
        return require("opencode.api.prompt").prompt(input, context)
      end)
    end)
    :catch(notify_error)
end

---Dispatches a managed read-only Plan directly.
---@param text string
---@param opts? { mode?: "plan" }
function M.prompt(text, opts)
  if opts and opts.mode and opts.mode ~= "plan" then
    notify_error({ error_class = "mode_unavailable" })
    return
  end
  start_context()
    :next(function(context)
      return require("opencode.api.prompt").prompt(text, context)
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
  vim.ui.select({ "Ask Plan", "Toggle sidebar", "Focus sidebar" }, { prompt = "OpenCode" }, function(choice)
    if choice == "Ask Plan" then
      M.ask(nil, { mode = "plan" })
    end
    if choice == "Toggle sidebar" then
      runtime.sidebar:toggle()
    end
    if choice == "Focus sidebar" then
      runtime.sidebar:focus()
    end
  end)
end

---Creates an operator range and sends it through the Plan workflow.
---@param text string
---@param opts? { mode?: "plan" }
---@return string
function M.operator(text, opts)
  _G.opencode_plan_operator = function(kind)
    local from, to = vim.api.nvim_buf_get_mark(0, "["), vim.api.nvim_buf_get_mark(0, "]")
    start_context({ from = from, to = to, kind = kind })
      :next(function(context)
        return require("opencode.api.prompt").prompt(text, context)
      end)
      :catch(notify_error)
  end
  vim.o.operatorfunc = "v:lua.opencode_plan_operator"
  return "g@"
end

M.format = require("opencode.context").format
M.statusline = function()
  local runtime = require("opencode.runtime").current()
  return runtime and ("OpenCode " .. runtime.state) or ""
end

return M
