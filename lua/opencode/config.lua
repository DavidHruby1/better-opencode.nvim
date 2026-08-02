---@class opencode.Opts
---@field runtime? { binary?: string, startup_timeout?: integer, reconnect?: { max_attempts?: integer, backoff_ms?: integer, max_backoff_ms?: integer }, shutdown_timeout?: integer }
---@field contexts? table<string, function>
---@field ask? { snacks?: { win?: snacks.win.Config } }
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
    snacks = {
      win = {
        backdrop = false,
        border = "rounded",
        width = 60,
        height = 1,
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
---Present optional values are checked before defaults are merged, nested runtime numbers are range-checked, and context
---values must be functions. Ask customizations stay in one Snacks.win table constrained when the prompt opens.
---@param value any
---@return boolean
---@return table?
local function validate(value)
  if type(value) ~= "table" then
    return failure("root", "type")
  end
  for key in pairs(value) do
    if key ~= "runtime" and key ~= "contexts" and key ~= "ask" and key ~= "notify" then
      return failure(tostring(key), "unsupported_key")
    end
  end
  if value.runtime ~= nil then
    if type(value.runtime) ~= "table" then
      return failure("runtime", "type")
    end
    for key in pairs(value.runtime) do
      if key ~= "binary" and key ~= "startup_timeout" and key ~= "reconnect" and key ~= "shutdown_timeout" then
        return failure("runtime." .. tostring(key), "unsupported_key")
      end
    end
    if value.runtime.binary ~= nil and (type(value.runtime.binary) ~= "string" or value.runtime.binary == "") then
      return failure("runtime.binary", "type")
    end
    if value.runtime.startup_timeout ~= nil then
      local ok, err = check_number(value.runtime.startup_timeout, "runtime.startup_timeout", 1, nil, true)
      if not ok then
        return ok, err
      end
    end
    if value.runtime.shutdown_timeout ~= nil then
      local ok, err = check_number(value.runtime.shutdown_timeout, "runtime.shutdown_timeout", 1, nil, true)
      if not ok then
        return ok, err
      end
    end
    if value.runtime.reconnect ~= nil then
      if type(value.runtime.reconnect) ~= "table" then
        return failure("runtime.reconnect", "type")
      end
      for key in pairs(value.runtime.reconnect) do
        if key ~= "max_attempts" and key ~= "backoff_ms" and key ~= "max_backoff_ms" then
          return failure("runtime.reconnect." .. tostring(key), "unsupported_key")
        end
      end
      for _, key in ipairs({ "max_attempts", "backoff_ms", "max_backoff_ms" }) do
        if value.runtime.reconnect[key] ~= nil then
          local ok, err = check_number(value.runtime.reconnect[key], "runtime.reconnect." .. key, 1, nil, true)
          if not ok then
            return ok, err
          end
        end
      end
    end
  end
  if value.contexts ~= nil then
    if type(value.contexts) ~= "table" then
      return failure("contexts", "type")
    end
    for key, context in pairs(value.contexts) do
      if type(key) ~= "string" or type(context) ~= "function" then
        return failure("contexts", "type")
      end
    end
  end
  if value.ask ~= nil then
    if type(value.ask) ~= "table" then
      return failure("ask", "type")
    end
    for key in pairs(value.ask) do
      if key ~= "snacks" then
        return failure("ask." .. tostring(key), "unsupported_key")
      end
    end
    if value.ask.snacks ~= nil and type(value.ask.snacks) ~= "table" then
      return failure("ask.snacks", "type")
    end
    if value.ask.snacks ~= nil then
      for key in pairs(value.ask.snacks) do
        if key ~= "win" then
          return failure("ask.snacks." .. tostring(key), "unsupported_key")
        end
      end
      if value.ask.snacks.win ~= nil and type(value.ask.snacks.win) ~= "table" then
        return failure("ask.snacks.win", "type")
      end
    end
  end
  if value.notify ~= nil then
    if type(value.notify) ~= "table" then
      return failure("notify", "type")
    end
    for key in pairs(value.notify) do
      if key ~= "enabled" and key ~= "opts" then
        return failure("notify." .. tostring(key), "unsupported_key")
      end
    end
    if value.notify.enabled ~= nil and type(value.notify.enabled) ~= "boolean" then
      return failure("notify.enabled", "type")
    end
    if value.notify.opts ~= nil and type(value.notify.opts) ~= "table" then
      return failure("notify.opts", "type")
    end
  end
  return true
end

local configured_opts = vim.g.opencode_opts
local user_opts = configured_opts == nil and {} or configured_opts
local valid, validation_error = validate(user_opts)
local opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), valid and user_opts or {})

return {
  opts = opts,
  defaults = vim.deepcopy(defaults),
  validation_error = validation_error,
  validate = validate,
}
