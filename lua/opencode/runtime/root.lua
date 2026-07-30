local M = {}

---Returns true when path is root itself or one of its descendants.
---The separator check avoids treating sibling names with a common prefix as contained.
---@param root string
---@param path string
---@return boolean
function M.contains(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

---Resolves a path to an absolute real path.
---@param path string
---@return string?
function M.realpath(path)
  local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  return vim.uv.fs_realpath(absolute)
end

local function lsp_roots(buf, file)
  local roots = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    local candidates = {}
    if client.workspace_folders then
      for _, folder in ipairs(client.workspace_folders) do
        table.insert(candidates, vim.uri_to_fname(folder.uri))
      end
    elseif client.config.root_dir then
      table.insert(candidates, client.config.root_dir)
    end
    for _, candidate in ipairs(candidates) do
      local root = M.realpath(candidate)
      if root and M.contains(root, file) then
        roots[root] = true
      end
    end
  end
  return vim.tbl_keys(roots)
end

---Chooses the canonical root for a captured file buffer.
---An unambiguous LSP workspace wins, then the nearest Git worktree, then a containing cwd.
---@param capture { buf: integer, path: string }
---@return string?
---@return string?
function M.resolve(capture)
  local file = M.realpath(capture.path)
  if not file then
    return nil, "target_not_found"
  end
  local roots = lsp_roots(capture.buf, file)
  if #roots > 1 then
    return nil, "ambiguous_lsp_root"
  end
  if #roots == 1 then
    return roots[1]
  end
  local result = vim
    .system({ "git", "-C", vim.fs.dirname(file), "rev-parse", "--show-toplevel" }, { text = true })
    :wait()
  if result.code == 0 then
    local git = M.realpath(vim.trim(result.stdout))
    if git and M.contains(git, file) then
      return git
    end
  end
  local current_directory = vim.uv.cwd()
  local cwd = current_directory and M.realpath(current_directory)
  if cwd and M.contains(cwd, file) then
    return cwd
  end
  return nil, "no_containing_root"
end

return M
