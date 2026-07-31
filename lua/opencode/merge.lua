local M = { active = {} }

local function forget(owner_key, paths)
  if not owner_key or not M.active[owner_key] then
    return
  end
  for index, active_paths in ipairs(M.active[owner_key]) do
    if active_paths == paths then
      table.remove(M.active[owner_key], index)
      break
    end
  end
  if #M.active[owner_key] == 0 then
    M.active[owner_key] = nil
  end
end

local function write_private(path, text)
  local handle, err = vim.uv.fs_open(path, "w", 384)
  if not handle then
    return nil, err
  end
  local written, write_error = vim.uv.fs_write(handle, text, 0)
  vim.uv.fs_close(handle)
  if not written then
    return nil, write_error
  end
  return true
end

---Runs git merge-file over private Base/Ours/Theirs operands without a shell.
---All content files are removed on every exit and stdout is returned only as merge content.
---@param base string
---@param ours string
---@param theirs string
---@param opts? { runner?: function, temp_dir?: string, preference?: "ours"|"theirs", owner_key?: string }
---@return Promise<table>
function M.run(base, ours, theirs, opts)
  opts = opts or {}
  local Promise = require("opencode.promise")
  if ours == theirs then
    return Promise.resolve({ kind = "clean", text = ours })
  end
  local directory = opts.temp_dir or (vim.fn.stdpath("state") .. "/opencode.nvim/merge")
  vim.fn.mkdir(directory, "p", 448)
  local prefix = directory .. "/" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random())):sub(1, 20)
  local paths = { base = prefix .. ".base", ours = prefix .. ".ours", theirs = prefix .. ".theirs" }
  if opts.owner_key then
    M.active[opts.owner_key] = M.active[opts.owner_key] or {}
    table.insert(M.active[opts.owner_key], paths)
  end
  for name, text in pairs({ base = base, ours = ours, theirs = theirs }) do
    local ok = write_private(paths[name], text)
    if not ok then
      for _, path in pairs(paths) do
        vim.uv.fs_unlink(path)
      end
      forget(opts.owner_key, paths)
      return Promise.reject({ error_class = "merge_temp" })
    end
  end
  local command = {
    "git",
    "merge-file",
    "-p",
    "--diff3",
    "-L",
    "Ours",
    "-L",
    "Base",
    "-L",
    "Theirs",
    paths.ours,
    paths.base,
    paths.theirs,
  }
  if opts.preference then
    table.insert(command, 4, "--" .. opts.preference)
  end
  local runner = opts.runner or vim.system
  return Promise.new(function(resolve, reject)
    runner(command, { text = false }, function(result)
      vim.schedule(function()
        for _, path in pairs(paths) do
          vim.uv.fs_unlink(path)
        end
        forget(opts.owner_key, paths)
        if result.code == 0 then
          resolve({ kind = "clean", text = result.stdout or "" })
        elseif result.code == 1 and (not result.signal or result.signal == 0) then
          resolve({ kind = "conflict", text = result.stdout or "" })
        else
          reject({ error_class = "merge_process" })
        end
      end)
    end)
  end)
end

---Removes private merge operands still owned by one Job.
---Process completion may repeat the unlink safely, so cancellation never waits for the backend.
---@param owner_key string
function M.cleanup(owner_key)
  for _, paths in ipairs(M.active[owner_key] or {}) do
    for _, path in pairs(paths) do
      vim.uv.fs_unlink(path)
    end
  end
  M.active[owner_key] = nil
end

return M
