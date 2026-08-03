local M = {}

---Returns the Runtime's concrete prompt blocker while retaining compatibility with small test fakes.
---Production callers use Runtime:prompt_blocker so dispatch errors name the actual lock instead of a generic not-ready state.
local function prompt_blocker(runtime)
  if runtime.prompt_blocker then
    return runtime:prompt_blocker()
  end
  if not runtime:accepts_prompts() then
    return "runtime_not_ready"
  end
end

local function relative_path(root, path)
  return assert(vim.fs.relpath(root, path))
end

---Claims a buffer range while asynchronous Session preparation is in progress.
---The check and insertion do not yield, so overlapping prompts cannot both pass before either Job is registered.
---@param runtime table
---@param buffer integer
---@param scope table
---@return table?, string?
function M.claim_scope(runtime, buffer, scope)
  runtime.scope_claims = runtime.scope_claims or {}
  for claim in pairs(runtime.scope_claims) do
    if claim.buffer == buffer and require("opencode.scope").overlaps(claim.scope, scope) then
      return nil, "scope_overlap"
    end
  end
  local claim = { buffer = buffer, scope = { start_byte = scope.start_byte, end_byte = scope.end_byte } }
  runtime.scope_claims[claim] = true
  return claim
end

---Releases only the exact pending range claim owned by one prompt preparation.
---@param runtime table
---@param claim table?
function M.release_scope(runtime, claim)
  if claim and runtime.scope_claims then
    runtime.scope_claims[claim] = nil
  end
end

---Restores the pointer captured before one dispatch only if that dispatch still owns the selected value.
---A later successful dispatch is left untouched, so an older failed request cannot roll back a newer selection.
---@param runtime table
---@param session_id string
---@param previous_id string?
local function restore_selection(runtime, session_id, previous_id)
  if runtime.selected_session_id == session_id then
    runtime.selected_session_id = previous_id
  end
end

---Creates a verified Build Session or revalidates the explicitly requested or selected reusable Session.
---An active selection is rejected instead of queued; new-session requests always create a fresh Session.
---The Session claim is taken immediately before revalidation so concurrent prompts cannot register the same Session.
local function prepare_session(runtime, opts)
  local Promise = require("opencode.promise")
  local sessions = require("opencode.session")
  local selected_id
  if not opts.new_session then
    selected_id = opts.session_id or runtime.selected_session_id
  end

  ---Claims one reusable Session before its detail verification and releases it if verification fails.
  ---Fresh Sessions use the same claim after POST so registration cannot race a second prompt.
  local function claim_and_revalidate(session_id, skip_update)
    local claim, error_class = sessions.claim(runtime, session_id)
    if not claim then
      return Promise.reject({ error_class = error_class or "session_busy" })
    end
    local ok, result = pcall(sessions.revalidate, runtime, session_id, skip_update)
    if not ok then
      sessions.release_claim(runtime, session_id, claim)
      return Promise.reject(result)
    end
    return result:catch(function(err)
      sessions.release_claim(runtime, session_id, claim)
      return Promise.reject(err)
    end)
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
    return claim_and_revalidate(selected_id)
  end
  local metadata = sessions.metadata(runtime.root_hash)
  metadata.last_mode = "build"
  return runtime.client
    :create_session({
      metadata = metadata,
      permission = sessions.permissions,
    })
    :next(function(created)
      return claim_and_revalidate(created.id, true)
    end)
end

---Builds the prompt instruction that binds the model to one captured scope and its Base snapshot.
---The rendered user text is followed by the exact replacement contract used by proposal validation.
local function build_instruction(context, rendered, base, scope)
  return table.concat({
    rendered.plaintext,
    "",
    "Return a structured replacement for only this authorized scope.",
    "Target: " .. relative_path(context.runtime.root, context.path),
    "Base SHA-256: " .. base.sha256,
    string.format("Scope bytes: [%d,%d)", scope.start_byte, scope.end_byte),
    "replacement must contain the complete new text for that scope only.",
    "Return only replacement and summary in the structured output; target identity is attached locally.",
  }, "\n")
end

