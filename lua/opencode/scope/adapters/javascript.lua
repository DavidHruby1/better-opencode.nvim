local M = {
  function_nodes = {
    arrow_function = true,
    function_declaration = true,
    function_expression = true,
    generator_function = true,
    generator_function_declaration = true,
    method_definition = true,
  },
}

local wrappers = {
  assignment_expression = true,
  export_statement = true,
  expression_statement = true,
  lexical_declaration = true,
  parenthesized_expression = true,
  pair = true,
  public_field_definition = true,
  variable_declaration = true,
  variable_declarator = true,
}

local function children(node)
  local result = {}
  for index = 0, node:named_child_count() - 1 do
    table.insert(result, node:named_child(index))
  end
  return result
end

local function has_multiple_declarators(node)
  local count = 0
  for index = 0, node:named_child_count() - 1 do
    if node:named_child(index):type() == "variable_declarator" then
      count = count + 1
      if count > 1 then
        return true
      end
    end
  end
  return false
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
  if
    (node:type() == "lexical_declaration" or node:type() == "variable_declaration")
    and has_multiple_declarators(node)
  then
    return false
  end
  for _, child in ipairs(children(node)) do
    if contains_function(child) then
      return true
    end
  end
  return false
end

---Returns one complete JavaScript or TypeScript callable declaration for any node on that declaration.
---Variable, field, assignment, object, and export wrappers are included so declaration names and function bodies share
---one stable scope. Multi-declarator declarations stop at their individual variable so unrelated siblings stay out.
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
