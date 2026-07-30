local M = {}

local function verify_session(session, runtime, metadata)
  return session.directory == runtime.root
    and vim.deep_equal(session.metadata, metadata)
    and require("opencode.session").verify_permissions(session.permission or {})
end

---Dispatches one read-only Plan through Session HTTP after target and dirty preflight.
---The Job is registered before prompt_async so immediate SSE cannot outrun local correlation state.
---@param text string
---@param context table
---@return Promise<table>
function M.prompt(text, context)
  local Promise = require("opencode.promise")
  if text:match("^%s*/[%w_.-]+") then
    return Promise.reject({ error_class = "command_unsupported" })
  end
  local rendered = context:render(text)
  return require("opencode.context.preflight").run(context):next(function()
    local runtime = context.runtime
    if runtime.state ~= "ready" then
      return Promise.reject({ error_class = "runtime_not_ready" })
    end
    local metadata = require("opencode.session").metadata(runtime.root_hash)
    local rules = require("opencode.session").permissions
    return runtime.client
      :create_session({
        title = "Plan " .. vim.fs.basename(context.path),
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
        local job =
          require("opencode.job").new(session.id, { root = runtime.root, buf = context.buf, path = context.path })
        runtime.jobs[job.key] = job
        session.active_job_key = job.key
        runtime.sidebar:show()
        return runtime.client
          :prompt_async(session.id, {
            messageID = job.user_message_id,
            agent = "plan",
            parts = { { type = "text", text = rendered.plaintext } },
          })
          :next(function()
            return job
          end)
          :catch(function(err)
            require("opencode.job").finish(job, session, "error")
            return Promise.reject(err)
          end)
      end)
  end)
end

return M
