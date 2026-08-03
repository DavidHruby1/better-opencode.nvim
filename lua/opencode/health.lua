local M = {}

local function executable(name)
  return vim.fn.executable(name) == 1
end

---Reads the local OpenCode executable's version without starting or contacting a Server.
---Only the trimmed command output is returned; callers compare it with the fixed compatibility profiles before reporting it.
local function opencode_version(binary)
  if not executable(binary) then
    return nil
  end
  local output = vim.fn.system({ binary, "--version" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(output)
end

---Reports whether a directory is writable without creating or changing it.
---Missing paths remain distinct from existing unwritable paths because normal Runtime startup creates missing paths.
---@return "missing"|"unwritable"|"writable"
local function directory_status(path)
  if not vim.uv.fs_stat(path) then
    return "missing"
  end
  if vim.fn.isdirectory(path) ~= 1 or vim.fn.filewritable(path) ~= 2 then
    return "unwritable"
  end
  return "writable"
end

---Resolves the active project's canonical root using the same LSP, Git, and cwd rules as Runtime startup.
---File-backed buffers use root resolution directly and preserve its failure reason; unnamed buffers fall back to the
---canonical cwd because there is no file for the existing resolver to anchor.
---@return string?
---@return string?
local function active_project_root()
  local root = require("opencode.runtime.root")
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= "" then
    return root.resolve({ buf = buf, path = path })
  end
  local cwd = root.realpath(vim.uv.cwd() or vim.fn.getcwd())
  if cwd then
    return cwd
  end
  return nil, "cwd_not_found"
end

local function parser_capability()
  local filetype = vim.bo.filetype
  if filetype == "" then
    return nil, "no active filetype"
  end
  local language = vim.treesitter.language.get_lang(filetype) or filetype
  local ok = pcall(vim.treesitter.get_parser, 0, language)
  if ok then
    return true, language
  end
  return false, language
end

---Collects local capability and OpenCode config facts without starting a Server or Runtime state.
---Command probes are read-only; the passive config guard matches startup's root and environment when a root exists.
---@return table
function M.capabilities()
  local parser_ok, parser_name = parser_capability()
  local snacks_ok, snacks = pcall(require, "snacks")
  local snack_input = snacks_ok
    and snacks.config
    and snacks.config.get
    and snacks.config.get("input", {}).enabled == true
  local snack_picker = snacks_ok
    and snacks.config
    and snacks.config.get
    and snacks.config.get("picker", {}).enabled == true
  local config = require("opencode.config")
  local version = opencode_version(config.opts.runtime.binary)
  local profile = version and require("opencode.compat")[version] or nil
  local root, root_error = active_project_root()
  local guard_ok = false
  local guard_error = root_error
  if type(root) == "string" then
    guard_ok, guard_error = require("opencode.runtime.config_guard").scan(root)
  else
    root_error = root_error or "root_not_found"
    guard_error = root_error
  end
  local state_dir_status = directory_status(vim.fn.stdpath("state") .. "/opencode.nvim")
  local temp_dir_status = directory_status(vim.fn.stdpath("state") .. "/opencode.nvim/runtimes")
  return {
    nvim_ok = vim.version.ge(vim.version(), { 0, 11, 0 }),
    opencode_ok = version ~= nil,
    version = version,
    profile = profile,
    curl_ok = executable("curl"),
    git_ok = executable("git"),
    snacks_ok = snacks_ok,
    snack_input = snack_input,
    snack_picker = snack_picker,
    parser_ok = parser_ok,
    parser_name = parser_name,
    lua_adapter_ok = pcall(require, "opencode.scope.adapters.lua"),
    terminal_ok = vim.fn.exists("*jobstart") == 1,
    loopback_ok = M.loopback_available(),
    state_dir_ok = state_dir_status == "writable",
    state_dir_status = state_dir_status,
    temp_dir_ok = temp_dir_status == "writable",
    temp_dir_status = temp_dir_status,
    config_error = config.validation_error,
    config_guard_ok = guard_ok,
    config_guard_error = guard_error,
    root_error = root_error,
  }
end

---Checks the loopback capability only; it never connects to an existing server or opens a discovery query.
---@return boolean
function M.loopback_available()
  local tcp = vim.uv.new_tcp()
  if not tcp then
    return false
  end
  local bound = tcp:bind("127.0.0.1", 0)
  tcp:close()
  return bound == 0 or bound == true
end

---Reports plugin configuration errors and the passive OpenCode config guard result.
---A missing project root makes the guard not applicable, while a failed scan remains an error.
local function report_config(report)
  if report.config_error then
    vim.health.error(
      string.format(
        "unsupported configuration at %s (%s); see docs/RECOVERY.md",
        report.config_error.scope,
        report.config_error.reason
      )
    )
  else
    vim.health.ok("documented plugin configuration shape")
  end
  local messages = {
    config_parse = "OpenCode config is invalid; fix it or use a clean config",
    custom_tool = "custom OpenCode tools are blocked; use a clean config for this plugin",
  }
  if report.root_error then
    vim.health.warn("local OpenCode config scan not applicable; project root unavailable (" .. report.root_error .. ")")
  elseif report.config_guard_ok then
    vim.health.ok("local OpenCode config parsed; plugins and MCPs are ignored; custom tools remain blocked")
  else
    vim.health.error(
      (messages[report.config_guard_error] or "local OpenCode config is blocked") .. "; see docs/RECOVERY.md"
    )
  end
end

---Reports hard dependencies and actionable warnings without starting a Server, MCP, plugin, or tool.
---External probes read local tool versions and exercise Git with empty /dev/null operands.
function M.check()
  vim.health.start("opencode.nvim")
  local report = M.capabilities()
  if report.nvim_ok then
    vim.health.ok("Neovim >= 0.11.0")
  else
    vim.health.error("Neovim 0.11.0 or newer is required")
  end
  if report.snacks_ok then
    if report.snack_input then
      vim.health.ok("snacks.input enabled")
    else
      vim.health.error("snacks.input must be enabled in snacks.nvim")
    end
    if report.snack_picker then
      vim.health.ok("snacks.picker enabled")
    else
      vim.health.error("snacks.picker must be enabled in snacks.nvim")
    end
  else
    vim.health.error("snacks.nvim is required; install it and enable input and picker")
  end
  if report.curl_ok then
    vim.health.ok("curl available for the production transport")
  else
    vim.health.error("curl is required; install curl and restart Neovim")
  end
  if report.git_ok then
    local result = vim
      .system({ "git", "merge-file", "-p", "--diff3", "/dev/null", "/dev/null", "/dev/null" }, { text = true })
      :wait()
    if result.code == 0 then
      vim.health.ok("git merge-file -p --diff3 available")
    else
      vim.health.error("git merge-file file-operand mode is required; install a complete Git")
    end
  else
    vim.health.error("git is required for three-way merge; install Git and restart Neovim")
  end
  if not report.version then
    vim.health.error("OpenCode executable is unavailable; configure runtime.binary or install exactly 1.17.3 or 1.18.9")
  elseif report.profile then
    vim.health.ok("OpenCode " .. report.version .. " selected; fixture SHA-256 " .. report.profile.fixture_sha256)
  else
    vim.health.error("unsupported OpenCode " .. report.version .. "; use exactly 1.17.3 or 1.18.9")
  end
  if report.loopback_ok then
    vim.health.ok("loopback bind 127.0.0.1 available")
  else
    vim.health.error("cannot bind 127.0.0.1; allow a loopback listener")
  end
  if report.terminal_ok then
    vim.health.ok("jobstart process API available")
  else
    vim.health.error("jobstart process API is required; use Neovim 0.11.0 or newer")
  end
  local missing_state_dir = report.state_dir_status == "missing"
  local missing_temp_dir = report.temp_dir_status == "missing"
  local unwritable_state_dir = report.state_dir_status == "unwritable"
  local unwritable_temp_dir = report.temp_dir_status == "unwritable"
  local directories_missing = missing_state_dir or missing_temp_dir
  local directories_unwritable = unwritable_state_dir or unwritable_temp_dir
  if not directories_missing and not directories_unwritable then
    vim.health.ok("private state and runtime temp directories are writable")
  elseif directories_unwritable then
    vim.health.error("private state/temp directories are not writable; fix permissions on stdpath(state)")
  end
  if directories_missing then
    vim.health.warn("private state/temp directories are missing; Runtime creates them on first start")
  end
  if report.parser_ok then
    vim.health.ok("Tree-sitter parser available for " .. report.parser_name)
  else
    vim.health.warn(
      "Tree-sitter parser unavailable for "
        .. tostring(report.parser_name)
        .. "; Build will use file scope (install the parser for function scope)"
    )
  end
  if report.lua_adapter_ok then
    vim.health.ok("Lua scope adapter available")
  else
    vim.health.error("Lua scope adapter is missing; reinstall the plugin")
  end
  report_config(report)
end

return M
