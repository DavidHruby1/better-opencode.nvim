local M = {}

local allowed = {
  timestamp = true,
  level = true,
  root_hash = true,
  runtime_state = true,
  session_short_id = true,
  message_short_id = true,
  old_state = true,
  new_state = true,
  event_type = true,
  endpoint = true,
  status_code = true,
  error_class = true,
}

local error_classes = {
  abort = true,
  config_parse = true,
  decode = true,
  external_change = true,
  http = true,
  merge_process = true,
  missing_result = true,
  permission = true,
  prompt_http = true,
  reconciliation = true,
  scope_violation = true,
  server_exit = true,
  shutdown_cleanup = true,
  stale_generation = true,
  startup_timeout = true,
  transport_closed = true,
  unknown_log_field = true,
}

local levels = { trace = true, debug = true, info = true, warn = true, error = true }
local states = {
  starting = true,
  ready = true,
  disconnected = true,
  stopping = true,
  stopped = true,
  running = true,
  waiting_user = true,
  pending_apply = true,
  conflict = true,
  completed = true,
  cancelled = true,
  scope_violation = true,
}
local event_types = {
  ["server.connected"] = true,
  ["session.idle"] = true,
  ["session.error"] = true,
  ["message.updated"] = true,
  ["message.part.updated"] = true,
  ["question.asked"] = true,
  ["question.replied"] = true,
  ["question.rejected"] = true,
  ["permission.asked"] = true,
  ["permission.replied"] = true,
  ["permission.rejected"] = true,
  ["file.edited"] = true,
}
local endpoint_segments = {
  global = true,
  health = true,
  doc = true,
  path = true,
  config = true,
  event = true,
  agent = true,
  session = true,
  status = true,
  message = true,
  prompt_async = true,
  abort = true,
  tui = true,
  select_session = true,
  permission = true,
  question = true,
  reply = true,
  reject = true,
}

local function timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Converts a root identity to the stable hash accepted by the log schema.
---Already hashed values are retained; path-shaped values never reach the file.
---@param value string
---@return string
function M.root_hash(value)
  value = tostring(value or "")
  if value:match("^[0-9a-fA-F]{64}$") then
    return value:lower()
  end
  return vim.fn.sha256(value)
end

---Shortens an internal identifier deterministically without accepting arbitrary display content.
---@param value string
---@param length? integer
---@return string
function M.short_id(value, length)
  return vim.fn.sha256(tostring(value or "unknown")):sub(1, length or 8)
end

---Reduces a URL or endpoint to its path and removes host, port, query, and credentials.
---The client normally supplies a path already, but the boundary also protects future callers from leaking URLs.
---@param value string
---@return string
function M.endpoint(value)
  value = tostring(value or "")
  local path = value:match("^[%a][%w+.-]*://[^/]*(/.*)$") or value
  path = path:match("^[^?#]*") or ""
  if path == "" then
    return "/"
  end
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    table.insert(segments, endpoint_segments[segment] and segment or M.short_id(segment))
  end
  return "/" .. table.concat(segments, "/")
end

---Maps external errors to a small enum-like class without serializing their body or tostring value.
---@param value any
---@param fallback? string
---@return string
function M.error_class(value, fallback)
  local class = type(value) == "table" and value.error_class or nil
  class = type(class) == "string" and class or fallback or "error"
  return error_classes[class] and class or "error"
end

---Validates and normalizes one metadata-only record before it can be written.
---Unknown fields, tables, functions, and arbitrary error strings are rejected; path-like roots and URLs are reduced.
---@param record table
---@return table?
---@return string?
function M.sanitize(record)
  if type(record) ~= "table" then
    return nil, "invalid_record"
  end
  local safe = { timestamp = timestamp() }
  for key, value in pairs(record) do
    if not allowed[key] then
      return nil, "unknown_log_field"
    end
    if value ~= nil and type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
      return nil, "unsafe_log_value"
    end
    if key == "root_hash" then
      safe[key] = M.root_hash(value)
    elseif key == "endpoint" then
      safe[key] = M.endpoint(value)
    elseif key == "session_short_id" or key == "message_short_id" then
      safe[key] = M.short_id(value)
    elseif key == "error_class" then
      safe[key] = M.error_class(record, "error")
    elseif key == "level" then
      safe[key] = levels[value] and value or "info"
    elseif key == "runtime_state" or key == "old_state" or key == "new_state" then
      safe[key] = states[value] and value or "unknown"
    elseif key == "event_type" then
      safe[key] = event_types[value] and value or "unknown"
    else
      safe[key] = value
    end
  end
  return safe
end

---Writes one normalized metadata-only diagnostic record.
---Invalid records are dropped and replaced by a fixed error class, so production logging cannot echo unknown data.
---@param record table
---@return boolean
function M.write(record)
  local safe, err = M.sanitize(record)
  if not safe then
    safe = { timestamp = timestamp(), level = "error", error_class = err == "unknown_log_field" and err or "error" }
  end
  local path = vim.fn.stdpath("state") .. "/opencode.nvim.log"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(safe) }, path, "a")
  return err == nil
end

return M
