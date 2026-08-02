---@diagnostic disable: duplicate-set-field

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["Runtime accepts only valid lifecycle transitions"] = function()
  local runtime = require("opencode.runtime").new("/root")
  eq(runtime:transition("starting"), true)
  eq(runtime:transition("ready"), true)
  eq(runtime:transition("disconnected"), true)
  eq(runtime:transition("starting"), true)
  eq(runtime:transition("stopping"), true)
  eq(runtime:transition("stopped"), true)
  eq(runtime:transition("ready"), false)
end

T["Runtime prompt blocker exposes the concrete lifecycle gate"] = function()
  local runtime = require("opencode.runtime").new("/root")
  eq(runtime:prompt_blocker(), "disconnected")
  runtime.state = "starting"
  eq(runtime:prompt_blocker(), "starting")
  runtime.state, runtime.sse_live = "ready", true
  eq(runtime:prompt_blocker(), nil)
  runtime.state, runtime.reconciling = "disconnected", true
  eq(runtime:prompt_blocker(), "disconnected")
  runtime.reconciling = false
  runtime.state = "ready"
  runtime.reconciling = true
  eq(runtime:prompt_blocker(), "reconciling")
  runtime.reconciling, runtime.reconciliation_failed = false, true
  eq(runtime:prompt_blocker(), "reconciliation_failed")
  runtime.reconciliation_failed, runtime.prompt_locked = nil, true
  eq(runtime:prompt_blocker(), "reconciliation_blocked")
  runtime.prompt_locked = false
  eq(runtime:prompt_blocker(), nil)
end

T["stale HTTP completion is rejected after Runtime generation changes"] = function()
  local callback
  local runtime = require("opencode.runtime").new("/root")
  runtime.generation = 1
  local client = require("opencode.client").new({
    host = "127.0.0.1",
    port = 1,
    username = "u",
    password = "p",
    root = "/root",
    runtime = runtime,
    runner = function(_, _, done)
      callback = done
    end,
  })
  local error
  client:health():catch(function(value)
    error = value
  end)
  runtime.generation = 2
  callback({ code = 0, stdout = vim.json.encode({ healthy = true }) .. "__OPENCODE_STATUS__:200" })
  eq(
    vim.wait(100, function()
      return error ~= nil
    end),
    true
  )
  eq(error.error_class, "stale_generation")
end

T["SSE reconnect attempts exhaust after a live stream exits"] = function()
  local Promise = require("opencode.promise")
  local config = require("opencode.config").opts.runtime.reconnect
  local saved = vim.deepcopy(config)
  config.max_attempts, config.backoff_ms, config.max_backoff_ms = 2, 0, 0
  local runtime = require("opencode.runtime").new("/root")
  runtime.state = "ready"
  local subscriptions = 0
  runtime.client = {
    subscribe = function(_, on_event, on_exit)
      subscriptions = subscriptions + 1
      vim.schedule(function()
        if subscriptions <= 2 then
          on_event({ type = "server.connected", properties = {} })
        end
        on_exit(7)
      end)
      return subscriptions
    end,
    session_status = function()
      return Promise.resolve({})
    end,
    questions = function()
      return Promise.resolve({})
    end,
    permissions = function()
      return Promise.resolve({})
    end,
  }
  runtime:connect_sse()
  eq(
    vim.wait(500, function()
      return runtime.reconnect_error ~= nil
    end),
    true
  )
  eq({ subscriptions, runtime.reconnect_attempt, runtime.reconnect_error }, { 3, 3, "reconnect_exhausted" })
  for key, value in pairs(saved) do
    config[key] = value
  end
end

