local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local Promise = require("opencode.promise")
local Runtime = require("opencode.runtime")

---Creates a deterministic client double at the HTTP boundary.
---Each declared method records its arguments and returns a resolved Promise unless its value is a callback.
---This keeps the Runtime, Session, Job, and event code real while removing network timing from these acceptance tests.
local function fake_client(methods)
  local client = { calls = {} }
  for name, value in pairs(methods or {}) do
    local method_name, method_value = name, value
    client[method_name] = function(self, ...)
      table.insert(self.calls, { name = method_name, args = { ... } })
      if type(method_value) == "function" then
        return method_value(self, ...)
      end
      return Promise.resolve(vim.deepcopy(method_value))
    end
  end
  return client
end

---Creates a ready Runtime with a small observable sidebar double.
---The fake exposes only the visibility and focus effects used by interaction and Session selection paths.
---Keeping the Runtime registered makes callbacks that carry a root identity use the same public lookup as production.
local function runtime_fixture(root, client)
  local sidebar = {
    visible = true,
    show_calls = 0,
    hide_calls = 0,
    input_locked = true,
    transcript_session = nil,
  }
  function sidebar:is_visible()
    return self.visible
  end
  function sidebar:show()
    self.visible = true
    self.show_calls = self.show_calls + 1
    if self.runtime then
      self.transcript_session = self.runtime.selected_session_id
    end
  end
  function sidebar:hide()
    self.visible = false
    self.hide_calls = self.hide_calls + 1
  end
  function sidebar:show_root(runtime)
    self.transcript_session = runtime.selected_session_id
    self:show()
  end

  local runtime = Runtime.new(root)
  runtime.state, runtime.sse_live, runtime.client, runtime.sidebar = "ready", true, client, sidebar
  sidebar.runtime = runtime
  Runtime.registry[root] = runtime
  Runtime.active_root = root
  return runtime
end

---Clears global Runtime and interaction state left by one isolated acceptance case.
---The registries are reset explicitly because MiniTest runs all functions in one Neovim process.
local function clear_fixture(runtime)
  if runtime and Runtime.registry[runtime.root] == runtime then
    Runtime.registry[runtime.root] = nil
  end
  if runtime and Runtime.active_root == runtime.root then
    Runtime.active_root = nil
  end
  local interaction = require("opencode.interaction")
  interaction.queue, interaction.current, interaction.remote, interaction.sequence = {}, nil, {}, 0
end

local function reset_globals()
  for root in pairs(Runtime.registry) do
    Runtime.registry[root] = nil
  end
  Runtime.active_root = nil
  local interaction = require("opencode.interaction")
  interaction.queue, interaction.current, interaction.remote, interaction.sequence = {}, nil, {}, 0
end

---Waits for the repository Promise callbacks and returns either its value or rejection.
---Promises schedule callbacks on Neovim's main loop, so the bounded wait keeps assertions independent of callback speed.
local function settle(promise)
  local done, value, error = false, nil, nil
  promise
    :next(function(result)
      done, value = true, result
    end)
    :catch(function(reason)
      done, error = true, reason
    end)
  eq(
    vim.wait(1000, function()
      return done
    end),
    true
  )
  return value, error
end

---Temporarily replaces the native dialog module with a UI boundary recorder.
---The queue still runs its real identity, ordering, and lock logic; only rendering is held at the edge.
local function fake_dialog()
  local old = package.loaded["opencode.ui.dialog"]
  local shown = {}
  package.loaded["opencode.ui.dialog"] = {
    show = function(request)
      table.insert(shown, request)
    end,
  }
  return shown, function()
    package.loaded["opencode.ui.dialog"] = old
  end
end

