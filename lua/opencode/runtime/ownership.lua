local M = {}

---Returns Linux process start identity and executable real path.
---Both values are required so a reused PID cannot be mistaken for an owned child.
---@param pid integer
---@return table?
function M.identity(pid)
  local stat = vim.fn.readfile("/proc/" .. pid .. "/stat")[1]
  local executable = vim.uv.fs_realpath("/proc/" .. pid .. "/exe")
  if not stat or not executable then
    return nil
  end
  local suffix = stat:match("^%d+ %b() (.*)$")
  if not suffix then
    return nil
  end
  local fields = vim.split(suffix, "%s+")
  return { pid = pid, start = fields[20], executable = executable }
end

---Atomically writes a private ownership manifest.
---@param path string
---@param manifest table
function M.write(path, manifest)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local temporary = path .. ".tmp"
  vim.fn.writefile({ vim.json.encode(manifest) }, temporary)
  assert(vim.uv.fs_chmod(temporary, 384))
  assert(vim.uv.fs_rename(temporary, path))
end

---Signals a process only when its complete start identity still matches.
---@param expected table
---@param signal? string
---@return boolean
function M.signal(expected, signal)
  local current = M.identity(expected.pid)
  if not current or current.start ~= expected.start or current.executable ~= expected.executable then
    return false
  end
  return vim.uv.kill(expected.pid, signal or "sigterm") == 0
end

---Removes a manifest only after all recorded process identities are gone or verified.
---@param path string
---@param manifest table
---@return boolean
function M.cleanup(path, manifest)
  for _, key in ipairs({ "tui", "server" }) do
    if manifest[key] and not M.signal(manifest[key]) then
      return false
    end
  end
  vim.uv.fs_unlink(path)
  return true
end

---Verifies and removes a stale Runtime using process identity, credentials, health, and routed root.
---Any uncertainty leaves both processes and manifest untouched for manual diagnosis.
---@param path string
---@param root string
---@return boolean
function M.cleanup_stale(path, root)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return true
  end
  if stat.mode % 512 ~= 384 then
    return false
  end
  local ok, manifest = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(manifest) ~= "table" or manifest.root_hash ~= vim.fn.sha256(root) then
    return false
  end
  for _, key in ipairs({ "server", "tui" }) do
    local expected = manifest[key]
    if expected then
      local actual = M.identity(expected.pid)
      if not actual or actual.start ~= expected.start or actual.executable ~= expected.executable then
        return false
      end
    end
  end
  local base = "http://127.0.0.1:" .. tostring(manifest.port)
  local common = {
    "--silent",
    "--show-error",
    "--max-time",
    "2",
    "--user",
    manifest.username .. ":" .. manifest.password,
    "-H",
    "x-opencode-directory: " .. root,
  }
  local health_cmd = { "curl" }
  vim.list_extend(health_cmd, common)
  table.insert(health_cmd, base .. "/global/health")
  local health = vim.system(health_cmd, { text = true }):wait()
  if health.code ~= 0 then
    return false
  end
  local path_cmd = { "curl" }
  vim.list_extend(path_cmd, common)
  table.insert(path_cmd, base .. "/path")
  local result = vim.system(path_cmd, { text = true }):wait()
  local path_ok, routed = pcall(vim.json.decode, result.stdout or "")
  if result.code ~= 0 or not path_ok then
    return false
  end
  if require("opencode.runtime.root").realpath(routed.directory or routed.worktree or "") ~= root then
    return false
  end
  if manifest.tui and not M.signal(manifest.tui) then
    return false
  end
  if manifest.server and not M.signal(manifest.server) then
    return false
  end
  vim.uv.fs_unlink(path)
  return true
end

return M
