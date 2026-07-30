local M = {}

---Reports the hard capabilities needed by the owned Runtime and Plan UI.
function M.check()
  vim.health.start("opencode.nvim")
  if vim.version.ge(vim.version(), { 0, 11, 0 }) then
    vim.health.ok("Neovim >= 0.11.0")
  else
    vim.health.error("Neovim 0.11.0 or newer is required")
  end
  for _, executable in ipairs({ "opencode", "curl", "git" }) do
    if vim.fn.executable(executable) == 1 then
      vim.health.ok(executable .. " available")
    else
      vim.health.error(executable .. " is required")
    end
  end
  if vim.fn.executable("git") == 1 then
    local probe = vim
      .system({ "git", "merge-file", "-p", "--diff3", "/dev/null", "/dev/null", "/dev/null" }, { text = true })
      :wait()
    if probe.code == 0 then
      vim.health.ok("git merge-file -p --diff3 available")
    else
      vim.health.error("git merge-file file-operand mode unavailable")
    end
  end
  if vim.fn.executable("opencode") == 1 then
    local version = vim.trim(vim.fn.system({ "opencode", "--version" }))
    if require("opencode.compat")[version] then
      vim.health.ok("supported OpenCode " .. version)
    else
      vim.health.error("unsupported OpenCode " .. version)
    end
  end
  local snacks_ok, snacks = pcall(require, "snacks")
  if not snacks_ok then
    vim.health.error("snacks.nvim is required")
  else
    for _, capability in ipairs({ "input", "picker" }) do
      if snacks.config.get(capability, {}).enabled then
        vim.health.ok("snacks." .. capability .. " enabled")
      else
        vim.health.error("snacks." .. capability .. " must be enabled")
      end
    end
  end
  local tcp = vim.uv.new_tcp()
  local bound = tcp and tcp:bind("127.0.0.1", 0)
  if tcp then
    tcp:close()
  end
  if bound then
    vim.health.ok("loopback bind available")
  else
    vim.health.error("cannot bind loopback")
  end
  if vim.fn.exists("*termopen") == 1 or vim.fn.exists("*jobstart") == 1 then
    vim.health.ok("terminal API available")
  else
    vim.health.error("terminal API unavailable")
  end
end

return M
