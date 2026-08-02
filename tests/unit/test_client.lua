---@diagnostic disable: duplicate-set-field

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local fixture_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/client"

local function client_with_runner(runner, runtime)
  return require("opencode.client").new({
    host = "127.0.0.1",
    port = 4096,
    username = "private-user",
    password = "private-password",
    root = "/private/root",
    runner = runner,
    runtime = runtime,
  })
end

local function wait_for(value)
  eq(
    vim.wait(200, function()
      return value() ~= nil
    end),
    true
  )
end

---Replaces Neovim's job and timer functions with manually driven doubles for one test.
---The callback receives every job callback and timer, and globals are restored even when an assertion fails.
local function with_sse_harness(callback)
  local saved = {
    jobstart = vim.fn.jobstart,
    chansend = vim.fn.chansend,
    chanclose = vim.fn.chanclose,
    jobstop = vim.fn.jobstop,
    defer_fn = vim.defer_fn,
  }
  local harness = { jobs = {}, timers = {}, stopped = {}, stdin = {} }
  vim.fn.jobstart = function(_, opts)
    local id = #harness.jobs + 1
    harness.jobs[id] = opts
    return id
  end
  vim.fn.chansend = function(job, value)
    harness.stdin[job] = value
    return #value
  end
  vim.fn.chanclose = function()
    return 1
  end
  vim.fn.jobstop = function(job)
    table.insert(harness.stopped, job)
    return 1
  end
  vim.defer_fn = function(timer_callback, timeout)
    local timer = { callback = timer_callback, timeout = timeout, stopped = false, closing = false }
    function timer:stop()
      self.stopped = true
    end
    function timer:is_closing()
      return self.closing
    end
    function timer:close()
      self.closing = true
    end
    function timer:fire()
      self.callback()
    end
    table.insert(harness.timers, timer)
    return timer
  end
  local ok, failure = xpcall(function()
    callback(harness)
  end, debug.traceback)
  vim.fn.jobstart = saved.jobstart
  vim.fn.chansend = saved.chansend
  vim.fn.chanclose = saved.chanclose
  vim.fn.jobstop = saved.jobstop
  vim.defer_fn = saved.defer_fn
  assert(ok, failure)
end

T["cancel rejects active and future requests while ignoring a late callback"] = function()
  local process_callback
  local killed = 0
  local client = client_with_runner(function(_, _, callback)
    process_callback = callback
    return {
      kill = function()
        killed = killed + 1
      end,
    }
  end)
  local active_error
  client:health():catch(function(err)
    active_error = err
  end)
  client:cancel_requests()
  wait_for(function()
    return active_error
  end)
  eq({ active_error.error_class, active_error.endpoint, killed }, { "transport_closed", "/global/health", 1 })

  process_callback({ code = 0, stdout = '{"healthy":true}__OPENCODE_STATUS__:200' })
  vim.wait(20)
  eq(active_error.error_class, "transport_closed")

  local closed_error
  client:health():catch(function(err)
    closed_error = err
  end)
  wait_for(function()
    return closed_error
  end)
  eq({ closed_error.error_class, closed_error.endpoint }, { "transport_closed", "/global/health" })
end

T["duplicate process callbacks settle a request exactly once"] = function()
  local process_callback
  local client = client_with_runner(function(_, _, callback)
    process_callback = callback
  end)
  local values = {}
  client:health():next(function(value)
    table.insert(values, value.healthy)
  end)
  process_callback({ code = 0, stdout = '{"healthy":"first"}__OPENCODE_STATUS__:200' })
  process_callback({ code = 0, stdout = '{"healthy":"late"}__OPENCODE_STATUS__:200' })
  wait_for(function()
    return values[1]
  end)
  vim.wait(20)
  eq(values, { "first" })
  client:cancel_requests()
end

T["curl exit 28 is reported as a timeout"] = function()
  local process_callback
  local client = client_with_runner(function(_, _, callback)
    process_callback = callback
  end)
  local request_error
  client:health():catch(function(err)
    request_error = err
  end)
  process_callback({ code = 28, stderr = "secret curl output", stdout = "" })
  wait_for(function()
    return request_error
  end)
  eq(request_error, { error_class = "timeout", endpoint = "/global/health" })
  client:cancel_requests()
end

T["malformed SSE JSON stops the stream and surfaces a decode exit"] = function()
  with_sse_harness(function(harness)
    local event, exit
    local client = client_with_runner(function() end)
    client:subscribe(function(value)
      event = value
    end, function(code, error_class)
      exit = { code, error_class }
    end)
    harness.jobs[1].on_stdout(1, vim.fn.readfile(fixture_root .. "/malformed.sse"))
    wait_for(function()
      return exit
    end)
    eq({ event, exit, harness.stopped }, { nil, { 1, "decode" }, { 1 } })
    client:cancel_requests()
  end)
end

T["silent SSE fires the liveness deadline through stream exit recovery"] = function()
  with_sse_harness(function(harness)
    local exit
    local client = client_with_runner(function() end)
    client:subscribe(function() end, function(code, error_class)
      exit = { code, error_class }
    end, { liveness_timeout_ms = 25 })
    eq(harness.timers[1].timeout, 25)
    harness.timers[1]:fire()
    wait_for(function()
      return exit
    end)
    eq({ exit, harness.stopped }, { { 28, "timeout" }, { 1 } })
    client:cancel_requests()
  end)
end

T["SSE activity resets liveness and a stopped deadline cannot exit the stream"] = function()
  with_sse_harness(function(harness)
    local event, exits = nil, 0
    local client = client_with_runner(function() end)
    client:subscribe(function(value)
      event = value
    end, function()
      exits = exits + 1
    end, { liveness_timeout_ms = 25 })
    harness.jobs[1].on_stdout(1, { 'data: {"type":"server.heartbeat","properties":{}}', "" })
    wait_for(function()
      return event
    end)
    eq({ assert(event).type, #harness.timers, harness.timers[1].stopped }, { "server.heartbeat", 2, true })
    harness.timers[1]:fire()
    vim.wait(20)
    eq(exits, 0)
    harness.timers[2]:fire()
    eq(
      vim.wait(200, function()
        return exits == 1
      end),
      true
    )
    client:cancel_requests()
  end)
end

T["replaced SSE generation ignores stale timers and process callbacks"] = function()
  with_sse_harness(function(harness)
    local events, exits = {}, 0
    local client = client_with_runner(function() end)
    client:subscribe(function(value)
      table.insert(events, value.type)
    end, function()
      exits = exits + 1
    end, { liveness_timeout_ms = 25 })
    local stale_timer = harness.timers[1]
    client:subscribe(function(value)
      table.insert(events, value.type)
    end, function()
      exits = exits + 1
    end, { liveness_timeout_ms = 25 })

    stale_timer:fire()
    harness.jobs[1].on_stdout(1, { 'data: {"type":"stale"}', "" })
    harness.jobs[1].on_exit(1, 7)
    harness.jobs[2].on_stdout(2, { 'data: {"type":"current"}', "" })
    wait_for(function()
      return events[1]
    end)
    vim.wait(20)
    eq({ events, exits }, { { "current" }, 0 })
    client:cancel_requests()
  end)
end

return T