T["AC-JOB-01 active Session rejects follow-up instead of queueing a Job"] = function()
  local prompt = require("opencode.api.prompt")
  local root = "/acceptance/job-01"
  local client = fake_client()
  local runtime = runtime_fixture(root, client)
  local session = { id = "ses_busy", active_job_key = "job_busy", remote_status = "idle" }
  local job = { key = "job_busy", session_id = session.id, state = "pending_apply", mode = "build" }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job
  runtime.selected_session_id = session.id
  local path = vim.fn.tempname()
  vim.fn.writefile({ "return 1" }, path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "return 1" })
  vim.api.nvim_buf_set_name(buf, path)
  local context = {
    runtime = runtime,
    buf = buf,
    path = path,
    referenced_buffers = {},
    render = function()
      return { plaintext = "follow up" }
    end,
  }

  for _, state in ipairs({ "pending_apply", "conflict" }) do
    job.state = state
    local _, error = settle(prompt.prompt("follow up", context, { mode = "build" }))
    eq(error.error_class, "session_active", state)
    eq(error.action, "create_new_session", state)
  end
  eq(#client.calls, 0)
  eq(vim.tbl_count(runtime.jobs), 1)

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.uv.fs_unlink(path)
  clear_fixture(runtime)
end

T["AC-JOB-02 picker switches the exact transcript without cross-Session events"] = function()
  local sessions = require("opencode.session")
  local select_session = require("opencode.ui.select_session")
  local events = require("opencode.events")
  local root = "/acceptance/job-02"
  local client = fake_client({
    list_sessions = {
      { id = "ses_first", directory = root, metadata = sessions.metadata(vim.fn.sha256(root)) },
      { id = "ses_second", directory = root, metadata = sessions.metadata(vim.fn.sha256(root)) },
    },
    session_status = { ses_first = "idle", ses_second = "idle" },
    get_session = function(_, id)
      return Promise.resolve({
        id = id,
        directory = root,
        title = id == "ses_first" and "First transcript" or "Second transcript",
        metadata = sessions.metadata(vim.fn.sha256(root)),
      })
    end,
    select_session = function(_, id)
      return Promise.resolve({ selected = id })
    end,
  })
  local runtime = runtime_fixture(root, client)
  local old_select = vim.ui.select
  local picker_items
  vim.ui.select = function(items, _, callback)
    picker_items = items
    callback(items[2])
  end

  select_session.show(runtime)
  eq(
    vim.wait(1000, function()
      return runtime.selected_session_id == "ses_second"
    end),
    true
  )
  eq(#picker_items, 2)
  eq(runtime.selected_session_id, "ses_second")
  eq(runtime.sidebar.transcript_session, "ses_second")
  eq(client.calls[#client.calls].name, "select_session")
  eq(client.calls[#client.calls].args, { "ses_second" })

  local first_job = {
    key = "ses_first:msg_first",
    session_id = "ses_first",
    user_message_id = "msg_first",
    state = "running",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  local second_job = {
    key = "ses_second:msg_second",
    session_id = "ses_second",
    user_message_id = "msg_second",
    state = "running",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime.jobs[first_job.key], runtime.jobs[second_job.key] = first_job, second_job
  runtime.sessions.ses_first.active_job_key, runtime.sessions.ses_second.active_job_key = first_job.key, second_job.key
  events.route(runtime, {
    type = "message.updated",
    properties = {
      info = { id = "assistant_first", role = "assistant", sessionID = "ses_first", parentID = "msg_first" },
    },
  })
  eq(runtime.assistant_jobs["ses_first:assistant_first"], first_job.key)
  eq(second_job.assistant_message_ids.assistant_first, nil)
  eq(runtime.selected_session_id, "ses_second")

  vim.ui.select = old_select
  clear_fixture(runtime)
end

T["session picker reports a failed TUI selection instead of swallowing it"] = function()
  local sessions = require("opencode.session")
  local root = "/acceptance/job-02-select-failure"
  local metadata = sessions.metadata(vim.fn.sha256(root))
  local client = fake_client({
    list_sessions = { { id = "ses_select_failure", directory = root, metadata = metadata } },
    session_status = { ses_select_failure = "idle" },
    get_session = {
      id = "ses_select_failure",
      directory = root,
      title = "Selection failure",
      metadata = metadata,
    },
    select_session = function()
      return Promise.reject({ error_class = "http" })
    end,
  })
  local runtime = runtime_fixture(root, client)
  local old_select, old_notify = vim.ui.select, vim.notify
  local notifications = {}
  vim.notify = function(message)
    table.insert(notifications, message)
  end
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  require("opencode.ui.select_session").show(runtime)
  eq(
    vim.wait(500, function()
      return #notifications > 0
    end),
    true
  )
  eq(notifications[1]:find("session_select", 1, true) ~= nil, true)
  eq(runtime.selected_session_id, nil)
  vim.ui.select, vim.notify = old_select, old_notify
  clear_fixture(runtime)
end

T["AC-JOB-04 cancel removes one Job locally while the other continues"] = function()
  local interaction = require("opencode.interaction")
  local jobs = require("opencode.job")
  local shown, restore_dialog = fake_dialog()
  local root = "/acceptance/job-04"
  local client = fake_client({
    abort = function(_, id)
      return Promise.resolve({ aborted = id })
    end,
  })
  local runtime = runtime_fixture(root, client)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
  local a_scope = { kind = "range", start_byte = 0, end_byte = 5 }
  local b_scope = { kind = "range", start_byte = 6, end_byte = 10 }
  local a = {
    key = "job_a",
    root = root,
    session_id = "ses_a",
    state = "running",
    buffer = buf,
    scope = a_scope,
    marks = require("opencode.scope").create_marks(buf, a_scope),
    proposal = { replacement = "A" },
    merge_key = root .. ":job_a",
  }
  local b = {
    key = "job_b",
    root = root,
    session_id = "ses_b",
    state = "running",
    buffer = buf,
    scope = b_scope,
    marks = require("opencode.scope").create_marks(buf, b_scope),
  }
  runtime.sessions.ses_a, runtime.sessions.ses_b =
    { id = "ses_a", active_job_key = a.key }, { id = "ses_b", active_job_key = b.key }
  runtime.jobs[a.key], runtime.jobs[b.key] = a, b
  local request_a = interaction.enqueue({ root = root, session_id = "ses_a", job_key = a.key, kind = "agent_conflict" })
  interaction.enqueue({ root = root, session_id = "ses_b", job_key = b.key, kind = "agent_conflict" })
  interaction.advance()
  eq(shown[1].job_key, a.key)

  local report = settle(jobs.cancel(runtime, a.key))
  eq(report.cancelled, 1)
  eq({ a.state, b.state }, { "cancelled", "running" })
  eq({ runtime.sessions.ses_a.active_job_key, runtime.sessions.ses_b.active_job_key }, { nil, b.key })
  eq({ a.proposal, a.marks }, { nil, nil })
  eq(interaction.current and interaction.current.job_key, b.key)
  eq(interaction.queue, {})
  eq(client.calls[1].args, { "ses_a" })
  eq(request_a.state, "closed")

  restore_dialog()
  vim.api.nvim_buf_delete(buf, { force = true })
  clear_fixture(runtime)
end

T["AC-JOB-05 cancel all snapshots every Runtime despite one abort failure"] = function()
  reset_globals()
  local jobs = require("opencode.job")
  local root_a, root_b = "/acceptance/job-05-a", "/acceptance/job-05-b"
  local client_a = fake_client({
    abort = function()
      return Promise.reject({ error_class = "http" })
    end,
  })
  local client_b = fake_client({
    abort = function()
      return Promise.resolve({})
    end,
  })
  local runtime_a, runtime_b = runtime_fixture(root_a, client_a), runtime_fixture(root_b, client_b)
  local a = { key = "job_a", root = root_a, session_id = "ses_a", state = "running", proposal = { value = "a" } }
  local b = { key = "job_b", root = root_b, session_id = "ses_b", state = "pending_apply", proposal = { value = "b" } }
  runtime_a.jobs[a.key], runtime_b.jobs[b.key] = a, b
  runtime_a.sessions.ses_a, runtime_b.sessions.ses_b =
    { id = "ses_a", active_job_key = a.key }, { id = "ses_b", active_job_key = b.key }

  local report = settle(Runtime.cancel_all())
  eq(report, { requested = 2, cancelled = 2, abort_failed = 1 })
  eq({ a.state, b.state }, { "cancelled", "cancelled" })
  eq({ a.proposal, b.proposal }, { nil, nil })
  eq({ runtime_a.sessions.ses_a.active_job_key, runtime_b.sessions.ses_b.active_job_key }, { nil, nil })
  eq(#client_a.calls, 1)
  eq(#client_b.calls, 1)

  clear_fixture(runtime_a)
  clear_fixture(runtime_b)
end

T["AC-JOB-06 picker retains only owned Sessions and revalidates before reuse"] = function()
  local sessions = require("opencode.session")
  local select_session = require("opencode.ui.select_session")
  local root = "/acceptance/job-06"
  local root_hash = vim.fn.sha256(root)
  local owned_metadata = sessions.metadata(root_hash)
  local client = fake_client({
    list_sessions = {
      { id = "ses_owned", directory = root, metadata = vim.deepcopy(owned_metadata) },
      { id = "ses_foreign", directory = root, metadata = { client = "other" } },
      { id = "ses_archived", directory = root, metadata = vim.deepcopy(owned_metadata), archivedAt = 1 },
    },
    session_status = { ses_owned = "idle" },
    get_session = function(_, id)
      return Promise.resolve({
        id = id,
        directory = root,
        title = "Owned reusable",
        metadata = vim.deepcopy(owned_metadata),
        permission = vim.deepcopy(sessions.permissions),
      })
    end,
    update_session = function(_, id, body)
      return Promise.resolve({ id = id, body = body })
    end,
    select_session = function(_, id)
      return Promise.resolve({ id = id })
    end,
  })
  local runtime = runtime_fixture(root, client)
  local old_select = vim.ui.select
  local offered
  vim.ui.select = function(items, _, callback)
    offered = items
    callback(items[1])
  end
  select_session.show(runtime)
  eq(
    vim.wait(1000, function()
      return runtime.selected_session_id == "ses_owned"
    end),
    true
  )
  eq(#offered, 1)
  eq(offered[1].id, "ses_owned")

  local detail, error = settle(sessions.revalidate(runtime, "ses_owned", "build"))
  eq(error, nil)
  eq(detail.id, "ses_owned")
  local update
  for _, call in ipairs(client.calls) do
    if call.name == "update_session" then
      update = call
    end
  end
  eq(update.args[1], "ses_owned")
  eq(
    update.args[2].metadata,
    { client = "opencode.nvim-inline", contract_version = 2, root_hash = root_hash, last_mode = "build" }
  )
  eq(update.args[2].permission, sessions.permissions)

  vim.ui.select = old_select
  clear_fixture(runtime)
end

T["AC-JOB-07 sidebar stays input-locked and rejects focus actions"] = function()
  local Sidebar = require("opencode.ui.sidebar")
  local root = "/acceptance/job-07"
  local runtime = Runtime.new(root)
  runtime.client = { url = "http://127.0.0.1:4321" }
  runtime.username, runtime.password, runtime.tui_generation = "opencode", "secret", 1
  local old_jobstart = vim.fn.jobstart
  local jobstart_calls = {}
  vim.fn.jobstart = function(command, opts)
    table.insert(jobstart_calls, { command = command, opts = opts })
    return 77
  end
  local source = vim.api.nvim_get_current_win()
  local sidebar = assert(Sidebar.new(runtime))
  local buf = sidebar.buf
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local locked = {}
  for _, map in ipairs(maps) do
    locked[map.lhs] = map
  end
  local lock_autocmds = vim.api.nvim_get_autocmds({ group = "OpencodeSidebar" .. buf, buffer = buf })
  eq(jobstart_calls[1].command, { "opencode", "attach", runtime.client.url, "--dir", root })
  for _, key in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    eq(locked[key] ~= nil, true, key)
    eq(locked[key].rhs == "" or locked[key].rhs == "<Nop>", true, key)
  end
  eq(#lock_autocmds, 3)
  runtime.interaction_locked = true
  sidebar:focus()
  sidebar:toggle()
  eq(vim.api.nvim_get_current_win(), source)
  eq(sidebar:is_visible(), false)

  vim.fn.jobstart = old_jobstart
  sidebar:stop()
end

T["AC-EVT-01 Runtime routes assistant parts by exact Session and Message identity"] = function()
  local root = "/acceptance/evt-01"
  local runtime = runtime_fixture(root, fake_client())
  local old_job = {
    key = "ses_shared:msg_old",
    root = root,
    session_id = "ses_shared",
    user_message_id = "msg_old",
    state = "completed",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  local current_job = {
    key = "ses_shared:msg_current",
    root = root,
    session_id = "ses_shared",
    user_message_id = "msg_current",
    state = "running",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime.jobs[old_job.key], runtime.jobs[current_job.key] = old_job, current_job
  runtime.sessions.ses_shared = { id = "ses_shared", active_job_key = current_job.key }
  runtime:route_event({
    type = "message.updated",
    properties = {
      info = { id = "msg_old", role = "user", sessionID = "ses_shared" },
    },
  })
  runtime:route_event({
    type = "message.updated",
    properties = {
      info = { id = "assistant_old", role = "assistant", sessionID = "ses_shared", parentID = "msg_old" },
    },
  })
  runtime:route_event({
    type = "message.updated",
    properties = {
      info = { id = "assistant_current", role = "assistant", sessionID = "ses_shared", parentID = "msg_current" },
    },
  })
  runtime:route_event({
    type = "message.part.updated",
    properties = { part = { sessionID = "ses_shared", messageID = "assistant_current", text = "current" } },
  })
  runtime:route_event({
    type = "message.part.updated",
    properties = { part = { sessionID = "ses_shared", messageID = "assistant_old" } },
  })
  eq(runtime.assistant_jobs["ses_shared:assistant_current"], current_job.key)
  eq(current_job.assistant_message_ids.assistant_current, true)
  eq(old_job.late_event_count, 3)
  eq(current_job.late_event_count, nil)
  eq(current_job.state, "running")
  eq(current_job.assistant_message_ids.assistant_old, nil)
  clear_fixture(runtime)
end

T["AC-EVT-02 requests without messageID use the only active Job and fail closed otherwise"] = function()
  local events = require("opencode.events")
  local root = "/acceptance/evt-02"
  local client = fake_client()
  local runtime = runtime_fixture(root, client)
  local job = { key = "job_only", root = root, session_id = "ses_only", state = "running" }
  local session = { id = "ses_only", active_job_key = job.key }
  runtime.jobs[job.key], runtime.sessions[session.id] = job, session
  events.route(
    runtime,
    { type = "question.asked", properties = { sessionID = session.id, requestID = "question-1", questions = {} } }
  )
  eq({ job.state, job.waiting_kind, job.waiting_request_id }, { "waiting_user", "question", "question-1" })
  eq(require("opencode.interaction").queue[1].job_key, job.key)
  local permission = { key = "job_permission", root = root, session_id = "ses_permission", state = "running" }
  runtime.jobs[permission.key], runtime.sessions[permission.session_id] =
    permission, {
      id = permission.session_id,
      active_job_key = permission.key,
    }
  events.route(runtime, {
    type = "permission.asked",
    properties = { sessionID = permission.session_id, requestID = "permission-1", permission = "webfetch" },
  })
  eq(
    { permission.state, permission.waiting_kind, permission.waiting_request_id },
    { "waiting_user", "permission", "permission-1" }
  )

  clear_fixture(runtime)
  local orphan = runtime_fixture(root .. "-orphan", fake_client())
  local reconciliation_calls = 0
  function orphan:begin_reconciliation()
    reconciliation_calls = reconciliation_calls + 1
  end
  events.route(orphan, {
    type = "permission.asked",
    properties = { sessionID = "ses_missing", requestID = "permission-1", permission = "read" },
  })
  eq({ orphan.prompt_locked, orphan.reconciliation_required, reconciliation_calls }, { true, true, 1 })
  eq(#require("opencode.interaction").queue, 0)
  clear_fixture(orphan)
end

T["AC-EVT-03 reconnect reconciles one exact completed structured result before prompts reopen"] = function()
  local root = "/acceptance/evt-03"
  local base_text = "one"
  local calls = {}
  local client = fake_client({
    subscribe = function()
      table.insert(calls, "subscribe")
      return 41
    end,
    session_status = function()
      table.insert(calls, "status")
      return Promise.resolve({ ses_reconnect = "idle" })
    end,
    messages = function()
      table.insert(calls, "messages")
      return Promise.resolve({
        {
          info = {
            id = "assistant_reconnect",
            role = "assistant",
            sessionID = "ses_reconnect",
            parentID = "msg_reconnect",
            structured = {
              version = 1,
              path = "file.lua",
              base_sha256 = vim.fn.sha256(base_text),
              scope = { start_byte = 0, end_byte = #base_text },
              replacement = "two",
              summary = "replace",
            },
          },
        },
      })
    end,
    questions = function()
      table.insert(calls, "questions")
      return Promise.resolve({})
    end,
    permissions = function()
      table.insert(calls, "permissions")
      return Promise.resolve({})
    end,
  })
  local runtime = runtime_fixture(root, client)
  runtime.state, runtime.sse_live = "disconnected", false
  local session = { id = "ses_reconnect", active_job_key = "job_reconnect" }
  local job = {
    key = "job_reconnect",
    root = root,
    session_id = session.id,
    user_message_id = "msg_reconnect",
    state = "running",
    mode = "build",
    auto_apply = false,
    base = { text = base_text, sha256 = vim.fn.sha256(base_text) },
    path = root .. "/file.lua",
    scope = { start_byte = 0, end_byte = #base_text },
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job

  local _, error = settle(runtime:connect_sse())
  eq(error, nil)
  eq(runtime.state, "ready")
  eq(runtime.prompt_locked, false)
  eq(job.state, "pending_apply")
  eq(job.completion_count, 1)
  eq(job.proposal.replacement, "two")
  eq(calls, { "subscribe", "status", "messages", "questions", "permissions" })
  clear_fixture(runtime)
end

T["AC-EVT-04 idle reconnect without an exact result ends the Job without applying"] = function()
  local root = "/acceptance/evt-04"
  local calls = {}
  local client = fake_client({
    subscribe = function()
      return 42
    end,
    session_status = function()
      table.insert(calls, "status")
      return Promise.resolve({ ses_missing_result = "idle" })
    end,
    messages = function()
      table.insert(calls, "messages")
      return Promise.resolve({
        {
          info = {
            id = "assistant_other",
            role = "assistant",
            sessionID = "ses_missing_result",
            parentID = "msg_other",
          },
        },
      })
    end,
    questions = function()
      table.insert(calls, "questions")
      return Promise.resolve({})
    end,
    permissions = function()
      table.insert(calls, "permissions")
      return Promise.resolve({})
    end,
  })
  local runtime = runtime_fixture(root, client)
  runtime.state, runtime.sse_live = "disconnected", false
  local session = { id = "ses_missing_result", active_job_key = "job_missing_result" }
  local job = {
    key = session.active_job_key,
    root = root,
    session_id = session.id,
    user_message_id = "msg_missing_result",
    state = "running",
    mode = "plan",
    assistant_message_ids = {},
    assistant_messages = {},
  }
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job

  local _, error = settle(runtime:connect_sse())
  eq(error, nil)
  eq({ job.state, job.error_class, session.active_job_key }, { "error", "missing_result", nil })
  eq(job.proposal, nil)
  eq(runtime.prompt_locked, false)
  eq(calls, { "status", "messages", "questions", "permissions" })
  clear_fixture(runtime)
end

T["AC-INT-01 question reply targets one request and resumes only its Job"] = function()
  local events = require("opencode.events")
  local root = "/acceptance/int-01"
  local replies = {}
  local client = fake_client({
    question_reply = function(_, id, answers)
      table.insert(replies, { id = id, answers = answers })
      return Promise.resolve({})
    end,
  })
  local runtime = runtime_fixture(root, client)
  local job = { key = "job_b", root = root, session_id = "ses_b", state = "running" }
  local other = { key = "job_a", root = root, session_id = "ses_a", state = "waiting_user", waiting_kind = "question" }
  runtime.jobs[job.key], runtime.jobs[other.key] = job, other
  runtime.sessions.ses_b, runtime.sessions.ses_a =
    { id = "ses_b", active_job_key = job.key }, { id = "ses_a", active_job_key = other.key }
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  events.route(runtime, {
    type = "question.asked",
    properties = {
      sessionID = "ses_b",
      requestID = "req_b",
      questions = { { question = "Continue?", options = { { label = "yes" } } } },
    },
  })
  local interaction = require("opencode.interaction")
  interaction.advance()
  eq(
    vim.wait(1000, function()
      return #replies == 1
    end),
    true
  )
  eq(replies[1], { id = "req_b", answers = { { "yes" } } })
  eq(job.state, "waiting_user")
  events.route(runtime, { type = "question.replied", properties = { sessionID = "ses_b", requestID = "req_b" } })
  eq({ job.state, other.state, interaction.current }, { "running", "waiting_user", nil })
  eq(runtime.confirmed_requests[job.key .. ":req_b"], runtime.generation)
  vim.ui.select = old_select
  clear_fixture(runtime)
end

T["AC-INT-02 permission UI exposes supported actions and hard-denies write capability"] = function()
  local events = require("opencode.events")
  local root = "/acceptance/int-02"
  local replies = {}
  local client = fake_client({
    permission_reply = function(_, id, response)
      table.insert(replies, { id = id, response = response })
      return Promise.resolve({})
    end,
  })
  local runtime = runtime_fixture(root, client)
  local normal = { key = "job_normal", root = root, session_id = "ses_normal", state = "running" }
  runtime.jobs[normal.key], runtime.sessions.ses_normal = normal, { id = "ses_normal", active_job_key = normal.key }
  local old_select, old_notify = vim.ui.select, vim.notify
  local presented
  vim.notify = function() end
  vim.ui.select = function(items, opts, callback)
    presented = { items = items, prompt = opts.prompt }
    callback("once")
  end
  events.route(runtime, {
    type = "permission.asked",
    properties = { sessionID = "ses_normal", requestID = "permission_read", permission = "webfetch" },
  })
  require("opencode.interaction").advance()
  eq(
    vim.wait(1000, function()
      return presented ~= nil
    end),
    true
  )
  eq(presented.items, { "once", "always", "reject" })
  eq(presented.prompt:find("acceptance", 1, true) ~= nil, true)
  eq(presented.prompt:find("s_normal", 1, true) ~= nil, true)
  eq(replies[1], { id = "permission_read", response = "once" })

  clear_fixture(runtime)
  local denied_client = fake_client({
    permission_reply = function(_, id, response)
      table.insert(replies, { id = id, response = response })
      return Promise.resolve({})
    end,
  })
  local denied_runtime = runtime_fixture(root .. "-deny", denied_client)
  local denied = { key = "job_denied", root = denied_runtime.root, session_id = "ses_denied", state = "running" }
  denied_runtime.jobs[denied.key], denied_runtime.sessions.ses_denied =
    denied, { id = "ses_denied", active_job_key = denied.key }
  events.route(denied_runtime, {
    type = "permission.asked",
    properties = { sessionID = "ses_denied", requestID = "permission_edit", permission = "edit" },
  })
  eq(
    { denied.state, denied.error_class, denied_runtime.prompt_locked, denied_runtime.reconciliation_required },
    { "error", "hard_denied_permission", true, true }
  )
  eq(replies[#replies], { id = "permission_edit", response = "reject" })
  eq(require("opencode.interaction").queue, {})

  vim.ui.select, vim.notify = old_select, old_notify
  clear_fixture(denied_runtime)
end

T["hard-deny reply failure is caught, visible, and remains fail-closed"] = function()
  local events = require("opencode.events")
  local messages, reconciliation_calls = {}, 0
  local old_notify = vim.notify
  vim.notify = function(message)
    table.insert(messages, message)
  end
  local root = "/acceptance/int-02-reply-failure"
  local runtime = runtime_fixture(
    root,
    fake_client({
      permission_reply = function()
        return Promise.reject({ error_class = "http" })
      end,
    })
  )
  function runtime:begin_reconciliation()
    reconciliation_calls = reconciliation_calls + 1
  end
  local job = { key = "job_hard_deny", root = root, session_id = "ses_hard_deny", state = "running" }
  runtime.jobs[job.key], runtime.sessions[job.session_id] = job, { id = job.session_id, active_job_key = job.key }
  events.route(runtime, {
    type = "permission.asked",
    properties = { sessionID = job.session_id, requestID = "permission_edit", permission = "edit" },
  })
  eq(
    vim.wait(500, function()
      return #messages > 0 and reconciliation_calls == 1
    end),
    true
  )
  eq(
    { job.state, job.error_class, runtime.prompt_locked, runtime.reconciliation_required, reconciliation_calls },
    { "error", "hard_denied_permission", true, true, 1 }
  )
  eq(messages[1]:find("interaction_failed", 1, true) ~= nil, true)
  vim.notify = old_notify
  clear_fixture(runtime)
end

T["AC-INT-03 dialogs remain FIFO while waiting Jobs and conflicts keep their states"] = function()
  reset_globals()
  local events = require("opencode.events")
  local root = "/acceptance/int-03"
  local replies = {}
  local runtime = runtime_fixture(
    root,
    fake_client({
      question_reject = function(_, id)
        table.insert(replies, { name = "question_reject", id = id })
        return Promise.resolve({})
      end,
      permission_reply = function(_, id, response)
        table.insert(replies, { name = "permission_reply", id = id, response = response })
        return Promise.resolve({})
      end,
    })
  )
  local question = { key = "job_question", root = root, session_id = "ses_question", state = "running" }
  local permission = { key = "job_permission", root = root, session_id = "ses_permission", state = "running" }
  local conflict = { key = "job_conflict", root = root, session_id = "ses_conflict", state = "conflict" }
  runtime.jobs[question.key], runtime.jobs[permission.key], runtime.jobs[conflict.key] = question, permission, conflict
  runtime.sessions.ses_question = { id = "ses_question", active_job_key = question.key }
  runtime.sessions.ses_permission = { id = "ses_permission", active_job_key = permission.key }
  runtime.sessions.ses_conflict = { id = "ses_conflict", active_job_key = conflict.key }
  local old_select = vim.ui.select
  local select_count, conflict_callback = 0, nil
  vim.ui.select = function(_, _, callback)
    select_count = select_count + 1
    if select_count < 3 then
      callback(nil)
    else
      conflict_callback = callback
    end
  end
  events.route(runtime, {
    type = "question.asked",
    properties = { sessionID = "ses_question", requestID = "q", questions = { { options = { { label = "yes" } } } } },
  })
  events.route(runtime, {
    type = "permission.asked",
    properties = { sessionID = "ses_permission", requestID = "p", permission = "webfetch" },
  })
  require("opencode.interaction").enqueue({
    root = root,
    session_id = "ses_conflict",
    job_key = conflict.key,
    kind = "agent_conflict",
  })
  local interaction = require("opencode.interaction")
  interaction.advance()
  eq(
    { interaction.current.job_key, interaction.queue[1].job_key, interaction.queue[2].job_key },
    { question.key, permission.key, conflict.key }
  )
  eq({ question.state, permission.state, conflict.state }, { "waiting_user", "waiting_user", "conflict" })
  events.route(runtime, { type = "question.rejected", properties = { sessionID = "ses_question", requestID = "q" } })
  eq(
    vim.wait(1000, function()
      return interaction.current and interaction.current.job_key == permission.key
    end),
    true
  )
  eq(replies[1], { name = "question_reject", id = "q" })
  eq(interaction.current.job_key, permission.key)
  eq(interaction.queue[1].job_key, conflict.key)
  events.route(
    runtime,
    { type = "permission.rejected", properties = { sessionID = "ses_permission", requestID = "p" } }
  )
  eq(
    vim.wait(1000, function()
      return interaction.current and interaction.current.job_key == conflict.key and conflict_callback ~= nil
    end),
    true
  )
  eq(replies[2], { name = "permission_reply", id = "p", response = "reject" })
  eq(interaction.current.job_key, conflict.key)
  eq(interaction.queue, {})
  conflict_callback(nil)
  eq(conflict.state, "cancelled")
  eq(interaction.current, nil)
  vim.ui.select = old_select
  clear_fixture(runtime)
end

T["AC-INT-04 canonical reply restores sidebar visibility without unlocking TUI input"] = function()
  local events = require("opencode.events")
  local root = "/acceptance/int-04"
  local replies = {}
  local client = fake_client({
    question_reply = function(_, id, answers)
      table.insert(replies, { id = id, answers = answers })
      return Promise.resolve({})
    end,
  })
  local runtime = runtime_fixture(root, client)
  local job = { key = "job_interaction", root = root, session_id = "ses_interaction", state = "running" }
  runtime.jobs[job.key], runtime.sessions[job.session_id] = job, { id = job.session_id, active_job_key = job.key }
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  events.route(runtime, {
    type = "question.asked",
    properties = {
      sessionID = job.session_id,
      requestID = "req_once",
      questions = { { options = { { label = "yes" } } } },
    },
  })
  local interaction = require("opencode.interaction")
  interaction.advance()
  eq(
    vim.wait(1000, function()
      return #replies == 1
    end),
    true
  )
  eq(
    { runtime.interaction_locked, runtime.prompt_locked, runtime.sidebar.visible, runtime.sidebar.hide_calls },
    { true, true, false, 1 }
  )
  eq(runtime.sidebar.input_locked, true)
  eq(replies, { { id = "req_once", answers = { { "yes" } } } })
  events.route(
    runtime,
    { type = "question.replied", properties = { sessionID = job.session_id, requestID = "req_once" } }
  )
  eq(
    { runtime.interaction_locked, runtime.prompt_locked, runtime.sidebar.visible, runtime.sidebar.show_calls },
    { false, false, true, 1 }
  )
  eq(job.state, "running")
  vim.ui.select = old_select
  clear_fixture(runtime)
end

T["AC-STATE-01 Job transition matrix accepts only declared transitions and required kinds"] = function()
  local jobs = require("opencode.job")
  local states =
    { "running", "waiting_user", "pending_apply", "conflict", "completed", "cancelled", "error", "scope_violation" }
  local allowed = {
    running = {
      waiting_user = true,
      pending_apply = true,
      completed = true,
      cancelled = true,
      error = true,
      scope_violation = true,
    },
    waiting_user = { running = true, cancelled = true, error = true },
    pending_apply = { completed = true, conflict = true, cancelled = true, error = true, scope_violation = true },
    conflict = { completed = true, cancelled = true, error = true },
  }
  for _, from in ipairs(states) do
    for _, to in ipairs(states) do
      local session = { active_job_key = "job" }
      local job = { key = "job", root = "/acceptance/state-01", state = from }
      if from == "waiting_user" then
        job.waiting_kind = "question"
      end
      if from == "conflict" then
        job.conflict_kind, job.conflict_payload = "agent", { marker = true }
      end
      local attrs = { session = session }
      if to == "waiting_user" then
        attrs.waiting_kind = "question"
      elseif to == "conflict" then
        attrs.conflict_kind, attrs.conflict_payload = "agent", { marker = true }
      end
      local expected = from == to and jobs.terminal(from) or allowed[from] and allowed[from][to] or false
      eq(jobs.transition(job, to, attrs), expected, from .. " -> " .. to)
      eq(job.state, expected and to or from, from .. " -> " .. to)
    end
  end
  local waiting = { key = "waiting", root = "/acceptance/state-01", state = "running" }
  eq(jobs.transition(waiting, "waiting_user", {}), false)
  eq(waiting.state, "running")
  local conflict = { key = "conflict", root = "/acceptance/state-01", state = "pending_apply" }
  eq(jobs.transition(conflict, "conflict", { conflict_kind = "agent" }), false)
  eq(conflict.state, "pending_apply")
end

T["AC-STATE-02 Session availability follows local Job state before remote status"] = function()
  local sessions = require("opencode.session")
  local root = "/acceptance/state-02"
  local runtime = runtime_fixture(root, fake_client())
  local active_states = { "running", "waiting_user", "pending_apply", "conflict" }
  for _, state in ipairs(active_states) do
    local job = { key = "job_" .. state, session_id = "ses_" .. state, state = state }
    local session = { id = job.session_id, active_job_key = job.key }
    runtime.jobs[job.key], runtime.sessions[session.id] = job, session
    eq(
      { (sessions.availability(runtime, session, "idle")), (sessions.availability(runtime, session, "idle")) },
      { "active", "active" }
    )
    eq(sessions.availability(runtime, session, "idle"), "active")
    runtime.jobs[job.key] = nil
  end
  for _, state in ipairs({ "completed", "cancelled", "error", "scope_violation" }) do
    local job = { key = "terminal_" .. state, session_id = "ses_terminal_" .. state, state = state }
    local session = { id = job.session_id, active_job_key = job.key }
    runtime.jobs[job.key], runtime.sessions[session.id] = job, session
    eq(sessions.availability(runtime, session, "idle"), "reusable")
    runtime.jobs[job.key], session.active_job_key = nil, nil
  end
  local remote = { id = "ses_remote", active_job_key = nil }
  runtime.sessions[remote.id] = remote
  eq(sessions.availability(runtime, remote, "busy"), "blocked")
  eq({ runtime.prompt_locked, runtime.reconciliation_required, runtime.reconciliation_blocked }, { true, true, true })
  clear_fixture(runtime)
end

return T
