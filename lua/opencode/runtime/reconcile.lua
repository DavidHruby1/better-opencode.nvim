local M = {}

---Converts the supported endpoint collection shapes into one ordered list without changing payload content.
local function entries(value)
  if type(value) ~= "table" then
    return {}
  end
  if type(value.items) == "table" then
    return value.items
  end
  if vim.islist(value) then
    return value
  end
  local result = {}
  for id, item in pairs(value) do
    if type(item) == "table" then
      local copy = vim.deepcopy(item)
      copy.id = copy.id or copy.sessionID or id
      table.insert(result, copy)
    elseif type(item) == "string" then
      table.insert(result, { id = id, status = item })
    end
  end
  return result
end

---Reads one Session status from either the keyed or list response form.
local function status_for(statuses, session_id)
  if type(statuses) ~= "table" then
    return nil
  end
  local direct = statuses[session_id]
  if type(direct) == "string" then
    return direct
  end
  if type(direct) == "table" then
    return direct.status or direct.state or direct.type
  end
  for _, item in ipairs(entries(statuses)) do
    if item.id == session_id or item.sessionID == session_id then
      return item.status or item.state or item.type
    end
  end
  return nil
end

local function message_info(message)
  return message.info or message.message or message
end

local function request_info(request)
  local info = request.info or request
  return info.sessionID or request.sessionID, info.id or info.requestID or request.requestID, info
end

local function request_order(a, b)
  local function stamp(request)
    local _, id, info = request_info(request)
    return info.timestamp or info.createdAt or info.created_at or 0, id or ""
  end
  local at, ai = stamp(a)
  local bt, bi = stamp(b)
  if at ~= bt then
    return at < bt
  end
  return ai < bi
end

local function active_jobs(runtime)
  local result = {}
  for _, job in pairs(runtime.jobs) do
    if not require("opencode.job").terminal(job.state) then
      table.insert(result, job)
    end
  end
  table.sort(result, function(a, b)
    return a.key < b.key
  end)
  return result
end

---Rebuilds assistant correlation maps only for messages whose parent is this exact Job.
local function register_messages(runtime, job, messages)
  for _, message in ipairs(entries(messages)) do
    local info = message_info(message)
    if info.role == "assistant" and info.parentID == job.user_message_id and info.id then
      job.assistant_message_ids[info.id] = true
      job.assistant_messages[info.id] = {
        info = {
          id = info.id,
          role = "assistant",
          parentID = info.parentID,
          structured = type(info.structured) == "table" and vim.deepcopy(info.structured) or nil,
        },
      }
      runtime.assistant_jobs[job.session_id .. ":" .. info.id] = job.key
    end
  end
end

---Selects assistant results by exact parent identity for one completion decision.
local function matching_assistants(job, messages)
  local result = {}
  for _, message in ipairs(entries(messages)) do
    local info = message_info(message)
    if info.role == "assistant" and info.parentID == job.user_message_id and info.id then
      table.insert(result, info)
    end
  end
  return result
end

---Reports whether a Session message snapshot contains a response owned by this exact Job.
---Live idle events can belong to an earlier turn during Session reuse, so callers wait instead of completing or failing the new Job.
---@param job table
---@param messages table
---@return boolean
function M.has_parent_response(job, messages)
  return #matching_assistants(job, messages) > 0
end

---Completes one Build Job from an exact Session message snapshot.
---Exactly one structured assistant message must pass the existing proposal validator before the Job can enter apply; state guards make repeated reconnect snapshots completion-once.
---@param runtime table
---@param session table
---@param job table
---@param messages table
---@return boolean
function M.complete_job(runtime, session, job, messages)
  if job.state ~= "running" or job.cancelling then
    return false
  end
  local matches = matching_assistants(job, messages)
  session.remote_status = "idle"
  session.availability = "reusable"
  session.availability_reason = nil
  if #matches == 0 then
    job.error_class = "missing_result"
    require("opencode.job").finish(job, session, "error")
    return false
  end
  local structured = {}
  for _, info in ipairs(matches) do
    if type(info.structured) == "table" then
      table.insert(structured, info)
    end
  end
  if #structured ~= 1 then
    job.error_class = "structured_output_count"
    require("opencode.job").finish(job, session, "error")
    return false
  end
  local validated, err = require("opencode.proposal").validate(structured[1].structured, job)
  if not validated then
    job.error_class = err and err.error_class or "proposal_validation"
    require("opencode.job").transition(
      job,
      err and err.error_class == "scope_violation" and "scope_violation" or "error",
      { session = session }
    )
    return false
  end
  job.completion_count = (job.completion_count or 0) + 1
  job.structured_assistant_message_id = structured[1].id
  job.proposal, job.theirs = validated.proposal, validated.theirs
  require("opencode.job").transition(job, "pending_apply", { session = session })
  if job.auto_apply then
    require("opencode.apply").start(job, runtime)
  end
  return true
end

