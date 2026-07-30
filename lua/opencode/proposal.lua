local M = {}

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "version", "path", "base_sha256", "scope", "replacement", "summary" },
  properties = {
    version = { const = 1 },
    path = { type = "string" },
    base_sha256 = { type = "string", pattern = "^[0-9a-f]{64}$" },
    scope = {
      type = "object",
      additionalProperties = false,
      required = { "start_byte", "end_byte" },
      properties = {
        start_byte = { type = "integer", minimum = 0 },
        end_byte = { type = "integer", minimum = 0 },
      },
    },
    replacement = { type = "string" },
    summary = { type = "string" },
  },
}

local function exact_keys(value, allowed)
  if type(value) ~= "table" then
    return false
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  for key in pairs(allowed) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

---Validates structured output against its schema and the local Build transaction.
---It constructs Theirs with one authorized Base slice replacement and never returns source in failures.
---@param value any
---@param job table
---@return table?
---@return table?
function M.validate(value, job)
  local fields = { version = true, path = true, base_sha256 = true, scope = true, replacement = true, summary = true }
  if not exact_keys(value, fields) or not exact_keys(value.scope, { start_byte = true, end_byte = true }) then
    return nil, { error_class = "invalid_structured_output" }
  end
  if value.version ~= 1 or type(value.path) ~= "string" or type(value.base_sha256) ~= "string" then
    return nil, { error_class = "invalid_structured_output" }
  end
  if
    type(value.scope.start_byte) ~= "number"
    or value.scope.start_byte % 1 ~= 0
    or type(value.scope.end_byte) ~= "number"
    or value.scope.end_byte % 1 ~= 0
  then
    return nil, { error_class = "invalid_structured_output" }
  end
  if type(value.replacement) ~= "string" or type(value.summary) ~= "string" then
    return nil, { error_class = "invalid_structured_output" }
  end
  local relative = vim.fs.relpath(job.root, job.path)
  if not relative or relative:match("^%.%./") or relative:match("/%.%./") or value.path ~= relative then
    return nil, { error_class = "scope_violation" }
  end
  if
    value.base_sha256 ~= job.base.sha256
    or value.scope.start_byte ~= job.scope.start_byte
    or value.scope.end_byte ~= job.scope.end_byte
  then
    return nil, { error_class = "scope_violation" }
  end
  if
    value.replacement:find("\0", 1, true)
    or value.replacement:find("\r", 1, true)
    or not pcall(vim.str_utfindex, value.replacement)
  then
    return nil, { error_class = "invalid_structured_output" }
  end
  local theirs = job.base.text:sub(1, job.scope.start_byte)
    .. value.replacement
    .. job.base.text:sub(job.scope.end_byte + 1)
  return { proposal = vim.deepcopy(value), theirs = theirs }
end

return M
