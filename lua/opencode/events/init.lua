local M = {}

local hard_denies = {
  edit = true,
  write = true,
  apply_patch = true,
  bash = true,
  task = true,
  external_directory = true,
}
local approvable = { webfetch = true, websearch = true, doom_loop = true }

---Classifies a permission independently from the Server's model-surface filtering.
---Unknown and write-capable names fail closed; read-like requests cannot create permanent approval.
function M.permission_policy(name)
  if hard_denies[name] or not (approvable[name] or name == "read") then
    return "hard_reject"
  end
  if name == "read" or name == "external_directory" then
    return "ask_once"
  end
  return "ask_once_always"
end

local function identity(properties)
  local info = properties.info or properties
  return info.sessionID or properties.sessionID, info.id or info.requestID or properties.requestID, info
end

local function request_reconcile(runtime)
  if runtime.client and runtime.begin_reconciliation then
    runtime:begin_reconciliation()
  end
end

local function active(runtime, session_id)
  local session = runtime.sessions[session_id]
  local job = session and runtime.jobs[session.active_job_key]
  if
    not job
    or require("opencode.job").terminal(job.state)
    or job.session_id ~= session_id
    or job.root ~= runtime.root
  then
    runtime.prompt_locked = true
    runtime.reconciliation_required = true
    request_reconcile(runtime)
    return nil
  end
  return session, job
end

local function unknown(runtime, class)
  runtime.prompt_locked = true
  runtime.reconciliation_required = true
  runtime.correlation = runtime.correlation or { exact = 0, late = 0, unknown = 0 }
  runtime.correlation.unknown = runtime.correlation.unknown + 1
  runtime.correlation.unknown_classes = runtime.correlation.unknown_classes or {}
  runtime.correlation.unknown_classes[class] = (runtime.correlation.unknown_classes[class] or 0) + 1
  if class ~= "part_unmapped" then
    request_reconcile(runtime)
  end
end

local function late(runtime, job)
  job.late_event_count = (job.late_event_count or 0) + 1
  runtime.correlation = runtime.correlation or { exact = 0, late = 0, unknown = 0 }
  runtime.correlation.late = runtime.correlation.late + 1
end

local function exact(runtime, job)
  runtime.correlation = runtime.correlation or { exact = 0, late = 0, unknown = 0 }
  runtime.correlation.exact = runtime.correlation.exact + 1
  if require("opencode.job").terminal(job.state) or job.cancelling then
    late(runtime, job)
    return false
  end
  return true
end

---Reconciles one part that arrived before its assistant bootstrap through exact message detail.
---The prompt gate reopens only after the fetched assistant parent proves a registered Job identity.
---Failures remain fail-closed and never replay the discarded part into another Job.
local function reconcile_part(runtime, session_id, assistant_id)
  unknown(runtime, "part_unmapped")
  if not session_id or not assistant_id or not runtime.client then
    return
  end
  local function unlock_if_mapped()
    if not runtime.assistant_jobs[session_id .. ":" .. assistant_id] then
      return false
    end
    runtime.reconciliation_required = false
    if not runtime.interaction_locked then
      runtime.prompt_locked = false
    end
    return true
  end
  local function unlock_reconciled()
    runtime.reconciliation_required = false
    if not runtime.interaction_locked then
      runtime.prompt_locked = false
    end
  end
  local function attempt(number)
    if unlock_if_mapped() then
      return
    end
    runtime.client
      :message(session_id, assistant_id)
      :next(function(message)
        local info = message.info or message
        if
          info.sessionID == session_id
          and info.role == "user"
          and info.id == assistant_id
          and runtime.jobs[session_id .. ":" .. assistant_id]
        then
          unlock_reconciled()
          return
        end
        local job = info.parentID and runtime.jobs[session_id .. ":" .. info.parentID]
        if info.sessionID ~= session_id or info.role ~= "assistant" or info.id ~= assistant_id or not job then
          if number < 3 then
            vim.defer_fn(function()
              attempt(number + 1)
            end, 100)
          end
          return
        end
        job.assistant_message_ids[assistant_id] = true
        runtime.assistant_jobs[session_id .. ":" .. assistant_id] = job.key
        unlock_if_mapped()
      end)
      :catch(function()
        if number < 3 then
          vim.defer_fn(function()
            attempt(number + 1)
          end, 100)
        end
      end)
  end
  attempt(1)
