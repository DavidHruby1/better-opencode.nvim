local M = {
  function_nodes = {
    function_declaration = true,
    function_definition = true,
  },
}

local wrappers = {
  assignment_statement = true,
  expression_list = true,
  variable_declaration = true,
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

local function is_single_assignment(node)
  local targets = node:named_child(0)
  local expressions = node:named_child(1)
  return node:named_child_count() == 2
    and targets
    and expressions
    and targets:named_child_count() == 1
    and expressions:named_child_count() == 1
end

local function can_wrap(node)
  if node:type() == "assignment_statement" then
    return is_single_assignment(node)
  end
  if node:type() == "expression_list" then
    return node:named_child_count() == 1
  end
  if node:type() == "variable_declaration" then
    local assignment = node:named_child(0)
    return node:named_child_count() == 1
      and assignment
      and assignment:type() == "assignment_statement"
      and is_single_assignment(assignment)
  end
  return true
end

---Returns one complete Lua function assignment for any node on that assignment.
---It widens through a local declaration only for one target and one expression; direct function declarations remain unchanged.
---This keeps sibling targets and expressions outside a callable's scope.
---@param node TSNode
---@return TSNode?
function M.scope_node(node)
  if not contains_function(node) or (wrappers[node:type()] and not can_wrap(node)) then
    return nil
  end
  local candidate = node
  local parent = node:parent()
  while parent and wrappers[parent:type()] and contains_function(parent) and can_wrap(parent) do
    candidate = parent
    parent = parent:parent()
  end
  return candidate
end

return M