T["SSE startup timeout stops an unconnected stream and allows retry"] = function()
  local config = require("opencode.config").opts.runtime
  local saved_timeout = config.startup_timeout
  local old_jobstop = vim.fn.jobstop
  local stopped, subscriptions = {}, 0
  local runtime = require("opencode.runtime").new("/root")
  runtime.state = "ready"
  runtime.client = {
    subscribe = function(_, on_event)
      subscriptions = subscriptions + 1
      if subscriptions == 2 then
        vim.schedule(function()
          on_event({ type = "server.connected", properties = {} })
        end)
      end
      return subscriptions
    end,
  }
  config.startup_timeout = 20
  vim.fn.jobstop = function(job)
    table.insert(stopped, job)
  end

  local first_error
  runtime:connect_sse():catch(function(err)
    first_error = err
  end)
  local first_settled = vim.wait(500, function()
    return first_error ~= nil
  end)
  config.startup_timeout = saved_timeout
  vim.fn.jobstop = old_jobstop

  eq(first_settled, true)
  eq(first_error.error_class, "startup_timeout")
  eq({ runtime.sse, runtime.sse_live, runtime.stream_generation, stopped[1] }, { nil, false, 2, 1 })

  local retry_result, retry_error
  runtime
    :connect_sse()
    :next(function(value)
      retry_result = value
    end)
    :catch(function(err)
      retry_error = err
    end)
  eq(
    vim.wait(500, function()
      return retry_result ~= nil or retry_error ~= nil
    end),
    true
  )
  eq({ retry_result, retry_error, runtime.sse_live, subscriptions }, { runtime, nil, true, 2 })
end

T["direct reconciliation fetches status when no snapshot is supplied"] = function()
  local Promise = require("opencode.promise")
  local runtime = require("opencode.runtime").new("/root")
  runtime.state = "disconnected"
  runtime.sse_live = true
  local job = require("opencode.job").new("ses_1", {
    root = "/root",
    buf = 1,
    path = "/root/file.lua",
    mode = "build",
  })
  runtime.jobs[job.key] = job
  runtime.sessions.ses_1 = { id = "ses_1", active_job_key = job.key }
  local calls, status_requests = {}, 0
  runtime.client = {
    session_status = function()
      status_requests = status_requests + 1
      table.insert(calls, "status")
      return Promise.resolve({ ses_1 = "idle" })
    end,
    messages = function()
      table.insert(calls, "messages")
      return Promise.resolve({ { info = { id = "assistant_1", role = "assistant", parentID = job.user_message_id } } })
    end,
    questions = function()
      table.insert(calls, "questions")
      return Promise.resolve({})
    end,
    permissions = function()
      table.insert(calls, "permissions")
      return Promise.resolve({})
    end,
  }
  local done
  require("opencode.runtime.reconcile").run(runtime, 1):next(function()
    done = true
  end)
  eq(
    vim.wait(500, function()
      return done == true
    end),
    true
  )
  eq(job.state, "completed")
  eq(job.completion_count, 1)
  eq(runtime.state, "ready")
  eq(runtime.prompt_locked, false)
  eq(status_requests, 1)
  eq(calls, { "status", "messages", "questions", "permissions" })
end

