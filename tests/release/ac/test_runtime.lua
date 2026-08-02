---Restores every harness after its case, including cases whose assertions abort before explicit teardown.
local active_harnesses = {}
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      for _, harness in ipairs(active_harnesses) do
        harness.restore()
      end
      active_harnesses = {}
    end,
  },
})
local eq = MiniTest.expect.equality
local Runtime = require("opencode.runtime")
---@diagnostic disable: duplicate-set-field, need-check-nil

local Promise = require("opencode.promise")
local Client = require("opencode.client")
local Session = require("opencode.session")

local function await(promise, timeout)
  local done, value, error = false, nil, nil
  promise
    :next(function(result)
      value, done = result, true
    end)
    :catch(function(reason)
      error, done = reason, true
    end)
  eq(
    vim.wait(timeout or 1500, function()
      return done
    end),
    true
  )
  return value, error
end

local function temp_root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

---Builds a Runtime with fake process, HTTP, config, reconciliation, and sidebar boundaries.
---The fakes retain argv, request order, ownership, and lifecycle facts for outer-boundary assertions.
---Each harness redirects state-backed manifests and logs to a disposable root and verifies teardown.
---@param spec? table
---@return table
local function runtime_harness(spec)
  spec = spec or {}
  local root = spec.root or temp_root()
  local state_root = temp_root()
  local calls = { client = {}, jobs = {}, jobstops = {}, tui = {}, manifests = {}, aborts = {}, selected_sessions = {} }
  local saved_modules, saved_functions = {}, {}
  local live, pid_for_job = {}, {}
  local subscriptions = {}
  local next_job = 100
  local old_startup_timeout = require("opencode.config").opts.runtime.startup_timeout
  local runtime_module = spec.Runtime or Runtime

  local function replace(name, value)
    saved_modules[name] = package.loaded[name] or false
    package.loaded[name] = value
  end

  local ownership
  ownership = {
    identity = function(pid)
      if not live[pid] then
        return nil
      end
      return { pid = pid, start = "start-" .. pid, executable = "/fake/opencode" }
    end,
    verified = function(expected)
      if type(expected) ~= "table" then
        return false, false
      end
      local actual = ownership.identity(expected.pid)
      if not actual then
        return true, false
      end
      return actual.start == expected.start and actual.executable == expected.executable, true
    end,
    signal = function(expected)
      table.insert(calls.jobstops, expected.pid)
      live[expected.pid] = false
      return true
    end,
    write = function(path, manifest)
      calls.manifests[path] = vim.deepcopy(manifest)
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({ vim.json.encode(manifest) }, path)
      vim.fn.setfperm(path, "rw-------")
    end,
    shutdown = function(path)
      if vim.uv.fs_stat(path) then
        vim.uv.fs_unlink(path)
      end
      return true
    end,
    cleanup_stale_manifests = function()
      calls.stale_cleanups = (calls.stale_cleanups or 0) + 1
      if type(spec.cleanup_stale_manifests) == "function" then
        return spec.cleanup_stale_manifests(calls.stale_cleanups)
      end
      return spec.cleanup_stale_manifests == nil and true or spec.cleanup_stale_manifests
    end,
  }

  local function result(value)
    return Promise.resolve(type(value) == "function" and value() or value)
  end

  local client = {
    root = root,
    url = "http://127.0.0.1:49152",
    closed = false,
  }
  function client:health()
    table.insert(calls.client, "health")
    if spec.health_error then
      return Promise.reject(spec.health_error)
    end
    return result(spec.health or { version = "1.17.3" })
  end
  function client:doc()
    table.insert(calls.client, "doc")
    local profile = require("opencode.compat")[spec.version or "1.17.3"]
    local doc = spec.doc
    if doc == nil then
      doc = vim.json.decode(table.concat(vim.fn.readfile(profile.fixture), "\n"))
    end
    return result(doc)
  end
  function client:path()
    table.insert(calls.client, "path")
    return result(spec.path or { directory = root })
  end
  function client:config()
    table.insert(calls.client, "config")
    return result(spec.config or {})
  end
  function client:agents()
    table.insert(calls.client, "agents")
    return result(spec.agents or { { name = "build", mode = "primary" }, { name = "plan", mode = "primary" } })
  end
  function client:subscribe(on_event, on_exit, options)
    table.insert(calls.client, "subscribe")
    local subscription = { on_event = on_event, on_exit = on_exit, options = options, handle = 901 + #subscriptions }
    table.insert(subscriptions, subscription)
    if spec.sse_connected ~= false then
      local connected = function()
        if subscription.on_event then
          subscription.on_event({ type = "server.connected", properties = {} })
        end
      end
      if spec.sse_connected_at == "immediate" then
        connected()
      else
        vim.schedule(connected)
      end
    end
    if spec.sse_exit_before_connected then
      vim.schedule(function()
        if subscription.on_exit then
          subscription.on_exit(spec.sse_exit_code or 1)
        end
      end)
    end
    return subscription.handle
  end
  function client:cancel_requests()
    calls.client_cancelled = true
    self.closed = true
  end
  function client:abort(session_id)
    table.insert(calls.aborts, session_id)
    if spec.abort_error then
      return Promise.reject({ error_class = "http" })
    end
    return Promise.resolve(nil)
  end
  function client:select_session(session_id)
    table.insert(calls.selected_sessions, session_id)
    return Promise.resolve(nil)
  end
  function client:session_status()
    table.insert(calls.client, "session_status")
    return result(spec.session_status or {})
  end
  function client:messages(session_id)
    table.insert(calls.client, "messages:" .. session_id)
    return result(spec.messages or {})
  end
  function client:questions()
    table.insert(calls.client, "questions")
    return result(spec.questions or {})
  end
  function client:permissions()
    table.insert(calls.client, "permissions")
    return result(spec.permissions or {})
  end

  replace("opencode.runtime.ownership", ownership)
  replace("opencode.client", {
    new = function(options)
      calls.client_options = options
      client.root, client.url = options.root, string.format("http://%s:%d", options.host, options.port)
      return client
    end,
  })
  replace("opencode.runtime.config_guard", {
    scan = function()
      return spec.guard ~= false, spec.guard_error
    end,
  })
  replace("opencode.session", {
    availability = Session.availability,
    inventory = function(_, statuses)
      calls.inventory_statuses = vim.deepcopy(statuses)
      return result(spec.inventory or {})
    end,
  })
  if not spec.real_reconcile then
    replace("opencode.runtime.reconcile", {
      run = function(runtime)
        calls.reconciled = true
        return Promise.resolve(runtime)
      end,
    })
  end
  replace("opencode.ui.sidebar", {
    available = function()
      return true
    end,
    new = function(runtime)
      return {
        runtime = runtime,
        show_root = function(_, shown_runtime)
          calls.shown_root = shown_runtime.root
          return true
        end,
        show = function()
          calls.sidebar_shown = true
          return true
        end,
        stop = function()
          calls.sidebar_stopped = true
        end,
        dead = function()
          calls.sidebar_dead = true
        end,
        is_visible = function()
          return false
        end,
        select_session = function(_, session_id)
          table.insert(calls.selected_sessions, session_id)
          return Promise.resolve(nil)
        end,
      }
    end,
  })

  saved_functions.jobstart, saved_functions.jobpid, saved_functions.jobstop, saved_functions.jobwait =
    vim.fn.jobstart, vim.fn.jobpid, vim.fn.jobstop, vim.fn.jobwait
  saved_functions.chanclose = vim.fn.chanclose
  saved_functions.stdpath = vim.fn.stdpath
  vim.fn.stdpath = function(kind)
    if kind == "state" then
      return state_root
    end
    return saved_functions.stdpath(kind)
  end
  vim.fn.jobstart = function(argv, options)
    next_job = next_job + 1
    local job = next_job
    pid_for_job[job] = job
    live[job] = true
    table.insert(calls.jobs, { argv = vim.deepcopy(argv), options = options, job = job })
    return job
  end
  vim.fn.jobpid = function(job)
    return pid_for_job[job] or job
  end
  vim.fn.jobstop = function(job)
    table.insert(calls.jobstops, job)
    live[pid_for_job[job] or job] = false
    return 1
  end
  vim.fn.jobwait = function(jobs)
    local result = {}
    for _, job in ipairs(jobs) do
      result[#result + 1] = live[pid_for_job[job] or job] and -1 or 0
    end
    return result
  end
  if spec.startup_timeout then
    require("opencode.config").opts.runtime.startup_timeout = spec.startup_timeout
  end

  local runtime = spec.runtime or runtime_module.new(root)
  runtime_module.registry[root] = runtime

  local harness = {
    root = root,
    state_root = state_root,
    log_path = state_root .. "/opencode.nvim.log",
    runtime = runtime,
    calls = calls,
    live = live,
    ownership = ownership,
    client = client,
  }
  function harness.emit_sse_event(event)
    local subscription = subscriptions[#subscriptions]
    assert(subscription and subscription.on_event, "SSE is not subscribed")
    subscription.on_event(event)
  end
  function harness.emit_sse_exit(code)
    local subscription = subscriptions[#subscriptions]
    assert(subscription and subscription.on_exit, "SSE is not subscribed")
    subscription.on_exit(code or 1)
  end
  function harness.emit_sse_connected()
    harness.emit_sse_event({ type = "server.connected", properties = {} })
  end
  ---Restores process and module boundaries after the Runtime under test has settled.
  function harness.restore()
    if harness.restored then
      return
    end
    harness.restored = true
    if runtime.state ~= "stopped" then
      runtime:stop()
    end
    require("opencode.config").opts.runtime.startup_timeout = old_startup_timeout
    for name, value in pairs(saved_modules) do
      package.loaded[name] = value or nil
    end
    for name, value in pairs(saved_functions) do
      vim.fn[name] = value
    end
    runtime_module.registry[root] = nil
    if vim.api.nvim_buf_is_valid(runtime.sidebar and runtime.sidebar.buf or -1) then
      vim.api.nvim_buf_delete(runtime.sidebar.buf, { force = true })
    end
    eq(vim.uv.fs_stat(runtime.owner_manifest), nil)
    eq(vim.uv.fs_stat(runtime.temp_root), nil)
    vim.fn.delete(harness.log_path)
    eq(vim.uv.fs_stat(harness.log_path), nil)
    if spec.root == nil then
      vim.fn.delete(root, "rf")
    end
    vim.fn.delete(state_root, "rf")
    eq(vim.uv.fs_stat(state_root), nil)
  end
  table.insert(active_harnesses, harness)
  return harness
end

T["AC-RUN-01 starts one owned root-bound Runtime"] = function()
  local harness = runtime_harness()
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  eq(runtime.state, "ready")
  eq(#harness.calls.jobs, 1)
  eq(harness.calls.jobs[1].argv[1], "opencode")
  eq(harness.calls.jobs[1].argv[2], "serve")
  eq(harness.calls.jobs[1].argv[3], "--hostname")
  eq(harness.calls.jobs[1].argv[4], "127.0.0.1")
  eq(harness.calls.jobs[1].options.cwd, harness.root)
  eq(harness.calls.jobs[1].options.env.OPENCODE_SERVER_PASSWORD, runtime.password)
  eq(harness.calls.tui_starts, nil)
  eq(runtime.tui_live, false)
  eq(runtime.tui_status, "stopped")
  eq(harness.calls.client, { "health", "doc", "path", "config", "agents", "subscribe" })

  local fake_runner, command_calls = require("tests.helpers.fake_opencode").runner({
    { body = { version = "1.17.3" } },
    { body = { paths = {} } },
  })
  local client = Client.new({
    host = "127.0.0.1",
    port = 4242,
    username = "opencode",
    password = "secret-for-test",
    root = harness.root,
    runner = fake_runner,
  })
  await(client:health())
  await(client:doc())
  for _, command in ipairs(command_calls) do
    eq(contains(command, "x-opencode-directory: " .. harness.root), true)
    eq(contains(command, "http://127.0.0.1:4242"), true)
    eq(contains(command, "secret-for-test"), false)
  end
  local old_chansend, old_chanclose = vim.fn.chansend, vim.fn.chanclose
  local sse_config
  vim.fn.chansend = function(_, value)
    sse_config = value
  end
  vim.fn.chanclose = function() end
  client:subscribe(function() end)
  local sse_command = harness.calls.jobs[#harness.calls.jobs].argv
  eq(contains(sse_command, "x-opencode-directory: " .. harness.root), true)
  eq(contains(sse_command, "http://127.0.0.1:4242/event"), true)
  eq(contains(sse_command, "secret-for-test"), false)
  eq(sse_config:find("secret-for-test", 1, true) ~= nil, true)
  vim.fn.chansend, vim.fn.chanclose = old_chansend, old_chanclose
  harness.restore()
end

T["AC-RUN-02 routes requests only to the Runtime-owned endpoint"] = function()
  local harness = runtime_harness()
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  eq(runtime.client.root, harness.root)
  eq(runtime.client.url:match("^http://127%.0%.0%.1:%d+$") ~= nil, true)
  eq(runtime.client.url:find("foreign", 1, true), nil)
  eq(harness.calls.tui, {})
  eq(#harness.calls.jobs, 1)
  harness.restore()
end

T["AC-RUN-03 rejects unsupported health and document contracts before prompts"] = function()
  local cases = {
    { health = { version = "9.9.9" }, expected = "unsupported_version" },
    { doc = {}, expected = "missing_operation:" },
  }
  for _, case in ipairs(cases) do
    local harness = runtime_harness(case)
    local runtime, error = await(harness.runtime:start())
    eq(runtime, nil)
    eq(error.error_class == case.expected or error.error_class:find(case.expected, 1, true) == 1, true)
    eq(harness.runtime.state, "stopped")
    eq(harness.calls.client.prompt_async, nil)
    eq(harness.calls.client[1], "health")
    harness.restore()
  end
end

T["AC-RUN-04 times out owned startup and stops partial processes"] = function()
  local harness = runtime_harness({ startup_timeout = 1, health_error = { error_class = "http" } })
  local runtime, error = await(harness.runtime:start())
  eq(runtime, nil)
  eq(error, { error_class = "startup_timeout" })
  eq(harness.runtime.state, "stopped")
  eq(#harness.calls.jobs, 1)
  eq(contains(harness.calls.jobstops, harness.calls.jobs[1].job), true)
  eq(harness.calls.tui_starts, nil)
  harness.restore()
end

T["AC-RUN-05 keeps roots, sidebars, Jobs, and events isolated"] = function()
  local first, second = temp_root(), temp_root()
  local calls = {}
  local runtime_a, runtime_b = Runtime.new(first), Runtime.new(second)
  runtime_a.state, runtime_b.state = "ready", "ready"
  runtime_a.sidebar = {
    show_root = function()
      calls.first = true
    end,
  }
  runtime_b.sidebar = {
    show_root = function()
      calls.second = true
    end,
  }
  local session_a = { id = "session-a", active_job_key = "session-a:message-a" }
  local session_b = { id = "session-b", active_job_key = "session-b:message-b" }
  local job_a = {
    key = session_a.active_job_key,
    session_id = session_a.id,
    user_message_id = "message-a",
    root = first,
    state = "running",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  local job_b = {
    key = session_b.active_job_key,
    session_id = session_b.id,
    user_message_id = "message-b",
    root = second,
    state = "running",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime_a.sessions[session_a.id], runtime_a.jobs[job_a.key] = session_a, job_a
  runtime_b.sessions[session_b.id], runtime_b.jobs[job_b.key] = session_b, job_b
  Runtime.registry[first], Runtime.registry[second] = runtime_a, runtime_b

  eq(Runtime.show_root(second), runtime_b)
  eq(calls.second, true)
  runtime_a:route_event({
    type = "message.updated",
    properties = {
      info = { sessionID = session_a.id, role = "assistant", parentID = job_a.user_message_id, id = "assistant-a" },
    },
  })
  eq(job_a.assistant_message_ids["assistant-a"], true)
  eq(job_b.assistant_message_ids["assistant-a"], nil)
  eq(job_a.state, "running")
  eq(job_b.state, "running")
  Runtime.registry[first], Runtime.registry[second] = nil, nil
  vim.fn.delete(first, "rf")
  vim.fn.delete(second, "rf")
end

T["AC-RUN-06 stops owned processes, Jobs, temp data, and manifest"] = function()
  local harness = runtime_harness()
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  local session = { id = "session-shutdown", active_job_key = "job-shutdown" }
  local job = { key = "job-shutdown", session_id = session.id, root = harness.root, state = "running", mode = "plan" }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job
  local temporary = runtime.temp_root .. "/proposal.tmp"
  vim.fn.mkdir(runtime.temp_root, "p")
  vim.fn.writefile({ "private" }, temporary)
  eq(vim.uv.fs_stat(runtime.owner_manifest) ~= nil, true)
  eq(runtime.owner_manifest:sub(1, #harness.state_root), harness.state_root)
  eq(vim.uv.fs_stat(harness.log_path) ~= nil, true)
  runtime:stop()
  eq(runtime.state, "stopped")
  eq(job.state, "cancelled")
  eq(vim.uv.fs_stat(temporary), nil)
  eq(vim.uv.fs_stat(runtime.owner_manifest), nil)
  eq(harness.calls.sidebar_stopped, true)
  eq(#harness.calls.jobstops >= 2, true)
  harness.restore()
end

T["AC-RUN-07 cleans stale ownership only after identity and root checks"] = function()
  package.loaded["opencode.runtime.ownership"] = nil
  local ownership = require("opencode.runtime.ownership")
  local root = temp_root()
  local manifest_path = vim.fn.tempname()
  local state = { server = true, tui = true }
  local expected = {
    schema_version = 1,
    root = root,
    root_hash = vim.fn.sha256(root),
    port = 4250,
    username = "opencode",
    password = "password-boundary",
    nonce = "nonce-boundary",
    server = { pid = 701, start = "s701", executable = "/fake/server" },
    tui = { pid = 702, start = "s702", executable = "/fake/tui" },
  }
  ownership.write(manifest_path, expected)
  local original = {
    identity = ownership.identity,
    signal = ownership.signal,
  }
  local signals = {}
  ownership.identity = function(pid)
    if not state[pid == 701 and "server" or "tui"] then
      return nil
    end
    return { pid = pid, start = "s" .. pid, executable = expected[pid == 701 and "server" or "tui"].executable }
  end
  ownership.signal = function(process)
    table.insert(signals, process.pid)
    state[process.pid == 701 and "server" or "tui"] = false
    return true
  end
  local old_system = vim.system
  vim.system = function(command)
    local is_path = command[#command]:match("/path$") ~= nil
    return {
      code = 0,
      stdout = is_path and vim.json.encode({ directory = root }) or vim.json.encode({ healthy = true }),
      wait = function(self)
        return self
      end,
    }
  end
  eq(ownership.cleanup_stale(manifest_path, root), true)
  eq(signals, { 702, 701 })
  eq(vim.uv.fs_stat(manifest_path), nil)

  local mismatch_path = vim.fn.tempname()
  ownership.write(mismatch_path, expected)
  ownership.identity = function(pid)
    return { pid = pid, start = "reused", executable = "/other/process" }
  end
  eq(ownership.cleanup_stale(mismatch_path, root), false)
  eq(vim.uv.fs_stat(mismatch_path) ~= nil, true)

  ownership.identity, ownership.signal = original.identity, original.signal
  vim.system = old_system
  vim.fn.delete(root, "rf")
  vim.uv.fs_unlink(mismatch_path)
end

T["supplemental stale cleanup retries after the blocking problem is corrected"] = function()
  local previous_runtime = package.loaded["opencode.runtime"]
  package.loaded["opencode.runtime"] = nil
  local fresh_runtime = require("opencode.runtime")
  package.loaded["opencode.runtime"] = previous_runtime

  local problem_present = true
  local harness = runtime_harness({
    Runtime = fresh_runtime,
    cleanup_stale_manifests = function()
      return not problem_present
    end,
  })
  local runtime, error = await(harness.runtime:start())
  eq(runtime, nil)
  eq(error, { error_class = "manual_cleanup" })
  eq(harness.calls.stale_cleanups, 1)

  problem_present = false
  local started, start_error = await(harness.runtime:start())
  eq(start_error, nil)
  eq(started.state, "ready")
  eq(harness.calls.stale_cleanups, 2)
  harness.restore()
end

T["AC-RUN-08 TUI loss is independent from Server, SSE, and Job state"] = function()
  local root = temp_root()
  local old_sidebar_module = package.loaded["opencode.ui.sidebar"]
  package.loaded["opencode.ui.sidebar"] = nil
  local Sidebar = require("opencode.ui.sidebar")
  local runtime = Runtime.new(root)
  runtime.state, runtime.sse_live, runtime.tui_live = "ready", true, true
  runtime.tui_status = "live"
  runtime.jobs["session-visible:job"] = { key = "session-visible:job", state = "running" }
  runtime.server_job = 41
  runtime.sidebar = Sidebar.new(runtime)
  runtime.sidebar:dead()
  eq({ runtime.tui_live, runtime.tui_status }, { false, "dead" })
  eq(runtime.server_job, 41)
  eq(runtime.jobs["session-visible:job"].state, "running")
  eq({ runtime.state, runtime.sse_live }, { "ready", true })
  package.loaded["opencode.ui.sidebar"] = old_sidebar_module
  vim.fn.delete(root, "rf")
end

T["AC-RUN-09 ignores plugins and MCPs but blocks custom tools"] = function()
  for _, entry in ipairs({
    { config = { plugin = { custom = {} } }, error_class = "server_spawn", starts = 1 },
    { config = { mcp = { custom = { command = "sensitive-command" } } }, error_class = "server_spawn", starts = 1 },
    { config = { tool = { custom = {} } }, error_class = "custom_tool", starts = 0 },
  }) do
    local root = temp_root()
    local path = root .. "/opencode.json"
    vim.fn.writefile({ vim.json.encode(entry.config) }, path)
    local runtime = Runtime.new(root)
    local old_jobstart = vim.fn.jobstart
    local starts = 0
    vim.fn.jobstart = function()
      starts = starts + 1
      return -1
    end
    Runtime.registry[root] = runtime
    local started, error = await(runtime:start())
    eq(started, nil)
    eq(error.error_class, entry.error_class)
    eq(runtime.state, "stopped")
    eq(starts, entry.starts)
    vim.fn.jobstart = old_jobstart
    Runtime.registry[root] = nil
    vim.fn.delete(root, "rf")
  end

  for _, config in ipairs({
    { plugin = { custom = {} } },
    { mcp = { custom = { command = "sensitive-command" } } },
  }) do
    local harness = runtime_harness({ config = config })
    local runtime, error = await(harness.runtime:start())
    eq(error, nil)
    eq(runtime.state, "ready")
    eq(contains(harness.calls.client, "config"), true)
    eq(contains(harness.calls.client, "subscribe"), true)
    harness.restore()
  end

  local harness = runtime_harness({ config = { tools = { custom = true } } })
  local runtime, error = await(harness.runtime:start())
  eq(runtime, nil)
  eq(error.error_class, "custom_tool")
  eq(contains(harness.calls.client, "subscribe"), false)
  harness.restore()
end

T["AC-EVT-05 disconnects on Server crash and restarts with fail-closed reconciliation"] = function()
  local harness =
    runtime_harness({ real_reconcile = true, inventory = {}, session_status = { crashed = "idle" }, messages = {} })
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  local status_requests = 0
  for _, call in ipairs(harness.calls.client) do
    if call == "session_status" then
      status_requests = status_requests + 1
    end
  end
  eq(status_requests, 1)
  local old_client = runtime.client
  local session = { id = "crashed", active_job_key = "crashed:msg_old" }
  local job = {
    key = session.active_job_key,
    session_id = session.id,
    user_message_id = "msg_old",
    root = harness.root,
    state = "running",
    mode = "plan",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job
  local old_server = runtime.server_job
  runtime:on_server_exit(runtime.server_generation)
  eq(runtime.state, "disconnected")
  eq(runtime.prompt_locked, true)
  eq(runtime.reconciling, true)
  eq(harness.calls.sidebar_dead, true)
  eq(old_client.closed, true)

  local restarted, restart_error = await(runtime:restart())
  eq(restart_error, nil)
  eq(restarted, runtime)
  eq(runtime.state, "ready")
  eq(runtime.prompt_locked, false)
  eq(job.state, "error")
  eq(session.active_job_key, nil)
  eq(runtime.server_job ~= old_server, true)
  eq(harness.calls.tui_starts, nil)
  eq(harness.calls.reconciled, nil)
  status_requests = 0
  for _, call in ipairs(harness.calls.client) do
    if call == "session_status" then
      status_requests = status_requests + 1
    end
  end
  eq(status_requests, 2)
  eq(contains(harness.calls.client, "messages:crashed"), true)
  eq(contains(harness.calls.client, "questions"), true)
  eq(contains(harness.calls.client, "permissions"), true)
  harness.restore()
end

T["startup issues its first health request immediately"] = function()
  local harness = runtime_harness()
  local readiness = harness.runtime:start()
  eq(harness.calls.client[1], "health")
  local runtime, error = await(readiness)
  eq(error, nil)
  eq(runtime.state, "ready")
  harness.restore()
end

T["startup retries a failed health request after the immediate attempt"] = function()
  local attempts = 0
  local harness = runtime_harness({
    health = function()
      attempts = attempts + 1
      if attempts == 1 then
        return Promise.reject({ error_class = "http" })
      end
      return { version = "1.17.3" }
    end,
  })
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  eq(runtime.state, "ready")
  eq(attempts, 2)
  eq({ harness.calls.client[1], harness.calls.client[2] }, { "health", "health" })
  harness.restore()
end

T["startup reuses one session status snapshot for inventory and reconciliation"] = function()
  local startup_status = { startup_session = "idle" }
  local status_requests = 0
  local harness = runtime_harness({
    real_reconcile = true,
    inventory = {},
    session_status = function()
      status_requests = status_requests + 1
      return vim.deepcopy(startup_status)
    end,
  })
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  eq(status_requests, 1)
  eq(harness.calls.inventory_statuses, startup_status)
  eq(runtime.reconcile_statuses, startup_status)
  harness.restore()
end

T["startup readiness waits for server.connected before exposing SSE"] = function()
  local harness = runtime_harness({ sse_connected = false })
  local readiness = harness.runtime:start()
  local settled = false
  readiness
    :next(function()
      settled = true
    end)
    :catch(function()
      settled = true
    end)
  eq(
    vim.wait(50, function()
      return settled
    end),
    false
  )
  eq(
    vim.wait(1000, function()
      return contains(harness.calls.client, "subscribe")
    end),
    true
  )
  eq({ harness.runtime.sse_live, harness.runtime.tui_live }, { false, false })
  harness.emit_sse_connected()
  local runtime, error = await(readiness)
  eq(error, nil)
  eq({ runtime.state, runtime.sse_live, runtime.tui_live, runtime.tui_status }, { "ready", true, false, "stopped" })
  harness.restore()
end

T["startup fails closed when SSE exits before its first connected event"] = function()
  local harness = runtime_harness({ sse_connected = false, sse_exit_before_connected = true })
  local runtime, error = await(harness.runtime:start())
  eq(runtime, nil)
  eq(error, { error_class = "sse_disconnected", status = 1 })
  eq({ harness.runtime.state, harness.runtime.sse_live, harness.runtime.tui_starts }, { "stopped", false, nil })
  harness.restore()
end

T["startup does not attach or wait for the lazy TUI"] = function()
  local harness = runtime_harness()
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
  eq({ runtime.state, runtime.sse_live, runtime.tui_live, runtime.tui_status }, { "ready", true, false, "stopped" })
  eq(harness.calls.tui_starts, nil)
  harness.restore()
end

T["startup requires both primary Build and Plan agents"] = function()
  for _, agents in ipairs({
    { { name = "build", mode = "primary" } },
    { { name = "build", mode = "secondary" }, { name = "plan", mode = "primary" } },
  }) do
    local harness = runtime_harness({ agents = agents })
    local runtime, error = await(harness.runtime:start())
    eq(runtime, nil)
    eq(error, { error_class = "agent_unavailable" })
    eq(harness.runtime.tui_starts, nil)
    harness.restore()
  end
end

T["reconciliation releases a blocked Session omitted from idle status"] = function()
  local harness = runtime_harness({ real_reconcile = true })
  local runtime = harness.runtime
  runtime.state, runtime.sse_live, runtime.client = "ready", true, harness.client
  runtime.prompt_locked, runtime.reconciliation_required, runtime.reconciliation_blocked = true, true, true
  runtime.sessions.ses_blocked = {
    id = "ses_blocked",
    remote_status = "busy",
    availability = "blocked",
    availability_reason = "remote_busy_without_job",
  }

  local reconciled, err = await(require("opencode.runtime.reconcile").run(runtime, runtime.generation, {}))
  eq(err, nil)
  eq(reconciled, runtime)
  eq({ runtime.sessions.ses_blocked.remote_status, runtime.sessions.ses_blocked.availability }, { "idle", "reusable" })
  eq(
    { runtime.prompt_locked, runtime.reconciliation_required, runtime.reconciliation_blocked },
    { false, false, false }
  )
  harness.restore()
end

return T
