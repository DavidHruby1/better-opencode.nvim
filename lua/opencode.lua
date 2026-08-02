local M = {}

---@class opencode.PromptOpts
---@field mode? "build"
---@field scope? "file"
---@field auto_apply? boolean
---@field new_session? boolean
---@field session_id? string
---@field range? opencode.context.Range

local function notify_error(err)
  local class = type(err) == "table" and err.error_class or "cancelled"
  if class ~= "cancelled" then
    require("opencode.ui.notify").error(err)
  end
end

---Checks the compatibility mode accepted by public prompt entrypoints.
---Omitted mode and explicit Build use the same workflow; every other value is unavailable.
local function accepts_build_mode(opts)
  return not opts or opts.mode == nil or opts.mode == "build"
end

---Creates a handled rejection for an unavailable prompt mode while preserving it for the caller.
---The attached handler keeps the public error notification, and the returned Promise retains the exact error class.
local function reject_mode()
  local Promise = require("opencode.promise")
  local rejection, _, reject = Promise.with_resolvers()
  rejection:catch(notify_error)
  reject({ error_class = "mode_unavailable" })
  return rejection
end

---Captures the source and starts or reuses its Runtime without waiting for readiness.
---The immediate Context lets ask open after dirty preflight while all callers share the same startup Promise.
local function acquire_context(range)
  local Promise = require("opencode.promise")
  local capture, err = require("opencode.context").capture(range)
  if not capture then
    return nil, Promise.reject({ error_class = err })
  end
  local runtime, readiness = require("opencode.runtime").acquire(capture)
  if not runtime then
    return nil, readiness
  end
  return require("opencode.context").new(capture, runtime), readiness
end

---Returns the captured Context only after its shared Runtime startup succeeds.
---Direct prompt and operator workflows have no editor in which to hold text while startup is pending.
local function ready_context(range)
  local context, readiness = acquire_context(range)
  if not context then
    return readiness
  end
  return readiness:next(function()
    return require("opencode.promise").resolve(context)
  end)
end

---Waits for or retries the captured Runtime, then dispatches the editor's unchanged text.
---A stopped startup may be retried in place; disconnected ownership uses the explicit restart path.
local function submit_when_ready(text, context, opts)
  local Promise = require("opencode.promise")
  local runtime = context.runtime
  local blocker = runtime:prompt_blocker()
  local readiness = Promise.resolve(runtime)
  if blocker and runtime.state == "stopped" then
    local replacement
    replacement, readiness = require("opencode.runtime").acquire(context)
    if replacement then
      runtime = replacement
      context.runtime = replacement
      context.root = replacement.root
    end
  elseif blocker == "disconnected" and runtime.state == "disconnected" then
    readiness = runtime:restart()
  elseif blocker then
    return Promise.reject({ error_class = blocker })
  end
  return readiness:next(function()
    return require("opencode.api.prompt").prompt(text, context, opts)
  end)
end

---Opens the managed Build input and rejects unavailable modes before runtime startup.
---Dirty buffers are checked before the editor opens, while the submit callback preserves the existing Build dispatch.
---@param default? string
---@param opts? opencode.PromptOpts
function M.ask(default, opts)
  if not accepts_build_mode(opts) then
    return reject_mode()
  end
  local context, readiness = acquire_context()
  if not context then
    readiness:catch(notify_error)
    return readiness
  end
  local flow = require("opencode.context.preflight").run(context):next(function()
    return require("opencode.ui.ask").ask(default, context, "build", opts, readiness, function(input)
      return submit_when_ready(input, context, opts)
    end)
  end)
  flow:catch(notify_error)
  return flow
end

---Dispatches a managed Build directly and rejects unavailable modes before runtime startup.
---The private prompt boundary repeats the mode check so direct internal callers cannot bypass the Build-only contract.
---@param text string
---@param opts? opencode.PromptOpts
function M.prompt(text, opts)
  if not accepts_build_mode(opts) then
    return reject_mode()
  end
  local flow = ready_context(opts and opts.range):next(function(context)
    return require("opencode.api.prompt").prompt(text, context, opts)
  end)
  flow:catch(notify_error)
  return flow
end

---Cancels the current Runtime's only active Job or lets the user choose one when several are running.
---The picker uses a stable Job key from one status snapshot, so cancellation never depends on Session selection.
function M.cancel()
  local runtime = require("opencode.runtime").current()
  if not runtime then
    require("opencode.ui.notify").warn("no_active_job")
    return
  end
  local jobs = require("opencode.ui.status").jobs(runtime)
  if #jobs == 0 then
    require("opencode.ui.notify").warn("no_active_job")
    return
  end
  if #jobs == 1 then
    return require("opencode.job").cancel(runtime, jobs[1].key)
  end
  vim.ui.select(jobs, {
    prompt = "Cancel OpenCode Job",
    format_item = function(job)
      return string.format("%s | %s | %s | %s", job.mode, job.file, job.state, job.job)
    end,
  }, function(job)
    if job then
      require("opencode.job").cancel(runtime, job.key)
    end
  end)
end

---Cancels a stable snapshot of all active Jobs across owned Runtimes.
function M.cancel_all()
  return require("opencode.runtime").cancel_all()
end

---Selects one of the two recovery actions for the current Runtime.
---Readiness and interaction guards run before the picker, while each action keeps its existing Runtime behavior.
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
    "Restart runtime",
    "Show diagnostics",
  }, { prompt = "OpenCode" }, function(choice)
    if choice == "Restart runtime" then
      runtime:restart():catch(notify_error)
    elseif choice == "Show diagnostics" then
      require("opencode.ui.notify").diagnostics(runtime)
    end
  end)
end

---Captures the current editor context before opening a fresh managed-session picker.
---The picker only selects a verified reusable Session; the unchanged capture is then passed to the Build prompt.
---@param opts? opencode.PromptOpts
---@return Promise<any>
function M.select_session(opts)
  if opts and opts.mode and opts.mode ~= "build" then
    return reject_mode()
  end
  local context, readiness = acquire_context()
  if not context then
    readiness:catch(notify_error)
    return readiness
  end
  local flow = readiness
    :next(function(runtime)
      return require("opencode.ui.session_picker").open(runtime, context, opts)
    end)
    :catch(notify_error)
  return flow
end

---Creates an operator range and sends it through the Build workflow.
---Unavailable modes are reported before the operator is installed, while a valid invocation captures its range at use time.
---@param text string
---@param opts? opencode.PromptOpts
---@return string
function M.operator(text, opts)
  if not accepts_build_mode(opts) then
    notify_error({ error_class = "mode_unavailable" })
    return ""
  end
  _G.opencode_build_operator = function(kind)
    local from, to = vim.api.nvim_buf_get_mark(0, "["), vim.api.nvim_buf_get_mark(0, "]")
    ready_context({ from = from, to = to, kind = kind })
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
