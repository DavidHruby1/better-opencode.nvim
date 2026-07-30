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

---Writes one metadata-only diagnostic record.
---Unknown fields are discarded so content cannot accidentally enter the default log.
---@param record table
function M.write(record)
  local safe = { timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  for key, value in pairs(record) do
    if allowed[key] then
      safe[key] = value
    end
  end
  local path = vim.fn.stdpath("state") .. "/opencode.nvim.log"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(safe) }, path, "a")
end

return M
