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

---Runs the public health check against local capability boundaries without starting OpenCode.
---The returned observations preserve health levels and command probes for privacy assertions.
---@param spec? table
---@return table, table
local function run_health(spec)
  spec = spec or {}
  local binary = vim.fn.tempname()
  vim.fn.writefile({ "#!/bin/sh", spec.version_error and "exit 1" or "printf '%s\\n' '" .. (spec.version or "") .. "'" }, binary)
  assert(vim.uv.fs_chmod(binary, 493))
  local observations = { start = {}, ok = {}, warn = {}, error = {} }
  local calls = { executable = {}, system = {} }
  local config = require("opencode.config")
  local health = require("opencode.health")
  local old = {
    health = vim.health,
    executable = vim.fn.executable,
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
    binary = config.opts.runtime.binary,
    snacks = package.loaded.snacks,
    snacks_preload = package.preload.snacks,
  }

  local function restore()
    vim.health = old.health
    vim.fn.executable = old.executable
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
    config.opts.runtime.binary = old.binary
    package.loaded.snacks = old.snacks
    package.preload.snacks = old.snacks_preload
    vim.uv.fs_unlink(binary)
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
  vim.fn.exists = function()
    return spec.terminal_available == false and 0 or 1
  end
  vim.fn.stdpath = function()
    return "/health-fixture/private-state"
  end
  vim.fn.isdirectory = function()
    return 1
  end
  vim.fn.mkdir = function()
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
  vim.system = function(command)
    table.insert(calls.system, vim.deepcopy(command))
    return {
      code = spec.git_probe_code or 0,
      wait = function(self)
        return self
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
  for _, command in ipairs(calls.system) do
    local command_text = table.concat(command, "\0")
    eq(command_text:find("pgrep", 1, true), nil)
    eq(command_text:find("lsof", 1, true), nil)
  end
  if vim.env.HOME and vim.env.HOME ~= "" then
    eq(text:find(vim.env.HOME, 1, true), nil)
  end
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
    "jobstart(term=true) terminal API is required; use Neovim 0.11.0 or newer",
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
      contains(
        supported.ok,
        "OpenCode " .. profile.version .. " selected; fixture SHA-256 " .. profile.fixture_sha256
      ),
      true
    )
    assert_private_health(supported, supported_calls)
  end
end

return T
