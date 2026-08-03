local M = {
  function_nodes = {
    function_definition = true,
    lambda = true,
  },
}

local wrappers = {
  assignment = true,
  decorated_definition = true,
  expression_statement = true,
}

local function children(node)
  local result = {}
  for index = 0, node:named_child_count() - 1 do
    table.insert(result, node:named_child(index))
  end
  return result
end

local function contains_function(node)
  if not node then
    return false
  end
  if M.function_nodes[node:type()] then
    return true
  end
  if not wrappers[node:type()] then
    return false
  end
  for _, child in ipairs(children(node)) do
    if contains_function(child) then
      return true
    end
  end
  return false
end

---Returns one complete Python callable declaration for any node on that declaration.
---Decorators and lambda assignments are included so moving the cursor within the declaration cannot widen its scope to
---the whole file or produce a different range for the same callable.
---@param node TSNode
---@return TSNode?
function M.scope_node(node)
  if not contains_function(node) then
    return nil
  end
  local candidate = node
  local parent = node:parent()
  while parent and wrappers[parent:type()] and contains_function(parent) do
    candidate = parent
    parent = parent:parent()
  end
  return candidate
end

return M
