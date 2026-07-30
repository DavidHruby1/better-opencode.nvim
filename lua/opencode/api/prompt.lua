local M = {}

local function verify_session(session, runtime, metadata)
  return session.directory == runtime.root
    and vim.deep_equal(session.metadata, metadata)
    and require("opencode.session").verify_permissions(session.permission or {})
end

local function relative_path(root, path)
  return assert(vim.fs.relpath(root, path))
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
---The Job is registered before prompt_async so immediate SSE cannot outrun local correlation state.
---@param text string
---@param context table
---@param opts? { mode?: "plan"|"build", scope?: "file", auto_apply?: boolean }
---@return Promise<table>
function M.prompt(text, context, opts)
  local Promise = require("opencode.promise")
  opts = opts or {}
  local mode = opts.mode or "build"
  if text:match("^%s*/[%w_.-]+") then
    return Promise.reject({ error_class = "command_unsupported" })
  end
  local rendered = context:render(text)
  return require("opencode.context.preflight").run(context):next(function()
    local runtime = context.runtime
    if runtime.state ~= "ready" then
      return Promise.reject({ error_class = "runtime_not_ready" })
    end
    local base, scope, marks
    if mode == "build" then
      base = assert(require("opencode.snapshot").capture(context.buf))
      local scope_error
      scope, scope_error = require("opencode.scope").resolve(context, base, opts.scope)
      if not scope then
        return Promise.reject({ error_class = scope_error })
      end
      local candidate = { start_byte = scope.start_byte, end_byte = scope.end_byte }
      local overlap = require("opencode.scope").find_overlap(runtime, context.buf, candidate)
      if overlap then
        return Promise.reject({ error_class = "scope_overlap", job_short_id = overlap.user_message_id:sub(-8) })
      end
      marks = require("opencode.scope").create_marks(context.buf, scope)
    end
    local metadata = require("opencode.session").metadata(runtime.root_hash)
    local rules = require("opencode.session").permissions
    return runtime.client
      :create_session({
        title = (mode == "build" and "Build " or "Plan ") .. vim.fs.basename(context.path),
        metadata = metadata,
        permission = rules,
      })
      :next(function(created)
        return runtime.client:update_session(created.id, { metadata = metadata, permission = rules }):next(function()
          return runtime.client:get_session(created.id)
        end)
      end)
      :next(function(remote)
        if not verify_session(remote, runtime, metadata) then
          return Promise.reject({ error_class = "session_verification" })
        end
        local session = {
          id = remote.id,
          root = runtime.root,
          title = remote.title,
          short_id = remote.id:sub(-8),
          active_job_key = nil,
          last_job_state = nil,
        }
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
        runtime.sidebar:show()
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
            return job
          end)
          :catch(function(err)
            require("opencode.job").transition(job, session, "error")
            return Promise.reject(err)
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