end

---Routes user, assistant, and part events only through immutable message identities.
---Assistant IDs bootstrap from an exact parent Job and remain mapped after that Job terminates.
---Unknown events close the prompt gate for reconciliation rather than borrowing UI selection or latest state.
local function route_message(runtime, event)
  if event.type ~= "message.updated" and not event.type:match("^message%.part%.") then
    return false
  end
  local properties = event.properties or {}
  local info = properties.info or properties.message or properties.part or properties
  local session_id = info.sessionID or properties.sessionID
  if event.type == "message.updated" then
    local key
    if info.role == "user" then
      key = session_id and info.id and (session_id .. ":" .. info.id)
    elseif info.role == "assistant" then
      key = session_id and info.parentID and (session_id .. ":" .. info.parentID)
    end
    local job = key and runtime.jobs[key]
    if not job then
      unknown(runtime, "message_" .. tostring(info.role or "unknown"))
      return true
    end
    if info.role == "assistant" and info.id then
      job.assistant_message_ids[info.id] = true
      job.assistant_messages[info.id] = {
        info = {
          id = info.id,
          role = "assistant",
          parentID = info.parentID,
          structured = type(info.structured) == "table" and vim.deepcopy(info.structured) or nil,
        },
      }
      runtime.assistant_jobs[session_id .. ":" .. info.id] = job.key
    end
    exact(runtime, job)
    return true
  end
  local assistant_id = info.messageID or properties.messageID
  local key = session_id and assistant_id and runtime.assistant_jobs[session_id .. ":" .. assistant_id]
  local job = key and runtime.jobs[key]
  if not job then
    reconcile_part(runtime, session_id, assistant_id)
    return true
  end
  exact(runtime, job)
  return true
end

---Routes question and permission events using only the stream Runtime and Session's active Job.
---Requests without a provable Job fail closed, while matching reply events alone release waiting state and UI locks.
---@return boolean handled
function M.route(runtime, event)
  local properties = event.properties or {}
  local event_root = properties.directory or properties.root or (properties.info and properties.info.directory)
  if event_root and require("opencode.runtime.root").realpath(event_root) ~= runtime.root then
    unknown(runtime, "root_mismatch")
    return true
  end
  if route_message(runtime, event) then
    return true
  end
  local session_id, request_id, payload = identity(event.properties or {})
  local kind = event.type:match("^(question)") or event.type:match("^(permission)")
  if not kind then
    return false
  end
  local session, job = active(runtime, session_id)
  if not session then
    return true
  end
  local completed = event.type == "question.replied"
    or event.type == "question.rejected"
    or event.type == "permission.replied"
    or event.type == "permission.rejected"
  if completed then
    local interaction = require("opencode.interaction")
    if
      job.state == "waiting_user"
      and job.waiting_kind == kind
      and interaction.has_remote(session_id, job.key, request_id, runtime.root)
    then
      runtime.confirmed_requests[job.key .. ":" .. request_id] = runtime.generation
      if require("opencode.job").transition(job, "running", { session = session }) then
        interaction.confirm(session_id, job.key, request_id, runtime.root)
      end
    end
    return true
  end
  if event.type ~= kind .. ".asked" or job.state ~= "running" or not request_id then
    return true
  end
  if kind == "permission" then
    local name = payload.permission or payload.name or payload.type
    local policy = M.permission_policy(name)
    if policy == "hard_reject" then
      runtime.client:permission_reply(request_id, "reject")
      job.error_class = "hard_denied_permission"
      require("opencode.job").transition(job, "error", { session = session })
      runtime.prompt_locked, runtime.reconciliation_required = true, true
      return true
    end
    payload.actions = policy == "ask_once" and { "once", "reject" } or { "once", "always", "reject" }
  end
  if not require("opencode.job").transition(job, "waiting_user", { session = session, waiting_kind = kind }) then
    return true
  end
  job.waiting_request_id = request_id
  require("opencode.interaction").enqueue({
    kind = kind,
    root = runtime.root,
    session_id = session_id,
    session_short_id = session_id:sub(-8),
    job_key = job.key,
    request_id = request_id,
    payload = payload,
  })
  local notify = require("opencode.ui.notify")
  notify.emit(kind, notify.snapshot(runtime, job), runtime)
  return true
end

return M