---Reconstructs one Job's pending interaction or fails it when neither pending nor a current-generation confirmation exists.
local function pending_for_job(runtime, job, pending, generation)
  local interaction = require("opencode.interaction")
  local seen = {}
  for _, request in ipairs(pending) do
    local session_id, request_id, payload = request_info(request)
    if session_id == job.session_id and request_id then
      local key = job.session_id .. ":" .. job.key .. ":" .. request_id
      seen[key] = true
      if job.state == "running" then
        job.waiting_remote = true
        require("opencode.job").transition(job, "waiting_user", {
          session = runtime.sessions[job.session_id],
          waiting_kind = payload.kind or job.waiting_kind,
        })
      end
      job.waiting_request_id = request_id
      if not interaction.has_remote(job.session_id, job.key, request_id, runtime.root) then
        interaction.enqueue({
          kind = payload.kind or job.waiting_kind,
          root = runtime.root,
          session_id = job.session_id,
          session_short_id = (runtime.sessions[job.session_id] and runtime.sessions[job.session_id].short_id)
            or job.session_id:sub(-8),
          job_key = job.key,
          request_id = request_id,
          payload = payload,
        })
      end
    end
  end
  if job.state == "waiting_user" then
    local confirmation = runtime.confirmed_requests[job.key .. ":" .. (job.waiting_request_id or "")]
    if not next(seen) and not confirmation then
      job.error_class = "missing_pending_request"
      require("opencode.job").finish(job, runtime.sessions[job.session_id], "error")
    elseif confirmation and confirmation == generation then
      require("opencode.job").transition(job, "running", { session = runtime.sessions[job.session_id] })
      job.waiting_remote = nil
    end
  end
end

---Loads questions before permissions and returns a stable timestamp/ID ordered interaction list.
local function collect_pending(runtime)
  local Promise = require("opencode.promise")
  return runtime.client:questions():next(function(questions)
    local result = {}
    for _, request in ipairs(entries(questions)) do
      local _, _, payload = request_info(request)
      payload.kind = "question"
      table.insert(result, request)
    end
    return runtime.client:permissions():next(function(permissions)
      for _, request in ipairs(entries(permissions)) do
        local _, _, payload = request_info(request)
        payload.kind = "permission"
        table.insert(result, request)
      end
      table.sort(result, request_order)
      return result
    end)
  end)
end

---Blocks the Runtime when remote work or requests cannot be attributed to a local active Job.
local function mark_unowned_remote_work(runtime, statuses, pending)
  local blocked = false
  for _, status in ipairs(entries(statuses)) do
    local session_id = status.id or status.sessionID
    local value = status.status or status.state or status.type
    if value == "busy" or value == "running" then
      local session = runtime.sessions[session_id]
      local job = session and session.active_job_key and runtime.jobs[session.active_job_key]
      if not job or require("opencode.job").terminal(job.state) then
        blocked = true
      end
    end
  end
  for _, request in ipairs(pending) do
    local session_id = request_info(request)
    local session = session_id and runtime.sessions[session_id]
    local job = session and session.active_job_key and runtime.jobs[session.active_job_key]
    if not job or require("opencode.job").terminal(job.state) then
      blocked = true
    end
  end
  runtime.reconciliation_blocked = blocked
  if blocked then
    runtime.prompt_locked = true
  end
end

---Closes one reconciliation generation, records its prompt blocker, and replays only same-stream events after success.
---A failed or genuinely blocked snapshot stays fail-closed; only a complete successful snapshot may clear obsolete locks.
local function finish(runtime, generation, sequence, ok, err)
  if
    runtime.generation ~= generation
    or runtime.reconcile_generation ~= sequence
    or runtime.state == "stopping"
    or runtime.state == "stopped"
  then
    return
  end
  runtime.reconciling = false
  runtime.reconcile_error = err
  runtime.reconciliation_failed = not ok
  if not ok then
    runtime.prompt_locked = true
    runtime.reconciliation_required = true
    require("opencode.ui.notify").error(err)
  end
  if ok and runtime.sse_live and (runtime.state == "starting" or runtime.state == "disconnected") then
    if runtime.state ~= "starting" or not runtime.startup_deadline or vim.uv.now() < runtime.startup_deadline then
      runtime:transition("ready")
    end
  end
  if ok then
    runtime.reconcile_error = nil
    runtime.reconciliation_failed = nil
    runtime.reconciliation_required = runtime.reconciliation_blocked == true
    runtime.reconnect_attempt = 0
    runtime.reconnect_error = nil
  end
  if ok and runtime.state == "ready" and not runtime.interaction_locked and not runtime.reconciliation_blocked then
    runtime.prompt_locked = false
  end
  if ok then
    local buffered = runtime.buffered_events or {}
    runtime.buffered_events = {}
    for _, item in ipairs(buffered) do
      if item.generation == runtime.stream_generation then
        runtime:route_event(item.event)
      end
    end
  end
  require("opencode.log").write({
    level = ok and "info" or "error",
    root_hash = runtime.root_hash,
    runtime_state = runtime.state,
    error_class = not ok and (type(err) == "table" and err.error_class or "reconciliation") or nil,
  })
end

