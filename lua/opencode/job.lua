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

---Creates a running Plan or fully captured Build Job before network dispatch.
---@param session_id string
---@param target table
---@return table
function M.new(session_id, target)
  local message_id = M.message_id()
  return {
    key = session_id .. ":" .. message_id,
    session_id = session_id,
    user_message_id = message_id,
    assistant_message_ids = {},
    assistant_messages = {},
    root = target.root,
    mode = target.mode or "plan",
    state = "running",
    buffer = target.buf,
    path = target.path,
    base = target.base,
    scope = target.scope,
    marks = target.marks,
    auto_apply = target.auto_apply ~= false,
  }
end

local terminal_states = { completed = true, cancelled = true, error = true, scope_violation = true }

function M.terminal(state)
  return terminal_states[state] == true
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
  waiting_user = { running = true },
  pending_apply = { completed = true, conflict = true, cancelled = true, error = true, scope_violation = true },
  conflict = { completed = true, cancelled = true, error = true },
}

---Moves a Job through the complete managed state machine and owns state-specific cleanup.
---Required kinds and payloads are checked before mutation; repeated terminal completion is idempotent.
---The Session is supplied in attrs because only terminal transitions release it.
---@param job table
---@param state string
---@param attrs? { session?: table, waiting_kind?: "question"|"permission", conflict_kind?: "agent"|"external_change", conflict_payload?: table }
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
  job.waiting_kind = state == "waiting_user" and attrs.waiting_kind or nil
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
    local interaction = package.loaded["opencode.interaction"]
    if interaction then
      interaction.remove_by_job(job.root, job.key)
    end
  end
  return true
end

---Cancels one Job locally before making a best-effort remote abort request.
---Owned marks, proposal, merge files, callbacks, and dialogs are removed by their behavior homes.
---The early cancelling guard makes every later event or apply callback a no-op even when abort fails.
---@param runtime table
---@param key string
---@return Promise<table>
function M.cancel(runtime, key)
  local Promise = require("opencode.promise")
  local job = runtime.jobs[key]
  if not job or M.terminal(job.state) or job.cancelling then
    return Promise.resolve({ cancelled = 0, errors = 0 })
  end
  job.cancelling = true
  local session = runtime.sessions[job.session_id]
  local interaction = require("opencode.interaction")
  interaction.reject_by_job(runtime, job)
  local merge = require("opencode.merge")
  if merge.cleanup then
    merge.cleanup(job.key)
  end
  M.transition(job, "cancelled", { session = session })
  if not runtime.client or job.remote_idle then
    return Promise.resolve({ cancelled = 1, errors = 0 })
  end
  return runtime.client:abort(job.session_id):next(function()
    return { cancelled = 1, errors = 0 }
  end):catch(function(err)
    job.cancel_error_class = type(err) == "table" and err.error_class or "abort"
    return { cancelled = 1, errors = 1 }
  end)
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
    return report
  end)
end

---Makes a running Plan Job terminal exactly once and releases its Session.
---@param job table
---@param session table
---@param state "completed"|"cancelled"|"error"
---@return boolean
function M.finish(job, session, state)
  return M.transition(job, state, { session = session })
end

return M
