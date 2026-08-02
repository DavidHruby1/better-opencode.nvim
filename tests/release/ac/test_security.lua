---@diagnostic disable: duplicate-set-field

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function contains(messages, expected)
  for _, message in ipairs(messages) do
    if message == expected then
      return true
    end
  end
  return false
end

---Converts an argv array into a stable comparison key without treating it as shell text.
---The NUL separator keeps each argument boundary visible when the test checks exact probes.
local function argv_key(command)
  return table.concat(command, "\0")
end

---Rejects shell-style, discovery, and terminal-mutating probes at the command boundary.
---Health only performs fixed Git capability and active-root probes; tmux is not a runtime prerequisite.
local function assert_read_only_commands(calls)
  local allowed = {
    ["git\0merge-file\0-p\0--diff3\0/dev/null\0/dev/null\0/dev/null"] = true,
  }
  for _, command in ipairs(calls.system) do
    eq(type(command), "table")
    local root_probe = command[1] == "git"
      and command[2] == "-C"
      and command[4] == "rev-parse"
      and command[5] == "--show-toplevel"
      and #command == 5
    eq(allowed[argv_key(command)] == true or root_probe, true, "unexpected or mutating system command")
  end
  for _, command in ipairs(calls.fn_system) do
    eq(type(command), "table")
    eq(#command, 2)
    eq(command[2], "--version")
  end
end

---Runs the public health check against local capability boundaries without starting OpenCode.
---The returned observations preserve health levels, root selection, and command probes for privacy assertions.
---@param spec? table
---@return table, table
local function run_health(spec)
  spec = spec or {}
  local binary = vim.fn.tempname()
  local root = spec.root or (vim.fn.tempname() .. "/health-private-path")
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    spec.version_error and "exit 1" or "printf '%s\\n' '" .. (spec.version or "") .. "'",
  }, binary)
  assert(vim.uv.fs_chmod(binary, 493))
  local observations = { start = {}, ok = {}, warn = {}, error = {} }
  local calls = { executable = {}, system = {}, fn_system = {}, jobstart = {}, mkdir = {} }
  local config = require("opencode.config")
  local health = require("opencode.health")
  local old = {
    health = vim.health,
    executable = vim.fn.executable,
    jobstart = vim.fn.jobstart,
    exists = vim.fn.exists,
    stdpath = vim.fn.stdpath,
    isdirectory = vim.fn.isdirectory,
    mkdir = vim.fn.mkdir,
    filewritable = vim.fn.filewritable,
    filetype = vim.bo.filetype,
    get_lang = vim.treesitter.language.get_lang,
    get_parser = vim.treesitter.get_parser,
    new_tcp = vim.uv.new_tcp,
    version_ge = vim.version.ge,
    vim_system = vim.system,
    fn_system = vim.fn.system,
    cwd = vim.uv.cwd,
    get_clients = vim.lsp.get_clients,
    buf_get_name = vim.api.nvim_buf_get_name,
    binary = config.opts.runtime.binary,
    config_guard = package.loaded["opencode.runtime.config_guard"],
    snacks = package.loaded.snacks,
    snacks_preload = package.preload.snacks,
    env = {
      XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
      OPENCODE_CONFIG = vim.env.OPENCODE_CONFIG,
      OPENCODE_CONFIG_DIR = vim.env.OPENCODE_CONFIG_DIR,
      OPENCODE_CONFIG_CONTENT = vim.env.OPENCODE_CONFIG_CONTENT,
      TMUX = vim.env.TMUX,
      TMUX_PANE = vim.env.TMUX_PANE,
    },
  }

  local function restore()
    vim.health = old.health
    vim.fn.executable = old.executable
    vim.fn.jobstart = old.jobstart
    vim.fn.exists = old.exists
    vim.fn.stdpath = old.stdpath
    vim.fn.isdirectory = old.isdirectory
    vim.fn.mkdir = old.mkdir
    vim.fn.filewritable = old.filewritable
    vim.bo.filetype = old.filetype
    vim.treesitter.language.get_lang = old.get_lang
    vim.treesitter.get_parser = old.get_parser
    vim.uv.new_tcp = old.new_tcp
    vim.version.ge = old.version_ge
    vim.system = old.vim_system
    vim.fn.system = old.fn_system
    vim.uv.cwd = old.cwd
    vim.lsp.get_clients = old.get_clients
    vim.api.nvim_buf_get_name = old.buf_get_name
    config.opts.runtime.binary = old.binary
    package.loaded["opencode.runtime.config_guard"] = old.config_guard
    package.loaded.snacks = old.snacks
    package.preload.snacks = old.snacks_preload
    vim.env.XDG_CONFIG_HOME = old.env.XDG_CONFIG_HOME
    vim.env.OPENCODE_CONFIG = old.env.OPENCODE_CONFIG
    vim.env.OPENCODE_CONFIG_DIR = old.env.OPENCODE_CONFIG_DIR
    vim.env.OPENCODE_CONFIG_CONTENT = old.env.OPENCODE_CONFIG_CONTENT
    vim.env.TMUX = old.env.TMUX
    vim.env.TMUX_PANE = old.env.TMUX_PANE
    vim.uv.fs_unlink(binary)
    if spec.root == nil then
      vim.fn.delete(root, "rf")
    end
  end

  vim.health = {
    start = function(message)
      table.insert(observations.start, message)
    end,
    ok = function(message)
      table.insert(observations.ok, message)
    end,
    warn = function(message)
      table.insert(observations.warn, message)
    end,
    error = function(message)
      table.insert(observations.error, message)
    end,
  }
  config.opts.runtime.binary = binary
  vim.uv.cwd = function()
    return root
  end
  vim.api.nvim_buf_get_name = function()
    return spec.active_file or ""
  end
  vim.lsp.get_clients = function()
    return {}
  end
  vim.env.XDG_CONFIG_HOME = root .. "/config"
  vim.env.OPENCODE_CONFIG = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
  vim.env.OPENCODE_CONFIG_CONTENT = spec.config_content
  if spec.in_tmux then
    vim.env.TMUX = "health-fixture-tmux"
    if spec.tmux_pane == false then
      vim.env.TMUX_PANE = nil
    else
      vim.env.TMUX_PANE = spec.tmux_pane or "%health-pane"
    end
  else
    vim.env.TMUX = nil
    vim.env.TMUX_PANE = nil
  end
  vim.fn.executable = function(name)
    table.insert(calls.executable, name)
    if name == binary and spec.opencode_available == false then
      return 0
    end
    local configured = spec.executable and spec.executable[name]
    if configured ~= nil then
      if configured == true or configured == 1 then
        return 1
      end
      return 0
    end
    return 1
  end
  vim.fn.jobstart = function(command)
    table.insert(calls.jobstart, vim.deepcopy(command))
    return -1
  end
  vim.fn.exists = function()
    return spec.terminal_available == false and 0 or 1
  end
  vim.fn.stdpath = function()
    return "/health-fixture/private-state"
  end
  vim.fn.isdirectory = function()
    return spec.state_exists == false and 0 or 1
  end
  vim.fn.mkdir = function(...)
    table.insert(calls.mkdir, vim.deepcopy({ ... }))
    return 1
  end
  vim.fn.filewritable = function()
    return spec.writable == false and 0 or 2
  end
  vim.bo.filetype = "lua"
  vim.treesitter.language.get_lang = function()
    return spec.parser_name or "lua"
  end
  vim.treesitter.get_parser = function()
    if spec.parser_available == false then
      error("missing parser fixture")
    end
    return {}
  end
  vim.uv.new_tcp = function()
    return {
      bind = function()
        return spec.loopback_available == false and 1 or 0
      end,
      close = function() end,
    }
  end
  vim.version.ge = function()
    return spec.nvim_available ~= false
  end
  vim.fn.system = function(command, ...)
    table.insert(calls.fn_system, vim.deepcopy(command))
    return old.fn_system(command, ...)
  end
  vim.system = function(command)
    table.insert(calls.system, vim.deepcopy(command))
    if command[1] == "git" and command[2] == "-C" then
      return {
        code = 0,
        stdout = (spec.git_root or root) .. "\n",
        wait = function(self)
          return self
        end,
      }
    end
    if command[1] == "tmux" then
      if command[2] == "-V" then
        return {
          code = spec.tmux_version_error and 1 or 0,
          stdout = spec.tmux_version or "tmux 3.4",
          wait = function(self)
            return self
          end,
        }
      end
      return {
        code = 1,
        stdout = "",
        wait = function(self)
          return self
        end,
      }
    end
    return {
      code = spec.git_probe_code or 0,
      wait = function(self)
        return self
      end,
    }
  end

  if spec.capture_guard_root then
    local guard = require("opencode.runtime.config_guard")
    package.loaded["opencode.runtime.config_guard"] = {
      scan = function(scan_root)
        calls.guard_root = scan_root
        return guard.scan(scan_root)
      end,
    }
  end

  if spec.snacks_available == false then
    package.loaded.snacks = nil
    package.preload.snacks = function()
      error("missing Snacks fixture")
    end
  else
    package.loaded.snacks = {
      config = {
        get = function(name)
          if name == "input" then
            return { enabled = spec.snack_input ~= false }
          end
          return { enabled = spec.snack_picker ~= false }
        end,
      },
    }
  end

  local success, failure = pcall(health.check)
  restore()
  assert(success, failure)
  return observations, calls
