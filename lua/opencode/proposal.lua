local M = {}

M.schema = {
  type = "object",
  additionalProperties = false,
  required = { "replacement", "summary" },
  properties = {
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

---Turns minimal structured output into a proposal bound to the local Build transaction.
---The model supplies only replacement text and a summary; trusted path, Base, and scope identity come from the Job so
---the model cannot mistype them or authorize another target. Unsafe text still fails before Theirs is constructed.
---@param value any
---@param job table
---@return table?
---@return table?
function M.validate(value, job)
  if not exact_keys(value, { replacement = true, summary = true }) then
    return nil, { error_class = "invalid_structured_output" }
  end
  if type(value.replacement) ~= "string" or type(value.summary) ~= "string" then
    return nil, { error_class = "invalid_structured_output" }
  end
  local relative = vim.fs.relpath(job.root, job.path)
  if not relative or relative:match("^%.%./") or relative:match("/%.%./") then
    return nil, { error_class = "scope_violation" }
  end
  if
    value.replacement:find("\0", 1, true)
    or value.replacement:find("\r", 1, true)
    or not require("opencode.snapshot").valid_utf8(value.replacement)
  then
    return nil, { error_class = "invalid_structured_output" }
  end
  local theirs = job.base.text:sub(1, job.scope.start_byte)
    .. value.replacement
    .. job.base.text:sub(job.scope.end_byte + 1)
  return {
    proposal = {
      version = 1,
      path = relative,
      base_sha256 = job.base.sha256,
      scope = { start_byte = job.scope.start_byte, end_byte = job.scope.end_byte },
      replacement = value.replacement,
      summary = value.summary,
    },
    theirs = theirs,
  }
end

return M
