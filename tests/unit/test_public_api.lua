local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local Promise = require("opencode.promise")

---Temporarily replaces the public API's external module boundaries and always restores package state.
---The callback runs with deterministic Runtime, context, input, and prompt fakes, while the real public module
---and Promise callbacks remain in use so these cases prove user-facing dispatch rather than private helpers.
---Promise callbacks run inline here so MiniTest cases already queued by the full-suite runner cannot observe fakes.
---@param modules table<string, table>
---@param callback function
local function with_modules(modules, callback)
  local saved = {}
  for name, module in pairs(modules) do
    saved[name] = package.loaded[name]
    package.loaded[name] = module
  end

  local original_schedule = vim.schedule
  vim.schedule = function(callback)
    callback()
  end
  local ok, failure = xpcall(callback, debug.traceback)
  vim.schedule = original_schedule
  for name in pairs(modules) do
    package.loaded[name] = saved[name]
  end
  assert(ok, failure)
end

T["public ask dispatches explicit Plan and default Build modes"] = function()
  local ask_calls, prompt_calls = {}, {}
  local runtime = {
    prompt_blocker = function()
      return nil
    end,
  }
  local context_module = {
    capture = function()
      return {}
    end,
    new = function()
      return { runtime = runtime }
    end,
  }
  local opencode = require("opencode")

  with_modules({
    ["opencode.context"] = context_module,
    ["opencode.context.preflight"] = {
      run = function(context)
        return Promise.resolve(context)
      end,
    },
    ["opencode.runtime"] = {
      acquire = function()
        return runtime, Promise.resolve(runtime)
      end,
    },
    ["opencode.ui.ask"] = {
      ask = function(default, context, mode, opts, readiness, submit)
        table.insert(
          ask_calls,
          { default = default, context = context, mode = mode, opts = opts, readiness = readiness }
        )
        submit(mode .. " input")
        return Promise.resolve(mode .. " input")
      end,
    },
    ["opencode.api.prompt"] = {
      prompt = function(text, context, opts)
        table.insert(prompt_calls, { text = text, context = context, opts = opts })
        return Promise.resolve({})
      end,
    },
  }, function()
    local plan = opencode.ask(nil, { mode = "plan" })
    local build = opencode.ask()
    eq(type(plan.next), "function")
    eq(type(build.next), "function")
  end)

  eq(#prompt_calls, 2)
  eq(ask_calls[1].mode, "plan")
  eq(prompt_calls[1].text, "plan input")
  eq(prompt_calls[1].opts.mode, "plan")
  eq(ask_calls[2].mode, "build")
  eq(prompt_calls[2].text, "build input")
  eq(prompt_calls[2].opts, nil)
end

T["operator rejects an invalid mode before installing an operator"] = function()
  local opencode = require("opencode")
  local original_notify = vim.notify
  local message
  local original_operator = vim.o.operatorfunc
  vim.notify = function(value)
    message = value
  end
  local result = opencode.operator("ignored", { mode = "review" })
  vim.notify = original_notify
  eq(result, "")
  eq(message:find("mode_unavailable", 1, true) ~= nil, true)
  eq(vim.o.operatorfunc, original_operator)
end

T["public startup rejection reaches the safe notification boundary"] = function()
  local rejection = {
    error_class = "startup_timeout",
    endpoint = "https://user:password@example.test/session/private?token=secret",
    status = 503,
    body = "STARTUP_RESPONSE_SECRET",
    message = "raw exception /private/project",
  }
  local runtime = {}
  local messages = {}
  local original_notify = vim.notify
  local opencode = require("opencode")

  local ok, failure = xpcall(function()
    vim.notify = function(message)
      table.insert(messages, message)
    end
    with_modules({
      ["opencode.context"] = {
        capture = function()
          return {}
        end,
      },
      ["opencode.runtime"] = {
        acquire = function()
          return nil, Promise.reject(rejection)
        end,
      },
    }, function()
      opencode.ask(nil, { mode = "plan" })
    end)
    eq(messages[1]:find("owned OpenCode startup timed out", 1, true) ~= nil, true)
    for _, secret in ipairs({ "STARTUP_RESPONSE_SECRET", "password", "secret", "raw exception", "/private/project" }) do
      eq(messages[1]:find(secret, 1, true), nil, secret)
    end
  end, debug.traceback)

  vim.notify = original_notify
  assert(ok, failure)
end

return T