end

---Checks emitted health text and executable probes for the no-discovery, no-path contract.
---@param observations table
---@param calls table
local function assert_private_health(observations, calls)
  local output = {}
  for _, level in ipairs({ "start", "ok", "warn", "error" }) do
    vim.list_extend(output, observations[level])
  end
  local text = table.concat(output, "\n")
  eq(text:find("health-fixture", 1, true), nil)
  eq(text:find("private-state", 1, true), nil)
  eq(text:find("pgrep", 1, true), nil)
  eq(text:find("lsof", 1, true), nil)
  eq(contains(calls.executable, "pgrep"), false)
  eq(contains(calls.executable, "lsof"), false)
  assert_read_only_commands(calls)
  for _, command in ipairs(calls.system) do
    local command_text = table.concat(command, "\0")
    eq(command_text:find("pgrep", 1, true), nil)
    eq(command_text:find("lsof", 1, true), nil)
  end
  for _, command in ipairs(calls.fn_system) do
    local command_text = table.concat(command, "\0")
    eq(command_text:find("pgrep", 1, true), nil)
    eq(command_text:find("lsof", 1, true), nil)
  end
  eq(calls.jobstart, {})
  eq(calls.mkdir, {})
  if vim.env.HOME and vim.env.HOME ~= "" then
    eq(text:find(vim.env.HOME, 1, true), nil)
  end