---Runs the one bounded recovery snapshot for a Runtime and only then reopens prompts.
---Requests are issued in status, exact messages, questions, permissions order; idle Jobs finish only from exact parent
---identities, while busy and local apply/dialog states are preserved. Startup may supply the already fetched status
---response to avoid a duplicate request.
---@param runtime table
---@param generation? integer
---@param statuses? table
---@return Promise<table>
function M.run(runtime, generation, statuses)
  local Promise = require("opencode.promise")
  generation = generation or runtime.generation
  runtime.reconcile_sequence = (runtime.reconcile_sequence or 0) + 1
  local sequence = runtime.reconcile_sequence
  runtime.reconciling = true
  runtime.prompt_locked = true
  runtime.reconcile_generation = sequence
  local jobs = active_jobs(runtime)
  local snapshots = {}
  ---Rejects callbacks from an older transport or reconciliation run before they can change local state.
  local function current()
    return runtime.generation == generation
      and runtime.reconcile_generation == sequence
      and runtime.state ~= "stopping"
      and runtime.state ~= "stopped"
  end
  local function require_current()
    if not current() then
      return Promise.reject({ error_class = "stale_generation" })
    end
    return nil
  end
  ---Ends remote-dependent Jobs when this snapshot cannot prove their state and leaves local apply/conflict work intact.
  local function fail_remote_jobs(err)
    if not current() then
      return
    end
    for _, job in ipairs(jobs) do
      if job.state == "running" or job.state == "waiting_user" then
        local session = runtime.sessions[job.session_id]
        job.error_class = type(err) == "table" and err.error_class or "reconciliation"
        job.error_endpoint = type(err) == "table" and err.endpoint or nil
        job.error_status = type(err) == "table" and err.status or nil
        if session then
          session.availability = "blocked"
          session.availability_reason = "reconciliation_failed"
        end
        require("opencode.job").finish(job, session, "error")
      end
    end
  end
  local snapshot = Promise.resolve(statuses or runtime.client:session_status())
    :next(function(statuses)
      local stale = require_current()
      if stale then
        return stale
      end
      runtime.reconcile_statuses = statuses
      for _, session in pairs(runtime.sessions) do
        if session.availability == "blocked" and not session.active_job_key then
          session.remote_status = status_for(statuses, session.id) or "idle"
          session.availability, session.availability_reason =
            require("opencode.session").availability(runtime, session, session.remote_status)
        end
      end
      for _, job in ipairs(jobs) do
        local session = runtime.sessions[job.session_id]
        local status = status_for(statuses, job.session_id)
        -- OpenCode omits idle Sessions from this endpoint; local managed inventory proves existence until messages are checked.
        status = status or (session and "idle")
        if not session or not status then
          job.error_class = "missing_session"
          require("opencode.job").finish(job, session, "error")
        else
          session.remote_status = status
          table.insert(
            snapshots,
            runtime.client
              :messages(job.session_id)
              :next(function(messages)
                local stale = require_current()
                if stale then
                  return stale
                end
                register_messages(runtime, job, messages)
                return { job = job, session = session, status = status, messages = messages }
              end)
              :catch(function(err)
                if current() then
                  job.error_class = type(err) == "table" and err.error_class or "message_reconciliation"
                  job.error_endpoint = type(err) == "table" and err.endpoint or nil
                  job.error_status = type(err) == "table" and err.status or nil
                end
                if current() and (job.state == "running" or job.state == "waiting_user") then
                  require("opencode.job").finish(job, session, "error")
                end
                return Promise.reject(err)
              end)
          )
        end
      end
      return Promise.all(snapshots)
    end)
    :next(function(results)
      local stale = require_current()
      if stale then
        return stale
      end
      return collect_pending(runtime):next(function(pending)
        local pending_stale = require_current()
        if pending_stale then
          return pending_stale
        end
        mark_unowned_remote_work(runtime, runtime.reconcile_statuses, pending)
        for _, job in ipairs(jobs) do
          if not require("opencode.job").terminal(job.state) then
            local matching = {}
            for _, request in ipairs(pending) do
              local session_id = request_info(request)
              if session_id == job.session_id then
                table.insert(matching, request)
              end
            end
            pending_for_job(runtime, job, matching, generation)
          end
        end
        for _, snapshot in ipairs(results) do
          local job = snapshot.job
          if job.state == "running" and not job.waiting_remote then
            if snapshot.status == "busy" or snapshot.status == "running" then
              job.remote_idle = false
            elseif snapshot.status == "idle" then
              job.remote_idle = true
              M.complete_job(runtime, snapshot.session, job, snapshot.messages)
            else
              job.error_class = "unknown_session_status"
              require("opencode.job").finish(job, snapshot.session, "error")
            end
          end
        end
        finish(runtime, generation, sequence, true)
        return runtime
      end)
    end)
  local timeout = Promise.new(function(_, reject)
    vim.defer_fn(function()
      reject({ error_class = current() and "reconciliation_timeout" or "stale_generation" })
    end, require("opencode.config").opts.runtime.startup_timeout)
  end)
  return Promise.race({ snapshot, timeout }):catch(function(err)
    fail_remote_jobs(err)
    finish(runtime, generation, sequence, false, err)
    return Promise.reject(err)
  end)
end

return M
