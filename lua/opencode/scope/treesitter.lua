local M = {}

---Finds the nearest supported language function around a captured cursor.
---Parser failures return no node so the caller can safely choose file scope.
---@param buf integer
---@param cursor integer[]
---@return table?
function M.function_range(buf, cursor)
  local language = vim.bo[buf].filetype
  local ok_adapter, adapter = pcall(require, "opencode.scope.adapters." .. language)
  if not ok_adapter then
    return nil
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, language)
  if not ok_parser or not parser then
    return nil
  end
  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return nil
  end
  local row, col = cursor[1] - 1, cursor[2]
  local node = trees[1]:root():descendant_for_range(row, col, row, col)
  while node do
    if adapter.function_nodes[node:type()] then
      local start_row, start_col, end_row, end_col = node:range()
      return { from = { start_row + 1, start_col }, to = { end_row + 1, end_col }, kind = "bytes" }
    end
    node = node:parent()
  end
  return nil
end

return M
