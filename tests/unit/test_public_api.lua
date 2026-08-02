---@diagnostic disable: duplicate-set-field

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

T["public ask uses Build for default and explicit Build modes"] = function()
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
        submit("Build input")
        return Promise.resolve("Build input")
      end,
    },
    ["opencode.api.prompt"] = {
      prompt = function(text, context, opts)
        table.insert(prompt_calls, { text = text, context = context, opts = opts })
        return Promise.resolve({})
      end,
    },
  }, function()
    local build = assert(opencode.ask(nil, { mode = "build" }))
    local default_build = assert(opencode.ask())
    eq(type(build.next), "function")
    eq(type(default_build.next), "function")
  end)

  eq(#prompt_calls, 2)
  eq(ask_calls[1].mode, "build")
  eq(prompt_calls[1].text, "Build input")
  eq(prompt_calls[1].opts.mode, "build")
  eq(ask_calls[2].mode, "build")
  eq(prompt_calls[2].text, "Build input")
  eq(prompt_calls[2].opts, nil)
end

T["public ask rejects Plan before opening UI or acquiring a Runtime"] = function()
  local calls = { acquire = 0, ask = 0 }
  local opencode = require("opencode")
  local old_notify = vim.notify
  local message
  vim.notify = function(value)
    message = value
  end

  with_modules({
    ["opencode.runtime"] = {
      acquire = function()
        calls.acquire = calls.acquire + 1
      end,
    },
    ["opencode.ui.ask"] = {
      ask = function()
        calls.ask = calls.ask + 1
      end,
    },
  }, function()
    local rejection = opencode.ask(nil, { mode = "plan" })
    local error
    rejection:catch(function(value)
      error = value
    end)
    eq(error, { error_class = "mode_unavailable" })
    local prompt_rejection = opencode.prompt("ignored", { mode = "plan" })
    local prompt_error
    prompt_rejection:catch(function(value)
      prompt_error = value
    end)
    eq(prompt_error, { error_class = "mode_unavailable" })
  end)

  vim.notify = old_notify
  eq(calls, { acquire = 0, ask = 0 })
  eq(message:find("mode_unavailable", 1, true) ~= nil, true)
end

T["public select exposes only recovery actions and dispatches the chosen action"] = function()
  local opencode = require("opencode")
  local actions, diagnostics_runtime, menus = {}, nil, {}
  local runtime = {
    state = "ready",
    interaction_locked = false,
    restart = function(self)
      table.insert(actions, "restart")
      return Promise.resolve(self)
    end,
  }
  local choices = { "Restart runtime", "Show diagnostics" }
  local original_select = vim.ui.select
  local ok, failure = xpcall(function()
    with_modules({
      ["opencode.runtime"] = {
        current = function()
          return runtime
        end,
      },
      ["opencode.ui.notify"] = {
        diagnostics = function(value)
          diagnostics_runtime = value
        end,
      },
    }, function()
      for _, choice in ipairs(choices) do
        vim.ui.select = function(items, opts, callback)
          table.insert(menus, { items = vim.deepcopy(items), prompt = opts.prompt })
          callback(choice)
        end
        opencode.select()
      end
    end)
  end, debug.traceback)
  vim.ui.select = original_select
  assert(ok, failure)

  eq(#menus, #choices)
  for _, menu in ipairs(menus) do
    eq(menu.items, choices)
    eq(menu.prompt, "OpenCode")
  end
  eq(actions, { "restart" })
  eq(diagnostics_runtime, runtime)
end

T["public session picker keeps the Build boundary and captured context"] = function()
  local opencode = require("opencode")
  local runtime, captured_context, picker_opts
  local context = {}
  local fake_runtime = {}

  with_modules({
    ["opencode.context"] = {
      capture = function()
        return context
      end,
      new = function()
        return { marker = "captured" }
      end,
    },
    ["opencode.runtime"] = {
      acquire = function()
        return fake_runtime, Promise.resolve(fake_runtime)
      end,
    },
    ["opencode.ui.session_picker"] = {
      open = function(value, captured, opts)
        runtime, captured_context, picker_opts = value, captured, opts
        return Promise.resolve("picked")
      end,
    },
  }, function()
    local result = opencode.select_session({ mode = "build" })
    local picked
    result:next(function(value)
      picked = value
    end)
    eq(picked, "picked")
  end)

  eq(runtime, fake_runtime)
  eq(captured_context.marker, "captured")
  eq(picker_opts.mode, "build")
end

T["operator rejects an invalid mode before installing an operator"] = function()
  local opencode = require("opencode")
  local original_notify = vim.notify
  local message
  local original_operator = vim.o.operatorfunc
  vim.notify = function(value)
    message = value
  end
  ---@diagnostic disable-next-line: assign-type-mismatch
  local result = opencode.operator("ignored", { mode = "review" })
  vim.notify = original_notify
  eq(result, "")
  eq(assert(message):find("mode_unavailable", 1, true) ~= nil, true)
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
      opencode.ask(nil, { mode = "build" })
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
