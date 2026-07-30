local M = {}

---Builds a programmable fake response table consumed by client runner tests.
---It records argv so tests assert real auth and root headers without bypassing the client.
---@param responses table[]
---@return function, table
function M.runner(responses)
  local calls = {}
  local index = 0
  return function(argv, _, callback)
    index = index + 1
    table.insert(calls, argv)
    local response = responses[index]
    callback({
      code = response.code or 0,
      stdout = vim.json.encode(response.body) .. "__OPENCODE_STATUS__:" .. (response.status or 200),
      stderr = "",
    })
  end,
    calls
end

return M
