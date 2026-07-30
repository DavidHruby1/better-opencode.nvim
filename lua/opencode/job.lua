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

---Creates a running Plan Job before network dispatch.
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
    mode = "plan",
    state = "running",
    buffer = target.buf,
    path = target.path,
  }
end

---Makes a Plan Job terminal exactly once and releases its Session.
---@param job table
---@param session table
---@param state "completed"|"cancelled"|"error"
---@return boolean
function M.finish(job, session, state)
  if job.state ~= "running" then
    return false
  end
  job.state = state
  session.active_job_key = nil
  session.last_job_state = state
  return true
end

return M