end

T["AC-SEC-02 health works outside tmux without terminal probes"] = function()
  local outside, outside_calls = run_health({ in_tmux = false })
  local output = table.concat(outside.error, "\n") .. "\n" .. table.concat(outside.ok, "\n")
  eq(output:find("tmux", 1, true), nil)
  for _, command in ipairs(outside_calls.system) do
    eq(command[1], "git")
  end
  assert_private_health(outside, outside_calls)
end

T["health scans the canonical active-buffer root without creating state"] = function()
  local root = vim.fn.tempname()
  local project = root .. "/project"
  local file = project .. "/src/main.lua"
  vim.fn.mkdir(project .. "/src", "p")
  vim.fn.writefile({ "return true" }, file)

  local observations, calls = run_health({
    root = root,
    active_file = file,
    git_root = project,
    capture_guard_root = true,
    state_exists = false,
  })
  eq(calls.guard_root, vim.uv.fs_realpath(project))
  eq(calls.mkdir, {})
  eq(calls.jobstart, {})
  eq(
    contains(observations.error, "private state/temp directories are not writable; fix permissions on stdpath(state)"),
    true
  )
  assert_private_health(observations, calls)
  vim.fn.delete(root, "rf")
end

T["AC-SEC-02 health reports actionable local capability failures without discovery"] = function()
  local missing, missing_calls = run_health({
    nvim_available = false,
    snacks_available = false,
    parser_available = false,
    writable = false,
    loopback_available = false,
    terminal_available = false,
    opencode_available = false,
    executable = {
      curl = false,
      git = false,
    },
  })
  for _, message in ipairs({
    "Neovim 0.11.0 or newer is required",
    "snacks.nvim is required; install it and enable input and picker",
    "curl is required; install curl and restart Neovim",
    "git is required for three-way merge; install Git and restart Neovim",
    "OpenCode executable is unavailable; configure runtime.binary or install exactly 1.17.3 or 1.18.9",
    "cannot bind 127.0.0.1; allow a loopback listener",
    "jobstart process API is required; use Neovim 0.11.0 or newer",
    "private state/temp directories are not writable; fix permissions on stdpath(state)",
  }) do
    eq(contains(missing.error, message), true, message)
  end
  eq(
    contains(
      missing.warn,
      "Tree-sitter parser unavailable for lua; Build will use file scope (install the parser for function scope)"
    ),
    true
  )
  assert_private_health(missing, missing_calls)

  local snacks, snacks_calls = run_health({ snack_input = false, snack_picker = false })
  eq(contains(snacks.error, "snacks.input must be enabled in snacks.nvim"), true)
  eq(contains(snacks.error, "snacks.picker must be enabled in snacks.nvim"), true)
  assert_private_health(snacks, snacks_calls)

  local unsupported, unsupported_calls = run_health({ version = "9.9.9" })
  eq(contains(unsupported.error, "unsupported OpenCode 9.9.9; use exactly 1.17.3 or 1.18.9"), true)
  assert_private_health(unsupported, unsupported_calls)

  local merge_file, merge_file_calls = run_health({ git_probe_code = 1 })
  eq(contains(merge_file.error, "git merge-file file-operand mode is required; install a complete Git"), true)
  assert_private_health(merge_file, merge_file_calls)

  for _, profile in ipairs({
    {
      version = "1.17.3",
      fixture_sha256 = "41d34a78b59d6bd472dd6b10b3de77fd200faec1c6ed7b757f352eed58b84e24",
    },
    {
      version = "1.18.9",
      fixture_sha256 = "f5cb443f0d160fc4b17190f64c2401f199160eb2137ce4e00ca319b99aa34005",
    },
  }) do
    local supported, supported_calls = run_health({ version = profile.version })
    eq(
      contains(supported.ok, "OpenCode " .. profile.version .. " selected; fixture SHA-256 " .. profile.fixture_sha256),
      true
    )
    assert_private_health(supported, supported_calls)
  end
