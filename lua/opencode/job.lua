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
  running = { pending_apply = true, completed = true, cancelled = true, error = true, scope_violation = true },
  pending_apply = { completed = true, conflict = true, cancelled = true, error = true, scope_violation = true },
  conflict = { cancelled = true, error = true },
}

---Moves a Job through the explicit F03-F04 state machine and owns terminal cleanup.
---Sessions remain active for pending proposals and conflicts, then release exactly once on terminal states.
---@param job table
---@param session table
---@param state string
---@param conflict_kind? "agent"|"external_change"
---@return boolean
function M.transition(job, session, state, conflict_kind)
  if not transitions[job.state] or not transitions[job.state][state] then
    return false
  end
  if state == "conflict" and not conflict_kind then
    return false
  end
  job.state = state
  job.conflict_kind = conflict_kind
  if terminal_states[state] then
    if job.insert_leave then
      pcall(vim.api.nvim_del_autocmd, job.insert_leave)
      job.insert_leave = nil
    end
    require("opencode.scope").delete_marks(job)
    job.proposal, job.theirs, job.conflict_payload = nil, nil, nil
    session.active_job_key = nil
    session.last_job_state = state
  end
  return true
end

---Makes a running Plan Job terminal exactly once and releases its Session.
---@param job table
---@param session table
---@param state "completed"|"cancelled"|"error"
---@return boolean
function M.finish(job, session, state)
  return M.transition(job, session, state)
end

return M