---Dispatches one scoped Build through Session HTTP after target and dirty preflight.
---The Job is registered before prompt_async so immediate SSE cannot outrun local correlation state; a Session claim covers
---revalidation and registration, and the selected pointer changes only after HTTP or exact SSE proves dispatch.
---Failed requests cancel the Job and remove its marks before returning the original error.
---@param text string
---@param context table
---@param opts? opencode.PromptOpts
---@return Promise<table>
function M.prompt(text, context, opts)
  local Promise = require("opencode.promise")
  opts = opts or {}
  if opts.mode ~= nil and opts.mode ~= "build" then
    return Promise.reject({ error_class = "mode_unavailable" })
  end
  if text:match("^%s*/[%w_.-]+") then
    return Promise.reject({ error_class = "command_unsupported" })
  end
  return require("opencode.context.preflight").run(context):next(function()
    local rendered = context:render(text)
    local runtime = context.runtime
    local blocker = prompt_blocker(runtime)
    if blocker then
      return Promise.reject({ error_class = blocker })
    end
    local base_error
    local base
    base, base_error = require("opencode.snapshot").capture(context.buf)
    if not base then
      return Promise.reject({ error_class = base_error or "disk_read" })
    end
    local scope_error
    local scope
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
    local scope_claim, claim_error = M.claim_scope(runtime, context.buf, candidate)
    if not scope_claim then
      return Promise.reject({ error_class = claim_error })
    end
    local function release_scope()
      M.release_scope(runtime, scope_claim)
      scope_claim = nil
    end
    local marks ---@type table?
    local marks_ok
    marks_ok, marks = pcall(require("opencode.scope").create_marks, context.buf, scope)
    if not marks_ok then
      release_scope()
      return Promise.reject(marks)
    end
    blocker = prompt_blocker(runtime)
    if blocker then
      if marks then
        require("opencode.scope").delete_marks({ buffer = context.buf, marks = marks })
        marks = nil
      end
      release_scope()
      return Promise.reject({ error_class = blocker })
    end
    local previous_selected_id = runtime.selected_session_id
    local claimed_session_id
    local claim
    local job
    local session
    local sessions = require("opencode.session")
    ---Releases this dispatch's claim without disturbing another prompt that may have taken the Session later.
    local function release_claim()
      if claimed_session_id and claim then
        sessions.release_claim(runtime, claimed_session_id, claim)
      end
    end
    ---Cancels a registered Job on dispatch failure and restores the prior pointer after cleanup is requested.
    local function fail_dispatch(err)
      release_scope()
      release_claim()
      restore_selection(runtime, claimed_session_id, previous_selected_id)
      if not job then
        return Promise.reject(err)
      end
      job.dispatch_pending = nil
      job.error_class = type(err) == "table" and err.error_class or "prompt_http"
      local ok, cancellation = pcall(require("opencode.job").cancel, runtime, job.key)
      if not ok then
        pcall(require("opencode.job").finish, job, session, "error")
        return Promise.reject(err)
      end
      return cancellation
        :next(function()
          release_claim()
          restore_selection(runtime, claimed_session_id, previous_selected_id)
          return Promise.reject(err)
        end)
        :catch(function()
          release_claim()
          restore_selection(runtime, claimed_session_id, previous_selected_id)
          return Promise.reject(err)
        end)
    end
    return prepare_session(runtime, opts)
      :next(function(remote)
        claimed_session_id = remote.id
        claim = runtime.session_claims and runtime.session_claims[claimed_session_id]
        local dispatch_blocker = prompt_blocker(runtime)
        if dispatch_blocker then
          return fail_dispatch({ error_class = dispatch_blocker })
        end
        session = runtime.sessions[remote.id]
          or { id = remote.id, root = runtime.root, short_id = remote.id:sub(-8), active_job_key = nil }
        session.title = remote.title
        session.last_mode = "build"
        session.remote_status = "busy"
        runtime.sessions[session.id] = session
        local ok, created_job = pcall(require("opencode.job").new, session.id, {
          root = runtime.root,
          buf = context.buf,
          path = context.path,
          base = base,
          scope = scope,
          marks = marks,
          auto_apply = opts.auto_apply,
        })
        if not ok then
          return fail_dispatch(created_job)
        end
        job = created_job
        job.runtime = runtime
        job.dispatch_pending = true
        runtime.jobs[job.key] = job
        session.active_job_key = job.key
        session.activity = vim.uv.now()
        if not sessions.bind_claim(runtime, session.id, claim, job.key) then
          return fail_dispatch({ error_class = "session_busy" })
        end
        release_scope()
        local payload_ok, payload = pcall(function()
          return {
            messageID = job.user_message_id,
            agent = "build",
            parts = { { type = "text", text = rendered.plaintext } },
            format = { type = "json_schema", schema = vim.deepcopy(require("opencode.proposal").schema) },
          }
        end)
        if not payload_ok then
          return fail_dispatch(payload)
        end
        local instruction_ok, instruction = pcall(build_instruction, context, rendered, base, scope)
        if not instruction_ok then
          return fail_dispatch(instruction)
        end
        payload.parts[1].text = instruction
        local request_ok, request = pcall(function()
          return runtime.client:prompt_async(session.id, payload)
        end)
        if not request_ok then
          return fail_dispatch(request)
        end
        return request
          :next(function()
            if job.cancelling or job.state == "cancelled" then
              return Promise.reject({ error_class = "cancelled" })
            end
            job.dispatch_pending = nil
            runtime.selected_session_id = session.id
            require("opencode.job").retain(runtime)
            return job
          end)
          :catch(function(err)
            if job.remote_observed and not job.cancelling and job.state ~= "cancelled" then
              job.dispatch_pending = nil
              runtime.selected_session_id = session.id
              require("opencode.job").retain(runtime)
              return job
            end
            job.dispatch_pending = nil
            return fail_dispatch(err)
          end)
      end)
      :catch(function(err)
        release_scope()
        release_claim()
        if claimed_session_id then
          restore_selection(runtime, claimed_session_id, previous_selected_id)
        end
        if marks then
          require("opencode.scope").delete_marks({ buffer = context.buf, marks = marks })
        end
        return Promise.reject(err)
      end)
  end)
end

return M