end

T["health ignores plugins and MCPs without config content or paths"] = function()
  local fixtures = {
    {
      name = "custom plugin",
      content = '{"plugin":{"private-plugin":"PLUGIN_SECRET_BODY"}}',
      ok = "local OpenCode config parsed; plugins and MCPs are ignored; custom tools remain blocked",
      secret = "PLUGIN_SECRET_BODY",
    },
    {
      name = "custom tool",
      content = '{"tool":{"private-tool":"TOOL_SECRET_BODY"}}',
      error = "custom OpenCode tools are blocked; use a clean config for this plugin; see docs/RECOVERY.md",
      secret = "TOOL_SECRET_BODY",
    },
    {
      name = "enabled MCP",
      content = '{"mcp":{"private-mcp":{"command":"MCP_SECRET_BODY"}}}',
      ok = "local OpenCode config parsed; plugins and MCPs are ignored; custom tools remain blocked",
      secret = "MCP_SECRET_BODY",
    },
    {
      name = "malformed config",
      content = '{"broken":"MALFORMED_SECRET_BODY"',
      error = "OpenCode config could not be parsed; fix it or use a clean config; see docs/RECOVERY.md",
      secret = "MALFORMED_SECRET_BODY",
    },
  }

  for _, fixture in ipairs(fixtures) do
    local observations, calls = run_health({ config_content = fixture.content })
    local messages = fixture.ok or fixture.error
    local level = fixture.ok and observations.ok or observations.error
    eq(contains(level, messages), true, fixture.name)
    local output = {}
    for _, level in ipairs({ "start", "ok", "warn", "error" }) do
      vim.list_extend(output, observations[level])
    end
    local text = table.concat(output, "\n")
    eq(text:find(fixture.secret, 1, true), nil, fixture.name)
    eq(text:find("health-private-path", 1, true), nil, fixture.name)
    assert_private_health(observations, calls)
    eq(#calls.jobstart, 0, fixture.name)
  end

  local clean, clean_calls = run_health({ config_content = '{"mcp":{"disabled":{"enabled":false}}}' })
  eq(
    contains(clean.ok, "local OpenCode config parsed; plugins and MCPs are ignored; custom tools remain blocked"),
    true
  )
  eq(contains(clean.error, "local OpenCode config is blocked"), false)
  assert_private_health(clean, clean_calls)
  eq(#clean_calls.jobstart, 0)
end

return T
