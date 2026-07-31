---@class opencode.Opts
---@field runtime? { binary?: string, startup_timeout?: integer, reconnect?: { max_attempts?: integer, backoff_ms?: integer, max_backoff_ms?: integer }, shutdown_timeout?: integer }
---@field sidebar? { width?: number }
---@field contexts? table<string, function>
---@field ask? { completion?: string, snacks?: table }
---@field notify? { enabled?: boolean, opts?: table }

---@type opencode.Opts?
vim.g.opencode_opts = vim.g.opencode_opts

local defaults = {
  runtime = {
    binary = "opencode",
    startup_timeout = 10000,
    reconnect = { max_attempts = 5, backoff_ms = 100, max_backoff_ms = 2000 },
    shutdown_timeout = 2000,
  },
  sidebar = { width = 0.30 },
  notify = { enabled = true, opts = {} },
  contexts = {
    ["@this"] = require("opencode.context.builtins").this,
    ["@buffer"] = require("opencode.context.builtins").buffer,
    ["@buffers"] = require("opencode.context.builtins").buffers,
    ["@diagnostics"] = require("opencode.context.builtins").diagnostics,
    ["@marks"] = require("opencode.context.builtins").marks,
    ["@quickfix"] = require("opencode.context.builtins").quickfix,
    ["@visible"] = require("opencode.context.builtins").visible_text,
  },
  ask = {
    completion = "customlist,v:lua.opencode_completion",
    snacks = {
      icon = "Plan ",
      history = false,
      win = {
        relative = "cursor",
        row = -3,
        col = 0,
        b = { completion = true },
        bo = { filetype = "opencode_ask" },
      },
    },
  },
}

local function failure(scope, reason)
  return false, { scope = scope, reason = reason }
end

local function check_number(value, scope, minimum, maximum, integer)
  if
    type(value) ~= "number"
    or integer and value % 1 ~= 0
    or minimum and value < minimum
    or maximum and value > maximum
  then
    return failure(scope, "type_or_range")
  end
  return true
end

---Validates only the documented v2 options and reports a source scope without exposing option values.
---Nested runtime numbers are range-checked, context values must be functions, and provider-specific Snacks options
---remain a single documented table passed to Snacks unchanged.
---@param value table
---@return boolean
---@return table?
local function validate(value)
  if type(value) ~= "table" then
    return failure("root", "type")
  end
  for key in pairs(value) do
    if key ~= "runtime" and key ~= "sidebar" and key ~= "contexts" and key ~= "ask" and key ~= "notify" then
      return failure("" .. key, "unsupported_key")
    end
  end
  if value.runtime then
    if type(value.runtime) ~= "table" then
      return failure("runtime", "type")
    end
    for key in pairs(value.runtime) do
      if key ~= "binary" and key ~= "startup_timeout" and key ~= "reconnect" and key ~= "shutdown_timeout" then
        return failure("runtime." .. key, "unsupported_key")
      end
    end
    if value.runtime.binary and (type(value.runtime.binary) ~= "string" or value.runtime.binary == "") then
      return failure("runtime.binary", "type")
    end
    local ok, err = check_number(
      value.runtime.startup_timeout or defaults.runtime.startup_timeout,
      "runtime.startup_timeout",
      1,
      nil,
      true
    )
    if not ok then
      return ok, err
    end
    ok, err = check_number(
      value.runtime.shutdown_timeout or defaults.runtime.shutdown_timeout,
      "runtime.shutdown_timeout",
      1,
      nil,
      true
    )
    if not ok then
      return ok, err
    end
    if value.runtime.reconnect then
      if type(value.runtime.reconnect) ~= "table" then
        return failure("runtime.reconnect", "type")
      end
      for key in pairs(value.runtime.reconnect) do
        if key ~= "max_attempts" and key ~= "backoff_ms" and key ~= "max_backoff_ms" then
          return failure("runtime.reconnect." .. key, "unsupported_key")
        end
      end
      for _, key in ipairs({ "max_attempts", "backoff_ms", "max_backoff_ms" }) do
        ok, err = check_number(
          value.runtime.reconnect[key] or defaults.runtime.reconnect[key],
          "runtime.reconnect." .. key,
          1,
          nil,
          true
        )
        if not ok then
          return ok, err
        end
      end
    end
  end
  if value.sidebar then
    if type(value.sidebar) ~= "table" then
      return failure("sidebar", "type")
    end
    for key in pairs(value.sidebar) do
      if key ~= "width" then
        return failure("sidebar." .. key, "unsupported_key")
      end
    end
    local ok, err = check_number(value.sidebar.width or defaults.sidebar.width, "sidebar.width", 0.05, 0.95, false)
    if not ok then
      return ok, err
    end
  end
  if value.contexts then
    if type(value.contexts) ~= "table" then
      return failure("contexts", "type")
    end
    for key, context in pairs(value.contexts) do
      if type(key) ~= "string" or type(context) ~= "function" then
        return failure("contexts", "type")
      end
    end
  end
  if value.ask then
    if type(value.ask) ~= "table" then
      return failure("ask", "type")
    end
    for key in pairs(value.ask) do
      if key ~= "completion" and key ~= "snacks" then
        return failure("ask." .. key, "unsupported_key")
      end
    end
    if value.ask.completion and type(value.ask.completion) ~= "string" then
      return failure("ask.completion", "type")
    end
    if value.ask.snacks and type(value.ask.snacks) ~= "table" then
      return failure("ask.snacks", "type")
    end
  end
  if value.notify then
    if type(value.notify) ~= "table" then
      return failure("notify", "type")
    end
    for key in pairs(value.notify) do
      if key ~= "enabled" and key ~= "opts" then
        return failure("notify." .. key, "unsupported_key")
      end
    end
    if value.notify.enabled ~= nil and type(value.notify.enabled) ~= "boolean" then
      return failure("notify.enabled", "type")
    end
    if value.notify.opts and type(value.notify.opts) ~= "table" then
      return failure("notify.opts", "type")
    end
  end
  return true
end

local user_opts = vim.g.opencode_opts or {}
local valid, validation_error = validate(user_opts)
local opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), valid and user_opts or {})

return {
  opts = opts,
  defaults = vim.deepcopy(defaults),
  validation_error = validation_error,
  validate = validate,
}
