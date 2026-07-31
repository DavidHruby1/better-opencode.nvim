local files = {
  "lua/opencode/log.lua",
  "lua/opencode/ui/notify.lua",
  "lua/opencode/client.lua",
}
local forbidden = { "prompt", "replacement", "authorization", "password", "source", "diff" }
local allowed_log = {
  "timestamp",
  "level",
  "root_hash",
  "runtime_state",
  "session_short_id",
  "message_short_id",
  "old_state",
  "new_state",
  "event_type",
  "endpoint",
  "status_code",
  "error_class",
}

local function read(path)
  local file = assert(io.open(path, "r"))
  local value = file:read("*a")
  file:close()
  return value
end

local log_source = read(files[1])
for _, field in ipairs(allowed_log) do
  assert(log_source:find(field, 1, true), "log schema lost " .. field)
end
for _, field in ipairs({ "prompt = true", "replacement = true", "authorization = true", "password = true" }) do
  assert(not log_source:find(field, 1, true), "forbidden log field " .. field)
end
for _, path in ipairs(files) do
  local source = read(path)
  assert(not source:find("vim%.inspect%(err", 1, false), "error body inspection in " .. path)
end
print("Privacy source audit passed")
