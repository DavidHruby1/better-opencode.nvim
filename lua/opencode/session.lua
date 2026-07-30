local M = {}

M.permissions = {
  { permission = "*", pattern = "*", action = "deny" },
  { permission = "read", pattern = "*", action = "allow" },
  { permission = "read", pattern = "*.env", action = "deny" },
  { permission = "read", pattern = "*.env.*", action = "deny" },
  { permission = "read", pattern = "*.env.example", action = "allow" },
  { permission = "glob", pattern = "*", action = "allow" },
  { permission = "grep", pattern = "*", action = "allow" },
  { permission = "lsp", pattern = "*", action = "allow" },
  { permission = "skill", pattern = "*", action = "allow" },
  { permission = "question", pattern = "*", action = "allow" },
  { permission = "StructuredOutput", pattern = "*", action = "allow" },
  { permission = "webfetch", pattern = "*", action = "ask" },
  { permission = "websearch", pattern = "*", action = "ask" },
  { permission = "doom_loop", pattern = "*", action = "ask" },
  { permission = "edit", pattern = "*", action = "deny" },
  { permission = "bash", pattern = "*", action = "deny" },
  { permission = "task", pattern = "*", action = "deny" },
  { permission = "external_directory", pattern = "*", action = "deny" },
}

---Builds plugin ownership metadata for a root.
---@param root_hash string
---@return table
function M.metadata(root_hash)
  return { client = "opencode.nvim-inline", contract_version = 2, root_hash = root_hash }
end

---Returns whether rules end with the exact required sequence.
---@param rules table[]
---@return boolean
function M.verify_permissions(rules)
  if #rules < #M.permissions then
    return false
  end
  local offset = #rules - #M.permissions
  for i, expected in ipairs(M.permissions) do
    if not vim.deep_equal(rules[offset + i], expected) then
      return false
    end
  end
  return true
end

return M
