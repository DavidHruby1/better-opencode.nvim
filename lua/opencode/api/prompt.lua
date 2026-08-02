local M = {}

---Returns the Runtime's concrete prompt blocker while retaining compatibility with small test fakes.
---Production callers use Runtime:prompt_blocker so dispatch errors name the actual lock instead of a generic not-ready state.
local function prompt_blocker(runtime)
  if runtime.prompt_blocker then
    return runtime:prompt_blocker()
  end
  return runtime:accepts_prompts() and nil or "runtime_not_ready"
end

local function relative_path(root, path)
  return assert(vim.fs.relpath(root, path))
end

---Creates a verified Session or revalidates the explicitly selected reusable Session.
---An active selection is rejected instead of queued; new-session requests clear transcript reuse intent.
---Permission verification remains mandatory on both paths because OpenCode PATCH is append-only.
local function prepare_session(runtime, mode, path, opts)
  local sessions = require("opencode.session")
  local selected_id = opts.new_session and nil or runtime.selected_session_id
  if opts.new_session then
    runtime.selected_session_id = nil
  end
  if selected_id then
    local selected = runtime.sessions[selected_id]
    if selected then
      local availability = sessions.availability(runtime, selected, selected.remote_status)
      if availability == "active" then
        return require("opencode.promise").reject({
          error_class = "session_active",
          action = "create_new_session",
        })
      end
      if availability == "blocked" then
        return require("opencode.promise").reject({ error_class = "session_busy" })
      end
    end
    return sessions.revalidate(runtime, selected_id, mode)
  end
  local metadata = sessions.metadata(runtime.root_hash)
  metadata.last_mode = mode
  return runtime.client
    :create_session({
      title = (mode == "build" and "Build " or "Plan ") .. vim.fs.basename(path),
      metadata = metadata,
      permission = sessions.permissions,
    })
    :next(function(created)
      return sessions.revalidate(runtime, created.id, mode, true)
    end)
end

local function build_instruction(context, rendered, base, scope)
  return table.concat({
    rendered.plaintext,
    "",
    "Return a structured replacement for only this authorized scope.",
    "Target: " .. relative_path(context.runtime.root, context.path),
    "Base SHA-256: " .. base.sha256,
    string.format("Scope bytes: [%d,%d)", scope.start_byte, scope.end_byte),
    "replacement must contain the complete new text for that scope only.",
  }, "\n")
end

---Dispatches one Plan or scoped Build through Session HTTP after target and dirty preflight.
---The Job is registered before prompt_async so immediate SSE cannot outrun local correlation state. Build stays editor-only,
---while Plan dispatches first, then attaches or reuses the lazy tmux pane and selects its transcript without focusing it.
---@param text string
---@param context table
---@param opts? opencode.PromptOpts
---@return Promise<table>
function M.prompt(text, context, opts)
  local Promise = require("opencode.promise")
  opts = opts or {}
  local mode = opts.mode or "build"
  if text:match("^%s*/[%w_.-]+") then
    return Promise.reject({ error_class = "command_unsupported" })
  end
  return require("opencode.context.preflight").run(context, mode):next(function()
    local rendered = context:render(text)
    local runtime = context.runtime
    local blocker = prompt_blocker(runtime)
    if blocker then
      return Promise.reject({ error_class = blocker })
    end
    local base, scope, marks
    if mode == "build" then
      local base_error
      base, base_error = require("opencode.snapshot").capture(context.buf)
      if not base then
        return Promise.reject({ error_class = base_error or "disk_read" })
      end
      local scope_error
      scope, scope_error = require("opencode.scope").resolve(context, base, opts.scope)
      if not scope then
        return Promise.reject({ error_class = scope_error })
      end
      local displayed = context.displayed_scope
      if
        displayed
        and (
          displayed.sha256 ~= base.sha256
          or displayed.kind ~= scope.kind
          or displayed.start_byte ~= scope.start_byte
          or displayed.end_byte ~= scope.end_byte
        )
      then
        return Promise.reject({ error_class = "scope_changed" })
      end
      local candidate = { start_byte = scope.start_byte, end_byte = scope.end_byte }
      local overlap = require("opencode.scope").find_overlap(runtime, context.buf, candidate)
      if overlap then
        return Promise.reject({ error_class = "scope_overlap", job_short_id = overlap.user_message_id:sub(-8) })
      end
      marks = require("opencode.scope").create_marks(context.buf, scope)
    end
    blocker = prompt_blocker(runtime)
    if blocker then
      if marks then
        require("opencode.scope").delete_marks({ buffer = context.buf, marks = marks })
        marks = nil
      end
      return Promise.reject({ error_class = blocker })
    end
    return prepare_session(runtime, mode, context.path, opts)
      :next(function(remote)
        local dispatch_blocker = prompt_blocker(runtime)
        if dispatch_blocker then
          return Promise.reject({ error_class = dispatch_blocker })
        end
        local session = runtime.sessions[remote.id]
          or { id = remote.id, root = runtime.root, short_id = remote.id:sub(-8), active_job_key = nil }
        session.title = remote.title
        session.last_mode = mode
        session.remote_status = "busy"
        runtime.sessions[session.id] = session
        local job = require("opencode.job").new(session.id, {
          root = runtime.root,
          buf = context.buf,
          path = context.path,
          mode = mode,
          base = base,
          scope = scope,
          marks = marks,
          auto_apply = opts.auto_apply,
        })
        runtime.jobs[job.key] = job
        session.active_job_key = job.key
        session.activity = vim.uv.now()
        runtime.selected_session_id = session.id
        local payload = {
          messageID = job.user_message_id,
          agent = mode,
          parts = { { type = "text", text = rendered.plaintext } },
        }
        if mode == "build" then
          payload.format = { type = "json_schema", schema = vim.deepcopy(require("opencode.proposal").schema) }
          payload.parts[1].text = build_instruction(context, rendered, base, scope)
        end
        return runtime.client
          :prompt_async(session.id, payload)
          :next(function()
            if job.cancelling or job.state == "cancelled" then
              return Promise.reject({ error_class = "cancelled" })
            end
            if mode ~= "plan" then
              return job
            end
            local shown, show_error = runtime.sidebar:show()
            if not shown or not runtime.sidebar:is_visible() then
              return Promise.reject({ error_class = show_error or "tui_unavailable" })
            end
            return runtime.sidebar:select_session(session.id):next(function()
              if job.cancelling or job.state == "cancelled" then
                return Promise.reject({ error_class = "cancelled" })
              end
              return job
            end)
          end)
          :catch(function(err)
            job.error_class = type(err) == "table" and err.error_class or "prompt_http"
            return require("opencode.job").cancel(runtime, job.key):next(function()
              return Promise.reject(err)
            end)
          end)
      end)
      :catch(function(err)
        if marks then
          require("opencode.scope").delete_marks({ buffer = context.buf, marks = marks })
        end
        return Promise.reject(err)
      end)
  end)
end

return M
