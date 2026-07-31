local M = {}

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function curl_config(username, password)
  local value = username .. ":" .. password
  return 'user = "' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"\n'
end

---Returns Linux process start identity and executable real path.
---Both values are required so a reused PID cannot be mistaken for an owned child.
---@param pid integer
---@return table?
function M.identity(pid)
  local ok, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/stat")
  local stat = ok and lines[1] or nil
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

---Checks whether a recorded process is still the same executable instance.
---A missing process is safe for cleanup, while a reused PID is never treated as owned.
---@param expected table
---@return boolean, boolean
function M.verified(expected)
  if type(expected) ~= "table" or not expected.pid then
    return false, false
  end
  local actual = M.identity(expected.pid)
  if not actual then
    return true, false
  end
  return actual.start == expected.start and actual.executable == expected.executable, true
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

---Terminates one verified process and waits only for that exact process identity to disappear.
---The configured bound allows normal SIGTERM cleanup without treating a reused PID as success.
local function terminate(expected)
  if not M.signal(expected) then
    return false
  end
  local timeout = require("opencode.config").opts.runtime.shutdown_timeout
  return vim.wait(timeout, function()
    local current = M.identity(expected.pid)
    return current == nil
  end, 20)
end

---Removes a manifest only after all recorded process identities are gone or verified.
---@param path string
---@param manifest table
---@return boolean
function M.cleanup(path, manifest)
  for _, key in ipairs({ "tui", "server" }) do
    if manifest[key] then
      local verified, running = M.verified(manifest[key])
      if not verified then
        return false
      end
      if running then
        if not terminate(manifest[key]) then
          return false
        end
      end
    end
  end
  if exists(path) then
    vim.uv.fs_unlink(path)
  end
  return true
end

---Signals only process identities recorded in a manifest and removes it after verification.
---The bounded shutdown caller can retry this operation without ever targeting a reused PID.
---@param path string
---@param manifest table
---@return boolean
function M.shutdown(path, manifest)
  return M.cleanup(path, manifest)
end

---Verifies and removes a stale Runtime using process identity, credentials, health, and routed root.
---Any uncertainty leaves both processes and manifest untouched for manual diagnosis.
---@param path string
---@param root? string
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
  if
    not ok
    or type(manifest) ~= "table"
    or manifest.schema_version ~= 1
    or type(manifest.root_hash) ~= "string"
    or type(manifest.port) ~= "number"
    or type(manifest.username) ~= "string"
    or type(manifest.password) ~= "string"
    or type(manifest.nonce) ~= "string"
    or type(manifest.server) ~= "table"
  then
    return false
  end
  root = root or manifest.root
  if not root and manifest.server then
    root = vim.uv.fs_realpath("/proc/" .. manifest.server.pid .. "/cwd")
  end
  if not root or vim.fn.sha256(root) ~= manifest.root_hash then
    return false
  end
  for _, key in ipairs({ "server", "tui" }) do
    local expected = manifest[key]
    if expected then
      local verified = M.verified(expected)
      if not verified then
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
    "--config",
    "-",
    "-H",
    "x-opencode-directory: " .. root,
  }
  local health_cmd = { "curl" }
  vim.list_extend(health_cmd, common)
  table.insert(health_cmd, base .. "/global/health")
  local health =
    vim.system(health_cmd, { text = true, stdin = curl_config(manifest.username, manifest.password) }):wait()
  if health.code ~= 0 then
    if manifest.server and M.identity(manifest.server.pid) then
      return false
    end
    if manifest.tui then
      local verified, running = M.verified(manifest.tui)
      if not verified then
        return false
      end
      if running and not terminate(manifest.tui) then
        return false
      end
    end
    if exists(path) then
      vim.uv.fs_unlink(path)
    end
    vim.fn.delete(vim.fn.stdpath("state") .. "/opencode.nvim/runtimes/" .. manifest.root_hash, "rf")
    return true
  end
  local path_cmd = { "curl" }
  vim.list_extend(path_cmd, common)
  table.insert(path_cmd, base .. "/path")
  local result = vim.system(path_cmd, { text = true, stdin = curl_config(manifest.username, manifest.password) }):wait()
  local path_ok, routed = pcall(vim.json.decode, result.stdout or "")
  if result.code ~= 0 or not path_ok then
    return false
  end
  if require("opencode.runtime.root").realpath(routed.directory or routed.worktree or "") ~= root then
    return false
  end
  if manifest.tui then
    local verified, running = M.verified(manifest.tui)
    if not verified then
      return false
    end
    if running and not terminate(manifest.tui) then
      return false
    end
  end
  if manifest.server then
    local verified, running = M.verified(manifest.server)
    if not verified then
      return false
    end
    if running and not terminate(manifest.server) then
      return false
    end
  end
  if exists(path) then
    vim.uv.fs_unlink(path)
  end
  vim.fn.delete(vim.fn.stdpath("state") .. "/opencode.nvim/runtimes/" .. manifest.root_hash, "rf")
  return true
end

---Verifies every stale manifest before the first new Runtime starts.
---Unknown roots are recovered from the recorded Server cwd; uncertain ownership remains for diagnostics.
---@return boolean
function M.cleanup_stale_manifests()
  local directory = vim.fn.stdpath("state") .. "/opencode.nvim/runtimes"
  local handle = vim.uv.fs_scandir(directory)
  if not handle then
    return true
  end
  for name, kind in vim.uv.fs_scandir_next, handle do
    if kind == "file" and name:match("%.json$") then
      local path = directory .. "/" .. name
      if not M.cleanup_stale(path) then
        return false
      end
    end
  end
  return true
end

return M
