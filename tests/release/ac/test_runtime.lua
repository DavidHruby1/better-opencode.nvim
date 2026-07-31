local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local Runtime = require("opencode.runtime")
local Promise = require("opencode.promise")
local Client = require("opencode.client")

local function await(promise, timeout)
  local done, value, error = false, nil, nil
  promise
    :next(function(result)
      value, done = result, true
    end)
    :catch(function(reason)
      error, done = reason, true
    end)
  eq(vim.wait(timeout or 1500, function()
    return done
  end), true)
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
---@param spec? table
---@return table
local function runtime_harness(spec)
  spec = spec or {}
  local root = spec.root or temp_root()
  local calls = { client = {}, jobs = {}, jobstops = {}, tui = {}, manifests = {}, aborts = {}, selected_sessions = {} }
  local saved_modules, saved_functions = {}, {}
  local live, pid_for_job = {}, {}
  local next_job, next_tui = 100, 200
  local old_startup_timeout = require("opencode.config").opts.runtime.startup_timeout

  local function replace(name, value)
    saved_modules[name] = package.loaded[name] or false
    package.loaded[name] = value
  end

  local ownership = {
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
    end,
    shutdown = function(path)
      if vim.uv.fs_stat(path) then
        vim.uv.fs_unlink(path)
      end
      return true
    end,
    cleanup_stale_manifests = function()
      return true
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
    return result(spec.agents or {})
  end
  function client:subscribe()
    table.insert(calls.client, "subscribe")
    return 901
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
    inventory = function()
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
    new = function(runtime)
      local pid = next_tui
      next_tui = next_tui + 1
      live[pid] = true
      pid_for_job[pid] = pid
      local sidebar = {
        job = pid,
        buf = vim.api.nvim_create_buf(false, true),
        show_root = function(_, shown_runtime)
          calls.shown_root = shown_runtime.root
        end,
        show = function()
          calls.sidebar_shown = true
        end,
        stop = function(self)
          calls.sidebar_stopped = true
          if self.job then
            vim.fn.jobstop(self.job)
          end
          if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
            vim.api.nvim_buf_delete(self.buf, { force = true })
          end
          self.job, self.buf = nil, nil
        end,
        dead = function(self)
          calls.sidebar_dead = true
          self.job, self.buf = nil, nil
        end,
        recover = function()
          calls.sidebar_recovered = true
          return Promise.resolve(runtime)
        end,
        is_visible = function()
          return false
        end,
      }
      calls.tui = { runtime = runtime, command = { require("opencode.config").opts.runtime.binary, "attach", client.url, "--dir", root } }
      calls.tui_starts = (calls.tui_starts or 0) + 1
      return sidebar
    end,
  })

  saved_functions.jobstart, saved_functions.jobpid, saved_functions.jobstop = vim.fn.jobstart, vim.fn.jobpid, vim.fn.jobstop
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
  if spec.startup_timeout then
    require("opencode.config").opts.runtime.startup_timeout = spec.startup_timeout
  end

  local runtime = spec.runtime or Runtime.new(root)
  Runtime.registry[root] = runtime

  local harness = {
    root = root,
    runtime = runtime,
    calls = calls,
    live = live,
    ownership = ownership,
  }
  ---Restores process and module boundaries after the Runtime under test has settled.
  function harness.restore()
    require("opencode.config").opts.runtime.startup_timeout = old_startup_timeout
    for name, value in pairs(saved_modules) do
      package.loaded[name] = value or nil
    end
    for name, value in pairs(saved_functions) do
      vim.fn[name] = value
    end
    Runtime.registry[root] = nil
    if vim.api.nvim_buf_is_valid(runtime.sidebar and runtime.sidebar.buf or -1) then
      vim.api.nvim_buf_delete(runtime.sidebar.buf, { force = true })
    end
    if spec.root == nil then
      vim.fn.delete(root, "rf")
    end
  end
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
  eq(harness.calls.tui.command, { "opencode", "attach", runtime.client.url, "--dir", harness.root })
  eq(harness.calls.tui_starts, 1)
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
  eq(harness.calls.tui.command[3], runtime.client.url)
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
  eq(error.error_class, "startup_timeout")
  eq(harness.runtime.state, "stopped")
  eq(#harness.calls.jobs, 1)
  eq(contains(harness.calls.jobstops, harness.calls.jobs[1].job), true)
  eq(harness.calls.tui.runtime, nil)
  harness.restore()
end

T["AC-RUN-05 keeps roots, sidebars, Jobs, and events isolated"] = function()
  local first, second = temp_root(), temp_root()
  local calls = {}
  local runtime_a, runtime_b = Runtime.new(first), Runtime.new(second)
  runtime_a.state, runtime_b.state = "ready", "ready"
  runtime_a.sidebar = { show_root = function() calls.first = true end }
  runtime_b.sidebar = { show_root = function() calls.second = true end }
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
    properties = { info = { sessionID = session_a.id, role = "assistant", parentID = job_a.user_message_id, id = "assistant-a" } },
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

T["AC-RUN-08 recovers TUI without restarting Server or Job"] = function()
  local root = temp_root()
  local runtime = Runtime.new(root)
  runtime.state, runtime.sse_live, runtime.tui_generation = "ready", true, 4
  runtime.username, runtime.password = "opencode", "runtime-secret"
  runtime.port = 4300
  runtime.selected_session_id = "session-visible"
  runtime.sessions[runtime.selected_session_id] = { id = runtime.selected_session_id }
  runtime.jobs["session-visible:job"] = { key = "session-visible:job", state = "running" }
  runtime.server_job = 41
  runtime.sidebar = {
    recover = function()
      runtime.tui_generation = runtime.tui_generation + 1
      runtime.sidebar_command = { "opencode", "attach", "http://127.0.0.1:4300", "--dir", root }
      return runtime.client:select_session(runtime.selected_session_id)
    end,
  }
  local selected
  runtime.client = {
    select_session = function(_, id)
      selected = id
      return Promise.resolve(nil)
    end,
  }
  runtime:handle_tui_exit(4)
  eq(vim.wait(1000, function()
    return selected ~= nil
  end), true)
  eq(runtime.sidebar_command, { "opencode", "attach", "http://127.0.0.1:4300", "--dir", root })
  eq(selected, runtime.selected_session_id)
  eq(runtime.server_job, 41)
  eq(runtime.jobs["session-visible:job"].state, "running")
  eq(runtime.state, "ready")
  vim.fn.delete(root, "rf")
end

T["AC-RUN-09 blocks passive and effective custom extensions"] = function()
  for _, entry in ipairs({
    { config = { plugin = { custom = {} } }, error_class = "custom_plugin" },
    { config = { tool = { custom = {} } }, error_class = "custom_tool" },
    { config = { mcp = { custom = { command = "sensitive-command" } } }, error_class = "enabled_mcp" },
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
    eq(starts, 0)
    vim.fn.jobstart = old_jobstart
    Runtime.registry[root] = nil
    vim.fn.delete(root, "rf")
  end

  local harness = runtime_harness({ config = { tools = { custom = true } } })
  local runtime, error = await(harness.runtime:start())
  eq(runtime, nil)
  eq(error.error_class, "custom_tool")
  eq(harness.calls.client.subscribe, nil)
  eq(harness.calls.client.mcp, nil)
  harness.restore()
end

T["AC-EVT-05 disconnects on Server crash and restarts with fail-closed reconciliation"] = function()
  local harness = runtime_harness({ real_reconcile = true, inventory = {}, session_status = { crashed = "idle" }, messages = {} })
  local runtime, error = await(harness.runtime:start())
  eq(error, nil)
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
  eq(harness.calls.tui_starts, 2)
  eq(harness.calls.reconciled, nil)
  eq(contains(harness.calls.client, "session_status"), true)
  eq(contains(harness.calls.client, "messages:crashed"), true)
  eq(contains(harness.calls.client, "questions"), true)
  eq(contains(harness.calls.client, "permissions"), true)
  harness.restore()
end

return T
