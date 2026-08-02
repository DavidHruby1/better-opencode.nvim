local M = {}

local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local function random_chars(count)
  local bytes = assert(vim.uv.random(count))
  local result = {}
  for i = 1, count do
    local byte = bytes:byte(i)
    result[i] = alphabet:sub((byte % #alphabet) + 1, (byte % #alphabet) + 1)
  end
  return table.concat(result)
end

---Creates an OpenCode-compatible message ID.
---The time prefix keeps IDs sortable and cryptographic random bytes avoid collisions.
---@return string
function M.message_id()
  local time, chars = math.floor(vim.uv.now()), {}
  for i = 10, 1, -1 do
    local index = (time % 32) + 1
    chars[i] = alphabet:sub(index, index)
    time = math.floor(time / 32)
  end
  return "msg_" .. table.concat(chars) .. random_chars(16)
end

---Creates a fully captured Build Job before network dispatch.
---Build scope marks own a transient inline display from this point until conflict or completion.
---@param session_id string
---@param target table
---@return table
function M.new(session_id, target)
  local message_id = M.message_id()
  local job = {
    key = session_id .. ":" .. message_id,
    merge_key = target.root .. ":" .. session_id .. ":" .. message_id,
    session_id = session_id,
    user_message_id = message_id,
    assistant_message_ids = {},
    assistant_messages = {},
    root = target.root,
    mode = "build",
    state = "running",
    buffer = target.buf,
    path = target.path,
    base = target.base,
    scope = target.scope,
    marks = target.marks,
    auto_apply = target.auto_apply ~= false,
  }
  if job.marks then
    job.request_status = require("opencode.ui.request_status").new(job)
  end
  return job
end

local terminal_states = { completed = true, cancelled = true, error = true, scope_violation = true }
local terminal_limit = 100

function M.terminal(state)
  return terminal_states[state] == true
end

---Keeps a bounded diagnostic tail of terminal Jobs without removing a Job whose HTTP dispatch can still settle.
---Assistant mappings owned by removed Jobs are dropped with them so later events fail closed as unknown identities.
---@param runtime table?
function M.retain(runtime)
  if not runtime then
    return
  end
  local terminal = {}
  for _, job in pairs(runtime.jobs or {}) do
    if M.terminal(job.state) and not job.dispatch_pending then
      table.insert(terminal, job)
    end
  end
  table.sort(terminal, function(a, b)
    return (a.finished_sequence or 0) > (b.finished_sequence or 0)
  end)
  for index = terminal_limit + 1, #terminal do
    local removed = terminal[index]
    runtime.jobs[removed.key] = nil
    for identity, key in pairs(runtime.assistant_jobs or {}) do
      if key == removed.key then
        runtime.assistant_jobs[identity] = nil
      end
    end
  end
end

local transitions = {
  running = {
    waiting_user = true,
    pending_apply = true,
    completed = true,
    cancelled = true,
    error = true,
    scope_violation = true,
  },
  waiting_user = { running = true, cancelled = true, error = true },
  pending_apply = { completed = true, conflict = true, cancelled = true, error = true, scope_violation = true },
  conflict = { completed = true, cancelled = true, error = true },
}

---Moves a Job through the complete managed state machine and owns state-specific cleanup.
---Required kinds and payloads are checked before mutation; repeated terminal completion is idempotent.
---Conflict and terminal states remove transient Build UI immediately; the Session is supplied because only terminal states release it.
---@param job table
---@param state string
---@param attrs? { runtime?: table, session?: table, waiting_kind?: "question"|"permission", conflict_kind?: "agent"|"external_change", conflict_payload?: table }
---@return boolean
function M.transition(job, state, attrs)
  attrs = attrs or {}
  if terminal_states[job.state] then
    return job.state == state
  end
  if not transitions[job.state] or not transitions[job.state][state] then
    return false
  end
  if state == "waiting_user" and attrs.waiting_kind ~= "question" and attrs.waiting_kind ~= "permission" then
    return false
  end
  if
    state == "conflict"
    and (attrs.conflict_kind ~= "agent" and attrs.conflict_kind ~= "external_change" or not attrs.conflict_payload)
  then
    return false
  end
  local leaving_conflict = job.state == "conflict"
  job.state = state
  if state == "conflict" or terminal_states[state] then
    require("opencode.ui.request_status").cleanup(job.request_status)
    job.request_status = nil
  end
  job.waiting_kind = state == "waiting_user" and attrs.waiting_kind or nil
  if state ~= "waiting_user" then
    job.waiting_request_id = nil
    job.waiting_remote = nil
  end
  job.conflict_kind = state == "conflict" and attrs.conflict_kind or nil
  if leaving_conflict then
    job.conflict_payload = nil
  elseif state == "conflict" then
    job.conflict_payload = vim.deepcopy(attrs.conflict_payload)
  end
  if terminal_states[state] then
    if job.insert_leave then
      pcall(vim.api.nvim_del_autocmd, job.insert_leave)
      job.insert_leave = nil
    end
    require("opencode.scope").delete_marks(job)
    job.proposal, job.theirs, job.conflict_payload = nil, nil, nil
    local session = attrs.session
    if session and session.active_job_key == job.key then
      session.active_job_key = nil
      session.last_job_state = state
    end
    local runtime = attrs.runtime or job.runtime or require("opencode.runtime").for_root(job.root)
    local claim = runtime and runtime.session_claims and runtime.session_claims[job.session_id]
    if
      runtime
      and claim
      and (claim == job.key or type(claim) ~= "table" or claim.pending or claim.job_key == job.key)
    then
      runtime.session_claims[job.session_id] = nil
    end
    local interaction = package.loaded["opencode.interaction"]
    if interaction then
      interaction.remove_by_job(job.root, job.key)
    end
    if state == "completed" or state == "error" or state == "scope_violation" then
      if runtime then
        local notify = require("opencode.ui.notify")
        notify.emit(state, notify.snapshot(runtime, job), runtime)
      end
    end
    if runtime then
      runtime.terminal_sequence = (runtime.terminal_sequence or 0) + 1
      job.finished_sequence = runtime.terminal_sequence
      M.retain(runtime)
    end
    job.runtime = nil
  end
  return true
end

---Cancels one Job locally before making one remote abort request shared by every caller.
---Owned marks, proposal, merge files, callbacks, and dialogs are removed by their behavior homes. A successful abort
---releases the Session; a failed abort blocks reuse and starts reconciliation because remote work may still be running.
---@param runtime table
---@param key string
---@return Promise<table>
function M.cancel(runtime, key)
  local Promise = require("opencode.promise")
  local job = runtime.jobs[key]
  if not job then
    return Promise.resolve({ cancelled = 0, errors = 0 })
  end
  if job.cancel_promise then
    return job.cancel_promise
  end
  if M.terminal(job.state) then
    return Promise.resolve({ cancelled = 0, errors = 0 })
  end
  job.cancelling = true
  local session = runtime.sessions[job.session_id]
  local interaction = require("opencode.interaction")
  interaction.reject_by_job(runtime, job)
  local merge = require("opencode.merge")
  if merge.cleanup then
    merge.cleanup(job.merge_key or job.key)
  end
  M.transition(job, "cancelled", { session = session })
  local function report(errors)
    if session then
      if errors == 0 then
        session.remote_status = "idle"
        session.availability = "reusable"
        session.availability_reason = nil
      else
        session.remote_status = "busy"
        session.availability, session.availability_reason =
          require("opencode.session").availability(runtime, session, session.remote_status)
        if runtime.begin_reconciliation then
          runtime:begin_reconciliation()
        end
      end
    end
    return { cancelled = 1, errors = errors }
  end
  if not runtime.client or job.remote_idle then
    job.cancel_promise = Promise.resolve(report(0))
    return job.cancel_promise
  end
  job.cancel_promise = runtime.client
    :abort(job.session_id)
    :next(function()
      return Promise.resolve(report(0))
    end)
    :catch(function(err)
      job.cancel_error_class = type(err) == "table" and err.error_class or "abort"
      return Promise.resolve(report(1))
    end)
  return job.cancel_promise
end

---Cancels a snapshot of every nonterminal Job in one Runtime.
---All local cancellations run even when individual Session aborts fail or mutate the registry.
---@param runtime table
---@return Promise<table>
function M.cancel_all(runtime)
  local keys = {}
  for key, job in pairs(runtime.jobs) do
    if not M.terminal(job.state) then
      table.insert(keys, key)
    end
  end
  local cancellations = {}
  for _, key in ipairs(keys) do
    table.insert(cancellations, M.cancel(runtime, key))
  end
  return require("opencode.promise").all(cancellations):next(function(results)
    local report = { root = vim.fs.basename(runtime.root), cancelled = 0, errors = 0 }
    for _, result in ipairs(results) do
      report.cancelled = report.cancelled + result.cancelled
      report.errors = report.errors + result.errors
    end
    return require("opencode.promise").resolve(report)
  end)
end

---Makes a running Build Job terminal exactly once and releases its Session.
---@param job table
---@param session table
---@param state "completed"|"cancelled"|"error"
---@return boolean
function M.finish(job, session, state)
  return M.transition(job, state, { session = session })
end

return M