T["failed reconciliation stays blocked and notifies until a later snapshot succeeds"] = function()
  local Promise = require("opencode.promise")
  local runtime = require("opencode.runtime").new("/root")
  runtime.state, runtime.sse_live = "ready", true
  runtime.reconnect_attempt = 3
  local calls, notifications = 0, {}
  local old_notify = vim.notify
  vim.notify = function(message)
    table.insert(notifications, message)
  end
  runtime.client = {
    session_status = function()
      calls = calls + 1
      return calls == 1 and Promise.reject({ error_class = "status_unavailable" }) or Promise.resolve({})
    end,
    questions = function()
      return Promise.resolve({})
    end,
    permissions = function()
      return Promise.resolve({})
    end,
  }
  runtime:begin_reconciliation()
  eq(
    vim.wait(500, function()
      return runtime.reconciliation_failed == true
    end),
    true
  )
  eq({ runtime.prompt_blocker and runtime:prompt_blocker() or nil, #notifications }, { "reconciliation_failed", 1 })
  eq(runtime.reconnect_attempt, 3)

  runtime:begin_reconciliation()
  eq(
    vim.wait(500, function()
      return runtime.reconciliation_failed == nil and runtime.reconciling == false
    end),
    true
  )
  eq({ runtime.prompt_blocker and runtime:prompt_blocker() or nil, runtime.reconciliation_required }, { nil, false })
  eq(runtime.reconnect_attempt, 0)
  vim.notify = old_notify
end

T["reconciliation timeout terminalizes remote-dependent Jobs and cleans claims"] = function()
  local Promise = require("opencode.promise")
  local config = require("opencode.config").opts.runtime
  local saved_timeout = config.startup_timeout
  config.startup_timeout = 20
  local runtime = require("opencode.runtime").new("/root")
  runtime.state, runtime.sse_live, runtime.generation = "ready", true, 1
  local job =
    { key = "job_timeout", root = runtime.root, runtime = runtime, session_id = "ses_timeout", state = "running" }
  local session = { id = job.session_id, active_job_key = job.key }
  runtime.jobs[job.key], runtime.sessions[session.id] = job, session
  runtime.session_claims[session.id] = { pending = false, job_key = job.key }
  runtime.client = {
    session_status = function()
      return Promise.new(function() end)
    end,
  }
  local error
  require("opencode.runtime.reconcile").run(runtime, 1):catch(function(err)
    error = err
  end)
  eq(
    vim.wait(500, function()
      return error ~= nil
    end),
    true
  )
  config.startup_timeout = saved_timeout
  eq({ error.error_class, job.state, job.error_class }, { "reconciliation_timeout", "error", "reconciliation_timeout" })
  eq({ session.active_job_key, session.availability, runtime.session_claims[session.id] }, { nil, "blocked", nil })
  eq(runtime:prompt_blocker(), "reconciliation_failed")
end

T["stale reconciliation callbacks cannot mutate the current generation"] = function()
  local Promise = require("opencode.promise")
  local resolve_old
  local runtime = require("opencode.runtime").new("/root")
  runtime.state, runtime.sse_live, runtime.generation = "ready", true, 1
  local job = { key = "job_generation", root = runtime.root, session_id = "ses_generation", state = "running" }
  local session = { id = job.session_id, active_job_key = job.key }
  runtime.jobs[job.key], runtime.sessions[session.id] = job, session
  runtime.client = {
    session_status = function()
      return Promise.new(function(resolve)
        resolve_old = resolve
      end)
    end,
    messages = function()
      return Promise.resolve({})
    end,
    questions = function()
      return Promise.resolve({})
    end,
    permissions = function()
      return Promise.resolve({})
    end,
  }
  local stale_error
  require("opencode.runtime.reconcile").run(runtime, 1):catch(function(err)
    stale_error = err
  end)
  runtime.generation = 2
  local current = require("opencode.runtime.reconcile").run(runtime, 2, { ses_generation = "busy" })
  eq(current ~= nil, true)
  assert(resolve_old)({ ses_generation = "idle" })
  eq(
    vim.wait(500, function()
      return stale_error ~= nil and runtime.reconciling == false
    end),
    true
  )
  eq({ stale_error.error_class, job.state, session.remote_status }, { "stale_generation", "running", "busy" })
end

T["interaction identity keeps identical request IDs isolated by root"] = function()
  package.loaded["opencode.interaction"] = nil
  local interaction = require("opencode.interaction")
  interaction.enqueue({
    root = "/one",
    session_id = "ses",
    job_key = "job",
    request_id = "req",
    kind = "question",
    payload = {},
  })
  interaction.enqueue({
    root = "/two",
    session_id = "ses",
    job_key = "job",
    request_id = "req",
    kind = "question",
    payload = {},
  })
  eq(interaction.has_remote("ses", "job", "req", "/one"), true)
  eq(interaction.has_remote("ses", "job", "req", "/two"), true)
end

T["cancel all snapshots every Runtime and reports aggregate failures"] = function()
  local Promise = require("opencode.promise")
  local Runtime = require("opencode.runtime")
  local first = Runtime.new("/one")
  local second = Runtime.new("/two")
  Runtime.registry[first.root], Runtime.registry[second.root] = first, second
  for index, runtime in ipairs({ first, second }) do
    local key = "job_" .. index
    runtime.client = {
      abort = function()
        return index == 1 and Promise.reject({ error_class = "http" }) or Promise.resolve(nil)
      end,
    }
    runtime.sessions.s = { id = "s", active_job_key = key }
    runtime.jobs[key] = { key = key, root = runtime.root, session_id = "s", state = "running", mode = "build" }
  end
  local report
  Runtime.cancel_all():next(function(value)
    report = value
  end)
  eq(
    vim.wait(500, function()
      return report ~= nil
    end),
    true
  )
  eq(report, { requested = 2, cancelled = 2, abort_failed = 1 })
  Runtime.registry[first.root], Runtime.registry[second.root] = nil, nil
end

return T
