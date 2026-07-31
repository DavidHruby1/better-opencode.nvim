local M = {}

local function notify_error(err)
  local class = type(err) == "table" and err.error_class or "cancelled"
  if class ~= "cancelled" then
    require("opencode.ui.notify").error(class)
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
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean, new_session?: boolean }
function M.ask(default, opts)
  if opts and opts.mode and opts.mode ~= "plan" and opts.mode ~= "build" then
    notify_error({ error_class = "mode_unavailable" })
    return
  end
  local mode = (opts and opts.mode) or "build"
  start_context()
    :next(function(context)
      if not context.runtime:accepts_prompts() then
        return require("opencode.promise").reject({ error_class = "interaction_locked" })
      end
      return require("opencode.ui.ask").ask(default, context, mode, opts):next(function(input)
        return require("opencode.api.prompt").prompt(input, context, opts)
      end)
    end)
    :catch(notify_error)
end

---Dispatches a managed Build directly, or an explicit read-only Plan.
---@param text string
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean, new_session?: boolean }
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

---Cancels the selected Session's active Job without touching Jobs in another Session or root.
function M.cancel()
  local runtime = require("opencode.runtime").current()
  local session = runtime and runtime.selected_session_id and runtime.sessions[runtime.selected_session_id]
  if runtime and session and session.active_job_key then
    return require("opencode.job").cancel(runtime, session.active_job_key)
  end
  require("opencode.ui.notify").warn("no_active_job")
end

---Cancels a stable snapshot of all active Jobs across owned Runtimes.
function M.cancel_all()
  return require("opencode.runtime").cancel_all()
end

---Selects the F02 Runtime UI actions.
function M.select()
  local runtime = require("opencode.runtime").current()
  if not runtime or runtime.state == "stopping" or runtime.state == "stopped" then
    notify_error({ error_class = "runtime_not_ready" })
    return
  end
  if runtime.interaction_locked then
    notify_error({ error_class = "interaction_locked" })
    return
  end
  vim.ui.select({
    "Ask Build",
    "Ask Plan",
    "New Build session",
    "Sessions",
    "Cancel current Job",
    "Cancel all",
    "Restart runtime",
    "Show diagnostics",
    "Toggle sidebar",
    "Focus sidebar",
  }, { prompt = "OpenCode" }, function(choice)
    if choice == "Ask Build" then
      M.ask()
    elseif choice == "Ask Plan" then
      M.ask(nil, { mode = "plan" })
    elseif choice == "New Build session" then
      M.ask(nil, { mode = "build", new_session = true })
    elseif choice == "Sessions" then
      require("opencode.ui.select_session").show(runtime)
    elseif choice == "Cancel current Job" then
      M.cancel()
    elseif choice == "Cancel all" then
      M.cancel_all()
    elseif choice == "Restart runtime" then
      runtime:restart():catch(notify_error)
    elseif choice == "Show diagnostics" then
      require("opencode.ui.notify").diagnostics(runtime)
    end
    if choice == "Toggle sidebar" then
      runtime.sidebar:toggle()
    end
    if choice == "Focus sidebar" then
      runtime.sidebar:focus()
    end
  end)
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
  if not runtime then
    return ""
  end
  return require("opencode.ui.status").text(require("opencode.ui.status").snapshot(runtime)):match("^[^\n]*")
end

return M
